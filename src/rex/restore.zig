//! Restoring a block's terminal from its snapshot, the same way in every
//! client: the app's surfaces and the headless Mirror.
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const Block = @import("Block.zig");

/// Decode one snapshot like `terminal.snapshot.decode`.
///
/// A snapshot page carries only the rows it holds, so the newest page of
/// each screen comes back full: the next line of output would start a new
/// page where the server's terminal still had room. Scrollback pruning
/// drops whole pages, so from then on the restored terminal would keep
/// up to a page fewer of the oldest lines than the server. Giving that
/// page the capacity a live terminal gives its pages keeps both terminals'
/// pages, and so their pruning, in step.
pub fn decode(
    alloc: Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
) (terminal.snapshot.DecodeError || Allocator.Error)!terminal.snapshot.Decoded {
    var decoded = try terminal.snapshot.decode(alloc, io, reader, .{
        .max_continuation_bytes = Block.max_continuation_bytes,
    });
    errdefer decoded.deinit(alloc);
    const t = &decoded.terminal.?;
    for ([_]terminal.ScreenSet.Key{ .primary, .alternate }) |key| {
        const screen = t.screens.get(key) orelse continue;
        if (try growLastPage(&screen.pages)) screen.cursorReload();
    }
    return decoded;
}

/// Replace the last page with one of standard capacity, as
/// `PageList.increaseCapacity` replaces a page. Returns whether it did.
// ponytail: only pool-sized pages, so the PageList's byte count is
// unchanged; wider or style-heavy pages stay as decoded, a page short.
fn growLastPage(pages: *terminal.PageList) Allocator.Error!bool {
    const node = pages.pages.last.?;
    const page = node.page();
    const want = terminal.page.std_capacity.adjust(.{ .cols = pages.cols }) catch return false;
    if (page.size.cols != pages.cols or page.capacity.rows >= want.rows) return false;

    var cap = page.capacity;
    cap.cols = want.cols;
    cap.rows = want.rows;
    var replacement = try pages.allocatePage(cap);
    // Frees the new page if it isn't used, and the old one if it is.
    defer replacement.deinit();
    const new_node = replacement.node.?;
    if (node.owned != .pool or new_node.owned != .pool) return false;
    const new_page = replacement.page();
    new_page.size = page.size;
    new_page.cloneFrom(page, 0, page.size.rows) catch return false;
    new_page.dirty = page.dirty;

    for (pages.tracked_pins.keys()) |p| {
        if (p.node == node) p.node = new_node;
    }
    pages.pages.insertBefore(node, new_node);
    pages.pages.remove(node);
    replacement.node = node;
    return true;
}

test "rex restore: a pruned snapshot keeps pruning like its source" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A limit of a few pages, so that the output below prunes some both
    // before the snapshot and after it.
    var src: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 1000 * 1000,
    });
    defer src.deinit(alloc);
    var src_vt = src.vtStream();
    defer src_vt.deinit();

    var buf: [32]u8 = undefined;
    for (0..20_000) |i| src_vt.nextSlice(try std.fmt.bufPrint(&buf, "line {d}\r\n", .{i}));

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try terminal.snapshot.encode(alloc, &encoded.writer, &src, .{ .continuation = .ground });
    var reader: std.Io.Reader = .fixed(encoded.written());
    var decoded = try decode(alloc, testing.io, &reader);
    defer decoded.deinit(alloc);
    var dst = decoded.toOwned();
    defer dst.deinit(alloc);
    var dst_vt = dst.vtStream();
    defer dst_vt.deinit();

    for (20_000..26_000) |i| {
        const line = try std.fmt.bufPrint(&buf, "line {d}\r\n", .{i});
        src_vt.nextSlice(line);
        dst_vt.nextSlice(line);
    }

    const want = try src.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(want);
    const got = try dst.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(got);
    try testing.expect(!std.mem.startsWith(u8, want, "line 0\n"));
    try testing.expectEqualStrings(want, got);
}
