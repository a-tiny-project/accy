//! Parses textual gpu dialect kernels for the emitter tests.

const std = @import("std");
const choir = @import("../../../root.zig");
const backends_gpu = @import("../root.zig");

const lowering = backends_gpu.lowering;
const registration = backends_gpu.registration;

const ir = choir.ir;
const testing = std.testing;

/// Parses `source` into a verified module and checks that it prints back
/// byte for byte, so each fixture also witnesses the gpu dialect round trip.
pub fn parse(ctx: *ir.Context, source: []const u8) !*ir.Operation {
    std.debug.assert(source.len > 0);
    const module = try ir.parse.operation(ctx, source);
    errdefer module.erase();
    try ir.verifyOperation(module, .{});
    const printed = try ir.dump.operationAlloc(testing.allocator, module);
    defer testing.allocator.free(printed);
    try testing.expectEqualStrings(source, printed);
    return module;
}

/// Parses `source` and runs the target lowering pipeline when one is named.
/// `ctx` must already hold the compilation dialects.
pub fn lower(
    ctx: *ir.Context,
    source: []const u8,
    target: ?lowering.TargetLowering,
) !*ir.Operation {
    const module = try parse(ctx, source);
    errdefer module.erase();
    if (target) |target_lowering| {
        var pm = choir.passes.PassManager.init(testing.allocator);
        defer pm.deinit();
        pm.enableVerifier();
        try lowering.addTargetLoweringPipeline(&pm, target_lowering);
        try testing.expectEqual(choir.passes.PassResult.success, pm.run(module, ctx));
    }
    return module;
}

/// Parses and lowers `source`, then returns the text that `emit` produces for
/// `entry_name`.
pub fn emitText(
    source: []const u8,
    entry_name: []const u8,
    target: ?lowering.TargetLowering,
    comptime emit: anytype,
) ![]u8 {
    std.debug.assert(entry_name.len > 0);
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try registration.prepareCompilationDialects(&ctx);
    const module = try lower(&ctx, source, target);
    defer module.erase();
    return emit(testing.allocator, entry_name, module);
}

pub fn expectContains(text: []const u8, needle: []const u8) !void {
    std.debug.assert(needle.len > 0);
    if (std.mem.indexOf(u8, text, needle) == null) return error.TestExpectedContains;
}

pub fn expectAbsent(text: []const u8, needle: []const u8) !void {
    std.debug.assert(needle.len > 0);
    if (std.mem.indexOf(u8, text, needle) != null) return error.TestUnexpectedContains;
}
