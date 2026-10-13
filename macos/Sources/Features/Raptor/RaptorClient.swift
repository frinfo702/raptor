import AppKit
import CryptoKit
import GhosttyKit
import os

/// The app's one connection to the rap server. It lives as long as the app: surfaces
/// configured by a client point into it, so it is never freed.
final class RaptorClient {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "raptor"
    )

    /// Nil if no server could be reached or started.
    static let shared: RaptorClient? = RaptorClient()

    let client: rap_client_t

    /// The open session windows by session id.
    var controllers: [String: RaptorController] = [:]

    /// Connect to the server on `socket`, else on the default socket, starting it if needed.
    init?(socket: String? = nil) {
        guard Self.startServer(socket: socket), let client = rap_client_connect(socket) else {
            Self.logger.warning("no rap server")
            return nil
        }
        self.client = client
        rap_client_set_event_callback(client, { userdata, json in
            guard let userdata, let json else { return }
            let me = Unmanaged<RaptorClient>.fromOpaque(userdata).takeUnretainedValue()
            let data = Data(bytes: json, count: strlen(json))
            DispatchQueue.main.async { me.handle(data) }
        }, Unmanaged.passRetained(self).toOpaque())
        call("session.subscribe")
    }

    // MARK: Server

    /// Copy the bundled `rap` to a path named for its contents, outside the bundle, and
    /// start a server from there if none is running. An app update then never swaps the
    /// binary out from under a running server. False if no server could be started.
    private static func startServer(socket: String?) -> Bool {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "rap"),
              let rap = versionedCopy(of: bundled) else {
            logger.warning("no rap helper in the app bundle")
            return false
        }
        let process = Process()
        process.executableURL = rap
        process.arguments = ["server", "start"] + (socket.map { ["-S", $0] } ?? [])
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.warning("starting the rap server failed: \(error, privacy: .public)")
            return false
        }
        return process.terminationStatus == 0
    }

    // ponytail: copies of older builds pile up; prune ones no server runs from if it matters.
    static func versionedCopy(of bundled: URL) -> URL? {
        guard let data = try? Data(contentsOf: bundled) else { return nil }
        let id = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Raptor/bin/\(id)", isDirectory: true)
        let rap = dir.appendingPathComponent("rap")
        if fm.isExecutableFile(atPath: rap.path) { return rap }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Copy then rename, so no one ever runs a half-written binary.
            let tmp = dir.appendingPathComponent("rap.\(getpid())")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: bundled, to: tmp)
            try fm.moveItem(at: tmp, to: rap)
        } catch {
            if !fm.isExecutableFile(atPath: rap.path) { return nil }
        }
        return rap
    }

    // MARK: Requests

    private struct Response<T: Decodable>: Decodable {
        let result: T?
    }

    private struct Ignored: Decodable {}

    /// Make a request and decode its result, nil if it failed.
    func call<T: Decodable>(_ method: String, _ params: [String: Any] = [:]) -> T? {
        guard let body = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params]),
              let json = String(data: body, encoding: .utf8),
              let resp = rap_client_request(client, json) else { return nil }
        defer { free(resp) }
        let data = Data(bytes: resp, count: strlen(resp))
        return (try? JSONDecoder().decode(Response<T>.self, from: data))?.result
    }

    /// Make a request whose result doesn't matter. False if it failed.
    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) -> Bool {
        let result: Ignored? = call(method, params)
        return result != nil
    }

    // MARK: Events

    private struct Event: Decodable {
        let event: String
        let session: String?
        let block: String?
        let title: String?
        let pwd: String?
        let foreground: Foreground?

        struct Foreground: Decodable { let name: String? }
    }

    private func handle(_ data: Data) {
        guard let event = try? JSONDecoder().decode(Event.self, from: data) else { return }
        switch event.event {
        case "server_reconnected":
            controllers.values.forEach { $0.refresh() }
        case "session_destroyed":
            if let id = event.session { controllers[id]?.sessionDestroyed() }
        case "title_changed":
            if let id = event.session, let block = event.block {
                controllers[id]?.titleChanged(block: block, to: event.title ?? "")
            }
        case "pwd_changed":
            if let id = event.session, let block = event.block {
                controllers[id]?.pwdChanged(block: block, to: event.pwd ?? "")
            }
        case "process_changed":
            if let id = event.session, let block = event.block {
                controllers[id]?.processChanged(block: block, to: event.foreground?.name)
            }
        case "session_view_changed", "session_label_changed":
            if let id = event.session { controllers[id]?.refresh() }
        default:
            break
        }
    }

    // MARK: Sessions

    private struct SessionList: Decodable {
        struct Session: Decodable { let id: String }
        let sessions: [Session]
    }

    private struct Created: Decodable {
        let session: String
    }

    private static let attachedKey = "RaptorAttachedSessions"

    /// The sessions that had windows, for reopening on the next launch.
    static var attached: [String] {
        get { UserDefaults.standard.stringArray(forKey: attachedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: attachedKey) }
    }

    /// Open a window for each session that had one when the app last quit, else the
    /// newest session, else a new one. False if there is no server to attach to.
    static func openSessions(_ ghostty: Ghostty.App) -> Bool {
        // Tests drive the client themselves.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let shared else { return false }
        guard let list: SessionList = shared.call("session.list") else { return false }
        let existing = list.sessions.map(\.id)
        var ids = attached.filter(existing.contains)
        if ids.isEmpty, let newest = existing.last { ids = [newest] }
        if ids.isEmpty {
            let created: Created? = shared.call("session.create", ["cwd": NSHomeDirectory()])
            if let created { ids = [created.session] }
        }
        for id in ids { shared.open(ghostty, session: id) }
        return !ids.isEmpty
    }

    /// Show a session in its window, opening one if needed.
    @discardableResult
    func open(_ ghostty: Ghostty.App, session: String) -> RaptorController {
        if let controller = controllers[session] {
            controller.showWindow(nil)
            return controller
        }
        let controller = RaptorController(ghostty, client: self, session: session)
        controllers[session] = controller
        if !Self.attached.contains(session) { Self.attached.append(session) }
        controller.showWindow(nil)
        return controller
    }

    /// The session's window closed: it is detached and won't reopen on launch.
    func closed(_ controller: RaptorController) {
        controllers[controller.session] = nil
        Self.attached.removeAll { $0 == controller.session }
    }
}
