import AppKit

/// Native Markdown for Agent transcripts: paragraphs, headings, lists, quotes, rules, tables, inline styles and
/// fenced code. Nothing is executed or fetched; links are attributes the text view opens only on a user click.
/// Unclosed constructs (a streaming fence or `**`) degrade to readable literal text.
extension NSAttributedString.Key {
    /// Inline code chip, drawn as a rounded glyph-height background by `CorralTranscriptLayoutManager`.
    static let corralInlineCode = NSAttributedString.Key("corral.inlineCode")
    /// Block quote depth; the layout manager draws one bar per level beside the line fragments.
    static let corralQuoteDepth = NSAttributedString.Key("corral.quoteDepth")
    /// A thematic break line.
    static let corralRule = NSAttributedString.Key("corral.rule")
}

enum CorralMarkdown {
    enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case listItem(depth: Int, marker: String, text: String)
        case quote([Block])
        case code(language: String, text: String, closed: Bool)
        case table(header: [String], alignments: [NSTextAlignment], rows: [[String]])
        case rule
    }

    /// A rendered message: flowing text runs separated by fenced code blocks.
    enum Segment {
        case text(NSAttributedString)
        case code(language: String, text: String)
    }

    struct Style {
        var font: NSFont
        var color: NSColor
        var secondaryColor: NSColor
        var linkColor: NSColor
        var codeColor: NSColor
        var codeBackground: NSColor
        var ruleColor: NSColor
        var tableHeaderBackground: NSColor
        var lineHeightMultiple: CGFloat = 1.32
        var paragraphSpacing: CGFloat = 7
    }

    // MARK: Parsing

    static func parse(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return parse(lines: lines[...])
    }

    private static func parse(lines: ArraySlice<String>) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var index = lines.startIndex
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); index += 1; continue }
            if let fence = fenceOpening(line) {
                flush()
                var body: [String] = []
                var closed = false
                index += 1
                while index < lines.endIndex {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence.marker), candidate.allSatisfy({ $0 == fence.marker.first }) {
                        closed = true
                        index += 1
                        break
                    }
                    body.append(dedent(lines[index], by: fence.indent))
                    index += 1
                }
                blocks.append(.code(language: fence.language, text: body.joined(separator: "\n"), closed: closed))
                continue
            }
            if let heading = heading(trimmed) { flush(); blocks.append(heading); index += 1; continue }
            if isRule(trimmed) { flush(); blocks.append(.rule); index += 1; continue }
            if trimmed.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while index < lines.endIndex {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var stripped = candidate.dropFirst()
                    if stripped.first == " " { stripped = stripped.dropFirst() }
                    inner.append(String(stripped))
                    index += 1
                }
                blocks.append(.quote(parse(lines: inner[...])))
                continue
            }
            if trimmed.contains("|"), index + 1 < lines.endIndex, let alignments = tableDelimiter(lines[index + 1]) {
                flush()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.endIndex {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, candidate.contains("|") else { break }
                    rows.append(tableCells(candidate))
                    index += 1
                }
                let width = max(header.count, alignments.count)
                func pad(_ cells: [String]) -> [String] { Array((cells + Array(repeating: "", count: max(0, width - cells.count))).prefix(width)) }
                let aligned = (alignments + Array(repeating: NSTextAlignment.natural, count: max(0, width - alignments.count))).prefix(width)
                blocks.append(.table(header: pad(header), alignments: Array(aligned), rows: rows.map(pad)))
                continue
            }
            if let item = listItem(line) {
                flush()
                blocks.append(item)
                index += 1
                // Lazy continuation lines belong to the item, not a new paragraph.
                while index < lines.endIndex {
                    let next = lines[index]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    guard !nextTrimmed.isEmpty, listItem(next) == nil, fenceOpening(next) == nil, heading(nextTrimmed) == nil,
                          !nextTrimmed.hasPrefix(">"), next.hasPrefix("  ") || next.hasPrefix("\t"),
                          case let .listItem(depth, marker, text) = blocks[blocks.count - 1] else { break }
                    blocks[blocks.count - 1] = .listItem(depth: depth, marker: marker, text: text + "\n" + nextTrimmed)
                    index += 1
                }
                continue
            }
            paragraph.append(trimmed)
            index += 1
        }
        flush()
        return blocks
    }

    private static func fenceOpening(_ line: String) -> (marker: String, language: String, indent: Int)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        for character in ["`", "~"] {
            let run = rest.prefix(while: { String($0) == character })
            guard run.count >= 3 else { continue }
            let info = rest.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            if character == "`", info.contains("`") { return nil }
            let language = info.split(separator: " ").first.map(String.init) ?? ""
            return (String(run), language, indent)
        }
        return nil
    }

    private static func dedent(_ line: String, by count: Int) -> String {
        var remaining = count
        var result = Substring(line)
        while remaining > 0, result.first == " " { result = result.dropFirst(); remaining -= 1 }
        return String(result)
    }

    private static func heading(_ trimmed: String) -> Block? {
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> Block? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let indent = expanded.prefix(while: { $0 == " " }).count
        let rest = expanded.dropFirst(indent)
        let depth = min(indent / 2, 4)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            var text = String(rest.dropFirst(2))
            var marker = ["•", "◦", "▪︎", "•", "◦"][depth]
            if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) }
            else if text.lowercased().hasPrefix("[x] ") { marker = "☑︎"; text.removeFirst(4) }
            return .listItem(depth: depth, marker: marker, text: text)
        }
        let digits = rest.prefix(while: \.isNumber)
        guard (1...9).contains(digits.count) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")", after.dropFirst().first == " " else { return nil }
        return .listItem(depth: depth, marker: digits + ".", text: String(after.dropFirst(2)))
    }

    private static func tableDelimiter(_ line: String) -> [NSTextAlignment]? {
        let cells = tableCells(line.trimmingCharacters(in: .whitespaces))
        guard !cells.isEmpty, line.contains("-") else { return nil }
        var alignments: [NSTextAlignment] = []
        for cell in cells {
            let compact = cell.replacingOccurrences(of: " ", with: "")
            guard !compact.isEmpty, compact.allSatisfy({ $0 == "-" || $0 == ":" }), compact.contains("-") else { return nil }
            switch (compact.hasPrefix(":"), compact.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.right)
            default: alignments.append(.natural)
            }
        }
        return alignments
    }

    private static func tableCells(_ row: String) -> [String] {
        var text = Substring(row)
        if text.hasPrefix("|") { text = text.dropFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text = text.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "`" { inCode.toggle() }
            if character == "|", !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(character)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Rendering

    static func render(_ source: String, style: Style) -> [Segment] {
        var segments: [Segment] = []
        let text = NSMutableAttributedString()
        func flushText() {
            guard text.length > 0 else { return }
            while text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
            segments.append(.text(NSAttributedString(attributedString: text)))
            text.setAttributedString(NSAttributedString())
        }
        for block in parse(source) {
            if case let .code(language, code, _) = block {
                flushText()
                segments.append(.code(language: language, text: code))
            } else {
                append(block, to: text, style: style, quoteDepth: 0)
            }
        }
        flushText()
        return segments
    }

    private static func paragraphStyle(_ style: Style, indent: CGFloat = 0, head: CGFloat? = nil, spacingBefore: CGFloat = 0) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = style.lineHeightMultiple
        paragraph.paragraphSpacing = style.paragraphSpacing
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = head ?? indent
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }

    private static func append(_ block: Block, to output: NSMutableAttributedString, style: Style, quoteDepth: Int) {
        let quoteIndent = CGFloat(quoteDepth) * 16
        var base: [NSAttributedString.Key: Any] = [.font: style.font, .foregroundColor: quoteDepth > 0 ? style.secondaryColor : style.color]
        if quoteDepth > 0 { base[.corralQuoteDepth] = quoteDepth }
        switch block {
        case let .paragraph(text):
            base[.paragraphStyle] = paragraphStyle(style, indent: quoteIndent)
            output.append(inline(text, base: base, style: style))
            output.append(NSAttributedString(string: "\n", attributes: base))
        case let .heading(level, text):
            let sizes: [CGFloat] = [20, 17, 15, 14, 13.5, 13]
            let size = sizes[min(level, 6) - 1]
            base[.font] = NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
            base[.paragraphStyle] = paragraphStyle(style, indent: quoteIndent, spacingBefore: level <= 2 ? 8 : 4)
            output.append(inline(text, base: base, style: style))
            output.append(NSAttributedString(string: "\n", attributes: base))
        case let .listItem(depth, marker, text):
            let indent = quoteIndent + CGFloat(depth) * 18
            let markerWidth: CGFloat = marker.count > 2 ? 26 : 18
            let paragraph = paragraphStyle(style, indent: indent, head: indent + markerWidth)
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
            paragraph.paragraphSpacing = 3
            base[.paragraphStyle] = paragraph
            var markerAttributes = base
            markerAttributes[.foregroundColor] = style.secondaryColor
            if marker.hasSuffix(".") { markerAttributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: style.font.pointSize, weight: .regular) }
            output.append(NSAttributedString(string: marker + "\t", attributes: markerAttributes))
            output.append(inline(text, base: base, style: style))
            output.append(NSAttributedString(string: "\n", attributes: base))
        case let .quote(blocks):
            for inner in blocks { append(inner, to: output, style: style, quoteDepth: quoteDepth + 1) }
        case let .table(header, alignments, rows):
            appendTable(header: header, alignments: alignments, rows: rows, to: output, style: style, base: base)
        case .rule:
            let paragraph = paragraphStyle(style)
            paragraph.minimumLineHeight = 18
            paragraph.maximumLineHeight = 18
            paragraph.lineHeightMultiple = 0
            var attributes = base
            attributes[.paragraphStyle] = paragraph
            attributes[.corralRule] = style.ruleColor
            output.append(NSAttributedString(string: "\u{200B}\n", attributes: attributes))
        case let .code(_, code, _):
            base[.font] = monospacedFont(size: style.font.pointSize - 1)
            base[.paragraphStyle] = paragraphStyle(style, indent: quoteIndent)
            output.append(NSAttributedString(string: code + "\n", attributes: base))
        }
    }

    private static func appendTable(header: [String], alignments: [NSTextAlignment], rows: [[String]], to output: NSMutableAttributedString,
                                    style: Style, base: [NSAttributedString.Key: Any]) {
        let table = NSTextTable()
        table.numberOfColumns = max(1, header.count)
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        table.setWidth(10, type: .absoluteValueType, for: .margin, edge: .maxY)
        for (rowIndex, cells) in ([header] + rows).enumerated() {
            for (column, cell) in cells.enumerated() {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(style.ruleColor)
                block.setWidth(5, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(5, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.setWidth(9, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(9, type: .absoluteValueType, for: .padding, edge: .maxX)
                if rowIndex == 0 { block.backgroundColor = style.tableHeaderBackground }
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.alignment = alignments.indices.contains(column) ? alignments[column] : .natural
                paragraph.lineHeightMultiple = 1.15
                var attributes = base
                attributes[.paragraphStyle] = paragraph
                attributes[.font] = rowIndex == 0 ? NSFont.systemFont(ofSize: style.font.pointSize - 0.5, weight: .semibold)
                    : NSFont.systemFont(ofSize: style.font.pointSize - 0.5)
                output.append(inline(cell.isEmpty ? " " : cell, base: attributes, style: style))
                output.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
    }

    static func monospacedFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: Inline

    static func inline(_ text: String, base: [NSAttributedString.Key: Any], style: Style) -> NSAttributedString {
        let output = NSMutableAttributedString()
        appendInline(Substring(text), base: base, style: style, into: output)
        return output
    }

    private static func appendInline(_ text: Substring, base: [NSAttributedString.Key: Any], style: Style, into output: NSMutableAttributedString) {
        var literal = ""
        func flush() {
            if !literal.isEmpty { output.append(NSAttributedString(string: literal, attributes: base)); literal = "" }
        }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let rest = text[index...]
            if character == "\\", let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex), next < text.endIndex,
               "\\`*_{}[]()#+-.!|~<>".contains(text[next]) {
                literal.append(text[next])
                index = text.index(after: next)
                continue
            }
            if character == "`" {
                let run = rest.prefix(while: { $0 == "`" })
                let afterRun = rest.dropFirst(run.count)
                if let close = afterRun.range(of: String(run)) {
                    flush()
                    var code = String(afterRun[afterRun.startIndex..<close.lowerBound])
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 2 { code = String(code.dropFirst().dropLast()) }
                    var attributes = base
                    attributes[.font] = monospacedFont(size: ((base[.font] as? NSFont)?.pointSize ?? style.font.pointSize) - 1)
                    attributes[.foregroundColor] = style.codeColor
                    attributes[.corralInlineCode] = style.codeBackground
                    output.append(NSAttributedString(string: "\u{202F}" + code + "\u{202F}", attributes: attributes))
                    index = close.upperBound
                    continue
                }
                literal.append(contentsOf: run)
                index = text.index(index, offsetBy: run.count)
                continue
            }
            if character == "[", let link = linkSpan(rest) {
                flush()
                var attributes = base
                if let url = safeURL(link.destination) {
                    attributes[.link] = url
                    attributes[.foregroundColor] = style.linkColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.underlineColor] = style.linkColor.withAlphaComponent(0.35)
                    attributes[.toolTip] = url.absoluteString
                }
                appendInline(link.label, base: attributes, style: style, into: output)
                index = link.end
                continue
            }
            if character == "<", let close = rest.firstIndex(of: ">"), let url = safeURL(String(rest[rest.index(after: rest.startIndex)..<close])) {
                flush()
                output.append(linkString(url.absoluteString, url: url, base: base, style: style))
                index = text.index(after: close)
                continue
            }
            if character == "h", (rest.hasPrefix("https://") || rest.hasPrefix("http://")),
               index == text.startIndex || !(text[text.index(before: index)].isLetter || text[text.index(before: index)].isNumber) {
                var candidate = String(rest.prefix(while: { !$0.isWhitespace && $0 != "<" && $0 != ">" && $0 != "\"" && $0 != "`" }))
                while let last = candidate.last, ".,;:!?)]}'。，；：！？）".contains(last), !(last == ")" && candidate.contains("(")) {
                    candidate.removeLast()
                }
                if let url = safeURL(candidate) {
                    flush()
                    output.append(linkString(candidate, url: url, base: base, style: style))
                    index = text.index(index, offsetBy: candidate.count)
                    continue
                }
            }
            if character == "*" || character == "_" || character == "~" {
                let run = rest.prefix(while: { $0 == character })
                let width = min(run.count, character == "~" ? 2 : 3)
                if character == "~", width < 2 { literal.append(character); index = text.index(after: index); continue }
                let opener = String(repeating: character, count: width)
                let inner = rest.dropFirst(width)
                let leftOK = !(inner.first?.isWhitespace ?? true)
                let wordInternal = character == "_" && index > text.startIndex && text[text.index(before: index)].isLetter
                if leftOK, !wordInternal, let close = closingDelimiter(opener, in: inner) {
                    flush()
                    var attributes = base
                    let font = (base[.font] as? NSFont) ?? style.font
                    switch (character, width) {
                    case ("~", _): attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    case (_, 1): attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    case (_, 2): attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    default: attributes[.font] = NSFontManager.shared.convert(NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), toHaveTrait: .italicFontMask)
                    }
                    appendInline(inner[inner.startIndex..<close], base: attributes, style: style, into: output)
                    index = text.index(close, offsetBy: width)
                    continue
                }
                literal.append(contentsOf: run)
                index = text.index(index, offsetBy: run.count)
                continue
            }
            literal.append(character)
            index = text.index(after: index)
        }
        flush()
    }

    private static func closingDelimiter(_ delimiter: String, in text: Substring) -> Substring.Index? {
        var search = text.startIndex
        while let range = text.range(of: delimiter, range: search..<text.endIndex) {
            search = text.index(after: range.lowerBound)
            guard range.lowerBound > text.startIndex else { continue }
            let before = text[text.index(before: range.lowerBound)]
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : " "
            if !before.isWhitespace, after != delimiter.first, delimiter.first != "_" || !(after.isLetter || after.isNumber) {
                return range.lowerBound
            }
        }
        return nil
    }

    private static func linkSpan(_ text: Substring) -> (label: Substring, destination: String, end: Substring.Index)? {
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 {
                    let open = text.index(after: index)
                    guard open < text.endIndex, text[open] == "(", let close = text[open...].firstIndex(of: ")") else { return nil }
                    let label = text[text.index(after: text.startIndex)..<index]
                    let destination = text[text.index(after: open)..<close].split(separator: " ").first.map(String.init) ?? ""
                    return (label, destination.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), text.index(after: close))
                }
            case "\n": return nil
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func linkString(_ title: String, url: URL, base: [NSAttributedString.Key: Any], style: Style) -> NSAttributedString {
        var attributes = base
        attributes[.link] = url
        attributes[.foregroundColor] = style.linkColor
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        attributes[.underlineColor] = style.linkColor.withAlphaComponent(0.35)
        return NSAttributedString(string: title, attributes: attributes)
    }

    /// Only web and mail links become clickable; file, script and custom schemes stay plain text.
    static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme != "mailto", url.host?.isEmpty != false { return nil }
        return url
    }
}

