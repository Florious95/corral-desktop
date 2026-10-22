import AppKit

/// Virtualized transcript. Only rows near the viewport have views; heights are measured with the same TextKit
/// configuration the rows draw with and cached per row revision and width. Reading position is a stable row ID
/// plus pixel offset, so prepending history, expanding a card or a live update never yanks the reader.
@MainActor
public final class CorralConversationTranscriptView: NSView {
    var onLoadOlder: (() -> Void)?
    var onRetryOlder: (() -> Void)?
    var onNeedBodies: (([String]) -> Void)?

    public let scrollView = NSScrollView()
    private let document = TranscriptDocumentView()
    private let topStatus = TranscriptTopStatusView()
    private let jumpButton = TranscriptJumpButton()
    public private(set) var rows: [CorralConversationRow] = []
    private var older: CorralConversationPaneState.Older = .complete
    private var indexByID: [String: Int] = [:]
    private var tops: [CGFloat] = []
    private var heights: [CGFloat] = []
    private var measured: [String: (signature: Int, height: CGFloat)] = [:]
    private var mounted: [String: TranscriptRowView] = [:]
    public private(set) var expanded = Set<String>()
    /// The reader is at the newest row; new content keeps them there.
    public private(set) var followsTail = true
    private var programmaticScroll = 0
    private var themeGeneration = 0
    private var columnWidth: CGFloat = 0
    private var columnX: CGFloat = 0
    private var requestedOlderFor: Int?
    private var lastBodyRequest: [String] = []

    static let rowSpacing: CGFloat = 18
    static let groupedSpacing: CGFloat = 8
    static let topInset: CGFloat = 12
    static let statusHeight: CGFloat = 36
    static let bottomInset: CGFloat = 28
    static let maximumColumn: CGFloat = 780

    var documentResponder: NSView { document }
    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .allowed
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.setAccessibilityIdentifier("corral.conversation.transcript")
        document.owner = self
        document.addSubview(topStatus)
        topStatus.onAction = { [weak self] in
            guard let self else { return }
            if case .failed = self.older { self.onRetryOlder?() } else { self.onLoadOlder?() }
        }
        addSubview(scrollView)
        addSubview(jumpButton)
        jumpButton.isHidden = true
        jumpButton.onClick = { [weak self] in self?.scrollToLatest(animated: true) }
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    public required init?(coder: NSCoder) { fatalError("CorralConversationTranscriptView is created programmatically") }

    // MARK: Data

    func apply(rows newRows: [CorralConversationRow], older newOlder: CorralConversationPaneState.Older) {
        guard newRows != rows || newOlder != older else { return }
        let anchor = followsTail ? nil : currentAnchor()
        let olderChanged = newOlder != older
        rows = newRows
        older = newOlder
        indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        expanded = expanded.filter { indexByID[$0] != nil }
        if olderChanged { requestedOlderFor = nil; topStatus.apply(older) }
        relayout(anchor: anchor)
    }

    func refreshTheme() {
        themeGeneration += 1
        CorralTranscriptRender.clear()
        for view in mounted.values { view.removeFromSuperview() }
        mounted.removeAll()
        topStatus.refreshTheme()
        jumpButton.refreshTheme()
        relayout(anchor: followsTail ? nil : currentAnchor())
    }

    func toggle(_ id: String) {
        guard let index = indexByID[id] else { return }
        let anchor = (id, (visibleTop - tops[index]))
        if expanded.contains(id) { expanded.remove(id) } else {
            expanded.insert(id)
            if rows[index].body == .summary { onNeedBodies?([id]) }
        }
        let keepTail = followsTail && index == rows.count - 1
        relayout(anchor: keepTail ? nil : anchor)
        // Opening a card above the tail is reading, not following: later bodies must not pull the reader down.
        if !keepTail { followsTail = document.frame.height - scrollView.contentView.bounds.maxY < 24 }
        updateJumpButton()
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let anchor = followsTail ? nil : currentAnchor()
        scrollView.frame = bounds
        relayout(anchor: anchor)
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        relayout(anchor: followsTail ? nil : currentAnchor())
    }

    private var visibleTop: CGFloat { scrollView.contentView.bounds.minY }

    private func currentAnchor() -> (String, CGFloat)? {
        let top = visibleTop
        guard !rows.isEmpty, tops.count == rows.count else { return nil }
        let index = firstRow(endingAfter: top)
        guard rows.indices.contains(index) else { return nil }
        return (rows[index].id, top - tops[index])
    }

    private func firstRow(endingAfter y: CGFloat) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if tops[middle] + heights[middle] <= y { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func spacing(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let previous = rows[index - 1].kind
        let current = rows[index].kind
        let compact: (CorralConversationRow.Kind) -> Bool = { $0 == .tool || $0 == .reasoning }
        return compact(previous) && compact(current) ? Self.groupedSpacing : Self.rowSpacing
    }

    private func relayout(anchor: (String, CGFloat)?) {
        let width = scrollView.contentSize.width
        guard width > 0 else { return }
        let side: CGFloat = width < 560 ? 16 : 28
        columnWidth = max(120, min(Self.maximumColumn, width - side * 2))
        columnX = floor((width - columnWidth) / 2)
        var y = Self.topInset
        let statusVisible = !rows.isEmpty && topStatus.isMeaningful
        topStatus.isHidden = !statusVisible
        if statusVisible {
            topStatus.frame = CGRect(x: columnX, y: y, width: columnWidth, height: Self.statusHeight)
            y += Self.statusHeight + 6
        }
        // During a live window resize only rows near the reader are re-measured; the rest keep their
        // previous height until the resize ends, so dragging the window never re-lays out the whole history.
        var exact = 0..<rows.count
        if inLiveResize, tops.count == rows.count, !rows.isEmpty {
            let start = max(0, firstRow(endingAfter: visibleTop) - 12)
            let end = min(rows.count, firstRow(endingAfter: visibleTop + scrollView.contentSize.height) + 12)
            exact = start..<max(start, end)
        }
        tops = []
        heights = []
        tops.reserveCapacity(rows.count)
        heights.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            y += spacing(before: index)
            let height = exact.contains(index) ? height(for: row, width: columnWidth) : (measured[row.id]?.height ?? height(for: row, width: columnWidth))
            tops.append(y)
            heights.append(height)
            y += height
        }
        y += Self.bottomInset
        let contentHeight = max(y, scrollView.contentSize.height)
        programmaticScroll += 1
        if document.frame.size != NSSize(width: width, height: contentHeight) {
            document.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        }
        if let anchor, let index = indexByID[anchor.0] {
            scroll(to: tops[index] + anchor.1)
        } else if followsTail {
            scroll(to: contentHeight - scrollView.contentSize.height)
        } else {
            scroll(to: visibleTop)
        }
        programmaticScroll -= 1
        mountVisibleRows()
        updateJumpButton()
    }

