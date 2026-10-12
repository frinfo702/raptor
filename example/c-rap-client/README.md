# Example: Raptor Client in C

This example uses the rap client in libghostty (`include/raptor.h`). It
starts a test rap server on a private socket, connects to it, and lists
sessions. It then creates a block that prints 1,000 lines and binds that
block to a headless surface (a `rap_mirror_t`). Finally it checks that the
surface's text matches the server's capture of the block. The project
links the full libghostty rather than libghostty-vt, and runs the server
with the `rap` built from the same source.

## Usage

Run the example:

```shell-session
zig build run
```

To use another `rap`, run the built program directly:

```shell-session
zig build
./zig-out/bin/c_rap_client /path/to/rap
```