/// Small lexical highlighter for fenced code. It colors only tokens it is sure about; unknown languages stay plain.
enum CorralCodeHighlighter {
    struct Palette {
        var plain: NSColor
        var keyword: NSColor
        var string: NSColor
        var number: NSColor
        var comment: NSColor
        var type: NSColor
    }

    private static let keywords = Set<String>([
        "func", "let", "var", "if", "else", "guard", "return", "for", "while", "in", "switch", "case", "default", "break", "continue",
        "struct", "class", "enum", "protocol", "extension", "import", "public", "private", "fileprivate", "internal", "static", "final",
        "async", "await", "throws", "throw", "try", "catch", "do", "defer", "self", "Self", "nil", "true", "false", "init", "where",
        "function", "const", "new", "this", "typeof", "instanceof", "export", "from", "as", "interface", "type", "implements", "extends",
        "null", "undefined", "yield", "def", "elif", "pass", "lambda", "None", "True", "False", "with", "not", "and", "or", "is",
        "package", "go", "chan", "select", "fn", "mut", "impl", "trait", "pub", "use", "mod", "match", "loop", "crate", "unsafe",
        "echo", "then", "fi", "esac", "done", "local", "export", "readonly", "until", "elseif", "end", "nonlocal", "global", "raise",
        "except", "finally", "void", "int", "bool", "string", "float", "double", "char", "long", "short", "unsigned", "sizeof"
    ])

