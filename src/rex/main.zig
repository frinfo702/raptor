//! Rex: the persistent terminal server and its clients.
pub const Block = @import("Block.zig");
pub const Server = @import("Server.zig");
pub const ids = @import("ids.zig");
pub const layout = @import("layout.zig");
pub const protocol = @import("protocol.zig");

test {
    _ = Block;
    _ = Server;
    _ = ids;
    _ = layout;
    _ = protocol;
}
