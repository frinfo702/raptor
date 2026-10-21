//! The split layout of a window: a binary tree whose leaves are blocks.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A horizontal split places `a` left of `b`, a vertical one places `a`
/// above `b`.
pub const Dir = enum { horizontal, vertical };

pub fn Tree(comptime Leaf: type) type {
    return struct {
        const Self = @This();

        pub const Node = union(enum) {
            leaf: Leaf,
            split: Split,
        };

        pub const Split = struct {
            dir: Dir,
            /// The share of the split that `a` takes. Clients' own
            /// ratios are f64, so they come back from a view unchanged.
            ratio: f64 = 0.5,
            a: *Node,
            b: *Node,
        };

        root: *Node,

        pub fn init(alloc: Allocator, leaf: Leaf) Allocator.Error!Self {
            const root = try alloc.create(Node);
            root.* = .{ .leaf = leaf };
            return .{ .root = root };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            destroyNode(alloc, self.root);
        }

        fn destroyNode(alloc: Allocator, node: *Node) void {
            if (node.* == .split) {
                destroyNode(alloc, node.split.a);
                destroyNode(alloc, node.split.b);
            }
            alloc.destroy(node);
        }

        fn find(node: *Node, leaf: Leaf) ?*Node {
            return switch (node.*) {
                .leaf => |l| if (l == leaf) node else null,
                .split => |s| find(s.a, leaf) orelse find(s.b, leaf),
            };
        }

        pub fn contains(self: Self, leaf: Leaf) bool {
            return find(self.root, leaf) != null;
        }

        /// Split the space of `target` in two, placing `new` second.
        pub fn split(self: *Self, alloc: Allocator, target: Leaf, new: Leaf, dir: Dir) !void {
            const node = find(self.root, target) orelse return error.NotFound;
            const a = try alloc.create(Node);
            errdefer alloc.destroy(a);
            const b = try alloc.create(Node);
            a.* = node.*;
            b.* = .{ .leaf = new };
            node.* = .{ .split = .{ .dir = dir, .a = a, .b = b } };
        }

        /// Remove `leaf`, giving its space to its sibling. The last leaf
        /// can't be removed: the tree is dropped with its window instead.
        pub fn remove(self: *Self, alloc: Allocator, leaf: Leaf) void {
            std.debug.assert(self.root.* == .split);
            removeFrom(alloc, self.root, leaf);
        }

        fn removeFrom(alloc: Allocator, node: *Node, leaf: Leaf) void {
            const s = &node.split;
            inline for (.{ .{ s.a, s.b }, .{ s.b, s.a } }) |pair| {
                const child, const sibling = pair;
                if (child.* == .leaf and child.leaf == leaf) {
                    node.* = sibling.*;
                    alloc.destroy(child);
                    alloc.destroy(sibling);
                    return;
                }
            }
            if (s.a.* == .split and find(s.a, leaf) != null) return removeFrom(alloc, s.a, leaf);
            if (s.b.* == .split) removeFrom(alloc, s.b, leaf);
        }

        /// The leaf to focus once `leaf` is removed: the one in its sibling
        /// that borders it, preferring the top or left one along the other
        /// axis. `leaf` must not be the root.
        pub fn heir(self: Self, leaf: Leaf) Leaf {
            var node = self.root;
            while (true) {
                const s = node.split;
                const in_a = find(s.a, leaf) != null;
                const child = if (in_a) s.a else s.b;
                if (child.* == .split) {
                    node = child;
                    continue;
                }
                // The sibling sits after `leaf` if `leaf` is in `a`, so its
                // bordering leaves are on its first side, else its last.
                var n = if (in_a) s.b else s.a;
                while (n.* == .split) n = if (!in_a and n.split.dir == s.dir) n.split.b else n.split.a;
                return n.leaf;
            }
        }

        /// Move `leaf` beside `target`, splitting the target's space in two
        /// with `leaf` first if `before`, else second.
        pub fn move(self: *Self, alloc: Allocator, leaf: Leaf, target: Leaf, dir: Dir, before: bool) !void {
            if (leaf == target or !self.contains(leaf) or !self.contains(target)) return error.NotFound;
            const a = try alloc.create(Node);
            errdefer alloc.destroy(a);
            const b = try alloc.create(Node);
            // Removing can move the target's node, so find it afterwards.
            self.remove(alloc, leaf);
            const node = find(self.root, target).?;
            a.* = node.*;
            b.* = .{ .leaf = leaf };
            node.* = .{ .split = .{ .dir = dir, .a = if (before) b else a, .b = if (before) a else b } };
        }

        /// Set the share of the split dividing `a` from `b` that `a`'s side
        /// takes. `a` must be on the split's first side.
        pub fn resize(self: *Self, a: Leaf, b: Leaf, ratio: f64) error{NotFound}!void {
            if (a == b or !self.contains(a) or !self.contains(b)) return error.NotFound;
            var node = self.root;
            while (true) {
                const s = &node.split;
                const a_first = find(s.a, a) != null;
                if (a_first == (find(s.a, b) != null)) {
                    node = if (a_first) s.a else s.b;
                    continue;
                }
                if (!a_first) return error.NotFound;
                s.ratio = ratio;
                return;
            }
        }

        /// The top-left leaf.
        pub fn first(self: Self) Leaf {
            var node = self.root;
            while (node.* == .split) node = node.split.a;
            return node.leaf;
        }

        pub fn count(self: Self) usize {
            return countNode(self.root);
        }

        fn countNode(node: *const Node) usize {
            return switch (node.*) {
                .leaf => 1,
                .split => |s| countNode(s.a) + countNode(s.b),
            };
        }

        /// The leaves left to right, top to bottom.
        pub fn leaves(self: Self, alloc: Allocator) Allocator.Error![]Leaf {
            var list: std.ArrayList(Leaf) = .empty;
            errdefer list.deinit(alloc);
            try collect(alloc, self.root, &list);
            return list.toOwnedSlice(alloc);
        }

        fn collect(alloc: Allocator, node: *const Node, list: *std.ArrayList(Leaf)) Allocator.Error!void {
            switch (node.*) {
                .leaf => |l| try list.append(alloc, l),
                .split => |s| {
                    try collect(alloc, s.a, list);
                    try collect(alloc, s.b, list);
                },
            }
        }

        /// Write the tree as JSON, using `ctx.writeLeaf(w, leaf)` for leaves.
        pub fn write(self: Self, w: *std.json.Stringify, ctx: anytype) std.json.Stringify.Error!void {
            try writeNode(self.root, w, ctx);
        }

        fn writeNode(node: *const Node, w: *std.json.Stringify, ctx: anytype) std.json.Stringify.Error!void {
            try w.beginObject();
            switch (node.*) {
                .leaf => |l| {
                    try w.objectField("type");
                    try w.write("block");
                    try ctx.writeLeaf(w, l);
                },
                .split => |s| {
                    try w.objectField("type");
                    try w.write(@tagName(s.dir));
                    try w.objectField("ratio");
                    try w.write(s.ratio);
                    try w.objectField("a");
                    try writeNode(s.a, w, ctx);
                    try w.objectField("b");
                    try writeNode(s.b, w, ctx);
                },
            }
            try w.endObject();
        }
    };
}

