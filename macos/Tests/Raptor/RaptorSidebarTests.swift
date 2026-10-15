import Foundation
import Testing
@testable import Ghostty

/// The sidebar's rows: sessions and their tabs, tabs made by another tab's program
/// nested under it, and Activity Mode's filter.
struct RaptorSidebarTests {
    typealias Model = RaptorSidebarModel

    private func tab(
        _ id: String,
        _ session: String,
        status: String? = nil,
        agent: Bool = false,
        parent: String? = nil,
        repo: String? = nil,
        linked: Bool = false
    ) -> Model.Tab {
        Model.Tab(
            tab: .init(id: id, title: id, program: agent ? RaptorProgram.identify("claude")! : .shell, others: []),
            session: session,
            status: status.map { .init(state: $0, msg: nil, updated_at: 0) },
            hasAgent: agent,
            parent: parent,
            blocks: ["block:\(id)"],
            checkout: repo.map { RaptorGitCheckout(commonDir: $0, isLinked: linked) })
    }

    /// Each row as text: "#session", or a tab's id indented two spaces per level.
    private func outline(_ rows: [Model.Row]) -> [String] {
        rows.map { row in
            switch row {
            case .session(let id, _, _): "#" + id
            case .tab(let t, let branch): String(repeating: "  ", count: branch.depth) + t.id
            case .more(_, let branch): String(repeating: "  ", count: branch.depth) + "…"
            }
        }
    }

    @Test func sessionsListTheirTabsInOrder() {
        let sessions = [
            Model.Session(id: "a", label: "a", tabs: [tab("a1", "a"), tab("a2", "a")]),
            Model.Session(id: "b", label: "b", tabs: [tab("b1", "b")]),
        ]
        #expect(outline(Model.rows(sessions, activity: false)) == ["#a", "a1", "a2", "#b", "b1"])
    }

