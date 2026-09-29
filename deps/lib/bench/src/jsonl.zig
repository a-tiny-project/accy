const std = @import("std");
const pretty_json = @import("pretty").json;

const stats_mod = @import("stats/root.zig");

pub const Unit = struct {
    name: []const u8,
    count: u64,
};

pub fn writePerUnitFields(
    object: pretty_json.Object,
    value_name: []const u8,
    value: f64,
    units: []const Unit,
) !void {
    for (units) |unit| {
        try object.fieldParts(
            &.{ value_name, "_per_", unit.name },
            stats_mod.valuePerUnit(value, unit.count),
        );
    }
}

pub fn writeNamedPerUnitFields(
    object: pretty_json.Object,
    name: []const u8,
    value_name: []const u8,
    value: f64,
    units: []const Unit,
) !void {
    for (units) |unit| {
        try object.fieldParts(
            &.{ name, "_", value_name, "_per_", unit.name },
            stats_mod.valuePerUnit(value, unit.count),
        );
    }
}

pub fn writeMemoryCounts(
    object: pretty_json.Object,
    name: []const u8,
    counts: anytype,
    units: []const Unit,
) !void {
    try object.fieldParts(&.{ name, "_alloc_count" }, counts.alloc_count);
    try object.fieldParts(&.{ name, "_free_count" }, counts.free_count);
    try object.fieldParts(&.{ name, "_alloc_bytes" }, counts.alloc_bytes);
    try writeNamedPerUnitFields(
        object,
        name,
        "alloc_bytes",
        @floatFromInt(counts.alloc_bytes),
        units,
    );
}

test "write per-unit fields" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const units = [_]Unit{
        .{ .name = "source_op", .count = 4 },
        .{ .name = "final_op", .count = 8 },
    };
    var stream = pretty_json.Writer.init(&out.writer, .minified);
    const object = try stream.object();
    try writePerUnitFields(object, "ns", 120, &units);
    try object.end();

    const text = out.written();
    try std.testing.expectEqualStrings(
        "{\"ns_per_source_op\":30,\"ns_per_final_op\":15}",
        text,
    );
}

test "write named memory count fields" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const units = [_]Unit{.{ .name = "source_op", .count = 8 }};
    var stream = pretty_json.Writer.init(&out.writer, .minified);
    const object = try stream.object();
    try writeMemoryCounts(
        object,
        "phase",
        .{ .alloc_count = 3, .free_count = 2, .alloc_bytes = @as(u64, 64) },
        &units,
    );
    try object.end();

    const text = out.written();
    try std.testing.expectEqualStrings(
        "{\"phase_alloc_count\":3,\"phase_free_count\":2," ++
            "\"phase_alloc_bytes\":64,\"phase_alloc_bytes_per_source_op\":8}",
        text,
    );
}
