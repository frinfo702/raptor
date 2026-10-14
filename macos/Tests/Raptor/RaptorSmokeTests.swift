import AppKit
import XCTest
@testable import Ghostty
import GhosttyKit

/// Launch-and-attach: the app starts a private rap server from its bundled helper,
/// opens a session window whose pane shows the block's output, and closing the window
/// only detaches.
final class RaptorSmokeTests: XCTestCase {
    private struct Created: Decodable {
        let session: String
    }

    private struct SessionList: Decodable {
        struct Session: Decodable { let id: String }
        let sessions: [Session]
    }

    @MainActor
    func testLaunchAndAttach() throws {
        // Directly in /tmp: sun_path is short.
        let socket = "/tmp/raptor-xctest-\(getpid()).sock"
        let client = try XCTUnwrap(RaptorClient(socket: socket), "no server started from the bundled rap")
        defer {
            client.call("server.stop")
            unlink(socket + ".lock")
        }
        let ghostty = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.ghostty)

        let created: Created = try XCTUnwrap(client.call("session.create", [
            "command": ["/bin/sh", "-c", "echo raptor-smoke; exec sleep 60"],
        ]))
        let controller = client.open(ghostty, session: created.session)
        XCTAssertEqual(controller.tabs.count, 1)

        // The pane is a surface bound to the block, showing what the block printed.
        let deadline = Date().addingTimeInterval(15)
        var text = ""
        while Date() < deadline {
            text = controller.surfaceTree.first?.cachedScreenContents.get() ?? ""
            if text.contains("raptor-smoke") { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(text.contains("raptor-smoke"), "pane shows: \(text)")

        // Closing the window detaches: the session lives on.
        controller.window?.close()
        XCTAssertFalse(client.controllers.contains { $0.session == created.session })
        let list: SessionList = try XCTUnwrap(client.call("session.list"))
        XCTAssertTrue(list.sessions.contains { $0.id == created.session })
        client.call("session.kill", ["session": created.session])
    }

    /// `rap run` from outside the app, the New Tab menu item and the ⌘T keybinding each
    /// add a tab to the session's window, never a plain Ghostty window.
    @MainActor
    func testServerWindowsBecomeTabs() throws {
        let socket = "/tmp/raptor-xctest-tabs-\(getpid()).sock"
        let client = try XCTUnwrap(RaptorClient(socket: socket), "no server started from the bundled rap")
        defer {
            client.call("server.stop")
            unlink(socket + ".lock")
        }
        let ghostty = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.ghostty)
        let created: Created = try XCTUnwrap(client.call("session.create", [
            "command": ["/bin/sh", "-c", "exec sleep 60"],
        ]))
        defer { client.call("session.kill", ["session": created.session]) }
        let controller = client.open(ghostty, session: created.session)
        let plain = TerminalController.all.count

        func waitForTabs(_ count: Int, _ what: String) {
            let deadline = Date().addingTimeInterval(10)
            while controller.tabs.count < count && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertEqual(controller.tabs.count, count, what)
            XCTAssertEqual(controller.activeTab, controller.tabs.last?.id, what)
            XCTAssertEqual(TerminalController.all.count, plain, "\(what) opened a plain window")
        }

        // The bundled CLI, run the way a user runs it from another terminal.
        let rap = Process()
        rap.executableURL = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "rap"))
        rap.arguments = ["-S", socket, "run", "--", "/bin/sleep", "60"]
        try rap.run()
        rap.waitUntilExit()
        XCTAssertEqual(rap.terminationStatus, 0)
        waitForTabs(2, "rap run")

        // File > New Tab, which goes up the responder chain to the app delegate even
        // when the app isn't active and has no main window.
        NSApp.sendAction(#selector(AppDelegate.newTab(_:)), to: nil, from: nil)
        waitForTabs(3, "New Tab menu item")

        // ⌘T as a keybinding: libghostty's new_tab action on the focused pane.
        let surface = try XCTUnwrap(controller.surfaceTree.first?.surface)
        ghostty.newTab(surface: surface)
        waitForTabs(4, "new_tab keybinding")

        controller.window?.close()
    }

    /// ⌘D, a pane header's split button, `rap split` from outside the app and ⌘T each
    /// hand the keyboard to the pane or tab they make, once the server shows it.
    @MainActor
    func testNewPanesTakeFocus() throws {
        let socket = "/tmp/raptor-xctest-focus-\(getpid()).sock"
        let client = try XCTUnwrap(RaptorClient(socket: socket), "no server started from the bundled rap")
        defer {
            client.call("server.stop")
            unlink(socket + ".lock")
        }
        let ghostty = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.ghostty)
        let created: Created = try XCTUnwrap(client.call("session.create", [
            "command": ["/bin/sh", "-c", "exec sleep 60"],
        ]))
        defer { client.call("session.kill", ["session": created.session]) }
        let controller = client.open(ghostty, session: created.session)
        defer { controller.window?.close() }

        /// Wait for a pane that wasn't there before to hold the keyboard.
        var old: [Ghostty.SurfaceView] = []
        func waitForNewFocus(_ what: String) {
            let deadline = Date().addingTimeInterval(10)
            var responder: Ghostty.SurfaceView?
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                responder = controller.window?.firstResponder as? Ghostty.SurfaceView
            } while (responder.map { old.contains($0) } ?? true) && Date() < deadline
            defer { old = Array(controller.surfaceTree) }
            guard let responder else { return XCTFail("\(what): no pane has the keyboard") }
            XCTAssertFalse(old.contains(responder), "\(what): focus stayed on an old pane")
            XCTAssertTrue(controller.surfaceTree.contains(responder), "\(what): focus is off the tab")
        }
        waitForNewFocus("open")

        // ⌘D: libghostty's new_split action on the focused pane.
        var focused = try XCTUnwrap(controller.window?.firstResponder as? Ghostty.SurfaceView)
        ghostty.split(surface: try XCTUnwrap(focused.surface), direction: GHOSTTY_SPLIT_DIRECTION_RIGHT)
        waitForNewFocus("new_split keybinding")

        // The header's Split Down button.
        focused = try XCTUnwrap(controller.window?.firstResponder as? Ghostty.SurfaceView)
        controller.split(focused, .down)
        waitForNewFocus("header split button")

        // The bundled CLI, which splits on the server without the app asking.
        let rap = Process()
        rap.executableURL = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "rap"))
        rap.arguments = ["-S", socket, "split", "-s", created.session]
        try rap.run()
        rap.waitUntilExit()
        XCTAssertEqual(rap.terminationStatus, 0)
        waitForNewFocus("rap split")

        // A pane picked here keeps the keyboard when the server closes another one.
        let newest = try XCTUnwrap(controller.window?.firstResponder as? Ghostty.SurfaceView)
        let panes = Array(controller.surfaceTree)
        let picked = try XCTUnwrap(panes.dropFirst().first { $0 !== newest })
        Ghostty.moveFocus(to: picked)
        var deadline = Date().addingTimeInterval(10)
        while controller.window?.firstResponder !== picked && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        client.call("block.close", ["block": try XCTUnwrap(controller.block(of: newest))])
        deadline = Date().addingTimeInterval(10)
        while controller.surfaceTree.contains(newest) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(controller.surfaceTree.contains(newest), "block.close: the pane stayed")
        XCTAssertTrue(controller.window?.firstResponder === picked, "block.close: focus left the picked pane")
        old = Array(controller.surfaceTree)

        // ⌘T: libghostty's new_tab action.
        focused = try XCTUnwrap(controller.window?.firstResponder as? Ghostty.SurfaceView)
        ghostty.newTab(surface: try XCTUnwrap(focused.surface))
        waitForNewFocus("new_tab keybinding")
        XCTAssertEqual(controller.tabs.count, 2)
    }

    /// Settings → Appearance applies to an open window at once, keeping its panes:
    /// the same surfaces stay bound to the same blocks.
    @MainActor
    func testAppearanceAppliesLive() throws {
        let socket = "/tmp/raptor-xctest-look-\(getpid()).sock"
        let client = try XCTUnwrap(RaptorClient(socket: socket), "no server started from the bundled rap")
        let appearance = RaptorAppearance.shared
        let keys = ["RaptorInterfaceStyle", "RaptorPaneDensity", "RaptorPaneHeaders"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let (style, density, headers) = (appearance.style, appearance.density, appearance.paneHeaders)
        defer {
            client.call("server.stop")
            unlink(socket + ".lock")
            (appearance.style, appearance.density, appearance.paneHeaders) = (style, density, headers)
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
        }
        let ghostty = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.ghostty)
        let created: Created = try XCTUnwrap(client.call("session.create", [
            "command": ["/bin/sh", "-c", "exec sleep 60"],
        ]))
        defer { client.call("session.kill", ["session": created.session]) }
        let controller = client.open(ghostty, session: created.session)
        defer { controller.window?.close() }
        let first = try XCTUnwrap(controller.surfaceTree.first)
        _ = controller.newSplit(at: first, direction: .right)

        func settle(until done: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(5)
            repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } while !done() && Date() < deadline
        }
        settle { Array(controller.surfaceTree).count == 2 }
        let panes = Array(controller.surfaceTree)
        XCTAssertEqual(panes.count, 2)

        for s in RaptorAppearance.Style.allCases {
            for d in RaptorAppearance.Density.allCases {
                for h in [true, false] {
                    (appearance.style, appearance.density, appearance.paneHeaders) = (s, d, h)
                    let glass = appearance.effectiveStyle == .glass
                    /// Glass is tinted like Blended, not at the panes' background-opacity.
                    var glassTint: Double? { controller.terminalViewContainer?.derivedConfig?.backgroundOpacity }
                    settle {
                        controller.window?.isOpaque == (appearance.effectiveStyle == .solid) &&
                            (glassTint == (glass ? RaptorWindowBackground.tint : nil))
                    }
                    let what = "\(s) \(d) headers \(h)"
                    XCTAssertEqual(controller.window?.isOpaque, appearance.effectiveStyle == .solid, what)
                    XCTAssertEqual(glassTint, glass ? RaptorWindowBackground.tint : nil, what)
                    XCTAssertEqual(Array(controller.surfaceTree), panes, "\(what) replaced a pane")
                    XCTAssertTrue(panes.allSatisfy { $0.window === controller.window }, "\(what) took a pane off screen")
                    XCTAssertTrue(panes.allSatisfy { controller.block(of: $0) != nil }, "\(what) unbound a pane")
                }
            }
        }
    }

    private struct Size: Decodable, Equatable {
        let cols: Int
        let rows: Int
    }

    /// Two windows on one session: both show `rap split` live, and the block takes the
    /// size of whichever window last focused it, since each window is its own client.
    @MainActor
    func testTwoWindowsOneSession() throws {
        let socket = "/tmp/raptor-xctest-two-\(getpid()).sock"
        let client = try XCTUnwrap(RaptorClient(socket: socket), "no server started from the bundled rap")
        defer {
            client.call("server.stop")
            unlink(socket + ".lock")
        }
        let ghostty = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.ghostty)
        let created: Created = try XCTUnwrap(client.call("session.create", [
            "command": ["/bin/sh", "-c", "exec sleep 60"],
        ]))
        defer { client.call("session.kill", ["session": created.session]) }
        let a = client.open(ghostty, session: created.session)
        let b = client.newWindow(ghostty, session: created.session)
        defer {
            a.window?.close()
            b.window?.close()
        }
        XCTAssertEqual(client.controllers.filter { $0.session == created.session }.count, 2)
        XCTAssertNotEqual(a.stream, b.stream, "the windows share a connection")
        a.window?.setFrame(NSRect(x: 100, y: 100, width: 1000, height: 700), display: true)
        b.window?.setFrame(NSRect(x: 200, y: 200, width: 600, height: 400), display: true)

        func wait(_ what: String, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !done() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertTrue(done(), what)
        }

        // The bundled CLI splits on the server; both windows show the new pane.
        let rap = Process()
        rap.executableURL = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "rap"))
        rap.arguments = ["-S", socket, "split", "-s", created.session, "--", "/bin/sleep", "60"]
        try rap.run()
        rap.waitUntilExit()
        XCTAssertEqual(rap.terminationStatus, 0)
        wait("rap split shows in both windows") {
            Array(a.surfaceTree).count == 2 && Array(b.surfaceTree).count == 2
        }

        // Focus the same block in each window in turn: its size follows, and
        // `rap events` names a different owner each time.
        let block = try XCTUnwrap(a.surfaceTree.first.flatMap(a.block(of:)))
        let events = Process()
        let out = Pipe()
        events.executableURL = rap.executableURL
        events.arguments = ["-S", socket, "events"]
        events.standardOutput = out
        try events.run()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func size() -> Size? { client.call("block.method", ["block": block, "method": "size"]) }
        func focus(_ c: RaptorController) throws {
            let pane = try XCTUnwrap(Array(c.surfaceTree).first { c.block(of: $0) == block })
            Ghostty.moveFocus(to: pane)
            // The test runner may not let the app take the keyboard, so make the
            // window key the way AppKit tells it.
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: c.window)
        }
        try focus(a)
        var sizeA: Size?
        wait("the block takes window A's size") {
            sizeA = size()
            return (sizeA?.cols ?? 0) > 50
        }
        try focus(b)
        wait("focusing the pane in window B moves the size to B") {
            guard let s = size(), let sizeA else { return false }
            return s.cols < sizeA.cols && s.rows < sizeA.rows
        }
        try focus(a)
        wait("and back to A") { size() == sizeA }

        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        events.terminate()
        events.waitUntilExit()
        let text = String(bytes: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let owners = text.split(separator: "\n")
            .filter { $0.contains("\"size_changed\"") && $0.contains(block) }
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .compactMap { $0["owner"] as? String }
        print("size_changed owners for \(block): \(owners)")
        // A may own the block already, so only the moves to B and back are certain.
        let moves = Array(owners.suffix(2))
        XCTAssertEqual(moves.count, 2, text)
        XCTAssertNotEqual(moves.first, moves.last, "B and A are different owners: \(owners)")
    }
}
