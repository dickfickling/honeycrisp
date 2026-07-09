import Foundation

/// A paired Apple TV as persisted on disk.
///
/// `id` is the pyatv identifier. On disk the collection is stored as a JSON
/// dictionary keyed by identifier, matching the old Electron app's shape:
/// `{ "<identifier>": { "name": ..., "credentials": ... } }`.
public struct StoredDevice: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var credentials: String

    public init(id: String, name: String, credentials: String) {
        self.id = id
        self.name = name
        self.credentials = credentials
    }
}

/// Reads and writes the paired-device list and remembers which device is active.
///
/// The devices themselves live in a JSON file under Application Support; the
/// active-device selection is a lightweight preference kept in `UserDefaults`.
/// Both the directory and the defaults are injectable so the store is unit
/// testable against a temp directory and a throwaway defaults suite.
public final class DeviceStore {
    /// Per-entry payload as stored on disk (the identifier is the dictionary key).
    private struct Entry: Codable {
        var name: String
        var credentials: String
    }

    private let directory: URL
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let activeDeviceKey = "activeDeviceID"

    public init(
        directory: URL = DeviceStore.defaultDirectory,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.defaults = defaults
        self.fileManager = fileManager
    }

    /// `~/Library/Application Support/Honeycrisp`.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Honeycrisp", isDirectory: true)
    }

    /// Location of the devices JSON file.
    public var fileURL: URL {
        directory.appendingPathComponent("devices.json", isDirectory: false)
    }

    // MARK: - Devices

    /// Loads the persisted devices, sorted by name for a stable display order.
    /// Returns an empty array when the file is missing or unreadable.
    public func load() -> [StoredDevice] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else {
            return []
        }
        return Self.displaySorted(
            entries.map { StoredDevice(id: $0.key, name: $0.value.name, credentials: $0.value.credentials) })
    }

    /// The stable display order shared by `load`, `upsert`, and `remove`.
    private static func displaySorted(_ devices: [StoredDevice]) -> [StoredDevice] {
        devices.sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.id < rhs.id }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Atomically persists the full device list.
    public func save(_ devices: [StoredDevice]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let dict = Dictionary(
            uniqueKeysWithValues: devices.map { ($0.id, Entry(name: $0.name, credentials: $0.credentials)) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(dict)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Inserts or updates a device by identifier and returns the new list.
    @discardableResult
    public func upsert(_ device: StoredDevice) throws -> [StoredDevice] {
        var devices = load()
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        try save(devices)
        // Return the in-memory list, not a re-read: load() maps transient read
        // failures to [], which would blank the UI even though the save worked.
        return Self.displaySorted(devices)
    }

    /// Removes a device by identifier and returns the new list. Clears the
    /// active selection if it pointed at the removed device.
    @discardableResult
    public func remove(id: String) throws -> [StoredDevice] {
        var devices = load()
        devices.removeAll { $0.id == id }
        try save(devices)
        if activeDeviceID == id {
            activeDeviceID = nil
        }
        return Self.displaySorted(devices)
    }

    // MARK: - Active device

    /// The identifier of the currently selected device, persisted in defaults.
    public var activeDeviceID: String? {
        get { defaults.string(forKey: activeDeviceKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: activeDeviceKey)
            } else {
                defaults.removeObject(forKey: activeDeviceKey)
            }
        }
    }
}
