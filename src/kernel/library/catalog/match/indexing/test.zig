const std = @import("std");
const gather = @import("gather.zig");
const histogram = @import("histogram.zig");
const indexing = @import("root.zig");
const scatter = @import("scatter.zig");
const scatter_add = @import("accumulate.zig");
const schedule = @import("schedule.zig");

test {
    @import("test_discovery").discover(indexing);
    @import("test_discovery").discover(gather);
    @import("test_discovery").discover(histogram);
    @import("test_discovery").discover(scatter);
    @import("test_discovery").discover(scatter_add);
    @import("test_discovery").discover(schedule);
}

test "accy kernel library catalog match indexing declaration coverage" {
    std.testing.refAllDecls(indexing);
    std.testing.refAllDecls(gather);
    std.testing.refAllDecls(histogram);
    std.testing.refAllDecls(scatter);
    std.testing.refAllDecls(scatter_add);
    std.testing.refAllDecls(schedule);
}
