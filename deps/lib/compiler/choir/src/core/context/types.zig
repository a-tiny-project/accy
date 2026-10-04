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

test "Context type store cleanup" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.getDialectTypeFromName("test.ty");
    _ = try ctx.getDialectTypeFromNameWithKey("test.ty", "key1");
    _ = try ctx.getDialectTypeFromNameWithKey("test.ty", "key2");
    _ = try ctx.getDialectTypeFromName("test.other");
}

test "Context dialect type construction cleans every allocation failure" {
    const Context = @import("root.zig").Context;
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var ctx = try Context.init(allocator, Context.Limits.testing);
            defer ctx.deinit(allocator);
            try ctx.allowUnregistered();
            _ = try ctx.getDialectTypeFromNameWithKey("allocation.type", "parameter");
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "Context type registry integration" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    try testing.expectEqual(@as(?*interfaces.TypeInfo, null), ctx.lookupType("test.ty"));

    const info = try ctx.registerType("test.ty");
    try testing.expectEqualStrings("test.ty", info.name);

    const Print = struct {
        fn print(_: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("test");
        }
    };
    const vtable = interfaces.TypePrintInterface.vtableFor(Print.print);
    try ctx.registerTypeInterface("test.ty", interfaces.TypePrintInterface.entry(vtable));

    const ty = try ctx.getDialectTypeFromName("test.ty");
    try testing.expect(ty.isDialectType());
    try testing.expectEqualStrings("test.ty", ty.getDialectTypeName().?);

    const iface = ctx.getTypeInterface(ty, interfaces.TypePrintInterface);
    try testing.expect(iface != null);
    try testing.expectEqual(vtable, iface.?);

    const ty2 = try ctx.getDialectTypeFromName("test.ty");
    try testing.expectEqual(ty.impl, ty2.impl);

    const keyed = try ctx.getDialectTypeFromNameWithKey("test.ty", "keyed");
    try testing.expectEqualStrings("test.ty", keyed.getDialectTypeName().?);
    try testing.expectEqualStrings("keyed", keyed.getDialectParamKey().?);

    const keyed2 = try ctx.getDialectTypeFromNameWithKey("test.ty", "keyed");
    try testing.expectEqual(keyed.impl, keyed2.impl);

    const keyed_other = try ctx.getDialectTypeFromNameWithKey("test.ty", "other");
    try testing.expect(keyed.impl != keyed_other.impl);
}

test "Context type interface updates existing type storage" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const ty = try ctx.getDialectTypeFromName("test.ty");

    const Print = struct {
        fn print(_: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("test");
        }
    };
    const vtable = interfaces.TypePrintInterface.vtableFor(Print.print);
    try ctx.registerTypeInterface("test.ty", interfaces.TypePrintInterface.entry(vtable));

    const iface = ctx.getTypeInterface(ty, interfaces.TypePrintInterface);
    try testing.expect(iface != null);
    try testing.expectEqual(vtable, iface.?);
}

test "Context caches and deinitializes type parameter payloads" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var gpa = alloc_observe.debug.Allocator(.{}).init(testing.allocator);
    defer {
        const status = gpa.deinit();
        testing.expect(status == .ok) catch @panic("type param cache leaked allocations");
    }

    var ctx = try Context.init(gpa.allocator(), Context.Limits.testing);
    defer ctx.deinit(gpa.allocator());
    try ctx.allowUnregistered();

    const Payload = struct {
        value: u64,
    };

    const Helpers = struct {
        fn deinitPayload(allocator: std.mem.Allocator, ptr: *anyopaque) void {
            const payload: *Payload = @ptrCast(@alignCast(ptr));
            allocator.destroy(payload);
        }

        fn parsePayload(type_ptr: *const anyopaque, ctx_opaque: *const interfaces.ContextOpaque) anyerror!?interfaces.TypeParamPayload {
            const context = interfaces.castContext(Context, @constCast(ctx_opaque));
            const storage: *const Type.DialectTypeStorage = @ptrCast(@alignCast(type_ptr));
            if (storage.param_key.len == 0) return null;

            const parsed = std.fmt.parseInt(u64, storage.param_key, 10) catch return null;
            const payload = try memory_ctx.segmentAllocator(context, .type_payloads).create(Payload);
            payload.* = .{ .value = parsed };
            return .{ .ptr = payload, .deinit = deinitPayload };
        }
    };

    _ = try ctx.registerType("test.param");
    const param_vtable = interfaces.TypeParamInterface.vtableFor(Helpers.parsePayload);
    try ctx.registerTypeInterface("test.param", interfaces.TypeParamInterface.entry(param_vtable));

    const typ = try ctx.getDialectTypeFromNameWithKey("test.param", "42");
    const payload1 = (try ctx.getTypeParamPayload(typ, Payload)).?;
    const payload2 = (try ctx.getTypeParamPayload(typ, Payload)).?;

    try testing.expectEqual(@as(u64, 42), payload1.value);
    try testing.expect(payload1 == payload2);
}

