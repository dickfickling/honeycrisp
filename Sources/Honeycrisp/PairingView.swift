import CompanionKit
import Observation
import SwiftUI

// MARK: - Row model

/// A discovered device as shown in the pairing list. Keyed by its stable
/// identifier so the list can dedup re-yielded scan results.
public struct PairingDeviceRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let host: String
    public let port: UInt16
    /// `true` when this identifier is already in the device store (shown dimmed).
    public let alreadyPaired: Bool
}

// MARK: - View model

/// Drives the pairing wizard: live scanning, PIN entry, and saving.
///
/// The pure list rules (dedup by identifier, drop identifier-less services, mark
/// already-paired) live in the static `merged`/`rows` helpers so they can be unit
/// tested without a live browser.
@Observable
@MainActor
public final class PairingModel {
    /// Which step of the wizard is showing.
    public enum Phase: Equatable {
        case scanning
        case pin(PairingDeviceRow)
        case success(String)
    }

    public private(set) var phase: Phase = .scanning
    public private(set) var rows: [PairingDeviceRow] = []
    public var pin: String = ""
    public private(set) var errorMessage: String?
    public private(set) var isBusy = false

    /// Identifiers already in the store; setting it re-derives the visible rows.
    @ObservationIgnored public var pairedIDs: Set<String> = [] {
        didSet { refreshRows() }
    }

    @ObservationIgnored private var discoveredByID: [String: DiscoveredDevice] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var discovery: CompanionDiscovery?
    @ObservationIgnored private var pairer: CompanionPairer?

    @ObservationIgnored private let makeDiscovery: () -> CompanionDiscovery
    @ObservationIgnored private let makePairer: (String, UInt16) -> CompanionPairer
    @ObservationIgnored private let onPaired: (StoredDevice) -> Void

    public init(
        makeDiscovery: @escaping () -> CompanionDiscovery = { CompanionDiscovery() },
        makePairer: @escaping (String, UInt16) -> CompanionPairer = { CompanionPairer(host: $0, port: $1) },
        onPaired: @escaping (StoredDevice) -> Void
    ) {
        self.makeDiscovery = makeDiscovery
        self.makePairer = makePairer
        self.onPaired = onPaired
    }

    // MARK: - Pure list rules (unit-tested)

    /// Fold a freshly discovered device into the accumulator, keyed by its
    /// identifier so the newest yield wins. Devices without an identifier are
    /// dropped (we can't key their credentials).
    public nonisolated static func merged(
        _ existing: [String: DiscoveredDevice], with device: DiscoveredDevice
    ) -> [String: DiscoveredDevice] {
        guard let id = device.identifier else { return existing }
        var copy = existing
        copy[id] = device
        return copy
    }

