//! Rex: the persistent terminal server and its clients.
pub const Block = @import("Block.zig");
pub const Client = @import("Client.zig");
pub const Feed = @import("Feed.zig");
pub const Mirror = @import("Mirror.zig");
pub const Server = @import("Server.zig");
pub const dataplane = @import("dataplane.zig");
pub const ids = @import("ids.zig");
pub const layout = @import("layout.zig");
pub const listdir = @import("listdir.zig");
pub const proc = @import("proc.zig");
pub const protocol = @import("protocol.zig");
pub const restore = @import("restore.zig");

test {
    _ = Block;
    _ = Client;
    _ = @import("client_test.zig");
    _ = Feed;
    _ = Mirror;
    _ = dataplane;
    _ = @import("dataplane_test.zig");
    _ = Server;
    _ = ids;
    _ = layout;
    _ = listdir;
    _ = proc;
    _ = protocol;
    _ = restore;
}
