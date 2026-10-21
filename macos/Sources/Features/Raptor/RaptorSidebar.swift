import AppKit
import SwiftUI

/// Every session's tabs, for the sidebar: one model for the app, kept up to date from
/// the server's events. Titles, directories, programs and statuses change in place;
/// anything that reshapes a session fetches the views again.
final class RaptorSidebarModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let tab: RaptorController.Tab
        let session: String
        let status: RaptorController.SessionView.Status?
        /// The panes running a coding agent, in the tab's order. Agents-only mode keeps
        /// only tabs with one.
        let agents: [Agent]
        /// The block whose program made this tab.
        let parent: String?
        let blocks: [String]
        /// The git checkout the focused pane is in.
        var checkout: RaptorGitCheckout?

        var id: String { tab.id }
        var isWorking: Bool { status?.state == "working" }
        var hasAgent: Bool { !agents.isEmpty }
        /// The agent a row in agents-only mode speaks for: a working one, else the first.
        var lead: Agent? { agents.first(where: { $0.status?.state == "working" }) ?? agents.first }
        /// Rows for agents, and for programs that report a status, add a status line.
        var hasStatusLine: Bool { hasAgent || status != nil }
    }

    /// A pane running a coding agent, and what it is doing.
    struct Agent: Equatable {
        let block: String
        let program: RaptorProgram
        let title: String
        let status: RaptorController.SessionView.Status?
    }

    struct Session: Identifiable, Equatable {
        let id: String
        let label: String
        let tabs: [Tab]
    }

    @Published private(set) var sessions: [Session] = []

    private weak var client: RaptorClient?
    /// The server's views, in session order.
    private var views: [(id: String, view: RaptorController.SessionView)] = []
    private var blocks: [String: RaptorController.Block] = [:]
    private var statuses: [String: RaptorController.SessionView.Status] = [:]
    /// Agents' statuses read from their titles, for agents that don't report one, kept
    /// so how long ago it changed survives title updates.
    private var titleStatuses: [String: RaptorController.SessionView.Status] = [:]
    // ponytail: never forgotten, so a directory that becomes a repo or worktree after it
    // was first seen is noticed only on the next launch.
    /// Checkouts by directory, nil where there is none.
    private var checkouts: [String: RaptorGitCheckout?] = [:]
    private var reloadPending = false

    init(client: RaptorClient) {
        self.client = client
    }

    /// Fetch every session's view on the next turn of the run loop, once however many
    /// events ask for it.
    func setNeedsReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    /// Fetch the views off the main thread, then show them.
    private func reload() {
        guard let client else { return }
        let known = Set(blocks.filter { $0.value.process != nil }.keys)
        client.request({ c in
            c.sessions().compactMap { s in c.view(s.id, known: known).map { (id: s.id, view: $0.view, processes: $0.processes) } }
        }, done: { [weak self] fetched in
            self?.apply(fetched)
        })
    }

    private func apply(_ fetched: [(id: String, view: RaptorController.SessionView, processes: [String: String])]) {
        views = fetched.map { ($0.id, $0.view) }
        var seen: Set<String> = []
        for (_, view, processes) in fetched {
            for w in view.windows {
                for b in w.blocks {
                    seen.insert(b.id)
                    var block = blocks[b.id] ?? .init()
                    block.title = b.title
                    block.pwd = RaptorController.path(b.pwd ?? "")
                    if block.process == nil { block.process = processes[b.id] }
                    blocks[b.id] = block
                    statuses[b.id] = b.status
                }
            }
        }
        blocks = blocks.filter { seen.contains($0.key) }
        statuses = statuses.filter { seen.contains($0.key) }
        rebuild()
    }

    // MARK: Events

    func titleChanged(block: String, to title: String) {
        update(block) { $0.title = title }
    }

    func pwdChanged(block: String, to pwd: String) {
        update(block) { $0.pwd = RaptorController.path(pwd) }
    }

    func processChanged(block: String, to name: String?) {
        update(block) { $0.process = name }
    }

    /// The block's root record changed: the status its row shows.
    func statusChanged(block: String, to status: RaptorController.SessionView.Status?) {
        guard blocks[block] != nil, statuses[block] != status else { return }
        statuses[block] = status
        rebuild()
    }

    /// Move a tab to another's place now, as the server is asked to, so a dropped row
    /// doesn't jump back until the server's view arrives.
    func move(_ id: String, onto target: String, in session: String) {
        guard let s = views.firstIndex(where: { $0.id == session }) else { return }
        var windows = views[s].view.windows
        guard let from = windows.firstIndex(where: { $0.id == id }),
              let to = windows.firstIndex(where: { $0.id == target }) else { return }
        windows.insert(windows.remove(at: from), at: to)
        views[s].view.windows = windows
        rebuild()
    }

    private func update(_ block: String, _ change: (inout RaptorController.Block) -> Void) {
        guard var b = blocks[block] else { return }
        change(&b)
        guard b != blocks[block] else { return }
        blocks[block] = b
        rebuild()
    }

    private func rebuild() {
        titleStatuses = titleStatuses.filter { blocks[$0.key]?.program.isAgent == true }
        let sessions = views.map { id, view in
            Session(id: id, label: view.label, tabs: view.windows.map { w in
                let ids = w.blocks.map(\.id)
                let agents = ids.compactMap { b -> Agent? in
                    guard let block = blocks[b], block.program.isAgent else { return nil }
                    return Agent(
                        block: b,
                        program: block.program,
                        title: Self.agentTitle(block.headerTitle),
                        status: statuses[b] ?? titleStatus(b, title: block.title))
                }
                // A working pane speaks for its tab, else the latest news does.
                let status = (ids.compactMap { statuses[$0] } + agents.compactMap(\.status)).max {
                    ($0.state == "working" ? 1 : 0, $0.updated_at) < ($1.state == "working" ? 1 : 0, $1.updated_at)
                }
                return Tab(
                    tab: RaptorController.tab(w, blocks: blocks),
                    session: id,
                    status: status,
                    agents: agents,
                    parent: w.parent,
                    blocks: ids,
                    checkout: checkout(blocks[w.focused_block]?.pwd ?? ""))
            })
        }
        if sessions != self.sessions { self.sessions = sessions }
    }

    /// An agent that reports no status still shows whether it works: its title.
    private func titleStatus(_ block: String, title: String) -> RaptorController.SessionView.Status {
        let state = Self.titleSaysWorking(title) ? "working" : "idle"
        if let known = titleStatuses[block], known.state == state { return known }
        let status = RaptorController.SessionView.Status(
            state: state, msg: nil, updated_at: Int64(Date().timeIntervalSince1970 * 1000))
        titleStatuses[block] = status
        return status
    }

    // ponytail: Claude Code, Gemini, Codex and others put a braille spinner at the start
    // of their title while they work; an agent that doesn't reads as idle until it
    // reports OSC 7501.
    /// Whether an agent's title shows its spinner.
    static func titleSaysWorking(_ title: String) -> Bool {
        title.unicodeScalars.first.map { (0x2801...0x28FF).contains($0.value) } ?? false
    }

    /// An agent's title without the spinner or idle mark ("✳") it leads with, which
    /// the row's dots and status line already say.
    static func agentTitle(_ title: String) -> String {
        guard let first = title.unicodeScalars.first,
              (0x2800...0x28FF).contains(first.value) || "✳✻✽✶✢·".unicodeScalars.contains(first)
        else { return title }
        return String(title.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private func checkout(_ dir: String) -> RaptorGitCheckout? {
        // A tailnet machine's directories aren't on this Mac.
        guard !dir.isEmpty, client?.host == nil else { return nil }
        if let known = checkouts[dir] { return known }
        let found = RaptorGitCheckout.resolve(dir)
        checkouts[dir] = found
        return found
    }

    // MARK: Rows

    enum Row: Identifiable, Equatable {
        case session(id: String, label: String, first: Bool)
        case tab(Tab, Branch)
        /// "…": the tabs nested under the tab with this id are deeper than the
        /// sidebar shows, so one row stands in for all of them, `hidden`.
        case more(id: String, hidden: [Tab], Branch)

        var id: String {
            switch self {
            case .session(let id, _, _): id
            case .tab(let t, _): t.id
            case .more(let id, _, _): "more:" + id
            }
        }
    }

    /// Where a tab sits in the tree of tabs made by other tabs' programs.
    struct Branch: Equatable {
        /// For each level above this row's own, whether a line runs on past it to a
        /// later sibling.
        var guides: [Bool] = []
        /// The last of its siblings, so its connector ends here.
        var last = false
        var isChild = false
        /// Tabs hang from this one, so a line leaves its tile downward.
        var hasChildren = false
        var depth: Int { guides.count + (isChild ? 1 : 0) }
    }

    /// A tab row is drawn at most this deep, so three levels show; tabs nested deeper
    /// than that collapse into one "…" row just below.
    static let maxDepth = 2

    /// The sidebar's rows below the host: each session's header and its tabs, a tab
    /// nested under its parent tab wherever that lives. A tab's parent is, first, the
    /// tab whose program made it (an agent starting another with `rap run` or `rap new`,
    /// as in Rex); else, for a tab in a linked git worktree, the first tab in its main
    /// checkout of the same repository (as herdr groups worktrees). So an agent's own
    /// tabs stay with it even when they work in a worktree, and a worktree tab nobody
    /// made from a tab joins its repository's checkout. A tab whose parents would lead
    /// back to itself stays at the top. Tabs deeper than `maxDepth` collapse into a
    /// single "…" row.
    ///
    /// Agents-only mode (`activity`, the eye closed) keeps only tabs running a coding
    /// agent; a session left with none goes, and a kept tab whose parent went falls back
    /// to the next rule, or the top.
    static func rows(_ sessions: [Session], activity: Bool) -> [Row] {
        let shown = sessions.map { s in
            (s, s.tabs.filter { !activity || $0.hasAgent })
        }
        var owner: [String: String] = [:]
        var mainCheckout: [String: String] = [:]
        for (_, tabs) in shown {
            for t in tabs {
                for b in t.blocks { owner[b] = t.id }
                if let c = t.checkout, !c.isLinked, mainCheckout[c.commonDir] == nil { mainCheckout[c.commonDir] = t.id }
            }
        }
        var links: [String: String] = [:]
        for (_, tabs) in shown {
            for t in tabs {
                if let p = t.parent.flatMap({ owner[$0] }), p != t.id {
                    links[t.id] = p
                } else if let c = t.checkout, c.isLinked, let m = mainCheckout[c.commonDir], m != t.id {
                    links[t.id] = m
                }
            }
        }
        func parent(_ t: Tab) -> String? {
            guard let first = links[t.id] else { return nil }
            var seen: Set<String> = []
            var next: String? = first
            while let n = next, seen.insert(n).inserted {
                if n == t.id { return nil }
                next = links[n]
            }
            return first
        }
        var children: [String: [Tab]] = [:]
        for (_, tabs) in shown { for t in tabs { if let p = parent(t) { children[p, default: []].append(t) } } }

        var rows: [Row] = []
        var placed: Set<String> = []
        func place(_ t: Tab, _ branch: Branch) {
            guard placed.insert(t.id).inserted else { return }
            let kids = (children[t.id] ?? []).filter { !placed.contains($0.id) }
            var branch = branch
            branch.hasChildren = !kids.isEmpty
            rows.append(.tab(t, branch))
            let guides = branch.isChild ? branch.guides + [!branch.last] : branch.guides
            // The kids would sit deeper than the sidebar shows: one "…" row stands
            // for the whole subtree, connected as its first kid would be.
            if branch.depth >= Self.maxDepth, !kids.isEmpty {
                var hidden: [Tab] = []
                func hide(_ t: Tab) {
                    guard placed.insert(t.id).inserted else { return }
                    hidden.append(t)
                    for kid in children[t.id] ?? [] { hide(kid) }
                }
                kids.forEach(hide)
                rows.append(.more(id: t.id, hidden: hidden, Branch(guides: guides, last: true, isChild: true)))
                return
            }
            for (i, kid) in kids.enumerated() {
                place(kid, Branch(guides: guides, last: i == kids.count - 1, isChild: true))
            }
        }
        for (s, tabs) in shown {
            let roots = tabs.filter { parent($0) == nil }
            guard !roots.isEmpty else { continue }
            rows.append(.session(id: s.id, label: s.label, first: rows.isEmpty))
            for t in roots { place(t, Branch()) }
        }
        return rows
    }

    /// The tabs a dragged tab can trade places with, itself among them: those under the
    /// same parent, in order, each with the rows it and its nested tabs take.
    static func siblings(of id: String, in rows: [Row]) -> [(id: String, rows: Range<Int>)] {
        func depth(_ row: Row) -> Int? {
            switch row {
            case .tab(_, let b), .more(_, _, let b): b.depth
            case .session: nil
            }
        }
        guard let r = rows.firstIndex(where: { $0.id == id }), case .tab(_, let branch) = rows[r] else { return [] }
        var lo = r, hi = r + 1
        while lo > 0, let d = depth(rows[lo - 1]), d >= branch.depth { lo -= 1 }
        while hi < rows.count, let d = depth(rows[hi]), d >= branch.depth { hi += 1 }
        var siblings: [(id: String, rows: Range<Int>)] = []
        for i in lo..<hi {
            if case .tab(let t, let b) = rows[i], b.depth == branch.depth {
                siblings.append((t.id, i..<i + 1))
            } else if let last = siblings.last {
                siblings[siblings.count - 1].rows = last.rows.lowerBound..<i + 1
            }
        }
        return siblings
    }

    /// How long ago, as Rex shows it: "now", then minutes, hours and days.
    static func age(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    /// A status as its row's second line: the program's message, else (or when the
    /// message only repeats the row's `title`) its state.
    static func statusLine(_ status: RaptorController.SessionView.Status?, title: String = "") -> String {
        guard let status else { return "Idle" }
        if let msg = status.msg, !msg.isEmpty, msg != title { return msg }
        return status.state.prefix(1).uppercased() + status.state.dropFirst()
    }
}

/// The vertical sidebar: a header with the traffic lights, the sidebar toggle and the
/// Activity Mode eye; each host, its sessions and their tabs; and a footer of actions.
/// Sizes are Rex's, from the captain's reference frames at 2x.
struct RaptorSidebar: View {
    @ObservedObject var servers: RaptorClient.Servers
    @ObservedObject var controller: RaptorController
    @ObservedObject var appearance: RaptorAppearance
    let tokens: ThemeTokens

    static let width: CGFloat = 276
    static let rowHeight: CGFloat = 32
    static let activityRowHeight: CGFloat = 46
    /// The selection pill's inset from the sidebar's edges.
    static let selectionInset: CGFloat = 10
    /// A nested row moves right by this much per level.
    static let indent: CGFloat = 22
    /// Activity Mode filters and reshapes the rows with this spring.
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.9)

    var body: some View {
        VStack(spacing: 0) {
            // SwiftUI stretches the scroll view up into the title bar's safe area, so
            // the header stays in front of it to keep its buttons' clicks.
            header
                .zIndex(1)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(servers.clients) { server in
                        RaptorSidebarServer(
                            model: server.sidebar,
                            server: server,
                            controller: controller,
                            activity: appearance.activity,
                            tokens: tokens)
                    }
                }
                .padding(.bottom, 24)
            }
            // The list fades out behind the footer.
            .mask(VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 32)
            })
            footer
        }
        .frame(width: Self.width)
        .environment(\.colorScheme, tokens.isLight ? .light : .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    private var header: some View {
        HStack(spacing: 0) {
            RaptorTitlebarButton(symbol: "sidebar.left", help: "Hide Sidebar ⌃⌘S") {
                appearance.sidebar = false
            }
            Spacer(minLength: 0)
            RaptorActivityButton(open: !appearance.activity, tokens: tokens) {
                withAnimation(Self.spring) { appearance.activity.toggle() }
            }
        }
        // The toggle sits where the title bar's does, past the traffic lights.
        .padding(.leading, 82)
        .padding(.trailing, 13)
        .frame(height: RaptorWindowView.titlebarHeight)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Menu {
                Toggle("Show All Tabs", isOn: Binding(
                    get: { !appearance.activity },
                    set: { all in withAnimation(Self.spring) { appearance.activity = !all } }))
                Toggle("Show Only Agents", isOn: Binding(
                    get: { appearance.activity },
                    set: { on in withAnimation(Self.spring) { appearance.activity = on } }))
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 24, height: 24)
            .raptorHover()
            .help("Filter")
            .accessibilityLabel("Filter")
            Spacer(minLength: 0)
            RaptorTitlebarButton(symbol: "rectangle.stack.badge.plus", help: "New Session ⇧⌘N") {
                controller.newSession()
            }
            RaptorTitlebarButton(symbol: "network", help: "Machines on Your Tailnet") {
                controller.hostPickerIsShowing.toggle()
            }
            .popover(isPresented: $controller.hostPickerIsShowing, arrowEdge: .top) {
                RaptorHostPicker(controller: controller) { controller.hostPickerIsShowing = false }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 13)
        .frame(height: 40)
        .padding(.bottom, 4)
    }
}

