const std = @import("std");
const Operation = @import("../root.zig").Operation;
const dialects = @import("../root.zig").dialects;
const freeze_ctx = @import("freeze.zig");
const memory_ctx = @import("memory.zig");
const transactions = @import("transactions.zig");

fn configurationTableAllocator(ctx: anytype) std.mem.Allocator {
    if (comptime @hasField(@TypeOf(ctx.*), "memory")) {
        return memory_ctx.segmentAllocator(ctx, .configuration_tables);
    }
    return ctx.allocator;
}

fn configurationNameAllocator(ctx: anytype) std.mem.Allocator {
    if (comptime @hasField(@TypeOf(ctx.*), "memory")) {
        return memory_ctx.segmentAllocator(ctx, .configuration_names);
    }
    return ctx.allocator;
}

fn configurationInterfaceAllocator(ctx: anytype) std.mem.Allocator {
    if (comptime @hasField(@TypeOf(ctx.*), "memory")) {
        return memory_ctx.segmentAllocator(ctx, .configuration_interfaces);
    }
    return ctx.allocator;
}

fn internDialectName(ctx: anytype, dialect_name: []const u8) ![]const u8 {
    return ctx.dialect_registry.internDialectName(
        configurationTableAllocator(ctx),
        configurationNameAllocator(ctx),
        dialect_name,
    );
}

pub fn appendDialectRegistry(
    ctx: anytype,
    registry: dialects.DialectRegistrySpec,
) @TypeOf(ctx.*).Error!void {
    try freeze_ctx.requireMutable(ctx);
    for (registry.entries) |entry| {
        try registerDialectLoader(ctx, entry.name, entry.load);
    }
}

pub fn registerDialectLoader(
    ctx: anytype,
    dialect_name: []const u8,
    loader: dialects.DialectLoaderFn,
) @TypeOf(ctx.*).Error!void {
    try freeze_ctx.requireMutable(ctx);
    const interned = try internDialectName(ctx, dialect_name);
    const gop = try ctx.dialect_registry.loaders.getOrPut(configurationTableAllocator(ctx), interned);
    gop.key_ptr.* = interned;
    if (gop.found_existing) return error.DuplicateDialectLoader;
    gop.value_ptr.* = loader;
}

pub fn registerBackendDialect(
    ctx: anytype,
    dialect_name: []const u8,
) @TypeOf(ctx.*).Error!void {
    try freeze_ctx.requireMutable(ctx);
    const interned = try internDialectName(ctx, dialect_name);
    const gop = try ctx.dialect_registry.backend_names.getOrPut(configurationTableAllocator(ctx), interned);
    gop.key_ptr.* = interned;
    if (!gop.found_existing) {
        gop.value_ptr.* = {};
    }
}

pub fn isBackendDialect(ctx: anytype, dialect_name: []const u8) bool {
    return ctx.dialect_registry.backend_names.get(dialect_name) != null;
}

pub fn addDialectExtension(
    ctx: anytype,
    dialect_name: []const u8,
    ext: dialects.DialectExtensionFn,
) anyerror!void {
    try freeze_ctx.requireMutable(ctx);

    if (ctx.dialect_registry.load_state.get(dialect_name)) |state| {
        switch (state) {
            .loaded => {
                try ext(ctx);
                return;
            },
            .loading => {
                return error.DialectLoadCycle;
            },
        }
    }

    const interned = try internDialectName(ctx, dialect_name);
    const gop = try ctx.dialect_registry.pending_extensions.getOrPut(configurationInterfaceAllocator(ctx), interned);
    gop.key_ptr.* = interned;
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(configurationInterfaceAllocator(ctx), ext);
}

