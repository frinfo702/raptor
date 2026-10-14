import AppKit
import GhosttyKit
import SwiftUI

/// One row of the command palette: a command with its shortcut, or a submenu showing
/// its current value.
struct RaptorCommand: Identifiable {
    var id: String { title }
    let title: String
    /// Shortcut glyphs, drawn trailing.
    var shortcut: [String] = []
    /// A submenu's current value, drawn trailing before its chevron.
    var value: String?
    /// The submenu's rows, nil for a plain command.
    var submenu: (() -> [RaptorCommand])?
    /// In a submenu, the row of the current value.
    var checked = false
    var action: () -> Void = {}

    // ponytail: greedy, so it can miss a better-scoring spelling; fine for short titles.
    /// The characters of `title` that spell out `query` in order, ignoring case, with a
    /// score that favours runs and word starts. Nil if they don't.
    static func match(_ query: String, in title: String) -> (score: Int, indices: [Int])? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return (0, []) }
        let t = Array(title.lowercased())
        // A substring wins outright, earlier and at a word start better.
        if let r = title.range(of: query, options: .caseInsensitive) {
            let start = title.distance(from: title.startIndex, to: r.lowerBound)
            let wordStart = start == 0 || t[start - 1] == " "
            return (1000 - start + (wordStart ? 100 : 0), Array(start..<start + q.count))
        }
        var indices: [Int] = []
        var score = 0
        var i = 0
        for c in q {
            while i < t.count && t[i] != c { i += 1 }
            guard i < t.count else { return nil }
            if let last = indices.last, last == i - 1 { score += 10 }
            if i == 0 || t[i - 1] == " " { score += 8 }
            score -= i - (indices.last.map { $0 + 1 } ?? 0)
            indices.append(i)
            i += 1
        }
        return (score, indices)
    }

    /// The commands matching `query`, best first; ties keep their order.
    static func filter(_ commands: [RaptorCommand], _ query: String) -> [RaptorCommand] {
        guard !query.isEmpty else { return commands }
        return commands.enumerated()
            .compactMap { i, c in match(query, in: c.title).map { (c, $0.score, i) } }
            .sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }
            .map(\.0)
    }

    /// Ghostty's glyphs for a shortcut, drawn the way Rex draws them.
    static func glyphs(_ shortcut: KeyboardShortcut?) -> [String] {
        let rex = ["▲": "↑", "▼": "↓", "◀": "←", "▶": "→", "⏎": "↩"]
        return (shortcut?.keyList ?? []).map { rex[$0] ?? $0 }
    }
}

/// Rex's command palette: a centred popover with a search field over rows of commands.
/// It opens instantly; typing filters fuzzily and bolds the matched characters; the
/// selected row is filled with the theme's accent. Submenus replace the rows; Escape
/// goes back, then closes.
struct RaptorCommandPalette: View {
    @Binding var isPresented: Bool
    /// Asked once, when the palette opens.
    let makeCommands: () -> [RaptorCommand]
    let tokens: ThemeTokens
    let accent: Color

