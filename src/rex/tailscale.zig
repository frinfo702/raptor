//! What the local tailscaled knows about the tailnet, from its LocalAPI:
//! this node, its peers, and who is on the other end of a connection.
//!
//! A server started with `--tailnet` listens on its node's tailnet
//! address. WireGuard has already authenticated the node a connection
//! comes from, and WhoIs names that node and its user. Clients find
//! servers among the peers that `status` lists.
//!
//! Requests are HTTP/1.0 over tailscaled's Unix socket, or for the
//! standalone macOS app, over the loopback port and token it publishes in
//! /Library/Tailscale.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const Allocator = std.mem.Allocator;
const Ip4Address = std.Io.net.Ip4Address;
const protocol = @import("protocol.zig");

/// The port a server listens on unless told otherwise.
pub const default_port = 7277;

/// A node on the tailnet.
pub const Node = struct {
    /// The MagicDNS name, without the trailing dot.
    name: []const u8,
    /// The node's IPv4 tailnet address.
    ip: [4]u8,
    /// The owning user's id. Null for a tagged node, which no user owns.
    user: ?i64,
    /// The owning user's login name, such as "me@github".
    login: []const u8 = "",
    online: bool = true,
    /// The node's OS as Tailscale names it: "linux", "macOS", "iOS", ...
    os: []const u8 = "",

    /// The MagicDNS name's first label.
    pub fn short(n: Node) []const u8 {
        return n.name[0 .. std.mem.indexOfScalar(u8, n.name, '.') orelse n.name.len];
    }

    /// Whether `host` names this node: its MagicDNS name, the name's first
    /// label, or its address.
    pub fn named(n: Node, host: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(host, n.name) or std.ascii.eqlIgnoreCase(host, n.short())) return true;
        const ip = Ip4Address.parse(host, 0) catch return false;
        return std.mem.eql(u8, &ip.bytes, &n.ip);
    }
};

/// How the rap server on a node's default port answers a client.
pub const Answer = enum { none, running, refused };

/// How the rap server on each of `nodes` answers, asked of all at once.
/// Offline nodes are not asked.
// ponytail: a thread per online peer, fine for a personal tailnet; poll
// nonblocking sockets instead if tailnets get large.
pub fn probe(alloc: Allocator, nodes: []const Node) Allocator.Error![]Answer {
    const answers = try alloc.alloc(Answer, nodes.len);
    @memset(answers, .none);
    const threads = try alloc.alloc(?std.Thread, nodes.len);
    defer alloc.free(threads);
    for (nodes, threads, answers) |n, *t, *a|
        t.* = if (n.online) std.Thread.spawn(.{}, probeOne, .{ n.ip, a }) catch null else null;
    for (threads) |t| if (t) |th| th.join();
    return answers;
}

/// Whether a rap server at `ip` answers within a second, and lets us in.
fn probeOne(ip: [4]u8, answer: *Answer) void {
    const fd = protocol.dialTcp(.{ .bytes = ip, .port = default_port }, 1000) catch return;
    defer _ = c.close(fd);
    const timeout: c.timeval = .{ .sec = 1, .usec = 0 };
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, std.mem.asBytes(&timeout), @sizeOf(c.timeval));
    // A server that refuses us says so as we connect, so read even if this fails.
    protocol.writeFrame(fd, .json, "{\"id\":1,\"method\":\"server.version\",\"params\":{}}") catch {};
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const frame = protocol.readFrame(fba.allocator(), fd) catch return;
    if (frame.type != .json) return;
    if (std.mem.indexOf(u8, frame.payload, "\"result\"") != null) answer.* = .running;
    if (std.mem.indexOf(u8, frame.payload, "\"event\":\"refused\"") != null) answer.* = .refused;
}

pub const Status = struct {
    self: Node,
    peers: []const Node,
};

pub const Error = error{ Unavailable, BadResponse } || Allocator.Error;

/// This node and its peers. `Unavailable` unless Tailscale is running.
/// Allocates more than the result; use an arena.
pub fn status(alloc: Allocator, io: std.Io) Error!Status {
    return parseStatus(alloc, try get(alloc, io, "/localapi/v0/status"));
}

/// The node at `addr`, an `ip:port` on the tailnet. `BadResponse` if no
/// node has that address. Allocates more than the result; use an arena.
pub fn whois(alloc: Allocator, io: std.Io, addr: []const u8) Error!Node {
    const path = try std.fmt.allocPrint(alloc, "/localapi/v0/whois?addr={s}", .{addr});
    return parseWhois(alloc, try get(alloc, io, path));
}

/// The LocalAPI's sockets: tailscaled's on Linux, then on macOS.
const sockets = [_][]const u8{ "/var/run/tailscale/tailscaled.sock", "/var/run/tailscaled.socket" };

