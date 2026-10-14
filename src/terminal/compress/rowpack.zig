//! Row packing: an exact, compact re-encoding of terminal page memory that
//! runs before LZ4.
//!
//! Page memory is laid out as `[rows][cells][metadata]` and the cell array
//! dominates it. Raw LZ4 does poorly there: an ASCII cell carries about one
//! byte of information in an eight byte word, so matches are short and
//! literals are mostly zero padding. Packing stores each cell row the way a
//! snapshot grid row does (`snapshot/grid.zig`): trailing zero cells are
//! elided and the rest are transported at the narrowest
//! `grid.Cell.EncodedWidth` (1, 2, 4, or 8 bytes) that admits every one of
//! them. LZ4 then sees text-like bytes.
//!
//! Unlike a snapshot, packing is a pure byte transform, not a semantic
//! re-encoding. Every step is a bijection on the raw bytes, so unpacking
//! reproduces the page memory byte for byte, including styles, graphemes,
//! hyperlinks, strings, allocator state, and padding. Nothing is normalized
//! and no IDs are remapped.
//!
//! ## Format
//!
//! All integers are little-endian.
//!
//! 1. Prefix, `cells_start` bytes: each row word minus (wrapping) the word an
//!    unrotated row `y` would hold, which points at cell row `y`. The bytes
//!    between the last row and the cell array follow verbatim. An unrotated
//!    page's prefix is therefore only its row flags, almost all zero.
//! 2. One record per cell row, in memory order, `capacity.rows` records of
//!    `capacity.cols` cells each: a width byte (`EncodedWidth`), a `u16`
//!    count of cells through the row's last nonzero cell, then that many
//!    values at the width. Cells past the count are zero.
//! 3. Metadata: the bytes from the end of the cell array through the last
//!    nonzero byte of the page memory. The remaining tail is zero.
//!
//! ## In-place unpacking
//!
//! Restoring a compressed page must not allocate, so `unpack` decodes inside
//! the destination memory. The caller places the packed image at the end of
//! the memory. Unpacking moves the prefix to the front, then expands cell
//! records forward, then moves the metadata down to its place and zeroes the
//! tail. Each expansion writes behind the read cursor as long as the packed
//! bytes still to be read never outnumber the raw bytes still to be written
//! plus the zero tail. `packedLen` checks that bound at every record and
//! declines pages which break it, which only happens when cell rows near the
//! end of the page are nearly incompressible and the zero tail is short.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const pagepkg = @import("../page.zig");
const grid = @import("../snapshot/grid.zig");

const TerminalPage = pagepkg.Page;
const Width = grid.Cell.EncodedWidth;

/// Width byte plus the `u16` cell count.
const record_header_len = 3;

/// Cell and row words are read and written in the host's byte order. Only
/// the packed form is little-endian.
const native = builtin.cpu.arch.endian();

pub const UnpackError = error{
    /// The packed image does not describe a page with this geometry. Packed
    /// images are produced internally, so this indicates memory corruption
    /// or a codec bug.
    InvalidPacking,
};

/// Return the packed size of `page.memory`, or null when packing is not
/// worthwhile or the result could not be unpacked in place.
pub fn packedLen(page: *const TerminalPage) ?usize {
    const geo = Geometry.init(page.capacity, page.memory.len) orelse
        return null;

    // These are the offsets the layout promises. Refuse anything else rather
    // than guess at a page we don't understand.
    if (page.rows.offset != 0 or page.cells.offset != geo.cells_start)
        return null;

    // Sum the records and remember how far the raw cells of any prefix of
    // them run ahead of its packed bytes. Expanding that prefix moves the
    // write cursor that much closer to the read cursor; see the in-place
    // notes above.
    const memory = page.memory;
    var cells_len: usize = 0;
    var raw_len: usize = 0;
    var lead: usize = 0;
    for (0..geo.rows) |y| {
        const count, const width = scan(memory, geo.cellRow(y), geo.cols);
        cells_len += record_header_len + count * width.size();
        raw_len += geo.cols * @sizeOf(u64);
        lead = @max(lead, raw_len -| cells_len);
    }

    const meta_len = geo.metaLen(memory);
    const zeros = memory.len - geo.cells_end - meta_len;

    // Before the first record the read cursor is `slack` bytes ahead of the
    // write cursor, which is `slack - cells_len` with the image at the end
    // of the memory. Each record changes that gap by its packed length minus
    // its raw length, so the gap is narrowest, by `lead` bytes, after the
    // prefix that expands the most.
    const slack = (geo.cells_end - geo.cells_start) + zeros;
    if (slack < cells_len + lead) return null;

    const total = geo.cells_start + cells_len + meta_len;
    if (total >= memory.len) return null;
    return total;
}

