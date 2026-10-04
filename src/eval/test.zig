const std = @import("std");
const evaluator = @import("evaluator.zig");
const eval = @import("root.zig");

test {
    @import("test_discovery").discover(eval);
    @import("test_discovery").discover(evaluator);
}

test "accy eval declaration coverage" {
    std.testing.refAllDecls(eval);
    std.testing.refAllDecls(evaluator);
}
