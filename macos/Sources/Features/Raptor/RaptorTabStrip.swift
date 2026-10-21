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
    /// The other tabs slide aside, and a dropped tab settles, with this spring.
    static let slide = Animation.spring(response: 0.25, dampingFraction: 0.85)

    /// A tab dragged along the strip, as native tabs are: it follows the pointer by `dx`
    /// and the others slide aside to show where it will land.
    struct Drag: Equatable {
        let id: String
        var dx: CGFloat
    }

    @State private var drag: Drag?
    /// Each tab's width. Widths, not frames: a frame measured here would move with the
    /// offset a drag gives it.
    @State private var widths: [String: CGFloat] = [:]

    var body: some View {
        let reorder = drag.flatMap(reorder(_:))
        HStack(spacing: 0) {
            ForEach(Array(controller.tabs.enumerated()), id: \.element.id) { i, tab in
                let active = tab.id == controller.activeTab
                if i > 0 {
                    let prevActive = controller.tabs[i - 1].id == controller.activeTab
                    Rectangle()
                        .fill(divider)
                        .frame(width: 1, height: 17)
                        // Dividers would stay put under sliding tabs.
                        .opacity(active || prevActive || drag != nil ? 0 : 1)
                }
                let dragged = drag?.id == tab.id
                let offset = reorder.map { $0.offset(of: i, drag?.dx ?? 0) } ?? 0
                RaptorTabView(
                    tab: tab,
                    active: active,
                    tokens: tokens,
                    select: { controller.selectTab(tab.id) },
                    close: { controller.closeTab(tab.id) },
                    slide: { slide(tab.id, by: $0?.width) })
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: TabWidths.self, value: [tab.id: geo.size.width])
                    })
                    // The dragged tab hides the ones it passes over.
                    .background(ZStack {
                        Capsule().fill(Color(nsColor: tokens.chrome))
                        Capsule().fill(track)
                    }.opacity(dragged ? 1 : 0))
                    .offset(x: offset)
                    // The dragged tab keeps up with the pointer; the others slide.
                    .animation(dragged ? nil : Self.slide, value: offset)
                    .zIndex(dragged ? 1 : 0)
            }
        }
        .onPreferenceChange(TabWidths.self) { widths = $0 }
        .padding(.horizontal, 2)
        .frame(height: Self.trackHeight)
        .background(Capsule().fill(track))
        .offset(y: Self.trackDrop)
    }

    /// The strip as a row the dragged tab moves along, the tabs 1 pt apart for the
    /// dividers between them.
    private func reorder(_ drag: Drag) -> RaptorReorder? {
        guard let from = controller.tabs.firstIndex(where: { $0.id == drag.id }) else { return nil }
        return RaptorReorder(lengths: controller.tabs.map { widths[$0.id] ?? 0 }, gap: 1, from: from)
    }

    /// Follow the pointer with a dragged tab, kept on the track; nil drops it in its new
    /// place, which shows at once and is sent to the server.
    private func slide(_ id: String, by dx: CGFloat?) {
        guard let dx else {
            guard let drag, let reorder = reorder(drag) else { return }
            let to = reorder.destination(drag.dx)
            withAnimation(Self.slide) {
                if to != reorder.from { controller.moveTab(drag.id, onto: controller.tabs[to].id) }
                self.drag = nil
            }
            return
        }
        guard let reorder = reorder(Drag(id: id, dx: 0)) else { return }
        drag = Drag(id: id, dx: reorder.clamp(dx))
    }

    private struct TabWidths: PreferenceKey {
        static var defaultValue: [String: CGFloat] = [:]
        static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
            value.merge(nextValue()) { $1 }
        }
    }

    /// The track and dividers lift the chrome on dark themes and darken it on light ones.
    private var track: Color { tokens.isLight ? .black.opacity(0.04) : .white.opacity(0.07) }
    private var divider: Color { tokens.isLight ? Color(nsColor: tokens.separator) : .white.opacity(0.2) }
}

/// One item of a row dragged along it, as native tabs are: how far the others slide to
/// make room, and where it lands. `lengths` run along the row in order, `gap` apart.
struct RaptorReorder {
    let lengths: [CGFloat]
    var gap: CGFloat = 0
    let from: Int

    private func start(_ i: Int) -> CGFloat { lengths[..<i].reduce(0) { $0 + $1 + gap } }

    /// A drag of `d`, kept within the row.
    func clamp(_ d: CGFloat) -> CGFloat {
        let end = start(lengths.count) - gap
        return min(max(d, -start(from)), end - start(from) - lengths[from])
    }

