import AppKit
import Combine
import SwiftUI
import GhosttyKit

/// A window showing one rap session: a tab strip of the session's windows and the active
/// one's splits. The server owns the layout; this view follows `session.view`, and every
/// pane is a surface bound to its block.
///
/// Several windows can show one session; they follow the server, so they stay in step.
/// Closing the window or quitting only detaches. Closing a pane or tab kills its processes.
class RaptorController: BaseTerminalController {
    let client: RaptorClient
    /// The connection the panes' surfaces are bound through, this window's own.
    let stream: rap_client_t
    @Published private(set) var session: String

    /// The session switcher under the session item.
    @Published var sessionPopoverIsShowing = false

    /// The tabs, in server order.
    @Published private(set) var tabs: [Tab] = []

    /// The session's name.
    @Published private(set) var label = ""

    /// The window id of the tab on show.
    @Published private(set) var activeTab: String?

    struct Tab: Identifiable, Equatable {
        let id: String
        /// The name given with Rename Tab, else the focused pane's title.
        let title: String
        /// The focused pane's program, then the others'.
        let program: RaptorProgram
        let others: [RaptorProgram]
    }

    /// What a pane's header shows about its block.
    struct Block: Equatable {
        var title = ""
        var pwd = ""
        /// The foreground process's name, nil until known.
        var process: String?

        var program: RaptorProgram { RaptorProgram.identify(process) ?? .shell }
        var headerTitle: String { RaptorProgram.title(process: process, terminalTitle: title, pwd: pwd) }
    }

    /// Every block's surface, kept across tab switches.
    private var surfaces: [String: Ghostty.SurfaceView] = [:]

    /// The last view the server sent.
    private var view: SessionView?

    /// The session whose panes are bound, which a switch replaces once its view arrives.
    private var shown: String

    /// Blocks by id, from the view and the server's events.
    @Published private(set) var blocks: [String: Block] = [:]

    /// The pane last focused, whose header is drawn as focused.
    @Published private(set) var focusedPane: Ghostty.SurfaceView?

    private var styleObservers: Set<AnyCancellable> = []

    init(_ ghostty: Ghostty.App, client: RaptorClient, stream: rap_client_t, session: String) {
        self.client = client
        self.stream = stream
        self.session = session
        self.shown = session
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
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "Raptor")
        window.toolbarStyle = .unifiedCompact
        window.center()
        window.setFrameAutosaveName("Raptor \(session)")
        window.delegate = self
        // The container draws Glass behind the views when the config asks for it.
        window.contentView = TerminalViewContainer {
            RaptorWindowView(ghostty: ghostty, controller: self, appearance: .shared)
        }
        self.window = window
        windowDidLoad()