    @Test func tabsMadeByAnotherTabNestUnderIt() {
        let sessions = [
            Model.Session(id: "a", label: "a", tabs: [
                tab("lead", "a", agent: true),
                tab("other", "a"),
                tab("sub1", "a", parent: "block:lead"),
                tab("subsub", "a", parent: "block:sub1"),
                tab("sub2", "a", parent: "block:lead"),
            ]),
            // A session made from a tab's program hangs under that tab, and loses its
            // header with nothing left at its top level.
            Model.Session(id: "b", label: "b", tabs: [tab("b1", "b", parent: "block:other")]),
        ]
        #expect(outline(Model.rows(sessions, activity: false)) == [
            "#a", "lead", "  sub1", "    subsub", "  sub2", "other", "  b1",
        ])
    }

    @Test func connectorsEndAtTheLastChildAndCarryPastEarlierOnes() {
        let sessions = [Model.Session(id: "a", label: "a", tabs: [
            tab("lead", "a"),
            tab("sub1", "a", parent: "block:lead"),
            tab("subsub", "a", parent: "block:sub1"),
            tab("sub2", "a", parent: "block:lead"),
        ])]
        let branches = Model.rows(sessions, activity: false).compactMap { row -> Model.Branch? in
            if case .tab(_, let b) = row { return b }
            return nil
        }
        #expect(branches.map(\.hasChildren) == [true, true, false, false])
        #expect(branches.map(\.last) == [false, false, true, true])
        // subsub's line runs on past sub1's level, since sub2 comes after.
        #expect(branches[2].guides == [true])
        #expect(branches[3].guides == [])
    }

    @Test func unknownOrLoopingParentsStayAtTheTop() {
        let sessions = [Model.Session(id: "a", label: "a", tabs: [
            tab("orphan", "a", parent: "block:gone"),
            tab("self", "a", parent: "block:self"),
        ])]
        #expect(outline(Model.rows(sessions, activity: false)) == ["#a", "orphan", "self"])
    }

    @Test func activityKeepsOnlyAgentsAndStatuses() {
        let sessions = [
            Model.Session(id: "a", label: "a", tabs: [tab("agent", "a", agent: true), tab("shell", "a")]),
            Model.Session(id: "b", label: "b", tabs: [tab("brew", "b", status: "done")]),
            Model.Session(id: "c", label: "c", tabs: [tab("nvim", "c")]),
        ]
        #expect(outline(Model.rows(sessions, activity: true)) == ["#a", "agent", "#b", "brew"])
    }

    @Test func activityMovesAKeptChildOfAHiddenTabUp() {
        let sessions = [Model.Session(id: "a", label: "a", tabs: [
            tab("shell", "a"),
            tab("codex", "a", status: "working", parent: "block:shell"),
        ])]
        #expect(outline(Model.rows(sessions, activity: false)) == ["#a", "shell", "  codex"])
        #expect(outline(Model.rows(sessions, activity: true)) == ["#a", "codex"])
    }

    @Test func worktreesNestUnderTheirMainCheckout() {
        let sessions = [
            Model.Session(id: "a", label: "a", tabs: [
                tab("wt1", "a", repo: "/r/.git", linked: true),
                tab("main", "a", repo: "/r/.git"),
                tab("main2", "a", repo: "/r/.git"),
                tab("other", "a", repo: "/o/.git", linked: true),
            ]),
            Model.Session(id: "b", label: "b", tabs: [tab("wt2", "b", repo: "/r/.git", linked: true)]),
        ]
        // Under the first main checkout tab, from any session; a worktree whose main
        // checkout has no tab stays put.
        #expect(outline(Model.rows(sessions, activity: false)) == [
            "#a", "main", "  wt1", "  wt2", "main2", "other",
        ])
    }

    @Test func theTabThatMadeATabComesBeforeItsWorktree() {
        let sessions = [Model.Session(id: "a", label: "a", tabs: [
            tab("main", "a", repo: "/r/.git"),
            tab("lead", "a", agent: true),
            // An agent's tab working in a worktree stays with the agent.
            tab("sub", "a", parent: "block:lead", repo: "/r/.git", linked: true),
            // A worktree tab under the main checkout can still make tabs of its own.
            tab("wt", "a", repo: "/r/.git", linked: true),
            tab("wtsub", "a", parent: "block:wt"),
        ])]
        #expect(outline(Model.rows(sessions, activity: false)) == [
            "#a", "main", "  wt", "    wtsub", "lead", "  sub",
        ])
        // With the agent filtered out of sight its worktree tab falls back to the checkout.
        let hidden = [Model.Session(id: "a", label: "a", tabs: [
            tab("main", "a", status: "done", repo: "/r/.git"),
            tab("lead", "a"),
            tab("sub", "a", status: "working", parent: "block:lead", repo: "/r/.git", linked: true),
        ])]
        #expect(outline(Model.rows(hidden, activity: true)) == ["#a", "main", "  sub"])
    }

    @Test func tabsWhoseParentsLoopStayAtTheTop() {
        // The main checkout was made by a tab in its own worktree.
        let sessions = [Model.Session(id: "a", label: "a", tabs: [
            tab("wt", "a", repo: "/r/.git", linked: true),
            tab("main", "a", parent: "block:wt", repo: "/r/.git"),
            tab("leaf", "a", parent: "block:main"),
        ])]
        #expect(outline(Model.rows(sessions, activity: false)) == ["#a", "wt", "main", "  leaf"])
    }

    @Test func tabsDeeperThanThreeLevelsCollapseIntoOneEllipsisRow() {
        let sessions = [Model.Session(id: "a", label: "a", tabs: [
            tab("lead", "a"),
            tab("sub", "a", parent: "block:lead"),
            tab("subsub", "a", parent: "block:sub"),
            tab("deep", "a", parent: "block:subsub"),
            tab("deep2", "a", parent: "block:subsub"),
            tab("deeper", "a", parent: "block:deep"),
        ])]
        let rows = Model.rows(sessions, activity: false)
        // Everything under subsub is hidden behind one "…" whose elbow ends at that row.
        #expect(outline(rows) == ["#a", "lead", "  sub", "    subsub", "      …"])
        #expect(rows.last == .more(
            id: "subsub", Model.Branch(guides: [false, false], last: true, isChild: true)))
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func activityModeCapsDepthTheSameWay() {
        let sessions = [Model.Session(id: "a", label: "a", tabs: [
            tab("lead", "a", agent: true),
            tab("sub", "a", status: "working", parent: "block:lead"),
            tab("subsub", "a", status: "working", parent: "block:sub"),
            tab("deep", "a", status: "working", parent: "block:subsub"),
        ])]
        #expect(outline(Model.rows(sessions, activity: true)) == ["#a", "lead", "  sub", "    subsub", "      …"])
    }

    @Test func agesReadAsRexShowsThem() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(Model.age(now.addingTimeInterval(-5), now: now) == "now")
        #expect(Model.age(now.addingTimeInterval(-125), now: now) == "2m")
        #expect(Model.age(now.addingTimeInterval(-12 * 3600), now: now) == "12h")
        #expect(Model.age(now.addingTimeInterval(-3 * 86400), now: now) == "3d")
        // Clocks that disagree never show a time to come.
        #expect(Model.age(now.addingTimeInterval(30), now: now) == "now")
    }

    @Test func directoriesAreThePathOfTheShellsURL() {
        #expect(RaptorController.path("file://mac/Users/me/My%20Apps") == "/Users/me/My Apps")
        #expect(RaptorController.path("kitty-shell-cwd://mac/Users/me/100%") == "/Users/me/100%")
        #expect(RaptorController.path("/Users/me") == "/Users/me")
        #expect(RaptorController.path("") == "")
    }

    @Test func statusLineIsTheMessageElseTheState() {
        #expect(Model.statusLine(.init(state: "working", msg: nil, updated_at: 0)) == "Working")
        #expect(Model.statusLine(.init(state: "done", msg: "Upgraded 12 packages", updated_at: 0)) == "Upgraded 12 packages")
        #expect(Model.statusLine(nil) == "Idle")
    }
}

