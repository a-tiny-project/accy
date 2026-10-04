const std = @import("std");
const compaction = @import("compaction.zig");
const indexing = @import("indexing.zig");
const image = @import("image.zig");
const linalg = @import("linalg/root.zig");
const loss = @import("loss.zig");
const random = @import("random.zig");
const scan = @import("scan.zig");
const segmented = @import("segmented.zig");
const sort = @import("sort.zig");
const sparse = @import("sparse.zig");
const spatial = @import("spatial.zig");
const stencil = @import("stencil.zig");

test {
    _ = @import("linalg/test.zig");
    @import("test_discovery").discover(compaction);
    @import("test_discovery").discover(indexing);
    @import("test_discovery").discover(image);
    @import("test_discovery").discover(linalg);
    @import("test_discovery").discover(loss);
    @import("test_discovery").discover(random);
    @import("test_discovery").discover(scan);
    @import("test_discovery").discover(segmented);
    @import("test_discovery").discover(sort);
    @import("test_discovery").discover(sparse);
    @import("test_discovery").discover(spatial);
    @import("test_discovery").discover(stencil);
}

test "accy kernel library catalog artifact specialized declaration coverage" {
    std.testing.refAllDecls(compaction);
    std.testing.refAllDecls(indexing);
    std.testing.refAllDecls(image);
    std.testing.refAllDecls(linalg);
    std.testing.refAllDecls(loss);
    std.testing.refAllDecls(random);
    std.testing.refAllDecls(scan);
    std.testing.refAllDecls(segmented);
    std.testing.refAllDecls(sort);
    std.testing.refAllDecls(sparse);
    std.testing.refAllDecls(spatial);
    std.testing.refAllDecls(stencil);
}
