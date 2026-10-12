//! ACC: Automatic Contrast Correction.
//!
//! Finds foreground colours that fall below WCAG 4.5:1 against their cell's
//! own background and moves them the smallest OKLab lightness step that
//! makes them legible. Hue is kept (nudged slightly towards the nearest
//! theme colour), chroma shrinks as needed, and results are cached per
//! (fg, bg) pair so the steady-state cost is one hash probe per cell.
const std = @import("std");
const RGB = @import("../terminal/color.zig").RGB;

/// WCAG AA body text.
pub const target: f32 = 4.5;

// Tunables, set by comparing screenshots against Rex.
const margin: f32 = 0.15;
const hue_pull: f32 = 0.35;
const hue_cap: f32 = 6;
const neutral_chroma: f32 = 0.03;
const neutral_max_chroma: f32 = 0.02;

const cache_bits = 12;
const cache_len = 1 << cache_bits;

pub const Acc = struct {
    bg_hue: f32,
    fg_hue: f32,
    anchors: [13]f32 = undefined,
    anchors_len: usize = 0,

    /// Packed (valid | fg << 24 | bg); 0 is an empty slot.
    keys: [cache_len]u64 = @splat(0),
    vals: [cache_len]RGB = undefined,

    /// Build the corrector for a theme. Re-init on theme change to flush
    /// the cache.
    pub fn init(bg: RGB, fg: RGB, palette: *const [256]RGB) Acc {
        var self: Acc = .{
            .bg_hue = Lch.from(bg).h,
            .fg_hue = Lch.from(fg).h,
        };
        const sources = [_]RGB{fg} ++ palette[1..7].* ++ palette[9..15].*;
        for (sources) |c| {
            const lch = Lch.from(c);
            if (lch.c <= neutral_chroma) continue;
            self.anchors[self.anchors_len] = lch.h;
            self.anchors_len += 1;
        }
        return self;
    }

    /// The legible version of `fg` on `bg`, cached.
    pub inline fn get(self: *Acc, fg: RGB, bg: RGB) RGB {
        const key: u64 = (1 << 48) |
            @as(u64, @as(u24, @bitCast(fg))) << 24 |
            @as(u24, @bitCast(bg));
        // ponytail: direct-mapped, a colliding pair just recomputes.
        const slot: usize = @intCast((key *% 0x9E3779B97F4A7C15) >> (64 - cache_bits));
        if (self.keys[slot] == key) return self.vals[slot];
        const v = self.correct(fg, bg);
        self.keys[slot] = key;
        self.vals[slot] = v;
        return v;
    }

    /// The uncached correction.
    pub fn correct(self: *const Acc, fg: RGB, bg: RGB) RGB {
        const bg_y = luminance(bg);
        if (ratio(luminance(fg), bg_y) >= target) return fg;

        const lighter = ratio(1, bg_y) > ratio(0, bg_y);
        const end: f32 = if (lighter) 1 else 0;
        const src = Lch.from(fg);
        const neutral = src.c < neutral_chroma;
        const hue = if (!neutral)
            self.harmonize(src.h)
        else if (lighter)
            self.bg_hue
        else
            self.fg_hue;
        const chroma = if (neutral) @min(src.c, neutral_max_chroma) else src.c;

        // Bisect the fraction of the way from L to the end for the
        // smallest move that clears the target plus margin.
        var lo: f32 = 0;
        var hi: f32 = 1;
        var best: ?RGB = null;
        for (0..10) |_| {
            const mid = (lo + hi) / 2;
            const l = src.l + (end - src.l) * mid;
            const c = toRgb(l, chroma * @min(1, l / src.l), hue);
            if (ratio(luminance(c), bg_y) >= target + margin) {
                best = c;
                hi = mid;
            } else lo = mid;
        }
        if (best) |c| if (ratio(luminance(c), bg_y) >= target) return c;

        // Unreachable (mid-grey bg): fall back to black or white like
        // Ghostty's minimum-contrast does.
        return if (lighter) .{ .r = 255, .g = 255, .b = 255 } else .{};
    }

    fn harmonize(self: *const Acc, h: f32) f32 {
        if (self.anchors_len == 0) return h;
        var nearest: f32 = 360;
        for (self.anchors[0..self.anchors_len]) |a| {
            const d = hueDelta(h, a);
            if (@abs(d) < @abs(nearest)) nearest = d;
        }
        return h + std.math.clamp(nearest * hue_pull, -hue_cap, hue_cap);
    }
};