/// The body of a LocalAPI GET.
fn get(alloc: Allocator, io: std.Io, path: []const u8) Error![]const u8 {
    var token: ?[]const u8 = null;
    const fd = for (sockets) |s| {
        if (protocol.dialUnix(s)) |fd| break fd else |_| {}
    } else fd: {
        if (comptime !builtin.os.tag.isDarwin()) return error.Unavailable;
        // ponytail: the App Store app's token is only found through lsof, as
        // Tailscale's own CLI does; add that if its users need --tailnet.
        var buf: [16]u8 = undefined;
        const n = std.Io.Dir.readLinkAbsolute(io, "/Library/Tailscale/ipnport", &buf) catch return error.Unavailable;
        const port = std.fmt.parseInt(u16, buf[0..n], 10) catch return error.Unavailable;
        const proof = try std.fmt.allocPrint(alloc, "/Library/Tailscale/sameuserproof-{d}", .{port});
        const t = std.Io.Dir.cwd().readFileAlloc(io, proof, alloc, .limited(256)) catch return error.Unavailable;
        token = std.mem.trim(u8, t, " \r\n");
        break :fd protocol.dialTcp(.loopback(port), 2000) catch return error.Unavailable;
    };
    defer _ = c.close(fd);
    // A wedged tailscaled must not hang its caller, which may be the server.
    const timeout: c.timeval = .{ .sec = 2, .usec = 0 };
    for ([_]u32{ c.SO.RCVTIMEO, c.SO.SNDTIMEO }) |opt|
        _ = c.setsockopt(fd, c.SOL.SOCKET, opt, std.mem.asBytes(&timeout), @sizeOf(c.timeval));

    var req: std.ArrayList(u8) = .empty;
    try req.print(alloc, "GET {s} HTTP/1.0\r\nHost: local-tailscaled.sock\r\nSec-Tailscale: localapi\r\n", .{path});
    if (token) |t| {
        const cred = try std.fmt.allocPrint(alloc, ":{s}", .{t});
        const b64 = std.base64.standard.Encoder;
        const enc = try alloc.alloc(u8, b64.calcSize(cred.len));
        try req.print(alloc, "Authorization: Basic {s}\r\n", .{b64.encode(enc, cred)});
    }
    try req.appendSlice(alloc, "\r\n");
    protocol.writeAll(fd, req.items) catch return error.Unavailable;

    // HTTP/1.0: the body ends where the connection does.
    var resp: std.ArrayList(u8) = .empty;
    while (true) {
        try resp.ensureUnusedCapacity(alloc, 64 * 1024);
        const buf = resp.unusedCapacitySlice();
        const n = c.read(fd, buf.ptr, buf.len);
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            return error.Unavailable;
        }
        if (n == 0) break;
        resp.items.len += @intCast(n);
        if (resp.items.len > protocol.max_frame) return error.BadResponse;
    }
    return body(resp.items);
}

/// The body of a 200 response.
fn body(resp: []const u8) Error![]const u8 {
    const end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.BadResponse;
    var words = std.mem.tokenizeScalar(u8, resp[0..end], ' ');
    _ = words.next();
    const code = words.next() orelse return error.BadResponse;
    if (!std.mem.eql(u8, code, "200")) return error.BadResponse;
    return resp[end + 4 ..];
}

fn parseStatus(alloc: Allocator, json: []const u8) Error!Status {
    const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{}) catch return error.BadResponse;
    if (v != .object) return error.BadResponse;
    // Logged out or stopped, it is on no tailnet.
    if (!std.mem.eql(u8, str(v, "BackendState"), "Running")) return error.Unavailable;
    const users = v.object.get("User") orelse .null;
    const self = peerStatus(v.object.get("Self") orelse .null, users) orelse return error.BadResponse;
    var peers: std.ArrayList(Node) = .empty;
    if (v.object.get("Peer")) |p| if (p == .object) for (p.object.values()) |pv| {
        if (peerStatus(pv, users)) |n| try peers.append(alloc, n);
    };
    return .{ .self = self, .peers = peers.items };
}

/// A status's `Self` or `Peer` entry, with its user's login from `users`.
fn peerStatus(v: std.json.Value, users: std.json.Value) ?Node {
    if (v != .object) return null;
    const user = owner(v, "UserID");
    var id_buf: [24]u8 = undefined;
    const login = if (user) |u| login: {
        if (users != .object) break :login "";
        const p = users.object.get(std.fmt.bufPrint(&id_buf, "{d}", .{u}) catch unreachable) orelse break :login "";
        break :login str(p, "LoginName");
    } else "";
    return .{
        .name = name(v, "DNSName"),
        .ip = firstIp4(v.object.get("TailscaleIPs")) orelse return null,
        .user = user,
        .login = login,
        .online = if (v.object.get("Online")) |o| o == .bool and o.bool else false,
        .os = str(v, "OS"),
    };
}

