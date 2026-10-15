import SwiftUI

/// How Raptor shows a pane's foreground program: a friendly name and an icon, drawn
/// plain in pane headers and, in tabs, as the program's card or else on a tinted tile.
///
/// ponytail: SF Symbols and text glyphs stand in for program logos in pane headers and
/// on tiles for programs without a card.
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
        "cursor-agent": "cursor",
        "docker": "docker",
        "gh": "github",
        "git": "git",
        "node": "node",
        "opencode": "opencode",
        "uv": "uv",
        "uvx": "uv",
        "vim": "vim",
    ]

    /// The imageset that draws a card on a light or dark theme; a card with one image
    /// serves both. Nil if the card has no art.
    static func cardAsset(_ card: String, light: Bool) -> String? {
        ["\(card)-\(light ? "light" : "dark")", card].first { NSImage(named: $0) != nil }
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
        "cursor-agent": .init(name: "Cursor", icon: .symbol("cursorarrow"), tile: rgb(0x111111), glyph: rgb(0xEDEDED), isAgent: true),
        "gemini": .init(name: "Gemini", icon: .symbol("sparkle"), tile: rgb(0x2F4F7A), glyph: rgb(0xBFD8F5), isAgent: true),
    ]

    /// The name a process goes by: its command name, unless only the name it was run as
    /// (argv[0], without a login shell's "-") is one Raptor knows. Claude Code's binary is
    /// named for its version ("2.1.299") but run as "claude".
    static func processName(_ name: String?, argv0: String?) -> String? {
        let known = { (n: String) in shells.contains(n) || Self.known[n] != nil || cards[n] != nil }
        if let name, known(name) { return name }
        guard let argv0 else { return name }
        let runAs = String((argv0 as NSString).lastPathComponent.drop { $0 == "-" })
        return known(runAs) ? runAs : name
    }

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

/// A program's card, or its tile if it has none, `height` tall.
struct RaptorCardFace: View {
    let program: RaptorProgram
    /// Picks a card's light-theme art.
    let light: Bool
    let height: CGFloat

    var body: some View {
        if let card = program.card, let asset = RaptorProgram.cardAsset(card, light: light),
           let image = NSImage(named: asset) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: height)
        } else {
            RaptorProgramIcon(icon: program.icon, size: height * 2 / 3)
                .foregroundStyle(program.glyph)
                .frame(width: height, height: height)
                .background(RoundedRectangle(cornerRadius: height * 5 / 18).fill(program.tile))
        }
    }
}

/// A tab's icon: the focused pane's program on its card or tile, tilted, with the card
/// of each other pane stacked behind it, up to two, as in Rex.
struct RaptorTileCluster: View {
    let program: RaptorProgram
    let others: [RaptorProgram]
    /// Picks a card's light-theme art.
    let light: Bool

    /// The front tile's lean, measured from the captain's close-up of Rex's tab.
    static let tilt = -5.0
    /// Rex shows at most two cards behind the front one, however many panes the tab has.
    static let maxBehind = 2
    /// How far each card behind peeks out past the one in front, and how much shorter it is.
    static let peek: CGFloat = 5
    static let shrink: CGFloat = 2

    /// The cards a tab draws, front first: the focused pane's, then one per other pane in
    /// the tab's order, the same program as often as it runs.
    static func stack(_ program: RaptorProgram, others: [RaptorProgram]) -> [RaptorProgram] {
        [program] + others.prefix(maxBehind)
    }

    var body: some View {
        let cards = Self.stack(program, others: others)
        // Cards share a right edge, then each card behind moves right to peek out.
        ZStack(alignment: .trailing) {
            // Back to front: each card behind is shorter and darker.
            ForEach(Array(cards.enumerated().reversed()), id: \.offset) { depth, card in
                let face = RaptorCardFace(program: card, light: light, height: 18 - Self.shrink * CGFloat(depth))
                if depth == 0 {
                    // Rex leans the front tile a few degrees, lifted by a soft shadow.
                    face
                        .rotationEffect(.degrees(Self.tilt))
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                } else {
                    face
                        .brightness(-0.12 * Double(depth))
                        .shadow(color: .black.opacity(0.3), radius: 0.5)
                        .offset(x: Self.peek * CGFloat(depth))
                }
            }
        }
        .padding(.trailing, Self.peek * CGFloat(cards.count - 1))
    }
}