    // ponytail: until Raptor's own themes (T18) name an accent each.
    /// The theme's accent: its ANSI magenta.
    static func accent(_ config: Ghostty.Config) -> NSColor {
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard let cfg = config.config,
              ghostty_config_get(cfg, &palette, key, UInt(key.lengthOfBytes(using: .utf8))) else { return .controlAccentColor }
        let c = palette.colors.5
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    /// The first palette's query, for scripted screenshots.
    static var scriptedQuery = ProcessInfo.processInfo.environment["RAPTOR_PALETTE_QUERY"]

    static let width: CGFloat = 330
    static let rowHeight: CGFloat = 28
    static let maxRows = 16

    /// The submenus opened, innermost last.
    @State private var commands: [RaptorCommand] = []
    @State private var path: [RaptorCommand] = []
    @State private var query = ""
    @State private var selected: Int?

    private var rows: [RaptorCommand] {
        RaptorCommand.filter(path.last?.submenu?() ?? commands, query)
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 7) {
            RaptorSearchField(
                placeholder: path.last.map { "\($0.title)…" } ?? "Search commands…",
                query: $query,
                tokens: tokens
            ) { event in
                switch event {
                case .exit:
                    if path.isEmpty { isPresented = false } else { open(nil) }
                case .lostFocus:
                    isPresented = false
                case .submit:
                    if let i = selected, i < rows.count { run(rows[i]) }
                case .up:
                    guard !rows.isEmpty else { break }
                    selected = ((selected ?? rows.count) + rows.count - 1) % rows.count
                case .down:
                    guard !rows.isEmpty else { break }
                    selected = ((selected ?? -1) + 1) % rows.count
                }
            }
            list(rows)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: Self.width)
        .background(Color(nsColor: tokens.popover))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: tokens.popoverBorder)))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .environment(\.colorScheme, tokens.isLight ? .light : .dark)
        .onChange(of: query) { q in if !q.isEmpty { selected = 0 } }
        .onAppear {
            commands = makeCommands()
            if let q = Self.scriptedQuery {
                Self.scriptedQuery = nil
                query = q
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command Palette")
    }

    @ViewBuilder private func list(_ rows: [RaptorCommand]) -> some View {
        if rows.isEmpty {
            Text("No matches")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(height: Self.rowHeight)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            RaptorCommandRow(command: row, query: query, selected: selected == i, accent: accent)
                                .id(row.id)
                                .onHover { if $0 { selected = i } }
                                .onTapGesture { run(row) }
                        }
                    }
                }
                // Rex shows no scroller.
                .scrollIndicators(.never)
                .frame(height: CGFloat(min(rows.count, Self.maxRows)) * Self.rowHeight)
                .onChange(of: selected) { i in
                    if let i, i < rows.count { proxy.scrollTo(rows[i].id) }
                }
            }
        }
    }

    private func run(_ command: RaptorCommand) {
        if command.submenu != nil { return open(command) }
        isPresented = false
        command.action()
    }

    /// Show a submenu's rows, nil for the parent's, starting on the current value.
    private func open(_ submenu: RaptorCommand?) {
        if let submenu { path.append(submenu) } else { path.removeLast() }
        query = ""
        selected = rows.firstIndex(where: \.checked)
    }
}

private struct RaptorCommandRow: View {
    let command: RaptorCommand
    let query: String
    let selected: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            if command.checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            title
                .font(.system(size: 14))
                .lineLimit(1)
            Spacer(minLength: 8)
            if command.submenu != nil {
                if let value = command.value {
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 1) {
                    ForEach(Array(command.shortcut.enumerated()), id: \.offset) { _, g in Text(g) }
                }
                .font(.system(size: 12))
                .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.fill)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? accent : .clear))
        .padding(.horizontal, 5)
        .frame(height: RaptorCommandPalette.rowHeight)
        .contentShape(Rectangle())
        .foregroundStyle(selected ? Color.white : Color.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.title)
        .accessibilityValue(command.value ?? command.shortcut.joined())
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The selected row's fill, inside the row's pitch.
    static let fill: CGFloat = 26

    /// The title with the characters the query matched in bold.
    private var title: Text {
        guard let m = RaptorCommand.match(query, in: command.title), !m.indices.isEmpty else {
            return Text(command.title)
        }
        var s = AttributedString(command.title)
        let chars = Array(s.characters.indices)
        for i in m.indices where i < chars.count {
            s[chars[i]..<s.characters.index(after: chars[i])].font = .system(size: 14, weight: .bold)
        }
        return Text(s)
    }
}

/// A popover's search field: a magnifier, the query, and a clear button once there is
/// one. It takes the keyboard on appearing; arrows and Control-P/N move the selection.
struct RaptorSearchField: View {
    let placeholder: String
    @Binding var query: String
    let tokens: ThemeTokens
    let onEvent: (Event) -> Void

    enum Event { case exit, lostFocus, submit, up, down }

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity)
                .focused($focused)
                .onSubmit { onEvent(.submit) }
                .onExitCommand { onEvent(.exit) }
                .onChange(of: focused) { if !$0 { onEvent(.lostFocus) } }
                // The field only takes focus once it's in the window.
                .onAppear { DispatchQueue.main.async { focused = true } }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 29, maxHeight: 29, alignment: .leading)
        // Moves through the rows without leaving the field.
        .background {
            Group {
                Button { onEvent(.up) } label: { Color.clear }.keyboardShortcut(.upArrow, modifiers: [])
                Button { onEvent(.down) } label: { Color.clear }.keyboardShortcut(.downArrow, modifiers: [])
                Button { onEvent(.up) } label: { Color.clear }.keyboardShortcut("p", modifiers: [.control])
                Button { onEvent(.down) } label: { Color.clear }.keyboardShortcut("n", modifiers: [.control])
            }
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: tokens.field)))
        .padding(.horizontal, 8)
    }
}