    private func height(for row: CorralConversationRow, width: CGFloat) -> CGFloat {
        let isExpanded = expanded.contains(row.id)
        var hasher = Hasher()
        hasher.combine(row)
        hasher.combine(isExpanded)
        hasher.combine(Int(width.rounded()))
        hasher.combine(themeGeneration)
        let signature = hasher.finalize()
        if let cached = measured[row.id], cached.signature == signature { return cached.height }
        let value = ceil(TranscriptRowView.height(for: row, width: width, expanded: isExpanded))
        measured[row.id] = (signature, value)
        if measured.count > rows.count + 256 { measured = measured.filter { indexByID[$0.key] != nil } }
        return value
    }

    private func scroll(to y: CGFloat) {
        let maximum = max(0, document.frame.height - scrollView.contentSize.height)
        let target = min(max(0, y), maximum)
        guard abs(scrollView.contentView.bounds.minY - target) > 0.25 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func scrollToLatest(animated: Bool) {
        followsTail = true
        programmaticScroll += 1
        scroll(to: document.frame.height - scrollView.contentSize.height)
        programmaticScroll -= 1
        mountVisibleRows()
        updateJumpButton()
    }

    private func mountVisibleRows() {
        guard tops.count == rows.count else { return }
        let visible = scrollView.contentView.bounds
        let overscan: CGFloat = 480
        let start = firstRow(endingAfter: visible.minY - overscan)
        var keep = Set<String>()
        var needBodies: [String] = []
        var index = start
        while index < rows.count, tops[index] < visible.maxY + overscan {
            let row = rows[index]
            keep.insert(row.id)
            let frame = CGRect(x: columnX, y: tops[index], width: columnWidth, height: heights[index])
            let view: TranscriptRowView
            if let existing = mounted[row.id], existing.kindMatches(row) { view = existing }
            else {
                mounted.removeValue(forKey: row.id)?.removeFromSuperview()
                view = TranscriptRowView.make(for: row)
                view.onToggle = { [weak self] id in self?.toggle(id) }
                view.onRetryBody = { [weak self] id in self?.onNeedBodies?([id]) }
                document.addSubview(view)
                mounted[row.id] = view
            }
            view.update(row, width: columnWidth, expanded: expanded.contains(row.id), theme: themeGeneration)
            if view.frame != frame { view.frame = frame }
            let onScreen = tops[index] < visible.maxY && tops[index] + heights[index] > visible.minY
            if onScreen, row.loadsBodyWhenVisible || (expanded.contains(row.id) && row.body == .summary) { needBodies.append(row.id) }
            index += 1
        }
        for (id, view) in mounted where !keep.contains(id) {
            view.removeFromSuperview()
            mounted.removeValue(forKey: id)
        }
        if !needBodies.isEmpty, needBodies != lastBodyRequest { onNeedBodies?(needBodies) }
        lastBodyRequest = needBodies
        if visible.minY < 600, older == .available, requestedOlderFor != rows.count, !rows.isEmpty {
            requestedOlderFor = rows.count
            onLoadOlder?()
        }
    }

    private func updateJumpButton() {
        let distance = document.frame.height - scrollView.contentView.bounds.maxY
        let show = !followsTail && distance > 240 && !rows.isEmpty
        jumpButton.isHidden = !show
        let size = jumpButton.intrinsicContentSize
        jumpButton.frame = CGRect(x: floor((bounds.width - size.width) / 2), y: bounds.height - size.height - 18, width: size.width, height: size.height)
    }

    @objc private func boundsChanged() {
        if programmaticScroll == 0 {
            let distance = document.frame.height - scrollView.contentView.bounds.maxY
            followsTail = distance < 24
        }
        mountVisibleRows()
        updateJumpButton()
    }

    // MARK: Keyboard reading

    fileprivate func scrollByKeyboard(_ amount: CGFloat) {
        let target = visibleTop + amount
        scroll(to: target)
    }

    fileprivate var pageHeight: CGFloat { max(40, scrollView.contentSize.height - 60) }
}

/// Flipped document hosting row views; first responder for keyboard reading (never PTY input).
@MainActor
private final class TranscriptDocumentView: NSView {
    weak var owner: CorralConversationTranscriptView?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        notifyConversationPaneInteraction()
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        guard let owner else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 125: owner.scrollByKeyboard(40)
        case 126: owner.scrollByKeyboard(-40)
        case 121, 49: owner.scrollByKeyboard(event.modifierFlags.contains(.shift) ? -owner.pageHeight : owner.pageHeight)
        case 116: owner.scrollByKeyboard(-owner.pageHeight)
        case 119: owner.scrollToLatest(animated: false)
        case 115: owner.scrollByKeyboard(-.greatestFiniteMagnitude)
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Shared text layout

/// TextKit 1 is used deliberately: Markdown tables are `NSTextTable` blocks, and measuring must match drawing.
@MainActor
enum CorralTextLayout {
    private static let storage = NSTextStorage()
    private static let container: NSTextContainer = {
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        return container
    }()
    private static let manager: NSLayoutManager = {
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        return manager
    }()

    static func size(of string: NSAttributedString, width: CGFloat) -> NSSize {
        guard string.length > 0 else { return .zero }
        _ = manager
        container.containerSize = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(string)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size
        storage.setAttributedString(NSAttributedString())
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }

    static func makeTextView(selectable: Bool = true) -> NSTextView {
        let storage = NSTextStorage()
        let manager = CorralTranscriptLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        manager.addTextContainer(container)
        let view = CorralTranscriptTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = selectable
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = false
        view.isAutomaticLinkDetectionEnabled = false
        view.displaysLinkToolTips = true
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.focusRingType = .none
        return view
    }

    static func set(_ view: NSTextView, text: NSAttributedString, width: CGFloat) {
        view.textContainer?.containerSize = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
    }
}

/// Draws the transcript's custom Markdown decorations: glyph-height rounded inline-code chips (not full
/// line-height boxes), quote bars beside each line fragment and thematic-break hairlines.
@MainActor
final class CorralTranscriptLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.corralInlineCode, in: characters) { value, range, _ in
            guard let color = value as? NSColor, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, lineGlyphs, _ in
                let piece = NSIntersectionRange(lineGlyphs, glyphs)
                guard piece.length > 0 else { return }
                var bounds = self.boundingRect(forGlyphRange: piece, in: container)
                let baseline = fragment.minY + self.location(forGlyphAt: piece.location).y
                bounds.origin.y = baseline - font.ascender - 2
                bounds.size.height = font.ascender - font.descender + 4
                bounds = bounds.offsetBy(dx: origin.x, dy: origin.y)
                color.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
            }
        }
        storage.enumerateAttribute(.corralQuoteDepth, in: characters) { value, range, _ in
            guard let depth = value as? Int, depth > 0 else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let color = (storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor ?? .secondaryLabelColor).withAlphaComponent(0.35)
            color.setFill()
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
                for level in 0..<depth {
                    NSRect(x: origin.x + CGFloat(level) * 16 + 2, y: origin.y + fragment.minY, width: 2.5, height: fragment.height).fill()
                }
            }
        }
        storage.enumerateAttribute(.corralRule, in: characters) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            color.setFill()
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, _, _ in
                NSRect(x: origin.x, y: origin.y + fragment.midY.rounded(.down), width: container.size.width, height: 1).fill()
            }
        }
    }
}

