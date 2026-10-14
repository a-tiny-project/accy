const std = @import("std");
const choir = @import("../../root.zig");
const gpu = @import("../../dialects/gpu/root.zig");
const spirv = @import("spirv/root.zig");
const nvptx = @import("nvptx/root.zig");
const lowering = @import("lowering.zig");

fn loadGpuDialect(ctx: *choir.ir.Context) !void {
    try choir.ir.dialects.loadDialectSpec(ctx, gpu.GpuDialect.spec);
}

fn loadSpirvDialect(ctx: *choir.ir.Context) !void {
    try choir.ir.dialects.loadDialectSpec(ctx, spirv.SpirvDialect.spec);
}

fn loadNvptxDialect(ctx: *choir.ir.Context) !void {
    try choir.ir.dialects.loadDialectSpec(ctx, nvptx.NvptxDialect.spec);
}

pub const dialect_registrations = [_]choir.extensions.DialectRegistration{
    .{ .name = "gpu", .load = loadGpuDialect },
    .{ .name = "spirv", .load = loadSpirvDialect, .is_backend = true },
    .{ .name = "nvptx", .load = loadNvptxDialect, .is_backend = true },
};

pub const package_extension = choir.extensions.PackageExtension{
    .name = "choir-gpu",
    .dialects = &dialect_registrations,
    .passes = &lowering.pass_registrations,
    .pipelines = &lowering.pipeline_registrations,
};

pub fn registerTargetDialects(ctx: *choir.ir.Context) !void {
    for (dialect_registrations) |registration| {
        ctx.registerDialectLoader(registration.name, registration.load) catch |err| switch (err) {
            error.DuplicateDialectLoader => {},
            else => return err,
        };
        if (registration.is_backend) try ctx.registerBackendDialect(registration.name);
    }
}

/// Load the native compilation dialect closure before an owned program Context activates.
pub fn prepareCompilationDialects(ctx: *choir.ir.Context) !void {
    try choir.dialects.registerChoirDialect(ctx);
    try registerTargetDialects(ctx);
    inline for (.{ "builtin", "arith", "memref", "scf", "func" }) |name| {
        _ = try ctx.getOrLoadDialect(name);
    }
    for (dialect_registrations) |registration| _ = try ctx.getOrLoadDialect(registration.name);
}
