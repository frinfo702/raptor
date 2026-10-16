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
        /// Some pane runs an agent, which Activity Mode shows even without a status.
        let hasAgent: Bool
        /// The block whose program made this tab.
        let parent: String?
        let blocks: [String]
        /// The git checkout the focused pane is in.
        var checkout: RaptorGitCheckout?

        var id: String { tab.id }
        var isWorking: Bool { status?.state == "working" }
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

    private func update(_ block: String, _ change: (inout RaptorController.Block) -> Void) {
        guard var b = blocks[block] else { return }
        change(&b)
        guard b != blocks[block] else { return }
        blocks[block] = b
        rebuild()
    }

    private func rebuild() {
        let sessions = views.map { id, view in
            Session(id: id, label: view.label, tabs: view.windows.map { w in
                let ids = w.blocks.map(\.id)
                // A working pane speaks for its tab, else the latest news does.
                let status = ids.compactMap { statuses[$0] }.max {
                    ($0.state == "working" ? 1 : 0, $0.updated_at) < ($1.state == "working" ? 1 : 0, $1.updated_at)
                }
                return Tab(
                    tab: RaptorController.tab(w, blocks: blocks),
                    session: id,
                    status: status,
                    hasAgent: ids.contains { blocks[$0]?.program.isAgent == true },
                    parent: w.parent,
                    blocks: ids,
                    checkout: checkout(blocks[w.focused_block]?.pwd ?? ""))
            })
        }
        if sessions != self.sessions { self.sessions = sessions }
    }

    private func checkout(_ dir: String) -> RaptorGitCheckout? {
        guard !dir.isEmpty else { return nil }
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
    /// Activity Mode keeps only tabs with an agent or a status; a session left with none
    /// goes, and a kept tab whose parent went falls back to the next rule, or the top.
    static func rows(_ sessions: [Session], activity: Bool) -> [Row] {
        let shown = sessions.map { s in
            (s, s.tabs.filter { !activity || $0.status != nil || $0.hasAgent })
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

    /// How long ago, as Rex shows it: "now", then minutes, hours and days.
    static func age(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    /// A status as its row's second line: the program's message, else its state.
    static func statusLine(_ status: RaptorController.SessionView.Status?) -> String {
        guard let status else { return "Idle" }
        if let msg = status.msg, !msg.isEmpty { return msg }
        return status.state.prefix(1).uppercased() + status.state.dropFirst()
    }
}

/// The vertical sidebar: a header with the traffic lights, the sidebar toggle and the
/// Activity Mode eye; the host, each session and its tabs; and a footer of actions.
/// Sizes are Rex's, from the captain's reference frames at 2x.
struct RaptorSidebar: View {
    @ObservedObject var model: RaptorSidebarModel
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
        let rows = RaptorSidebarModel.rows(model.sessions, activity: appearance.activity)
        VStack(spacing: 0) {
            // SwiftUI stretches the scroll view up into the title bar's safe area, so
            // the header stays in front of it to keep its buttons' clicks.
            header
                .zIndex(1)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    RaptorSidebarHost(name: "This Mac", symbol: "laptopcomputer")
                    ForEach(rows) { row in
                        switch row {
                        case .session(_, let label, let first):
                            RaptorSidebarSessionHeader(label: label, first: first)
                                .transition(.opacity)
                        case .tab(let tab, let branch):
                            RaptorSidebarRow(
                                tab: tab,
                                branch: branch,
                                selected: tab.session == controller.session && tab.id == controller.activeTab,
                                activity: appearance.activity,
                                tokens: tokens
                            ) {
                                controller.show(tab: tab.id, in: tab.session)
                            }
                            .transition(.opacity)
                        case .more(_, let hidden, let branch):
                            RaptorSidebarMore(
                                branch: branch,
                                selected: hidden.contains {
                                    $0.session == controller.session && $0.id == controller.activeTab
                                },
                                activity: appearance.activity,
                                tokens: tokens
                            )
                            .transition(.opacity)
                        }
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
            RaptorActivityButton(on: appearance.activity, tokens: tokens) {
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
                Toggle("Show Activity", isOn: Binding(
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
            .help("Filter")
            .accessibilityLabel("Filter")
            Spacer(minLength: 0)
            RaptorTitlebarButton(symbol: "rectangle.stack.badge.plus", help: "New Session ⇧⌘N") {
                controller.newSession()
            }
            // ponytail: one host until rap reaches remote machines; the button holds its place.
            RaptorTitlebarButton(symbol: "network", help: "Add Host (remote hosts aren't supported yet)") {}
                .disabled(true)
        }
        .padding(.leading, 12)
        .padding(.trailing, 13)
        .frame(height: 40)
        .padding(.bottom, 4)
    }
}

/// The eye that turns Activity Mode on and off: an outline, or on a filled circle.
struct RaptorActivityButton: View {
    let on: Bool
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "eye")
                .font(.system(size: 14, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(on ? RaptorSidebarRow.raised(tokens) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(on ? "Hide Activity ⇧⌘A" : "Show Activity ⇧⌘A")
        .accessibilityLabel("Show Activity")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
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

/// A tab: its program's tile and title, nested under the tab that made it, with a
/// pulsing "•••" while it works. Activity Mode adds the status line and how long ago
/// it changed.
struct RaptorSidebarRow: View {
    let tab: RaptorSidebarModel.Tab
    let branch: RaptorSidebarModel.Branch
    let selected: Bool
    let activity: Bool
    let tokens: ThemeTokens
    let select: () -> Void

    /// The selection pill and the eye's circle lift the chrome as the tab strip's pill
    /// does, so they stay translucent over Blended and Glass.
    static func raised(_ tokens: ThemeTokens) -> Color {
        tokens.isLight ? .black.opacity(0.05) : .white.opacity(0.05)
    }

    static func raisedBorder(_ tokens: ThemeTokens) -> Color {
        // Over the fill: #2F2F2F on Rex's #111111 chrome.
        tokens.isLight ? .black.opacity(0.1) : .white.opacity(0.08)
    }

    var body: some View {
        let height = activity ? RaptorSidebar.activityRowHeight : RaptorSidebar.rowHeight
        let parts = RaptorTabView.titleParts(tab.tab.title, program: tab.tab.program.name)
        HStack(spacing: 8) {
            RaptorCardFace(program: tab.tab.program, light: tokens.isLight, height: 18)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    (Text(parts.name) + Text(parts.path).foregroundColor(.secondary))
                        .font(.system(size: 13))
                        .fadeTruncated()
                    if tab.isWorking { RaptorWorkingDots() }
                }
                if activity {
                    HStack(spacing: 6) {
                        Text(RaptorSidebarModel.statusLine(tab.status))
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
        .background { Self.pill(selected: selected, height: height, activity: activity, tokens: tokens) }
        .contentShape(Rectangle())
        .padding(.horizontal, RaptorSidebar.selectionInset)
        .frame(height: height)
        .background(alignment: .leading) {
            RaptorTreeConnector(branch: branch)
                .padding(.leading, RaptorSidebar.selectionInset + 10)
        }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }

    @ViewBuilder
    static func pill(selected: Bool, height: CGFloat, activity: Bool, tokens: ThemeTokens) -> some View {
        if selected {
            let shape = RoundedRectangle(cornerRadius: activity ? 15 : (height - 3) / 2, style: .continuous)
            shape.fill(raised(tokens))
                .overlay(shape.strokeBorder(raisedBorder(tokens), lineWidth: 1))
        }
    }

    private var accessibilityLabel: String {
        var label = tab.tab.title
        if tab.isWorking || activity { label += ", " + RaptorSidebarModel.statusLine(tab.status) }
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
                RaptorSidebarRow.pill(selected: selected, height: height, activity: activity, tokens: tokens)
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
