//! The C API of the rap client (include/raptor.h), part of libghostty.
const std = @import("std");
const c = std.c;
const global = @import("../global.zig");
const embedded = @import("../apprt/embedded.zig");
const External = @import("../termio/External.zig");
const Client = @import("Client.zig");
const Feed = @import("Feed.zig");
const Mirror = @import("Mirror.zig");
const protocol = @import("protocol.zig");
const tailscale = @import("tailscale.zig");

const log = std.log.scoped(.rap_capi);

/// The online macOS and Linux peers on the tailnet, which rap runs on, and
/// how a rap server on each answers.
export fn rap_tailnet_peers() ?[*:0]u8 {
    var arena: std.heap.ArenaAllocator = .init(global.alloc());
    defer arena.deinit();
    return tailnetPeers(arena.allocator()) catch null;
}

fn tailnetPeers(alloc: std.mem.Allocator) !?[*:0]u8 {
    const st = tailscale.status(alloc, global.io()) catch return null;
    var nodes: std.ArrayList(tailscale.Node) = .empty;
    for (st.peers) |p| if (p.online and (std.mem.eql(u8, p.os, "linux") or std.mem.eql(u8, p.os, "macOS")))
        try nodes.append(alloc, p);
    const Peer = struct { name: []const u8, dns: []const u8, rap: tailscale.Answer };
    const peers = try alloc.alloc(Peer, nodes.items.len);
    for (nodes.items, try tailscale.probe(alloc, nodes.items), peers) |n, a, *p|
        p.* = .{ .name = n.short(), .dns = n.name, .rap = a };
    return cString(try std.json.Stringify.valueAlloc(alloc, .{ .peers = peers }, .{}));
}

export fn rap_client_connect(socket_path: ?[*:0]const u8) ?*Client {
    return connect(socket_path) catch |err| {
        log.warn("connecting to the rap server failed err={t}", .{err});
        return null;
    };
}

fn connect(socket_path: ?[*:0]const u8) !*Client {
    const alloc = global.alloc();
    const io = global.io();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var env = try global.environMap();
    defer env.deinit();
    const flag = if (socket_path) |p| std.mem.span(p) else null;
    const path = try protocol.resolveServer(arena.allocator(), io, &env, flag);
    return Client.connect(alloc, io, path, null);
}

export fn rap_client_free(client: *Client) void {
    client.deinit();
}

export fn rap_client_set_event_callback(client: *Client, cb: ?Client.EventFn, userdata: ?*anyopaque) void {
    client.setEventCallback(cb, userdata);
}

export fn rap_client_request(client: *Client, json: [*:0]const u8) ?[*:0]u8 {
    const resp = client.request(std.mem.span(json)) catch |err| {
        log.warn("rap request failed err={t}", .{err});
        return null;
    };
    defer client.alloc.free(resp);
    return cString(resp);
}

/// `bytes` in memory from malloc, for the caller to free.
fn cString(bytes: []const u8) ?[*:0]u8 {
    const p: [*]u8 = @ptrCast(c.malloc(bytes.len + 1) orelse return null);
    @memcpy(p[0..bytes.len], bytes);
    p[bytes.len] = 0;
    return p[0..bytes.len :0];
}

export fn rap_client_surface_config(client: *Client, config: *embedded.Surface.Options) void {
    // ponytail: on failure the surface just stays unbindable.
    const b = client.newBinding() catch return;
    config.io_mode = .external;
    config.io_userdata = b;
    config.io_write_cb = Client.Binding.onWrite;
    config.io_resize_cb = Client.Binding.onResize;
    config.io_focus_cb = Client.Binding.onFocus;
}

/// The client's binding that a surface's I/O goes to.
fn surfaceBinding(client: *Client, surface: *embedded.Surface) ?*Client.Binding {
    const ext = surface.io_external orelse return null;
    const ud = ext.userdata orelse return null;
    client.lock.lockUncancelable(client.io);
    defer client.lock.unlock(client.io);
    for (client.bindings.items) |b| if (@as(*anyopaque, b) == ud) return b;
    return null;
}

