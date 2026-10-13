import AppKit
import SwiftUI

/// The session switcher under the session item: "Filter or create…", the server's
/// sessions with ⌘1–⌘9 while it's open, and New Session (⇧⌘N), named after the query
/// when one is typed. A row's context menu renames or closes its session.
struct RaptorSessionPopover: View {
    @ObservedObject var controller: RaptorController
    @Binding var isPresented: Bool
    let tokens: ThemeTokens

    @State private var query = ""
    @State private var selected: Int?
    @State private var sessions: [RaptorClient.SessionSummary] = []

    private enum Row: Identifiable {
        case session(RaptorClient.SessionSummary, number: Int)
        case create(String)

        var id: String {
            switch self {
            case .session(let s, _): s.id
            case .create: "create"
            }
        }
    }

    private var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let numbered = sessions.enumerated().map { Row.session($1, number: $0 + 1) }
        guard !q.isEmpty else { return numbered + [.create("")] }
        let matches = numbered.compactMap { row -> (Row, Int)? in
            guard case .session(let s, _) = row, let m = RaptorCommand.match(q, in: s.label) else { return nil }
            return (row, m.score)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
        let exists = sessions.contains { $0.label == q }
        return matches + (exists ? [] : [.create(q)])
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            RaptorSearchField(placeholder: "Filter or create…", query: $query, tokens: tokens) { event in
                switch event {
                case .exit, .lostFocus:
                    isPresented = false
                case .submit:
                    if let i = selected, i < rows.count { run(rows[i]) }
                case .up:
                    selected = ((selected ?? rows.count) + rows.count - 1) % rows.count
                case .down:
                    selected = ((selected ?? -1) + 1) % rows.count
                }
            }
            .padding(.vertical, 8)
            Divider()
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if case .create = row, i > 0 { Divider().padding(.vertical, 4) }
                    self.row(row, selected: selected == i)
                        .onHover { if $0 { selected = i } }
                        .onTapGesture { run(row) }
                }
            }
            .padding(.vertical, 5)
            // ⌘1–⌘9 pick a session while the switcher is open.
            ForEach(Array(sessions.prefix(9).enumerated()), id: \.element.id) { i, s in
                Button { pick(s) } label: { EmptyView() }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .frame(minWidth: 220, maxWidth: 320)
        .fixedSize()
        .background(Color(nsColor: tokens.popover))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: tokens.popoverBorder)))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .environment(\.colorScheme, tokens.isLight ? .light : .dark)
        .onAppear {
            sessions = controller.client.sessions()
            selected = sessions.firstIndex { $0.id == controller.session }
        }
        .onChange(of: query) { q in selected = q.isEmpty ? nil : 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions")
    }

    private func row(_ row: Row, selected: Bool) -> some View {
        HStack(spacing: 8) {
            switch row {
            case .session(let s, let number):
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(s.id == controller.session ? 1 : 0)
                Text(s.label).lineLimit(1)
                Spacer(minLength: 16)
                if number <= 9 { shortcut("⌘\(number)", selected) }
            case .create(let name):
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 12))
                Text(name.isEmpty ? "New Session" : "New Session “\(name)”").lineLimit(1)
                Spacer(minLength: 16)
                shortcut("⇧⌘N", selected)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : .clear))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 5)
        .frame(height: 28)
        .contentShape(Rectangle())
        .contextMenu {
            if case .session(let s, _) = row {
                Button("Rename Session…") { isPresented = false; controller.renameSession(id: s.id) }
                Button("Close Session…") { isPresented = false; controller.closeSession(id: s.id) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(row))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func shortcut(_ text: String, _ selected: Bool) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(selected ? .primary : .secondary)
    }

    private func label(_ row: Row) -> String {
        switch row {
        case .session(let s, _): s.label
        case .create(let name): name.isEmpty ? "New Session" : "New Session “\(name)”"
        }
    }

    private func run(_ row: Row) {
        switch row {
        case .session(let s, _): pick(s)
        case .create(let name):
            isPresented = false
            controller.newSession(label: name.isEmpty ? nil : name)
        }
    }

    private func pick(_ s: RaptorClient.SessionSummary) {
        isPresented = false
        controller.switchSession(to: s.id)
    }
}
