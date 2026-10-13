import AppKit
import SwiftUI
import GhosttyKit

/// A window showing one rap session: a tab strip of the session's windows and the active
/// one's splits. The server owns the layout; this view follows `session.view`, and every
/// pane is a surface bound to its block.
///
/// Closing the window or quitting only detaches. Closing a pane or tab kills its processes.
class RaptorController: BaseTerminalController {
    let client: RaptorClient
    let session: String

    /// The tabs, in server order.
    @Published private(set) var tabs: [Tab] = []

    /// The session's name.
    @Published private(set) var label = ""

    /// The window id of the tab on show.
    @Published private(set) var activeTab: String?

    struct Tab: Identifiable, Equatable {
        let id: String
        let title: String
    }

    /// Every block's surface, kept across tab switches.
    private var surfaces: [String: Ghostty.SurfaceView] = [:]

    /// The last view the server sent.
    private var view: SessionView?

    /// Block titles, from the view and title_changed events.
    private var titles: [String: String] = [:]

    init(_ ghostty: Ghostty.App, client: RaptorClient, session: String) {
        self.client = client
        self.session = session
        super.init(ghostty, surfaceTree: .init())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        // The tab strip replaces native tabs, and the server replaces state restoration.
        window.tabbingMode = .disallowed
        window.isRestorable = false
        // The tab strip is the title bar, tinted from the terminal background. An empty
        // toolbar centres the traffic lights in a taller title bar.
        let tokens = ThemeTokens(background: NSColor(ghostty.config.backgroundColor))
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "Raptor")
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = tokens.chrome
        window.appearance = NSAppearance(named: tokens.isLight ? .aqua : .darkAqua)
        window.center()
        window.setFrameAutosaveName("Raptor \(session)")
        window.delegate = self
        window.contentView = NSHostingView(rootView: RaptorWindowView(
            ghostty: ghostty,
            controller: self,
            tokens: tokens))
        self.window = window
        windowDidLoad()

        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    // MARK: Server state

    struct SessionView: Decodable {
        let label: String
        let active_window: String
        let windows: [Window]

        struct Window: Decodable {
            let id: String
            let label: String
            let focused_block: String
            let zoomed: String?
            let layout: Layout
            let blocks: [Block]
        }

        struct Block: Decodable {
            let id: String
            let title: String
        }
    }