    /// Project the accumulator into sorted rows, marking store members dimmed.
    public nonisolated static func rows(
        from discovered: [String: DiscoveredDevice], paired: Set<String>
    ) -> [PairingDeviceRow] {
        discovered.values
            .compactMap { device -> PairingDeviceRow? in
                guard let id = device.identifier else { return nil }
                return PairingDeviceRow(
                    id: id, name: device.name, host: device.host, port: device.port,
                    alreadyPaired: paired.contains(id))
            }
            .sorted { lhs, rhs in
                if lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedSame {
                    return lhs.id < rhs.id
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: - Scanning

    public func startScan() {
        stopScan()
        phase = .scanning
        errorMessage = nil
        discoveredByID = [:]
        refreshRows()

        let discovery = makeDiscovery()
        self.discovery = discovery
        let stream = discovery.devices()
        scanTask = Task { [weak self] in
            for await device in stream {
                guard let self else { return }
                self.discoveredByID = Self.merged(self.discoveredByID, with: device)
                self.refreshRows()
            }
        }
    }

    public func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        discovery?.stop()
        discovery = nil
    }

    public func rescan() {
        startScan()
    }

    private func refreshRows() {
        rows = Self.rows(from: discoveredByID, paired: pairedIDs)
    }

    // MARK: - Pairing

    /// Begin Pair-Setup with a device (the TV then shows a PIN).
    public func beginPairing(_ row: PairingDeviceRow) async {
        guard !row.alreadyPaired else { return }
        stopScan()
        errorMessage = nil
        pin = ""
        isBusy = true
        defer { isBusy = false }

        let pairer = makePairer(row.host, row.port)
        self.pairer = pairer
        do {
            _ = try await pairer.begin()
            phase = .pin(row)
        } catch {
            errorMessage = "Couldn't start pairing: \(error.localizedDescription)"
            // Close any half-open connection before dropping the pairer.
            await pairer.cancel()
            self.pairer = nil
            startScan()
        }
    }

    /// Finish pairing with the entered PIN, saving credentials on success.
    ///
    /// A failed SRP attempt (wrong PIN) can't be resumed, so on error we begin a
    /// fresh pairing session in the background so the user can retry immediately.
    public func submitPin() async {
        guard case let .pin(row) = phase, let pinValue = Int(pin), let pairer else { return }
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let credentials = try await pairer.finish(pin: pinValue)
            let device = StoredDevice(
                id: row.id, name: row.name, credentials: credentials.stringValue)
            onPaired(device)
            self.pairer = nil
            phase = .success(row.name)
        } catch {
            errorMessage = Self.describePairingError(error)
            pin = ""
            await rebegin(row)
        }
    }

    /// Tear down everything when the wizard window closes: stop scanning and
    /// cancel any mid-flight pairing session so its connection is released.
    public func shutdown() async {
        stopScan()
        await pairer?.cancel()
        pairer = nil
    }

    /// Abandon PIN entry and go back to scanning.
    public func cancelPairing() async {
        await pairer?.cancel()
        pairer = nil
        pin = ""
        errorMessage = nil
        startScan()
    }

    private func rebegin(_ row: PairingDeviceRow) async {
        await pairer?.cancel()
        let pairer = makePairer(row.host, row.port)
        self.pairer = pairer
        do {
            _ = try await pairer.begin()
        } catch {
            self.pairer = nil
            errorMessage = "Pairing session ended. Rescan and try again."
        }
    }

    static func describePairingError(_ error: Error) -> String {
        if case PairingError.deviceError(0x02) = error {
            return "Incorrect PIN. Try again."
        }
        return "Pairing failed: \(error.localizedDescription)"
    }
}

// MARK: - View

/// Pairing wizard shown in the "Add Device" window. Replaces the old placeholder.
struct PairingView: View {
    @Environment(AppState.self) private var appState
    @State private var model: PairingModel?

    var body: some View {
        Group {
            if let model {
                PairingContent(model: model)
            } else {
                Color.clear
            }
        }
        .frame(width: 340, height: 320)
        .onAppear {
            if model == nil {
                let created = PairingModel { device in appState.addDevice(device) }
                created.pairedIDs = Set(appState.devices.map(\.id))
                created.startScan()
                model = created
            }
        }
        .onChange(of: appState.devices) { _, newValue in
            model?.pairedIDs = Set(newValue.map(\.id))
        }
        .onDisappear {
            // Discard the model so reopening the window starts a fresh scan
            // (no stale PIN/success phase), tearing down any mid-flight pairer.
            let closing = model
            model = nil
            Task { await closing?.shutdown() }
        }
    }
}

private struct PairingContent: View {
    @Bindable var model: PairingModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            switch model.phase {
            case .scanning:
                scanning
            case let .pin(row):
                pinEntry(row)
            case let .success(name):
                success(name)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Scanning

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add a device")
                    .font(.headline)
                Spacer()
                Button {
                    model.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan")
            }

            if model.rows.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Scanning for Apple TVs…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.rows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            if row.alreadyPaired {
                                Text("Already paired")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Pair") {
                            Task { await model.beginPairing(row) }
                        }
                        .disabled(row.alreadyPaired || model.isBusy)
                    }
                    .opacity(row.alreadyPaired ? 0.5 : 1)
                }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: PIN entry

    private func pinEntry(_ row: PairingDeviceRow) -> some View {
        VStack(spacing: 14) {
            Text("Pair with \(row.name)")
                .font(.headline)
            Text("Enter the 4-digit PIN shown on your Apple TV.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("PIN", text: $model.pin)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.title2.monospacedDigit())
                .frame(width: 120)
                .focused($pinFocused)
                .onChange(of: model.pin) { _, newValue in
                    let digits = newValue.filter(\.isNumber)
                    model.pin = String(digits.prefix(4))
                }
                .onSubmit { submit() }
                .onAppear { pinFocused = true }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    Task { await model.cancelPairing() }
                }
                .disabled(model.isBusy)
                Button("Pair") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pin.count != 4 || model.isBusy)
            }

            if model.isBusy {
                ProgressView()
            }
        }
    }

    private func submit() {
        guard model.pin.count == 4, !model.isBusy else { return }
        Task { await model.submitPin() }
    }

    // MARK: Success

    private func success(_ name: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Paired with \(name)")
                .font(.headline)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
