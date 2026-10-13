import AppKit
import XCTest
@testable import Ghostty

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
}