/// Opens only http(s)/mailto links, and only from an explicit click.
@MainActor
final class CorralTranscriptTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        notifyConversationPaneInteraction()
        super.mouseDown(with: event)
    }
    override func clicked(onLink link: Any, at charIndex: Int) {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, CorralMarkdown.safeURL(url.absoluteString) != nil else { return }
        NSWorkspace.shared.open(url)
    }
    override func scrollWheel(with event: NSEvent) { enclosingScrollView?.scrollWheel(with: event) ?? super.scrollWheel(with: event) }
}

/// Rendered Markdown is cached per row revision and theme; streaming re-renders only the changed row.
@MainActor
enum CorralTranscriptRender {
    private static var cache: [String: [CorralMarkdown.Segment]] = [:]
    private static var order: [String] = []

    static func segments(for row: CorralConversationRow, style: CorralMarkdown.Style, variant: String) -> [CorralMarkdown.Segment] {
        let key = "\(variant)\u{1F}\(row.id)\u{1F}\(row.revision)\u{1F}\(row.text.utf8.count)\u{1F}\(row.text.hashValue)"
        if let hit = cache[key] { return hit }
        // Display bound only (the native body is untouched); matches Core's 200000-unit display clip.
        let limit = 200_000
        let source = row.text.utf16.count > limit
            ? String(row.text.utf16.prefix(limit)).map { $0 + "\n\n… 内容过长，此处仅显示前 \(limit) 个字符" } ?? row.text
            : row.text
        let rendered = CorralMarkdown.render(source, style: style)
        cache[key] = rendered
        order.append(key)
        if order.count > 400 { cache.removeValue(forKey: order.removeFirst()) }
        return rendered
    }

    static func clear() { cache.removeAll(); order.removeAll() }
}

// MARK: - Rows

@MainActor
class TranscriptRowView: NSView {
    var onToggle: ((String) -> Void)?
    var onRetryBody: ((String) -> Void)?
    fileprivate(set) var row: CorralConversationRow?
    private var configuredSignature: Int?
    override var isFlipped: Bool { true }

    static func make(for row: CorralConversationRow) -> TranscriptRowView {
        switch row.kind {
        case .user: UserRowView()
        case .assistant: AssistantRowView()
        case .reasoning: ReasoningRowView()
        case .tool: ToolRowView()
        case .notice, .other: NoticeRowView()
        }
    }

    static func height(for row: CorralConversationRow, width: CGFloat, expanded: Bool) -> CGFloat {
        switch row.kind {
        case .user: UserRowView.measure(row, width: width)
        case .assistant: AssistantRowView.measure(row, width: width)
        case .reasoning: ReasoningRowView.measure(row, width: width, expanded: expanded)
        case .tool: ToolRowView.measure(row, width: width, expanded: expanded)
        case .notice, .other: NoticeRowView.measure(row, width: width)
        }
    }

    func kindMatches(_ row: CorralConversationRow) -> Bool { self.row?.kind == row.kind }

    func update(_ row: CorralConversationRow, width: CGFloat, expanded: Bool, theme: Int) {
        var hasher = Hasher()
        hasher.combine(row)
        hasher.combine(Int(width.rounded()))
        hasher.combine(expanded)
        hasher.combine(theme)
        let signature = hasher.finalize()
        self.row = row
        guard signature != configuredSignature else { return }
        configuredSignature = signature
        configure(row, width: width, expanded: expanded)
        setAccessibilityIdentifier("corral.conversation.item")
    }

    func configure(_ row: CorralConversationRow, width: CGFloat, expanded: Bool) {}

    /// Status line under partial text: summary only, loading, or a local retry.
    static func bodyStatus(for row: CorralConversationRow) -> String? {
        switch row.body {
        case .complete: nil
        case .summary: "仅显示摘要 · 正在准备全文"
        case .loading: "正在载入全文…"
        case let .failed(code): "全文载入失败（\(CorralConversationStateOverlay.describe(code))）· 点按重试"
        }
    }

    static let bodyStatusHeight: CGFloat = 22
    static let suffixNoticeHeight: CGFloat = 20

    /// Measured single-line width; `intrinsicContentSize` of a truncating label is not reliable for layout.
    static func width(of label: NSTextField) -> CGFloat {
        guard let font = label.font else { return ceil(label.attributedStringValue.size().width) + 6 }
        return ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + 6
    }

    static func makeLabel(size: CGFloat = 11.5, weight: NSFont.Weight = .regular, mono: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        return label
    }
}

/// Small clickable status/caption line ("正在载入全文…", "点按重试").
@MainActor
final class TranscriptCaption: NSTextField {
    var onClick: (() -> Void)?
    convenience init() {
        self.init(labelWithString: "")
        font = .systemFont(ofSize: 11.5)
        lineBreakMode = .byTruncatingTail
    }
    override func mouseDown(with event: NSEvent) {
        notifyConversationPaneInteraction()
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onClick != nil }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
}

extension NSView {
    /// Any click inside a structured pane focuses that pane, exactly like a click into a terminal pane.
    /// Gesture recognizers are deliberately not used: they would swallow the row controls' mouse events.
    func notifyConversationPaneInteraction() {
        var view: NSView? = self
        while let current = view {
            if let pane = current as? CorralConversationPaneView { pane.onFocus?(); return }
            view = current.superview
        }
    }
}

/// Top-left origin container so row layout code reads the same in every nested view.
@MainActor
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: User

