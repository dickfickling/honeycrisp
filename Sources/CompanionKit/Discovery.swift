import Foundation
import Network

/// A Companion service discovered on the local network.
public struct DiscoveredDevice: Sendable, Equatable {
    /// The Bonjour service instance name (e.g. "Living Room").
    public let name: String
    /// Resolved host (IP or hostname) to connect to.
    public let host: String
    /// Resolved TCP port.
    public let port: UInt16
    /// Stable device identifier from the TXT record, if present
    /// (pyatv derives this from `rpmrtid`).
    public let identifier: String?
    /// Raw TXT key/value pairs advertised by the service.
    public let txt: [String: String]

    public init(
        name: String, host: String, port: UInt16,
        identifier: String?, txt: [String: String]
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.identifier = identifier
        self.txt = txt
    }
}

/// Discovers Apple TVs advertising the Companion service (`_companion-link._tcp`)
/// via Bonjour / `NWBrowser`.
///
/// Mirrors pyatv's scan for `_companion-link._tcp.local.` and its identifier
/// derivation (`get_unique_id` -> the `rpmrtid` TXT property).
public final class CompanionDiscovery: @unchecked Sendable {
    /// The Bonjour service type pyatv scans for.
    public static let serviceType = "_companion-link._tcp"

    private let queue = DispatchQueue(label: "companion.discovery")
    private let lock = NSLock()
    private var browser: NWBrowser?

    public init() {}

    /// Derive the stable device identifier from a service's TXT record the way
    /// pyatv does: the `rpmrtid` property (case-insensitive; pyatv lowercases
    /// all TXT keys). Returns `nil` when the property is absent.
    ///
    /// Pure and side-effect free, so it is unit-testable without a live browser.
    public static func identifier(fromTXT txt: [String: String]) -> String? {
        for (key, value) in txt where key.lowercased() == "rpmrtid" {
            return value
        }
        return nil
    }

    /// Browse for Companion services, yielding a `DiscoveredDevice` for each
    /// service that resolves to a host/port. The stream runs until the consumer
    /// stops iterating (which cancels the browser) or `stop()` is called.
    public func devices() -> AsyncStream<DiscoveredDevice> {
        AsyncStream { continuation in
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
                using: params)

            lock.lock()
            self.browser = browser
            lock.unlock()

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                for result in results {
                    self.handle(result, continuation: continuation)
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
                if case .cancelled = state { continuation.finish() }
            }
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
            browser.start(queue: queue)
        }
    }

    /// Resolve the current address of the device advertising `identifier`.
    ///
    /// Unlike `devices()`, which opens a probe connection to every Companion
    /// service on the network (HomePods, iPhones, Macs, …) before the caller
    /// can filter, this browses TXT records only — no connections — until a
    /// service's `rpmrtid` matches, then resolves just that one endpoint.
    /// Runs until it finds the device or the surrounding task is cancelled.
    public func resolveAddress(identifier: String) async -> (host: String, port: UInt16)? {
        let endpointStream = AsyncStream<NWEndpoint> { continuation in
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
                using: params)

            lock.lock()
            self.browser = browser
            lock.unlock()

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .bonjour(let record) = result.metadata,
                          Self.identifier(fromTXT: record.dictionary) == identifier
                    else { continue }
                    continuation.yield(result.endpoint)
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
                if case .cancelled = state { continuation.finish() }
            }
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
            browser.start(queue: queue)
        }

        for await endpoint in endpointStream {
            // The browser only re-yields on result-set changes, so a failed
            // probe would otherwise never be retried; give each matching
            // endpoint a few attempts before falling back to waiting.
            for _ in 0..<3 {
                if let resolved = await resolve(endpoint) {
                    stop()
                    return resolved
                }
                if Task.isCancelled { return nil }
            }
        }
        return nil
    }

    /// Stop browsing and release the underlying `NWBrowser`.
    public func stop() {
        lock.lock()
        let browser = self.browser
        self.browser = nil
        lock.unlock()
        browser?.cancel()
    }

    private func handle(
        _ result: NWBrowser.Result,
        continuation: AsyncStream<DiscoveredDevice>.Continuation
    ) {
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata {
            txt = record.dictionary
        }
        let name: String
        if case .service(let serviceName, _, _, _) = result.endpoint {
            name = serviceName
        } else {
            name = ""
        }
        let identifier = Self.identifier(fromTXT: txt)
        let endpoint = result.endpoint

        // Resolve host/port off the browser's serial queue so we do not block it.
        Task { [weak self] in
            guard let self, let (host, port) = await self.resolve(endpoint) else { return }
            continuation.yield(DiscoveredDevice(
                name: name, host: host, port: port,
                identifier: identifier, txt: txt))
        }
    }

    /// Resolve a Bonjour endpoint to a concrete host/port by briefly opening an
    /// `NWConnection` and reading its resolved remote endpoint.
    ///
    /// Every exit path resumes the continuation: `.waiting` counts as failure
    /// (a probe stuck in `.waiting` otherwise never resumes, and a suspended
    /// continuation cannot be cancelled — it would wedge any task group
    /// waiting on it, timeouts included), and a hard deadline backstops states
    /// the handler never reports (e.g. `.preparing` forever).
    private func resolve(_ endpoint: NWEndpoint) async -> (String, UInt16)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(String, UInt16)?, Never>) in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let resumed = ResolveLatch()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var resolved: (String, UInt16)?
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                        resolved = (Self.hostString(host), port.rawValue)
                    }
                    if resumed.take() { cont.resume(returning: resolved) }
                    connection.cancel()
                case .failed, .cancelled:
                    if resumed.take() { cont.resume(returning: nil) }
                    connection.cancel()
                case .waiting:
                    // Transient while mDNS resolves the service endpoint — not
                    // terminal. The deadline below bounds a probe that never
                    // leaves this state.
                    break
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + 3) {
                if resumed.take() {
                    cont.resume(returning: nil)
                    connection.cancel()
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _): return name
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        @unknown default: return "\(host)"
        }
    }
}

/// One-shot latch so a repeatedly-invoked `NWConnection.stateUpdateHandler`
/// resumes its continuation exactly once.
private final class ResolveLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
