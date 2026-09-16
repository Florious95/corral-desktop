import Foundation
import Services
import Shell

/// Application-owned composition root for the four native capabilities.
///
/// This is deliberately a concrete protocol conformer rather than a subclass:
/// the app owns service identity and can inject an isolated file store in tests,
/// while Shell still provides its own equivalent default for direct probes.
@MainActor
public final class AppServices: ShellServiceHandling {
    public static let shared = AppServices()

    public let availableMethods: Set<String> = [
        "devices.load", "devices.save",
        "secureStore.get", "secureStore.set",
        "clipboard.text", "clipboard.readText",
        "clipboard.image", "clipboard.readImage",
        "clipboard.files", "clipboard.readFiles",
        "upload", "upload.http",
        "migration.loadUI", "migration.saveUI",
    ]
    private let implementation: DefaultShellServices
    private let uiSnapshotStore: UISnapshotStore

    public init(
        deviceStore: DeviceStore? = nil,
        uploadService: UploadService = .shared,
        clipboardService: ClipboardService? = nil,
        uiSnapshotStore: UISnapshotStore? = nil
    ) {
        self.implementation = DefaultShellServices(
            deviceStore: deviceStore,
            uploadService: uploadService,
            clipboardService: clipboardService ?? ClipboardService.shared
        )
        self.uiSnapshotStore = uiSnapshotStore ?? UISnapshotStore()
    }

    public func handle(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "migration.loadUI":
            guard params.isEmpty else { throw ShellError.invalidRequest }
            return uiSnapshotStore.load() ?? NSNull()
        case "migration.saveUI":
            let snapshot: Any
            if let wrapped = params["snapshot"] {
                guard params.count == 1 else { throw ShellError.invalidRequest }
                snapshot = wrapped
            } else {
                guard !params.isEmpty else { throw ShellError.invalidRequest }
                snapshot = params
            }
            do {
                try uiSnapshotStore.save(snapshot)
                return true
            } catch let error as UISnapshotError {
                switch error {
                case .tooLarge: throw ShellError.tooLarge
                case .io: throw ShellError.storageFailed
                case .invalidSnapshot, .sensitiveField: throw ShellError.invalidRequest
                }
            }
        default:
            return try await implementation.handle(method: method, params: params)
        }
    }
}
