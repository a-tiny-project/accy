const std = @import("std");
const artifact = @import("root.zig");
const model = @import("model.zig");
const owned = @import("owned.zig");
const pipeline = @import("pipeline.zig");
const request = @import("request.zig");

test {
    _ = @import("specialized/test.zig");
    @import("test_discovery").discover(artifact);
    @import("test_discovery").discover(model);
    @import("test_discovery").discover(owned);
    @import("test_discovery").discover(pipeline);
    @import("test_discovery").discover(request);
}

test "accy kernel library catalog artifact declaration coverage" {
    std.testing.refAllDecls(artifact);
    std.testing.refAllDecls(model);
    std.testing.refAllDecls(owned);
    std.testing.refAllDecls(pipeline);
    std.testing.refAllDecls(request);
}