    indirect enum Layout: Decodable {
        case block(String)
        case split(horizontal: Bool, ratio: Double, a: Layout, b: Layout)

        private enum Keys: String, CodingKey { case type, block, ratio, a, b }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let type = try c.decode(String.self, forKey: .type)
            if type == "block" {
                self = .block(try c.decode(String.self, forKey: .block))
            } else {
                self = .split(
                    horizontal: type == "horizontal",
                    ratio: try c.decode(Double.self, forKey: .ratio),
                    a: try c.decode(Layout.self, forKey: .a),
                    b: try c.decode(Layout.self, forKey: .b))
            }
        }
    }

    /// Fetch the session's view and bring the tabs and splits in line with it.
    func refresh() {
        guard let view: SessionView = client.call("session.view", ["session": session]) else { return }
        self.view = view
        label = view.label
        titleOverride = view.label

        var seen: Set<String> = []
        var trees: [String: SplitTree<Ghostty.SurfaceView>] = [:]
        for w in view.windows {
            for b in w.blocks { titles[b.id] = b.title }
            let root = node(w.layout, seen: &seen)
            let zoomed = w.zoomed.flatMap { surfaces[$0] }.flatMap { root?.node(view: $0) }
            trees[w.id] = SplitTree(root: root, zoomed: zoomed)
        }

        // Blocks that are gone take their surfaces with them.
        for (id, surface) in surfaces where !seen.contains(id) {
            if let s = surface.surface { rap_client_unbind(client.client, s) }
            surfaces[id] = nil
            titles[id] = nil
        }

        updateTabs()
        let switched = activeTab != view.active_window
        activeTab = view.active_window
        let tree = trees[view.active_window] ?? .init()
        if tree.root != surfaceTree.root || tree.zoomed != surfaceTree.zoomed { surfaceTree = tree }

        // Focus the server's focused block when the tab changes or focus was lost.
        if switched || focusedSurface.map({ !tree.contains($0) }) ?? true,
           let w = view.windows.first(where: { $0.id == view.active_window }),
           let target = surfaces[w.focused_block] {
            DispatchQueue.main.async { Ghostty.moveFocus(to: target) }
        }
    }

    private func node(_ layout: Layout, seen: inout Set<String>) -> SplitTree<Ghostty.SurfaceView>.Node? {
        switch layout {
        case .block(let id):
            guard let surface = surface(for: id) else { return nil }
            seen.insert(id)
            return .leaf(view: surface)
        case .split(let horizontal, let ratio, let a, let b):
            let left = node(a, seen: &seen)
            let right = node(b, seen: &seen)
            guard let left else { return right }
            guard let right else { return left }
            return .split(.init(
                direction: horizontal ? .horizontal : .vertical,
                ratio: ratio,
                left: left,
                right: right))
        }
    }

    /// The block's surface, made and bound on first sight.
    private func surface(for block: String) -> Ghostty.SurfaceView? {
        if let surface = surfaces[block] { return surface }
        guard let app = ghostty.app else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.rapClient = client.client
        let view = Ghostty.SurfaceView(
            app,
            baseConfig: config,
            uuid: UUID(uuidString: String(block.dropFirst("block:".count))))
        guard let surface = view.surface else { return nil }
        // Bind at the size the pane will likely get rather than the view's placeholder:
        // a program starting in the block reads its size before a later resize lands.
        // ponytail: a new split still starts at the whole area; size it from the layout if that bites.
        let size = surfaceTree.isEmpty ? (window?.contentLayoutRect.size ?? .zero) : surfaceTree.viewBounds()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if size.width > 0 && size.height > 0 {
            ghostty_surface_set_size(surface, UInt32(size.width * scale), UInt32(size.height * scale))
        }
        guard rap_client_bind(client.client, block, surface) else { return nil }
        surfaces[block] = view
        return view
    }

    private func updateTabs() {
        guard let view else { return }
        tabs = view.windows.map { w in
            let title = titles[w.focused_block] ?? ""
            return Tab(id: w.id, title: title.isEmpty ? w.label : title)
        }
    }

    // MARK: Events

    func titleChanged(block: String, to title: String) {
        guard titles[block] != nil else { return }
        titles[block] = title
        updateTabs()
    }

    /// The session ended, so there is nothing left to show.
    func sessionDestroyed() {
        window?.close()
    }

    // MARK: Actions

    func newTab() {
        client.call("session.new_window", ["session": session])
    }

    func selectTab(_ id: String) {
        client.call("session.focus", ["session": session, "window": id])
    }

    func closeTab(_ id: String) {
        guard let w = view?.windows.first(where: { $0.id == id }) else { return }
        confirmKill(w.blocks.map(\.id), messageText: "Close Tab?") { [weak self] in
            guard let self else { return }
            self.client.call("session.close_window", ["session": self.session, "window": id])
        }
    }

    /// Closing a pane kills its block; the server's next view removes it.
    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        let blocks = node.leaves().compactMap { leaf in surfaces.first { $0.value === leaf }?.key }
        confirmKill(blocks, messageText: "Close Pane?") { [weak self] in
            blocks.forEach { self?.client.call("block.close", ["block": $0]) }
        }
    }

    /// New splits are made by the server, so they show up as blocks of the session.
    override func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        guard let block = surfaces.first(where: { $0.value === oldView })?.key else { return nil }
        // ponytail: the server splits only right and down; left and up map onto them.
        let dir = direction == .right || direction == .left ? "right" : "down"
        client.call("session.new_split", ["session": session, "block": block, "direction": dir])
        return nil
    }

    private struct BlockProcess: Decodable {
        struct Foreground: Decodable { let pid: Int }
        let pid: Int
        let foreground: Foreground?
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh"]

    // ponytail: reads the process name locally, which holds while the server is on this Mac.
    /// True if the block's foreground program is something other than a shell.
    private func isBusy(_ block: String) -> Bool {
        guard let p: BlockProcess = client.call("block.method", ["block": block, "method": "process"]) else { return false }
        var name = [CChar](repeating: 0, count: 256)
        // proc_name fails (EPERM) for setuid programs such as top or sudo; shells are never setuid.
        guard proc_name(Int32(p.foreground?.pid ?? p.pid), &name, UInt32(name.count)) > 0 else { return true }
        return !Self.shells.contains(String(cString: name))
    }

    /// Run `kill`, after asking first if any of the blocks runs something besides a shell.
    private func confirmKill(_ blocks: [String], messageText: String, kill: @escaping () -> Void) {
        let busy = blocks.contains(where: isBusy)
        guard busy else { return kill() }
        confirmClose(
            messageText: messageText,
            informativeText: "A process is still running. Closing will kill it.",
            completion: kill)
    }

    // MARK: NSWindowDelegate

    /// The window closed: detach, leaving the session and its processes running.
    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        for surface in surfaces.values {
            if let s = surface.surface { rap_client_unbind(client.client, s) }
        }
        surfaces = [:]
        surfaceTree = .init()
        client.closed(self)
    }
}

/// The title bar, holding the session item and the tab strip, above the active tab's splits.
struct RaptorWindowView: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var controller: RaptorController
    let tokens: ThemeTokens

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
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
                        select: { controller.selectTab(tab.id) },
                        close: { controller.closeTab(tab.id) })
                }
                Spacer(minLength: 8)
                Button(action: controller.newTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Tab")
            }
            // The session item sits 40 pt right of the green traffic light's centre.
            .padding(.leading, 104)
            .padding(.trailing, 14)
            .frame(height: Self.titlebarHeight)
            .background(Color(nsColor: tokens.chrome))

            Rectangle()
                .fill(Color(nsColor: tokens.hairline))
                .frame(height: 1)

            TerminalView(ghostty: ghostty, viewModel: controller, delegate: controller)
                .environment(\.splitDividerColor, Color(nsColor: tokens.hairline))
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    static let titlebarHeight: CGFloat = 40
}

// ponytail: inert until the session switcher lands.
/// The session and the machine it runs on.
struct RaptorSessionItem: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("This Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RaptorTabView: View {
    let tab: RaptorController.Tab
    let active: Bool
    let tokens: ThemeTokens
    let select: () -> Void
    let close: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(">_")
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.5))
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(red: 0x3B / 255, green: 0x5C / 255, blue: 0x3E / 255)))
            // Long titles fade out instead of ending in an ellipsis.
            Text(tab.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Dark themes lift the active tab; light themes draw it as chrome with a border.
    @ViewBuilder private var pill: some View {
        if active {
            Capsule()
                .fill(Color(nsColor: tokens.isLight ? tokens.chrome : tokens.tabActive))
                .overlay(Capsule().strokeBorder(Color(nsColor: tokens.isLight ? tokens.separator : .clear)))
        }
    }
}