/// Write the packed image of `page.memory` into `out`, which must be exactly
/// `packedLen(page)` bytes.
pub fn pack(page: *const TerminalPage, out: []u8) void {
    const geo = Geometry.init(page.capacity, page.memory.len).?;
    const memory = page.memory;

    for (0..geo.rows) |y| {
        const word = std.mem.readInt(u64, memory[y * 8 ..][0..8], native);
        std.mem.writeInt(u64, out[y * 8 ..][0..8], word -% geo.identity(y), .little);
    }
    const rows_end = geo.rows * 8;
    @memcpy(out[rows_end..geo.cells_start], memory[rows_end..geo.cells_start]);

    var o = geo.cells_start;
    for (0..geo.rows) |y| {
        const start = geo.cellRow(y);
        const count, const width = scan(memory, start, geo.cols);
        out[o] = @backingInt(width);
        std.mem.writeInt(u16, out[o + 1 ..][0..2], @intCast(count), .little);
        o += record_header_len;

        switch (width) {
            inline else => |w| for (0..count) |x| {
                const size = comptime w.size();
                const word = std.mem.readInt(u64, memory[start + x * 8 ..][0..8], native);
                std.mem.writeInt(w.Int(), out[o..][0..size], w.truncate(word), .little);
                o += size;
            },
        }
    }

    const meta_len = geo.metaLen(memory);
    @memcpy(out[o..][0..meta_len], memory[geo.cells_end..][0..meta_len]);
    assert(o + meta_len == out.len);
}

/// Unpack a page image in place. `memory` is the destination page memory for
/// a page with `capacity`, and its last `packed_len` bytes hold the packed
/// image. Every byte of `memory` is overwritten.
///
/// Arbitrary input never reads or writes outside `memory`, but it can leave
/// garbage behind, which an error reports when detected.
pub fn unpack(
    capacity: pagepkg.Capacity,
    memory: []u8,
    packed_len: usize,
) UnpackError!void {
    const geo = Geometry.init(capacity, memory.len) orelse
        return error.InvalidPacking;
    if (packed_len > memory.len or packed_len < geo.cells_start)
        return error.InvalidPacking;

    // The prefix moves toward the front, so a forward copy is safe even when
    // the two ranges overlap. It ends before the first record begins.
    var r = memory.len - packed_len;
    @memmove(memory[0..geo.cells_start], memory[r..][0..geo.cells_start]);
    r += geo.cells_start;
    for (0..geo.rows) |y| {
        const word = std.mem.readInt(u64, memory[y * 8 ..][0..8], .little);
        std.mem.writeInt(u64, memory[y * 8 ..][0..8], word +% geo.identity(y), native);
    }

    // Each value is read before its expanded word is written. `packedLen`
    // proved the packed bytes left to read never outnumber the raw bytes
    // left to write plus the zero tail, so for images it accepts the write
    // cursor never passes the read cursor. Corrupt images may overwrite unread bytes but never escape
    // `memory`: reads are checked against its end below, and each record
    // writes exactly `cols` words, so `w` ends at `cells_end`.
    var w = geo.cells_start;
    for (0..geo.rows) |_| {
        if (memory.len - r < record_header_len) return error.InvalidPacking;
        const width_byte = memory[r];
        const count = std.mem.readInt(u16, memory[r + 1 ..][0..2], .little);
        r += record_header_len;
        if (width_byte > @backingInt(Width.eight) or count > geo.cols)
            return error.InvalidPacking;

        switch (@as(Width, @fromBackingInt(@intCast(width_byte)))) {
            inline else => |width| {
                const size = comptime width.size();
                if ((memory.len - r) / size < count) return error.InvalidPacking;
                for (0..count) |_| {
                    const value = std.mem.readInt(width.Int(), memory[r..][0..size], .little);
                    r += size;
                    std.mem.writeInt(u64, memory[w..][0..8], width.extend(value), native);
                    w += 8;
                }
            },
        }

        const zero_len = (geo.cols - count) * 8;
        @memset(memory[w..][0..zero_len], 0);
        w += zero_len;
    }
    assert(w == geo.cells_end);

    // The metadata is the rest of the image. It moves down onto its place
    // after the cells, which the bound above guarantees is not behind it.
    if (r < geo.cells_end) return error.InvalidPacking;
    const meta_len = memory.len - r;
    @memmove(memory[geo.cells_end..][0..meta_len], memory[r..]);
    @memset(memory[geo.cells_end + meta_len ..], 0);
}