test "lazy type payload caching rolls back on named table exhaustion" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Context, "choir_context_lazy_param_exhaustion"),
        );
    }

    const testing = std.testing;
    const Context = @import("root.zig").Context;
    const Payload = struct {
        value: u64,
    };
    const Helpers = struct {
        fn deinitPayload(allocator: std.mem.Allocator, ptr: *anyopaque) void {
            const payload: *Payload = @ptrCast(@alignCast(ptr));
            allocator.destroy(payload);
        }

        fn parsePayload(
            type_ptr: *const anyopaque,
            ctx_opaque: *const interfaces.ContextOpaque,
        ) anyerror!?interfaces.TypeParamPayload {
            const context = interfaces.castContext(Context, @constCast(ctx_opaque));
            const storage: *const Type.DialectTypeStorage = @ptrCast(@alignCast(type_ptr));
            const payload = try memory_ctx.segmentAllocator(context, .type_payloads).create(Payload);
            payload.* = .{ .value = try std.fmt.parseInt(u64, storage.param_key, 10) };
            return .{ .ptr = payload, .deinit = deinitPayload };
        }

        fn prepare(ctx: *Context) !Type {
            try ctx.allowUnregistered();
            _ = try ctx.registerType("test.bounded_param");
            const vtable = interfaces.TypeParamInterface.vtableFor(parsePayload);
            try ctx.registerTypeInterface(
                "test.bounded_param",
                interfaces.TypeParamInterface.entry(vtable),
            );
            return try ctx.getDialectTypeFromNameWithKey("test.bounded_param", "7");
        }
    };

    var table_frontier: usize = undefined;
    var table_delta: usize = undefined;
    {
        var probe = try Context.init(testing.allocator, Context.Limits.testing);
        defer probe.deinit(testing.allocator);
        const probe_type = try Helpers.prepare(&probe);
        table_frontier = probe.capacityUsage().type_tables.frontier_bytes;
        _ = (try probe.getTypeParamPayload(probe_type, Payload)).?;
        table_delta = probe.capacityUsage().type_tables.frontier_bytes - table_frontier;
        try testing.expect(table_delta > 0);
    }

    var limits = Context.Limits.testing;
    limits.types.table_bytes = table_frontier + table_delta - 1;
    var context = try Context.init(testing.allocator, limits);
    defer context.deinit(testing.allocator);
    const typ = try Helpers.prepare(&context);
    try testing.expectEqual(
        table_frontier,
        context.capacityUsage().type_tables.frontier_bytes,
    );
    context.activate();

    const payload_frontier = context.capacityUsage().type_payloads.frontier_bytes;
    try testing.expectError(
        error.OutOfMemory,
        context.getTypeParamPayload(typ, Payload),
    );
    try testing.expectEqual(
        payload_frontier,
        context.capacityUsage().type_payloads.frontier_bytes,
    );
    try testing.expect(context.type_param_cache.get(typ.uniqueId()) == null);
    try testing.expectEqual(
        Context.Segment.type_tables,
        context.exhaustedSegment().?,
    );
}
