import AppKit
import CorralContracts
import CorralProtocol
import CorralUI

/// Pi's verified Core adapter. UI action identities and surfaces remain provider-neutral; host paths never enter commands.
@MainActor
final class ConversationActionsController {
    struct Context {
        let epoch: ConnectionEpoch
        let sessionID: String
        let viewID: String
        let ready: Bool
        let running: Bool?
        let queued: Int
        let inputPending: Bool
        let markedText: Bool
        let title: String
        func sameSession(as other: Context) -> Bool { epoch == other.epoch && sessionID == other.sessionID }
    }
    private struct Pending {
        let id, command: String
        let action: CorralActionID
        let origin: Context
        var target: String?
        var draft: String?
        var changesSession: Bool { [.history, .newSession, .fork, .clone].contains(action) && command != "list_sessions" && command != "fork_points" }
        var query: Bool { command == "list_sessions" || command == "fork_points" }
    }
    let reference: SessionReference
    var context: () -> Context
    var send: @MainActor (ClientCommand) async throws -> Void = { _ in }
    var download: @MainActor (String) async throws -> ConversationExportArtifact = { _ in throw ConversationExportFailure("unavailable") }
    var window: () -> NSWindow? = { nil }
    var onStateChange: () -> Void = {}
    var onBeginRename: (String) -> Void = { _ in }
    var onRenameState: (Bool, String?) -> Void = { _, _ in }
    var onEndRename: () -> Void = {}
    var onRenamed: (String) -> Void = { _ in }
    var onTransition: (String, String?) -> Void = { _, _ in }
    var onNeedFreshView: () -> Void = {}
    var onNotice: (String) -> Void = { _ in }
    private(set) var panel: CorralSessionActionPanel?
    private(set) var activeAction: CorralActionID?
    private var opened: Context?
    private var pending: Pending?
    private var timeout: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var exportID: UUID?
    var isBusy: Bool { pending != nil || exportID != nil }
    var expectsSessionReplacement: Bool { pending?.changesSession == true }

    init(reference: SessionReference, context: @escaping () -> Context) { self.reference = reference; self.context = context }

    func open(_ action: CorralActionID) {
        let value = context()
        guard !isBusy, value.ready, !value.inputPending else { return }
        guard !value.markedText else { onNotice("请先完成输入法组字，再执行会话操作"); return }
        close()
        activeAction = action; opened = value
        if action == .rename { onBeginRename(value.title); return }
        let panel = CorralSessionActionPanel(action: action, sessionTitle: value.title)
        panel.onSubmit = { [weak self] selection, instructions in self?.submit(selection: selection, instructions: instructions) }
        panel.onReload = { [weak self] in self?.loadChoices() }
        panel.onClose = { [weak self] in self?.close() }
        self.panel = panel
        if let window = window() { panel.present(over: window) }
        if action == .history || action == .fork { loadChoices() }
    }

    func close() {
        guard pending?.query != false, exportID == nil else { return }
        pending = nil; timeout?.cancel(); timeout = nil
        panel?.closeDialog(); panel = nil
        if activeAction == .rename { onEndRename() }
        activeAction = nil; opened = nil
        onStateChange()
    }

    private func validSubmission() -> Context? {
        let current = context()
        guard let opened, current.sameSession(as: opened), !current.sessionID.isEmpty, current.ready, !current.inputPending else {
            fail("会话或连接已改变，请关闭面板后重新选择"); return nil
        }
        guard !current.markedText else { fail("请先完成输入法组字"); return nil }
        return current
    }

    private func loadChoices() {
        guard !isBusy, let action = activeAction, let current = validSubmission() else { return }
        panel?.setChoices([])
        request(action == .history ? "list_sessions" : "fork_points", fields: [:], action: action, origin: current)
    }