/// A server's part of the sidebar: its machine, then each session and its tabs.
struct RaptorSidebarServer: View {
    @ObservedObject var model: RaptorSidebarModel
    let server: RaptorClient
    @ObservedObject var controller: RaptorController
    let activity: Bool
    let tokens: ThemeTokens

    /// A tab dragged up or down among its siblings, as the strip's tabs are dragged
    /// along it: it follows the pointer by `dy`, with the tabs nested under it.
    struct Drag: Equatable {
        let id: String
        var dy: CGFloat
    }

    @State private var drag: Drag?

    var body: some View {
        let rows = RaptorSidebarModel.rows(model.sessions, activity: activity)
        let shown = server === controller.client
        let plan = drag.flatMap { plan($0, rows) }
        VStack(spacing: 0) {
            RaptorSidebarHost(name: server.name, symbol: server.host == nil ? "laptopcomputer" : "server.rack")
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                let block = plan?.siblings.firstIndex { $0.rows.contains(i) }
                let dragged = block != nil && block == plan?.reorder.from
                let offset = block.flatMap { plan?.reorder.offset(of: $0, drag?.dy ?? 0) } ?? 0
                Group {
                    switch row {
                    case .session(_, let label, let first):
                        RaptorSidebarSessionHeader(label: label, first: first)
                    case .tab(let tab, let branch):
                        RaptorSidebarRow(
                            tab: tab,
                            branch: branch,
                            selected: shown && tab.session == controller.session && tab.id == controller.activeTab,
                            activity: activity,
                            tokens: tokens,
                            select: { controller.show(tab: tab.id, in: tab.session, on: server) },
                            slide: { slide(tab, by: $0?.height, rows: rows) })
                    case .more(_, let hidden, let branch):
                        RaptorSidebarMore(
                            branch: branch,
                            selected: shown && hidden.contains {
                                $0.session == controller.session && $0.id == controller.activeTab
                            },
                            activity: activity,
                            tokens: tokens
                        )
                    }
                }
                // The dragged rows hide the ones they pass over.
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color(nsColor: tokens.chrome))
                    .padding(.horizontal, RaptorSidebar.selectionInset)
                    .padding(.vertical, 1.5)
                    .opacity(dragged ? 1 : 0))
                .offset(y: offset)
                // The dragged rows keep up with the pointer; the others slide.
                .animation(dragged ? nil : RaptorTabStrip.slide, value: offset)
                .zIndex(dragged ? 1 : 0)
                .transition(.opacity)
            }
        }
    }

    /// The dragged tab's siblings, and the column of rows they make.
    private func plan(_ drag: Drag, _ rows: [RaptorSidebarModel.Row]) -> (siblings: [(id: String, rows: Range<Int>)], reorder: RaptorReorder)? {
        let siblings = RaptorSidebarModel.siblings(of: drag.id, in: rows)
        guard let from = siblings.firstIndex(where: { $0.id == drag.id }) else { return nil }
        let height = activity ? RaptorSidebar.activityRowHeight : RaptorSidebar.rowHeight
        return (siblings, RaptorReorder(lengths: siblings.map { CGFloat($0.rows.count) * height }, from: from))
    }

    /// Follow the pointer with a dragged tab, kept among its siblings; nil drops it in its
    /// new place, which shows at once and is sent to the server.
    private func slide(_ tab: RaptorSidebarModel.Tab, by dy: CGFloat?, rows: [RaptorSidebarModel.Row]) {
        guard let dy else {
            guard let drag, let plan = plan(drag, rows) else { return }
            let to = plan.reorder.destination(drag.dy)
            withAnimation(RaptorTabStrip.slide) {
                if to != plan.reorder.from {
                    let target = plan.siblings[to].id
                    model.move(tab.id, onto: target, in: tab.session)
                    controller.moveTab(tab.id, onto: target, in: tab.session, on: server)
                }
                self.drag = nil
            }
            return
        }
        guard let plan = plan(Drag(id: tab.id, dy: 0), rows) else { return }
        drag = Drag(id: tab.id, dy: plan.reorder.clamp(dy))
    }
}