@MainActor
final class UserRowView: TranscriptRowView {
    private let bubble = FlippedView()
    private let text = CorralTextLayout.makeTextView()
    private let attachments = TranscriptRowView.makeLabel(size: 11.5, weight: .medium)
    private let caption = TranscriptCaption()
    private let suffix = TranscriptRowView.makeLabel(size: 11)
    static let padding = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 14
        bubble.layer?.cornerCurve = .continuous
        addSubview(bubble)
        bubble.addSubview(text)
        bubble.addSubview(attachments)
        addSubview(caption)
        addSubview(suffix)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    static func attributed(_ row: CorralConversationRow) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.3
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: row.text.isEmpty ? " " : row.text,
                                  attributes: [.font: CorralConversationStyle.bodyFont, .foregroundColor: CorralAestheticTokens.text, .paragraphStyle: paragraph])
    }

    static func maximumBubble(_ width: CGFloat) -> CGFloat { max(160, min(width * 0.82, 640)) }

    static func layout(_ row: CorralConversationRow, width: CGFloat) -> (bubble: CGSize, text: CGSize, extra: CGFloat) {
        let inner = maximumBubble(width) - padding.left - padding.right
        let size = CorralTextLayout.size(of: attributed(row), width: inner)
        let attachmentHeight: CGFloat = row.imageCount > 0 ? 20 : 0
        let attachmentWidth: CGFloat = row.imageCount > 0 ? 96 : 0
        let bubbleWidth = min(maximumBubble(width), max(size.width, attachmentWidth) + padding.left + padding.right)
        let bubbleHeight = size.height + attachmentHeight + padding.top + padding.bottom
        let extra = (bodyStatus(for: row) == nil ? 0 : bodyStatusHeight) + (row.observedSuffix ? suffixNoticeHeight : 0)
        return (CGSize(width: ceil(bubbleWidth), height: ceil(bubbleHeight)), size, extra)
    }

    static func measure(_ row: CorralConversationRow, width: CGFloat) -> CGFloat {
        let metrics = layout(row, width: width)
        return metrics.bubble.height + metrics.extra
    }

    override func configure(_ row: CorralConversationRow, width: CGFloat, expanded: Bool) {
        let metrics = Self.layout(row, width: width)
        var y: CGFloat = 0
        suffix.isHidden = !row.observedSuffix
        if row.observedSuffix {
            suffix.stringValue = "… 接入前的内容未显示"
            suffix.alignment = .right
            suffix.textColor = CorralAestheticTokens.textMuted
            suffix.frame = CGRect(x: 0, y: 2, width: width, height: 15)
            y += Self.suffixNoticeHeight
        }
        bubble.layer?.backgroundColor = CorralConversationStyle.userBubble.cgColor
        bubble.frame = CGRect(x: width - metrics.bubble.width, y: y, width: metrics.bubble.width, height: metrics.bubble.height)
        let textWidth = metrics.bubble.width - Self.padding.left - Self.padding.right
        CorralTextLayout.set(text, text: Self.attributed(row), width: textWidth)
        text.frame = CGRect(x: Self.padding.left, y: Self.padding.top, width: textWidth, height: metrics.text.height)
        attachments.isHidden = row.imageCount == 0
        if row.imageCount > 0 {
            attachments.stringValue = "▣ \(row.imageCount) 张图片"
            attachments.textColor = CorralAestheticTokens.textSecondary
            attachments.frame = CGRect(x: Self.padding.left, y: Self.padding.top + metrics.text.height + 3, width: textWidth, height: 15)
        }
        let status = Self.bodyStatus(for: row)
        caption.isHidden = status == nil
        caption.stringValue = status ?? ""
        caption.alignment = .right
        caption.textColor = CorralAestheticTokens.textMuted
        caption.onClick = { if case .failed = row.body { self.onRetryBody?(row.id) } }
        caption.frame = CGRect(x: 0, y: bubble.frame.maxY + 4, width: width, height: 15)
        setAccessibilityLabel("你：\(row.text)")
    }
}

// MARK: Assistant

@MainActor
final class AssistantRowView: TranscriptRowView {
    private var blocks: [NSView] = []
    private let caption = TranscriptCaption()
    private let suffix = TranscriptRowView.makeLabel(size: 11)
    private let typing = TranscriptTypingIndicator()
    static let segmentSpacing: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(caption)
        addSubview(suffix)
        addSubview(typing)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    static func segments(_ row: CorralConversationRow) -> [CorralMarkdown.Segment] {
        CorralTranscriptRender.segments(for: row, style: CorralConversationStyle.markdown, variant: "assistant")
    }

    static func measure(_ row: CorralConversationRow, width: CGFloat) -> CGFloat {
        var height: CGFloat = row.observedSuffix ? suffixNoticeHeight : 0
        let parts = segments(row)
        for (index, segment) in parts.enumerated() {
            if index > 0 { height += segmentSpacing }
            switch segment {
            case let .text(string): height += CorralTextLayout.size(of: string, width: width).height
            case let .code(language, code): height += CodeBlockView.measure(language: language, code: code)
            }
        }
        if bodyStatus(for: row) != nil { height += bodyStatusHeight }
        if row.streaming { height += 22 }
        return max(height, 18)
    }

    override func configure(_ row: CorralConversationRow, width: CGFloat, expanded: Bool) {
        let parts = Self.segments(row)
        // Reuse block views in order; only kinds that changed are rebuilt.
        var reused: [NSView] = []
        var y: CGFloat = 0
        suffix.isHidden = !row.observedSuffix
        if row.observedSuffix {
            suffix.stringValue = "… 接入前的内容未显示"
            suffix.textColor = CorralAestheticTokens.textMuted
            suffix.frame = CGRect(x: 0, y: 2, width: width, height: 15)
            y += Self.suffixNoticeHeight
        }
        for (index, segment) in parts.enumerated() {
            if index > 0 { y += Self.segmentSpacing }
            let existing = index < blocks.count ? blocks[index] : nil
            switch segment {
            case let .text(string):
                let view = (existing as? NSTextView) ?? CorralTextLayout.makeTextView()
                if view !== existing { existing?.removeFromSuperview(); addSubview(view) }
                CorralTextLayout.set(view, text: string, width: width)
                let height = CorralTextLayout.size(of: string, width: width).height
                view.frame = CGRect(x: 0, y: y, width: width, height: height)
                y += height
                reused.append(view)
            case let .code(language, code):
                let view = (existing as? CodeBlockView) ?? CodeBlockView()
                if view !== existing { existing?.removeFromSuperview(); addSubview(view) }
                view.apply(language: language, code: code)
                let height = CodeBlockView.measure(language: language, code: code)
                view.frame = CGRect(x: 0, y: y, width: width, height: height)
                y += height
                reused.append(view)
            }
        }
        for view in blocks.dropFirst(parts.count) { view.removeFromSuperview() }
        blocks = reused
        let status = Self.bodyStatus(for: row)
        caption.isHidden = status == nil
        caption.stringValue = status ?? ""
        caption.textColor = CorralAestheticTokens.textMuted
        caption.onClick = { if case .failed = row.body { self.onRetryBody?(row.id) } }
        if status != nil {
            caption.frame = CGRect(x: 0, y: y + 5, width: width, height: 15)
            y += Self.bodyStatusHeight
        }
        typing.isHidden = !row.streaming
        typing.frame = CGRect(x: 0, y: y + 8, width: 36, height: 10)
        typing.setAnimating(row.streaming)
        setAccessibilityLabel("Pi：\(row.text)")
    }
}