/// Page offsets derived from the canonical layout of a capacity.
const Geometry = struct {
    cols: usize,
    rows: usize,
    cells_start: usize,
    cells_end: usize,

    fn init(capacity: pagepkg.Capacity, memory_len: usize) ?Geometry {
        const layout = TerminalPage.layout(capacity);
        if (layout.total_size != memory_len) return null;
        assert(layout.rows_start == 0);
        assert(layout.rows_size == @as(usize, capacity.rows) * 8);
        return .{
            .cols = capacity.cols,
            .rows = capacity.rows,
            .cells_start = layout.cells_start,
            .cells_end = layout.cells_start + layout.cells_size,
        };
    }

    /// The byte offset of cell row `y` in memory order.
    fn cellRow(self: Geometry, y: usize) usize {
        return self.cells_start + y * self.cols * @sizeOf(pagepkg.Cell);
    }

    /// The row word an unrotated row `y` holds: no flags, pointing at cell
    /// row `y`.
    fn identity(self: Geometry, y: usize) u64 {
        const row: pagepkg.Row = .{ .cells = .{ .offset = @intCast(self.cellRow(y)) } };
        return @bitCast(row);
    }

    /// Metadata bytes through the last nonzero byte of `memory`.
    fn metaLen(self: Geometry, memory: []const u8) usize {
        const meta = memory[self.cells_end..];
        const last = std.mem.findLastNone(u8, meta, &.{0}) orelse return 0;
        return last + 1;
    }
};

comptime {
    // Row and cell words are moved as u64 values.
    assert(@sizeOf(pagepkg.Row) == 8);
    assert(@sizeOf(pagepkg.Cell) == 8);
}

/// The number of cells through the last nonzero cell of the cell row at
/// `start`, and the narrowest width admitting all of them.
fn scan(memory: []const u8, start: usize, cols: usize) struct { usize, Width } {
    var count = cols;
    while (count > 0 and
        std.mem.readInt(u64, memory[start + (count - 1) * 8 ..][0..8], native) == 0)
        count -= 1;

    var bits: u64 = 0;
    for (0..count) |x| bits |= std.mem.readInt(u64, memory[start + x * 8 ..][0..8], native);
    return .{ count, Width.select(bits) };
}

