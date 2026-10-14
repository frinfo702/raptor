import SwiftUI

/// How Raptor shows a pane's foreground program: a friendly name and an icon, drawn
/// plain in pane headers and on a tinted tile in tabs.
///
/// ponytail: SF Symbols and text glyphs stand in for program logos until the final icon art.
struct RaptorProgram: Equatable {
    enum Icon: Equatable {
        case symbol(String)
        case text(String)
    }

    let name: String
    let icon: Icon
    /// The tab tile's fill, and the glyph's colour on it.
    let tile: Color
    let glyph: Color
    /// Agents title their panes with the task they're on.
    var isAgent = false
    /// The tab card drawn instead of the tile, from `cards`.
    var card: String?

    static let shells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh",
    ]

    private static func rgb(_ hex: Int) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static let shell = RaptorProgram(name: "shell", icon: .text(">_"), tile: rgb(0x3B5C3E), glyph: rgb(0x8CD97F), card: "shell")

    /// Tab cards by process name, shells aside: imagesets in RaptorCards.xcassets. A card
    /// drawn for light and dark themes is two imagesets, "<card>-light" and "<card>-dark".
    static let cards: [String: String] = [
        "claude": "claudecode",
        "codex": "codex",
        "gh": "github",
        "git": "git",
        "opencode": "opencode",
    ]

    /// A card's image for a light or dark theme; a card with one image serves both.
    static func cardImage(_ card: String, light: Bool) -> NSImage? {
        NSImage(named: "\(card)-\(light ? "light" : "dark")") ?? NSImage(named: card)
    }

    /// Programs by process name.
    private static let known: [String: RaptorProgram] = [
        "nvim": .init(name: "Neovim", icon: .text("N"), tile: rgb(0x1F6F68), glyph: rgb(0x9BE3C8)),
        "vim": .init(name: "Vim", icon: .text("V"), tile: rgb(0x1F5F2E), glyph: rgb(0x9BE39F)),
        "hx": .init(name: "Helix", icon: .symbol("chevron.left.forwardslash.chevron.right"), tile: rgb(0x4B3A6E), glyph: rgb(0xD2C2F5)),
        "node": .init(name: "Node", icon: .symbol("hexagon.fill"), tile: rgb(0x3A4A3A), glyph: rgb(0xC9D1C9)),
        "bun": .init(name: "Bun", icon: .symbol("circle.dotted"), tile: rgb(0xF2E8DC), glyph: rgb(0x3A3028)),
        "deno": .init(name: "Deno", icon: .symbol("circle.fill"), tile: rgb(0x2A2A2A), glyph: rgb(0xEDEDED)),
        "python": .init(name: "Python", icon: .symbol("chevron.left.forwardslash.chevron.right"), tile: rgb(0x2F4F7A), glyph: rgb(0xF5D76E)),
        "python3": .init(name: "Python", icon: .symbol("chevron.left.forwardslash.chevron.right"), tile: rgb(0x2F4F7A), glyph: rgb(0xF5D76E)),
        "lazygit": .init(name: "Git Changes", icon: .symbol("plusminus.circle"), tile: rgb(0x4A3A2A), glyph: rgb(0xF0B27A)),
        "git": .init(name: "Git", icon: .symbol("arrow.triangle.branch"), tile: rgb(0x4A3A2A), glyph: rgb(0xF0B27A)),
        "btop": .init(name: "btop", icon: .text("B"), tile: rgb(0x7A1E1E), glyph: rgb(0xFF8A80)),
        "htop": .init(name: "htop", icon: .symbol("chart.bar.fill"), tile: rgb(0x2E5A2E), glyph: rgb(0x9BE39F)),
        "top": .init(name: "top", icon: .symbol("chart.bar.fill"), tile: rgb(0x3A3A3A), glyph: rgb(0xDDDDDD)),
        "ssh": .init(name: "SSH", icon: .symbol("network"), tile: rgb(0x2F4F7A), glyph: rgb(0xBFD8F5)),
        "less": .init(name: "less", icon: .symbol("doc.text"), tile: rgb(0x3A3A3A), glyph: rgb(0xDDDDDD)),
        "man": .init(name: "Manual", icon: .symbol("book"), tile: rgb(0x3A3A3A), glyph: rgb(0xDDDDDD)),
        "claude": .init(name: "Claude", icon: .symbol("asterisk"), tile: rgb(0xD9774B), glyph: rgb(0xFFFFFF), isAgent: true),
        "codex": .init(name: "Codex", icon: .symbol("circle.hexagongrid"), tile: rgb(0xF2F2F2), glyph: rgb(0x111111), isAgent: true),
        "opencode": .init(name: "OpenCode", icon: .symbol("sparkle"), tile: rgb(0x2A2A2A), glyph: rgb(0xEDEDED), isAgent: true),
        "gemini": .init(name: "Gemini", icon: .symbol("sparkle"), tile: rgb(0x2F4F7A), glyph: rgb(0xBFD8F5), isAgent: true),
    ]

    /// The program for a process name, nil if there is none yet.
    static func identify(_ process: String?) -> RaptorProgram? {
        guard let process, !process.isEmpty else { return nil }
        if shells.contains(process) {
            return .init(name: process, icon: shell.icon, tile: shell.tile, glyph: shell.glyph, card: shell.card)
        }
        var program = known[process] ?? .init(name: process, icon: .symbol("terminal"), tile: rgb(0x3A3A3A), glyph: rgb(0xDDDDDD))
        program.card = cards[process]
        return program
    }

    /// A pane's title: an agent's own title, else "Name ~/path", else the terminal title.
    static func title(process: String?, terminalTitle: String, pwd: String, home: String = NSHomeDirectory()) -> String {
        guard let program = identify(process) else { return terminalTitle.isEmpty ? shell.name : terminalTitle }
        if program.isAgent && !terminalTitle.isEmpty { return terminalTitle }
        guard !pwd.isEmpty else { return program.name }
        let path = pwd == home ? "~" : pwd.hasPrefix(home + "/") ? "~" + pwd.dropFirst(home.count) : pwd
        return "\(program.name) \(path)"
    }
}

/// A program's icon, sized to fit `size`.
struct RaptorProgramIcon: View {
    let icon: RaptorProgram.Icon
    let size: CGFloat

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.8, weight: .medium))
        case .text(let text):
            Text(text)
                .font(.system(size: text.count > 1 ? size * 0.55 : size * 0.8, weight: .heavy, design: .monospaced))
        }
    }
}

/// A tab's icon: the focused pane's program on its card or tile, with a coloured sliver
/// behind it for each other pane, up to two.
struct RaptorTileCluster: View {
    let program: RaptorProgram
    let others: [RaptorProgram]
    /// Picks a card's light-theme art.
    let light: Bool

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let card = program.card, let image = RaptorProgram.cardImage(card, light: light) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 18)
                } else {
                    RaptorProgramIcon(icon: program.icon, size: 12)
                        .foregroundStyle(program.glyph)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5).fill(program.tile))
                }
            }
            .zIndex(1)
            ForEach(Array(others.prefix(2).enumerated()), id: \.offset) { i, other in
                RoundedRectangle(cornerRadius: 3)
                    .fill(other.glyph)
                    .frame(width: 8, height: 18 - CGFloat(i + 1) * 3)
                    .padding(.leading, -4)
                    .zIndex(-Double(i))
            }
        }
    }
}