/// The machines a window can show the sessions of: this Mac, then the macOS and Linux
/// machines on the tailnet, looked for as it opens. Picking one without a rap server
/// running says how to start one there.
struct RaptorHostPicker: View {
    @ObservedObject var controller: RaptorController
    let dismiss: () -> Void

    /// Nil while looking, and stays nil without Tailscale.
    @State private var peers: [RaptorClient.Peer]?
    @State private var looking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("This Mac", symbol: "laptopcomputer", detail: nil, current: controller.client.host == nil) {
                if let local = RaptorClient.shared { controller.showNewest(on: local) }
            }
            Divider().padding(.vertical, 4)
            if let peers, !peers.isEmpty {
                ForEach(peers) { peer in
                    row(peer.name, symbol: "server.rack", detail: Self.detail(peer), current: controller.client.host == peer.dns) {
                        controller.open(peer)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    if looking { ProgressView().controlSize(.small) }
                    Text(looking ? "Looking on your tailnet…"
                        : peers == nil ? "Tailscale isn't running on this Mac."
                        : "No other Mac or Linux machine on your tailnet is online.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
            }
        }
        .padding(6)
        .frame(width: 300)
        .onAppear {
            DispatchQueue.global().async {
                let found = RaptorClient.tailnetPeers()
                DispatchQueue.main.async {
                    peers = found
                    looking = false
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Machines")
    }

    /// What a machine's row says about its rap server.
    static func detail(_ peer: RaptorClient.Peer) -> String? {
        switch peer.rap {
        case .running: nil
        case .refused: "Not allowed"
        case .none: "rap not running"
        }
    }

    private func row(_ name: String, symbol: String, detail: String?, current: Bool, pick: @escaping () -> Void) -> some View {
        RaptorHostPickerRow(name: name, symbol: symbol, detail: detail, current: current) {
            dismiss()
            if !current { pick() }
        }
    }
}

struct RaptorHostPickerRow: View {
    let name: String
    let symbol: String
    let detail: String?
    let current: Bool
    let pick: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(name)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 12)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .opacity(current ? 1 : 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: pick)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\(name), \($0)" } ?? name)
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, pick)
    }
}

/// The eye that picks what the sidebar shows: open on a filled circle for every tab,
/// closing its lid for only the tabs running an agent.
struct RaptorActivityButton: View {
    let open: Bool
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RaptorEye(openness: open ? 1 : 0)
                .frame(width: 18, height: 12)
                .foregroundStyle(open ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(open ? RaptorSidebarRow.raised(tokens) : .clear))
                .contentShape(Circle())
                .animation(.easeInOut(duration: 0.25), value: open)
        }
        .buttonStyle(.raptor)
        .help(open ? "Show Only Agents ⇧⌘A" : "Show All Tabs ⇧⌘A")
        .accessibilityLabel("Show All Tabs")
        .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
    }
}

