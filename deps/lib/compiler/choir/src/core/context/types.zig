const std = @import("std");
const alloc_phase = @import("alloc_phase");
const alloc_observe = @import("alloc_observe");
const interfaces = @import("../root.zig").interfaces;
const Operation = @import("../root.zig").Operation;
const Type = @import("../root.zig").Type;
const types = @import("../root.zig").types;
const dialect_ctx = @import("dialects.zig");
const freeze_ctx = @import("freeze.zig");
const memory_ctx = @import("memory.zig");
const transactions = @import("transactions.zig");

pub fn getTypeRegistry(ctx: anytype) *interfaces.TypeRegistry {
    return &ctx.type_interner.registry;
}

pub fn lookupType(ctx: anytype, type_name: []const u8) ?*interfaces.TypeInfo {
    return ctx.type_interner.registry.lookup(type_name);
}

pub fn registerType(
    ctx: anytype,
    type_name: []const u8,
) (@TypeOf(ctx.*).Error || interfaces.TypeRegistry.GetOrCreateError || interfaces.TypeRegistry.RegisterInterfaceError)!*interfaces.TypeInfo {
    try freeze_ctx.requireMutable(ctx);
    const type_result = try ctx.type_interner.registry.getOrCreateTracked(type_name);
    try transactions.recordCreatedType(ctx, type_name, type_result.created);
    return type_result.info;
}

pub fn registerTypeBatch(
    ctx: anytype,
    type_specs: anytype,
) (@TypeOf(ctx.*).Error || interfaces.TypeRegistry.GetOrCreateError)!void {
    try freeze_ctx.requireMutable(ctx);
    for (type_specs) |typ| {
        try transactions.recordCreatedType(
            ctx,
            typ.name,
            ctx.type_interner.registry.lookup(typ.name) == null,
        );
    }
    try ctx.type_interner.registry.getOrCreateNamedBatch(type_specs);
}

pub fn registerTypeInterface(
    ctx: anytype,
    type_name: []const u8,
    entry: interfaces.InterfaceEntry,
) (@TypeOf(ctx.*).Error || interfaces.TypeRegistry.GetOrCreateError || interfaces.TypeRegistry.RegisterInterfaceError)!void {
    try freeze_ctx.requireMutable(ctx);
    const type_result = try ctx.type_interner.registry.getOrCreateTracked(type_name);
    try transactions.recordCreatedType(ctx, type_name, type_result.created);
    try type_result.info.addInterface(memory_ctx.segmentAllocator(ctx, .type_keys), entry);
    applyTypeInterfaceUpdate(ctx, type_name, entry);
}

pub fn registerTypeInterfaceExternal(
    ctx: anytype,
    type_name: []const u8,
    entry: interfaces.InterfaceEntry,
) (@TypeOf(ctx.*).Error || interfaces.TypeRegistry.GetOrCreateError || interfaces.TypeRegistry.RegisterInterfaceError)!void {
    try freeze_ctx.requireMutable(ctx);
    const type_result = try ctx.type_interner.registry.getOrCreateTracked(type_name);
    try transactions.recordCreatedType(ctx, type_name, type_result.created);
    try type_result.info.addOrReplaceInterface(memory_ctx.segmentAllocator(ctx, .type_keys), entry);
    applyTypeInterfaceUpdate(ctx, type_name, entry);
}

fn applyTypeInterfaceUpdate(
    ctx: anytype,
    type_name: []const u8,
    entry: interfaces.InterfaceEntry,
) void {
    if (entry.id != interfaces.TypePrintInterface.id) return;
    const vtable: *const interfaces.TypePrintInterface.VTable = @ptrCast(@alignCast(entry.vtable));

    var iter = ctx.type_interner.storage.dialect_types.valueIterator();
    while (iter.next()) |typ| {
        if (typ.getDialectStorage()) |storage| {
            if (!std.mem.eql(u8, storage.name, type_name)) continue;
            const mutable_storage: *Type.DialectTypeStorage = @ptrCast(@alignCast(@constCast(typ.impl)));
            mutable_storage.print_fn = vtable.print;
        }
    }
}

