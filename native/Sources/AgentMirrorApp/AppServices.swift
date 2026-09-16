import Services
import Shell

/// Application-owned composition root for the four native capabilities.
///
/// This is deliberately a concrete protocol conformer rather than a subclass:
/// the app owns service identity and can inject an isolated namespace in tests,
/// while Shell still provides its own equivalent default for direct probes.
@MainActor
public final class AppServices: ShellServiceHandling {
    public static let shared = AppServices()

    public let namespace: KeychainNamespace
    public let availableMethods: Set<String> = [
        "devices.load", "devices.save",
        "secureStore.get", "secureStore.set",
        "clipboard.text", "clipboard.readText",
        "clipboard.image", "clipboard.readImage",
        "clipboard.files", "clipboard.readFiles",
        "upload", "upload.http",
    ]
    private let implementation: DefaultShellServices

    public init(
        namespace: KeychainNamespace = .currentApp,
        deviceStore: DeviceStore? = nil,
        uploadService: UploadService = .shared,
        clipboardService: ClipboardService? = nil
    ) {
        self.namespace = namespace
        let store = deviceStore ?? (namespace == .currentApp
            ? DeviceStore.shared
            : DeviceStore(namespace: namespace))
        self.implementation = DefaultShellServices(
            namespace: namespace,
            deviceStore: store,
            uploadService: uploadService,
            clipboardService: clipboardService ?? ClipboardService.shared
        )
    }

    public func handle(method: String, params: [String: Any]) async throws -> Any {
        try await implementation.handle(method: method, params: params)
    }
}