test "rex layout: split, remove, and order" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const T = Tree(u8);

    var t = try T.init(alloc, 1);
    defer t.deinit(alloc);
    try t.split(alloc, 1, 2, .horizontal);
    try t.split(alloc, 1, 3, .vertical);
    try testing.expectError(error.NotFound, t.split(alloc, 9, 4, .vertical));
    try testing.expectEqual(3, t.count());

    const order = try t.leaves(alloc);
    defer alloc.free(order);
    try testing.expectEqualSlices(u8, &.{ 1, 3, 2 }, order);
    try testing.expectEqual(1, t.first());

    const Ctx = struct {
        pub fn writeLeaf(_: @This(), w: *std.json.Stringify, l: u8) !void {
            try w.objectField("block");
            try w.write(l);
        }
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var w: std.json.Stringify = .{ .writer = &out.writer };
    try t.write(&w, Ctx{});
    try testing.expectEqualStrings(
        \\{"type":"horizontal","ratio":0.5,"a":{"type":"vertical","ratio":0.5,"a":{"type":"block","block":1},"b":{"type":"block","block":3}},"b":{"type":"block","block":2}}
    , out.written());

    // Moving a leaf takes it out and splits the target's space with it.
    try t.move(alloc, 1, 2, .vertical, true);
    try testing.expect(t.root.* == .split and t.root.split.dir == .horizontal);
    const moved = t.root.split.b;
    try testing.expect(moved.* == .split and moved.split.dir == .vertical);
    try testing.expectEqual(1, moved.split.a.leaf);
    try testing.expectEqual(2, moved.split.b.leaf);
    try t.move(alloc, 3, 1, .horizontal, false);
    try testing.expect(t.root.* == .split and t.root.split.dir == .vertical);
    try testing.expectEqual(2, t.root.split.b.leaf);
    try testing.expectEqual(3, t.root.split.a.split.b.leaf);
    try testing.expectError(error.NotFound, t.move(alloc, 1, 1, .vertical, false));
    try testing.expectError(error.NotFound, t.move(alloc, 9, 1, .vertical, false));
    try testing.expectEqual(3, t.count());

    // Resizing sets the ratio of the split between the two leaves, and only
    // with the first leaf on the split's first side.
    try t.resize(3, 2, 0.25);
    try testing.expectEqual(0.25, t.root.split.ratio);
    try t.resize(1, 3, 0.75);
    try testing.expectEqual(0.75, t.root.split.a.split.ratio);
    try testing.expectEqual(0.25, t.root.split.ratio);
    try testing.expectError(error.NotFound, t.resize(2, 1, 0.5));
    try testing.expectError(error.NotFound, t.resize(1, 1, 0.5));
    try testing.expectError(error.NotFound, t.resize(1, 9, 0.5));

    // Removing a leaf gives its space to its sibling.
    // Here the tree is (1 | 3) above 2.
    try testing.expectEqual(1, t.heir(2));
    try testing.expectEqual(1, t.heir(3));
    try testing.expectEqual(3, t.heir(1));
    t.remove(alloc, 3);
    t.remove(alloc, 2);
    try testing.expectEqual(1, t.count());
    try testing.expect(t.root.* == .leaf and t.root.leaf == 1);
}

test "rex layout: heir borders the removed leaf" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try Tree(u8).init(alloc, 1);
    defer t.deinit(alloc);

    // (1 | 2) | 3: closing the right pane goes to the middle one.
    try t.split(alloc, 1, 3, .horizontal);
    try t.split(alloc, 1, 2, .horizontal);
    try testing.expectEqual(2, t.heir(3));
    try testing.expectEqual(2, t.heir(1));
    try testing.expectEqual(1, t.heir(2));

    // (1 | 2) | (3 above 4): closing 4 goes up, closing 3 goes down.
    try t.split(alloc, 3, 4, .vertical);
    try testing.expectEqual(3, t.heir(4));
    try testing.expectEqual(4, t.heir(3));

    // (1 | (2 above 5)) | 3: closing 3 goes to the top pane beside it.
    t.remove(alloc, 4);
    try t.split(alloc, 2, 5, .vertical);
    try testing.expectEqual(2, t.heir(3));
}
