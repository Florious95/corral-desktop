import Foundation
#if canImport(Services)
import Services
#endif

/// Default concrete implementation used by Shell when a caller constructs a
/// MainWindowController directly (for example, a headless WebKit probe).
/// The application composition root uses the same capability behavior through
/// AppServices, while this fallback keeps direct Shell probes fully usable.
@MainActor
open class DefaultShellServices: ShellServiceHandling {
    public static let shared = DefaultShellServices()

    public let namespace: KeychainNamespace
    public let availableMethods: Set<String> = [
        "devices.load", "devices.save",
        "secureStore.get", "secureStore.set",
        "clipboard.text", "clipboard.readText",
        "clipboard.image", "clipboard.readImage",
        "clipboard.files", "clipboard.readFiles",
        "upload", "upload.http",
    ]

    private let deviceStore: DeviceStore
    private let uploadService: UploadService
    private let clipboardService: ClipboardService

    public init(
        namespace: KeychainNamespace = .currentApp,
        deviceStore: DeviceStore? = nil,
        uploadService: UploadService = .shared,
        clipboardService: ClipboardService? = nil
    ) {
        self.namespace = namespace
        self.deviceStore = deviceStore ?? (namespace == .currentApp
            ? DeviceStore.shared
            : DeviceStore(namespace: namespace))
        self.uploadService = uploadService
        self.clipboardService = clipboardService ?? ClipboardService.shared
    }

    public func handle(method: String, params: [String: Any]) async throws -> Any {
        do {
            switch method {
            case "devices.load":
                guard params.isEmpty else { throw ShellError.invalidRequest }
                return try await deviceStore.loadDevices().map(Self.dictionary)
            case "secureStore.get":
                try requireDevicesKey(params)
                return try await deviceStore.loadDevices().map(Self.dictionary)
            case "devices.save":
                let devices = try decodeDevices(params["devices"] ?? params["value"])
                try await deviceStore.saveDevices(devices)
                return true
            case "secureStore.set":
                try requireDevicesKey(params)
                let devices = try decodeDevices(params["value"])
                try await deviceStore.saveDevices(devices)
                return true
            case "clipboard.text", "clipboard.readText":
                guard params.isEmpty else { throw ShellError.invalidRequest }
                return clipboardService.readText()
            case "clipboard.image", "clipboard.readImage":
                guard params.isEmpty else { throw ShellError.invalidRequest }
                guard let image = clipboardService.readImage() else { return NSNull() }
                return [
                    "name": image.name,
                    "mime": image.mime,
                    "bytesBase64": image.bytesBase64,
                ]
            case "clipboard.files", "clipboard.readFiles":
                guard params.isEmpty else { throw ShellError.invalidRequest }
                return try clipboardService.readFiles()
            case "upload", "upload.http":
                return try await upload(params)
            default:
                throw ShellError.unsupported
            }
        } catch let error as ShellError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    private func upload(_ params: [String: Any]) async throws -> String {
        guard let url = params["url"] as? String,
              let filename = params["filename"] as? String,
              let mime = params["mime"] as? String,
              let bytesBase64 = params["bytesBase64"] as? String,
              let bytes = Data(base64Encoded: bytesBase64),
              !bytes.isEmpty else {
            throw ShellError.invalidRequest
        }

        let token: String
        if let supplied = params["token"] as? String {
            token = supplied
        } else if let deviceID = params["deviceId"] as? String {
            let devices = try await deviceStore.loadDevices()
            guard let device = devices.first(where: { $0.id == deviceID }) else {
                throw ShellError.invalidRequest
            }
            token = device.token
        } else {
            throw ShellError.invalidRequest
        }

        do {
            return try await uploadService.upload(
                url: url,
                token: token,
                filename: filename,
                mime: mime,
                bytes: bytes
            )
        } catch {
            throw Self.map(error)
        }
    }

    private func requireDevicesKey(_ params: [String: Any]) throws {
        guard params["key"] as? String == "devices",
              Set(params.keys) == ["key"] else {
            throw ShellError.invalidRequest
        }
    }

    private func decodeDevices(_ value: Any?) throws -> [Device] {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            throw ShellError.invalidRequest
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            return try JSONDecoder().decode([Device].self, from: data)
        } catch {
            throw ShellError.invalidRequest
        }
    }

    private static func dictionary(_ device: Device) -> [String: Any] {
        [
            "id": device.id,
            "name": device.name,
            "url": device.url,
            "token": device.token,
        ]
    }

    private static func map(_ error: Error) -> ShellError {
        switch error {
        case is DeviceStoreError, is MigrationError:
            return .storageFailed
        case is ClipboardError:
            return .invalidRequest
        case let error as UploadError:
            switch error {
            case .unauthorized: return .unauthorized
            case .unreachable: return .unreachable
            case .timeout: return .timeout
            case .httpStatus: return .httpStatus
            case .invalidURL, .invalidRequest, .invalidFile:
                return .invalidRequest
            case .invalidResponse:
                return .invalidResponse
            }
        default:
            return .unavailable
        }
    }
}