        // Restyle the window when the theme or interface style changes. Both publish
        // before they change, so look again on the next turn of the run loop.
        Publishers.Merge(
            ghostty.$config.map { _ in () },
            RaptorAppearance.shared.objectWillChange.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyStyle() }
            .store(in: &styleObservers)
        applyStyle()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(onGotoTab), name: Ghostty.Notification.ghosttyGotoTab, object: nil)
        center.addObserver(self, selector: #selector(onCloseTab), name: .ghosttyCloseTab, object: nil)
        center.addObserver(self, selector: #selector(onCloseWindow), name: .ghosttyCloseWindow, object: nil)
        center.addObserver(self, selector: #selector(onToggleZoom), name: Ghostty.Notification.didToggleSplitZoom, object: nil)

        refresh()

        // Scripted screenshots open the palette (with RAPTOR_PALETTE_QUERY as its query)
        // or the session switcher (RAPTOR_SESSIONS=1) once the window is up.
        let env = ProcessInfo.processInfo.environment
        if env["RAPTOR_PALETTE_QUERY"] != nil || env["RAPTOR_SESSIONS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.commandPaletteIsShowing = env["RAPTOR_PALETTE_QUERY"] != nil
                self?.sessionPopoverIsShowing = env["RAPTOR_SESSIONS"] == "1"
            }
        }
    }

    /// Make the window opaque for Solid, see-through for Blended and Glass.
    private func applyStyle() {
        guard let window else { return }
        let tokens = ThemeTokens(background: NSColor(ghostty.config.backgroundColor))
        let solid = RaptorAppearance.shared.effectiveStyle == .solid
        window.appearance = NSAppearance(named: tokens.isLight ? .aqua : .darkAqua)
        window.isOpaque = solid
        window.backgroundColor = solid ? tokens.chrome : .clear
        // The glass itself is untinted, whatever background-opacity says: the window
        // background tints the chrome around the panes as it does Blended's blur.
        terminalViewContainer?.ghosttyConfigDidChange(
            ghostty.config,
            preferredBackgroundColor: tokens.chrome,
            glassTint: 0)
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
            let label: String?
            let focused_block: String
            let zoomed: String?
            /// The block whose program made this window, if one did.
            let parent: String?
            let layout: Layout
            let blocks: [Block]
        }

        struct Block: Decodable {
            let id: String
            let title: String
            let pwd: String?
            /// What the block's program last said it is doing.
            let status: Status?
        }

        struct Status: Decodable, Equatable {
            let state: String
            let msg: String?
            /// Wall-clock milliseconds.
            let updated_at: Int64
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

    /// Fetch the session's view off the main thread, then bring the tabs and splits in
    /// line with it.
    func refresh() {
        let session = session
        let known = Set(blocks.filter { $0.value.process != nil }.keys)
        client.request({ $0.view(session, known: known) }, done: { [weak self] fetched in
            // A closed window, or one that has moved to another session, has no use for it.
            guard let self, let fetched, self.session == session,
                  self.client.controllers.contains(where: { $0 === self }) else { return }
            self.apply(fetched.view, processes: fetched.processes)
        })
    }

    private func apply(_ view: SessionView, processes: [String: String]) {
        if shown != session {
            unbindAll()
            shown = session
        }
        let focusedBefore = self.view?.windows.first { $0.id == view.active_window }?.focused_block
        self.view = view
        label = view.label
        titleOverride = view.label

        var seen: Set<String> = []
        var trees: [String: SplitTree<Ghostty.SurfaceView>] = [:]
        for w in view.windows {
            for b in w.blocks {
                var block = blocks[b.id] ?? Block()
                block.title = b.title
                block.pwd = Self.path(b.pwd ?? "")
                if block.process == nil { block.process = processes[b.id] }
                if blocks[b.id] != block { blocks[b.id] = block }
            }
            let root = node(w.layout, seen: &seen)
            let zoomed = w.zoomed.flatMap { surfaces[$0] }.flatMap { root?.node(view: $0) }
            trees[w.id] = SplitTree(root: root, zoomed: zoomed)
        }

        // Blocks that are gone take their surfaces with them.
        for (id, surface) in surfaces where !seen.contains(id) {
            if let s = surface.surface { rap_client_unbind(stream, s) }
            surfaces[id] = nil
        }
        for id in blocks.keys where !seen.contains(id) { blocks[id] = nil }

        updateTabs()
        let switched = activeTab != view.active_window
        activeTab = view.active_window
        let tree = trees[view.active_window] ?? .init()
        let reshaped = tree.root != surfaceTree.root || tree.zoomed != surfaceTree.zoomed
        if reshaped {
            applyingView = true
            surfaceTree = tree
            applyingView = false
        }

        // Focus the server's focused block when the tab changes, the server moves focus
        // (a new split, from here or elsewhere), or focus was lost. A reshaped tree
        // counts too: removing a pane leaves the window itself as first responder.
        if let w = view.windows.first(where: { $0.id == view.active_window }),
           switched || reshaped || w.focused_block != focusedBefore || focusedSurface.map({ !tree.contains($0) }) ?? true,
           let target = surfaces[w.focused_block] {
            if window?.isKeyWindow != true,
               client.controllers.contains(where: { $0 !== self && $0.session == session }) {
                if (window?.firstResponder as? Ghostty.SurfaceView).map({ !tree.contains($0) }) ?? true {
                    focusedPane = target
                    window?.initialFirstResponder = target
                }
                return
            }
            // The header shows it even while the window isn't key.
            focusedPane = target
            // A window made key with nothing focused focuses its first key view, the
            // first pane, which would move the server's focus there before ours lands.
            window?.initialFirstResponder = target
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
        config.rapClient = stream
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
        guard rap_client_bind(stream, block, surface) else { return nil }
        surfaces[block] = view
        return view
    }

    private func updateTabs() {
        guard let view else { return }
        tabs = view.windows.map { Self.tab($0, blocks: blocks) }
    }

    /// A window as a tab: named for its focused pane unless it was renamed.
    static func tab(_ w: SessionView.Window, blocks: [String: Block]) -> Tab {
        let focused = blocks[w.focused_block] ?? Block()
        let others = w.blocks.filter { $0.id != w.focused_block }.map { (blocks[$0.id] ?? Block()).program }
        return Tab(
            id: w.id,
            title: RaptorTabView.isDefaultLabel(w.label, window: w.id) ? focused.headerTitle : w.label ?? "",
            program: focused.program,
            others: others)
    }

    /// Set while the tree is the server's, so its ratios aren't sent back to it.
    private var applyingView = false

    /// Splits resized here (a dragged divider, a resize key, equalizing) resize on the
    /// server, whose next view would otherwise put the old ratios back.
    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)
        guard !applyingView, let old = from.root, let new = to.root, old.leaves() == new.leaves() else { return }
        sendRatios(old, new)
    }

    private func sendRatios(_ old: SplitTree<Ghostty.SurfaceView>.Node, _ new: SplitTree<Ghostty.SurfaceView>.Node) {
        guard case .split(let o) = old, case .split(let n) = new, o.direction == n.direction else { return }
        if o.ratio != n.ratio,
           let a = block(of: n.left.leftmostLeaf()),
           let b = block(of: n.right.leftmostLeaf()) {
            client.send("session.resize_split", ["session": session, "block": a, "target": b, "ratio": n.ratio])
        }
        sendRatios(o.left, n.left)
        sendRatios(o.right, n.right)
    }

    /// The block shown by a surface.
    func block(of surface: Ghostty.SurfaceView) -> String? {
        surfaces.first(where: { $0.value === surface })?.key
    }

    /// True if the active tab has a single pane.
    var isSinglePane: Bool { !surfaceTree.isSplit }

    // MARK: Events

    func titleChanged(block: String, to title: String) {
        guard blocks[block] != nil else { return }
        blocks[block]?.title = title
        updateTabs()
    }

    func pwdChanged(block: String, to pwd: String) {
        guard blocks[block] != nil else { return }
        blocks[block]?.pwd = Self.path(pwd)
        updateTabs()
    }

    func processChanged(block: String, to name: String?) {
        guard blocks[block] != nil else { return }
        blocks[block]?.process = name
        updateTabs()
    }

    /// Shells report their directory as a URL (OSC 7): file://host/path, or zsh's and
    /// fish's kitty-shell-cwd://host/path. Headers show its path.
    static func path(_ pwd: String) -> String {
        guard let scheme = pwd.range(of: "://"),
              let slash = pwd[scheme.upperBound...].firstIndex(of: "/") else { return pwd }
        let path = String(pwd[slash...])
        // file URLs are percent-encoded; kitty-shell-cwd ones are sent raw.
        return pwd.hasPrefix("file://") ? path.removingPercentEncoding ?? path : path
    }

    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)
        if let to, to !== focusedPane { focusedPane = to }
        // Keep the server's focused block on the pane the user picked, so its own focus
        // moves (closing a pane, zooming) start from there.
        if let to, let block = block(of: to),
           let w = view?.windows.first(where: { $0.id == view?.active_window }),
           w.focused_block != block {
            client.send("session.focus", ["session": session, "block": block])
        }
    }

    /// The session ended, so there is nothing left to show.
    func sessionDestroyed() {
        window?.close()
    }

    private func unbindAll() {
        for surface in surfaces.values {
            if let s = surface.surface { rap_client_unbind(stream, s) }
        }
        surfaces = [:]
        blocks = [:]
        view = nil
        surfaceTree = .init()
    }

    // MARK: Actions

    func newTab() {
        client.send("session.new_window", ["session": session])
    }

    func split(_ surface: Ghostty.SurfaceView, _ direction: SplitTree<Ghostty.SurfaceView>.NewDirection) {
        _ = newSplit(at: surface, direction: direction)
    }

    func zoom(_ surface: Ghostty.SurfaceView) {
        guard let block = block(of: surface) else { return }
        client.send("session.zoom_block", ["session": session, "block": block])
    }

    func close(_ surface: Ghostty.SurfaceView) {
        guard let node = surfaceTree.root?.node(view: surface) else { return }
        closeSurface(node)
    }

    func selectTab(_ id: String) {
        client.send("session.focus", ["session": session, "window": id])
    }

    /// Show a tab of any session, as a sidebar row does.
    func show(tab id: String, in session: String) {
        switchSession(to: session)
        selectTab(id)
    }

    func closeTab(_ id: String) {
        guard let w = view?.windows.first(where: { $0.id == id }) else { return }
        confirmKill(w.blocks.map(\.id), messageText: "Close Tab?") { [weak self] in
            guard let self else { return }
            self.client.send("session.close_window", ["session": self.session, "window": id])
        }
    }

    /// Closing a pane kills its block; the server's next view removes it.
    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        let blocks = node.leaves().compactMap { leaf in surfaces.first { $0.value === leaf }?.key }
        confirmKill(blocks, messageText: "Close Pane?") { [weak self] in
            blocks.forEach { self?.client.send("block.close", ["block": $0]) }
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
        client.send("session.new_split", ["session": session, "block": block, "direction": dir])
        return nil
    }

    /// A pane dropped on another moves on the server, whose next view shows it here;
    /// moving only the local tree would last until that view.
    override func performSplitAction(_ action: TerminalSplitOperation) {
        guard case .drop(let drop) = action else { return super.performSplitAction(action) }
        // Panes of another window are other surfaces, so they are not ours to move.
        guard let moved = block(of: drop.payload), let target = block(of: drop.destination) else { return }
        let direction = switch drop.zone {
        case .top: "up"
        case .bottom: "down"
        case .left: "left"
        case .right: "right"
        }
        client.send("session.move_block", ["session": session, "block": moved, "target": target, "direction": direction])
    }

    // ponytail: reads the process name locally, which holds while the server is on this Mac.
    /// True if the block's foreground program is something other than a shell.
    private static func isBusy(_ block: String, _ client: RaptorClient) -> Bool {
        guard let p: RaptorClient.BlockProcess = client.call("block.method", ["block": block, "method": "process"]) else { return false }
        var name = [CChar](repeating: 0, count: 256)
        // proc_name fails (EPERM) for setuid programs such as top or sudo; shells are never setuid.
        guard proc_name(Int32(p.foreground?.pid ?? p.pid), &name, UInt32(name.count)) > 0 else { return true }
        return !RaptorProgram.shells.contains(String(cString: name))
    }

    /// Run `kill`, after asking first if any of the blocks runs something besides a shell.
    private func confirmKill(_ blocks: [String], messageText: String, kill: @escaping () -> Void) {
        client.request({ c in blocks.contains { Self.isBusy($0, c) } }, done: { [weak self] busy in
            guard busy else { return kill() }
            self?.confirmClose(
                messageText: messageText,
                informativeText: "A process is still running. Closing will kill it.",
                completion: kill)
        })
    }

    // MARK: Sessions and windows

    /// Show another session in this window.
    func switchSession(to id: String) {
        guard id != session else { return }
        let old = session
        session = id
        client.switched(self, from: old)
        refresh()
    }

    /// Make a session and show it here.
    func newSession(label: String? = nil) {
        client.request({ $0.createSession(label: label) }, done: { [weak self] id in
            guard let self else { return }
            guard let id else {
                return self.alert("Couldn't create the session", label.map { "A session named “\($0)” may already exist." })
            }
            self.switchSession(to: id)
        })
    }

    /// The session before or after this one in the server's list, wrapping around.
    func cycleSession(by offset: Int) {
        client.request({ $0.sessions().map(\.id) }, done: { [weak self] ids in
            guard let self, let i = ids.firstIndex(of: self.session), ids.count > 1 else { return }
            self.switchSession(to: ids[(i + offset + ids.count) % ids.count])
        })
    }

    func renameSession(id: String? = nil) {
        let id = id ?? session
        client.request({ $0.sessions().first { $0.id == id }?.label }, done: { [weak self] found in
            guard let self else { return }
            self.prompt("Rename Session", found ?? self.label) { name in
                self.client.send("session.set_label", ["session": id, "label": name]) { ok in
                    if !ok { self.alert("Couldn't rename the session", "A session named “\(name)” may already exist.") }
                }
            }
        })
    }

    func renameTab() {
        guard let id = activeTab, let current = tabs.first(where: { $0.id == id })?.title else { return }
        prompt("Rename Tab", current) { [weak self] name in
            guard let self else { return }
            self.client.send("session.set_window_label", ["session": self.session, "window": id, "label": name])
        }
    }

    /// Kill a session and everything running in it, after asking.
    func closeSession(id: String? = nil) {
        let id = id ?? session
        client.request({ $0.sessions().first { $0.id == id }?.label }, done: { [weak self] found in
            self?.confirmClose(
                messageText: "Close Session “\(found ?? id)”?",
                informativeText: "Every tab in the session and the programs running in them will be closed."
            ) { [weak self] in
                self?.client.send("session.kill", ["session": id])
            }
        })
    }

    /// Fetch every window's session again.
    func refreshSessions() {
        client.controllers.forEach { $0.refresh() }
    }

    func newWindow() {
        client.newWindow(ghostty, session: session)
    }

    /// Ask for a name in a sheet, starting from `current`. Empty names are ignored.
    private func prompt(_ title: String, _ current: String, done: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if response == .alertFirstButtonReturn && !name.isEmpty && name != current { done(name) }
        }
    }

    private func alert(_ title: String, _ text: String?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text ?? ""
        alert.beginSheetModal(for: window)
    }

    // MARK: Menu items

    @IBAction func changeSession(_ sender: Any?) {
        sessionPopoverIsShowing.toggle()
    }

    @IBAction func newSession(_ sender: Any?) { newSession() }
    @IBAction func renameSession(_ sender: Any?) { renameSession() }
    @IBAction func renameTab(_ sender: Any?) { renameTab() }
    @IBAction func previousSession(_ sender: Any?) { cycleSession(by: -1) }
    @IBAction func nextSession(_ sender: Any?) { cycleSession(by: 1) }
    @IBAction func refreshSessions(_ sender: Any?) { refreshSessions() }
    @IBAction func closeSession(_ sender: Any?) { closeSession() }
    @IBAction func toggleSidebar(_ sender: Any?) { RaptorAppearance.shared.sidebar.toggle() }
    @IBAction func toggleActivity(_ sender: Any?) { Self.toggleActivity() }

    /// Activity Mode's filter. A hidden sidebar comes back showing activity.
    static func toggleActivity() {
        let appearance = RaptorAppearance.shared
        guard appearance.sidebar else {
            appearance.activity = true
            appearance.sidebar = true
            return
        }
        withAnimation(RaptorSidebar.spring) { appearance.activity.toggle() }
    }

    // MARK: Keys

    /// ⌘1–⌘9, ⇧⌘[ and ⇧⌘]: the session's tabs, not native ones.
    @objc private func onGotoTab(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView, surfaceTree.contains(target),
              let raw = (notification.userInfo?[Ghostty.Notification.GotoTabKey] as? ghostty_action_goto_tab_e)?.rawValue,
              let current = tabs.firstIndex(where: { $0.id == activeTab }) else { return }
        let n = tabs.count
        let index: Int = switch raw {
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue: (current + n - 1) % n
        case GHOSTTY_GOTO_TAB_NEXT.rawValue: (current + 1) % n
        case GHOSTTY_GOTO_TAB_LAST.rawValue: n - 1
        default: min(Int(raw) - 1, n - 1)
        }
        guard index >= 0, index != current else { return }
        selectTab(tabs[index].id)
    }

    @objc private func onCloseTab(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView, surfaceTree.contains(target),
              let id = activeTab else { return }
        closeTab(id)
    }

    /// Closing the window only detaches, so it needs no confirmation.
    @objc private func onCloseWindow(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView, surfaceTree.contains(target) else { return }
        window?.close()
    }

    /// The base class zooms locally; the server's next view settles it for every window.
    @objc private func onToggleZoom(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView, surfaceTree.contains(target) else { return }
        zoom(target)
    }

    // MARK: Command palette

    /// Rex's commands. Shortcuts are read from the keybindings, so they follow the
    /// user's config; ones that are menu items show the menu's.
    var paletteCommands: [RaptorCommand] {
        let config = ghostty.config
        func command(_ title: String, _ action: String) -> RaptorCommand {
            RaptorCommand(title: title, shortcut: RaptorCommand.glyphs(config.keyboardShortcut(for: action))) { [weak self] in
                guard let self, let surface = self.focusedSurface else { return }
                self.performAction(action, on: surface)
            }
        }
        let appearance = RaptorAppearance.shared
        // The sidebar's sessions, kept current from the server's events: the palette is
        // built now, so it can't wait for the server.
        let current = client.sidebar.sessions
        let styles = RaptorAppearance.Style.allCases.filter { $0 != .glass || RaptorAppearance.glassAvailable }

        return [
            RaptorCommand(
                title: "Change Session",
                value: current.first { $0.id == session }?.label,
                submenu: { [weak self] in
                    current.map { s in
                        RaptorCommand(title: s.label, checked: s.id == self?.session) { self?.switchSession(to: s.id) }
                    }
                }),
            RaptorCommand(title: "Rename Session…") { [weak self] in self?.renameSession() },
            RaptorCommand(title: "Rename Tab…") { [weak self] in self?.renameTab() },
            RaptorCommand(title: "New Session", shortcut: ["⇧", "⌘", "N"]) { [weak self] in self?.newSession() },
            command("New Tab", "new_tab"),
            command("New Window", "new_window"),
            command("Show Previous Tab", "previous_tab"),
            command("Show Next Tab", "next_tab"),
            command("Close Tab", "close_tab:this"),
            command("Close Window", "close_window"),
            RaptorCommand(title: "Previous Session") { [weak self] in self?.cycleSession(by: -1) },
            RaptorCommand(title: "Next Session") { [weak self] in self?.cycleSession(by: 1) },
            RaptorCommand(title: "Refresh Sessions", shortcut: ["⌘", "R"]) { [weak self] in self?.refreshSessions() },
            RaptorCommand(title: "Close Session…") { [weak self] in self?.closeSession() },
            RaptorCommand(title: appearance.sidebar ? "Hide Sidebar" : "Show Sidebar", shortcut: ["⌃", "⌘", "S"]) {
                appearance.sidebar.toggle()
            },
            RaptorCommand(title: appearance.activity ? "Hide Activity" : "Show Activity", shortcut: ["⇧", "⌘", "A"]) {
                Self.toggleActivity()
            },
            command("Split Pane Right", "new_split:right"),
            command("Split Pane Down", "new_split:down"),
            command("Split Pane Best Fit", "new_split:auto"),
            command("Zoom Pane", "toggle_split_zoom"),
            command("Focus Pane Left", "goto_split:left"),
            command("Focus Pane Right", "goto_split:right"),
            command("Focus Pane Up", "goto_split:up"),
            command("Focus Pane Down", "goto_split:down"),
            command("Focus Previous Pane", "goto_split:previous"),
            command("Focus Next Pane", "goto_split:next"),
            command("Reset Terminal", "reset"),
            RaptorCommand(
                title: "Change Interface Style",
                value: appearance.effectiveStyle.name,
                submenu: {
                    styles.map { style in
                        RaptorCommand(title: style.name, checked: appearance.effectiveStyle == style) { appearance.style = style }
                    }
                }),
            RaptorCommand(title: appearance.fontSmoothing ? "Disable Terminal Font Smoothing" : "Enable Terminal Font Smoothing") {
                appearance.fontSmoothing.toggle()
            },
            RaptorCommand(
                title: "Change Terminal Padding Color",
                value: appearance.paddingColor.name,
                submenu: {
                    RaptorAppearance.PaddingColor.allCases.map { c in
                        RaptorCommand(title: c.name, checked: appearance.paddingColor == c) { appearance.paddingColor = c }
                    }
                }),
        ]
    }

    // MARK: NSWindowDelegate

    /// A pane keeps its focus while another window has the keyboard, so coming back
    /// here focuses nothing anew: claim the focused pane's size for this window.
    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        if let s = focusedSurface?.surface { rap_client_claim(stream, s) }
        if let window, window.firstResponder === window, let pane = focusedPane {
            Ghostty.moveFocus(to: pane)
        }
    }

    /// The window closed: detach, leaving the session and its processes running.
    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        unbindAll()
        client.closed(self)
    }
}

