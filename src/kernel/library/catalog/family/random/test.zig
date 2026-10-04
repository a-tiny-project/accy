const std = @import("std");
const candidate = @import("candidate.zig");
const philox = @import("philox.zig");
const squares = @import("squares.zig");
const threefry = @import("threefry.zig");

test {
    @import("test_discovery").discover(candidate);
    @import("test_discovery").discover(philox);
    @import("test_discovery").discover(squares);
    @import("test_discovery").discover(threefry);
}

test "accy kernel library catalog family random declaration coverage" {
    std.testing.refAllDecls(candidate);
    std.testing.refAllDecls(philox);
    std.testing.refAllDecls(squares);
    std.testing.refAllDecls(threefry);
}
