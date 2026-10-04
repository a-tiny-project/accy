const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");
const interfaces = @import("../core/root.zig").interfaces;

pub const type_names = struct {
    pub const tile = "tile";
    pub const barrier = "tile.barrier";
};

pub const TileMemLevel = enum {
    register,
    shared,
    global,

    pub fn toString(self: TileMemLevel) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?TileMemLevel {
        inline for (@typeInfo(TileMemLevel).@"enum".field_names, std.meta.tags(TileMemLevel)) |field_name, value| {
            if (std.mem.eql(u8, s, field_name)) return value;
        }
        return null;
    }
};

pub const TileDialect = struct {
    pub const name = type_names.tile;
    const op_specs = ir.dialects.opSpec.dialect(@This());

    pub const spec = ir.dialects.dialectSpec(@This(), .{
        .types = ir.dialects.typeNames(type_specs),
    });

    const type_specs = struct {
        pub const tile = ir.dialects.TypeSpec{
            .name = type_names.tile,
            .interfaces = &.{
                interfaces.TypeParamInterface.entry(&tile_type_param_vtable),
            },
        };
        pub const barrier = type_names.barrier;
    };

    pub const TileTypePayload = struct {
        element_type_name: []const u8,
        element_type: ?ir.Type,
        mem_level: TileMemLevel,
        shape: []u32,
    };

    const tile_type_param_vtable = interfaces.TypeParamInterface.VTable{
        .parse = parseTileTypeParams,
    };

    pub const LoadOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "load",
            .operands = 2,
            .results = 1,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            buffer: *ir.Value,
            coord: *ir.Value,
            result_type: ir.Type,
        ) !LoadOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ buffer, coord });
            state.addTypes(&.{result_type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const LoadOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getBuffer(self: LoadOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getCoord(self: LoadOp) *ir.Value {
            return self.op.operands.items[1].value;
        }
    };

    pub const StoreOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "store",
            .operands = 3,
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            tile: *ir.Value,
            buffer: *ir.Value,
            coord: *ir.Value,
        ) !StoreOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ tile, buffer, coord });
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getTile(self: StoreOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getBuffer(self: StoreOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getCoord(self: StoreOp) *ir.Value {
            return self.op.operands.items[2].value;
        }
    };

    pub const MmaOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "mma",
            .operands = 3,
            .results = 1,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            a: *ir.Value,
            b: *ir.Value,
            c: *ir.Value,
            result_type: ir.Type,
        ) !MmaOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ a, b, c });
            state.addTypes(&.{result_type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const MmaOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getA(self: MmaOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getB(self: MmaOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getC(self: MmaOp) *ir.Value {
            return self.op.operands.items[2].value;
        }
    };

    pub const CopyOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "copy",
            .operands = 2,
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            src: *ir.Value,
            dst: *ir.Value,
        ) !CopyOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ src, dst });
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getSrc(self: CopyOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getDst(self: CopyOp) *ir.Value {
            return self.op.operands.items[1].value;
        }
    };

    pub const BarrierOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "barrier",
            .operands = 0,
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !BarrierOp {
            var builder = ir.OperationBuilder.init(ctx);
            const state = op_specs.state(@This(), loc);
            const op = try builder.create(state);
            return .{ .op = op };
        }
    };

    pub const ArriveOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "arrive",
            .operands = 1,
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, barrier: *ir.Value) !ArriveOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{barrier});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getBarrier(self: ArriveOp) *ir.Value {
            return self.op.operands.items[0].value;
        }
    };

    pub const WaitOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "wait",
            .operands = 2,
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, barrier: *ir.Value, phase: *ir.Value) !WaitOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ barrier, phase });
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getBarrier(self: WaitOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getPhase(self: WaitOp) *ir.Value {
            return self.op.operands.items[1].value;
        }
    };

    fn deinitTilePayload(allocator: std.mem.Allocator, ptr: *anyopaque) void {
        const payload: *TileTypePayload = @ptrCast(@alignCast(ptr));
        if (payload.shape.len > 0) {
            allocator.free(payload.shape);
        }
        allocator.destroy(payload);
    }

    fn parseShape(allocator: std.mem.Allocator, shape_str: []const u8) ![]u32 {
        if (shape_str.len == 0) return error.InvalidTileShape;

        var dims = std.ArrayListUnmanaged(u32).empty;
        errdefer dims.deinit(allocator);

        var iter = std.mem.splitScalar(u8, shape_str, 'x');
        while (iter.next()) |part| {
            if (part.len == 0) return error.InvalidTileShape;
            const value = std.fmt.parseInt(u32, part, 10) catch return error.InvalidTileShape;
            try dims.append(allocator, value);
        }

        if (dims.items.len == 0) return error.InvalidTileShape;
        return dims.toOwnedSlice(allocator);
    }

    fn parseTileTypeParams(
        type_ptr: *const anyopaque,
        ctx_opaque: *const interfaces.ContextOpaque,
    ) anyerror!?interfaces.TypeParamPayload {
        const ctx = interfaces.castContext(ir.Context, ctx_opaque);
        const storage: *const ir.Type.DialectTypeStorage = @ptrCast(@alignCast(type_ptr));
        if (storage.param_key.len == 0) return null;

        var iter = std.mem.splitScalar(u8, storage.param_key, ',');
        const elem_name = iter.next() orelse return null;
        const mem_level_str = iter.next() orelse return null;
        const shape_str = iter.next() orelse return null;
        if (iter.next() != null) return null;

        const mem_level = TileMemLevel.fromString(mem_level_str) orelse return null;
        const allocator = ir.context.typePayloadAllocator(ctx);
        const shape = parseShape(allocator, shape_str) catch return null;
        errdefer allocator.free(shape);

        const payload = try allocator.create(TileTypePayload);
        payload.* = .{
            .element_type_name = elem_name,
            .element_type = ctx.getDialectTypeFromName(elem_name) catch null,
            .mem_level = mem_level,
            .shape = shape,
        };
        return .{ .ptr = payload, .deinit = deinitTilePayload };
    }

    fn loadSpec(ctx: *ir.Context) !void {
        ir.dialects.loadDialectSpec(ctx, spec) catch |err| switch (err) {
            error.ContextFrozen => {},
            else => return err,
        };
    }

    fn payloadFromType(ctx: *ir.Context, typ: ir.Type) ?*const TileTypePayload {
        loadSpec(ctx) catch return null;
        return ctx.getTypeParamPayload(typ, TileTypePayload) catch null;
    }

    pub fn getTileType(
        ctx: *ir.Context,
        element_type: ir.Type,
        mem_level: TileMemLevel,
        shape: []const u32,
    ) !ir.Type {
        try loadSpec(ctx);
        if (shape.len == 0) return error.InvalidTileShape;

        var buf: [128]u8 = undefined;
        const elem_name = element_type.getDialectTypeName() orelse "unknown";
        var pos: usize = 0;
        pos = try ir.format.appendFmt(buf[0..], pos, "{s},{s},", .{ elem_name, mem_level.toString() });
        for (shape, 0..) |dim, idx| {
            if (idx > 0) {
                pos = try ir.format.appendFmt(buf[0..], pos, "x", .{});
            }
            pos = try ir.format.appendFmt(buf[0..], pos, "{d}", .{dim});
        }
        return ctx.getDialectTypeFromNameWithKey(type_names.tile, buf[0..pos]);
    }

    pub fn getTileElementType(ctx: *ir.Context, typ: ir.Type) ?ir.Type {
        const payload = payloadFromType(ctx, typ) orelse return null;
        return payload.element_type;
    }

    pub fn getTileMemLevel(ctx: *ir.Context, typ: ir.Type) ?TileMemLevel {
        const payload = payloadFromType(ctx, typ) orelse return null;
        return payload.mem_level;
    }

    pub fn getTileShape(ctx: *ir.Context, typ: ir.Type) ?[]const u32 {
        const payload = payloadFromType(ctx, typ) orelse return null;
        return payload.shape;
    }

    pub fn getBarrierType(ctx: *ir.Context) !ir.Type {
        try loadSpec(ctx);
        return ctx.getDialectTypeFromName(type_names.barrier);
    }
};
