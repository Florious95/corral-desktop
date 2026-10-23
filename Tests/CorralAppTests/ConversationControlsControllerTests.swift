import AppKit
import CorralContracts
import CorralUI
import XCTest
@testable import CorralApp

@MainActor
final class ConversationControlsControllerTests: XCTestCase {
    private let ref = try! SessionReference("private\u{1F}%1")
    private var owner: ConversationControlsController.Scope? = .init(epoch: .init(1), viewID: "v", sourceEpoch: "e", sessionID: "sid")
    private var sent: [(String, [String: Any])] = []
    private func make() -> ConversationControlsController {
        let value = ConversationControlsController(reference: ref) { [weak self] in self?.owner }
        value.send = { [weak self] command in
            if case let .conversationCommand(_, id, bytes) = command { self?.sent.append((id, try JSONSerialization.jsonObject(with: bytes) as! [String: Any])) }
        }
        return value
    }
    private func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(30)) }
    private func reply(_ control: ConversationControlsController, _ kind: String, data: [String: Any], success: Bool = true, view: String = "v") throws {
        let id = try XCTUnwrap(sent.last(where: { $0.1["type"] as? String == kind })?.0)
        let object: [String: Any] = ["type": "response", "id": id, "success": success, "data": data, "error": "native rejection"]
        let event = ConversationEvent(reference: ref, viewID: view, sourceEpoch: "e", event: try JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(control.handle(event, object: object))
    }

    func testNativeCatalogsNotInventedLevelsAndCorrelatedSettings() async throws {
        let control = make(); var confirmed = 0; control.onSettingsChanged = { confirmed += 1 }
        control.loadModels(); control.loadModels(); await settle()
        XCTAssertEqual(sent.count, 2, "no duplicate native queries")
        XCTAssertTrue(control.models.isEmpty); XCTAssertTrue(control.levels.isEmpty)
        try reply(control, "get_available_models", data: ["models": [["id": "m1", "provider": "p", "name": "Model One"], ["id": "m2", "provider": "q", "name": "Model Two"]]])
        try reply(control, "get_available_thinking_levels", data: ["levels": ["off", "max"]])
        XCTAssertEqual(control.levels, ["off", "max"])
        control.chooseLevel("high"); await settle(); XCTAssertEqual(sent.count, 2)
        control.chooseModel(.init(id: "unadvertised", provider: "p", name: "invented")); await settle(); XCTAssertEqual(sent.count, 2)
        control.chooseModel(control.models[1]); control.chooseModel(control.models[0]); await settle()
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent.last?.1["modelId"] as? String, "m2"); XCTAssertEqual(sent.last?.1["provider"] as? String, "q")
        XCTAssertTrue(control.settingsPending)
        try reply(control, "set_model", data: ["id": "m2", "provider": "q"])
        await settle(); XCTAssertEqual(confirmed, 1)
        XCTAssertTrue(control.levels.isEmpty, "old model's levels must not remain selectable")
        try reply(control, "get_available_thinking_levels", data: ["levels": ["off"]])
        control.chooseLevel("off"); await settle()
        XCTAssertEqual(sent.last?.1["type"] as? String, "set_thinking_level")
        XCTAssertEqual(sent.last?.1["level"] as? String, "off")
        try reply(control, "set_thinking_level", data: [:]); XCTAssertEqual(confirmed, 2)
        control.invalidate()
    }

    func testFailureForeignViewAndRebindCannotAdoptCatalogOrMutate() async throws {
        let control = make(); control.loadModels(); await settle()
        try reply(control, "get_available_models", data: ["models": [["id": "m", "provider": "p"]]], view: "retired")
        XCTAssertTrue(control.models.isEmpty)
        try reply(control, "get_available_models", data: [:], success: false)
        XCTAssertTrue(control.models.isEmpty); XCTAssertEqual(control.modelStatus, "native rejection")
        let old = try XCTUnwrap(sent.first(where: { $0.1["type"] as? String == "get_available_thinking_levels" }))
        control.invalidate(); owner = .init(epoch: .init(2), viewID: "new", sourceEpoch: "new", sessionID: "other")
        let object: [String: Any] = ["type": "response", "id": old.0, "success": true, "data": ["levels": ["high"]]]
        XCTAssertFalse(control.handle(.init(reference: ref, viewID: "v", sourceEpoch: "e", event: Data()), object: object))
        XCTAssertTrue(control.levels.isEmpty)
        owner = nil; control.loadModels(); await settle(); XCTAssertEqual(sent.count, 2)
    }

    func testOldModelLevelsInFlightCannotPopulateNewModelPicker() async throws {
        let control = make(); control.loadModels(); await settle()
        try reply(control, "get_available_models", data: ["models": [["id": "m", "provider": "p"]]])
        let old = try XCTUnwrap(sent.first(where: { $0.1["type"] as? String == "get_available_thinking_levels" }))
        control.chooseModel(control.models[0]); await settle()
        let stale: [String: Any] = ["type": "response", "id": old.0, "success": true, "data": ["levels": ["max"]]]
        XCTAssertFalse(control.handle(.init(reference: ref, viewID: "v", sourceEpoch: "e", event: Data()), object: stale))
        XCTAssertTrue(control.levels.isEmpty)
        try reply(control, "set_model", data: [:]); await settle()
        XCTAssertEqual(sent.filter { $0.1["type"] as? String == "get_available_thinking_levels" }.count, 2)
        try reply(control, "get_available_thinking_levels", data: ["levels": ["off"]])
        XCTAssertEqual(control.levels, ["off"]); control.invalidate()
    }

    func testOneSuccessfulCatalogCannotHideOtherCatalogFailure() async throws {
        let control = make(); control.loadModels(); await settle()
        try reply(control, "get_available_thinking_levels", data: [:], success: false)
        try reply(control, "get_available_models", data: ["models": [["id": "m", "provider": "p"]]])
        XCTAssertEqual(control.modelStatus, "native rejection"); XCTAssertEqual(control.models.count, 1)
        control.loadModels(); await settle()
        try reply(control, "get_available_thinking_levels", data: ["levels": 42])
        try reply(control, "get_available_models", data: ["models": [["id": "m", "provider": "p"]]])
        XCTAssertEqual(control.modelStatus, "思考选项目录格式不完整"); control.invalidate()
    }

    func testCommandsTemplatesAndNoAutomaticCommandExecution() async throws {
        let control = make(); control.loadCommands(); await settle()
        try reply(control, "get_commands", data: ["commands": [["name": "review", "source": "prompt", "description": "review changes"], ["name": "skill:verify", "source": "skill"], ["name": "bad\ncommand"]]])
        XCTAssertEqual(control.commands.map(\.name), ["review", "skill:verify"])
        XCTAssertEqual(control.commands[0].source, "prompt")
        XCTAssertEqual(sent.count, 1, "catalog reads never execute a prompt")
        control.invalidate()
    }

    func testLocalTemplateCRUDIsSeparateFromUserDefaultsAndBounded() throws {
        let suite = "corral-batch1-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConversationPromptStore(defaults: defaults)
        let original = CorralPromptTemplate(title: "中文模板", text: "检查\r\nUTF-8🙂")
        XCTAssertTrue(store.save([original])); XCTAssertEqual(store.load(), [original])
        var edited = original; edited.text += "\n保持原文"; XCTAssertTrue(store.save([edited])); XCTAssertEqual(store.load()[0].text, edited.text)
        XCTAssertFalse(store.save([.init(title: "", text: "invalid")]))
        XCTAssertEqual(store.load(), [edited], "failure does not destroy the previous library")
        XCTAssertTrue(store.save([])); XCTAssertTrue(store.load().isEmpty)
    }

    func testPickerDisplaysOnlyAdvertisedLevelsAndCanRemainDisabledOffline() {
        let picker = CorralModelPickerController()
        let models = [CorralModelChoice(id: "id", provider: "p", name: "Native Model")]
        picker.apply(models: models, levels: ["off", "max"], currentProvider: "p", currentModel: "id", currentLevel: "max", enabled: true, pending: false, status: "native")
        XCTAssertEqual(picker.modelButton.indexOfSelectedItem, 1)
        XCTAssertEqual(picker.thinkingButton.itemTitles, ["当前：最高", "关", "最高"])
        XCTAssertEqual(picker.thinkingButton.indexOfSelectedItem, 2)
        picker.apply(models: models, levels: ["off"], currentProvider: "p", currentModel: "id", currentLevel: "off", enabled: false, pending: false, status: "offline")
        XCTAssertFalse(picker.modelButton.isEnabled); XCTAssertFalse(picker.thinkingButton.isEnabled)
    }
}
