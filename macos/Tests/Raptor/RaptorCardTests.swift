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
            #expect(RaptorProgram.cardAsset(card, light: true) != nil, "\(card)")
            #expect(RaptorProgram.cardAsset(card, light: false) != nil, "\(card)")
        }
    }

    @Test func variantFollowsTheTheme() {
        #expect(RaptorProgram.cardAsset("codex", light: true) == "codex-light")
        #expect(RaptorProgram.cardAsset("codex", light: false) == "codex-dark")
        #expect(RaptorProgram.cardAsset("shell", light: true) == "shell-light")
        #expect(RaptorProgram.cardAsset("shell", light: false) == "shell-dark")
    }

    @Test func singleArtServesBothThemes() {
        #expect(RaptorProgram.cardAsset("claudecode", light: true) == "claudecode")
        #expect(RaptorProgram.cardAsset("claudecode", light: false) == "claudecode")
    }
}

/// Tab titles draw the program's name, then its directory dimmer.
struct RaptorTabTitleTests {
    @Test func nameThenPath() {
        #expect(RaptorTabView.titleParts("Bun ~/sites/announcement", program: "Bun") == ("Bun", " ~/sites/announcement"))
        #expect(RaptorTabView.titleParts("fish ~/sites/macos-client", program: "fish") == ("fish", " ~/sites/macos-client"))
        #expect(RaptorTabView.titleParts("zsh", program: "zsh") == ("zsh", ""))
    }

    /// An agent's own title is all name.
    @Test func agentTitle() {
        #expect(RaptorTabView.titleParts("Stress-test Snake demo", program: "Codex") == ("Stress-test Snake demo", ""))
    }
}
