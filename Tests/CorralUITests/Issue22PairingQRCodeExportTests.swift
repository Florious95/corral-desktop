import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import CorralUI

/// Issue 22 red gate for the user-visible QR export action.
///
/// The test deliberately drives the real PairingDialogViewController view
/// hierarchy and the real NSSavePanel.  It does not call a private image
/// helper or manufacture a QR file itself: the saved PNG must round-trip
/// through Vision back to the v1 payload shown by the dialog.
@MainActor
final class Issue22PairingQRCodeExportTests: XCTestCase {
    func testPairingDialogSaveQRCodeButtonExportsDecodableV1Payload() async throws {
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
        defer { window.close() }

        let saveButton = try XCTUnwrap(
            descendants(of: dialog.view).compactMap { $0 as? NSButton }
                .first(where: { $0.title == "保存二维码" }),
            "The real pairing dialog must expose a 保存二维码 button"
        )
        XCTAssertTrue(saveButton.isEnabled, "A rendered QR payload must make Save QR actionable")

        let target = destination.appendingPathComponent("pairing.png")
        let panelHandled = Task { @MainActor in
            await handleNextSavePanel(destination: target, decision: .save)
        }
        await Task.yield()
        saveButton.performClick(nil)
        let didHandlePanel = await panelHandled.value
        XCTAssertTrue(didHandlePanel, "The Save QR action must present a controllable NSSavePanel")

        let savedURL = await waitForPNG(in: destination)
        let saved = try XCTUnwrap(savedURL, "Save QR must create a PNG file")
        XCTAssertEqual(saved.standardizedFileURL, target.standardizedFileURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: saved.path)
        let permissions = try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(permissions & 0o077, 0, "The exported QR must not be group/world accessible")

        let decoded = try decodeQRCode(at: saved)
        XCTAssertFalse(decoded.contains("\n"), "The QR payload must be one-line JSON")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["host_id"] as? String, "issue22-host-id")
        XCTAssertEqual(object["token"] as? String, "issue22-private-token")
        XCTAssertEqual(object["port"] as? Int, 9919)
        XCTAssertEqual(object["candidates"] as? [String], payload.candidates)
        XCTAssertEqual(object["url"] as? String, payload.candidates[0])
    }

    func testCancelingSaveQRCodeDoesNotWriteAFile() async throws {
        let destination = try makePrivateDirectory(prefix: "corral-issue22-cancel-")
        defer { try? FileManager.default.removeItem(at: destination) }

        let payload = CorralPairingPayload(
            url: "wss://pair.example/ws",
            token: "issue22-cancel-token",
            candidates: ["wss://100.64.0.1:9919/ws"],
            hostID: "issue22-cancel-host"
        )
        let (dialog, window) = try makeDialog(payload: payload)
        defer { window.close() }
        let saveButton = try XCTUnwrap(saveButton(in: dialog), "The pairing dialog must expose 保存二维码")
        let panelHandled = Task { @MainActor in
            await handleNextSavePanel(
                destination: destination.appendingPathComponent("must-not-exist.png"),
                decision: .cancel
            )
        }
        await Task.yield()
        saveButton.performClick(nil)
        let didHandlePanel = await panelHandled.value
        XCTAssertTrue(didHandlePanel, "Cancel must be handled by the real SavePanel")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).isEmpty,
                      "Canceling Save QR must not create a file")
    }

    func testSaveQRCodeWithNoRenderedQRCodeDoesNotWriteAFile() async throws {
        let destination = try makePrivateDirectory(prefix: "corral-issue22-empty-")
        defer { try? FileManager.default.removeItem(at: destination) }

        let payload = CorralPairingPayload(url: "ws://127.0.0.1:9919/ws")
        let (dialog, window) = try makeDialog(payload: payload)
        defer { window.close() }
        XCTAssertNil(dialog.qrImage, "A local pairing dialog without token/hosts must have no QR")

        let saveButton = try XCTUnwrap(saveButton(in: dialog), "The dialog must keep the Save QR action discoverable")
        XCTAssertFalse(saveButton.isEnabled, "Save QR must be disabled when no QR is rendered")
        saveButton.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).isEmpty,
                      "No QR must never write a file")
    }

    private enum PanelDecision {
        case save
        case cancel
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
        window.contentViewController = dialog
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        dialog.view.layoutSubtreeIfNeeded()
        return (dialog, window)
    }

    private func saveButton(in dialog: PairingDialogViewController) -> NSButton? {
        descendants(of: dialog.view).compactMap { $0 as? NSButton }
            .first(where: { $0.title == "保存二维码" })
    }

    private func handleNextSavePanel(destination: URL, decision: PanelDecision) async -> Bool {
        for _ in 0..<300 {
            if let panel = visibleSavePanel() {
                switch decision {
                case .save:
                    panel.directoryURL = destination.deletingLastPathComponent()
                    panel.nameFieldStringValue = destination.lastPathComponent
                    panel.ok(nil)
                case .cancel:
                    panel.cancel(nil)
                }
                // NSSavePanel completion handlers are allowed to run while a
                // sheet's dismissal transform is still active.  Do not let
                // the test's parent-window defer close the owner during that
                // animation; AppKit can otherwise tear down an
                // NSWindowTransformAnimation from inside XCTest.
                await waitForSavePanelToDisappear()
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForSavePanelToDisappear() async {
        for _ in 0..<300 {
            if visibleSavePanel() == nil {
                // The sheet may have left the window list one run-loop turn
                // before its transform animation releases its layer.
                try? await Task.sleep(for: .milliseconds(250))
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func visibleSavePanel() -> NSSavePanel? {
        if let panel = NSApp.modalWindow as? NSSavePanel, panel.isVisible { return panel }
        if let panel = NSApp.keyWindow as? NSSavePanel, panel.isVisible { return panel }
        return NSApp.windows.compactMap { $0 as? NSSavePanel }.first(where: { $0.isVisible })
    }

    private func waitForPNG(in directory: URL) async -> URL? {
        let fileManager = FileManager.default
        for _ in 0..<100 {
            if let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
               let png = files.first(where: { $0.pathExtension.lowercased() == "png" }) {
                return png
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
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
