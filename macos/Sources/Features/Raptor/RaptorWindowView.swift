import AppKit
import SwiftUI
import SystemConfiguration

/// The active tab's panes, islands (cards with the chrome between them) or compact
/// (1 px dividers), beside the sidebar or under the title bar of the session item and
/// the tab strip. With the sidebar the cards start at the traffic lights' row, as in Rex.
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
        let sidebar = appearance.sidebar
        HStack(spacing: 0) {
            if sidebar {
                RaptorSidebar(model: controller.client.sidebar, controller: controller, appearance: appearance, tokens: tokens)
                if !islands {
                    Rectangle()
                        .fill(Color(nsColor: tokens.hairline))
                        .frame(width: 1)
                }
            }
            VStack(spacing: 0) {
                if !sidebar {
                    titlebar(tokens)
                    if !islands {
                        Rectangle()
                            .fill(Color(nsColor: tokens.hairline))
                            .frame(height: 1)
                    }
                }
                panes(tokens)
            }
        }
        .backgroundPreferenceValue(RaptorPaneFrames.self) { panes in
            GeometryReader { proxy in
                RaptorWindowBackground(
                    style: appearance.effectiveStyle,
                    tokens: tokens,
                    panes: panes.map { proxy[$0] },
                    paneRadius: islands ? RaptorPane.islandRadius : 0)
            }
        }
        .overlay(alignment: .top) {
            if controller.commandPaletteIsShowing {
                RaptorCommandPalette(
                    isPresented: $controller.commandPaletteIsShowing,
                    makeCommands: { controller.paletteCommands },
                    tokens: tokens,
                    accent: Color(nsColor: RaptorCommandPalette.accent(ghostty.config)))
                    .padding(.top, Self.paletteTop)
            }
        }
        .overlay(alignment: .topLeading) {
            if controller.sessionPopoverIsShowing {
                RaptorSessionPopover(controller: controller, isPresented: $controller.sessionPopoverIsShowing, tokens: tokens)
                    .padding(.leading, 72)
                    .padding(.top, Self.titlebarHeight + 2)
            }
        }
        .onChange(of: controller.commandPaletteIsShowing || controller.sessionPopoverIsShowing) { showing in
            // Give the keyboard back to the pane, unless a command already moved it.
            guard !showing else { return }
            DispatchQueue.main.async {
                guard let window = controller.window, !(window.firstResponder is Ghostty.SurfaceView),
                      let pane = controller.focusedPane else { return }
                Ghostty.moveFocus(to: pane)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private func panes(_ tokens: ThemeTokens) -> some View {
        TerminalView(ghostty: ghostty, viewModel: controller, delegate: controller)
            .environment(\.terminalCommandPalette, false)
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
            // as in Rex; beside the sidebar they start at its edge.
            .padding(.top, islands ? (appearance.sidebar ? Self.islandInset : Self.islandInset - 2) : 0)
            .padding(.leading, islands && !appearance.sidebar ? Self.islandInset : 0)
            .padding([.trailing, .bottom], islands ? Self.islandInset : 0)
    }

    /// The palette's top edge below the window's, as in Rex: 36 pt under the title bar.
    static let paletteTop: CGFloat = 76

    private func titlebar(_ tokens: ThemeTokens) -> some View {
        HStack(spacing: 0) {
            RaptorTitlebarButton(symbol: "sidebar.left", help: "Show Sidebar ⌃⌘S") {
                appearance.sidebar = true
            }
            .padding(.trailing, 6)
            Button { controller.sessionPopoverIsShowing.toggle() } label: {
                RaptorSessionItem(label: controller.label)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change Session ⌘K")
            .padding(.trailing, 20)
            RaptorTabStrip(controller: controller, tokens: tokens)
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
/// window (Blended) or seen through the container's glass (Glass) and tinted with it.
/// The tint stops at the panes, which draw the theme background at the same opacity
/// over the same blur or glass, so their bodies let the desktop through just as the
/// chrome does.
struct RaptorWindowBackground: View {
    let style: RaptorAppearance.Style
    let tokens: ThemeTokens
    /// The panes' cards, in this view's coordinates.
    var panes: [CGRect] = []
    var paneRadius: CGFloat = 0

    /// How much of the chrome colour covers the blurred desktop.
    static let tint = 0.3

    var body: some View {
        switch style {
        case .solid:
            Color(nsColor: tokens.chrome)
        case .blended:
            ZStack {
                BehindWindowBlur()
                chromeTint
            }
        case .glass:
            chromeTint
        }
    }

    /// The chrome colour everywhere but the panes.
    private var chromeTint: some View {
        GeometryReader { proxy in
            Path { path in
                path.addRect(CGRect(origin: .zero, size: proxy.size))
                for pane in panes {
                    path.addRoundedRect(in: pane, cornerSize: CGSize(width: paneRadius, height: paneRadius))
                }
            }
            .fill(Color(nsColor: tokens.chrome).opacity(Self.tint), style: FillStyle(eoFill: true))
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
        // The tabs shrink before the session's name does.
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
