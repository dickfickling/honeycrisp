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

    @ObservationIgnored
    private let makeController: @MainActor (StoredDevice) -> any RemoteControlling

    /// The controller commands are dispatched to, rebuilt for the active device.
    /// `nil` when no device is selected.
    public private(set) var remote: (any RemoteControlling)?

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
        makeController: @escaping @MainActor (StoredDevice) -> any RemoteControlling
            = { CompanionRemoteController(device: $0) }
    ) {
        self.store = store
        self.makeController = makeController
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
        rebuildController()
    }

    /// Re-reads the device list from disk (used after mutations).
    public func reload() {
        devices = store.load()
        if let activeDeviceID, !devices.contains(where: { $0.id == activeDeviceID }) {
            setActiveDevice(devices.first?.id)
        }
    }

    /// Selects the active device and persists the choice. Tears down the old
    /// controller and builds a fresh one for the new device.
    public func setActiveDevice(_ id: String?) {
        guard id != activeDeviceID else { return }
        activeDeviceID = id
        store.activeDeviceID = id
        rebuildController()
    }

    /// Disconnect the current controller (if any) and build a new one for the
    /// active device. A no-op-safe teardown runs on the outgoing controller.
    private func rebuildController() {
        if let old = remote {
            Task { await old.teardown() }
        }
        if let device = activeDevice {
            let controller = makeController(device)
            remote = controller
            // Eagerly reconnect to the most recently used device so the first
            // button press doesn't pay discovery + handshake latency. Failures
            // surface via the controller's connectionState/lastError; the next
            // send() retries lazily as before.
            Task { [logger] in
                do {
                    try await controller.connect()
                } catch {
                    logger.info("Eager connect failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            remote = nil
        }
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
        guard let remote else {
            logger.info("send(\(command.rawValue, privacy: .public)) ignored: no active device")
            return
        }
        Task {
            do {
                try await remote.send(command)
            } catch {
                logger.error("send(\(command.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