/// Three soft dots for a streaming reply; animates only while a live item is actually streaming.
@MainActor
final class TranscriptTypingIndicator: NSView {
    private var dots: [CALayer] = []
    private var animating = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for index in 0..<3 {
            let dot = CALayer()
            dot.frame = CGRect(x: CGFloat(index) * 10, y: 2, width: 6, height: 6)
            dot.cornerRadius = 3
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        setAccessibilityElement(true)
        setAccessibilityLabel("正在生成")
    }
    required init?(coder: NSCoder) { fatalError() }
    func setAnimating(_ value: Bool) {
        for dot in dots { dot.backgroundColor = CorralAestheticTokens.textMuted.cgColor }
        guard value != animating else { return }
        animating = value
        for (index, dot) in dots.enumerated() {
            dot.removeAllAnimations()
            guard value else { continue }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.2
            pulse.isRemovedOnCompletion = false
            dot.add(pulse, forKey: "typing")
        }
    }
}

// MARK: Code

/// Fenced code: language caption, copy action and a horizontally scrolling body that never widens the pane.
@MainActor
final class CodeBlockView: NSView {
    static let headerHeight: CGFloat = 28
    static let verticalPadding: CGFloat = 10
    static let horizontalPadding: CGFloat = 14
    static var font: NSFont { CorralMarkdown.monospacedFont(size: 12.5) }
    private let header = NSView()
    private let languageLabel = TranscriptRowView.makeLabel(size: 11, weight: .medium, mono: true)
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let scroll = HorizontalCodeScrollView()
    private let text = CorralTextLayout.makeTextView()
    private var code = ""
    private var language = ""

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        header.wantsLayer = true
        copyButton.isBordered = false
        copyButton.image = CorralLegacyIcon.image(.copy, size: 12)
        copyButton.imagePosition = .imageLeading
        copyButton.font = .systemFont(ofSize: 11)
        copyButton.target = self
        copyButton.action = #selector(copyCode)
        copyButton.setAccessibilityLabel("复制代码")
        copyButton.setAccessibilityIdentifier("corral.conversation.code.copy")
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        text.isHorizontallyResizable = true
        scroll.documentView = text
        addSubview(header)
        header.addSubview(languageLabel)
        header.addSubview(copyButton)
        addSubview(scroll)
        setAccessibilityIdentifier("corral.conversation.code")
    }
    required init?(coder: NSCoder) { fatalError() }

    static func attributed(language: String, code: String) -> NSAttributedString {
        let highlighted = NSMutableAttributedString(attributedString: CorralCodeHighlighter.highlight(code.isEmpty ? " " : code, language: language,
                                                                                                    font: font, palette: CorralConversationStyle.codePalette))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.22
        paragraph.lineBreakMode = .byClipping
        highlighted.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: highlighted.length))
        return highlighted
    }

    static func measure(language: String, code: String) -> CGFloat {
        let size = CorralTextLayout.size(of: attributed(language: language, code: code), width: 100_000)
        return headerHeight + verticalPadding * 2 + size.height
    }

    func apply(language: String, code: String) {
        self.code = code
        self.language = language
        languageLabel.stringValue = language.isEmpty ? "code" : language
        let attributed = Self.attributed(language: language, code: code)
        let size = CorralTextLayout.size(of: attributed, width: 100_000)
        CorralTextLayout.set(text, text: attributed, width: 100_000)
        text.frame = CGRect(x: 0, y: 0, width: size.width + Self.horizontalPadding * 2, height: size.height)
        text.textContainerInset = NSSize(width: Self.horizontalPadding, height: 0)
        text.frame.size.width = size.width + Self.horizontalPadding * 2
        refreshTheme()
        needsLayout = true
    }

    func refreshTheme() {
        layer?.backgroundColor = CorralConversationStyle.codeBackground.cgColor
        layer?.borderColor = CorralConversationStyle.cardBorder.cgColor
        header.layer?.backgroundColor = CorralConversationStyle.codeHeader.cgColor
        languageLabel.textColor = CorralAestheticTokens.textMuted
        copyButton.contentTintColor = CorralAestheticTokens.textMuted
        copyButton.attributedTitle = NSAttributedString(string: " 复制", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: CorralAestheticTokens.textMuted])
    }

    override func layout() {
        super.layout()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        languageLabel.frame = CGRect(x: Self.horizontalPadding, y: 7, width: max(0, bounds.width - 110), height: 14)
        copyButton.frame = CGRect(x: bounds.width - 66, y: 4, width: 58, height: 20)
        let bodyHeight = bounds.height - Self.headerHeight - Self.verticalPadding * 2
        scroll.frame = CGRect(x: 0, y: Self.headerHeight + Self.verticalPadding, width: bounds.width, height: max(0, bodyHeight + Self.verticalPadding))
        text.frame.size.height = max(bodyHeight, text.frame.height)
        text.frame.size.width = max(text.frame.width, bounds.width)
    }

    @objc private func copyCode() {
        // Copy is an explicit user action on the general pasteboard, like any native Copy command.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copyButton.attributedTitle = NSAttributedString(string: " 已复制", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: CorralAestheticTokens.success])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.refreshTheme() }
    }
}

/// Horizontal-only scroller: vertical wheel movement continues to the transcript.
@MainActor
final class HorizontalCodeScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) { nextResponder?.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
}

// MARK: Reasoning