/// An eye whose upper lid closes down onto the lower one as `openness` goes to 0,
/// leaving a closed eye's curve with three lashes.
struct RaptorEye: Shape {
    var openness: CGFloat

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let (left, right) = (CGPoint(x: rect.minX + 1, y: rect.midY), CGPoint(x: rect.maxX - 1, y: rect.midY))
        // A quadratic's control point sits twice as far out as the curve's peak.
        let lower = rect.midY + rect.height
        let upper = lower + (rect.minY - rect.height / 2 - lower) * openness
        var eye = Path()
        eye.move(to: left)
        eye.addQuadCurve(to: right, control: CGPoint(x: rect.midX, y: lower))
        eye.move(to: left)
        eye.addQuadCurve(to: right, control: CGPoint(x: rect.midX, y: upper))
        var path = eye.strokedPath(.init(lineWidth: 1.4, lineCap: .round))
        // The pupil shrinks away behind the closing lid.
        let r = rect.height * 0.22 * openness
        path.addEllipse(in: CGRect(x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2))
        // Lashes grow from the lid's curve as it closes.
        let lash = (1 - openness) * rect.height * 0.3
        if lash > 0.1 {
            var lashes = Path()
            for dx in [-0.3, 0, 0.3] {
                let x = rect.midX + rect.width * dx
                // On the closed curve: y = midY + (height/2)·(1 - (2t-1)²).
                let t = (x - left.x) / (right.x - left.x)
                let y = rect.midY + rect.height / 2 * (1 - pow(2 * t - 1, 2))
                lashes.move(to: CGPoint(x: x, y: y))
                lashes.addLine(to: CGPoint(x: x + lash * dx * 1.2, y: y + lash))
            }
            path.addPath(lashes.strokedPath(.init(lineWidth: 1.2, lineCap: .round)))
        }
        return path
    }
}

