import AppKit
import Testing
@testable import Ghostty

/// Tabs show the focused pane's program on its card, in the art for the theme.
struct RaptorCardTests {
    private func card(_ process: String?) -> String? {
        (RaptorProgram.identify(process) ?? .shell).card
    }

    @Test func shellsAndNoProgramShowTheShellCard() {
        for process in ["zsh", "bash", "fish", "sh", "nu", nil] {
            #expect(card(process) == "shell", "\(process ?? "nil")")
        }
    }

    @Test func programsShowTheirCards() {
        #expect(card("claude") == "claudecode")
        #expect(card("codex") == "codex")
        #expect(card("gh") == "github")
        #expect(card("git") == "git")
        #expect(card("opencode") == "opencode")
    }

    @Test func unknownProgramsKeepTheTile() {
        #expect(card("vim") == nil)
        #expect(card("make") == nil)
        #expect(card("lazygit") == nil)
    }

    @Test func everyCardHasArtForBothThemes() {
        for card in Set(RaptorProgram.cards.values).union(["shell"]) {
            #expect(RaptorProgram.cardImage(card, light: true) != nil, "\(card)")
            #expect(RaptorProgram.cardImage(card, light: false) != nil, "\(card)")
        }
    }

    @Test func variantFollowsTheTheme() {
        #expect(RaptorProgram.cardImage("codex", light: true) === NSImage(named: "codex-light"))
        #expect(RaptorProgram.cardImage("codex", light: false) === NSImage(named: "codex-dark"))
        #expect(RaptorProgram.cardImage("shell", light: true) === NSImage(named: "shell-light"))
        #expect(RaptorProgram.cardImage("shell", light: false) === NSImage(named: "shell-dark"))
    }

    @Test func singleArtServesBothThemes() {
        #expect(RaptorProgram.cardImage("claudecode", light: true) === NSImage(named: "claudecode"))
        #expect(RaptorProgram.cardImage("claudecode", light: false) === NSImage(named: "claudecode"))
    }
}
