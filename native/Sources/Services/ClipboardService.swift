import AppKit
import Foundation
import UniformTypeIdentifiers

public enum ClipboardError: Error, Equatable, Sendable {
    case invalidImage
    case invalidFileURL
}

extension ClipboardError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "clipboard_invalid_image"
        case .invalidFileURL: return "clipboard_invalid_file_url"
        }
    }
}

public struct ClipboardImage: Codable, Equatable, Sendable {
    public let name: String
    public let mime: String
    public let bytesBase64: String

    public init(name: String, mime: String, bytesBase64: String) {
        self.name = name
        self.mime = mime
        self.bytesBase64 = bytesBase64
    }

    public init(name: String, mime: String, bytes: Data) {
        self.init(name: name, mime: mime, bytesBase64: bytes.base64EncodedString())
    }

    public init(name: String, mime: String, bytes: [UInt8]) {
        self.init(name: name, mime: mime, bytes: Data(bytes))
    }

    public var bytes: Data? {
        Data(base64Encoded: bytesBase64)
    }
}

public typealias ClipboardImagePayload = ClipboardImage

/// MainActor keeps NSPasteboard access on AppKit's required thread while
/// allowing tests to inject a deterministic, non-system implementation.
@MainActor
public protocol PasteboardClient: AnyObject {
    func string(forType type: String) -> String?
    func data(forType type: String) -> Data?
    func fileURLs() -> [URL]
}

public typealias PasteboardProvider = PasteboardClient

@MainActor
public final class SystemPasteboard: PasteboardClient {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func string(forType type: String) -> String? {
        pasteboard.string(forType: NSPasteboard.PasteboardType(rawValue: type))
    }

    public func data(forType type: String) -> Data? {
        pasteboard.data(forType: NSPasteboard.PasteboardType(rawValue: type))
    }

    public func fileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { object in
            if let url = object as? URL { return url }
            if let url = object as? NSURL { return url as URL }
            return nil
        }
    }
}

@MainActor
public final class ClipboardService {
    public static let shared = ClipboardService()

    private static let plainTextType = "public.utf8-plain-text"
    private static let legacyStringType = NSPasteboard.PasteboardType.string.rawValue
    private static let imageTypes: [(type: String, mime: String, name: String)] = [
        (UTType.png.identifier, "image/png", "clipboard.png"),
        (UTType.jpeg.identifier, "image/jpeg", "clipboard.jpg"),
        (UTType.tiff.identifier, "image/tiff", "clipboard.tiff"),
    ]

    private let pasteboard: any PasteboardClient

    public init(pasteboard: any PasteboardClient = SystemPasteboard()) {
        self.pasteboard = pasteboard
    }

    /// Returns an empty string when no pasteboard text is available, matching
    /// the WebView capability contract.
    public func readText() -> String {
        pasteboard.string(forType: Self.plainTextType)
            ?? pasteboard.string(forType: Self.legacyStringType)
            ?? ""
    }

    /// Returns the first supported non-empty image representation in PNG,
    /// JPEG, TIFF order. Data is base64 only at the RPC boundary.
    public func readImage() -> ClipboardImage? {
        for imageType in Self.imageTypes {
            guard let data = pasteboard.data(forType: imageType.type), !data.isEmpty else {
                continue
            }
            return ClipboardImage(
                name: imageType.name,
                mime: imageType.mime,
                bytes: data
            )
        }
        return nil
    }

    /// Returns Finder file URLs in pasteboard order. Only normalized absolute
    /// paths are exposed; no shell parsing, execution, or path resolution is
    /// performed beyond URL normalization.
    public func readFiles() throws -> [String] {
        try pasteboard.fileURLs().map(Self.normalizedPath)
    }

    private nonisolated static func normalizedPath(_ url: URL) throws -> String {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw ClipboardError.invalidFileURL
        }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), !containsUnsafePathScalar(path) else {
            throw ClipboardError.invalidFileURL
        }
        return path
    }

    private nonisolated static func containsUnsafePathScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value == 0 || scalar.value == 0x0A || scalar.value == 0x0D
        }
    }
}