pub fn getOrLoadDialect(
    ctx: anytype,
    dialect_name: []const u8,
) anyerror!*dialects.Dialect {
    if (ctx.dialect_registry.load_state.get(dialect_name)) |state| {
        switch (state) {
            .loaded => {
                return ctx.dialect_registry.loaded.get(dialect_name).?;
            },
            .loading => {
                return error.DialectLoadCycle;
            },
        }
    }

    try freeze_ctx.requireMutable(ctx);

    const loader = ctx.dialect_registry.loaders.get(dialect_name);
    if (loader == null and !ctx.dialect_registry.allow_unregistered) {
        return error.UnknownDialect;
    }

    const interned = try internDialectName(ctx, dialect_name);

    const txn_index = try transactions.begin(ctx, interned);
    errdefer transactions.rollback(ctx, txn_index);

    const load_gop = try ctx.dialect_registry.load_state.getOrPut(configurationTableAllocator(ctx), interned);
    load_gop.key_ptr.* = interned;
    load_gop.value_ptr.* = .loading;

    const dialect_result = try getOrCreateDialectObject(ctx, interned);
    if (dialect_result.created) {
        transactions.markDialectObjectCreated(ctx, interned);
    }

    if (loader) |load_fn| {
        try load_fn(ctx);
    }

    if (ctx.dialect_registry.pending_extensions.get(interned)) |ext_list| {
        for (ext_list.items) |ext_fn| {
            try ext_fn(ctx);
        }
        var ext_list_mut = ctx.dialect_registry.pending_extensions.fetchRemove(interned).?.value;
        ext_list_mut.deinit(configurationInterfaceAllocator(ctx));
    }

    const loaded_gop = try ctx.dialect_registry.load_state.getOrPut(configurationTableAllocator(ctx), interned);
    loaded_gop.key_ptr.* = interned;
    loaded_gop.value_ptr.* = .loaded;

    transactions.commit(ctx, txn_index);
    return dialect_result.dialect;
}

pub fn isDialectLoaded(ctx: anytype, dialect_name: []const u8) bool {
    return ctx.dialect_registry.loaded.get(dialect_name) != null;
}

pub fn getDialect(ctx: anytype, name: []const u8) ?*dialects.Dialect {
    return ctx.dialect_registry.loaded.get(name);
}

pub fn ensureDialectForOperation(
    ctx: anytype,
    op_name: []const u8,
) anyerror!void {
    const op_name_struct = Operation.OperationName.init(op_name);
    const ns = op_name_struct.getDialectNamespace();
    if (ns.len == 0) return;
    _ = try getOrLoadDialect(ctx, ns);
}

const DialectCreateResult = struct {
    dialect: *dialects.Dialect,
    created: bool,
};

fn getOrCreateDialectObject(
    ctx: anytype,
    dialect_name: []const u8,
) !DialectCreateResult {
    if (ctx.dialect_registry.loaded.get(dialect_name)) |dialect| {
        return .{ .dialect = dialect, .created = false };
    }

    const interned = try internDialectName(ctx, dialect_name);
    const dialect = try configurationTableAllocator(ctx).create(dialects.Dialect);
    errdefer configurationTableAllocator(ctx).destroy(dialect);
    dialect.* = dialects.Dialect.init(interned, ctx);
    const gop = try ctx.dialect_registry.loaded.getOrPut(interned);
    gop.key_ptr.* = interned;
    gop.value_ptr.* = dialect;
    return .{ .dialect = dialect, .created = true };
}

const FakeContext = struct {
    allocator: std.mem.Allocator,
    dialect_registry: dialects.DialectRegistry,
    freeze_policy: freeze_ctx.Policy = freeze_ctx.Policy.init(),
    multithreaded: bool = false,

    pub const Error = error{
        ContextFrozen,
        ContextMutationDuringMultithreadedExecution,
    } || std.mem.Allocator.Error;

    fn init(allocator: std.mem.Allocator) FakeContext {
        return .{
            .allocator = allocator,
            .dialect_registry = dialects.DialectRegistry.init(allocator, allocator),
        };
    }

    fn deinit(self: *FakeContext) void {
        self.dialect_registry.deinit(self.allocator, self.allocator, self.allocator);
    }

    pub fn isMultithreadedExecution(self: *const FakeContext) bool {
        return self.multithreaded;
    }
};
