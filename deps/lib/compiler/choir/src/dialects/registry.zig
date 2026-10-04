const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");
const core_dialects = @import("../core/root.zig").dialects;
const interfaces = @import("../core/root.zig").interfaces;

const builtin = @import("builtin.zig");
const arith = @import("arith/root.zig");
const memref = @import("memref.zig");
const rc = @import("rc.zig");
const scf = @import("scf.zig");
const func = @import("func.zig");
const tile = @import("tile.zig");
const aarch64 = @import("aarch64.zig");

const BuiltinDialect = builtin.BuiltinDialect;
const MemrefDialect = memref.MemrefDialect;
const RcDialect = rc.RcDialect;
const ScfDialect = scf.ScfDialect;
const FuncDialect = func.FuncDialect;
const TileDialect = tile.TileDialect;
const AArch64Dialect = aarch64.AArch64Dialect;

fn loadBuiltinDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, BuiltinDialect.spec);
}

fn loadTileDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, TileDialect.spec);
}

fn loadAArch64Dialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, AArch64Dialect.spec);
}

fn loadArithDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, arith.spec);
}

fn loadMemrefDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, MemrefDialect.spec);
}

fn loadRcDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, RcDialect.spec);
}

fn loadScfDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, ScfDialect.spec);
}

fn loadFuncDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, FuncDialect.spec);
}

pub const choir_registry = core_dialects.DialectRegistrySpec{
    .entries = &[_]core_dialects.DialectRegistryEntry{
        .{ .name = "builtin", .load = loadBuiltinDialect },
        .{ .name = "tile", .load = loadTileDialect },
        .{ .name = "aarch64", .load = loadAArch64Dialect },
        .{ .name = "arith", .load = loadArithDialect },
        .{ .name = "memref", .load = loadMemrefDialect },
        .{ .name = "rc", .load = loadRcDialect },
        .{ .name = "scf", .load = loadScfDialect },
        .{ .name = "func", .load = loadFuncDialect },
    },
};

fn registerChoirDialectLoader(ctx: *ir.Context, entry: core_dialects.DialectRegistryEntry) !void {
    ctx.registerDialectLoader(entry.name, entry.load) catch |err| switch (err) {
        error.DuplicateDialectLoader => {
            const existing = ctx.dialect_registry.loaders.get(entry.name) orelse return err;
            if (existing != entry.load) return err;
        },
        else => return err,
    };
}

pub fn registerChoirDialect(ctx: *ir.Context) !void {
    inline for (choir_registry.entries) |entry| {
        try registerChoirDialectLoader(ctx, entry);
    }
}

pub fn registerAllDialects(ctx: *ir.Context) !void {
    try registerChoirDialect(ctx);
    inline for (choir_registry.entries) |entry| {
        _ = try ctx.getOrLoadDialect(entry.name);
    }
}