/// True when dark text is the legible choice on `bg`; ACC's Auto mode is
/// on for these themes.
pub fn isLight(bg: RGB) bool {
    const y = luminance(bg);
    return ratio(0, y) > ratio(1, y);
}

/// `fg` drawn over `bg` at `alpha`, as faint text is.
pub fn blend(fg: RGB, bg: RGB, alpha: u8) RGB {
    const a: u16 = alpha;
    return .{
        .r = @intCast((@as(u16, fg.r) * a + @as(u16, bg.r) * (255 - a) + 127) / 255),
        .g = @intCast((@as(u16, fg.g) * a + @as(u16, bg.g) * (255 - a) + 127) / 255),
        .b = @intCast((@as(u16, fg.b) * a + @as(u16, bg.b) * (255 - a) + 127) / 255),
    };
}

/// WCAG contrast ratio between two colours.
pub fn contrast(a: RGB, b: RGB) f32 {
    return ratio(luminance(a), luminance(b));
}

fn ratio(a: f32, b: f32) f32 {
    return (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
}

fn luminance(c: RGB) f32 {
    return 0.2126 * linear[c.r] + 0.7152 * linear[c.g] + 0.0722 * linear[c.b];
}

const linear: [256]f32 = table: {
    @setEvalBranchQuota(100_000);
    var t: [256]f32 = undefined;
    for (&t, 0..) |*v, i| {
        const c: f64 = @as(f64, @floatFromInt(i)) / 255;
        v.* = @floatCast(if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4));
    }
    break :table t;
};

fn encode(v: f32) u8 {
    const c = std.math.clamp(v, 0, 1);
    const s = if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(s * 255));
}

/// OKLCh with hue in degrees.
const Lch = struct {
    l: f32,
    c: f32,
    h: f32,

    fn from(rgb: RGB) Lch {
        const r = linear[rgb.r];
        const g = linear[rgb.g];
        const b = linear[rgb.b];
        const l_ = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
        const m_ = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
        const s_ = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
        const lab_a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
        const lab_b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;
        return .{
            .l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            .c = @sqrt(lab_a * lab_a + lab_b * lab_b),
            .h = std.math.radiansToDegrees(std.math.atan2(lab_b, lab_a)),
        };
    }
};

/// OKLCh to linear sRGB, unclamped.
fn toLinear(l: f32, c: f32, h: f32) [3]f32 {
    const rad = std.math.degreesToRadians(h);
    const a = c * @cos(rad);
    const b = c * @sin(rad);
    const l_ = l + 0.3963377774 * a + 0.2158037573 * b;
    const m_ = l - 0.1055613458 * a - 0.0638541728 * b;
    const s_ = l - 0.0894841775 * a - 1.2914855480 * b;
    const lc = l_ * l_ * l_;
    const mc = m_ * m_ * m_;
    const sc = s_ * s_ * s_;
    return .{
        4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
        -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
        -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc,
    };
}

/// OKLCh to sRGB8, reducing chroma at fixed L and h until in gamut.
fn toRgb(l: f32, c: f32, h: f32) RGB {
    var v = toLinear(l, c, h);
    if (!inGamut(v)) {
        var lo: f32 = 0;
        var hi: f32 = c;
        for (0..12) |_| {
            const mid = (lo + hi) / 2;
            if (inGamut(toLinear(l, mid, h))) lo = mid else hi = mid;
        }
        v = toLinear(l, lo, h);
    }
    return .{ .r = encode(v[0]), .g = encode(v[1]), .b = encode(v[2]) };
}

fn inGamut(v: [3]f32) bool {
    const eps = 1e-4;
    for (v) |x| if (x < -eps or x > 1 + eps) return false;
    return true;
}

/// Signed shortest hue difference `to - from` in (-180, 180].
fn hueDelta(from: f32, to: f32) f32 {
    const d = @mod(to - from + 180, 360) - 180;
    return if (d == -180) 180 else d;
}

const testing = std.testing;
const default_palette = @import("../terminal/color.zig").default;

fn hex(v: u24) RGB {
    return @bitCast(@as(u24, @byteSwap(v)));
}

const light_bg = hex(0xF8F6F7);
const bar_bg = hex(0x5471BD);