@MainActor
final class ReasoningRowView: TranscriptRowView {
    static let headerHeight: CGFloat = 26
    static let indent: CGFloat = 14
    private let disclosure = DisclosureHeaderView()
    private let rule = NSView()
    private let text = CorralTextLayout.makeTextView()
    private let caption = TranscriptCaption()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rule.wantsLayer = true
        addSubview(disclosure)
        addSubview(rule)
        addSubview(text)
        addSubview(caption)
        disclosure.onClick = { [weak self] in if let id = self?.row?.id, self?.row?.redacted == false { self?.onToggle?(id) } }
    }
    required init?(coder: NSCoder) { fatalError() }

    static func body(_ row: CorralConversationRow) -> NSAttributedString {
        let segments = CorralTranscriptRender.segments(for: row, style: CorralConversationStyle.reasoningMarkdown, variant: "reasoning")
        let output = NSMutableAttributedString()
        for segment in segments {
            if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
            switch segment {
            case let .text(string): output.append(string)
            case let .code(_, code):
                output.append(NSAttributedString(string: code, attributes: [.font: CorralMarkdown.monospacedFont(size: 12),
                                                                             .foregroundColor: CorralAestheticTokens.textSecondary]))
            }
        }
        return output
    }

    static func measure(_ row: CorralConversationRow, width: CGFloat, expanded: Bool) -> CGFloat {
        guard expanded, !row.redacted else { return headerHeight }
        var height = headerHeight + 6 + CorralTextLayout.size(of: body(row), width: width - indent).height
        if bodyStatus(for: row) != nil { height += bodyStatusHeight }
        return height + 4
    }

    override func configure(_ row: CorralConversationRow, width: CGFloat, expanded: Bool) {
        let preview = row.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = row.redacted ? "思考过程（提供方未公开）" : row.streaming ? "思考中…" : "思考过程"
        disclosure.apply(icon: .sparkles, title: title, detail: expanded || row.redacted ? "" : preview, expanded: expanded, expandable: !row.redacted)
        disclosure.frame = CGRect(x: 0, y: 0, width: width, height: Self.headerHeight)
        let showsBody = expanded && !row.redacted
        rule.isHidden = !showsBody
        text.isHidden = !showsBody
        caption.isHidden = true
        guard showsBody else { setAccessibilityLabel(title); return }
        let body = Self.body(row)
        let height = CorralTextLayout.size(of: body, width: width - Self.indent).height
        rule.layer?.backgroundColor = CorralConversationStyle.rule.cgColor
        rule.frame = CGRect(x: 5, y: Self.headerHeight + 4, width: 1.5, height: height + 4)
        CorralTextLayout.set(text, text: body, width: width - Self.indent)
        text.frame = CGRect(x: Self.indent, y: Self.headerHeight + 6, width: width - Self.indent, height: height)
        if let status = Self.bodyStatus(for: row) {
            caption.isHidden = false
            caption.stringValue = status
            caption.textColor = CorralAestheticTokens.textMuted
            caption.onClick = { if case .failed = row.body { self.onRetryBody?(row.id) } }
            caption.frame = CGRect(x: Self.indent, y: text.frame.maxY + 5, width: width - Self.indent, height: 15)
        }
        setAccessibilityLabel("思考过程：\(row.text)")
    }
}

/// Chevron + icon + title + muted one-line detail; the whole line toggles.
@MainActor
final class DisclosureHeaderView: NSView {
    var onClick: (() -> Void)?
    private let chevron = NSImageView()
    private let icon = NSImageView()
    private let title = TranscriptRowView.makeLabel(size: 12.5, weight: .medium)
    private let detail = TranscriptRowView.makeLabel(size: 12.5)
    private var expandable = true
    private var hovering = false
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        for view in [chevron, icon, title, detail] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityIdentifier("corral.conversation.disclosure")
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(icon name: CorralLegacyIcon, title text: String, detail detailText: String, expanded: Bool, expandable: Bool) {
        self.expandable = expandable
        chevron.image = CorralLegacyIcon.image(expanded ? .chevronDown : .chevronRight, size: 10)
        chevron.contentTintColor = CorralAestheticTokens.textMuted
        chevron.isHidden = !expandable
        icon.image = CorralLegacyIcon.image(name, size: 13)
        icon.contentTintColor = CorralAestheticTokens.textMuted
        title.stringValue = text
        title.textColor = CorralAestheticTokens.textSecondary
        detail.stringValue = detailText
        detail.textColor = CorralAestheticTokens.textMuted
        setAccessibilityLabel(text)
        setAccessibilityValue(expanded ? 1 : 0)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        chevron.frame = CGRect(x: 0, y: midY - 5, width: 10, height: 10)
        icon.frame = CGRect(x: 15, y: midY - 6.5, width: 13, height: 13)
        let titleWidth = TranscriptRowView.width(of: title)
        title.frame = CGRect(x: 34, y: midY - 8, width: min(titleWidth, bounds.width - 34), height: 16)
        let detailX = title.frame.maxX + 8
        detail.frame = CGRect(x: detailX, y: midY - 8, width: max(0, bounds.width - detailX - 4), height: 16)
    }

