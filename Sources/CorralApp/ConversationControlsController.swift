import AppKit
import CorralContracts
import CorralProtocol
import CorralUI

/// On-demand native catalogs and mutations. Every response belongs to one live view, not a tab title.
@MainActor
final class ConversationControlsController {
    struct Scope: Equatable {
        let epoch: ConnectionEpoch
        let viewID, sourceEpoch, sessionID: String
    }
    private struct Request { let kind: String; let scope: Scope }
    private let reference: SessionReference
    private let scope: () -> Scope?
    var send: @MainActor (ClientCommand) async throws -> Void = { _ in }
    var onChange: () -> Void = {}
    var onSettingsChanged: () -> Void = {}
    var canChangeSettings: () -> Bool = { true }
    private(set) var models: [CorralModelChoice] = []
    private(set) var levels: [String] = []
    private(set) var commands: [CorralCommandChoice] = []
    private(set) var modelStatus = "点击刷新读取原生模型与思考选项"
    private(set) var commandStatus = ""
    private(set) var settingsPending = false
    private var requests: [String: Request] = [:]
    private var catalogErrors: [String: String] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]

    init(reference: SessionReference, scope: @escaping () -> Scope?) {
        self.reference = reference; self.scope = scope
    }

    func loadModels() {
        guard scope() != nil, !settingsPending else { return }
        models = []; levels = []; catalogErrors = [:]; modelStatus = "正在读取原生模型与思考选项…"
        request("get_available_models"); request("get_available_thinking_levels")
    }

    func loadCommands() {
        guard scope() != nil else { commandStatus = "连接就绪后可读取主机命令"; onChange(); return }
        commandStatus = "正在读取主机命令…"
        request("get_commands")
    }

    func chooseModel(_ choice: CorralModelChoice) {
        guard canChangeSettings(), !settingsPending, models.contains(choice) else { return }
        // A delayed levels response belongs to the old model, even if its view/SID is unchanged.
        for id in requests.keys.filter({ requests[$0]?.kind == "get_available_thinking_levels" }) { remove(id) }
        levels = []; catalogErrors.removeValue(forKey: "get_available_thinking_levels")
        settingsPending = true; modelStatus = "正在确认模型切换…"
        request("set_model", fields: ["provider": choice.provider, "modelId": choice.id])
    }

    func chooseLevel(_ level: String) {
        guard canChangeSettings(), !settingsPending, levels.contains(level) else { return }
        settingsPending = true; modelStatus = "正在确认思考强度…"
        request("set_thinking_level", fields: ["level": level])
    }

    private func request(_ kind: String, fields: [String: Any] = [:]) {
        guard let owner = scope() else { settingsPending = false; modelStatus = "当前会话不可操作"; onChange(); return }
        guard !requests.values.contains(where: { $0.kind == kind && $0.scope == owner }) else { onChange(); return }
        let id = "controls-" + UUID().uuidString
        var fields = fields; fields["type"] = kind
        guard let body = try? JSONSerialization.data(withJSONObject: fields) else { return }
        requests[id] = Request(kind: kind, scope: owner)
        onChange()
        Task { @MainActor [weak self] in
            guard let self, self.requests[id]?.scope == self.scope() else { return }
            do { try await self.send(.conversationCommand(reference: self.reference, id: id, command: body)) }
            catch { self.finishFailure(id, "请求未确认；不会自动重发") }
        }
        timeouts[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.finishFailure(id, "请求超时；结果未知，请刷新核对")
        }
    }

    @discardableResult
    func handle(_ event: ConversationEvent, object: [String: Any]) -> Bool {
        guard event.reference == reference, object["type"] as? String == "response", let id = object["id"] as? String,
              let request = requests[id] else { return false }
        guard request.scope == scope(), event.viewID == nil || event.viewID == request.scope.viewID,
              event.sourceEpoch == nil || event.sourceEpoch == request.scope.sourceEpoch else { return true }
        guard object["success"] as? Bool == true else {
            finishFailure(id, String((object["error"] as? String ?? "主机未返回可用结果").prefix(160))); return true
        }
        let data = object["data"] as? [String: Any] ?? [:]
        remove(id); catalogErrors.removeValue(forKey: request.kind)
        switch request.kind {
        case "get_available_models":
            guard let rows = data["models"] as? [[String: Any]], rows.count <= 1024 else { catalogErrors[request.kind] = "模型目录格式不完整"; break }
            var seen = Set<String>()
            models = rows.compactMap { row in
                guard let id = row["id"] as? String, let provider = row["provider"] as? String,
                      Self.validToken(id), Self.validToken(provider), seen.insert(provider + "\u{1F}" + id).inserted else { return nil }
                return CorralModelChoice(id: id, provider: provider, name: String((row["name"] as? String ?? id).prefix(160)))
            }
            modelStatus = models.isEmpty ? "原生未提供可用模型" : "选项来自当前原生会话"
        case "get_available_thinking_levels":
            guard let values = data["levels"] as? [String], values.count <= 32 else { catalogErrors[request.kind] = "思考选项目录格式不完整"; break }
            // Labels may be translated, wire values and availability are never invented.
            var seen = Set<String>()
            levels = values.filter { Self.validToken($0) && seen.insert($0).inserted }
            if levels.isEmpty { modelStatus = "当前模型未提供可调整的思考选项" }
        case "get_commands":
            guard let rows = data["commands"] as? [[String: Any]], rows.count <= 512 else { commandStatus = "主机命令目录格式不完整"; break }
            var seen = Set<String>()
            commands = rows.compactMap { row in
                guard let name = row["name"] as? String, !name.isEmpty, name.utf8.count <= 256,
                      !name.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
                      seen.insert(name).inserted else { return nil }
                return CorralCommandChoice(name: name, detail: String((row["description"] as? String ?? "").prefix(320)), source: row["source"] as? String ?? "extension")
            }
            commandStatus = commands.isEmpty ? "主机未提供扩展命令或模板" : "来自当前主机的命令与模板"
        case "set_model":
            settingsPending = false; levels = []; modelStatus = "模型已确认，正在核对思考选项"
            onSettingsChanged(); requestLevels()
        case "set_thinking_level":
            settingsPending = false; modelStatus = "思考强度已确认"; onSettingsChanged()
        default: break
        }
        showCatalogErrors(); onChange(); return true
    }

    private func showCatalogErrors() {
        if !settingsPending, !catalogErrors.isEmpty { modelStatus = catalogErrors.keys.sorted().compactMap { catalogErrors[$0] }.joined(separator: "；") }
    }
    private func requestLevels() { request("get_available_thinking_levels") }
    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
    private func remove(_ id: String) { requests.removeValue(forKey: id); timeouts.removeValue(forKey: id)?.cancel() }
    private func finishFailure(_ id: String, _ message: String) {
        guard let request = requests[id] else { return }
        remove(id)
        if request.kind == "get_commands" { commandStatus = message }
        else {
            modelStatus = message
            if request.kind.hasPrefix("set_") { settingsPending = false }
            else { catalogErrors[request.kind] = message }
            showCatalogErrors()
        }
        onChange()
    }
    func invalidate() {
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll(); requests.removeAll()
        models = []; levels = []; commands = []; catalogErrors = [:]; settingsPending = false
        modelStatus = "会话已改变，请重新读取选项"; commandStatus = "会话已改变，请重新读取命令"
        onChange()
    }
}

/// Development/production bundle domains remain separate. Tests inject a private defaults suite.
@MainActor
final class ConversationPromptStore {
    private let defaults: UserDefaults
    private let key = "corral.conversation.prompts.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> [CorralPromptTemplate] {
        guard let data = defaults.data(forKey: key), data.count <= 1 << 20,
              let values = try? JSONDecoder().decode([CorralPromptTemplate].self, from: data) else { return [] }
        return Array(values.prefix(100))
    }
    func save(_ values: [CorralPromptTemplate]) -> Bool {
        guard values.count <= 100, values.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.text.isEmpty }),
              let data = try? JSONEncoder().encode(values), data.count <= 1 << 20 else { return false }
        defaults.set(data, forKey: key); return true
    }
}