extension RaptorController {
    /// A Session menu after File, for the switcher's keys. Its items go to the front
    /// Raptor window and are disabled without one.
    static func installMenu() {
        guard let main = NSApp.mainMenu, main.item(withTitle: "Session") == nil else { return }
        let menu = NSMenu(title: "Session")
        func add(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
        }
        add("Change Session…", #selector(changeSession(_:)), "k")
        add("New Session", #selector(newSession(_:)), "n", [.command, .shift])
        add("Rename Session…", #selector(renameSession(_:)))
        add("Rename Tab…", #selector(renameTab(_:)))
        menu.addItem(.separator())
        add("Previous Session", #selector(previousSession(_:)))
        add("Next Session", #selector(nextSession(_:)))
        add("Refresh Sessions", #selector(refreshSessions(_:)), "r")
        menu.addItem(.separator())
        add("Close Session…", #selector(closeSession(_:)))
        menu.addItem(.separator())
        add("Toggle Sidebar", #selector(toggleSidebar(_:)), "s", [.command, .control])
        add("Show Activity", #selector(toggleActivity(_:)), "a", [.command, .shift])
        let item = NSMenuItem(title: "Session", action: nil, keyEquivalent: "")
        item.submenu = menu
        let file = main.items.firstIndex { $0.title == "File" } ?? 0
        main.insertItem(item, at: file + 1)
    }
}