    static func highlight(_ code: String, language: String, font: NSFont, palette: Palette) -> NSAttributedString {
        let output = NSMutableAttributedString(string: code, attributes: [.font: font, .foregroundColor: palette.plain])
        let lowered = language.lowercased()
        guard !["", "text", "txt", "plain", "plaintext", "log", "output", "console"].contains(lowered),
              code.utf16.count <= 200_000 else { return output }
        let hashComments = ["sh", "bash", "zsh", "shell", "python", "py", "ruby", "rb", "yaml", "yml", "toml", "make", "makefile", "dockerfile", "r", "perl", "conf", "ini"].contains(lowered)
        let slashComments = !["json", "yaml", "yml", "toml", "html", "xml", "md", "markdown", "ini", "conf"].contains(lowered)
        let source = code as NSString
        let length = source.length
        var index = 0
        func color(_ range: NSRange, _ value: NSColor) { output.addAttribute(.foregroundColor, value: value, range: range) }
        func character(_ at: Int) -> unichar { at < length ? source.character(at: at) : 0 }
        while index < length {
            let c = character(index)
            if slashComments, c == 47, character(index + 1) == 47 { // //
                let end = source.range(of: "\n", options: [], range: NSRange(location: index, length: length - index)).location
                let stop = end == NSNotFound ? length : end
                color(NSRange(location: index, length: stop - index), palette.comment)
                index = stop
                continue
            }
            if slashComments, c == 47, character(index + 1) == 42 { // /*
                let end = source.range(of: "*/", options: [], range: NSRange(location: index + 2, length: max(0, length - index - 2))).location
                let stop = end == NSNotFound ? length : end + 2
                color(NSRange(location: index, length: stop - index), palette.comment)
                index = stop
                continue
            }
            if hashComments, c == 35, index == 0 || [10, 32, 9].contains(character(index - 1)) { // #
                let end = source.range(of: "\n", options: [], range: NSRange(location: index, length: length - index)).location
                let stop = end == NSNotFound ? length : end
                color(NSRange(location: index, length: stop - index), palette.comment)
                index = stop
                continue
            }
            if c == 34 || c == 39 || c == 96 { // " ' `
                var cursor = index + 1
                while cursor < length {
                    let d = character(cursor)
                    if d == 92 { cursor += 2; continue }
                    if d == c { cursor += 1; break }
                    if d == 10, c != 96 { break }
                    cursor += 1
                }
                color(NSRange(location: index, length: min(cursor, length) - index), palette.string)
                index = min(cursor, length)
                continue
            }
            if let scalar = UnicodeScalar(c), CharacterSet.decimalDigits.contains(scalar),
               index == 0 || !isIdentifier(character(index - 1)) {
                var cursor = index + 1
                while cursor < length, isIdentifier(character(cursor)) || character(cursor) == 46 { cursor += 1 }
                color(NSRange(location: index, length: cursor - index), palette.number)
                index = cursor
                continue
            }
            if isIdentifierStart(c) {
                var cursor = index + 1
                while cursor < length, isIdentifier(character(cursor)) { cursor += 1 }
                let word = source.substring(with: NSRange(location: index, length: cursor - index))
                if keywords.contains(word) { color(NSRange(location: index, length: cursor - index), palette.keyword) }
                else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first), word.count > 1 {
                    color(NSRange(location: index, length: cursor - index), palette.type)
                }
                index = cursor
                continue
            }
            index += 1
        }
        return output
    }

    private static func isIdentifierStart(_ c: unichar) -> Bool { (65...90).contains(c) || (97...122).contains(c) || c == 95 || c == 36 }
    private static func isIdentifier(_ c: unichar) -> Bool { isIdentifierStart(c) || (48...57).contains(c) }
}
