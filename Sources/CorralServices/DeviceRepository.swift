import CorralContracts
import Foundation

public enum DeviceRepositoryError: Error, Equatable, Sendable {
    case invalidDevice
    case confirmationRequired
    case deletionNotConfirmed
    case sessionCleanupUnavailable
    case deletionInProgress
    case unsafeStorage
    case corruptStore
}

/// Two separate positive responses are required before destructive cleanup can begin.
public protocol DeviceDeletionConfirming: Sendable {
    func confirmFirstDeletion(of device: DeviceRecord) async -> Bool
    func confirmFinalDeletion(of device: DeviceRecord) async -> Bool
}

/// Connectors use this hook to disconnect a device and remove its local session records.
public protocol DeviceSessionLifecycle: Sendable {
    func disconnectSessions(on deviceID: DeviceID) async throws
    func removeSessions(on deviceID: DeviceID) async throws
}

/// Stores only device metadata and opaque credential handles; credential secrets belong in Keychain.
public actor DeviceRepository: DeviceRepositoryProtocol {
    public static let namespace = CorralPrivateStorage.namespace
    public static let storageFilename = "devices.json"

    private let storageURL: URL
    private let deletionConfirmer: (any DeviceDeletionConfirming)?
    private let sessionLifecycle: (any DeviceSessionLifecycle)?
    private var devices: [DeviceRecord]
    private var deletingDeviceIDs = Set<DeviceID>()

    /// `applicationSupportDirectory` is injectable for isolated tests; the namespace is always appended.
    public init(
        applicationSupportDirectory: URL? = nil,
        deletionConfirmer: (any DeviceDeletionConfirming)? = nil,
        sessionLifecycle: (any DeviceSessionLifecycle)? = nil
    ) throws {
        let directoryURL = try CorralPrivateStorage.directoryURL(applicationSupportDirectory: applicationSupportDirectory)
        let storageURL = directoryURL.appendingPathComponent(Self.storageFilename, isDirectory: false)
        self.storageURL = storageURL
        self.deletionConfirmer = deletionConfirmer
        self.sessionLifecycle = sessionLifecycle
        let loaded = try Self.loadDevices(from: storageURL)
        self.devices = loaded.devices
        if loaded.requiresPruning {
            try Self.persist(loaded.devices, to: storageURL)
        }
    }

    public func listDevices() async throws -> [DeviceRecord] {
        devices
    }

    public func device(id: DeviceID) -> DeviceRecord? {
        devices.first { $0.id == id }
    }

    /// Inserts or updates a device after re-validating its endpoint at the persistence boundary.
    public func save(_ device: DeviceRecord) async throws {
        guard !device.id.rawValue.isEmpty else { throw DeviceRepositoryError.invalidDevice }
        guard !deletingDeviceIDs.contains(device.id) else { throw DeviceRepositoryError.deletionInProgress }
        let endpoint = try device.endpoint.revalidated()
        let validated = DeviceRecord(id: device.id, name: device.name, endpoint: endpoint, credential: device.credential)
        var updated = devices
        if let index = updated.firstIndex(where: { $0.id == validated.id }) {
            updated[index] = validated
        } else {
            updated.append(validated)
        }
        try Self.persist(updated, to: storageURL)
        devices = updated
    }

    /// Renames a device without changing its endpoint or opaque credential reference.
    public func rename(id: DeviceID, to name: String) async throws {
        guard let existing = devices.first(where: { $0.id == id }) else {
            throw DeviceRepositoryError.invalidDevice
        }
        try await save(DeviceRecord(id: existing.id, name: name, endpoint: existing.endpoint, credential: existing.credential))
    }

    /// Deletion fails closed unless the injected confirmer has completed both confirmations.
    public func delete(id: DeviceID) async throws {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        guard deletingDeviceIDs.insert(id).inserted else { throw DeviceRepositoryError.deletionInProgress }
        defer { deletingDeviceIDs.remove(id) }
        guard let deletionConfirmer else { throw DeviceRepositoryError.confirmationRequired }
        guard let sessionLifecycle else { throw DeviceRepositoryError.sessionCleanupUnavailable }
        guard await deletionConfirmer.confirmFirstDeletion(of: device),
              await deletionConfirmer.confirmFinalDeletion(of: device) else {
            throw DeviceRepositoryError.deletionNotConfirmed
        }

        try await sessionLifecycle.disconnectSessions(on: id)
        try await sessionLifecycle.removeSessions(on: id)

        let updated = devices.filter { $0.id != id }
        try Self.persist(updated, to: storageURL)
        devices = updated
    }

    private static func loadDevices(from url: URL) throws -> (devices: [DeviceRecord], requiresPruning: Bool) {
        guard let data = try CorralPrivateStorage.readData(from: url) else { return ([], false) }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw DeviceRepositoryError.corruptStore
        }
        let decoder = JSONDecoder()
        var loaded: [DeviceRecord] = []
        var seen = Set<DeviceID>()
        var requiresPruning = false

        for row in rows {
            guard JSONSerialization.isValidJSONObject(row), let rowData = try? JSONSerialization.data(withJSONObject: row),
                  let raw = try? decoder.decode(PersistedDevice.self, from: rowData) else {
                requiresPruning = true
                continue
            }
            guard !raw.id.isEmpty,
                  let endpoint = try? raw.endpoint.revalidated() else {
                requiresPruning = true
                continue
            }
            guard seen.insert(DeviceID(raw.id)).inserted else {
                requiresPruning = true
                continue
            }
            loaded.append(DeviceRecord(
                id: DeviceID(raw.id),
                name: raw.name,
                endpoint: endpoint,
                credential: CredentialHandle(raw.credentialHandle)
            ))
        }
        if loaded.count != rows.count { requiresPruning = true }
        return (loaded, requiresPruning)
    }

    private static func persist(_ devices: [DeviceRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(devices.map(PersistedDevice.init))
        try CorralPrivateStorage.atomicallyWrite(data, to: url)
    }
}

private struct PersistedDevice: Codable {
    let id: String
    let name: String
    let endpoint: ApprovedEndpoint
    let credentialHandle: String

    init(_ device: DeviceRecord) {
        id = device.id.rawValue
        name = device.name
        endpoint = device.endpoint
        credentialHandle = device.credential.rawValue
    }
}