/// Test helper: a page covering every packed width, rotated rows, row flags,
/// and each kind of state outside the cells: styles past ID 63, wide and
/// spacer cells, graphemes, hyperlinks, background-only cells, and empty,
/// partial, and full rows. The caller owns the page.
pub fn testPage() !TerminalPage {
    var page = try TerminalPage.init(.{
        .cols = 24,
        .rows = 16,
        .styles = 128,
        .grapheme_bytes = 512,
        .string_bytes = 512,
    });
    errdefer page.deinit();

    // Capacity rows past the size are packed like any other.
    page.size.rows = 12;

    // Row 0: full ASCII, one byte per cell and nothing to elide.
    for (0..24) |x| page.getRowAndCell(x, 0).cell.* = .init(@intCast('a' + x % 26));

    // Row 1: BMP text at two bytes per cell, then trailing blanks.
    for ([_]u21{ 'h', 0xE9, 'l', 'l', 'o', 0x2192 }, 0..) |cp, x| {
        page.getRowAndCell(x, 1).cell.* = .init(cp);
    }

    // Row 2: wide pairs, an astral wide emoji, and a spacer head ending a
    // soft-wrapped row which row 3 continues.
    for ([_]u21{ 0x4E16, 0x754C, 0x1F600 }, 0..) |cp, i| {
        var wide: pagepkg.Cell = .init(cp);
        wide.wide = .wide;
        page.getRowAndCell(i * 2, 2).cell.* = wide;
        page.getRowAndCell(i * 2 + 1, 2).cell.* = .{ .wide = .spacer_tail };
    }
    page.getRowAndCell(23, 2).cell.* = .{ .wide = .spacer_head };
    page.getRowAndCell(0, 2).row.wrap = true;
    page.getRowAndCell(0, 3).row.wrap_continuation = true;

    // Row 3: graphemes, a combining mark and a ZWJ sequence.
    {
        const e = page.getRowAndCell(0, 3);
        e.cell.* = .init('e');
        try page.appendGrapheme(e.row, e.cell, 0x0301);
        const family = page.getRowAndCell(1, 3);
        family.cell.* = .init(0x1F468);
        family.cell.wide = .wide;
        page.getRowAndCell(2, 3).cell.* = .{ .wide = .spacer_tail };
        for ([_]u21{ 0x200D, 0x1F469, 0x200D, 0x1F467 }) |cp| {
            try page.appendGrapheme(family.row, family.cell, cp);
        }
    }

    // Rows 4-6: seventy distinct styles. IDs past 63 need full words.
    for (0..70) |i| {
        const rac = page.getRowAndCell(i % 24, 4 + i / 24);
        rac.cell.* = .init('S');
        rac.cell.style_id = try page.styles.add(page.memory, .{
            .fg_color = .{ .palette = @intCast(i) },
            .flags = .{ .bold = i % 2 == 0 },
        });
        rac.row.styled = true;
    }

    // Row 7: two cells sharing a hyperlink and one with its own.
    {
        const shared = try page.insertHyperlink(.{
            .id = .{ .explicit = "shared" },
            .uri = "https://ghostty.org/docs",
        });
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, 7);
            rac.cell.* = .init('L');
            if (x > 0) page.hyperlink_set.use(page.memory, shared);
            try page.setHyperlink(rac.row, rac.cell, shared);
        }
        const own = try page.insertHyperlink(.{
            .id = .{ .implicit = 7 },
            .uri = "file:///tmp",
        });
        const rac = page.getRowAndCell(5, 7);
        rac.cell.* = .init('F');
        try page.setHyperlink(rac.row, rac.cell, own);
    }

    // Row 8: background-only cells, a protected cell, and prompt and input
    // semantic content.
    page.getRowAndCell(0, 8).cell.* = .{
        .content_tag = .bg_color_palette,
        .content = .{ .color_palette = .{ .data = 4 } },
    };
    page.getRowAndCell(1, 8).cell.* = .{
        .content_tag = .bg_color_rgb,
        .content = .{ .color_rgb = .{ .r = 1, .g = 2, .b = 3 } },
    };
    page.getRowAndCell(2, 8).cell.* = .{
        .content = .{ .codepoint = .{ .data = 'P' } },
        .protected = true,
    };
    page.getRowAndCell(3, 8).cell.* = .{
        .content = .{ .codepoint = .{ .data = '$' } },
        .semantic_content = .prompt,
    };
    page.getRowAndCell(4, 8).cell.* = .{
        .content = .{ .codepoint = .{ .data = 'l' } },
        .semantic_content = .input,
    };

    // Row 9: blank but flagged. Rows 10 and up stay empty.
    page.getRowAndCell(0, 9).row.semantic_prompt = .prompt;

    // Swap rows 0 and 9 so neither points at its own cell row.
    const rows = page.rows.ptr(page.memory);
    std.mem.swap(pagepkg.Row, &rows[0], &rows[9]);

    return page;
}

/// Pack `page` at the end of a garbage-filled buffer and unpack it there.
fn testRoundTrip(page: *const TerminalPage) ![]align(std.heap.page_size_min) u8 {
    const len = packedLen(page) orelse return error.TestUnexpectedResult;
    const memory = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        page.memory.len,
    );
    errdefer testing.allocator.free(memory);

    // Unpacking must overwrite every byte, so garbage must not survive.
    @memset(memory, 0xAA);
    pack(page, memory[memory.len - len ..]);
    try unpack(page.capacity, memory, len);
    return memory;
}

const testing = std.testing;

