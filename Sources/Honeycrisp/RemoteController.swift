import Foundation
import os

/// A single logical command the user can issue from the remote.
///
/// Raw values are the case names (camelCase). The mock controller only logs
/// them for now; the future CompanionKit-backed controller is responsible for
/// mapping these onto the wire protocol.
public enum RemoteCommand: String, CaseIterable, Sendable {
    case up
    case down
    case left
    case right
    case select
    case menu
    case homeHold
    case playPause
    case volumeUp
    case volumeDown
    case powerToggle
}

/// Connection lifecycle of a `RemoteControlling` instance. Kept as a plain
/// value type so it can drive SwiftUI observation from a concrete controller.
public enum ConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
}

/// Abstraction the UI talks to, so the app is fully runnable before the real
/// CompanionKit client exists. A later task swaps `MockRemoteController` for a
/// CompanionKit-backed implementation behind this same protocol.
///
/// Isolated to the main actor: the app is a SwiftUI menu-bar app and both the
/// connection state (observed by views) and command dispatch happen on the
/// main actor. A real controller performs its network I/O off-main internally.
@MainActor
public protocol RemoteControlling: AnyObject {
    var connectionState: ConnectionState { get }
    /// Human-readable description of the most recent failure, for a status
    /// tooltip. `nil` when there is nothing to report.
    var lastError: String? { get }
    func send(_ command: RemoteCommand) async throws
    /// Disconnect and release any live session. Called when the controller is
    /// being replaced (e.g. the user switched or removed the active device).
    func teardown() async
}

public extension RemoteControlling {
    var lastError: String? { nil }
    func teardown() async {}
}

/// A stand-in controller used until the real client lands. It reports itself as
/// permanently `connected` and logs every command it receives.
@Observable
@MainActor
public final class MockRemoteController: RemoteControlling {
    public private(set) var connectionState: ConnectionState = .connected

    @ObservationIgnored
    private let logger = Logger(subsystem: "us.fickling.honeycrisp2", category: "MockRemote")

    public init() {}

    public func send(_ command: RemoteCommand) async throws {
        logger.info("MockRemoteController.send(\(command.rawValue, privacy: .public))")
        print("MockRemoteController.send(\(command.rawValue))")
    }
}
