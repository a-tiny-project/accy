const fixture = @import("../fixture/root.zig");
const std = @import("std");
const source = @import("root.zig");
const choir = @import("../../root.zig");
const verification = @import("verification/test.zig");

test {
    std.testing.refAllDecls(source);
    _ = verification;
}

test "composition source products preserve explicit partition boundaries" {
    const records = try fixture.Records.init(std.testing.allocator);
    defer records.deinit();
    var source_module = try source.PartitionedModule.init(std.testing.allocator, "hybrid.score");
    defer source_module.deinit();

    try source_module.addBoundary(.{ .id = .{ .value = 1 }, .name = "x", .element_type = .f32, .dimensions = &.{8}, .byte_size = 32, .access = .read_write, .ownership = .borrowed, .alias = .disjoint, .provenance = .{ .path = "score.chic", .symbol = "x", .line = 4 } });
    try source_module.addBoundary(.{ .id = .{ .value = 2 }, .name = "y", .element_type = .f32, .dimensions = &.{8}, .byte_size = 32, .access = .write, .ownership = .produced, .alias = .disjoint, .provenance = .{ .path = "score.chic", .symbol = "y", .line = 6 } });
    try source_module.addPartition(.{ .id = .{ .value = 10 }, .name = "score/host", .pipeline = .choir, .outputs = &.{.{ .value = 1 }}, .product = .{ .producer = "composition-fixture", .source = "90", .stage = "hybrid.host.input", .variant = "default" }, .effect = .none, .provenance = .{ .path = "score.chic", .symbol = "score", .line = 4 } });
    try source_module.addPartition(.{ .id = .{ .value = 11 }, .name = "score/affine", .pipeline = .accy, .inputs = &.{.{ .value = 1 }}, .outputs = &.{.{ .value = 2 }}, .product = .{ .producer = "composition-fixture", .source = "91", .stage = "hybrid.input", .variant = "default" }, .effect = .none, .provenance = .{ .path = "score.chic", .symbol = "affine8", .line = 6 } });
    try source_module.addCallSite(.{ .id = .{ .value = 30 }, .name = "score/affine", .caller = .{ .value = 10 }, .callee = .{ .value = 11 }, .inputs = &.{.{ .value = 1 }}, .outputs = &.{.{ .value = 2 }}, .provenance = .{ .path = "score.chic", .symbol = "affine8", .line = 6 } });
    try source_module.verify();

    const pipeline_input = try source.PipelineInput.init(&source_module, .{ .value = 11 }, .accy, try records.key("hybrid.input", "91", "92"));
    try std.testing.expectEqual(source.Pipeline.accy, pipeline_input.pipeline);

    var copy = try source_module.clone(std.testing.allocator);
    defer copy.deinit();
    try std.testing.expectEqual(@as(usize, 2), copy.partitions.items.len);
    try std.testing.expectEqual(@as(usize, 1), copy.call_sites.items.len);
    try std.testing.expectEqualStrings("affine8", copy.partition(.{ .value = 11 }).?.provenance.symbol);
}

test "partitioned module survives every allocation failure" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const records = try fixture.Records.init(allocator);
            defer records.deinit();
            var source_module = try source.PartitionedModule.init(allocator, "allocation");
            defer source_module.deinit();
            try source_module.addBoundary(.{ .id = .{ .value = 1 }, .name = "input", .element_type = .u8, .dimensions = &.{8}, .byte_size = 8, .access = .read, .ownership = .borrowed, .alias = .disjoint, .provenance = .{ .path = "allocation", .symbol = "input" } });
            try source_module.addBoundary(.{ .id = .{ .value = 2 }, .name = "output", .element_type = .u8, .dimensions = &.{8}, .byte_size = 8, .access = .write, .ownership = .produced, .alias = .disjoint, .provenance = .{ .path = "allocation", .symbol = "output" } });
            try source_module.addPartition(.{ .id = .{ .value = 1 }, .name = "caller", .pipeline = .choir, .product = .{ .producer = "composition-fixture", .source = "1", .stage = "allocation.host.input", .variant = "default" }, .effect = .none, .provenance = .{ .path = "allocation", .symbol = "caller" } });
            try source_module.addPartition(.{ .id = .{ .value = 2 }, .name = "callee", .pipeline = .accy, .inputs = &.{.{ .value = 1 }}, .outputs = &.{.{ .value = 2 }}, .product = .{ .producer = "composition-fixture", .source = "1", .stage = "allocation.input", .variant = "default" }, .effect = .none, .provenance = .{ .path = "allocation", .symbol = "callee" } });
            try source_module.addCallSite(.{ .id = .{ .value = 1 }, .name = "call", .caller = .{ .value = 1 }, .callee = .{ .value = 2 }, .inputs = &.{.{ .value = 1 }}, .outputs = &.{.{ .value = 2 }}, .provenance = .{ .path = "allocation", .symbol = "call" } });
            try source_module.verify();
            var clone = try source_module.clone(allocator);
            defer clone.deinit();
            try clone.verify();
            _ = try source.PipelineInput.init(&source_module, .{ .value = 2 }, .accy, try records.key("allocation.input", "1", "2"));
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}
