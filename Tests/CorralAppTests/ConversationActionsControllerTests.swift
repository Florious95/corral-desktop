import AppKit
import CorralContracts
@testable import CorralProtocol
import CorralUI
import XCTest
@testable import CorralApp

@MainActor
final class ConversationActionsControllerTests: XCTestCase {
    private let ref = try! SessionReference("sock\u{1F}%7")
    private var sid = "old", viewID = "view1", epoch = ConnectionEpoch(1), ready = true, running = false
    private var sent: [(String, [String: Any])] = []
    private var transitions: [(String, String?)] = []
    private func make() -> ConversationActionsController {
        _ = NSApplication.shared
        let manager = ConversationActionsController(reference: ref) { [unowned self] in
            .init(epoch: epoch, sessionID: sid, viewID: viewID, ready: ready, running: running, queued: 0,
                  inputPending: false, markedText: false, title: "Native session")
        }
        manager.send = { [unowned self] command in
            guard case let .conversationCommand(reference, id, data) = command else { return XCTFail("Wrong transport") }
            XCTAssertEqual(reference, ref)
            sent.append((id, try JSONSerialization.jsonObject(with: data) as! [String: Any]))
        }
        manager.onTransition = { [unowned self] in transitions.append(($0, $1)) }
        return manager
    }
    private func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(20)) }
    private func respond(_ manager: ConversationActionsController, data: [String: Any], success: Bool = true, id: String? = nil) throws {
        let object: [String: Any] = ["type": "response", "id": try id ?? XCTUnwrap(sent.last?.0), "success": success, "data": data, "error": "native rejection"]
        XCTAssertTrue(manager.handle(.init(reference: ref, viewID: nil, sourceEpoch: nil, event: Data()), object: object))
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func submit(_ manager: ConversationActionsController) throws {
        let panel = try XCTUnwrap(manager.panel); panel.loadViewIfNeeded()
        let button = try XCTUnwrap(descendants(panel.view).first { $0.accessibilityIdentifier() == "corral.action.submit" } as? NSButton)
        button.performClick(nil)
    }

    func testHistoryUsesOnlyCatalogIDsAndRequiresReceiptPlusAdoptedTarget() async throws {
        let manager = make(); manager.open(.history); await settle()
        XCTAssertEqual(sent.last?.1["type"] as? String, "list_sessions")
        try respond(manager, data: ["sessions": [["session_id": "old", "current": true], ["session_id": "target", "name": "Target", "modified_ms": 1000]]])
        XCTAssertFalse(manager.panel!.selectChoice("old"))
        XCTAssertFalse(manager.panel!.selectChoice("/arbitrary/host/path"))
        XCTAssertTrue(manager.panel!.selectChoice("target"))
        try submit(manager); try submit(manager); await settle()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.1["type"] as? String, "resume_session")
        XCTAssertEqual(sent.last?.1["sessionId"] as? String, "target")
        XCTAssertEqual(sent.last?.1["force"] as? Bool, false)
        XCTAssertNil(sent.last?.1["sessionPath"])
        try respond(manager, data: ["session_id": "target"])
        XCTAssertTrue(manager.isBusy); XCTAssertTrue(transitions.isEmpty)
        sid = "target"; viewID = "view2"; ready = false; manager.update()
        XCTAssertTrue(transitions.isEmpty)
        ready = true; manager.update()
        XCTAssertEqual(transitions.first?.0, "target")
        XCTAssertTrue(manager.panel?.completed == true)
        XCTAssertFalse(manager.isBusy)
        manager.close()
    }

    func testBusyNewSessionRequiresExplicitSecondConsentAndCancellationIsNotSuccess() async throws {
        let manager = make(); running = true; manager.open(.newSession)
        try submit(manager); await settle()
        XCTAssertTrue(sent.isEmpty); XCTAssertTrue(manager.panel?.requiresForce == true)
        try submit(manager); await settle()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.last?.1["type"] as? String, "new_session")
        XCTAssertEqual(sent.last?.1["force"] as? Bool, true)
        try respond(manager, data: ["cancelled": true])
        XCTAssertFalse(manager.panel!.completed); XCTAssertTrue(transitions.isEmpty)
        manager.close()
    }

    func testForkUsesOpaqueNativePointAndRestoresOnlyConfirmedNativeDraft() async throws {
        let manager = make(); manager.open(.fork); await settle()
        XCTAssertEqual(sent.last?.1["type"] as? String, "fork_points")
        let point = String(repeating: "a", count: 32)
        try respond(manager, data: ["session_id": "old", "points": [["id": point, "text": "clipped preview"]]])
        XCTAssertTrue(manager.panel!.selectChoice(point))
        try submit(manager); await settle()
        XCTAssertEqual(sent.last?.1["type"] as? String, "fork_session")
        XCTAssertEqual(sent.last?.1["pointId"] as? String, point)
        try respond(manager, data: ["session_id": "forked", "draft": "完整中文原文\nnot the preview"])
        sid = "forked"; viewID = "new"; manager.update()
        XCTAssertEqual(transitions.first?.1, "完整中文原文\nnot the preview")
        manager.close()
    }

    func testCloneWaitsForNewIdentityAndBusyServerRefusalDoesNotAutoForce() async throws {
        let manager = make(); manager.open(.clone)
        try submit(manager); await settle()
        XCTAssertEqual(sent.last?.1["type"] as? String, "clone_session")
        try respond(manager, data: ["busy": true], success: false)
        XCTAssertEqual(sent.count, 1); XCTAssertTrue(manager.panel!.requiresForce)
        try submit(manager); await settle()
        XCTAssertEqual(sent.last?.1["force"] as? Bool, true)
        try respond(manager, data: ["session_id": "old"])
        XCTAssertFalse(manager.panel!.completed); XCTAssertTrue(transitions.isEmpty)
        XCTAssertTrue(manager.panel!.statusLabel.stringValue.contains("身份未确认"))
        manager.close()
    }

    func testRenameValidatesInputAndAdoptsOnlyVerifiedSameSessionName() async throws {
        let manager = make()
        var renamed: [String] = []
        manager.onRenamed = { renamed.append($0) }
        manager.open(.rename)
        manager.rename(String(repeating: "名", count: 161)); await settle()
        XCTAssertTrue(sent.isEmpty)
        manager.rename("  中文名称  "); await settle()
        XCTAssertEqual(sent.last?.1["type"] as? String, "rename_session")
        XCTAssertEqual(sent.last?.1["name"] as? String, "中文名称")
        try respond(manager, data: ["session_id": "other", "sessionName": "wrong"])
        XCTAssertTrue(renamed.isEmpty)
        manager.rename("中文名称"); await settle()
        try respond(manager, data: ["session_id": "old", "sessionName": "中文名称"])
        XCTAssertEqual(renamed, ["中文名称"])
        XCTAssertNil(manager.activeAction)
    }

    func testCompactPreservesCustomInstructionsAndDoesNotTreatBareAdmissionAsCompletion() async throws {
        let manager = make(); manager.open(.compact)
        manager.panel!.loadViewIfNeeded()
        manager.panel!.instructions.string = String(repeating: "中", count: 3000)
        try submit(manager); await settle()
        XCTAssertTrue(sent.isEmpty)
        manager.panel!.instructions.string = "保留接口契约\nkeep tests"
        try submit(manager); await settle()
        XCTAssertEqual(sent.last?.1["type"] as? String, "compact")
        XCTAssertEqual(sent.last?.1["customInstructions"] as? String, "保留接口契约\nkeep tests")
        try respond(manager, data: [:])
        XCTAssertFalse(manager.panel!.completed)
        try submit(manager); await settle()
        try respond(manager, data: ["summary": "Native compacted summary", "tokensBefore": 1200])
        XCTAssertTrue(manager.panel!.completed)
        XCTAssertFalse(manager.panel!.statusLabel.stringValue.contains("%"))
        manager.close()
    }

    func testMalformedDuplicateCatalogFailsAndEmptyCatalogIsSuccessfulEmptyState() async throws {
        let manager = make(); manager.open(.history); await settle()
        try respond(manager, data: ["sessions": [["session_id": "a"], ["session_id": "a"]]])
        XCTAssertTrue(manager.panel!.choices.isEmpty)
        XCTAssertTrue(manager.panel!.statusLabel.stringValue.contains("重复"))
        manager.close(); manager.open(.history); await settle()
        try respond(manager, data: ["sessions": []])
        XCTAssertTrue(manager.panel!.statusLabel.stringValue.contains("暂无"))
        manager.close()
    }

    func testDisconnectInvalidatesPendingMutationWithoutReplayOrLateAdoption() async throws {
        let manager = make(); manager.open(.newSession)
        try submit(manager); await settle()
        let id = try XCTUnwrap(sent.last?.0)
        epoch = ConnectionEpoch(2); manager.invalidate("连接已改变")
        XCTAssertFalse(manager.handle(.init(reference: ref, viewID: nil, sourceEpoch: nil, event: Data()), object: ["type": "response", "id": id, "success": true, "data": ["session_id": "new"]]))
        try submit(manager); await settle()
        XCTAssertEqual(sent.count, 1); XCTAssertTrue(transitions.isEmpty)
        manager.close()
    }

    func testLateExportAfterDisconnectCannotReplaceUserFileAndCleansPrivateArtifact() async throws {
        let manager = make(); manager.open(.export)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("corral-export-" + UUID().uuidString)
        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("corral-export-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: destinationDirectory) }
        let source = directory.appendingPathComponent("session.html"), destination = destinationDirectory.appendingPathComponent("keep.html")
        try Data("<html>late</html>".utf8).write(to: source)
        try Data("existing user file".utf8).write(to: destination)
        var receipt: CheckedContinuation<ConversationExportArtifact, Error>?
        manager.download = { _ in try await withCheckedThrowingContinuation { receipt = $0 } }
        manager.panel!.savePanelPresenter = { _, _, completion in completion(.OK, destination) }
        try submit(manager); await settle()
        XCTAssertTrue(manager.isBusy)
        epoch = ConnectionEpoch(2); manager.invalidate("连接已断开")
        let continuation = try XCTUnwrap(receipt)
        continuation.resume(returning: ConversationExportArtifact(file: source))
        await settle()
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing user file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(manager.isBusy)
        manager.close()
    }

    func testExportCancelAndStaleSavePanelSelectionNeverDownload() async throws {
        let manager = make(); manager.open(.export)
        var downloads = 0
        manager.download = { _ in downloads += 1; throw ConversationExportFailure("not expected") }
        manager.panel!.savePanelPresenter = { panel, _, completion in
            XCTAssertEqual(panel.allowedContentTypes.first, .html)
            completion(.cancel, nil)
        }
        try submit(manager); await settle()
        XCTAssertEqual(downloads, 0); XCTAssertFalse(manager.isBusy)
        manager.panel!.savePanelPresenter = { [unowned self] _, _, completion in
            sid = "changed"
            completion(.OK, URL(fileURLWithPath: "/tmp/not-written-corral.html"))
        }
        try submit(manager); await settle()
        XCTAssertEqual(downloads, 0); XCTAssertFalse(manager.isBusy)
        manager.close()
    }
}
