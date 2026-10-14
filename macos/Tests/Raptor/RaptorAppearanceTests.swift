import Foundation
import Testing
@testable import Ghostty

struct RaptorAppearanceTests {
    private func fresh() -> UserDefaults {
        let name = "raptor-appearance-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A fresh install looks like Rex's screenshots: islands with headers, Blended.
    @Test func freshInstallDefaults() {
        let a = RaptorAppearance(defaults: fresh(), environment: [:])
        #expect(a.style == .blended)
        #expect(a.density == .islands)
        #expect(a.paneHeaders)
        #expect(a.translucentPanes)
    }

    @Test func savedAndForcedValues() {
        let defaults = fresh()
        defaults.set("compact", forKey: "RaptorPaneDensity")
        defaults.set(false, forKey: "RaptorPaneHeaders")
        defaults.set(false, forKey: "RaptorTranslucentPanes")
        let saved = RaptorAppearance(defaults: defaults, environment: [:])
        #expect(saved.density == .compact)
        #expect(!saved.paneHeaders)
        #expect(!saved.translucentPanes)

        let forced = RaptorAppearance(defaults: defaults, environment: [
            "RAPTOR_INTERFACE_STYLE": "solid",
            "RAPTOR_PANE_DENSITY": "islands",
            "RAPTOR_PANE_HEADERS": "1",
            "RAPTOR_TRANSLUCENT_PANES": "1",
        ])
        #expect(forced.style == .solid)
        #expect(forced.density == .islands)
        #expect(forced.paneHeaders)
        #expect(forced.translucentPanes)
    }

    /// Every style keeps unfocused panes undimmed; only the translucent ones let the
    /// desktop through the panes, as much as through the chrome, unless turned off.
    @Test func config() {
        let a = RaptorAppearance(defaults: fresh(), environment: [:])
        a.style = .solid
        #expect(a.config.contains("unfocused-split-opacity = 1"))
        #expect(a.config.contains("background-opacity = 1.0\n"))
        a.style = .blended
        #expect(RaptorAppearance.paneOpacity == RaptorWindowBackground.tint)
        #expect(a.config.contains("background-opacity = \(RaptorAppearance.paneOpacity)\n"))
        #expect(!a.config.contains("background-blur"))
        a.translucentPanes = false
        #expect(a.config.contains("background-opacity = 1.0\n"))
        a.translucentPanes = true
        a.style = .glass
        if RaptorAppearance.glassAvailable {
            #expect(a.config.contains("background-blur = macos-glass-regular"))
        } else {
            #expect(a.effectiveStyle == .blended)
            #expect(!a.config.contains("background-blur"))
        }
    }
}

struct RaptorProgramTests {
    private let home = "/Users/me"

    @Test func shellsAndPrograms() {
        #expect(RaptorProgram.title(process: "fish", terminalTitle: "~/apps - fish", pwd: "/Users/me/apps/replay-web", home: home)
            == "fish ~/apps/replay-web")
        #expect(RaptorProgram.title(process: "nvim", terminalTitle: "x", pwd: "/Users/me/apps", home: home) == "Neovim ~/apps")
        #expect(RaptorProgram.title(process: "lazygit", terminalTitle: "", pwd: "/Users/me", home: home) == "Git Changes ~")
        #expect(RaptorProgram.title(process: "node", terminalTitle: "", pwd: "/tmp", home: home) == "Node /tmp")
        // A sibling of home is not under it.
        #expect(RaptorProgram.title(process: "zsh", terminalTitle: "", pwd: "/Users/meow", home: home) == "zsh /Users/meow")
        #expect(RaptorProgram.title(process: "zsh", terminalTitle: "", pwd: "", home: home) == "zsh")
    }

    /// Agents name their pane after the task they're on.
    @Test func agents() {
        #expect(RaptorProgram.title(process: "codex", terminalTitle: "Stress-test Snake demo", pwd: "/Users/me", home: home)
            == "Stress-test Snake demo")
        #expect(RaptorProgram.title(process: "claude", terminalTitle: "", pwd: "/Users/me/x", home: home) == "Claude ~/x")
    }

    @Test func unknownProcess() {
        #expect(RaptorProgram.title(process: nil, terminalTitle: "", pwd: "/x", home: home) == "shell")
        #expect(RaptorProgram.title(process: nil, terminalTitle: "vim foo", pwd: "/x", home: home) == "vim foo")
        #expect(RaptorProgram.identify("cargo")?.name == "cargo")
        #expect(RaptorProgram.identify("bash")?.icon == RaptorProgram.shell.icon)
    }
}