pub fn TypeInterfaceHandle(comptime ContextT: type, comptime IFace: type) type {
    return struct {
        ctx: *ContextT,
        typ: Type,
        vtable: *const IFace.VTable,

        fn returnType(comptime fn_ptr_type: type) type {
            const ptr_info = @typeInfo(fn_ptr_type);
            const fn_type = switch (ptr_info) {
                .pointer => |p| p.child,
                else => @compileError("expected interface vtable field to be a function pointer"),
            };
            const fn_info = switch (@typeInfo(fn_type)) {
                .@"fn" => |f| f,
                else => @compileError("expected interface vtable field to be a function pointer"),
            };
            return fn_info.return_type orelse @compileError("generic interface vtable methods are not supported");
        }

        fn methodFnPtrType(comptime method: std.meta.FieldEnum(IFace.VTable)) type {
            const dummy: IFace.VTable = undefined;
            return @TypeOf(@field(dummy, @tagName(method)));
        }

        fn wantsContext(comptime fn_ptr_type: type) bool {
            const ptr_info = @typeInfo(fn_ptr_type);
            const fn_type = switch (ptr_info) {
                .pointer => |p| p.child,
                else => @compileError("expected interface vtable field to be a function pointer"),
            };
            const fn_info = switch (@typeInfo(fn_type)) {
                .@"fn" => |f| f,
                else => @compileError("expected interface vtable field to be a function pointer"),
            };
            if (fn_info.param_types.len < 2) return false;
            const param_ty = fn_info.param_types[1] orelse return false;
            return param_ty == *interfaces.ContextOpaque or param_ty == *const interfaces.ContextOpaque;
        }

        pub inline fn call(
            self: @This(),
            comptime method: std.meta.FieldEnum(IFace.VTable),
            args: anytype,
        ) returnType(methodFnPtrType(method)) {
            const fn_ptr = @field(self.vtable, @tagName(method));
            if (comptime wantsContext(@TypeOf(fn_ptr))) {
                const ctx_opaque: *interfaces.ContextOpaque = @ptrCast(self.ctx);
                return @call(.auto, fn_ptr, .{ self.typ.impl, ctx_opaque } ++ args);
            }
            return @call(.auto, fn_ptr, .{self.typ.impl} ++ args);
        }
    };
}

pub fn typeInterface(
    ctx: anytype,
    typ: Type,
    comptime IFace: type,
) ?TypeInterfaceHandle(@TypeOf(ctx.*), IFace) {
    const vtable = getTypeInterface(ctx, typ, IFace) orelse return null;
    return .{ .ctx = ctx, .typ = typ, .vtable = vtable };
}

pub fn getTypeInterface(
    ctx: anytype,
    typ: Type,
    comptime IFace: type,
) ?*const IFace.VTable {
    if (typ.getDialectStorage()) |storage| {
        const info_any = storage.type_info orelse return null;
        const info: *const interfaces.TypeInfo = @ptrCast(@alignCast(info_any));
        if (info.getInterface(IFace.id)) |vt_any| {
            return @ptrCast(@alignCast(vt_any));
        }

        const fallbacks = ctx.dialect_registry.type_interface_fallbacks.lookup(IFace.id) orelse return null;
        const ns = typeDialectNamespace(storage.name);
        if (ns.len > 0) {
            if (fallbacks.get(ns)) |fallback| {
                if (fallback(ctx, typ)) |vt_any| {
                    return @ptrCast(@alignCast(vt_any));
                }
            }
        }
        return null;
    }
    return null;
}

pub fn getTypeParamPayloadRaw(
    ctx: anytype,
    typ: Type,
) anyerror!?interfaces.TypeParamPayload {
    if (!typ.isDialectType()) return null;

    const type_id = typ.uniqueId();
    if (ctx.type_param_cache.get(type_id)) |cached| {
        return cached;
    }

    const iface = getTypeInterface(ctx, typ, interfaces.TypeParamInterface) orelse return null;
    try freeze_ctx.requireSingleThreadedMutation(ctx);

    const ctx_opaque: *const interfaces.ContextOpaque = @ptrCast(ctx);
    const payload = try iface.parse(typ.impl, ctx_opaque) orelse return null;
    errdefer payload.deinit(memory_ctx.segmentAllocator(ctx, .type_payloads), payload.ptr);

    try ctx.type_param_cache.put(memory_ctx.segmentAllocator(ctx, .type_tables), type_id, payload);
    return payload;
}

