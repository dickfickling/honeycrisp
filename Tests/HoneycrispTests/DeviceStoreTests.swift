import Foundation
import Testing
@testable import Honeycrisp

@Suite("DeviceStore")
struct DeviceStoreTests {
    /// Fresh temp directory + isolated defaults suite per test, cleaned up on deinit.
    private final class Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suiteName: String
        let store: DeviceStore

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("HoneycrispTests-\(UUID().uuidString)", isDirectory: true)
            suiteName = "HoneycrispTests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            store = DeviceStore(directory: directory, defaults: defaults)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @Test("Empty store loads no devices")
    func emptyLoad() {
        let f = Fixture()
        #expect(f.store.load().isEmpty)
    }

    @Test("Save then load round-trips devices")
    func roundTrip() throws {
        let f = Fixture()
        let a = StoredDevice(id: "id-a", name: "Living Room", credentials: "cred-a")
        let b = StoredDevice(id: "id-b", name: "Bedroom", credentials: "cred-b")
        try f.store.save([a, b])

        let loaded = f.store.load()
        #expect(Set(loaded) == Set([a, b]))
    }

    @Test("Load returns a stable name-sorted order")
    func sortedOrder() throws {
        let f = Fixture()
        try f.store.save([
            StoredDevice(id: "3", name: "Roof", credentials: "c3"),
            StoredDevice(id: "1", name: "Bedroom", credentials: "c1"),
            StoredDevice(id: "2", name: "kitchen", credentials: "c2"),
        ])
        #expect(f.store.load().map(\.name) == ["Bedroom", "kitchen", "Roof"])
    }

    @Test("Persistence survives a new store instance on the same directory")
    func persistsAcrossInstances() throws {
        let f = Fixture()
        let device = StoredDevice(id: "id-a", name: "Office", credentials: "cred")
        try f.store.save([device])

        let reopened = DeviceStore(directory: f.directory, defaults: f.defaults)
        #expect(reopened.load() == [device])
    }

    @Test("Upsert inserts new and updates existing by identifier")
    func upsert() throws {
        let f = Fixture()
        try f.store.upsert(StoredDevice(id: "id-a", name: "Old", credentials: "c1"))
        var loaded = f.store.load()
        #expect(loaded == [StoredDevice(id: "id-a", name: "Old", credentials: "c1")])

        try f.store.upsert(StoredDevice(id: "id-a", name: "New", credentials: "c2"))
        loaded = f.store.load()
        #expect(loaded == [StoredDevice(id: "id-a", name: "New", credentials: "c2")])
        #expect(loaded.count == 1)
    }

    @Test("Remove deletes the matching device")
    func remove() throws {
        let f = Fixture()
        try f.store.save([
            StoredDevice(id: "id-a", name: "A", credentials: "c1"),
            StoredDevice(id: "id-b", name: "B", credentials: "c2"),
        ])
        let remaining = try f.store.remove(id: "id-a")
        #expect(remaining.map(\.id) == ["id-b"])
    }

    @Test("activeDeviceID persists and clears")
    func activeDeviceIDPersistence() {
        let f = Fixture()
        #expect(f.store.activeDeviceID == nil)
        f.store.activeDeviceID = "id-a"
        #expect(f.store.activeDeviceID == "id-a")

        let reopened = DeviceStore(directory: f.directory, defaults: f.defaults)
        #expect(reopened.activeDeviceID == "id-a")

        reopened.activeDeviceID = nil
        #expect(reopened.activeDeviceID == nil)
    }

    @Test("Removing the active device clears the active selection")
    func removeActiveClearsSelection() throws {
        let f = Fixture()
        try f.store.save([StoredDevice(id: "id-a", name: "A", credentials: "c")])
        f.store.activeDeviceID = "id-a"
        try f.store.remove(id: "id-a")
        #expect(f.store.activeDeviceID == nil)
    }

    @Test("AppState resolves active device and falls back to first")
    @MainActor
    func appStateActiveResolution() throws {
        let f = Fixture()
        try f.store.save([
            StoredDevice(id: "id-a", name: "Alpha", credentials: "c1"),
            StoredDevice(id: "id-b", name: "Bravo", credentials: "c2"),
        ])
        // No persisted selection -> first (name-sorted) device wins.
        let state = AppState(store: DeviceStore(directory: f.directory, defaults: f.defaults))
        #expect(state.activeDevice?.id == "id-a")

        state.setActiveDevice("id-b")
        #expect(state.activeDevice?.id == "id-b")

        // Removing the active device advances to the remaining one.
        state.removeDevice("id-b")
        #expect(state.activeDevice?.id == "id-a")
    }

    @Test("AppState ignores a stale persisted active selection")
    @MainActor
    func appStateIgnoresStaleSelection() throws {
        let f = Fixture()
        try f.store.save([StoredDevice(id: "id-a", name: "Alpha", credentials: "c1")])
        f.store.activeDeviceID = "gone" // points at a device that no longer exists
        let state = AppState(store: DeviceStore(directory: f.directory, defaults: f.defaults))
        #expect(state.activeDevice?.id == "id-a")
    }

    /// Records `connect()` calls so eager-connect behavior is observable.
    @MainActor
    private final class RecordingController: RemoteControlling {
        let device: StoredDevice
        private(set) var connectCount = 0
        var connectionState: ConnectionState = .disconnected

        init(device: StoredDevice) { self.device = device }
        func send(_ command: RemoteCommand) async throws {}
        func connect() async throws { connectCount += 1 }
    }

    @Test("AppState eagerly connects to the most recently used device at launch and on switch")
    @MainActor
    func appStateEagerlyConnects() async throws {
        let f = Fixture()
        try f.store.save([
            StoredDevice(id: "id-a", name: "Alpha", credentials: "c1"),
            StoredDevice(id: "id-b", name: "Bravo", credentials: "c2"),
        ])
        f.store.activeDeviceID = "id-b" // most recently used

        var controllers: [RecordingController] = []
        let state = AppState(store: DeviceStore(directory: f.directory, defaults: f.defaults)) { device in
            let controller = RecordingController(device: device)
            controllers.append(controller)
            return controller
        }

        // Launch: one controller for the persisted device, eagerly connected.
        #expect(state.activeDevice?.id == "id-b")
        try #require(controllers.count == 1)
        #expect(controllers[0].device.id == "id-b")
        await waitUntil { controllers[0].connectCount == 1 }
        #expect(controllers[0].connectCount == 1)

        // Switching devices builds a fresh controller and eagerly connects it too.
        state.setActiveDevice("id-a")
        try #require(controllers.count == 2)
        #expect(controllers[1].device.id == "id-a")
        await waitUntil { controllers[1].connectCount == 1 }
        #expect(controllers[1].connectCount == 1)
    }

    /// Polls a main-actor condition (the eager connect runs in a spawned Task).
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