    override func mouseDown(with event: NSEvent) { notifyConversationPaneInteraction(); if expandable { onClick?() } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// One atomic control: labels inside must not swallow the click.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) && !isHidden ? self : nil }
    override func accessibilityPerformPress() -> Bool { if expandable { onClick?() }; return expandable }
    override func resetCursorRects() { if expandable { addCursorRect(bounds, cursor: .pointingHand) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; layer?.backgroundColor = expandable ? CorralAestheticTokens.hoverSubtle.cgColor : nil }
    override func mouseExited(with event: NSEvent) { hovering = false; layer?.backgroundColor = nil }
}

// MARK: Tool

@MainActor
final class ToolRowView: TranscriptRowView {
    static let headerHeight: CGFloat = 36
    static let sectionPadding: CGFloat = 12
    private let card = FlippedView()
    private let headerButton = ToolHeaderView()
    private let divider = NSView()
    private let argumentsTitle = TranscriptRowView.makeLabel(size: 10.5, weight: .semibold)
    private let argumentsText = CorralTextLayout.makeTextView()
    private let outputTitle = TranscriptRowView.makeLabel(size: 10.5, weight: .semibold)
    private let outputText = CorralTextLayout.makeTextView()
    private let caption = TranscriptCaption()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 0.5
        divider.wantsLayer = true
        addSubview(card)
        for view in [headerButton, divider, argumentsTitle, argumentsText, outputTitle, outputText, caption] { card.addSubview(view) }
        headerButton.onClick = { [weak self] in if let id = self?.row?.id { self?.onToggle?(id) } }
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    static func monoBlock(_ text: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.2
        paragraph.lineBreakMode = .byCharWrapping
        return NSAttributedString(string: text.isEmpty ? "（空）" : text, attributes: [.font: CorralMarkdown.monospacedFont(size: 12), .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// Pretty JSON for display only; the original bytes are never rewritten or re-sent.
    static func prettyArguments(_ raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return raw }
        if let string = object as? String { return string }
        guard JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return raw }
        return String(decoding: pretty, as: UTF8.self)
    }

    /// The most informative short argument, e.g. a path or command, as a header preview.
    static func argumentPreview(_ raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["command", "path", "file_path", "filePath", "pattern", "query", "url", "cmd"] {
            if let value = object[key] as? String, !value.isEmpty { return value.replacingOccurrences(of: "\n", with: " ") }
        }
        return object.keys.sorted().first.flatMap { key in (object[key] as? String).map { "\(key): \($0)" } }
    }

    static let maximumOutputLines = 600
    static let maximumOutputBytes = 96 << 10

    /// Very large outputs are shown as a bounded head with an explicit count, never silently cut.
    static func boundedOutput(_ text: String) -> String {
        var lines = 0
        var end = text.startIndex
        var bytes = 0
        for index in text.indices {
            if text[index] == "\n" { lines += 1; if lines >= maximumOutputLines { break } }
            bytes += text[index].utf8.count
            if bytes > maximumOutputBytes { break }
            end = text.index(after: index)
        }
        guard end < text.endIndex else { return text }
        let total = text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
        return String(text[..<end]) + "\n… 输出过长，此处显示前 \(lines) 行（共 \(total) 行）"
    }

    private static func sections(_ row: CorralConversationRow) -> (arguments: String?, output: String) {
        if let output = row.toolOutput { return (prettyArguments(row.toolArguments), boundedOutput(output)) }
        return (nil, row.text)
    }

    static func measure(_ row: CorralConversationRow, width: CGFloat, expanded: Bool) -> CGFloat {
        guard expanded else { return headerHeight }
        let inner = width - sectionPadding * 2
        let content = sections(row)
        var height = headerHeight + 1 + sectionPadding
        if let arguments = content.arguments {
            height += 16 + CorralTextLayout.size(of: monoBlock(arguments, color: CorralAestheticTokens.text), width: inner).height + 12
        }
        height += 16 + CorralTextLayout.size(of: monoBlock(content.output, color: CorralAestheticTokens.text), width: inner).height
        if bodyStatus(for: row) != nil { height += bodyStatusHeight }
        return height + sectionPadding
    }

    override func configure(_ row: CorralConversationRow, width: CGFloat, expanded: Bool) {
        let height = Self.measure(row, width: width, expanded: expanded)
        card.frame = CGRect(x: 0, y: 0, width: width, height: height)
        card.layer?.backgroundColor = CorralConversationStyle.cardBackground.cgColor
        card.layer?.borderColor = CorralConversationStyle.cardBorder.cgColor
        let preview = Self.argumentPreview(row.toolArguments) ?? row.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        headerButton.apply(name: row.toolName ?? "tool", preview: preview, phase: row.toolPhase, expanded: expanded)
        headerButton.frame = CGRect(x: 0, y: 0, width: width, height: Self.headerHeight)
        let showsBody = expanded
        for view in [divider, argumentsTitle, argumentsText, outputTitle, outputText] as [NSView] { view.isHidden = !showsBody }
        caption.isHidden = true
        guard showsBody else { setAccessibilityLabel("工具 \(row.toolName ?? "")，\(ToolHeaderView.phaseText(row.toolPhase))"); return }
        divider.layer?.backgroundColor = CorralConversationStyle.cardBorder.cgColor
        divider.frame = CGRect(x: 0, y: Self.headerHeight, width: width, height: 0.5)
        let inner = width - Self.sectionPadding * 2
        var y = Self.headerHeight + 1 + Self.sectionPadding
        let content = Self.sections(row)
        argumentsTitle.isHidden = content.arguments == nil
        argumentsText.isHidden = content.arguments == nil
        if let arguments = content.arguments {
            argumentsTitle.stringValue = "参数"
            argumentsTitle.textColor = CorralAestheticTokens.textMuted
            argumentsTitle.frame = CGRect(x: Self.sectionPadding, y: y, width: inner, height: 13)
            y += 16
            let block = Self.monoBlock(arguments, color: CorralAestheticTokens.text)
            let size = CorralTextLayout.size(of: block, width: inner)
            CorralTextLayout.set(argumentsText, text: block, width: inner)
            argumentsText.frame = CGRect(x: Self.sectionPadding, y: y, width: inner, height: size.height)
            y += size.height + 12
        }
        outputTitle.stringValue = row.toolOutput == nil && row.body != .complete ? "结果摘要" : "输出"
        outputTitle.textColor = CorralAestheticTokens.textMuted
        outputTitle.frame = CGRect(x: Self.sectionPadding, y: y, width: inner, height: 13)
        y += 16
        let output = Self.monoBlock(content.output, color: row.toolPhase == "failed" ? CorralAestheticTokens.danger : CorralAestheticTokens.text)
        let outputSize = CorralTextLayout.size(of: output, width: inner)
        CorralTextLayout.set(outputText, text: output, width: inner)
        outputText.frame = CGRect(x: Self.sectionPadding, y: y, width: inner, height: outputSize.height)
        y += outputSize.height
        if let status = Self.bodyStatus(for: row) {
            caption.isHidden = false
            caption.stringValue = status == "仅显示摘要 · 正在准备全文" ? "正在载入参数与完整输出…" : status
            caption.textColor = CorralAestheticTokens.textMuted
            caption.onClick = { if case .failed = row.body { self.onRetryBody?(row.id) } }
            caption.frame = CGRect(x: Self.sectionPadding, y: y + 5, width: inner, height: 15)
        }
        setAccessibilityLabel("工具 \(row.toolName ?? "")，\(ToolHeaderView.phaseText(row.toolPhase))")
    }
}

/// Tool card header: phase glyph, tool name, argument/result preview, phase text and chevron.
@MainActor
final class ToolHeaderView: NSView {
    var onClick: (() -> Void)?
    private let glyph = NSImageView()
    private let spinner = NSProgressIndicator()
    private let name = TranscriptRowView.makeLabel(size: 12.5, weight: .semibold, mono: true)
    private let preview = TranscriptRowView.makeLabel(size: 12, mono: true)
    private let phaseLabel = TranscriptRowView.makeLabel(size: 11.5, weight: .medium)
    private let chevron = NSImageView()
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [glyph, spinner, name, preview, phaseLabel, chevron] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityIdentifier("corral.conversation.tool")
    }
    required init?(coder: NSCoder) { fatalError() }

    static func phaseText(_ phase: String?) -> String {
        switch phase {
        case "pending": "等待结果"
        case "running": "运行中"
        case "succeeded": "完成"
        case "failed": "失败"
        case let other?: other
        case nil: "状态未知"
        }
    }

    func apply(name tool: String, preview text: String, phase: String?, expanded: Bool) {
        name.stringValue = tool
        name.textColor = CorralAestheticTokens.text
        preview.stringValue = text
        preview.textColor = CorralAestheticTokens.textMuted
        phaseLabel.stringValue = Self.phaseText(phase)
        chevron.image = CorralLegacyIcon.image(expanded ? .chevronDown : .chevronRight, size: 10)
        chevron.contentTintColor = CorralAestheticTokens.textMuted
        // Only a live running tool animates; historical pending stays still.
        if phase == "running" { spinner.startAnimation(nil); glyph.isHidden = true } else { spinner.stopAnimation(nil); glyph.isHidden = false }
        switch phase {
        case "succeeded":
            glyph.image = CorralLegacyIcon.image(.check, size: 13); glyph.contentTintColor = CorralAestheticTokens.success
            phaseLabel.textColor = CorralAestheticTokens.textMuted
        case "failed":
            glyph.image = CorralLegacyIcon.image(.close, size: 13); glyph.contentTintColor = CorralAestheticTokens.danger
            phaseLabel.textColor = CorralAestheticTokens.danger
        case "pending":
            glyph.image = CorralLegacyIcon.image(.wrench, size: 13); glyph.contentTintColor = CorralAestheticTokens.textMuted
            phaseLabel.textColor = CorralAestheticTokens.textMuted
        default:
            glyph.image = CorralLegacyIcon.image(.wrench, size: 13); glyph.contentTintColor = CorralAestheticTokens.textSecondary
            phaseLabel.textColor = CorralAestheticTokens.textSecondary
        }
        setAccessibilityLabel("工具 \(tool)，\(Self.phaseText(phase))")
        setAccessibilityValue(expanded ? 1 : 0)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        glyph.frame = CGRect(x: 12, y: midY - 6.5, width: 13, height: 13)
        spinner.frame = CGRect(x: 11, y: midY - 8, width: 16, height: 16)
        chevron.frame = CGRect(x: bounds.width - 22, y: midY - 5, width: 10, height: 10)
        let phaseWidth = TranscriptRowView.width(of: phaseLabel)
        phaseLabel.frame = CGRect(x: chevron.frame.minX - 8 - phaseWidth, y: midY - 8, width: phaseWidth, height: 16)
        let nameWidth = min(TranscriptRowView.width(of: name), max(40, (phaseLabel.frame.minX - 46) * 0.45))
        name.frame = CGRect(x: 34, y: midY - 8, width: nameWidth, height: 16)
        let previewX = name.frame.maxX + 10
        preview.frame = CGRect(x: previewX, y: midY - 8, width: max(0, phaseLabel.frame.minX - 12 - previewX), height: 16)
    }

    override func mouseDown(with event: NSEvent) { notifyConversationPaneInteraction(); onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// One atomic control: labels inside must not swallow the click.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) && !isHidden ? self : nil }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: Notice

@MainActor
final class NoticeRowView: TranscriptRowView {
    private let icon = NSImageView()
    private let text = CorralTextLayout.makeTextView()
    static let iconSize: CGFloat = 13

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(icon)
        addSubview(text)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    static func attributed(_ row: CorralConversationRow) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        paragraph.alignment = .left
        var message = row.text
        if case let .other(kind) = row.kind { message = "未识别的内容类型「\(kind)」" + (message.isEmpty ? "" : "：\(message)") }
        if let status = bodyStatus(for: row) { message += "\n" + status }
        return NSAttributedString(string: message.isEmpty ? "（无内容）" : message,
                                  attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: CorralAestheticTokens.textMuted, .paragraphStyle: paragraph])
    }

    static func measure(_ row: CorralConversationRow, width: CGFloat) -> CGFloat {
        max(20, CorralTextLayout.size(of: attributed(row), width: width - 22).height)
    }

    override func configure(_ row: CorralConversationRow, width: CGFloat, expanded: Bool) {
        icon.image = CorralLegacyIcon.image(.info, size: Self.iconSize)
        icon.contentTintColor = CorralAestheticTokens.textMuted
        icon.frame = CGRect(x: 0, y: 3, width: Self.iconSize, height: Self.iconSize)
        let string = Self.attributed(row)
        let height = CorralTextLayout.size(of: string, width: width - 22).height
        CorralTextLayout.set(text, text: string, width: width - 22)
        text.frame = CGRect(x: 22, y: 0, width: width - 22, height: height)
        setAccessibilityLabel("通知：\(row.text)")
    }
}

// MARK: Top status & jump button

@MainActor
final class TranscriptTopStatusView: NSView {
    var onAction: (() -> Void)?
    private let label = TranscriptCaption()
    private let spinner = NSProgressIndicator()
    private let leftRule = NSView()
    private let rightRule = NSView()
    private var older: CorralConversationPaneState.Older = .complete
    override var isFlipped: Bool { true }

    var isMeaningful: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 11.5)
        for rule in [leftRule, rightRule] { rule.wantsLayer = true; addSubview(rule) }
        addSubview(label)
        addSubview(spinner)
        setAccessibilityIdentifier("corral.conversation.history-status")
        apply(.complete)
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ older: CorralConversationPaneState.Older) {
        self.older = older
        spinner.stopAnimation(nil)
        label.onClick = nil
        switch older {
        case .available:
            label.stringValue = "载入更早的消息"
            label.onClick = { [weak self] in self?.onAction?() }
        case .loading:
            label.stringValue = "正在载入更早的消息…"
            spinner.startAnimation(nil)
        case let .failed(code):
            label.stringValue = "更早的消息载入失败（\(CorralConversationStateOverlay.describe(code))）· 重试"
            label.onClick = { [weak self] in self?.onAction?() }
        case .complete:
            label.stringValue = "会话开始"
        case .limit:
            label.stringValue = "更早的内容保留在主机上 · 本地最多显示 1500 条"
        case .partial:
            label.stringValue = "主机仅提供最近的历史窗口，更早内容未包含"
        }
        label.setAccessibilityLabel(label.stringValue)
        refreshTheme()
        needsLayout = true
    }

