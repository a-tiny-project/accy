const interfaces = @import("../root.zig").interfaces;
const dialects = @import("../root.zig").dialects;
const Operation = @import("../root.zig").Operation;
const Type = @import("../root.zig").Type;
const freeze_ctx = @import("freeze.zig");
const memory_ctx = @import("memory.zig");

const TestFallbackOpVTable = struct {
    marker: u8,
};

const TestFallbackOpInterface = struct {
    pub const id = interfaces.interfaceId("fallback.interface");
    pub const VTable: type = TestFallbackOpVTable;
};

const TestFallbackOpVTableStorage = struct {
    var table: TestFallbackOpInterface.VTable = .{ .marker = 7 };
};

const TestFallbackTypeVTable = struct {
    getMarker: *const fn (type_ptr: *const anyopaque) u8,
};

const TestFallbackTypeInterface = struct {
    pub const id = interfaces.interfaceId("fallback.type_interface");
    pub const VTable: type = TestFallbackTypeVTable;
};

const TestFallbackTypeVTableStorage = struct {
    var table: TestFallbackTypeInterface.VTable = .{ .getMarker = get_marker };

    fn get_marker(_: *const anyopaque) u8 {
        return 9;
    }
};

fn test_translation_noop(
    _: *const anyopaque,
    _: *const anyopaque,
) interfaces.TranslationDialectInterface.TranslationError!void {}

fn test_fallback_op_interface(_: *const Operation) ?*const anyopaque {
    return @ptrCast(&TestFallbackOpVTableStorage.table);
}

fn test_fallback_type_interface(_: *const @import("root.zig").Context, _: Type) ?*const anyopaque {
    return @ptrCast(&TestFallbackTypeVTableStorage.table);
}

pub fn registerDialectInterface(
    ctx: anytype,
    dialect_name: []const u8,
    entry: interfaces.InterfaceEntry,
) @TypeOf(ctx.*).Error!void {
    try freeze_ctx.requireMutable(ctx);
    if (entry.id == interfaces.TranslationDialectInterface.id and !ctx.isBackendDialect(dialect_name)) {
        return error.BackendDialectRequired;
    }

    const interned = try ctx.dialect_registry.internDialectName(
        memory_ctx.segmentAllocator(ctx, .configuration_tables),
        memory_ctx.segmentAllocator(ctx, .configuration_names),
        dialect_name,
    );
    const gop = try ctx.dialect_registry.interfaces.getOrPut(memory_ctx.segmentAllocator(ctx, .configuration_interfaces), interned);
    gop.key_ptr.* = interned;
    if (!gop.found_existing) {
        gop.value_ptr.* = .empty;
    }

    for (gop.value_ptr.items) |existing| {
        if (existing.id == entry.id) {
            return error.DuplicateInterface;
        }
    }

    try gop.value_ptr.append(memory_ctx.segmentAllocator(ctx, .configuration_interfaces), entry);
}

pub fn getDialectInterface(
    ctx: anytype,
    dialect_name: []const u8,
    id: interfaces.InterfaceId,
) ?*const anyopaque {
    const iface_list = ctx.dialect_registry.interfaces.get(dialect_name) orelse return null;
    for (iface_list.items) |entry| {
        if (entry.id == id) {
            return entry.vtable;
        }
    }
    return null;
}

pub fn registerDialectOpInterfaceFallback(
    ctx: anytype,
    dialect_name: []const u8,
    id: interfaces.InterfaceId,
    fallback: dialects.OpInterfaceFallbackFn,
) @TypeOf(ctx.*).Error!void {
    try freeze_ctx.requireMutable(ctx);

    const interned = try ctx.dialect_registry.internDialectName(
        memory_ctx.segmentAllocator(ctx, .configuration_tables),
        memory_ctx.segmentAllocator(ctx, .configuration_names),
        dialect_name,
    );
    try ctx.dialect_registry.op_interface_fallbacks.register(memory_ctx.segmentAllocator(ctx, .configuration_interfaces), interned, id, fallback);
}

pub fn getDialectOpInterfaceFallback(
    ctx: anytype,
    dialect_name: []const u8,
    id: interfaces.InterfaceId,
) ?dialects.OpInterfaceFallbackFn {
    return ctx.dialect_registry.op_interface_fallbacks.get(dialect_name, id);
}

pub fn registerDialectTypeInterfaceFallback(
    ctx: anytype,
    dialect_name: []const u8,
    id: interfaces.InterfaceId,
    fallback: dialects.TypeInterfaceFallbackFn,
) @TypeOf(ctx.*).Error!void {
    try freeze_ctx.requireMutable(ctx);

    const interned = try ctx.dialect_registry.internDialectName(
        memory_ctx.segmentAllocator(ctx, .configuration_tables),
        memory_ctx.segmentAllocator(ctx, .configuration_names),
        dialect_name,
    );
    try ctx.dialect_registry.type_interface_fallbacks.register(memory_ctx.segmentAllocator(ctx, .configuration_interfaces), interned, id, fallback);
}

pub fn getDialectTypeInterfaceFallback(
    ctx: anytype,
    dialect_name: []const u8,
    id: interfaces.InterfaceId,
) ?dialects.TypeInterfaceFallbackFn {
    return ctx.dialect_registry.type_interface_fallbacks.get(dialect_name, id);
}
