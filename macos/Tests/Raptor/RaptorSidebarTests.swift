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
        parent: String? = nil
    ) -> Model.Tab {
        Model.Tab(
            tab: .init(id: id, title: id, program: agent ? RaptorProgram.identify("claude")! : .shell, others: []),
            session: session,
            status: status.map { .init(state: $0, msg: nil, updated_at: 0) },
            hasAgent: agent,
            parent: parent,
            blocks: ["block:\(id)"])
    }

    /// Each row as text: "#session", or a tab's id indented two spaces per level.
    private func outline(_ rows: [Model.Row]) -> [String] {
        rows.map { row in
            switch row {
            case .session(let id, _, _): "#" + id
            case .tab(let t, let branch): String(repeating: "  ", count: branch.depth) + t.id
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
