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
        #expect(card("nvim") == nil)
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

/// A tab stacks the other panes' cards behind the focused pane's, as in Rex.
struct RaptorCardStackTests {
    private func cards(_ focused: String?, _ others: [String?]) -> [String?] {
        let program = { (p: String?) in RaptorProgram.identify(p) ?? .shell }
        return RaptorTileCluster.stack(program(focused), others: others.map(program)).map(\.card)
    }

    @Test func otherPanesShowTheirOwnCards() {
        #expect(cards("zsh", ["claude"]) == ["shell", "claudecode"])
        #expect(cards("claude", ["zsh"]) == ["claudecode", "shell"])
    }

    @Test func identicalProgramsShowOneCardEach() {
        #expect(cards("zsh", ["zsh"]) == ["shell", "shell"])
        #expect(cards("zsh", ["zsh", "zsh"]) == ["shell", "shell", "shell"])
    }

    @Test func atMostTwoCardsBehind() {
        #expect(cards("zsh", ["claude", "codex", "git", "zsh"]) == ["shell", "claudecode", "codex"])
        #expect(cards("make", []) == [nil])
    }

    /// A process goes by the name it runs as when Raptor knows it: Claude Code's version-named
    /// binary runs as "claude", Cursor's node-based agent as "cursor-agent".
    @Test func versionedBinariesGoByTheNameTheyRunAs() {
        #expect(RaptorProgram.processName("2.1.299", argv0: "claude") == "claude")
        #expect(RaptorProgram.processName("2.1.299", argv0: "/Users/me/.local/bin/claude") == "claude")
        #expect(RaptorProgram.processName("zsh", argv0: "-zsh") == "zsh")
        #expect(RaptorProgram.processName("make", argv0: "make") == "make")
        #expect(RaptorProgram.processName("node", argv0: "cursor-agent") == "cursor-agent")
        #expect(RaptorProgram.processName("node", argv0: "/Users/me/.local/bin/node") == "node")
        #expect(RaptorProgram.processName("node", argv0: "script.js") == "node")
        #expect(RaptorProgram.processName("2.1.299", argv0: nil) == "2.1.299")
        #expect(RaptorProgram.processName(nil, argv0: nil) == nil)
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

/// rap names every window; only a name from Rename Tab replaces the program title.
struct RaptorTabLabelTests {
    private let id = "window:01a13804-5407-744d-a5e0-773af9b8d402"

    @Test func defaultLabelsGiveWayToTheProgramTitle() {
        #expect(RaptorTabView.isDefaultLabel("Primary", window: id))
        #expect(RaptorTabView.isDefaultLabel("Window f9b8d402", window: id))
        #expect(RaptorTabView.isDefaultLabel(nil, window: id))
        #expect(RaptorTabView.isDefaultLabel("", window: id))
    }

    @Test func renamedTabsKeepTheirName() {
        #expect(!RaptorTabView.isDefaultLabel("Snake", window: id))
        // Another window's default is a real name here.
        #expect(!RaptorTabView.isDefaultLabel("Window 12345678", window: id))
    }
}
