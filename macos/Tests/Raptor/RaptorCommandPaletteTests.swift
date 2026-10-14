import SwiftUI
import Testing
@testable import Ghostty

/// The palette's fuzzy filter and its shortcut glyphs.
struct RaptorCommandPaletteTests {
    private func titles(_ query: String, _ titles: [String]) -> [String] {
        RaptorCommand.filter(titles.map { RaptorCommand(title: $0) }, query).map(\.title)
    }

    @Test func substringMatchesBoldTheRun() {
        let m = RaptorCommand.match("mig", in: "Migrate theme from Ghostty config")
        #expect(m?.indices == [0, 1, 2])
    }

    @Test func subsequenceMatches() {
        let m = RaptorCommand.match("fpl", in: "Focus Pane Left")
        #expect(m?.indices == [0, 6, 11])
        #expect(RaptorCommand.match("xyz", in: "Focus Pane Left") == nil)
        #expect(RaptorCommand.match("SPLIT", in: "Split Pane Down") != nil)
    }

    @Test func bestMatchesFirst() {
        let all = ["Rename Tab…", "Split Pane Down", "Show Previous Tab", "Split Pane Right"]
        #expect(titles("spl", all) == ["Split Pane Down", "Split Pane Right"])
        // A substring at a word start beats a scattered match; ties keep their order.
        #expect(titles("tab", all) == ["Rename Tab…", "Show Previous Tab"])
        #expect(titles("", all) == all)
    }

    @Test func glyphsAreRexs() {
        let split = KeyboardShortcut(.downArrow, modifiers: [.command, .shift])
        #expect(RaptorCommand.glyphs(split) == ["⇧", "⌘", "↓"])
        #expect(RaptorCommand.glyphs(KeyboardShortcut(.return, modifiers: .command)) == ["⌘", "↩"])
        #expect(RaptorCommand.glyphs(nil) == [])
    }
}
