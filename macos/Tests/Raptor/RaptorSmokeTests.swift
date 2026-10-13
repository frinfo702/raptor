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
        XCTAssertNil(client.controllers[created.session])
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
}