    func refreshTheme() {
        let actionable = label.onClick != nil
        label.textColor = actionable ? CorralAestheticTokens.accent : CorralAestheticTokens.textMuted
        for rule in [leftRule, rightRule] { rule.layer?.backgroundColor = CorralConversationStyle.rule.withAlphaComponent(0.6).cgColor }
        window?.invalidateCursorRects(for: label)
    }

    override func layout() {
        super.layout()
        let width = min(bounds.width, TranscriptRowView.width(of: label))
        let midY = bounds.height / 2
        label.frame = CGRect(x: (bounds.width - width) / 2, y: midY - 8, width: width, height: 16)
        spinner.frame = CGRect(x: label.frame.minX - 22, y: midY - 8, width: 16, height: 16)
        let showRules = older == .complete
        leftRule.isHidden = !showRules
        rightRule.isHidden = !showRules
        let ruleWidth = max(0, min(120, label.frame.minX - 12))
        leftRule.frame = CGRect(x: label.frame.minX - 12 - ruleWidth, y: midY, width: ruleWidth, height: 0.5)
        rightRule.frame = CGRect(x: label.frame.maxX + 12, y: midY, width: ruleWidth, height: 0.5)
    }
}

@MainActor
final class TranscriptJumpButton: NSView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "回到最新")
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.borderWidth = 0.5
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        addSubview(icon)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("回到最新")
        setAccessibilityIdentifier("corral.conversation.jump-latest")
        refreshTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: TranscriptRowView.width(of: label) + 40, height: 30) }

    func refreshTheme() {
        layer?.backgroundColor = CorralAestheticTokens.surface2.cgColor
        layer?.borderColor = CorralConversationStyle.cardBorder.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        label.textColor = CorralAestheticTokens.text
        icon.image = CorralLegacyIcon.image(.arrowDown, size: 12)
        icon.contentTintColor = CorralAestheticTokens.textSecondary
    }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 14, y: (bounds.height - 12) / 2, width: 12, height: 12)
        label.frame = CGRect(x: 32, y: (bounds.height - 16) / 2, width: bounds.width - 44, height: 16)
    }

    override func mouseDown(with event: NSEvent) { notifyConversationPaneInteraction(); onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// One atomic control: labels inside must not swallow the click.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) && !isHidden ? self : nil }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
