//! Object ids and generated names.
const std = @import("std");

/// A UUIDv7 in its 36 character text form. Ids sort by creation time.
pub const Uuid = [36]u8;

pub fn uuidv7(io: std.Io) Uuid {
    var b: [16]u8 = undefined;
    io.random(&b);
    const ms: u48 = @truncate(@as(u64, @intCast(std.Io.Clock.real.now(io).toMilliseconds())));
    std.mem.writeInt(u48, b[0..6], ms, .big);
    b[6] = (b[6] & 0x0f) | 0x70;
    b[8] = (b[8] & 0x3f) | 0x80;

    var out: Uuid = undefined;
    const hex = "0123456789abcdef";
    var i: usize = 0;
    for (b, 0..) |byte, n| {
        if (n == 4 or n == 6 or n == 8 or n == 10) {
            out[i] = '-';
            i += 1;
        }
        out[i] = hex[byte >> 4];
        out[i + 1] = hex[byte & 0xf];
        i += 2;
    }
    return out;
}

const adjectives = [_][]const u8{
    "amber", "ancient",   "autumn",  "bold",   "brave",  "bright",
    "calm",  "cosmic",    "crimson", "crisp",  "dawn",   "drifting",
    "dusky", "electric",  "faded",   "gentle", "golden", "hidden",
    "icy",   "lively",    "lunar",   "misty",  "mossy",  "quiet",
    "rapid", "restless",  "rustic",  "silent", "solar",  "steady",
    "swift", "wandering",
};

const nouns = [_][]const u8{
    "bay",    "brook",  "canyon", "cedar",   "cliff",  "comet",
    "cove",   "delta",  "dune",   "ember",   "fern",   "fjord",
    "forest", "glade",  "harbor", "heron",   "island", "lagoon",
    "meadow", "mesa",   "orbit",  "pine",    "quarry", "reef",
    "ridge",  "river",  "summit", "thicket", "tundra", "valley",
    "willow", "zephyr",
};

/// A random adjective-noun session name such as "cosmic-summit".
pub fn sessionName(io: std.Io, buf: []u8) []const u8 {
    var r: [2]u8 = undefined;
    io.random(&r);
    return std.fmt.bufPrint(buf, "{s}-{s}", .{
        adjectives[r[0] % adjectives.len],
        nouns[r[1] % nouns.len],
    }) catch unreachable;
}

test "rex ids: uuidv7 layout" {
    const a = uuidv7(std.testing.io);
    const b = uuidv7(std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    for ([_]usize{ 8, 13, 18, 23 }) |i| try std.testing.expectEqual('-', a[i]);
    try std.testing.expectEqual('7', a[14]);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", a[19]) != null);
    // The leading timestamp makes later ids sort after earlier ones.
    try std.testing.expect(std.mem.order(u8, a[0..13], b[0..13]) != .gt);
}

test "rex ids: session names are adjective-noun" {
    var buf: [32]u8 = undefined;
    const name = sessionName(std.testing.io, &buf);
    const dash = std.mem.indexOfScalar(u8, name, '-').?;
    for (adjectives) |a| {
        if (std.mem.eql(u8, a, name[0..dash])) break;
    } else return error.TestUnexpectedResult;
}
