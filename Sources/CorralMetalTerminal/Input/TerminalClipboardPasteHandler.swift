import AppKit
import Foundation
import UniformTypeIdentifiers

public enum TerminalClipboardPasteTrigger: Sendable {
    case controlV
    case commandV
}

/// Resolves special clipboard payloads to UTF-8 terminal input while keeping
/// pasteboard ownership injectable for isolated tests.
@MainActor
public enum TerminalClipboardPasteHandler {
    /// Sends a resolved payload to `completion`; returns false when no text payload exists.
    @discardableResult
    public static func handle(
        pasteboard: NSPasteboard,
        trigger: TerminalClipboardPasteTrigger,
        completion: (Data) -> Void
    ) -> Bool {
        let text: String?
        switch trigger {
        case .controlV:
            text = writeClipboardImage(from: pasteboard).map(shellQuotedPath)
                ?? pasteboard.string(forType: .string)
        case .commandV:
            if let paths = clipboardFilePaths(from: pasteboard), !paths.isEmpty {
                text = paths.map(shellQuotedPath).joined(separator: " ")
            } else if let path = writeClipboardImage(from: pasteboard) {
                text = shellQuotedPath(path)
            } else {
                text = pasteboard.string(forType: .string)
            }
        }

        guard let text else { return false }
        completion(Data(text.utf8))
        return true
    }

    private static func clipboardFilePaths(from pasteboard: NSPasteboard) -> [String]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        let urls = objects.compactMap { $0 as? URL }.filter(\.isFileURL)
        if !urls.isEmpty { return urls.map { $0.standardizedFileURL.path } }

        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let filenames = pasteboard.propertyList(forType: filenamesType) as? [String] {
            return filenames.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        }
        if let value = pasteboard.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
            return [url.standardizedFileURL.path]
        }
        return nil
    }

    private static func writeClipboardImage(from pasteboard: NSPasteboard) -> String? {
        guard let png = clipboardPNGData(from: pasteboard) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-clipboard-\(UUID().uuidString).png")
        do {
            try png.write(to: url, options: .atomic)
            return url.standardizedFileURL.path
        } catch {
            return nil
        }
    }

    private static func clipboardPNGData(from pasteboard: NSPasteboard) -> Data? {
        var types: [NSPasteboard.PasteboardType] = [.png, .tiff]
        types.append(contentsOf: (pasteboard.types ?? []).filter {
            $0 != .png && $0 != .tiff && UTType($0.rawValue)?.conforms(to: .image) == true
        })
        for type in types {
            guard let data = pasteboard.data(forType: type), data.count <= 64 * 1024 * 1024 else { continue }
            let bitmap = NSBitmapImageRep(data: data)
                ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
            if let png = bitmap?.representation(using: .png, properties: [:]) { return png }
        }
        return nil
    }

    private static func shellQuotedPath(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