struct RaptorSidebarHost: View {
    let name: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .frame(height: 32)
        .padding(.top, 3)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct RaptorSidebarSessionHeader: View {
    let label: String
    /// Right under the host, which already leaves room above it.
    let first: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 21)
            .padding(.trailing, 20)
            .frame(height: 26)
            .padding(.top, first ? 0 : 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A tab: its panes' cards stacked as on the tab strip and its title, nested under the
/// tab that made it, with a pulsing "•••" while it works. A tab with an agent or a
/// status adds the status line and how long ago it changed. In agents-only mode the
/// row speaks for the tab's agent instead: its card in front, its title and status.
struct RaptorSidebarRow: View {
    let tab: RaptorSidebarModel.Tab
    let branch: RaptorSidebarModel.Branch
    let selected: Bool
    let activity: Bool
    let tokens: ThemeTokens
    let select: () -> Void
    /// This row dragged by so much, nil when it's let go.
    let slide: (CGSize?) -> Void

    @State private var hovering = false

    /// The selection pill and the eye's circle lift the chrome as the tab strip's pill
    /// does, so they stay translucent over Blended and Glass.
    static func raised(_ tokens: ThemeTokens) -> Color {
        tokens.isLight ? .black.opacity(0.05) : .white.opacity(0.05)
    }

    static func raisedBorder(_ tokens: ThemeTokens) -> Color {
        // Over the fill: #2F2F2F on Rex's #111111 chrome.
        tokens.isLight ? .black.opacity(0.1) : .white.opacity(0.08)
    }

    /// What the row draws: the tab's, or in agents-only mode its lead agent's, in front
    /// of the tab's other agents.
    private var face: (program: RaptorProgram, others: [RaptorProgram], title: String) {
        guard activity, let lead = tab.lead else {
            let title = tab.tab.program.isAgent ? RaptorSidebarModel.agentTitle(tab.tab.title) : tab.tab.title
            return (tab.tab.program, tab.tab.others, title)
        }
        return (lead.program, tab.agents.filter { $0.block != lead.block }.map(\.program), lead.title)
    }

    var body: some View {
        let twoLine = tab.hasStatusLine
        let height = twoLine ? RaptorSidebar.activityRowHeight : RaptorSidebar.rowHeight
        let face = face
        let parts = RaptorTabView.titleParts(face.title, program: face.program.name)
        HStack(spacing: 8) {
            RaptorTileCluster(program: face.program, others: face.others, light: tokens.isLight)
                .fixedSize()
                .frame(minWidth: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    (Text(parts.name) + Text(parts.path).foregroundColor(.secondary))
                        .font(.system(size: 13))
                        .fadeTruncated()
                    if tab.isWorking { RaptorWorkingDots() }
                }
                if twoLine {
                    HStack(spacing: 6) {
                        Text(RaptorSidebarModel.statusLine(tab.status, title: face.title))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fadeTruncated()
                        if let status = tab.status {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(RaptorSidebarModel.age(
                                    Date(timeIntervalSince1970: Double(status.updated_at) / 1000), now: context.date))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(.leading, 10 + CGFloat(branch.depth) * RaptorSidebar.indent)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, minHeight: height - 3, maxHeight: height - 3, alignment: .leading)
        .background {
            Self.pill(selected: selected, hovering: hovering, height: height, twoLine: twoLine, tokens: tokens)
        }
        .contentShape(Rectangle())
        .overlay(RaptorTabHandle(select: select, slide: slide) { hovering = $0 })
        .padding(.horizontal, RaptorSidebar.selectionInset)
        .frame(height: height)
        .background(alignment: .leading) {
            RaptorTreeConnector(branch: branch)
                .padding(.leading, RaptorSidebar.selectionInset + 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }

    @ViewBuilder
    static func pill(selected: Bool, hovering: Bool, height: CGFloat, twoLine: Bool, tokens: ThemeTokens) -> some View {
        let shape = RoundedRectangle(cornerRadius: twoLine ? 15 : (height - 3) / 2, style: .continuous)
        if selected {
            shape.fill(raised(tokens))
                .overlay(shape.strokeBorder(raisedBorder(tokens), lineWidth: 1))
        } else if hovering {
            shape.fill(Color.primary.opacity(0.08))
        }
    }

    private var accessibilityLabel: String {
        var label = face.title
        if tab.isWorking || tab.hasStatusLine { label += ", " + RaptorSidebarModel.statusLine(tab.status, title: face.title) }
        return label
    }
}

/// The "…" row that stands in for tabs nested deeper than the sidebar shows, drawn
/// like a tab row and hanging from its parent's connector. It wears the selection
/// pill while the active tab is one of those it hides.
struct RaptorSidebarMore: View {
    let branch: RaptorSidebarModel.Branch
    let selected: Bool
    let activity: Bool
    let tokens: ThemeTokens

    var body: some View {
        let height = activity ? RaptorSidebar.activityRowHeight : RaptorSidebar.rowHeight
        Text("…")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .padding(.leading, 10 + CGFloat(branch.depth) * RaptorSidebar.indent)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, minHeight: height - 3, maxHeight: height - 3, alignment: .leading)
            .background {
                RaptorSidebarRow.pill(selected: selected, hovering: false, height: height, twoLine: activity, tokens: tokens)
            }
            .padding(.horizontal, RaptorSidebar.selectionInset)
            .frame(height: height)
            .background(alignment: .leading) {
                RaptorTreeConnector(branch: branch)
                    .padding(.leading, RaptorSidebar.selectionInset + 10)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("More tabs, nested deeper than the sidebar shows")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The lines tying a nested tab to the one above it: a rounded elbow from the parent's
/// tile into this row's, carried on past rows of its parent's later children.
struct RaptorTreeConnector: View {
    let branch: RaptorSidebarModel.Branch

    var body: some View {
        Canvas { context, size in
            let column = RaptorSidebar.indent
            // Lines run down the middle of the tile they come from.
            func x(_ level: Int) -> CGFloat { CGFloat(level) * column + 9 }
            let mid = size.height / 2
            var path = Path()
            if branch.hasChildren {
                path.move(to: CGPoint(x: x(branch.depth), y: mid + 12))
                path.addLine(to: CGPoint(x: x(branch.depth), y: size.height))
            }
            defer { context.stroke(path, with: .style(Color(nsColor: .tertiaryLabelColor)), lineWidth: 1) }
            guard branch.isChild else { return }
            for (level, on) in branch.guides.enumerated() where on {
                path.move(to: CGPoint(x: x(level), y: 0))
                path.addLine(to: CGPoint(x: x(level), y: size.height))
            }
            let level = branch.depth - 1
            let radius: CGFloat = 6
            path.move(to: CGPoint(x: x(level), y: 0))
            path.addLine(to: CGPoint(x: x(level), y: mid - radius))
            path.addQuadCurve(
                to: CGPoint(x: x(level) + radius, y: mid),
                control: CGPoint(x: x(level), y: mid))
            path.addLine(to: CGPoint(x: x(level + 1) - 13, y: mid))
            if !branch.last {
                path.move(to: CGPoint(x: x(level), y: mid - radius))
                path.addLine(to: CGPoint(x: x(level), y: size.height))
            }
        }
        .frame(width: CGFloat(branch.depth + 1) * RaptorSidebar.indent)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Rex's "•••" on a working row: three dots pulsing one after another.
struct RaptorWorkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<3) { i in
                    Circle()
                        .frame(width: 3.5, height: 3.5)
                        .opacity(0.35 + 0.65 * (sin((t - Double(i) * 0.2) * 2 * .pi / 1.2) + 1) / 2)
                }
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityLabel("Working")
    }
}

extension View {
    /// Fade a line out at its end instead of ending it in an ellipsis, as Rex does.
    func fadeTruncated() -> some View {
        lineLimit(1)
            .fixedSize()
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .mask(HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 24)
            })
    }
}

/// Where a directory sits in git: the repository's common directory, shared by its main
/// checkout and every linked worktree, and whether this is a linked worktree. Read the
/// way git finds them, from `.git` and the files it points to, without running git.
struct RaptorGitCheckout: Equatable {
    let commonDir: String
    let isLinked: Bool

    /// The checkout holding `dir`, nil outside any.
    static func resolve(_ dir: String, fileManager fm: FileManager = .default) -> RaptorGitCheckout? {
        var url = URL(fileURLWithPath: dir).standardizedFileURL
        while true {
            let dotGit = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue { return .init(commonDir: canonical(dotGit), isLinked: false) }
                // A worktree's or submodule's .git file: "gitdir: <path>".
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
                let gitDir = path(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), in: url)
                // A linked worktree's git dir names the common one in "commondir".
                let common = (try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8))
                    .map { path($0.trimmingCharacters(in: .whitespacesAndNewlines), in: gitDir) }
                    ?? gitDir
                let commonDir = canonical(common), own = canonical(gitDir)
                return .init(commonDir: commonDir, isLinked: commonDir != own)
            }
            let up = url.deletingLastPathComponent()
            if up.path == url.path { return nil }
            url = up
        }
    }

    /// `p` as git reads it: absolute, or relative to the directory `base`.
    private static func path(_ p: String, in base: URL) -> URL {
        (p.hasPrefix("/") ? URL(fileURLWithPath: p) : base.appendingPathComponent(p)).standardizedFileURL
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
