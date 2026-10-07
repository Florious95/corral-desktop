import AppKit
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import CorralUI

/// Issue 22 gate for the user-visible QR export action.
///
/// The test drives the real pairing dialog and real PNG/QR export completion.
/// Only the NSSavePanel presentation boundary is injected: invoking the system
/// remote panel from XCTest can destroy its AppKit proxy during teardown and
/// crash the xctest host with SIG6/SIG11. The injected presenter still checks
/// the production panel configuration and supplies the user's selected URL to
/// the same completion/write path used by the native panel.
@MainActor
final class Issue22PairingQRCodeExportTests: XCTestCase {
    func testPairingDialogSaveQRCodeButtonExportsDecodableV1Payload() throws {
        let destination = try makePrivateDirectory(prefix: "corral-issue22-save-")
        defer { try? FileManager.default.removeItem(at: destination) }

        let payload = CorralPairingPayload(
            url: "wss://pair.example/ws",
            token: "issue22-private-token",
            name: "Issue 22 Fixture",
            candidates: ["wss://100.64.0.1:9919/ws", "wss://192.168.1.50:9919/ws"],
            hostID: "issue22-host-id",
            port: 9919
        )
        let (dialog, window) = try makeDialog(payload: payload)

        let target = destination.appendingPathComponent("pairing.png")
        var presentedPanel: NSSavePanel?
        var presentedParent: NSWindow?
        var presentedDefaultName: String?
        var presenterCalls = 0
        dialog.savePanelPresenter = { panel, parent, completion in
            presenterCalls += 1
            presentedPanel = panel
            presentedParent = parent
            presentedDefaultName = panel.nameFieldStringValue
            panel.directoryURL = destination
            panel.nameFieldStringValue = target.lastPathComponent
            completion(.OK, target)
        }

        let saveButton = try XCTUnwrap(saveButton(in: dialog), "The real pairing dialog must expose 保存二维码")
        XCTAssertTrue(saveButton.isEnabled, "A rendered QR payload must make Save QR actionable")
        saveButton.performClick(nil)

        XCTAssertEqual(presenterCalls, 1)
        XCTAssertTrue(presentedParent === window, "The native panel must be presented as a sheet of the pairing dialog")
        XCTAssertTrue(presentedPanel?.allowedContentTypes.contains(.png) == true,
                      "The export action must restrict the native panel to PNG")
        XCTAssertEqual(presentedDefaultName, "Corral-Pairing.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "Save completion must write the selected PNG")

        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let permissions = try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(permissions & 0o077, 0, "The exported QR must not be group/world accessible")

        let decoded = try decodeQRCode(at: target)
        XCTAssertFalse(decoded.contains("\n"), "The QR payload must be one-line JSON")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["host_id"] as? String, "issue22-host-id")
        XCTAssertEqual(object["token"] as? String, "issue22-private-token")
        XCTAssertEqual(object["port"] as? Int, 9919)
        XCTAssertEqual(object["candidates"] as? [String], payload.candidates)
        XCTAssertEqual(object["url"] as? String, payload.candidates[0])
    }

    func testCancelingSaveQRCodeDoesNotWriteAFile() throws {
        let destination = try makePrivateDirectory(prefix: "corral-issue22-cancel-")
        defer { try? FileManager.default.removeItem(at: destination) }

        let payload = CorralPairingPayload(
            url: "wss://pair.example/ws",
            token: "issue22-cancel-token",
            candidates: ["wss://100.64.0.1:9919/ws"],
            hostID: "issue22-cancel-host"
        )
        let (dialog, _) = try makeDialog(payload: payload)

        var presenterCalls = 0
        dialog.savePanelPresenter = { _, _, completion in
            presenterCalls += 1
            completion(.cancel, nil)
        }
        let saveButton = try XCTUnwrap(saveButton(in: dialog), "The pairing dialog must expose 保存二维码")
        saveButton.performClick(nil)

        XCTAssertEqual(presenterCalls, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).isEmpty,
                      "Canceling Save QR must not create a file")
    }

    func testSaveQRCodeWithNoRenderedQRCodeDoesNotWriteAFile() throws {
        let destination = try makePrivateDirectory(prefix: "corral-issue22-empty-")
        defer { try? FileManager.default.removeItem(at: destination) }

        let payload = CorralPairingPayload(url: "ws://127.0.0.1:9919/ws")
        let (dialog, _) = try makeDialog(payload: payload)
        XCTAssertNil(dialog.qrImage, "A local pairing dialog without token/hosts must have no QR")

        var presenterCalls = 0
        dialog.savePanelPresenter = { _, _, _ in presenterCalls += 1 }
        let saveButton = try XCTUnwrap(saveButton(in: dialog), "The dialog must keep the Save QR action discoverable")
        XCTAssertFalse(saveButton.isEnabled, "Save QR must be disabled when no QR is rendered")
        saveButton.performClick(nil)

        XCTAssertEqual(presenterCalls, 0, "A disabled/no-QR action must not present a SavePanel")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).isEmpty,
                      "No QR must never write a file")
    }

    private func makePrivateDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func makeDialog(payload: CorralPairingPayload) throws -> (PairingDialogViewController, NSWindow) {
        _ = NSApplication.shared
        let dialog = PairingDialogViewController(payload: payload)
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 420, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // AppKit may still finish a close transform after close() returns.
        // Keep the test owner alive until the teardown RunLoop drain releases
        // it, instead of letting the animation message a deallocated window.
        window.isReleasedWhenClosed = false
        window.contentViewController = dialog
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        dialog.view.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            if let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .cancel)
                sheet.orderOut(nil)
                sheet.close()
            }
            dialog.savePanelPresenter = nil
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            for _ in 0..<6 {
                CATransaction.flush()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
            }
            CATransaction.flush()
        }
        return (dialog, window)
    }

    private func saveButton(in dialog: PairingDialogViewController) -> NSButton? {
        descendants(of: dialog.view).compactMap { $0 as? NSButton }
            .first(where: { $0.title == "保存二维码" })
    }

    private func decodeQRCode(at url: URL) throws -> String {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "The saved file must be a readable image")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "The saved file must contain a PNG image")
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let result = try XCTUnwrap(
            request.results?.first(where: { $0.symbology == .QR }),
            "The exported PNG must contain a QR code"
        )
        return try XCTUnwrap(result.payloadStringValue, "The QR scanner must recover a payload")
    }
}

@MainActor
private func descendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(descendants)
}