/// The ten ACC-off pairs sampled from Rex's light-theme screenshots.
const off_pairs = [_][2]RGB{
    .{ hex(0xF9FBE7), light_bg }, // lsd user
    .{ hex(0xFAFCD2), light_bg }, // lsd size
    .{ hex(0x6F9C8F), light_bg }, // lsd date, mid green
    .{ hex(0x82C0A0), light_bg }, // lsd date, light green
    .{ hex(0x82797A), light_bg }, // lsd perms
    .{ hex(0x626B95), light_bg }, // lsd .druk, already legible
    .{ hex(0xC8C6C4), light_bg }, // btop dim labels
    .{ hex(0x6994C1), bar_bg }, // lazygit selected branch
    .{ hex(0x8576CC), bar_bg }, // lazygit selected path
    .{ hex(0x3C476B), bar_bg }, // lazygit selected name
};

fn testAcc() Acc {
    return .init(light_bg, hex(0x3A3A3A), &default_palette);
}

test "rex acc: hex is big-endian rgb" {
    try testing.expectEqual(RGB{ .r = 0x12, .g = 0x34, .b = 0x56 }, hex(0x123456));
}

test "rex acc: off-pairs reach the target, keep hue, minimal change" {
    const acc = testAcc();
    for (off_pairs) |p| {
        const out = acc.correct(p[0], p[1]);
        try testing.expect(contrast(out, p[1]) >= target);

        // Already legible: untouched.
        if (contrast(p[0], p[1]) >= target) {
            try testing.expectEqual(p[0], out);
            continue;
        }

        // Darkened on the light bg, lightened on the blue bar.
        const lighter = !isLight(p[1]);
        try testing.expectEqual(lighter, luminance(out) > luminance(p[0]));

        // Hue is undefined at near-zero chroma, so the check applies when the output chroma is at least 0.02.
        const in = Lch.from(p[0]);
        const o = Lch.from(out);
        if (in.c >= 0.04 and o.c >= 0.02) {
            try testing.expect(@abs(hueDelta(in.h, o.h)) <= 10);
        }

        // Stops just past the target rather than at black or white.
        try testing.expect(contrast(out, p[1]) < 7);
    }
}

test "rex acc: idempotent" {
    var acc = testAcc();
    for (off_pairs) |p| {
        const once = acc.get(p[0], p[1]);
        try testing.expectEqual(once, acc.get(once, p[1]));
        try testing.expectEqual(once, acc.get(p[0], p[1]));
    }
}

test "rex acc: faint text reaches the target after blending" {
    var acc = testAcc();
    const fg = hex(0x6F9C8F);
    const blended = blend(fg, light_bg, 128);
    try testing.expect(contrast(blended, light_bg) < target);
    const out = acc.get(blended, light_bg);
    try testing.expect(contrast(out, light_bg) >= target);
}

test "rex acc: lightens on a dark bg" {
    const bg = hex(0x1E1E1E);
    const acc: Acc = .init(bg, hex(0xD0D0D0), &default_palette);
    const fg = hex(0x3B4A6B);
    const out = acc.correct(fg, bg);
    try testing.expect(contrast(out, bg) >= target);
    try testing.expect(luminance(out) > luminance(fg));
    try testing.expect(@abs(hueDelta(Lch.from(fg).h, Lch.from(out).h)) <= 10);
    try testing.expect(!isLight(bg));
    try testing.expect(isLight(light_bg));
}

test "rex acc: cached lookup cost" {
    var acc = try testing.allocator.create(Acc);
    defer testing.allocator.destroy(acc);
    acc.* = testAcc();
    for (off_pairs) |p| _ = acc.get(p[0], p[1]);

    var pairs = off_pairs;
    std.mem.doNotOptimizeAway(&pairs);
    const n = 10_000_000;
    const start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
    var sink: u32 = 0;
    for (0..n) |i| {
        const p = pairs[i % pairs.len];
        sink +%= @as(u24, @bitCast(acc.get(p[0], p[1])));
    }
    std.mem.doNotOptimizeAway(sink);
    const ns: f64 = @as(f64, @floatFromInt(std.Io.Clock.awake.now(testing.io).toNanoseconds() - start)) / n;
    // Only meaningful optimized; run with zig test -OReleaseFast to see it.
    if (@import("builtin").mode == .fast) {
        std.debug.print("rex acc: {d:.2} ns per cached lookup\n", .{ns});
        try testing.expect(ns <= 20);
    }
}
