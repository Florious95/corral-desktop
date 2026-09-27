import AppKit
import CorralContracts
import CorralMetalTerminal

public struct PaneRenderSubmission: Equatable, Sendable {
    public let paneID: UUID
    public let session: SessionKey
    public let viewport: StageViewportRect
    public let snapshot: TerminalGridSnapshot

    public init(paneID: UUID, session: SessionKey, viewport: StageViewportRect, snapshot: TerminalGridSnapshot) {
        self.paneID = paneID
        self.session = session
        self.viewport = viewport
        self.snapshot = snapshot
    }

    var frameSnapshot: PaneFrameSnapshot {
        PaneFrameSnapshot(paneID: paneID, session: session, viewport: viewport, contentGeneration: snapshot.generation, snapshot: snapshot)
    }
}

@MainActor
final class MetalStageView: NSView {
    let renderer: SharedMetalTerminalRenderer
    let stageID: UUID
    private var layoutGeneration = LayoutGeneration(0)
    private var metricsGeneration = MetricsGeneration(0)
    private var terminalFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var lastSize: NSSize?
    private var lastBackingScale: CGFloat?
    private var sleepState = RenderSleepState.active
    var currentGeometry: (NSSize, CGFloat)? {
        guard let lastSize, let lastBackingScale else { return nil }
        return (lastSize, lastBackingScale)
    }
    var terminalCellSize: NSSize {
        NSSize(
            width: max(1, terminalFont.maximumAdvancement.width),
            height: max(1, terminalFont.ascender - terminalFont.descender + terminalFont.leading)
        )
    }
    private var inputViews: [SessionKey: TerminalTextInputView] = [:]
    private var snapshotsBySession: [SessionKey: TerminalGridSnapshot] = [:]
    private var inputRouting: (any TerminalInputRouting)?
    private var presentationGeneration: UInt64 = 0
    private var presentationTask: Task<Void, Never>?

    private(set) var submissions: [PaneRenderSubmission] = []
    private(set) var presentedSubmissions: [PaneRenderSubmission] = []
    private(set) var activeInputSession: SessionKey?
    private(set) var lastFrameReceipt: FrameReceipt?
    var onGeometryChanged: ((NSSize, CGFloat) -> Void)?

    init(renderer: SharedMetalTerminalRenderer, stageID: UUID) {
        self.renderer = renderer
        self.stageID = stageID
        super.init(frame: .zero)
        wantsLayer = true
        layer = renderer.stageLayer
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateStageGeometry()
        layoutInputViews()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateStageGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateStageGeometry()
    }

    func configureStage(sizeInPoints: NSSize, backingScale: CGFloat) {
        guard sizeInPoints.width.isFinite, sizeInPoints.height.isFinite,
              sizeInPoints.width > 0, sizeInPoints.height > 0,
              backingScale.isFinite, backingScale > 0 else { return }
        applyGeometry(size: sizeInPoints, backingScale: backingScale)
    }

