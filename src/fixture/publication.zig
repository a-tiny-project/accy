const std = @import("std");
const choir = @import("choir");
const accy = @import("../choir/root.zig");
const executable = @import("../executable/root.zig");
const revision = choir.product.revision;
const operation = choir.product.operation;

pub const configuration = operation.Configuration{
    .context = choir.ir.Context.Limits.testing,
    .register = registerContext,
    .registration = .{ .name = "composition-test-context", .version = 1 },
    .codec = .{ .operations = 1000, .entities = 10000, .fields = 10000, .depth = 64 },
    .image = .{ .bytes = 1024 * 1024, .entities = 10000, .depth = 64 },
    .roots = 1,
    .gate_scratch = 64 * 1024 * 1024,
    .verify = choir.ir.verify.default_options,
};

pub const artifact_workspace_bytes = 256 * 1024 * 1024;

fn registerContext(context: *choir.ir.Context) !void {
    try choir.dialects.registerChoirDialect(context);
    try accy.registerAccyDialect(context);
    try choir.backends.gpu.registerTargetDialects(context);
}

pub fn request(source: []const u8, workspace: []u8) executable.FragmentCompilationRequest {
    return .{
        .source = source,
        .work = .{
            .allowance = revision.WorkVector.uniform(std.math.maxInt(u64)),
            .workspace = 512 * 1024 * 1024,
            .events = 256,
        },
        .record_bytes = 32 * 1024 * 1024,
        .artifact_workspace = workspace,
    };
}
