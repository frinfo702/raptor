//! Rex: the persistent terminal server and its clients.
pub const Block = @import("Block.zig");
pub const Mirror = @import("Mirror.zig");
pub const Server = @import("Server.zig");
pub const dataplane = @import("dataplane.zig");
pub const ids = @import("ids.zig");
pub const layout = @import("layout.zig");
pub const protocol = @import("protocol.zig");
pub const restore = @import("restore.zig");

test {
    _ = Block;
    _ = Mirror;
    _ = dataplane;
    _ = @import("dataplane_test.zig");
    _ = Server;
    _ = ids;
    _ = layout;
    _ = protocol;
    _ = restore;
}
