const std = @import("std");

const cap = @import("cap.zig");
const table_mod = @import("table.zig");

test "compact namespace" {
    std.testing.refAllDecls(table_mod);
    std.testing.refAllDecls(cap);
}
