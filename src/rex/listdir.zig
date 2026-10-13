//! The `list_dir` block method: the entries under a directory, breadth
//! first and sorted by name within each directory, for the path picker.
//!
//! A listing is bounded: it returns at most `limit` entries and reads at
//! most `max_scanned`, and it doesn't descend into `.git` or
//! `node_modules` unless the query names them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Kind = std.Io.File.Kind;

pub const default_limit = 5000;

/// The most entries one listing reads, matched or not.
// ponytail: the walk runs on the server's loop thread, so a slow disk
// stalls every block for up to this many reads; move it to a thread if
// that shows.
pub const max_scanned = 100_000;

/// Directories listed but not descended into unless the query names them.
const skipped = [_][]const u8{ ".git", "node_modules" };

pub const Options = struct {
    /// 1 lists only the directory's own entries.
    depth: u16 = 1,
    /// Keep only paths containing these characters in order, ignoring
    /// ASCII case.
    query: ?[]const u8 = null,
    limit: usize = default_limit,
};

pub const Entry = struct {
    /// Relative to the listed directory.
    name: []const u8,
    kind: Kind,
};

pub const Result = struct {
    entries: []Entry,
    /// A bound cut the listing short.
    truncated: bool,
};

/// List `root`, an absolute path. Everything is allocated in `arena`.
pub fn list(arena: Allocator, io: std.Io, root: []const u8, opts: Options) !Result {
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer root_dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    var queue: std.ArrayList(struct { rel: []const u8, depth: u16 }) = .empty;
    try queue.append(arena, .{ .rel = "", .depth = 1 });
    var scanned: usize = 0;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const d = queue.items[head];
        var dir = if (d.rel.len == 0)
            root_dir
        else
            root_dir.openDir(io, d.rel, .{ .iterate = true, .follow_symlinks = false }) catch continue;
        defer if (d.rel.len > 0) dir.close(io);

        var children: std.ArrayList(Entry) = .empty;
        var truncated = false;
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (scanned == max_scanned) {
                truncated = true;
                break;
            }
            scanned += 1;
            const name = if (d.rel.len == 0)
                try arena.dupe(u8, e.name)
            else
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ d.rel, e.name });
            try children.append(arena, .{ .name = name, .kind = e.kind });
        }
        std.mem.sort(Entry, children.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        for (children.items) |e| {
            if (e.kind == .directory and d.depth < opts.depth and descend(std.fs.path.basename(e.name), opts.query))
                try queue.append(arena, .{ .rel = e.name, .depth = d.depth + 1 });
            if (opts.query) |q| if (!matches(q, e.name)) continue;
            if (entries.items.len == opts.limit) return .{ .entries = entries.items, .truncated = true };
            try entries.append(arena, e);
        }
        if (truncated) return .{ .entries = entries.items, .truncated = true };
    }
    return .{ .entries = entries.items, .truncated = false };
}

fn descend(name: []const u8, query: ?[]const u8) bool {
    for (skipped) |s| if (std.mem.eql(u8, name, s))
        return if (query) |q| std.ascii.findIgnoreCase(q, s) != null else false;
    return true;
}

/// `query`'s characters appear in `text` in order, ignoring ASCII case.
pub fn matches(query: []const u8, text: []const u8) bool {
    var i: usize = 0;
    for (text) |ch| {
        if (i == query.len) break;
        if (std.ascii.toLower(ch) == std.ascii.toLower(query[i])) i += 1;
    }
    return i == query.len;
}

test "rex listdir: depth, skipped directories, query, and limit" {
    const testing = std.testing;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a/b", ".git", "node_modules/x", "src" }) |p| try tmp.dir.createDirPath(io, p);
    for ([_][]const u8{ "a/b/c.txt", ".git/HEAD", "node_modules/x/y.js", "README.md", "src/main.zig" }) |p|
        try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    const T = struct {
        fn names(a: Allocator, r: Result) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (r.entries) |e| {
                try out.appendSlice(a, e.name);
                if (e.kind == .directory) try out.append(a, '/');
                try out.append(a, ' ');
            }
            return out.items;
        }
    };

    const top = try list(arena, io, root, .{});
    try testing.expectEqualStrings(".git/ README.md a/ node_modules/ src/ ", try T.names(arena, top));
    try testing.expect(!top.truncated);

    const deep = try list(arena, io, root, .{ .depth = 3 });
    try testing.expectEqualStrings(
        ".git/ README.md a/ node_modules/ src/ a/b/ src/main.zig a/b/c.txt ",
        try T.names(arena, deep),
    );

    const found = try list(arena, io, root, .{ .depth = 8, .query = "C.TXT" });
    try testing.expectEqualStrings("a/b/c.txt ", try T.names(arena, found));
    const named = try list(arena, io, root, .{ .depth = 8, .query = "node_modules/y" });
    try testing.expectEqualStrings("node_modules/x/y.js ", try T.names(arena, named));

    const cut = try list(arena, io, root, .{ .limit = 2 });
    try testing.expectEqualStrings(".git/ README.md ", try T.names(arena, cut));
    try testing.expect(cut.truncated);

    try testing.expectError(error.FileNotFound, list(arena, io, "/nonexistent-rex-dir", .{}));
}
