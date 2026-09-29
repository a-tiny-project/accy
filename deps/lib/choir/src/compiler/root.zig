const std = @import("std");
const choir = @import("../root.zig");
const ir = choir.ir;
const dialects = choir.dialects;
const extensions = choir.extensions;

pub const default_compiler_dialects = [_][]const u8{
    "builtin",
    "arith",
    "memref",
    "scf",
    "func",
};

pub const ContextOptions = struct {
    context_limits: ir.Context.Limits,
    packages: []const extensions.PackageExtension = &.{},
    preload_dialects: []const []const u8 = &default_compiler_dialects,
    preload_all_choir_dialects: bool = false,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    ctx: ir.Context,
    extension_registry: extensions.ExtensionRegistry,
    live: bool = true,

    pub fn init(allocator: std.mem.Allocator, options: ContextOptions) !Session {
        var ctx = try ir.Context.init(allocator, options.context_limits);
        errdefer ctx.deinit(allocator);

        try registerCoreDialects(&ctx);

        var extension_registry = extensions.ExtensionRegistry.init(allocator);
        errdefer extension_registry.deinit();
        for (options.packages) |package| {
            try extension_registry.registerPackage(&ctx, package);
        }
        try preloadRequestedDialects(&ctx, options);

        return .{
            .allocator = allocator,
            .ctx = ctx,
            .extension_registry = extension_registry,
        };
    }

    pub fn deinit(self: *Session) void {
        if (!self.live) return;
        self.extension_registry.deinit();
        self.ctx.deinit(self.allocator);
        self.live = false;
    }

    pub fn context(self: *Session) *ir.Context {
        return &self.ctx;
    }

    pub fn extensionRegistry(self: *Session) *extensions.ExtensionRegistry {
        return &self.extension_registry;
    }
};

pub fn initContext(allocator: std.mem.Allocator, options: ContextOptions) !ir.Context {
    var ctx = try ir.Context.init(allocator, options.context_limits);
    errdefer ctx.deinit(allocator);

    try registerCoreDialects(&ctx);
    for (options.packages) |package| {
        try package.registerContext(&ctx);
    }
    try preloadRequestedDialects(&ctx, options);

    return ctx;
}

fn registerCoreDialects(ctx: *ir.Context) !void {
    try ctx.requireRegistered();
    try dialects.registerChoirDialect(ctx);
}

fn preloadRequestedDialects(ctx: *ir.Context, options: ContextOptions) !void {
    if (options.preload_all_choir_dialects) {
        inline for (dialects.choir_registry.entries) |entry| {
            _ = try ctx.getOrLoadDialect(entry.name);
        }
    }

    for (options.preload_dialects) |name| {
        _ = try ctx.getOrLoadDialect(name);
    }
}
