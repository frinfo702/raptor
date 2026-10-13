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

    /// Requests and events.
    let client: rap_client_t

    /// The server's socket, nil for the default one.
    let socket: String?

    /// The open session windows. Several may show one session.
    private(set) var controllers: [RaptorController] = []

    /// Connections for the windows' panes, one per open window, reused as windows come
    /// and go. The server makes the client that last focused or typed into a block its
    /// size owner, so each window needs its own. Never freed: surfaces point into them.
    private var streams: [rap_client_t] = []

    /// Connect to the server on `socket`, else on the default socket, starting it if needed.
    init?(socket: String? = nil) {
        guard Self.startServer(socket: socket), let client = rap_client_connect(socket) else {
            Self.logger.warning("no rap server")
            return nil
        }
        self.client = client
        self.socket = socket
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
            controllers.forEach { $0.refresh() }
            return
        default:
            break
        }
        guard let id = event.session else { return }
        for controller in controllers where controller.session == id {
            switch event.event {
            case "session_destroyed":
                controller.sessionDestroyed()
            case "title_changed":
                if let block = event.block { controller.titleChanged(block: block, to: event.title ?? "") }
            case "pwd_changed":
                if let block = event.block { controller.pwdChanged(block: block, to: event.pwd ?? "") }
            case "process_changed":
                if let block = event.block { controller.processChanged(block: block, to: event.foreground?.name) }
            case "session_view_changed", "session_label_changed", "window_label_changed":
                controller.refresh()
            default:
                break
            }
        }
    }

    // MARK: Sessions

    struct SessionSummary: Decodable, Identifiable {
        let id: String
        let label: String
    }

    private struct SessionList: Decodable {
        let sessions: [SessionSummary]
    }

    /// The server's sessions, oldest first.
    func sessions() -> [SessionSummary] {
        let list: SessionList? = call("session.list")
        return list?.sessions ?? []
    }

    struct Created: Decodable {
        let session: String
    }

    /// Make a session, named `label` or by the server, in the home directory.
    func createSession(label: String? = nil) -> String? {
        var params: [String: Any] = ["cwd": NSHomeDirectory()]
        if let label { params["label"] = label }
        let created: Created? = call("session.create", params)
        return created?.session
    }

    private static let attachedKey = "RaptorAttachedSessions"

    /// The session of each window open when the app last quit, for reopening.
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
        if ids.isEmpty, let created = shared.createSession() { ids = [created] }
        attached = []
        for id in ids { shared.newWindow(ghostty, session: id) }
        return !ids.isEmpty
    }

    /// Show a session in a window, opening one if it has none.
    @discardableResult
    func open(_ ghostty: Ghostty.App, session: String) -> RaptorController {
        if let controller = controllers.first(where: { $0.session == session }) {
            controller.showWindow(nil)
            return controller
        }
        return newWindow(ghostty, session: session)
    }

    /// Open another window on a session.
    @discardableResult
    func newWindow(_ ghostty: Ghostty.App, session: String) -> RaptorController {
        let controller = RaptorController(ghostty, client: self, stream: stream(), session: session)
        controllers.append(controller)
        Self.attached.append(session)
        controller.showWindow(nil)
        return controller
    }

    /// A connection no open window uses.
    private func stream() -> rap_client_t {
        let used = controllers.map(\.stream)
        if let free = streams.first(where: { s in !used.contains(where: { $0 == s }) }) { return free }
        // ponytail: falls back to sharing the control connection, and so its size ownership.
        guard let s = rap_client_connect(socket) else { return client }
        streams.append(s)
        return s
    }

    /// A window moved from one session to another.
    func switched(_ controller: RaptorController, from old: String) {
        if let i = Self.attached.firstIndex(of: old) { Self.attached[i] = controller.session }
    }

    /// A window closed: it is detached and won't reopen on launch.
    func closed(_ controller: RaptorController) {
        controllers.removeAll { $0 === controller }
        if let i = Self.attached.firstIndex(of: controller.session) { Self.attached.remove(at: i) }
    }
}