    /// Where the dragged item lands: past every item whose middle its leading edge has
    /// crossed, so even the longest item reaches either end.
    func destination(_ d: CGFloat) -> Int {
        let lead = start(from) + d, trail = lead + lengths[from]
        var to = from
        for i in lengths.indices {
            let middle = start(i) + lengths[i] / 2
            if i > from, trail > middle { to += 1 }
            if i < from, lead < middle { to -= 1 }
        }
        return to
    }

    /// How far item `i` is drawn from its place: the dragged one by the drag, the ones
    /// it has passed by its length and the gap, to make room.
    func offset(of i: Int, _ d: CGFloat) -> CGFloat {
        if i == from { return d }
        let to = destination(d)
        if from < i, i <= to { return -(lengths[from] + gap) }
        if to <= i, i < from { return lengths[from] + gap }
        return 0
    }
}

struct RaptorTabView: View {
    let tab: RaptorController.Tab
    let active: Bool
    let tokens: ThemeTokens
    let select: () -> Void
    let close: () -> Void
    /// This tab dragged by so much, nil when it's let go.
    let slide: (CGSize?) -> Void

    @State private var hovering = false

    /// A tab's title as the program's name and, after it, the working directory, which
    /// is drawn dimmer. Titles that don't start with the name (an agent's) are all name.
    static func titleParts(_ title: String, program: String) -> (name: String, path: String) {
        guard title.hasPrefix(program + " ") else { return (title, "") }
        return (program, String(title.dropFirst(program.count)))
    }

    /// Whether a window's label is the one rap gave it ("Primary", else "Window" and its
    /// id's last 8 characters) rather than a name from Rename Tab.
    /// ponytail: a tab renamed to exactly its default reads as unnamed; a flag from the
    /// server would settle it.
    static func isDefaultLabel(_ label: String?, window id: String) -> Bool {
        guard let label, !label.isEmpty else { return true }
        return label == "Primary" || label == "Window \(id.suffix(8))"
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
                .fadeTruncated()
            if hovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.raptor)
                .help("Close Tab")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(minWidth: 48, maxWidth: RaptorTabStrip.tabWidth, minHeight: RaptorTabStrip.tabHeight, maxHeight: RaptorTabStrip.tabHeight)
        .background(pill)
        .contentShape(Capsule())
        // The close button, while it shows, keeps its clicks.
        .overlay(RaptorTabHandle(passThrough: hovering ? 26 : 0, select: select, slide: slide) { hovering = $0 })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityAction(named: "Close Tab", close)
    }

    /// The active tab is a raised capsule on the track. Light themes draw it as chrome
    /// with a border. An inactive tab under the pointer gets a faint plate instead.
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
        } else if hovering {
            Capsule().fill(Color.primary.opacity(0.08))
        }
    }
}

/// Takes a tab's clicks and drags, and says when the pointer is over it. An AppKit
/// view, as Ghostty's pane grab handles are: in the title bar a SwiftUI drag moves the
/// window instead.
struct RaptorTabHandle: NSViewRepresentable {
    /// Points at the trailing edge left to the SwiftUI below, such as a close button.
    var passThrough: CGFloat = 0
    let select: () -> Void
    /// How far the tab has been dragged, x right and y down, then nil when let go.
    let slide: (CGSize?) -> Void
    let hover: (Bool) -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.passThrough = passThrough
        view.select = select
        view.slide = slide
        view.hover = hover
    }

    final class HandleView: NSView {
        var passThrough: CGFloat = 0
        var select: () -> Void = {}
        var slide: (CGSize?) -> Void = { _ in }
        var hover: (Bool) -> Void = { _ in }
        /// Where the button went down.
        private var downAt: NSPoint?
        /// The pointer has moved far enough from `downAt` to be a drag, not a click.
        private var sliding = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            convert(point, from: superview).x > bounds.maxX - passThrough ? nil : super.hitTest(point)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self))
        }

        // The title bar moves the window on a drag before any view sees it, so the
        // window holds still while the pointer is over a tab.
        override func mouseEntered(with event: NSEvent) { pointer(inside: true) }
        override func mouseExited(with event: NSEvent) { pointer(inside: false) }

        private func pointer(inside: Bool) {
            window?.isMovable = !inside
            hover(inside)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            window?.isMovable = true
            super.viewWillMove(toWindow: newWindow)
        }

        override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

        override func mouseUp(with event: NSEvent) {
            if sliding {
                slide(nil)
                // The tab moved with the pointer, so enters and exits went astray.
                pointer(inside: bounds.contains(convert(event.locationInWindow, from: nil)))
            } else if downAt != nil {
                select()
            }
            downAt = nil
            sliding = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let downAt else { return }
            let d = CGSize(width: event.locationInWindow.x - downAt.x, height: downAt.y - event.locationInWindow.y)
            guard sliding || hypot(d.width, d.height) > 3 else { return }
            sliding = true
            slide(d)
        }
    }
}