    func present(_ submission: PaneRenderSubmission?) {
        setSubmissions(submission.map { [$0] } ?? [])
        guard presentationTask == nil else { return }
        presentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let generation = presentationGeneration
                await draw(submissions, generation: generation)
                if generation == presentationGeneration { break }
            }
            presentationTask = nil
        }
    }

    func submit(_ newSubmissions: [PaneRenderSubmission]) async {
        setSubmissions(newSubmissions)
        await draw(submissions, generation: presentationGeneration)
    }

    private func setSubmissions(_ newSubmissions: [PaneRenderSubmission]) {
        let validSubmissions = newSubmissions.filter { $0.snapshot.isValid && $0.viewport.isValid }
        if submissions != validSubmissions { presentedSubmissions = [] }
        submissions = validSubmissions
        snapshotsBySession = Dictionary(uniqueKeysWithValues: submissions.map { ($0.session, $0.snapshot) })
        presentationGeneration &+= 1
        updateInputViews()
    }

    private func draw(_ submitted: [PaneRenderSubmission], generation: UInt64) async {
        guard sleepState.allowsDrawing else {
            await renderer.setSleepState(sleepState, for: stageID)
            return
        }
        let request = StageFrameRequest(
            stageID: stageID,
            layoutGeneration: layoutGeneration,
            metricsGeneration: metricsGeneration,
            visibility: currentVisibility,
            panes: submitted.map(\.frameSnapshot)
        )
        let receipt = await renderer.render(request)
        guard generation == presentationGeneration else { return }
        lastFrameReceipt = receipt
        guard receipt.outcome == .completed, receipt.visibility == .visible,
              receipt.layoutGeneration == layoutGeneration,
              receipt.metricsGeneration == metricsGeneration else { return }
        let currentByPane = Dictionary(uniqueKeysWithValues: submissions.map { ($0.paneID, $0) })
        presentedSubmissions = submitted.filter { pane in
            guard currentByPane[pane.paneID]?.snapshot.generation == pane.snapshot.generation,
                  currentByPane[pane.paneID]?.viewport == pane.viewport else { return false }
            return receipt.presentedGeneration(
                for: pane.paneID,
                currentStageID: stageID,
                currentLayout: layoutGeneration,
                currentMetrics: metricsGeneration,
                parsedGeneration: pane.snapshot.generation
            ) == pane.snapshot.generation
        }
    }

    func setTerminalFont(family: String, size: Int) {
        let font = Self.resolveFont(family: family, size: size)
        guard font != terminalFont else { return }
        terminalFont = font
        if metricsGeneration.rawValue < UInt64.max {
            metricsGeneration = MetricsGeneration(metricsGeneration.rawValue + 1)
        }
        updateInputViews()
        if let currentGeometry { onGeometryChanged?(currentGeometry.0, currentGeometry.1) }
    }

    func setRenderSleepState(_ state: RenderSleepState) {
        sleepState = state
        Task { @MainActor [weak self] in
            guard let self else { return }
            await renderer.setSleepState(state, for: stageID)
            if state.allowsDrawing { await submit(submissions) }
        }
    }

    func activateInput(for session: SessionKey?, using routing: any TerminalInputRouting) {
        inputRouting = routing
        activeInputSession = session
        for (key, view) in inputViews { view.isHidden = key != session }
        if let session, let view = inputView(for: session) {
            view.isHidden = false
            updateInputView(view, for: session)
            window?.makeFirstResponder(view)
        }
    }

    func inputView(for session: SessionKey) -> TerminalTextInputView? {
        if let view = inputViews[session] { return view }
        guard let inputRouting else { return nil }
        let view = TerminalTextInputView(frame: bounds, sessionKey: session, inputRouting: inputRouting)
        view.isHidden = true
        addSubview(view, positioned: .above, relativeTo: nil)
        inputViews[session] = view
        return view
    }

    private var currentVisibility: StageVisibility {
        if isHidden { return .tabHidden }
        if window?.isMiniaturized == true { return .windowMinimized }
        return .visible
    }

    private func updateStageGeometry() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let size = bounds.size
        guard size.width > 0, size.height > 0, scale > 0,
              size != lastSize || scale != lastBackingScale else { return }
        applyGeometry(size: size, backingScale: scale)
    }

    private func applyGeometry(size: NSSize, backingScale: CGFloat) {
        if size != lastSize, layoutGeneration.rawValue < UInt64.max {
            layoutGeneration = LayoutGeneration(layoutGeneration.rawValue + 1)
        }
        lastSize = size
        lastBackingScale = backingScale
        renderer.configureStage(sizeInPoints: size, backingScale: backingScale)
        onGeometryChanged?(size, backingScale)
        layoutInputViews()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.submit(self.submissions)
        }
    }

    private func layoutInputViews() {
        for (key, view) in inputViews { updateInputView(view, for: key) }
    }

    private func updateInputViews() {
        for (key, view) in inputViews {
            view.isHidden = key != activeInputSession
            updateInputView(view, for: key)
        }
    }

    private static func resolveFont(family: String, size: Int) -> NSFont {
        for item in family.split(separator: ",") {
            let name = item.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !name.isEmpty, name.caseInsensitiveCompare("monospace") != .orderedSame else { continue }
            if let font = NSFont(name: name, size: CGFloat(size)) { return font }
        }
        return NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    private func updateInputView(_ view: TerminalTextInputView, for session: SessionKey) {
        guard let submission = submissions.first(where: { $0.session == session }) else { return }
        let rect = submission.viewport
        view.frame = NSRect(
            x: bounds.minX + rect.x,
            y: bounds.minY + bounds.height - rect.y - rect.height,
            width: rect.width,
            height: rect.height
        )
        let size = submission.snapshot.size
        view.configure(
            grid: size,
            cellSize: NSSize(width: rect.width / CGFloat(size.columns), height: rect.height / CGFloat(size.rows)),
            cursor: submission.snapshot.cursor,
            font: terminalFont
        )
        view.updateTerminalSnapshot(submission.snapshot)
    }
}

// Stage presentation is intentionally a single persistent NSView/CAMetalLayer for the MVP root.
