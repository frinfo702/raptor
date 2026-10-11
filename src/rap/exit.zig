//! Process exit codes shared by every `rap` command.

/// Exit status returned by the `rap` executable.
pub const Code = enum(u8) {
    /// The command succeeded.
    ok = 0,

    /// The command failed.
    fail = 1,

    /// The command line was invalid.
    usage = 2,

    /// The target session, window, or block is missing or ambiguous.
    target = 3,

    /// The server could not be reached.
    unreachable_server = 4,

    /// The command was interrupted (128 + SIGINT).
    interrupted = 130,
};
