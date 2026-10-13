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

    var body: some View {
        let islands = appearance.density == .islands
        let tokens = ThemeTokens(background: NSColor(ghostty.config.backgroundColor))
        // The surface draws the terminal background at the configured opacity; the
        // header matches it so the card reads as one piece. Under glass the surface
        // draws none, leaving it to the card.
        let glass = ghostty.config.backgroundBlur.isGlassStyle
        let paneFill = Color(nsColor: NSColor(ghostty.config.backgroundColor))
            .opacity(ghostty.config.backgroundOpacity)
        let focused = controller.focusedPane === surface
        let block = controller.block(of: surface).flatMap { controller.blocks[$0] } ?? .init()

        VStack(spacing: 0) {
            if appearance.paneHeaders {
                RaptorPaneHeader(
                    block: block,
                    single: controller.isSinglePane,
                    split: { controller.split(surface, $0) },
                    zoom: { controller.zoom(surface) },
                    close: { controller.close(surface) })
                    .frame(height: islands ? 33 : 34)
                    // Compact headers of unfocused panes show the chrome behind them.
                    .background(islands || focused ? paneFill : .clear)
            }
            content
                .background(glass ? paneFill : .clear)
        }
        .clipShape(RoundedRectangle(cornerRadius: islands ? Self.islandRadius : 0))
        .overlay {
            if islands {
                RoundedRectangle(cornerRadius: Self.islandRadius)
                    .strokeBorder(Color(nsColor: tokens.islandBorder), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The program's icon and title, with split, zoom and close buttons.
struct RaptorPaneHeader: View {
    let block: RaptorController.Block
    /// The pane is its tab's only one, so it can't be closed from here.
    let single: Bool
    let split: (SplitTree<Ghostty.SurfaceView>.NewDirection) -> Void
    let zoom: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            RaptorProgramIcon(icon: block.program.icon, size: 16)
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
        }
        .padding(.leading, 12)
        // The buttons' 16 pt glyphs on a 24 pt pitch end 17 pt from the edge.
        .padding(.trailing, 13)
        .foregroundStyle(.primary)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