export fn rap_client_bind(client: *Client, block: [*:0]const u8, surface: *embedded.Surface) bool {
    const b = surfaceBinding(client, surface) orelse {
        log.warn("surface was not configured by rap_client_surface_config", .{});
        return false;
    };
    client.bind(b, std.mem.span(block), External.sink(&surface.core_surface.io)) catch |err| {
        log.warn("binding block failed err={t}", .{err});
        return false;
    };
    // The surface told its size before it was bound.
    const size = surface.core_surface.size;
    const grid = size.grid();
    b.resize(grid.columns, grid.rows, size.screen.width, size.screen.height);
    return true;
}

export fn rap_client_unbind(client: *Client, surface: *embedded.Surface) void {
    if (surfaceBinding(client, surface)) |b| client.unbind(b);
}

/// Make the client the size owner of the surface's block, as focusing the
/// surface does, for a surface that kept its focus while another window had
/// the keyboard.
export fn rap_client_claim(client: *Client, surface: *embedded.Surface) void {
    if (surfaceBinding(client, surface)) |b| b.focus(true);
}

/// A headless surface: a mirror that is safe to read while the client's
/// reader thread feeds it.
const CMirror = struct {
    lock: std.Io.Mutex = .init,
    mirror: Mirror,
    binding: ?*Client.Binding = null,

    const vtable: Feed.Sink.VTable = .{
        .load = struct {
            fn f(ctx: *anyopaque, bytes: []const u8) anyerror!void {
                const self = from(ctx);
                self.lock.lockUncancelable(global.io());
                defer self.lock.unlock(global.io());
                return self.mirror.load(bytes);
            }
        }.f,
        .output = struct {
            fn f(ctx: *anyopaque, bytes: []const u8) void {
                const self = from(ctx);
                self.lock.lockUncancelable(global.io());
                defer self.lock.unlock(global.io());
                self.mirror.output(bytes);
            }
        }.f,
        .grid = struct {
            fn f(ctx: *anyopaque, cols: u16, rows: u16) anyerror!void {
                const self = from(ctx);
                self.lock.lockUncancelable(global.io());
                defer self.lock.unlock(global.io());
                return self.mirror.grid(cols, rows);
            }
        }.f,
        .exited = struct {
            fn f(_: *anyopaque, _: u32) void {}
        }.f,
    };

    fn from(ctx: *anyopaque) *CMirror {
        return @ptrCast(@alignCast(ctx));
    }
};

export fn rap_mirror_new() ?*CMirror {
    const m = global.alloc().create(CMirror) catch return null;
    m.* = .{ .mirror = .init(global.alloc(), global.io()) };
    return m;
}

export fn rap_mirror_free(m: *CMirror) void {
    m.mirror.deinit();
    global.alloc().destroy(m);
}

export fn rap_client_bind_mirror(client: *Client, block: [*:0]const u8, m: *CMirror) bool {
    if (m.binding) |old| if (old.client != client) {
        old.client.unbind(old);
        m.binding = null;
    };
    if (m.binding == null) m.binding = client.newBinding() catch return false;
    client.bind(m.binding.?, std.mem.span(block), .{ .ctx = m, .vtable = &CMirror.vtable }) catch |err| {
        log.warn("binding block failed err={t}", .{err});
        return false;
    };
    return true;
}

export fn rap_client_unbind_mirror(client: *Client, m: *CMirror) void {
    const b = m.binding orelse return;
    if (b.client == client) client.unbind(b);
}

export fn rap_mirror_text(m: *CMirror) ?[*:0]u8 {
    m.lock.lockUncancelable(global.io());
    defer m.lock.unlock(global.io());
    if (m.mirror.term == null) return null;
    const text = m.mirror.plainAll(global.alloc()) catch return null;
    defer global.alloc().free(text);
    return cString(text);
}