pub fn getTypeParamPayload(
    ctx: anytype,
    typ: Type,
    comptime PayloadT: type,
) anyerror!?*const PayloadT {
    const payload = try getTypeParamPayloadRaw(ctx, typ) orelse return null;
    return @ptrCast(@alignCast(payload.ptr));
}

pub fn getDialectType(
    ctx: anytype,
    dialect: []const u8,
    type_name: []const u8,
) !Type {
    return getDialectTypeWithKey(ctx, dialect, type_name, "");
}

pub fn getDialectTypeWithKey(
    ctx: anytype,
    dialect: []const u8,
    type_name: []const u8,
    param_key: []const u8,
) !Type {
    const full_name = try std.fmt.allocPrint(memory_ctx.segmentAllocator(ctx, .transient), "{s}.{s}", .{ dialect, type_name });
    defer memory_ctx.segmentAllocator(ctx, .transient).free(full_name);
    return getDialectTypeFromNameWithKey(ctx, full_name, param_key);
}

pub fn getDialectTypeFromName(ctx: anytype, full_name: []const u8) !Type {
    return getDialectTypeFromNameWithKey(ctx, full_name, "");
}

pub fn getDialectTypeFromNameWithKey(
    ctx: anytype,
    full_name: []const u8,
    param_key: []const u8,
) !Type {
    const ns = typeDialectNamespace(full_name);
    if (ns.len > 0) {
        if (ctx.dialect_registry.load_state.get(ns)) |state| {
            if (state == .loaded) {
                _ = try dialect_ctx.getOrLoadDialect(ctx, ns);
            }
        } else {
            _ = try dialect_ctx.getOrLoadDialect(ctx, ns);
        }
    }

    const lookup_key = types.TypeStorage.DialectTypeKey{
        .name = full_name,
        .param_key = param_key,
    };
    if (ctx.type_interner.storage.dialect_types.get(lookup_key)) |t| {
        return t;
    }

    const info = ctx.type_interner.registry.lookup(full_name) orelse blk: {
        if (!ctx.type_interner.registry.allow_unregistered_types) return error.UnknownType;
        try freeze_ctx.requireMutable(ctx);
        break :blk try ctx.type_interner.registry.registerType(full_name);
    };

    try freeze_ctx.requireSingleThreadedMutation(ctx);

    const stored_param_key = if (param_key.len > 0)
        try memory_ctx.segmentAllocator(ctx, .type_keys).dupe(u8, param_key)
    else
        "";
    errdefer if (stored_param_key.len > 0) memory_ctx.segmentAllocator(ctx, .type_keys).free(stored_param_key);

    const print_fn = if (info.getInterface(interfaces.TypePrintInterface.id)) |vt_any|
        @as(*const interfaces.TypePrintInterface.VTable, @ptrCast(@alignCast(vt_any))).print
    else
        null;

    const type_id = ctx.type_interner.storage.allocateTypeId();

    const storage = try memory_ctx.segmentAllocator(ctx, .type_payloads).create(Type.DialectTypeStorage);
    errdefer memory_ctx.segmentAllocator(ctx, .type_payloads).destroy(storage);
    storage.* = .{
        .name = info.name,
        .param_key = stored_param_key,
        .type_info = @ptrCast(info),
        .print_fn = print_fn,
        .unique_id = type_id,
    };

    const t = Type{
        .type_id = .dialect_type,
        .impl = storage,
    };

    const insert_key = types.TypeStorage.DialectTypeKey{
        .name = info.name,
        .param_key = storage.param_key,
    };
    try ctx.type_interner.storage.dialect_types.put(memory_ctx.segmentAllocator(ctx, .type_tables), insert_key, t);
    return t;
}

fn typeDialectNamespace(type_name: []const u8) []const u8 {
    const op_name = Operation.OperationName.init(type_name);
    const ns = op_name.getDialectNamespace();
    return if (ns.len > 0) ns else type_name;
}