/// Finding a directory's repository and whether it is a linked worktree, as git does.
struct RaptorGitCheckoutTests {
    private let fm = FileManager.default

    private func tempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("raptor-git-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    private func write(_ text: String, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// git's own layout: repo/.git, a worktree's .git file pointing at
    /// repo/.git/worktrees/<name>, whose commondir leads back to repo/.git.
    @Test func mainCheckoutAndLinkedWorktreeShareTheCommonDir() throws {
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try fm.createDirectory(at: repo.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try write("../..\n", repo.appendingPathComponent(".git/worktrees/wt/commondir"))
        let wt = root.appendingPathComponent("wt")
        try write("gitdir: \(repo.path)/.git/worktrees/wt\n", wt.appendingPathComponent(".git"))
        try fm.createDirectory(at: wt.appendingPathComponent("sub"), withIntermediateDirectories: true)

        let main = RaptorGitCheckout.resolve(repo.appendingPathComponent("src/deep").path)
        let linked = RaptorGitCheckout.resolve(wt.appendingPathComponent("sub").path)
        #expect(main?.isLinked == false)
        #expect(linked?.isLinked == true)
        #expect(main?.commonDir != nil)
        #expect(main?.commonDir == linked?.commonDir)
    }

    @Test func relativeGitdirAndSubmodulesAndPlainDirectories() throws {
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        // A relative gitdir, as `git worktree add --relative-paths` writes.
        let repo = root.appendingPathComponent("repo")
        try write("../..\n", repo.appendingPathComponent(".git/worktrees/rel/commondir"))
        let rel = root.appendingPathComponent("rel")
        try write("gitdir: ../repo/.git/worktrees/rel\n", rel.appendingPathComponent(".git"))
        #expect(RaptorGitCheckout.resolve(rel.path) == RaptorGitCheckout.resolve(repo.path).map {
            RaptorGitCheckout(commonDir: $0.commonDir, isLinked: true)
        })
        // A submodule's git dir has no commondir: its own repository, not a worktree.
        try fm.createDirectory(at: repo.appendingPathComponent(".git/modules/lib"), withIntermediateDirectories: true)
        try write("gitdir: ../.git/modules/lib\n", repo.appendingPathComponent("lib/.git"))
        #expect(RaptorGitCheckout.resolve(repo.appendingPathComponent("lib").path)?.isLinked == false)
        // Outside any repository.
        let plain = root.appendingPathComponent("plain")
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(RaptorGitCheckout.resolve(plain.path) == nil)
    }

    /// The same answers for a worktree that git itself made.
    @Test func realGitWorktree() throws {
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        func git(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", root.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "git \(args)")
        }
        try git("init", "-q", "repo")
        try git("-C", "repo", "commit", "-q", "--allow-empty", "-m", "x")
        try git("-C", "repo", "worktree", "add", "-q", "../wt")
        let main = RaptorGitCheckout.resolve(root.appendingPathComponent("repo").path)
        let linked = RaptorGitCheckout.resolve(root.appendingPathComponent("wt").path)
        #expect(main?.isLinked == false)
        #expect(linked?.isLinked == true)
        #expect(main?.commonDir == linked?.commonDir)
    }
}