test "rowpack round trip is byte exact" {
    var page = try testPage();
    defer page.deinit();
    try page.verifyIntegrity(testing.allocator);

    const memory = try testRoundTrip(&page);
    defer testing.allocator.free(memory);
    try testing.expectEqualSlices(u8, page.memory, memory);

    // Identical bytes imply identical contents, but spell out what the page
    // holds so a broken fixture can't make this vacuous.
    var restored = page;
    restored.memory = memory;
    try restored.verifyIntegrity(testing.allocator);

    // Rows 0 and 9 were swapped, so row 9 shows the full ASCII row.
    try testing.expectEqual(@as(u21, 'x'), restored.getRowAndCell(23, 9).cell.codepoint());
    try testing.expectEqual(.wide, restored.getRowAndCell(4, 2).cell.wide);
    try testing.expectEqual(@as(u21, 0x1F600), restored.getRowAndCell(4, 2).cell.codepoint());
    try testing.expectEqual(.spacer_head, restored.getRowAndCell(23, 2).cell.wide);
    try testing.expectEqualSlices(
        u21,
        &.{ 0x200D, 0x1F469, 0x200D, 0x1F467 },
        restored.lookupGrapheme(restored.getRowAndCell(1, 3).cell).?,
    );

    const styled = restored.getRowAndCell(69 % 24, 4 + 69 / 24).cell;
    try testing.expect(styled.style_id > 63);
    try testing.expectEqual(
        @as(u8, 69),
        restored.styles.get(restored.memory, styled.style_id).fg_color.palette,
    );

    const link = restored.lookupHyperlink(restored.getRowAndCell(1, 7).cell).?;
    try testing.expectEqualStrings(
        "https://ghostty.org/docs",
        restored.hyperlink_set.get(restored.memory, link).uri.slice(restored.memory),
    );
    try testing.expectEqual(.input, restored.getRowAndCell(4, 8).cell.semantic_content);
}

test "rowpack records use the narrowest width" {
    var page = try testPage();
    defer page.deinit();

    const len = packedLen(&page).?;
    const image = try testing.allocator.alloc(u8, len);
    defer testing.allocator.free(image);
    pack(&page, image);

    // Walk the records independently of `unpack`, in cell row order (the row
    // swap in the fixture moves row headers, not cell rows).
    const Record = struct { Width, u16 };
    const expected = [_]Record{
        .{ .one, 24 }, // ASCII
        .{ .two, 6 }, // BMP text
        .{ .eight, 24 }, // wide cells
        .{ .eight, 3 }, // graphemes, one of them wide
        .{ .four, 24 }, // style IDs 1-24
        .{ .four, 24 }, // style IDs 25-48
        .{ .eight, 22 }, // style IDs past 63 need full words
        .{ .eight, 6 }, // hyperlinks
        .{ .eight, 5 }, // flags and semantic content
    };
    const layout = TerminalPage.layout(page.capacity);
    var r = layout.cells_start;
    for (0..page.capacity.rows) |y| {
        const width: Width = @fromBackingInt(@intCast(image[r]));
        const count = std.mem.readInt(u16, image[r + 1 ..][0..2], .little);
        const want: Record = if (y < expected.len) expected[y] else .{ .one, 0 };
        try testing.expectEqual(want, Record{ width, count });
        r += record_header_len + count * width.size();
    }

    // Row headers are stored relative to their identity, so rows which are
    // neither swapped nor flagged pack to zero.
    for ([_]usize{ 1, 8, 10, 11, 12, 13, 14, 15 }) |y| {
        const word = std.mem.readInt(u64, image[y * 8 ..][0..8], .little);
        try testing.expectEqual(@as(u64, 0), word);
    }

    // The metadata is everything after the records.
    try testing.expect(len - r > 0);
    try testing.expect(len < page.memory.len);
}

test "rowpack declines pages it cannot unpack in place" {
    var page = try TerminalPage.init(.{ .cols = 8, .rows = 8, .styles = 0 });
    defer page.deinit();

    // Every cell row needs full words and no tail byte of the page is zero,
    // so each record outgrows its raw row and nothing makes up for it.
    const cells = page.cells.ptr(page.memory)[0 .. 8 * 8];
    for (cells, 0..) |*cell, i| {
        cell.* = .init(@intCast('A' + i % 26));
        cell.wide = .spacer_tail;
    }
    page.memory[page.memory.len - 1] = 1;
    try testing.expectEqual(null, packedLen(&page));

    // A zero byte at the end of the memory gives the unpacker room to read
    // ahead, so the same rows become packable once there is enough of it.
    page.memory[page.memory.len - 1] = 0;
    const memory = try testRoundTrip(&page);
    defer testing.allocator.free(memory);
    try testing.expectEqualSlices(u8, page.memory, memory);
}

