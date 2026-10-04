const std = @import("std");
const subject = @import("root.zig");
const local = @import("local.zig");
const pointer = @import("pointer.zig");
const thread = @import("thread.zig");
const transfer = @import("transfer.zig");

comptime {
    _ = subject;
}

test {
    std.testing.refAllDecls(local);
    std.testing.refAllDecls(pointer);
    std.testing.refAllDecls(thread);
    std.testing.refAllDecls(transfer);
}
