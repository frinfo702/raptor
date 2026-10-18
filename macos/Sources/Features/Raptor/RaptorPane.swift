import AppKit
import SwiftUI

/// One pane: its surface under an optional header, and in islands density a rounded
/// card with a 1 px border.
struct RaptorPane: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var controller: RaptorController
    @ObservedObject var appearance: RaptorAppearance
    let surface: Ghostty.SurfaceView
    let content: AnyView

    static let islandRadius: CGFloat = 10

    /// How much of the chrome colour covers an unfocused compact header in Blended and
    /// Glass, where the pane body lets the desktop through as the chrome does.
    static let unfocusedHeaderOpacity = 0.7

    /// The rim of an island in Blended and Glass: as in Rex, a glassy edge that lifts
    /// whatever shows through the card (about +35/255 on Rex's dark frames), so it
    /// takes the desktop's colour rather than a fixed one.
    static func sheen(light: Bool) -> Color {
        light ? .black.opacity(0.1) : .white.opacity(0.15)
    }

    var body: some View {
        let islands = appearance.density == .islands
        let tokens = ThemeTokens(background: NSColor(ghostty.config.backgroundColor))
        // The surface draws the terminal background at the configured opacity; the
        // header matches it so the card reads as one piece. Under glass the surface
        // draws none, leaving it to the card.
        let glass = ghostty.config.backgroundBlur.isGlassStyle
        let paneFill = Color(nsColor: NSColor(ghostty.config.backgroundColor))
            .opacity(ghostty.config.backgroundOpacity)
        // The window's chrome tint stops at the card, so an unfocused compact header
        // draws the chrome itself (Solid's opaque window already shows it), denser than
        // the translucent body so it still reads as unfocused.
        let chromeFill = appearance.effectiveStyle == .solid ? .clear
            : Color(nsColor: tokens.chrome).opacity(Self.unfocusedHeaderOpacity)
        let focused = controller.focusedPane === surface
        let block = controller.block(of: surface).flatMap { controller.blocks[$0] } ?? .init()

        VStack(spacing: 0) {
            if appearance.paneHeaders {
                RaptorPaneHeader(
                    block: block,
                    single: controller.isSinglePane,
                    focused: focused,
                    light: tokens.isLight,
                    split: { controller.split(surface, $0) },
                    zoom: { controller.zoom(surface) },
                    close: { controller.close(surface) })
                    .frame(height: islands ? 33 : 34)
                    // Compact headers of unfocused panes show the chrome behind them.
                    .background(islands || focused ? paneFill : chromeFill)
            }
            content
                .background(glass ? paneFill : .clear)
        }
        .clipShape(RoundedRectangle(cornerRadius: islands ? Self.islandRadius : 0))
        .anchorPreference(key: RaptorPaneFrames.self, value: .bounds) { [$0] }
        .overlay {
            if islands {
                RoundedRectangle(cornerRadius: Self.islandRadius)
                    .strokeBorder(appearance.effectiveStyle == .solid ? Color(nsColor: tokens.islandBorder)
                        : Self.sheen(light: tokens.isLight), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The panes' cards, for the window background to leave untinted.
struct RaptorPaneFrames: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

/// The program's icon and title, with split, zoom and close buttons.
struct RaptorPaneHeader: View {
    let block: RaptorController.Block
    /// The pane is its tab's only one, so it can't be closed from here.
    let single: Bool
    /// Unfocused panes show their buttons only while the pointer is over the header.
    let focused: Bool
    /// Picks the program logo's light-theme art.
    let light: Bool
    let split: (SplitTree<Ghostty.SurfaceView>.NewDirection) -> Void
    let zoom: () -> Void
    let close: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            RaptorProgramIcon(icon: block.program.icon, size: 16, light: light)
                .frame(width: 16, height: 16)
            Text(block.headerTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                button("rectangle.split.2x1", "Split Right") { split(.right) }
                button("rectangle.split.1x2", "Split Down") { split(.down) }
                button("arrow.up.left.and.arrow.down.right", "Zoom", action: zoom)
                button("xmark", "Close Pane", action: close)
                    .disabled(single)
                    .opacity(single ? 0.35 : 1)
            }
            .opacity(focused || hovering ? 1 : 0)
            .allowsHitTesting(focused || hovering)
        }
        .padding(.leading, 12)
        // The buttons' 16 pt glyphs on a 24 pt pitch end 17 pt from the edge.
        .padding(.trailing, 13)
        .foregroundStyle(.primary)
        // Hover over the header's full height, not just its glyphs.
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.raptor)
        .help(help)
        .accessibilityLabel(help)
    }
}
