import Foundation
import Observation
import os

/// App-wide observable state: the paired devices, the active selection, and the
/// controller the UI sends commands through. Created once by `HoneycrispApp` and
/// injected into the SwiftUI environment.
@Observable
@MainActor
public final class AppState {
    @ObservationIgnored
    private let store: DeviceStore

    @ObservationIgnored
    private let logger = Logger(subsystem: "us.fickling.honeycrisp2", category: "AppState")

    /// The controller commands are dispatched to. A mock for now.
    public let remote: any RemoteControlling

    /// All paired devices, sorted for display.
    public private(set) var devices: [StoredDevice]

    /// Identifier of the active device, or `nil` when none is selected.
    public private(set) var activeDeviceID: String?

    /// The active device, resolved against the current list.
    public var activeDevice: StoredDevice? {
        guard let activeDeviceID else { return nil }
        return devices.first { $0.id == activeDeviceID }
    }

    public init(
        store: DeviceStore = DeviceStore(),
        remote: any RemoteControlling = MockRemoteController()
    ) {
        self.store = store
        self.remote = remote
        let loaded = store.load()
        self.devices = loaded
        // Prefer the persisted selection, but only if it still exists; otherwise
        // fall back to the first available device.
        let persisted = store.activeDeviceID
        if let persisted, loaded.contains(where: { $0.id == persisted }) {
            self.activeDeviceID = persisted
        } else {
            self.activeDeviceID = loaded.first?.id
        }
        // Persist the resolved selection so disk and memory agree.
        store.activeDeviceID = self.activeDeviceID
    }

    /// Re-reads the device list from disk (used after mutations).
    public func reload() {
        devices = store.load()
        if let activeDeviceID, !devices.contains(where: { $0.id == activeDeviceID }) {
            setActiveDevice(devices.first?.id)
        }
    }

    /// Selects the active device and persists the choice.
    public func setActiveDevice(_ id: String?) {
        activeDeviceID = id
        store.activeDeviceID = id
    }

    /// Adds (or updates) a device and refreshes the list.
    public func addDevice(_ device: StoredDevice) {
        do {
            devices = try store.upsert(device)
            if activeDeviceID == nil {
                setActiveDevice(device.id)
            }
        } catch {
            logger.error("Failed to add device: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes a device and refreshes the list and active selection.
    public func removeDevice(_ id: String) {
        do {
            devices = try store.remove(id: id)
            if activeDeviceID == id {
                setActiveDevice(devices.first?.id)
            }
        } catch {
            logger.error("Failed to remove device: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fire-and-forget command dispatch. Errors are logged, not surfaced.
    public func send(_ command: RemoteCommand) {
        Task {
            do {
                try await remote.send(command)
            } catch {
                logger.error("send(\(command.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
