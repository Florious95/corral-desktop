import AppKit
@testable import CorralUI
import CorralContracts
import XCTest

@MainActor
final class CLIProviderRecognitionTests: XCTestCase {
    private struct Case {
        let wireValue: String
        let canonicalKind: String
        let displayName: String
        let badgeCharacter: Character?
    }

    private let cases = [
        Case(wireValue: "pi", canonicalKind: "pi", displayName: "Pi", badgeCharacter: nil),
        Case(wireValue: "claude_code", canonicalKind: "claude_code", displayName: "Claude Code", badgeCharacter: nil),
        Case(wireValue: "codex", canonicalKind: "codex", displayName: "Codex", badgeCharacter: nil),
        Case(wireValue: "cursor", canonicalKind: "cursor", displayName: "Cursor", badgeCharacter: nil),
        Case(wireValue: "aider", canonicalKind: "aider", displayName: "Aider", badgeCharacter: "A"),
        Case(wireValue: "goose", canonicalKind: "goose", displayName: "Goose", badgeCharacter: "G"),
        Case(wireValue: "opencode", canonicalKind: "opencode", displayName: "OpenCode", badgeCharacter: "O"),
        Case(wireValue: "kiro_cli", canonicalKind: "kiro_cli", displayName: "Kiro CLI", badgeCharacter: "K"),
    ]

    func testSidebarRecognizesAllEightCLIsWithCanonicalKindTextAndClassifiedIcon() throws {
        let sidebar = CorralSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 700))
        let space = CorralSidebarSpace(name: "CLI workspace")
        sidebar.setSpaces([space])
        sidebar.setAgents(cases.map { item in
            CorralSidebarAgent(name: "\(item.displayName) session", provider: item.wireValue,
                               spaceID: space.id, sessionID: SessionID(UUID().uuidString))
        })
        sidebar.layoutSubtreeIfNeeded()
        sidebar.agentsTable.layoutSubtreeIfNeeded()

        for (row, item) in cases.enumerated() {
            let cell = try XCTUnwrap(sidebar.agentsTable.view(atColumn: 0, row: row, makeIfNecessary: true),
                                     "Missing rendered sidebar row for \(item.displayName)")
            cell.layoutSubtreeIfNeeded()
            let icon = try XCTUnwrap(descendants(of: cell).compactMap { $0 as? CorralProviderIconView }.first,
                                     "\(item.displayName) row must mount CorralProviderIconView")
            XCTAssertEqual(icon.provider, item.canonicalKind,
                           "\(item.displayName) must resolve to its canonical ProviderKind")
            XCTAssertEqual(icon.accessibilityLabel(), item.displayName,
                           "\(item.displayName) must be the native sidebar/AX label")
            let image = try XCTUnwrap(icon.image, "\(item.displayName) must render an icon image")
            if let badgeCharacter = item.badgeCharacter {
                XCTAssertTrue(image.isTemplate,
                              "\(item.displayName) must render a template letter badge for \(badgeCharacter)")
                XCTAssertTrue(image.representations.contains {
                    String(describing: type(of: $0)).contains("NSCustomImageRep")
                }, "\(item.displayName) must render its \(badgeCharacter) classified letter badge, not a missing icon")
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