test "rowpack declines expanding rows after compressible ones" {
    var page = try TerminalPage.init(.{ .cols = 8, .rows = 8, .styles = 0 });
    defer page.deinit();

    // Rows 0-3 are empty and pack to bare headers, so the page as a whole
    // shrinks. Rows 4-7 need full words, and expanding the empty rows first
    // brings the write cursor up to their records before they are read.
    const cells = page.cells.ptr(page.memory)[4 * 8 .. 8 * 8];
    for (cells, 0..) |*cell, i| {
        cell.* = .init(@intCast('A' + i % 26));
        cell.wide = .spacer_tail;
    }
    page.memory[page.memory.len - 1] = 1;

    if (packedLen(&page) == null) return;
    const memory = try testRoundTrip(&page);
    defer testing.allocator.free(memory);
    try testing.expectEqualSlices(u8, page.memory, memory);
}

test "rowpack unpack survives corrupt images" {
    var page = try testPage();
    defer page.deinit();

    const len = packedLen(&page).?;
    const image = try testing.allocator.alloc(u8, len);
    defer testing.allocator.free(image);
    pack(&page, image);

    const memory = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        page.memory.len,
    );
    defer testing.allocator.free(memory);

    // Runtime safety turns any out-of-bounds access into a test failure.
    // Errors and garbage output are both acceptable for corrupt input.
    var prng = std.Random.DefaultPrng.init(0x5243_4B50);
    const random = prng.random();
    for (0..500) |_| {
        const corrupt_len = if (random.boolean())
            len
        else
            random.uintAtMost(usize, memory.len);
        const start = memory.len - corrupt_len;
        @memset(memory, 0);
        const copy_len = @min(len, corrupt_len);
        @memcpy(memory[start..][0..copy_len], image[0..copy_len]);
        for (0..random.uintAtMost(usize, 4)) |_| {
            if (corrupt_len == 0) break;
            memory[start + random.uintLessThan(usize, corrupt_len)] = random.int(u8);
        }
        unpack(page.capacity, memory, corrupt_len) catch {};
    }

    try testing.expectError(
        error.InvalidPacking,
        unpack(page.capacity, memory, memory.len + 1),
    );
    try testing.expectError(
        error.InvalidPacking,
        unpack(pagepkg.std_capacity, memory, len),
    );
}

/// Round-trip random page images. Packing is a byte transform, so the bytes
/// need not form a valid page, only the shapes packing cares about: rows of
/// every width and length, rotated and flagged row words, and metadata
/// ending anywhere.
fn propertySuite(iterations: usize, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var accepted: usize = 0;
    for (0..iterations) |_| {
        var page = try TerminalPage.init(.{
            .cols = random.intRangeAtMost(u16, 1, 300),
            .rows = random.intRangeAtMost(u16, 1, 64),
            .styles = 16,
        });
        defer page.deinit();
        const geo = Geometry.init(page.capacity, page.memory.len).?;
        const memory = page.memory;

        for (0..geo.rows) |y| {
            const word = switch (random.uintLessThan(u8, 3)) {
                0 => geo.identity(y),
                1 => geo.identity(random.uintLessThan(usize, geo.rows)) |
                    @as(u64, random.int(u32)) << 32,
                else => random.int(u64),
            };
            std.mem.writeInt(u64, memory[y * 8 ..][0..8], word, native);
        }

        for (0..geo.rows) |y| {
            const mask: u64 = switch (random.enumValue(Width)) {
                inline else => |w| comptime w.mask(),
            };
            const start = geo.cellRow(y);
            for (0..random.uintAtMost(usize, geo.cols)) |x| {
                std.mem.writeInt(u64, memory[start + x * 8 ..][0..8], random.int(u64) & mask, native);
            }
        }

        for (0..random.uintAtMost(usize, 8)) |_| {
            const meta_len = memory.len - geo.cells_end;
            memory[geo.cells_end + random.uintLessThan(usize, meta_len)] = random.int(u8);
        }

        if (packedLen(&page) == null) continue;
        accepted += 1;
        const restored = try testRoundTrip(&page);
        defer testing.allocator.free(restored);
        try testing.expectEqualSlices(u8, memory, restored);
    }

    // Declining is legal but must stay the exception.
    try testing.expect(accepted > iterations / 2);
}

test "rowpack property light" {
    try propertySuite(40, 0x524F_5701);
}

test "rowpack property exhaustive" {
    // Slow. Enable explicitly, ideally together with a test filter:
    //   GHOSTTY_ROWPACK_SLOW=1 zig build test -Dtest-filter="rowpack property"
    if (!std.testing.environ.containsConstant("GHOSTTY_ROWPACK_SLOW"))
        return error.SkipZigTest;

    for (0..4) |seed| try propertySuite(2000, 0x524F_5800 + seed);
}