fn parseWhois(alloc: Allocator, json: []const u8) Error!Node {
    const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{}) catch return error.BadResponse;
    if (v != .object) return error.BadResponse;
    const n = v.object.get("Node") orelse return error.BadResponse;
    if (n != .object) return error.BadResponse;
    const user = owner(n, "User");
    return .{
        .name = name(n, "Name"),
        .ip = firstIp4(n.object.get("Addresses")) orelse return error.BadResponse,
        .user = user,
        .login = if (user != null) str(v.object.get("UserProfile") orelse .null, "LoginName") else "",
    };
}

/// The node's user id, unless it is tagged: tags replace its user.
fn owner(node: std.json.Value, key: []const u8) ?i64 {
    if (node.object.get("Tags")) |t| if (t == .array and t.array.items.len > 0) return null;
    const u = node.object.get(key) orelse return null;
    return if (u == .integer) u.integer else null;
}

fn name(node: std.json.Value, key: []const u8) []const u8 {
    return std.mem.trimEnd(u8, str(node, key), ".");
}

/// The first IPv4 address of a list such as ["100.1.2.3", "fd7a::1"] or
/// ["100.1.2.3/32"].
fn firstIp4(list: ?std.json.Value) ?[4]u8 {
    const l = list orelse return null;
    if (l != .array) return null;
    for (l.array.items) |a| if (a == .string) {
        const text = a.string[0 .. std.mem.indexOfScalar(u8, a.string, '/') orelse a.string.len];
        if (Ip4Address.parse(text, 0)) |ip| return ip.bytes else |_| {}
    };
    return null;
}

fn str(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const f = v.object.get(key) orelse return "";
    return if (f == .string) f.string else "";
}

test "tailscale: status" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const s = try parseStatus(arena.allocator(),
        \\{"BackendState":"Running",
        \\ "Self":{"DNSName":"mac.tail1.ts.net.","UserID":7,"TailscaleIPs":["100.67.1.2","fd7a:115c:a1e0::1"],"Online":true},
        \\ "Peer":{
        \\  "nodekey:a":{"DNSName":"box.tail1.ts.net.","UserID":7,"TailscaleIPs":["fd7a:115c:a1e0::2","100.96.1.3"],"Online":true,"OS":"linux"},
        \\  "nodekey:b":{"DNSName":"ci.tail1.ts.net.","UserID":9,"Tags":["tag:ci"],"TailscaleIPs":["100.96.1.4"],"Online":false},
        \\  "nodekey:c":{"DNSName":"v6only.tail1.ts.net.","UserID":7,"TailscaleIPs":["fd7a:115c:a1e0::5"]}},
        \\ "User":{"7":{"ID":7,"LoginName":"me@github"}}}
    );
    try std.testing.expectEqualStrings("mac.tail1.ts.net", s.self.name);
    try std.testing.expectEqual(7, s.self.user.?);
    try std.testing.expectEqualStrings("me@github", s.self.login);
    try std.testing.expectEqual(2, s.peers.len);
    const box = s.peers[0];
    try std.testing.expectEqualSlices(u8, &.{ 100, 96, 1, 3 }, &box.ip);
    try std.testing.expect(box.online);
    try std.testing.expectEqualStrings("linux", box.os);
    try std.testing.expectEqualStrings("box", box.short());
    try std.testing.expect(box.named("box") and box.named("BOX.tail1.ts.net") and box.named("100.96.1.3"));
    try std.testing.expect(!box.named("bo") and !box.named("100.96.1.4") and !box.named("tail1"));
    // A tagged node has no user, whatever UserID says.
    try std.testing.expectEqual(null, s.peers[1].user);
    try std.testing.expect(!s.peers[1].online);

    try std.testing.expectError(error.Unavailable, parseStatus(arena.allocator(), "{\"BackendState\":\"Stopped\"}"));
}

test "tailscale: whois" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const n = try parseWhois(arena.allocator(),
        \\{"Node":{"Name":"box.tail1.ts.net.","User":7,"Addresses":["100.96.1.3/32","fd7a:115c:a1e0::2/128"]},
        \\ "UserProfile":{"ID":7,"LoginName":"me@github"}}
    );
    try std.testing.expectEqualStrings("box.tail1.ts.net", n.name);
    try std.testing.expectEqual(7, n.user.?);
    try std.testing.expectEqualStrings("me@github", n.login);
    const tagged = try parseWhois(arena.allocator(),
        \\{"Node":{"Name":"ci.","User":9,"Tags":["tag:ci"],"Addresses":["100.96.1.4/32"]},
        \\ "UserProfile":{"ID":9,"LoginName":"tagged-devices"}}
    );
    try std.testing.expectEqual(null, tagged.user);
    try std.testing.expectEqualStrings("", tagged.login);
}

test "tailscale: response body" {
    try std.testing.expectEqualStrings("{}", try body("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n{}"));
    try std.testing.expectError(error.BadResponse, body("HTTP/1.0 404 Not Found\r\n\r\nno such peer"));
    try std.testing.expectError(error.BadResponse, body("HTTP/1.0 200 OK\r\n"));
}
