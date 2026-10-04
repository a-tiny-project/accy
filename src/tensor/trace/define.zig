const std = @import("std");
const trace = @import("root.zig");

const Builder = trace.Builder;
const Program = trace.Program;
const Spec = trace.Spec;

pub fn define(
    allocator: std.mem.Allocator,
    name: []const u8,
    specs: []const Spec,
    comptime body: anytype,
) !Program {
    var builder = try Builder.init(allocator, name);
    errdefer builder.deinit();
    const args = try builder.inputs(specs);
    const output = try body(&builder, args);
    return try builder.finish(&.{output});
}
