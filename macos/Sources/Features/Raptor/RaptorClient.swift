import AppKit
import CryptoKit
import GhosttyKit
import os

/// The app's connection to a rap server: this Mac's, or one on a tailnet machine. It
/// lives as long as the app: surfaces configured by a client point into it, so it is
/// never freed.
final class RaptorClient: Identifiable {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "raptor"
    )

    /// This Mac's server. Nil if no server could be reached or started.
    static let shared: RaptorClient? = RaptorClient()

    /// Requests and events.
    let client: rap_client_t

    /// The server's socket, nil for the default one.
    let socket: String?

    /// The tailnet machine the server runs on, by MagicDNS name; nil for this Mac.
    let host: String?

    /// The machine, as the sidebar names it.
    let name: String

    /// The open session windows. Several may show one session.
    private(set) var controllers: [RaptorController] = []

    /// Connections for the windows' panes, one per open window, reused as windows come
    /// and go. The server makes the client that last focused or typed into a block its
    /// size owner, so each window needs its own. Never freed: surfaces point into them.
    private var streams: [rap_client_t] = []

    /// Requests run here one at a time, in the order they are made, so the main thread
    /// never waits on the server.
    private let requests = DispatchQueue(label: "raptor.requests")

    /// Set while `openSessions` waits for the server, so it opens the windows once.
    private var opening = false

    /// Every session's tabs, for the windows' sidebars.
    private(set) lazy var sidebar = RaptorSidebarModel(client: self)

    /// Connect to the server on `socket`, else on the default socket, starting it if needed.
    convenience init?(socket: String? = nil) {
        guard Self.startServer(socket: socket), let client = rap_client_connect(socket) else {
            Self.logger.warning("no rap server")
            return nil
        }
        self.init(client, socket: socket, host: nil, name: "This Mac")
    }

    /// The server on a tailnet machine, `host` its MagicDNS name and `name` the short one.
    convenience init(_ client: rap_client_t, host: String, name: String) {
        self.init(client, socket: nil, host: host, name: name)
    }

    private init(_ client: rap_client_t, socket: String?, host: String?, name: String) {
        self.client = client
        self.socket = socket
        self.host = host
        self.name = name
        rap_client_set_event_callback(client, { userdata, json in
            guard let userdata, let json else { return }
            let me = Unmanaged<RaptorClient>.fromOpaque(userdata).takeUnretainedValue()
            let data = Data(bytes: json, count: strlen(json))
            DispatchQueue.main.async { me.handle(data) }
        }, Unmanaged.passRetained(self).toOpaque())
        send("session.subscribe")
        sidebar.setNeedsReload()
        // Clients are made on the main thread, which the sidebar reads this on.
        Servers.shared.clients.append(self)
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

    // MARK: Tailnet

    /// Every server the app has connected to, in the order it did: this Mac's, then
    /// tailnet machines'. The sidebar lists their sessions in that order.
    final class Servers: ObservableObject {
        static let shared = Servers()
        @Published fileprivate(set) var clients: [RaptorClient] = []

        func client(host: String) -> RaptorClient? { clients.first { $0.host == host } }

        /// The client for `host` made from `connection`, or the one made already, in which
        /// case `connection` is closed.
        func add(_ connection: rap_client_t, host: String, name: String) -> RaptorClient {
            if let known = client(host: host) {
                DispatchQueue.global().async { rap_client_free(connection) }
                return known
            }
            return RaptorClient(connection, host: host, name: name)
        }
    }

    /// A macOS or Linux machine on the tailnet, as `rap_tailnet_peers` reports it.
    struct Peer: Decodable, Identifiable, Equatable {
        enum Rap: String, Decodable { case running, refused, none }
        /// The MagicDNS name's first label.
        let name: String
        /// The MagicDNS name.
        let dns: String
        /// How a rap server there answers.
        let rap: Rap

        var id: String { dns }
    }

    private struct Peers: Decodable {
        let peers: [Peer]
    }

    /// The online macOS and Linux machines on the tailnet, those running rap first; nil
    /// if Tailscale isn't running. Asks every machine, so never on the main thread.
    static func tailnetPeers() -> [Peer]? {
        guard let json = rap_tailnet_peers() else { return nil }
        defer { free(json) }
        let peers = (try? JSONDecoder().decode(Peers.self, from: Data(bytes: json, count: strlen(json))))?.peers ?? []
        return peers.sorted { ($0.rap == .running ? 0 : 1, $0.name) < ($1.rap == .running ? 0 : 1, $1.name) }
    }

    /// A connection to the rap server on the tailnet machine `host` that lets us in, nil
    /// if none answers there. Waits on the network, so never on the main thread.
    static func dial(host: String) -> rap_client_t? {
        guard let c = rap_client_connect(host) else { return nil }
        // A server that won't let us in hangs up on every request.
        if let resp = rap_client_request(c, #"{"method":"session.list","params":{}}"#) {
            defer { free(resp) }
            if strstr(resp, #""result""#) != nil { return c }
        }
        rap_client_free(c)
        return nil
    }

    /// What to run on a machine to install rap and start its server on the tailnet, as
    /// the README gives it.
    static let installCommands = """
        curl -fsSL https://github.com/frinfo702/raptor/releases/latest/download/install-rap.sh | sh
        ~/.local/bin/rap server start --tailnet
        """

    // MARK: Requests

    private struct Response<T: Decodable>: Decodable {
        let result: T?
    }

    private struct Ignored: Decodable {}

    /// Run `work`, which makes requests, off the main thread, then hand its result to
    /// `done` on the main thread. Work runs, and results arrive, in the order asked.
    func request<T>(_ work: @escaping (RaptorClient) -> T, done: @escaping (T) -> Void) {
        requests.async {
            let result = work(self)
            DispatchQueue.main.async { done(result) }
        }
    }

    /// Make a request off the main thread, then tell `done`, on the main thread, whether
    /// it worked.
    func send(_ method: String, _ params: [String: Any] = [:], done: @escaping (Bool) -> Void = { _ in }) {
        request({ $0.call(method, params) }, done: done)
    }

    /// Make a request and wait for its result, nil if it failed. Only `request`'s work
    /// and tests may wait, never the main thread.
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

    struct BlockProcess: Decodable {
        struct Foreground: Decodable {
            let pid: Int
            let name: String?
            let argv0: String?
        }
        let pid: Int
        let foreground: Foreground?
    }

    /// The name of the block's foreground program, asked of the server.
    func foregroundName(_ block: String) -> String? {
        let p: BlockProcess? = call("block.method", ["block": block, "method": "process"])
        return RaptorProgram.processName(p?.foreground?.name, argv0: p?.foreground?.argv0)
    }

    /// The session's view, with the foreground program of each of its blocks that isn't
    /// in `known`, asked of the server.
    func view(_ session: String, known: Set<String>) -> (view: RaptorController.SessionView, processes: [String: String])? {
        guard let view: RaptorController.SessionView = call("session.view", ["session": session]) else { return nil }
        var processes: [String: String] = [:]
        for w in view.windows {
            for b in w.blocks where !known.contains(b.id) { processes[b.id] = foregroundName(b.id) }
        }
        return (view, processes)
    }

    // MARK: Events

    private struct Event: Decodable {
        let event: String
        let session: String?
        let block: String?
        let title: String?
        let pwd: String?
        let foreground: Foreground?
        /// A program status record's id, nil for the block's root record.
        let id: String?
        let record: RaptorController.SessionView.Status?
        /// The ids of removed records, null for the root one.
        let ids: [String?]?

        struct Foreground: Decodable {
            let name: String?
            let argv0: String?
        }
    }

    private func handle(_ data: Data) {
        guard let event = try? JSONDecoder().decode(Event.self, from: data) else { return }
        updateSidebar(event)
        switch event.event {
        case "server_reconnected":
            controllers.forEach { $0.refresh() }
            return
        default:
            break
        }
        guard let id = event.session else { return }
        if event.event == "session_destroyed" {
            for controller in controllers where controller.switching == id { controller.cancelSwitch() }
        }
        for controller in controllers where controller.session == id {
            switch event.event {
            case "session_destroyed":
                controller.sessionDestroyed()
            case "title_changed":
                if let block = event.block { controller.titleChanged(block: block, to: event.title ?? "") }
            case "pwd_changed":
                if let block = event.block { controller.pwdChanged(block: block, to: event.pwd ?? "") }
            case "process_changed":
                if let block = event.block { controller.processChanged(
                    block: block, to: RaptorProgram.processName(event.foreground?.name, argv0: event.foreground?.argv0)) }
            case "session_view_changed", "session_label_changed", "window_label_changed":
                controller.refresh()
            default:
                break
            }
        }
    }

    private func updateSidebar(_ event: Event) {
        switch (event.event, event.block) {
        case ("title_changed", let block?):
            sidebar.titleChanged(block: block, to: event.title ?? "")
        case ("pwd_changed", let block?):
            sidebar.pwdChanged(block: block, to: event.pwd ?? "")
        case ("process_changed", let block?):
            sidebar.processChanged(
                block: block, to: RaptorProgram.processName(event.foreground?.name, argv0: event.foreground?.argv0))
        case ("program_status_changed", let block?) where event.id == nil:
            sidebar.statusChanged(block: block, to: event.record)
        case ("program_status_removed", let block?) where event.ids?.contains(where: { $0 == nil }) == true:
            sidebar.statusChanged(block: block, to: nil)
        case ("session_view_changed", _), ("session_label_changed", _), ("window_label_changed", _),
             ("session_created", _), ("session_destroyed", _), ("server_reconnected", _):
            sidebar.setNeedsReload()
        default:
            break
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
        var params: [String: Any] = [:]
        // A tailnet machine's server starts in its own home.
        if host == nil { params["cwd"] = NSHomeDirectory() }
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
    /// newest session, else a new one. `fallback` runs instead if there is no server to
    /// attach to.
    static func openSessions(_ ghostty: Ghostty.App, fallback: @escaping () -> Void) {
        // Tests drive the client themselves.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let shared else { return fallback() }
        if !shared.controllers.isEmpty {
            shared.controllers.forEach { $0.showWindow(nil) }
            return
        }
        guard !shared.opening else { return }
        shared.opening = true
        let attached = attached
        shared.request({ c -> [String]? in
            guard let list: SessionList = c.call("session.list") else { return nil }
            let existing = list.sessions.map(\.id)
            var ids = attached.filter(existing.contains)
            if ids.isEmpty, let newest = existing.last { ids = [newest] }
            if ids.isEmpty, let created = c.createSession() { ids = [created] }
            return ids
        }, done: { ids in
            shared.opening = false
            guard let ids else { return fallback() }
            Self.attached = []
            for id in ids { shared.newWindow(ghostty, session: id) }
            if ids.isEmpty { fallback() }
        })
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
        if let free = freeStream { return free }
        // ponytail: falls back to sharing the control connection, and so its size ownership.
        // A tailnet machine's connections are made by `prepareStream`, off the main thread.
        guard host == nil, let s = rap_client_connect(socket) else { return client }
        streams.append(s)
        return s
    }

    private var freeStream: rap_client_t? {
        let used = controllers.map(\.stream)
        return streams.first { s in !used.contains { $0 == s } }
    }

    /// Have a connection no open window uses ready, making one off the main thread if
    /// there is none, then call `done`.
    func prepareStream(_ done: @escaping () -> Void) {
        guard freeStream == nil else { return done() }
        request({ c in rap_client_connect(c.host ?? c.socket) }, done: { [self] s in
            if let s { streams.append(s) }
            done()
        })
    }

    /// A window moved here from a session of `old`'s: its panes take one of this
    /// server's connections, which this returns.
    func adopt(_ controller: RaptorController, from old: RaptorClient) -> rap_client_t {
        old.controllers.removeAll { $0 === controller }
        let s = stream()
        controllers.append(controller)
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
