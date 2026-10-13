import AppKit
import SwiftUI
import SystemConfiguration

/// The title bar, holding the session item and the tab strip, above the active tab's
/// panes: islands (cards with the chrome between them) or compact (1 px dividers).
struct RaptorWindowView: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var controller: RaptorController
    @ObservedObject var appearance: RaptorAppearance

    static let titlebarHeight: CGFloat = 40
    /// Islands: the cards' inset from the window edges and the gutter between them.
    static let islandInset: CGFloat = 8
    static let islandGutter: CGFloat = 9

    private var tokens: ThemeTokens { ThemeTokens(background: NSColor(ghostty.config.backgroundColor)) }
    private var islands: Bool { appearance.density == .islands }

    var body: some View {
        let tokens = tokens
        VStack(spacing: 0) {
            titlebar(tokens)

            if !islands {
                Rectangle()
                    .fill(Color(nsColor: tokens.hairline))
                    .frame(height: 1)
            }

            TerminalView(ghostty: ghostty, viewModel: controller, delegate: controller)
                .environment(\.splitDividerColor, islands ? .clear : Color(nsColor: tokens.hairline))
                .environment(\.splitDividerSize, islands ? Self.islandGutter : 1)
                .environment(\.splitLeafWrapper) { surface, content in
                    AnyView(RaptorPane(
                        ghostty: ghostty,
                        controller: controller,
                        appearance: appearance,
                        surface: surface,
                        content: content))
                }
                // Below the title bar the cards sit a little closer than at the sides,
                // as in Rex.
                .padding(.top, islands ? Self.islandInset - 2 : 0)
                .padding([.leading, .trailing, .bottom], islands ? Self.islandInset : 0)
        }
        .background(RaptorWindowBackground(style: appearance.effectiveStyle, tokens: tokens))
        .ignoresSafeArea(.container, edges: .top)
    }

    private func titlebar(_ tokens: ThemeTokens) -> some View {
        HStack(spacing: 0) {
            // ponytail: inert until the session switcher lands.
            RaptorTitlebarButton(symbol: "rectangle.stack", help: "Sessions") {}
                .padding(.trailing, 6)
            RaptorSessionItem(label: controller.label)
                .padding(.trailing, 20)
            ForEach(Array(controller.tabs.enumerated()), id: \.element.id) { i, tab in
                let active = tab.id == controller.activeTab
                // Light themes separate inactive tabs, Safari-style.
                if i > 0 && tokens.isLight {
                    let prevActive = controller.tabs[i - 1].id == controller.activeTab
                    Rectangle()
                        .fill(Color(nsColor: tokens.separator))
                        .frame(width: 1, height: 16)
                        .opacity(active || prevActive ? 0 : 1)
                }
                RaptorTabView(
                    tab: tab,
                    active: active,
                    tokens: tokens,
                    solid: appearance.effectiveStyle == .solid,
                    select: { controller.selectTab(tab.id) },
                    close: { controller.closeTab(tab.id) })
            }
            Spacer(minLength: 8)
            RaptorTitlebarButton(symbol: "command", help: "Command Palette") {
                controller.toggleCommandPalette(nil)
            }
            .padding(.trailing, 6)
            RaptorTitlebarButton(symbol: "plus", help: "New Tab", action: controller.newTab)
        }
        // The first button sits about 32 pt right of the green traffic light's centre.
        .padding(.leading, 82)
        .padding(.trailing, 14)
        .frame(height: Self.titlebarHeight)
    }
}

/// The window's background: the chrome colour, or the desktop blurred behind the
/// window and tinted with it. Glass is drawn by the window's container.
struct RaptorWindowBackground: View {
    let style: RaptorAppearance.Style
    let tokens: ThemeTokens

    /// How much of the chrome colour covers the blurred desktop.
    static let tint = 0.3

    var body: some View {
        switch style {
        case .solid:
            Color(nsColor: tokens.chrome)
        case .blended:
            ZStack {
                BehindWindowBlur()
                Color(nsColor: tokens.chrome).opacity(Self.tint)
            }
        case .glass:
            Color.clear
        }
    }

    private struct BehindWindowBlur: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.blendingMode = .behindWindow
            view.material = .hudWindow
            view.state = .active
            return view
        }

        func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    }
}

struct RaptorTitlebarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// ponytail: inert until the session switcher lands.
/// The session and the machine it runs on.
struct RaptorSessionItem: View {
    let label: String

    /// The Mac's name, as Sharing in System Settings shows it.
    static let machine = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "This Mac"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(Self.machine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RaptorTabView: View {
    let tab: RaptorController.Tab
    let active: Bool
    let tokens: ThemeTokens
    /// Solid chrome lifts the active tab with an opaque token; the translucent
    /// styles raise a sheet of white over whatever is behind.
    let solid: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            RaptorTileCluster(program: tab.program, others: tab.others)
            // Long titles fade out instead of ending in an ellipsis.
            Text(tab.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? .primary : .secondary)
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
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .frame(minWidth: 80, maxWidth: 220, minHeight: 27, maxHeight: 27)
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

    /// The active tab is a raised capsule. Light themes draw it as chrome with a border.
    @ViewBuilder private var pill: some View {
        if active {
            if tokens.isLight {
                Capsule()
                    .fill(Color(nsColor: tokens.chrome))
                    .overlay(Capsule().strokeBorder(Color(nsColor: tokens.separator)))
            } else if solid {
                Capsule().fill(Color(nsColor: tokens.tabActive))
            } else {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
            }
        }
    }
}
