import SwiftUI

/// The tabs, sharing one rounded track: the active tab is a raised capsule inside it,
/// the others sit on the track with a thin divider between them. Sizes are Rex's, from
/// the captain's reference frame at 2x.
struct RaptorTabStrip: View {
    @ObservedObject var controller: RaptorController
    let tokens: ThemeTokens

    static let trackHeight: CGFloat = 32
    static let tabHeight: CGFloat = 29
    static let tabWidth: CGFloat = 208
    /// The track sits 1.5 pt below the title bar's centre, as in Rex.
    static let trackDrop: CGFloat = 1.5

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(controller.tabs.enumerated()), id: \.element.id) { i, tab in
                let active = tab.id == controller.activeTab
                if i > 0 {
                    let prevActive = controller.tabs[i - 1].id == controller.activeTab
                    Rectangle()
                        .fill(divider)
                        .frame(width: 1, height: 17)
                        .opacity(active || prevActive ? 0 : 1)
                }
                RaptorTabView(
                    tab: tab,
                    active: active,
                    tokens: tokens,
                    select: { controller.selectTab(tab.id) },
                    close: { controller.closeTab(tab.id) })
            }
        }
        .padding(.horizontal, 2)
        .frame(height: Self.trackHeight)
        .background(Capsule().fill(track))
        .offset(y: Self.trackDrop)
    }

    /// The track and dividers lift the chrome on dark themes and darken it on light ones.
    private var track: Color { tokens.isLight ? .black.opacity(0.04) : .white.opacity(0.07) }
    private var divider: Color { tokens.isLight ? Color(nsColor: tokens.separator) : .white.opacity(0.2) }
}

struct RaptorTabView: View {
    let tab: RaptorController.Tab
    let active: Bool
    let tokens: ThemeTokens
    let select: () -> Void
    let close: () -> Void

    @State private var hovering = false

    /// A tab's title as the program's name and, after it, the working directory, which
    /// is drawn dimmer. Titles that don't start with the name (an agent's) are all name.
    static func titleParts(_ title: String, program: String) -> (name: String, path: String) {
        guard title.hasPrefix(program + " ") else { return (title, "") }
        return (program, String(title.dropFirst(program.count)))
    }

    var body: some View {
        let parts = Self.titleParts(tab.title, program: tab.program.name)
        HStack(spacing: 12) {
            RaptorTileCluster(program: tab.program, others: tab.others, light: tokens.isLight)
                // Crowded tabs give up their title, never the card.
                .fixedSize()
            // Long titles fade out instead of ending in an ellipsis.
            (Text(parts.name).foregroundColor(active ? .primary : .secondary)
                + Text(parts.path).foregroundColor(active ? .secondary : Color(nsColor: .tertiaryLabelColor)))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .mask(HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 24)
                })
            if hovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(minWidth: 48, maxWidth: RaptorTabStrip.tabWidth, minHeight: RaptorTabStrip.tabHeight, maxHeight: RaptorTabStrip.tabHeight)
        .background(pill)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityAction(named: "Close Tab", close)
    }

    /// The active tab is a raised capsule on the track. Light themes draw it as chrome
    /// with a border.
    @ViewBuilder private var pill: some View {
        if active {
            if tokens.isLight {
                Capsule()
                    .fill(Color(nsColor: tokens.chrome))
                    .overlay(Capsule().strokeBorder(Color(nsColor: tokens.separator)))
            } else {
                Capsule()
                    .fill(Color.white.opacity(0.05))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
            }
        }
    }
}