    func rename(_ name: String) {
        guard activeAction == .rename, !isBusy, let current = validSubmission() else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.count <= 160,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            fail("名称须为 1–160 个字符，且不能包含控制字符"); return
        }
        request("rename_session", fields: ["name": value], action: .rename, origin: current)
    }

    private func submit(selection: String?, instructions: String) {
        guard !isBusy, let action = activeAction, let current = validSubmission() else { return }
        if action == .export { export(origin: current); return }
        var fields: [String: Any] = [:]
        let command: String
        switch action {
        case .history:
            guard let selection, panel?.choices.contains(where: { $0.id == selection && !$0.current }) == true else { return }
            fields["sessionId"] = selection; command = "resume_session"
        case .fork:
            guard let selection, panel?.choices.contains(where: { $0.id == selection }) == true else { return }
            fields["pointId"] = selection; command = "fork_session"
        case .newSession: command = "new_session"
        case .clone: command = "clone_session"
        case .compact:
            guard current.running == false, current.queued == 0 else { fail("请先停止当前任务并清空队列，再压缩上下文"); return }
            guard panel?.instructions.hasMarkedText() != true else { fail("请先完成保留重点的输入法组字"); return }
            guard instructions.utf8.count <= 8192 else { fail("保留重点超过 8192 UTF-8 字节，请缩短后重试"); return }
            if !instructions.isEmpty { fields["customInstructions"] = instructions }
            command = "compact"
        default: return
        }
        if [.history, .newSession, .fork, .clone].contains(action) {
            let force = panel?.requiresForce == true
            if (current.running != false || current.queued > 0), !force {
                panel?.setStatus("此操作需要停止当前任务并清空排队输入。确认后才会继续。", requiresForce: true)
                return
            }
            fields["force"] = force
        }
        request(command, fields: fields, action: action, origin: current)
    }

    private func request(_ kind: String, fields: [String: Any], action: CorralActionID, origin: Context) {
        let id = "action-" + UUID().uuidString
        var fields = fields; fields["type"] = kind
        guard let body = try? JSONSerialization.data(withJSONObject: fields) else { fail("无法编码会话操作"); return }
        let command = ClientCommand.conversationCommand(reference: reference, id: id, command: body)
        guard (try? JSONV1Codec().encodeClientCommand(command)) != nil else { fail("操作超过协议传输上限，未提交"); return }
        let request = Pending(id: id, command: kind, action: action, origin: origin)
        pending = request
        panel?.setStatus(request.query ? "正在读取主机原生目录…" : "正在等待原生操作确认…", busy: true, allowsClose: request.query)
        if action == .rename { onRenameState(true, nil) }
        onStateChange()
        Task { @MainActor [weak self] in
            guard let self, self.pending?.id == id, self.context().sameSession(as: origin) else { return }
            do { try await self.send(command) }
            catch { if self.pending?.id == id { self.fail("请求结果未确认，请核对原生会话；不会自动重试") } }
        }
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(request.query ? 45 : 155))
            guard !Task.isCancelled, let self, self.pending?.id == id else { return }
            self.fail("原生操作确认超时，结果未知；请核对会话，勿重复提交")
        }
    }

    /// The API mutation receipt is intentionally outside a retired view. Only its unique ID + connection scope can correlate it.
    func handle(_ event: ConversationEvent, object: [String: Any]) -> Bool {
        guard event.reference == reference, object["type"] as? String == "response", let request = pending,
              object["id"] as? String == request.id else { return false }
        let current = context()
        guard current.epoch == request.origin.epoch else { fail("连接已改变，旧操作结果未采用"); return true }
        if !request.changesSession, !current.sameSession(as: request.origin) { fail("会话已改变，旧操作结果未采用"); return true }
        if request.query, current.viewID != request.origin.viewID { fail("目录视图已过期，请重新打开面板"); return true }
        guard event.viewID == nil || event.viewID == request.origin.viewID else { return true }
        let data = object["data"] as? [String: Any] ?? [:]
        guard object["success"] as? Bool == true, data["cancelled"] as? Bool != true else {
            let busy = data["busy"] as? Bool == true && request.changesSession
            let reason = String((object["error"] as? String ?? "原生操作已取消或未确认").prefix(240))
            clearPending()
            panel?.setStatus(reason, error: true, requiresForce: busy)
            if request.action == .rename { onRenameState(false, reason); onNotice(reason) }
            onStateChange()
            return true
        }
        if request.command == "list_sessions" { acceptHistory(data); return true }
        if request.command == "fork_points" { acceptForkPoints(data, origin: request.origin); return true }
        if request.changesSession {
            guard let target = data["session_id"] as? String, !target.isEmpty,
                  request.action == .history || target != request.origin.sessionID else { fail("原生会话身份未确认，未重置视口"); return true }
            pending?.target = target; pending?.draft = data["draft"] as? String
            panel?.setStatus("原生操作已确认，正在加载目标会话…", busy: true, allowsClose: false)
            update()
            if pending != nil, context().sessionID != target { onNeedFreshView() }
        } else if request.action == .rename {
            guard data["session_id"] as? String == request.origin.sessionID, let name = data["sessionName"] as? String else {
                fail("原生会话名称或身份未确认"); return true
            }
            clearPending(); onRenamed(name); onEndRename(); activeAction = nil; opened = nil; onStateChange()
        } else if request.action == .compact {
            // Pi's compact response contains its completed native result. Admission alone is not completion.
            guard let summary = data["summary"] as? String else { fail("压缩结果未确认，未宣称上下文减少"); return true }
            finish("原生压缩已完成\n" + String(summary.prefix(160)))
        }
        return true
    }

    private func acceptHistory(_ data: [String: Any]) {
        guard let rows = data["sessions"] as? [[String: Any]] else { fail("历史目录响应不完整"); return }
        var ids = Set<String>(), choices: [CorralSessionChoice] = []
        for row in rows {
            guard let id = row["session_id"] as? String, !id.isEmpty, id.utf8.count <= 128, ids.insert(id).inserted else { fail("历史目录身份缺失或重复"); return }
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (row["first_message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let modified = (row["modified_ms"] as? NSNumber)?.doubleValue
            let date = modified.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) : nil } ?? "时间未提供"
            choices.append(.init(id: id, title: name, detail: date + " · " + id, current: row["current"] as? Bool == true))
        }
        clearPending(); panel?.setChoices(choices)
        panel?.setStatus(choices.isEmpty ? "此目录暂无可恢复的原生历史会话" : "选择会话后确认切换；当前会话不会被删除。")
        onStateChange()
    }

    private func acceptForkPoints(_ data: [String: Any], origin: Context) {
        guard data["session_id"] as? String == origin.sessionID, let rows = data["points"] as? [[String: Any]] else { fail("分叉目录或会话身份未确认"); return }
        var ids = Set<String>(), choices: [CorralSessionChoice] = []
        for row in rows {
            guard let id = row["id"] as? String, id.utf8.count == 32, ids.insert(id).inserted,
                  let text = row["text"] as? String else { fail("分叉节点身份缺失或重复"); return }
            choices.append(.init(id: id, title: text.isEmpty ? "用户消息" : text, detail: "在此消息之前分叉 · 原文将恢复到草稿"))
        }
        clearPending(); panel?.setChoices(choices)
        panel?.setStatus(choices.isEmpty ? "当前会话暂无可分叉的用户消息" : "仅列出原生提供的可分叉节点，不使用本地消息索引。")
        onStateChange()
    }

    /// Two-sided commit barrier: a native receipt and the target SID's adopted live history must both exist.
    func update() {
        guard let request = pending, let target = request.target else { return }
        let current = context()
        guard current.epoch == request.origin.epoch else { invalidate("连接已改变，目标会话结果未确认"); return }
        guard current.ready, current.sessionID == target else { return }
        let draft = request.draft
        clearPending()
        onTransition(target, draft)
        finish("已切换到原生会话 \(target)")
    }

    private func export(origin: Context) {
        guard let panel else { return }
        let id = UUID(); exportID = id
        panel.setStatus("请选择本地保存位置；取消不会生成或下载文件。", busy: true, allowsClose: false)
        onStateChange()
        panel.chooseExportDestination { [weak self] destination in
            guard let self, self.exportID == id else { return }
            guard let destination else {
                self.exportID = nil; panel.setStatus("已取消保存，未下载文件。"); self.onStateChange(); return
            }
            guard self.context().sameSession(as: origin), self.context().ready else { self.invalidate("会话已改变，未开始导出"); return }
            panel.setStatus("正在生成并下载官方 HTML…", busy: true, allowsClose: false)
            self.exportTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let artifact = try await self.download(origin.sessionID)
                    defer { artifact.remove() }
                    guard !Task.isCancelled, self.exportID == id else { return }
                    guard self.context().sameSession(as: origin), self.context().ready else {
                        self.invalidate("会话已改变，下载结果已丢弃，未保存文件"); return
                    }
                    try artifact.save(to: destination)
                    self.exportID = nil; self.exportTask = nil
                    self.finish("已保存官方 HTML：\(destination.lastPathComponent)\n文件可能包含敏感内容，请妥善保管。")
                } catch {
                    guard self.exportID == id else { return }
                    self.exportID = nil; self.exportTask = nil
                    self.fail("导出或保存未完成，原目标文件未替换；请核对当前会话后重试")
                }
            }
        }
    }

    func invalidate(_ reason: String) {
        guard activeAction != nil || isBusy else { return }
        exportID = nil; exportTask?.cancel(); exportTask = nil
        panel?.savePanel?.cancel(nil)
        fail(reason)
        opened = nil
        if activeAction == .rename { onEndRename(); activeAction = nil }
    }
    func stop() {
        invalidate("会话已关闭，操作结果未确认")
        panel?.closeDialog(); panel = nil; opened = nil; activeAction = nil
    }
    private func clearPending() { pending = nil; timeout?.cancel(); timeout = nil }
    private func fail(_ reason: String) {
        clearPending()
        panel?.setStatus(reason, error: true)
        if activeAction == .rename { onRenameState(false, reason); onNotice(reason) }
        onStateChange()
    }
    private func finish(_ message: String) {
        clearPending(); panel?.setStatus(message, completed: true)
        onStateChange()
    }
}
