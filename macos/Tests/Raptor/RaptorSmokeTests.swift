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
}
