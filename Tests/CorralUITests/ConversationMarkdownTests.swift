import AppKit
@testable import CorralUI
import XCTest

@MainActor
final class ConversationMarkdownTests: XCTestCase {
    private var style: CorralMarkdown.Style {
        CorralMarkdown.Style(font: .systemFont(ofSize: 14), color: .textColor, secondaryColor: .secondaryLabelColor, linkColor: .linkColor,
                             codeColor: .systemOrange, codeBackground: .quaternaryLabelColor, ruleColor: .separatorColor,
                             tableHeaderBackground: .controlBackgroundColor)
    }

    func testBlocksCoverTheTranscriptVocabulary() {
        let blocks = CorralMarkdown.parse("""
        # Title
        Para line one
        line two

        - a
          continued
        1. first
        > quote
        ---
        | h1 | h2 |
        |:--|--:|
        | x | y |
        ```swift
        let a = 1
        ```
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("Para line one\nline two"),
            .listItem(depth: 0, marker: "•", text: "a\ncontinued"),
            .listItem(depth: 0, marker: "1.", text: "first"),
            .quote([.paragraph("quote")]),
            .rule,
            .table(header: ["h1", "h2"], alignments: [.natural, .right], rows: [["x", "y"]]),
            .code(language: "swift", text: "let a = 1", closed: true)
        ])
    }

    func testAnUnclosedStreamingFenceStaysReadableCode() {
        XCTAssertEqual(CorralMarkdown.parse("text\n```py\nprint(1)"), [.paragraph("text"), .code(language: "py", text: "print(1)", closed: false)])
        let segments = CorralMarkdown.render("**bold and `code", style: style)
        guard case let .text(string)? = segments.first else { return XCTFail("expected text") }
        XCTAssertEqual(string.string, "**bold and `code", "unclosed inline markers degrade to literal text")
    }

    func testInlineStylesLinksAndCodeChips() {
        let segments = CorralMarkdown.render("a **b** `c` [d](https://example.com) [e](file:///etc/passwd) <javascript:x> https://pi.dev/x.", style: style)
        guard case let .text(string)? = segments.first else { return XCTFail("expected text") }
        let text = string.string as NSString
        XCTAssertFalse(string.string.contains("**"))
        let bold = string.attribute(.font, at: text.range(of: "b").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertNotNil(string.attribute(.corralInlineCode, at: text.range(of: "c").location, effectiveRange: nil))
        XCTAssertEqual(string.attribute(.link, at: text.range(of: "d").location, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        XCTAssertNil(string.attribute(.link, at: text.range(of: "e").location, effectiveRange: nil), "file links are never clickable")
        XCTAssertNil(string.attribute(.link, at: text.range(of: "javascript").location, effectiveRange: nil))
        XCTAssertEqual(string.attribute(.link, at: text.range(of: "pi.dev").location, effectiveRange: nil) as? URL, URL(string: "https://pi.dev/x"),
                       "trailing punctuation is not part of a bare URL")
    }

    func testFencedCodeIsASeparateSegmentAndHighlighterKeepsTextIntact() {
        let segments = CorralMarkdown.render("intro\n```swift\nlet x = \"s\" // c\n```\nafter", style: style)
        XCTAssertEqual(segments.count, 3)
        guard case let .code(language, code) = segments[1] else { return XCTFail("expected code") }
        XCTAssertEqual(language, "swift")
        let palette = CorralCodeHighlighter.Palette(plain: .white, keyword: .red, string: .green, number: .blue, comment: .gray, type: .yellow)
        let highlighted = CorralCodeHighlighter.highlight(code, language: language, font: .monospacedSystemFont(ofSize: 12, weight: .regular), palette: palette)
        XCTAssertEqual(highlighted.string, code)
        XCTAssertEqual(highlighted.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .red)
        let comment = (code as NSString).range(of: "// c")
        XCTAssertEqual(highlighted.attribute(.foregroundColor, at: comment.location, effectiveRange: nil) as? NSColor, .gray)
    }

    func testToolOutputIsBoundedWithAnExplicitCount() {
        let output = (1...700).map { "line \($0)" }.joined(separator: "\n")
        let bounded = ToolRowView.boundedOutput(output)
        XCTAssertTrue(bounded.hasSuffix("（共 700 行）"))
        XCTAssertLessThan(bounded.count, output.count)
        XCTAssertEqual(ToolRowView.boundedOutput("short"), "short")
    }
}
