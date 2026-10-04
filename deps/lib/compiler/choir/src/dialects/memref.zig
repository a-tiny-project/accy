const std = @import("std");
const effects = ir.interfaces.effects;
const alloc_arena = @import("alloc_arena");
const alloc_observe = @import("alloc_observe");
const ir = @import("../core/root.zig");
const interfaces = @import("../core/root.zig").interfaces;
const arith = @import("arith/root.zig");

/// Refusals the memref verifiers name. Each one is a fact about the operation that was written,
/// never an assertion about the compiler, so user input reaches a named error rather than a trap.
pub const MemrefVerifyError = error{
    GlobalMissingName,
    GlobalMissingType,
    GlobalTypeNotMemref,
    GlobalTypeNotStatic,
    GlobalMissingAlignment,
    GlobalInvalidAlignment,
    GlobalMissingConstant,
    GlobalConstantWithoutInitial,
    GlobalInitialLengthMismatch,
    GetGlobalMissingName,
    GetGlobalResultNotMemref,
    ViewBaseNotMemref,
    ViewBaseNotBytes,
    ViewResultNotMemref,
    ViewResultNotStatic,
    AtomicOperandNotMemref,
    AtomicElementNotWordOrHalfWord,
    AtomicTypeMismatch,
    AtomicOrderingMissing,
    AtomicOrderingInvalid,
};

/// Where a global's storage comes from, which follows from its attributes rather than being
/// spelled separately.
pub const GlobalPlacement = enum {
    /// Declared constant and carrying bytes: the bytes are in the image and never written.
    read_only,
    /// Carrying bytes that code may write.
    writable,
    /// Carrying no bytes at all: the loader supplies zeroes for the whole extent.
    zeroed,
};

pub const AddressSpace = enum(u8) {
    host = 0,
    device = 1,
    constant = 2,
    shared = 3,
    unified = 4,
    local = 5,

    pub fn toString(self: AddressSpace) []const u8 {
        return switch (self) {
            .host => "host",
            .device => "device",
            .constant => "constant",
            .shared => "shared",
            .unified => "unified",
            .local => "local",
        };
    }

    pub fn fromString(s: []const u8) ?AddressSpace {
        if (std.mem.eql(u8, s, "host")) return .host;
        if (std.mem.eql(u8, s, "device")) return .device;
        if (std.mem.eql(u8, s, "constant")) return .constant;
        if (std.mem.eql(u8, s, "shared")) return .shared;
        if (std.mem.eql(u8, s, "unified")) return .unified;
        if (std.mem.eql(u8, s, "local")) return .local;
        return null;
    }
};

pub const Indexing = enum(u8) {
    i32,
    i64,

    pub fn toString(self: Indexing) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?Indexing {
        if (std.mem.eql(u8, s, "i32")) return .i32;
        if (std.mem.eql(u8, s, "i64")) return .i64;
        return null;
    }
};

pub const CacheOperation = enum(u8) {
    always,
    global,
    streaming,
    last_use,
    volatile_,
    write_back,
    write_through,
    workgroup,

    pub fn toString(self: CacheOperation) []const u8 {
        return switch (self) {
            .volatile_ => "volatile",
            else => @tagName(self),
        };
    }

    pub fn fromString(s: []const u8) ?CacheOperation {
        if (std.mem.eql(u8, s, "always")) return .always;
        if (std.mem.eql(u8, s, "global")) return .global;
        if (std.mem.eql(u8, s, "streaming")) return .streaming;
        if (std.mem.eql(u8, s, "last_use")) return .last_use;
        if (std.mem.eql(u8, s, "volatile")) return .volatile_;
        if (std.mem.eql(u8, s, "write_back")) return .write_back;
        if (std.mem.eql(u8, s, "write_through")) return .write_through;
        if (std.mem.eql(u8, s, "workgroup")) return .workgroup;
        return null;
    }
};

pub const CacheEviction = enum(u8) {
    normal,
    first,
    last,
    no_allocate,

    pub fn toString(self: CacheEviction) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?CacheEviction {
        inline for (@typeInfo(CacheEviction).@"enum".field_names, std.meta.tags(CacheEviction)) |field_name, tag| {
            if (std.mem.eql(u8, s, field_name)) {
                return tag;
            }
        }
        return null;
    }
};

pub const FenceScope = enum(u8) {
    system,
    device,
    workgroup,

    pub fn toString(self: FenceScope) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?FenceScope {
        inline for (@typeInfo(FenceScope).@"enum".field_names, std.meta.tags(FenceScope)) |field_name, tag| {
            if (std.mem.eql(u8, s, field_name)) {
                return tag;
            }
        }
        return null;
    }
};

pub const FenceOrdering = enum(u8) {
    acquire,
    release,
    acq_rel,
    seq_cst,

    pub fn toString(self: FenceOrdering) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?FenceOrdering {
        inline for (@typeInfo(FenceOrdering).@"enum".field_names, std.meta.tags(FenceOrdering)) |field_name, tag| {
            if (std.mem.eql(u8, s, field_name)) {
                return tag;
            }
        }
        return null;
    }
};

pub const AtomicRmwKind = enum(u8) {
    add,
    min,
    max,
    bit_and,
    bit_or,
    bit_xor,
    exchange,

    pub fn toString(self: AtomicRmwKind) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?AtomicRmwKind {
        inline for (@typeInfo(AtomicRmwKind).@"enum".field_names, std.meta.tags(AtomicRmwKind)) |field_name, tag| {
            if (std.mem.eql(u8, s, field_name)) {
                return tag;
            }
        }
        return null;
    }
};

pub const MemrefDialect = struct {
    pub const name = "memref";
    const op_specs = ir.dialects.opSpec.dialect(@This());
    const op_templates = ir.dialects.operationTemplate.dialect(@This());
    pub const spec = ir.dialects.dialectSpec(@This(), .{
        .types = &.{ir.dialects.typeName(name)},
        .type_interface_fallbacks = &.{
            .{ .id = interfaces.TypeParamInterface.id, .fallback = typeParamFallback },
            .{ .id = interfaces.ShapedTypeInterface.id, .fallback = shapedTypeFallback },
        },
    });

    pub const MemrefTypePayload = struct {
        size: ?u64,
        element_type_name: []const u8,
        element_type: ?ir.Type,
        addr_space: AddressSpace,
        alignment: ?u64,
        exclusive: ?bool,
        indexing: ?Indexing,
        shape_storage: [1]u64 = [_]u64{0},
        shape: ?[]const u64 = null,
    };

    const type_param_vtable = interfaces.TypeParamInterface.VTable{
        .parse = parseTypeParams,
    };

    const shaped_type_vtable = interfaces.ShapedTypeInterface.VTable{
        .getRank = shapedGetRank,
        .getShape = shapedGetShape,
        .getElementType = shapedGetElementType,
        .getAddressSpaceTag = shapedGetAddressSpaceTag,
    };

    pub const MemrefTypeAttrs = struct {
        alignment: ?u64 = null,
        exclusive: ?bool = null,
        indexing: ?Indexing = null,
    };

    pub const MemrefParams = struct {
        size: ?u64,
        element_type_name: []const u8,
        addr_space: AddressSpace,
        alignment: ?u64 = null,
        exclusive: ?bool = null,
        indexing: ?Indexing = null,
    };

    pub const LayoutAttrs = struct {
        offset: ?u64 = null,
        shape: ?[]const u64 = null,
        stride: ?[]const u64 = null,
    };

    pub const AllocOp = struct {
        op: *ir.Operation,

        const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "alloc",
            .interfaces = &.{allocationEffects("heap")},
            .operands = ir.dialects.shape.atMost(1),
            .operand_names = .{"dynamic_size"},
            .results = .{"memref"},
        });
        pub const operation_spec = leaf.operation_spec;
        pub const operation_name = leaf.operation_name;
        pub const createLeaf = leaf.createLeaf;
        pub const getOptionalOperand = leaf.getOptionalOperand;

        pub fn createStatic(
            ctx: *ir.Context,
            loc: ir.Location,
            result_type: ir.Type,
        ) !AllocOp {
            return @This().createLeaf(ctx, loc, &.{}, &.{result_type});
        }

        pub fn createDynamic(
            ctx: *ir.Context,
            loc: ir.Location,
            size: *ir.Value,
            result_type: ir.Type,
        ) !AllocOp {
            return @This().createLeaf(ctx, loc, &.{size}, &.{result_type});
        }

        pub fn getResult(self: *const AllocOp) *ir.Value {
            return leaf.getResult(self.*);
        }

        pub fn getDynamicSize(self: AllocOp) ?*ir.Value {
            return self.getOptionalOperand("dynamic_size");
        }
    };

    /// Allocates per-invocation storage. Its contents are undefined until stored;
    /// loading an element before storing it has no defined result on any backend.
    /// The CPU twin maps a local alloca to host stack storage without zeroing it.
    pub const AllocaOp = struct {
        op: *ir.Operation,

        const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "alloca",
            .interfaces = &.{allocationEffects("stack")},
            .operands = ir.dialects.shape.atMost(1),
            .operand_names = .{"dynamic_size"},
            .results = .{"memref"},
        });
        pub const operation_spec = leaf.operation_spec;
        pub const operation_name = leaf.operation_name;
        pub const createLeaf = leaf.createLeaf;
        pub const getOptionalOperand = leaf.getOptionalOperand;

        pub fn createStatic(
            ctx: *ir.Context,
            loc: ir.Location,
            result_type: ir.Type,
        ) !AllocaOp {
            return @This().createLeaf(ctx, loc, &.{}, &.{result_type});
        }

        pub fn createDynamic(
            ctx: *ir.Context,
            loc: ir.Location,
            size: *ir.Value,
            result_type: ir.Type,
        ) !AllocaOp {
            return @This().createLeaf(ctx, loc, &.{size}, &.{result_type});
        }

        pub fn getResult(self: *const AllocaOp) *ir.Value {
            return leaf.getResult(self.*);
        }

        pub fn getDynamicSize(self: AllocaOp) ?*ir.Value {
            return self.getOptionalOperand("dynamic_size");
        }
    };

    /// A module level declaration of storage that code addresses by name.
    ///
    /// The placement follows from two attributes rather than being spelled a third time.
    /// `constant` with `initial` bytes is storage nothing writes, `initial` bytes without
    /// `constant` is storage code may write, and neither is an extent the loader fills with
    /// zeroes and the image carries no bytes for. `constant` with nothing to be constant about
    /// is refused, because the only thing it could mean is a read only run of zeroes that no
    /// one can ever have written.
    ///
    /// The type travels as a one element type list because the builtin attributes carry a list
    /// of types and not a single one, and this operation has no result to carry it on.
    pub const GlobalOp = struct {
        op: *ir.Operation,

        pub const attr_names = struct {
            pub const sym_name = "sym_name";
            pub const memref_type = "type";
            pub const alignment = "alignment";
            pub const constant = "constant";
            pub const initial = "initial";
        };

        const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "global",
            .operands = 0,
            .results = 0,
            .required_attrs = .{
                ir.dialects.attribute.string(attr_names.sym_name),
                ir.dialects.attribute.any(attr_names.memref_type),
                ir.dialects.attribute.integer(attr_names.alignment),
                ir.dialects.attribute.boolean(attr_names.constant),
            },
            .attrs = .{ir.dialects.attribute.string(attr_names.initial)},
            .interfaces = &.{effects.EffectOpInterface.entryFor(.{ .complete = true })},
        });
        pub const operation_spec = leaf.operation_spec;
        pub const operation_name = leaf.operation_name;
        pub const createLeaf = leaf.createLeaf;
        pub const verify = verifyGlobalOp;

        pub const Declaration = struct {
            sym_name: []const u8,
            memref_type: ir.Type,
            alignment: u64 = 1,
            constant: bool = false,
            /// Bytes the image carries. Absent declares an extent of zeroes instead.
            initial: ?[]const u8 = null,
        };

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            declaration: Declaration,
        ) !GlobalOp {
            try loadSpec(ctx);
            if (declaration.alignment > std.math.maxInt(i64)) {
                return MemrefVerifyError.GlobalInvalidAlignment;
            }
            const self = try @This().createLeaf(ctx, loc, &.{}, &.{});
            errdefer self.op.erase();
            const names = attr_names;
            try self.op.setAttr(names.sym_name, try ctx.getStringAttr(declaration.sym_name));
            try self.op.setAttr(
                names.memref_type,
                try ctx.getTypeListAttr(&.{declaration.memref_type}),
            );
            try self.op.setAttr(
                names.alignment,
                try ctx.getI64Attr(@intCast(declaration.alignment)),
            );
            try self.op.setAttr(names.constant, try ctx.getBoolAttr(declaration.constant));
            if (declaration.initial) |bytes| {
                try self.op.setAttr(names.initial, try ctx.getStringAttr(bytes));
            }
            try verifyGlobal(self.op);
            return self;
        }

        pub fn getSymName(self: GlobalOp) ?[]const u8 {
            const attr = self.op.getAttrAs(ir.Attribute.StringAttr, attr_names.sym_name) orelse
                return null;
            return attr.getValue();
        }

        pub fn getType(self: GlobalOp) ?ir.Type {
            const attr = self.op.getAttrAs(
                ir.Attribute.TypeListAttr,
                attr_names.memref_type,
            ) orelse return null;
            const values = attr.getValues();
            if (values.len != 1) return null;
            return values[0];
        }

        pub fn getAlignment(self: GlobalOp) ?u64 {
            const attr = self.op.getAttrAs(ir.Attribute.IntegerAttr, attr_names.alignment) orelse
                return null;
            const value = attr.getValue();
            if (value < 0) return null;
            return @intCast(value);
        }

        pub fn isConstant(self: GlobalOp) ?bool {
            const attr = self.op.getAttrAs(ir.Attribute.BoolAttr, attr_names.constant) orelse
                return null;
            return attr.getValue();
        }

        pub fn getInitial(self: GlobalOp) ?[]const u8 {
            const attr = self.op.getAttrAs(ir.Attribute.StringAttr, attr_names.initial) orelse
                return null;
            return attr.getValue();
        }

        /// Where this global's storage comes from, or null when the attributes do not decide it.
        pub fn getPlacement(self: GlobalOp) ?GlobalPlacement {
            const constant = self.isConstant() orelse return null;
            if (self.getInitial() == null) {
                if (constant) return null;
                return .zeroed;
            }
            return if (constant) .read_only else .writable;
        }
    };

    /// The address of a global, as a memref value of that global's declared type.
    ///
    /// This computes an address and touches nothing, so it declares one result and no event.
    /// Reading or writing through the result is what `memref.load` and `memref.store` declare.
    pub const GetGlobalOp = struct {
        op: *ir.Operation,

        pub const attr_names = struct {
            pub const sym_name = "sym_name";
        };

        const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "get_global",
            .operands = 0,
            .results = .{"memref"},
            .required_attrs = .{ir.dialects.attribute.string(attr_names.sym_name)},
            .interfaces = &.{effects.EffectOpInterface.entryFor(.{
                .complete = true,
                .facts = &.{.{ .result = .{ .index = 0, .ownership = .none } }},
            })},
        });
        pub const operation_spec = leaf.operation_spec;
        pub const operation_name = leaf.operation_name;
        pub const createLeaf = leaf.createLeaf;
        pub const verify = verifyGetGlobalOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            sym_name: []const u8,
            result_type: ir.Type,
        ) !GetGlobalOp {
            try loadSpec(ctx);
            const self = try @This().createLeaf(ctx, loc, &.{}, &.{result_type});
            errdefer self.op.erase();
            try self.op.setAttr(attr_names.sym_name, try ctx.getStringAttr(sym_name));
            try verifyGetGlobal(self.op);
            return self;
        }

        pub fn getResult(self: *const GetGlobalOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSymName(self: GetGlobalOp) ?[]const u8 {
            const attr = self.op.getAttrAs(ir.Attribute.StringAttr, attr_names.sym_name) orelse
                return null;
            return attr.getValue();
        }
    };

    pub const DeallocOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "dealloc",
            .interfaces = &.{effects.EffectOpInterface.entryFor(.{ .facts = &.{
                .{ .requirement = .{ .kind = .live, .subject = .{ .operand = 0 } } },
                .{ .event = .{ .kind = .free, .resource = .{ .subject = .{ .operand = 0 } } } },
            } })},
            .operands = 1,
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            memref: *ir.Value,
        ) !DeallocOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{memref});

            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getMemref(self: DeallocOp) *ir.Value {
            return self.op.operands.items[0].value;
        }
    };

    pub const FenceOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "fence",
            .interfaces = &.{effects.EffectOpInterface.entryFor(.{ .facts = &.{.{
                .event = .{ .kind = .synchronize, .ordered = true },
            }} })},
            .operands = 0,
            .results = 0,
            .attrs = &.{ "scope", "ordering" },
            .traits = ir.OperationTraits{},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            scope: FenceScope,
            ordering: FenceOrdering,
        ) !FenceOp {
            var builder = ir.OperationBuilder.init(ctx);
            const op = try builder.create(op_specs.state(@This(), loc));
            errdefer op.erase();
            try setFenceScopeAttr(op, ctx, scope);
            try setFenceOrderingAttr(op, ctx, ordering);
            return .{ .op = op };
        }

        pub fn getScope(self: FenceOp) ?FenceScope {
            return getFenceScopeAttr(self.op);
        }

        pub fn getOrdering(self: FenceOp) ?FenceOrdering {
            return getFenceOrderingAttr(self.op);
        }
    };

    pub const LoadOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "load",
            .interfaces = &.{accessEffects(0, 1, true, false, false)},
            .operands = 2,
            .results = 1,
            .attrs = &.{ "cache", "eviction" },
            .traits = ir.OperationTraits{},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            memref: *ir.Value,
            index: *ir.Value,
            result_type: ir.Type,
        ) !LoadOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ memref, index });
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn createWithCache(
            ctx: *ir.Context,
            loc: ir.Location,
            memref: *ir.Value,
            index: *ir.Value,
            result_type: ir.Type,
            cache: ?CacheOperation,
            eviction: ?CacheEviction,
        ) !LoadOp {
            const load = try create(ctx, loc, memref, index, result_type);
            errdefer load.op.erase();
            if (cache) |hint| {
                try setCacheOperationAttr(load.op, ctx, hint);
            }
            if (eviction) |hint| {
                try setCacheEvictionAttr(load.op, ctx, hint);
            }
            return load;
        }

        pub fn getResult(self: *const LoadOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getMemref(self: LoadOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getIndex(self: LoadOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getCacheOperation(self: LoadOp) ?CacheOperation {
            return getCacheOperationAttr(self.op);
        }

        pub fn getCacheEviction(self: LoadOp) ?CacheEviction {
            return getCacheEvictionAttr(self.op);
        }
    };

    pub const StoreOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "store",
            .interfaces = &.{accessEffects(1, 2, false, true, false)},
            .operands = 3,
            .results = 0,
            .attrs = &.{ "cache", "eviction" },
            .traits = ir.OperationTraits{},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            value: *ir.Value,
            memref: *ir.Value,
            index: *ir.Value,
        ) !StoreOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ value, memref, index });

            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn createWithCache(
            ctx: *ir.Context,
            loc: ir.Location,
            value: *ir.Value,
            memref: *ir.Value,
            index: *ir.Value,
            cache: ?CacheOperation,
            eviction: ?CacheEviction,
        ) !StoreOp {
            const store = try create(ctx, loc, value, memref, index);
            errdefer store.op.erase();
            if (cache) |hint| {
                try setCacheOperationAttr(store.op, ctx, hint);
            }
            if (eviction) |hint| {
                try setCacheEvictionAttr(store.op, ctx, hint);
            }
            return store;
        }

        pub fn getValue(self: StoreOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getMemref(self: StoreOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getIndex(self: StoreOp) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getCacheOperation(self: StoreOp) ?CacheOperation {
            return getCacheOperationAttr(self.op);
        }

        pub fn getCacheEviction(self: StoreOp) ?CacheEviction {
            return getCacheEvictionAttr(self.op);
        }
    };

    pub const AtomicRmwOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "atomic_rmw",
            .interfaces = &.{accessEffects(1, 2, true, true, true)},
            .operands = 3,
            .results = 1,
            .attrs = &.{"kind"},
            .traits = ir.OperationTraits{},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            kind: AtomicRmwKind,
            value: *ir.Value,
            memref: *ir.Value,
            index: *ir.Value,
            result_type: ir.Type,
        ) !AtomicRmwOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ value, memref, index });
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            errdefer op.erase();
            const kind_attr = try ctx.getDialectAttr("memref.atomic_kind", kind.toString());
            try op.setAttr("kind", kind_attr);
            return .{ .op = op };
        }

        pub fn getKind(self: AtomicRmwOp) ?AtomicRmwKind {
            const dialect_attr = self.op.getAttrAs(ir.Attribute.DialectAttr, "kind") orelse return null;
            return AtomicRmwKind.fromString(dialect_attr.payload);
        }

        pub fn getValue(self: AtomicRmwOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getMemref(self: AtomicRmwOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getIndex(self: AtomicRmwOp) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getResult(self: *const AtomicRmwOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    /// Reads one element atomically: no other thread observes a torn word, and the read is
    /// ordered by `ordering`, which is `acquire` or `seq_cst` because a load cannot release.
    pub const AtomicLoadOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "atomic_load",
            .interfaces = &.{accessEffects(0, 1, true, false, true)},
            .operands = 2,
            .results = 1,
            .required_attrs = .{ir.dialects.attribute.dialect("ordering", "memref.fence_ordering")},
            .traits = ir.OperationTraits{},
        });
        pub const operation_name = operation_spec.name;
        pub const verify = verifyAtomicLoadOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            memref: *ir.Value,
            index: *ir.Value,
            result_type: ir.Type,
            ordering: FenceOrdering,
        ) !AtomicLoadOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ memref, index });
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            errdefer op.erase();
            try setFenceOrderingAttr(op, ctx, ordering);
            try verifyAtomicLoad(op);
            return .{ .op = op };
        }

        pub fn getMemref(self: AtomicLoadOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getIndex(self: AtomicLoadOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getOrdering(self: AtomicLoadOp) ?FenceOrdering {
            return getFenceOrderingAttr(self.op);
        }

        pub fn getResult(self: *const AtomicLoadOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    /// Writes one element atomically, ordered by `ordering`, which is `release` or `seq_cst`
    /// because a store cannot acquire.
    pub const AtomicStoreOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "atomic_store",
            .interfaces = &.{accessEffects(1, 2, false, true, true)},
            .operands = 3,
            .results = 0,
            .required_attrs = .{ir.dialects.attribute.dialect("ordering", "memref.fence_ordering")},
            .traits = ir.OperationTraits{},
        });
        pub const operation_name = operation_spec.name;
        pub const verify = verifyAtomicStoreOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            value: *ir.Value,
            memref: *ir.Value,
            index: *ir.Value,
            ordering: FenceOrdering,
        ) !AtomicStoreOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ value, memref, index });

            const op = try builder.create(state);
            errdefer op.erase();
            try setFenceOrderingAttr(op, ctx, ordering);
            try verifyAtomicStore(op);
            return .{ .op = op };
        }

        pub fn getValue(self: AtomicStoreOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getMemref(self: AtomicStoreOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getIndex(self: AtomicStoreOp) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getOrdering(self: AtomicStoreOp) ?FenceOrdering {
            return getFenceOrderingAttr(self.op);
        }
    };

    pub const AtomicCasOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "atomic_cas",
            .interfaces = &.{accessEffects(2, 3, true, true, true)},
            .operands = 4,
            .results = 1,
            .attrs = .{ir.dialects.attribute.dialect("ordering", "memref.fence_ordering")},
            .traits = ir.OperationTraits{},
        });
        pub const operation_name = operation_spec.name;
        pub const verify = verifyAtomicCasOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            expected: *ir.Value,
            desired: *ir.Value,
            memref: *ir.Value,
            index: *ir.Value,
            result_type: ir.Type,
        ) !AtomicCasOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ expected, desired, memref, index });
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getExpected(self: AtomicCasOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getDesired(self: AtomicCasOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getMemref(self: AtomicCasOp) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getIndex(self: AtomicCasOp) *ir.Value {
            return self.op.operands.items[3].value;
        }

        /// The same exchange with its ordering spelled. Every ordering is legal on a compare
        /// and swap, which both reads and writes.
        pub fn createOrdered(
            ctx: *ir.Context,
            loc: ir.Location,
            expected: *ir.Value,
            desired: *ir.Value,
            memref: *ir.Value,
            index: *ir.Value,
            result_type: ir.Type,
            ordering: FenceOrdering,
        ) !AtomicCasOp {
            const cas = try create(ctx, loc, expected, desired, memref, index, result_type);
            errdefer cas.op.erase();
            try setFenceOrderingAttr(cas.op, ctx, ordering);
            return cas;
        }

        /// The ordering the exchange carries, `seq_cst` when none is spelled.
        pub fn getOrdering(self: AtomicCasOp) FenceOrdering {
            return getFenceOrderingAttr(self.op) orelse .seq_cst;
        }

        pub fn getResult(self: *const AtomicCasOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const CopyOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "copy",
            .interfaces = &.{effects.EffectOpInterface.entryFor(.{ .facts = &.{
                .{ .event = .{ .kind = .read, .resource = .{ .subject = .{ .operand = 0 } } } },
                .{ .event = .{ .kind = .write, .resource = .{ .subject = .{ .operand = 1 } } } },
            } })},
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

    pub const SubviewOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "subview",
            .interfaces = &.{aliasEffects()},
            .operands = 1,
            .results = 1,
            .attrs = &.{ "offset", "shape", "stride" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            source: *ir.Value,
            result_type: ir.Type,
        ) !SubviewOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{source});
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const SubviewOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSource(self: SubviewOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getShapePayload(self: SubviewOp) ?[]const u8 {
            return getLayoutPayload(self.op, "shape");
        }

        pub fn getStridePayload(self: SubviewOp) ?[]const u8 {
            return getLayoutPayload(self.op, "stride");
        }

        pub fn getOffsetPayload(self: SubviewOp) ?[]const u8 {
            return getLayoutPayload(self.op, "offset");
        }
    };

    /// A memref over a byte offset into a byte addressed base, with the offset unscaled.
    ///
    /// This is the one spelling for reaching a value inside an arena. `memref.load` and
    /// `memref.store` scale their index by the element size of the memref they are given, so a
    /// byte offset cannot be expressed as an index into a base of wider elements, and
    /// `memref.subview` carries a static offset attribute rather than a value. Here the base is
    /// 8 bit elements, the offset is one `index` operand added to the base unscaled, and loads
    /// and stores through the result scale by the RESULT's element size.
    ///
    /// The result type is the result's own type rather than a repeated attribute, so there is
    /// one statement of it that cannot disagree with itself.
    ///
    /// The arithmetic is one add and touches no memory, but the VALUE is a borrow: the result
    /// points inside the base's storage. So this declares the base borrowed and the result an
    /// alias of it, the same as `memref.subview` and `memref.transpose`. Declaring an
    /// independent result instead would tell a consumer that a write through the view cannot
    /// reach the base, which is the one thing that is never true here.
    ///
    /// Aligning the offset is the producer's duty. This operation does not check it, at
    /// verification or at run time, because the offset is a value and the alignment a value
    /// must satisfy is a property of what the producer intends to store there.
    pub const ViewOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "view",
            .interfaces = &.{aliasEffects()},
            .operands = 2,
            .results = 1,
        });
        pub const operation_name = operation_spec.name;
        pub const verify = verifyViewOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            base: *ir.Value,
            byte_offset: *ir.Value,
            result_type: ir.Type,
        ) !ViewOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ base, byte_offset });
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            errdefer op.erase();
            try verifyView(op);
            return .{ .op = op };
        }

        pub fn getResult(self: *const ViewOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getBase(self: ViewOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getByteOffset(self: ViewOp) *ir.Value {
            return self.op.operands.items[1].value;
        }
    };

    pub const TransposeOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "transpose",
            .interfaces = &.{aliasEffects()},
            .operands = 1,
            .results = 1,
            .attrs = &.{ "shape", "stride" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            source: *ir.Value,
            result_type: ir.Type,
        ) !TransposeOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{source});
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const TransposeOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSource(self: TransposeOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getShapePayload(self: TransposeOp) ?[]const u8 {
            return getLayoutPayload(self.op, "shape");
        }

        pub fn getStridePayload(self: TransposeOp) ?[]const u8 {
            return getLayoutPayload(self.op, "stride");
        }
    };

    fn deinitPayload(allocator: std.mem.Allocator, ptr: *anyopaque) void {
        const payload: *MemrefTypePayload = @ptrCast(@alignCast(ptr));
        allocator.destroy(payload);
    }

    fn typeParamFallback(ctx: *const ir.Context, typ: ir.Type) ?*const anyopaque {
        _ = ctx;
        const type_name = typ.getDialectTypeName() orelse return null;
        if (!std.mem.eql(u8, type_name, name)) return null;
        return &type_param_vtable;
    }

    fn shapedTypeFallback(ctx: *const ir.Context, typ: ir.Type) ?*const anyopaque {
        _ = ctx;
        const type_name = typ.getDialectTypeName() orelse return null;
        if (!std.mem.eql(u8, type_name, name)) return null;
        return &shaped_type_vtable;
    }

    fn loadSpec(ctx: *ir.Context) !void {
        ir.dialects.loadDialectSpec(ctx, spec) catch |err| switch (err) {
            error.ContextFrozen => {},
            else => return err,
        };
    }

    fn payloadFromTypePtr(ctx: *ir.Context, type_ptr: *const anyopaque) ?*const MemrefTypePayload {
        loadSpec(ctx) catch return null;

        const storage: *const ir.Type.DialectTypeStorage = @ptrCast(@alignCast(type_ptr));
        const typ = ir.Type{
            .type_id = .dialect_type,
            .impl = storage,
        };
        return ctx.getTypeParamPayload(typ, MemrefTypePayload) catch null;
    }

    fn parseTypeParams(type_ptr: *const anyopaque, ctx_opaque: *const interfaces.ContextOpaque) anyerror!?interfaces.TypeParamPayload {
        const ctx = interfaces.castContext(ir.Context, ctx_opaque);
        const storage: *const ir.Type.DialectTypeStorage = @ptrCast(@alignCast(type_ptr));
        if (storage.param_key.len == 0) return null;

        const params = parseMemrefParams(storage.param_key) orelse return null;

        const payload = try ir.context.typePayloadAllocator(ctx).create(MemrefTypePayload);
        payload.* = .{
            .size = params.size,
            .element_type_name = params.element_type_name,
            .element_type = ctx.getDialectTypeFromName(params.element_type_name) catch null,
            .addr_space = params.addr_space,
            .alignment = params.alignment,
            .exclusive = params.exclusive,
            .indexing = params.indexing,
        };

        if (params.size) |size| {
            payload.shape_storage[0] = size;
            payload.shape = payload.shape_storage[0..1];
        } else {
            payload.shape = null;
        }

        return .{ .ptr = payload, .deinit = deinitPayload };
    }

    fn shapedGetRank(type_ptr: *const anyopaque, ctx_opaque: *const interfaces.ContextOpaque) ?usize {
        const ctx = interfaces.castContext(ir.Context, ctx_opaque);
        const payload = payloadFromTypePtr(ctx, type_ptr) orelse return null;
        _ = payload;
        return 1;
    }

    fn shapedGetShape(type_ptr: *const anyopaque, ctx_opaque: *const interfaces.ContextOpaque) ?[]const u64 {
        const ctx = interfaces.castContext(ir.Context, ctx_opaque);
        const payload = payloadFromTypePtr(ctx, type_ptr) orelse return null;
        return payload.shape;
    }

    fn shapedGetElementType(type_ptr: *const anyopaque, ctx_opaque: *const interfaces.ContextOpaque) ?ir.Type {
        const ctx = interfaces.castContext(ir.Context, ctx_opaque);
        const payload = payloadFromTypePtr(ctx, type_ptr) orelse return null;
        return payload.element_type;
    }

    fn shapedGetAddressSpaceTag(type_ptr: *const anyopaque, ctx_opaque: *const interfaces.ContextOpaque) ?u8 {
        const ctx = interfaces.castContext(ir.Context, ctx_opaque);
        const payload = payloadFromTypePtr(ctx, type_ptr) orelse return null;
        return @backingInt(payload.addr_space);
    }

    pub fn getMemrefType1D(
        ctx: *ir.Context,
        size: u64,
        element_type: ir.Type,
        addr_space: AddressSpace,
    ) !ir.Type {
        return getMemrefType1DWithAttrs(ctx, size, element_type, addr_space, .{});
    }

    pub fn getMemrefTypeDynamic(
        ctx: *ir.Context,
        element_type: ir.Type,
        addr_space: AddressSpace,
    ) !ir.Type {
        return getMemrefTypeDynamicWithAttrs(ctx, element_type, addr_space, .{});
    }

    pub fn getMemrefType1DWithAttrs(
        ctx: *ir.Context,
        size: u64,
        element_type: ir.Type,
        addr_space: AddressSpace,
        attrs: MemrefTypeAttrs,
    ) !ir.Type {
        try loadSpec(ctx);
        var buf: [512]u8 = undefined;
        const elem_name = element_type.getDialectTypeName() orelse "unknown";
        var pos: usize = 0;
        pos = try ir.format.appendFmt(buf[0..], pos, "{d},{s},{s}", .{
            size,
            elem_name,
            addr_space.toString(),
        });
        pos = try appendTypeAttrs(buf[0..], pos, attrs);
        return ctx.getDialectTypeFromNameWithKey("memref", buf[0..pos]);
    }

    pub fn getMemrefTypeDynamicWithAttrs(
        ctx: *ir.Context,
        element_type: ir.Type,
        addr_space: AddressSpace,
        attrs: MemrefTypeAttrs,
    ) !ir.Type {
        try loadSpec(ctx);
        var buf: [512]u8 = undefined;
        const elem_name = element_type.getDialectTypeName() orelse "unknown";
        var pos: usize = 0;
        pos = try ir.format.appendFmt(buf[0..], pos, "?,{s},{s}", .{
            elem_name,
            addr_space.toString(),
        });
        pos = try appendTypeAttrs(buf[0..], pos, attrs);
        return ctx.getDialectTypeFromNameWithKey("memref", buf[0..pos]);
    }

    pub fn parseMemrefParams(param_key: []const u8) ?MemrefParams {
        var section_iter = std.mem.splitScalar(u8, param_key, ';');
        const base = section_iter.next() orelse return null;
        var iter = std.mem.splitScalar(u8, base, ',');

        const size_str = iter.next() orelse return null;
        const size: ?u64 = if (std.mem.eql(u8, size_str, "?"))
            null
        else
            std.fmt.parseInt(u64, size_str, 10) catch return null;

        const elem_type = iter.next() orelse return null;
        const addr_space_str = iter.next() orelse return null;
        const addr_space = AddressSpace.fromString(addr_space_str) orelse return null;

        var alignment: ?u64 = null;
        var exclusive: ?bool = null;
        var indexing: ?Indexing = null;

        while (section_iter.next()) |section| {
            if (section.len == 0) continue;
            var kv_iter = std.mem.splitScalar(u8, section, '=');
            const key = kv_iter.next() orelse continue;
            const value = kv_iter.next() orelse continue;
            if (kv_iter.next() != null) return null;

            if (std.mem.eql(u8, key, "alignment") or std.mem.eql(u8, key, "align")) {
                alignment = std.fmt.parseInt(u64, value, 10) catch return null;
                continue;
            }

            if (std.mem.eql(u8, key, "exclusive")) {
                if (std.mem.eql(u8, value, "true")) {
                    exclusive = true;
                } else if (std.mem.eql(u8, value, "false")) {
                    exclusive = false;
                } else {
                    return null;
                }
                continue;
            }

            if (std.mem.eql(u8, key, "indexing")) {
                indexing = Indexing.fromString(value) orelse return null;
                continue;
            }
        }

        return .{
            .size = size,
            .element_type_name = elem_type,
            .addr_space = addr_space,
            .alignment = alignment,
            .exclusive = exclusive,
            .indexing = indexing,
        };
    }

    fn formatDims(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, dims: []const u64) !void {
        if (dims.len == 0) return;
        for (dims, 0..) |dim, i| {
            if (i > 0) try buf.append(allocator, ',');
            var tmp: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&tmp, "{d}", .{dim});
            try buf.appendSlice(allocator, text);
        }
    }

    fn setLayoutDimsAttr(op: *ir.Operation, ctx: *ir.Context, attr_name: []const u8, full_name: []const u8, dims: []const u64) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        const allocator = ir.context.transientAllocator(ctx);
        defer buf.deinit(allocator);
        try formatDims(&buf, allocator, dims);
        const attr = try ctx.getDialectAttr(full_name, buf.items);
        try op.setAttr(attr_name, attr);
    }

    fn setLayoutOffsetAttr(op: *ir.Operation, ctx: *ir.Context, offset: u64) !void {
        var buf: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, "{d}", .{offset});
        const attr = try ctx.getDialectAttr("memref.offset", payload);
        try op.setAttr("offset", attr);
    }

    fn getLayoutPayload(op: *const ir.Operation, attr_name: []const u8) ?[]const u8 {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, attr_name) orelse return null;
        return dialect_attr.payload;
    }

    pub fn setLayoutAttrs(op: *ir.Operation, ctx: *ir.Context, attrs: LayoutAttrs) !void {
        if (attrs.offset) |offset| {
            try setLayoutOffsetAttr(op, ctx, offset);
        }
        if (attrs.shape) |shape| {
            try setLayoutDimsAttr(op, ctx, "shape", "memref.shape", shape);
        }
        if (attrs.stride) |stride| {
            try setLayoutDimsAttr(op, ctx, "stride", "memref.stride", stride);
        }
    }

    fn setCacheOperationAttr(op: *ir.Operation, ctx: *ir.Context, cache: CacheOperation) !void {
        const cache_attr = try ctx.getDialectAttr("memref.cache", cache.toString());
        try op.setAttr("cache", cache_attr);
    }

    fn getCacheOperationAttr(op: *const ir.Operation) ?CacheOperation {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "cache") orelse return null;
        return CacheOperation.fromString(dialect_attr.payload);
    }

    fn setCacheEvictionAttr(op: *ir.Operation, ctx: *ir.Context, eviction: CacheEviction) !void {
        const eviction_attr = try ctx.getDialectAttr("memref.eviction", eviction.toString());
        try op.setAttr("eviction", eviction_attr);
    }

    fn getCacheEvictionAttr(op: *const ir.Operation) ?CacheEviction {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "eviction") orelse return null;
        return CacheEviction.fromString(dialect_attr.payload);
    }

    fn setFenceScopeAttr(op: *ir.Operation, ctx: *ir.Context, scope: FenceScope) !void {
        const attr = try ctx.getDialectAttr("memref.fence_scope", scope.toString());
        try op.setAttr("scope", attr);
    }

    fn getFenceScopeAttr(op: *const ir.Operation) ?FenceScope {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "scope") orelse return null;
        return FenceScope.fromString(dialect_attr.payload);
    }

    fn setFenceOrderingAttr(op: *ir.Operation, ctx: *ir.Context, ordering: FenceOrdering) !void {
        const attr = try ctx.getDialectAttr("memref.fence_ordering", ordering.toString());
        try op.setAttr("ordering", attr);
    }

    fn getFenceOrderingAttr(op: *const ir.Operation) ?FenceOrdering {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "ordering") orelse return null;
        return FenceOrdering.fromString(dialect_attr.payload);
    }

    fn appendTypeAttrs(buf: []u8, start: usize, attrs: MemrefTypeAttrs) !usize {
        var pos = start;
        if (attrs.alignment) |alignment| {
            pos = try ir.format.appendFmt(buf, pos, ";alignment={d}", .{alignment});
        }
        if (attrs.exclusive) |exclusive| {
            pos = try ir.format.appendFmt(
                buf,
                pos,
                ";exclusive={s}",
                .{if (exclusive) "true" else "false"},
            );
        }
        if (attrs.indexing) |indexing| {
            pos = try ir.format.appendFmt(buf, pos, ";indexing={s}", .{indexing.toString()});
        }
        return pos;
    }
};

const ConstructorResourceCounts = struct {
    operations: usize,

    fn capture(ctx: *const ir.Context) ConstructorResourceCounts {
        return .{
            .operations = ctx.operationCount(),
        };
    }

    fn expectEqual(self: ConstructorResourceCounts, ctx: *const ir.Context) !void {
        try std.testing.expectEqual(self.operations, ctx.operationCount());
    }
};

fn expectConstructorCleanup(baseline: ConstructorResourceCounts, ctx: *ir.Context, constructed: anytype) !void {
    const value = constructed catch |err| {
        try baseline.expectEqual(ctx);
        return err;
    };
    value.op.erase();
    try baseline.expectEqual(ctx);
}

fn checkMemrefConstructorAllocationFailures(allocator: std.mem.Allocator) !void {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const loc = ir.Location.getUnknown();
    const f32_type = try arith.ArithDialect.getScalarType(&ctx, .f32);
    const index_type = try arith.ArithDialect.getIndexType(&ctx);
    const memref_type = try MemrefDialect.getMemrefType1D(&ctx, 16, f32_type, .device);
    var alloc = try MemrefDialect.AllocOp.createStatic(&ctx, loc, memref_type);
    var index = try arith.ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 0);
    var value = try arith.ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 1.0);
    const baseline = ConstructorResourceCounts.capture(&ctx);

    try expectConstructorCleanup(baseline, &ctx, MemrefDialect.FenceOp.create(&ctx, loc, .device, .acq_rel));
    try expectConstructorCleanup(baseline, &ctx, MemrefDialect.LoadOp.createWithCache(
        &ctx,
        loc,
        alloc.getResult(),
        index.getResult(),
        f32_type,
        .streaming,
        .first,
    ));
    try expectConstructorCleanup(baseline, &ctx, MemrefDialect.StoreOp.createWithCache(
        &ctx,
        loc,
        value.getResult(),
        alloc.getResult(),
        index.getResult(),
        .write_through,
        .no_allocate,
    ));
    try expectConstructorCleanup(baseline, &ctx, MemrefDialect.AtomicRmwOp.create(
        &ctx,
        loc,
        .add,
        value.getResult(),
        alloc.getResult(),
        index.getResult(),
        f32_type,
    ));
}

test "MemrefDialect constructors clean every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkMemrefConstructorAllocationFailures,
        .{},
    );
}

test "MemrefDialect type construction" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const f32_type = try arith.ArithDialect.getScalarType(&ctx, .f32);
    const memref_type = try MemrefDialect.getMemrefType1D(&ctx, 1024, f32_type, .host);

    const params = MemrefDialect.parseMemrefParams(memref_type.getDialectParamKey().?).?;
    try testing.expectEqual(@as(u64, 1024), params.size.?);
    try testing.expectEqual(AddressSpace.host, params.addr_space);
    try testing.expect(params.alignment == null);
    try testing.expect(params.exclusive == null);
    try testing.expect(params.indexing == null);
}

test "MemrefDialect type attributes" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const f32_type = try arith.ArithDialect.getScalarType(&ctx, .f32);
    const attrs = MemrefDialect.MemrefTypeAttrs{
        .alignment = 16,
        .exclusive = true,
        .indexing = .i32,
    };
    const memref_type = try MemrefDialect.getMemrefType1DWithAttrs(&ctx, 64, f32_type, .device, attrs);

    const params = MemrefDialect.parseMemrefParams(memref_type.getDialectParamKey().?).?;
    try testing.expectEqual(@as(u64, 64), params.size.?);
    try testing.expectEqual(AddressSpace.device, params.addr_space);
    try testing.expectEqual(@as(u64, 16), params.alignment.?);
    try testing.expectEqual(true, params.exclusive.?);
    try testing.expectEqual(Indexing.i32, params.indexing.?);
}

test "MemrefDialect structured payload and shaped interface" {
    const testing = std.testing;
    var gpa = alloc_observe.debug.Allocator(.{}).init(testing.allocator);
    defer {
        const status = gpa.deinit();
        testing.expect(status == .ok) catch @panic("memref payload leaked allocations");
    }

    var ctx = try ir.Context.init(gpa.allocator(), ir.Context.Limits.testing);
    defer ctx.deinit(gpa.allocator());

    const f32_type = try arith.ArithDialect.getScalarType(&ctx, .f32);
    const memref_type = try MemrefDialect.getMemrefType1D(&ctx, 64, f32_type, .device);

    const payload1 = (try ctx.getTypeParamPayload(memref_type, MemrefDialect.MemrefTypePayload)).?;
    const payload2 = (try ctx.getTypeParamPayload(memref_type, MemrefDialect.MemrefTypePayload)).?;
    try testing.expect(payload1 == payload2);
    try testing.expectEqual(@as(u64, 64), payload1.size.?);
    try testing.expectEqual(AddressSpace.device, payload1.addr_space);

    const shaped = ctx.typeInterface(memref_type, interfaces.ShapedTypeInterface).?;
    const rank = shaped.call(.getRank, .{}).?;
    try testing.expectEqual(@as(usize, 1), rank);

    const shape = shaped.call(.getShape, .{}).?;
    try testing.expectEqual(@as(usize, 1), shape.len);
    try testing.expectEqual(@as(u64, 64), shape[0]);

    const elem = shaped.call(.getElementType, .{}).?;
    try testing.expect(elem.eql(f32_type));

    const addr_tag = shaped.call(.getAddressSpaceTag, .{}).?;
    try testing.expectEqual(@as(u8, @backingInt(AddressSpace.device)), addr_tag);
}

test "MemrefDialect spec owns type interface fallbacks" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    try ir.dialects.loadDialectSpec(&ctx, MemrefDialect.spec);

    try testing.expect(ctx.getDialectTypeInterfaceFallback(MemrefDialect.name, interfaces.TypeParamInterface.id) != null);
    try testing.expect(ctx.getDialectTypeInterfaceFallback(MemrefDialect.name, interfaces.ShapedTypeInterface.id) != null);

    const f32_type = try arith.ArithDialect.getScalarType(&ctx, .f32);
    const memref_type = try MemrefDialect.getMemrefType1D(&ctx, 32, f32_type, .shared);

    try testing.expect((try ctx.getTypeParamPayload(memref_type, MemrefDialect.MemrefTypePayload)) != null);
    try testing.expect(ctx.typeInterface(memref_type, interfaces.ShapedTypeInterface) != null);
}

test "MemrefDialect.AllocOp creates allocation" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try arith.ArithDialect.getScalarType(&ctx, .f32);
    const memref_type = try MemrefDialect.getMemrefType1D(&ctx, 1024, f32_type, .device);

    var alloc = try MemrefDialect.AllocOp.createStatic(&ctx, loc, memref_type);

    try testing.expectEqualStrings("memref.alloc", alloc.op.name.name);
    try testing.expect(alloc.getDynamicSize() == null);
}

test "MemrefDialect.AllocaOp creates local allocation" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try arith.ArithDialect.getScalarType(&ctx, .f32);
    const memref_type = try MemrefDialect.getMemrefType1D(&ctx, 32, f32_type, .host);

    var alloca = try MemrefDialect.AllocaOp.createStatic(&ctx, loc, memref_type);

    try testing.expectEqualStrings("memref.alloca", alloca.op.name.name);
    try testing.expect(alloca.getDynamicSize() == null);
}

test "MemrefDialect.LoadOp and StoreOp" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try arith.ArithDialect.getScalarType(&ctx, .f32);
    const index_type = try arith.ArithDialect.getIndexType(&ctx);
    const memref_type = try MemrefDialect.getMemrefType1D(&ctx, 1024, f32_type, .host);

    var alloc = try MemrefDialect.AllocOp.createStatic(&ctx, loc, memref_type);
    var idx = try arith.ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 0);

    var load = try MemrefDialect.LoadOp.create(&ctx, loc, alloc.getResult(), idx.getResult(), f32_type);
    try testing.expectEqualStrings("memref.load", load.op.name.name);
    try testing.expect(load.getMemref() == alloc.getResult());

    var val = try arith.ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 3.14);
    var store = try MemrefDialect.StoreOp.create(&ctx, loc, val.getResult(), alloc.getResult(), idx.getResult());
    try testing.expectEqualStrings("memref.store", store.op.name.name);
    try testing.expect(store.getMemref() == alloc.getResult());
    try testing.expect(store.getValue() == val.getResult());
}

test "MemrefDialect cache attributes on load/store" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try arith.ArithDialect.getScalarType(&ctx, .f32);
    const index_type = try arith.ArithDialect.getIndexType(&ctx);
    const memref_type = try MemrefDialect.getMemrefType1D(&ctx, 16, f32_type, .device);

    var alloc = try MemrefDialect.AllocOp.createStatic(&ctx, loc, memref_type);
    var idx = try arith.ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 0);

    var load = try MemrefDialect.LoadOp.createWithCache(
        &ctx,
        loc,
        alloc.getResult(),
        idx.getResult(),
        f32_type,
        .streaming,
        .first,
    );
    try testing.expectEqual(CacheOperation.streaming, load.getCacheOperation().?);
    try testing.expectEqual(CacheEviction.first, load.getCacheEviction().?);

    var val = try arith.ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 1.0);
    var store = try MemrefDialect.StoreOp.createWithCache(
        &ctx,
        loc,
        val.getResult(),
        alloc.getResult(),
        idx.getResult(),
        .write_through,
        .no_allocate,
    );
    try testing.expectEqual(CacheOperation.write_through, store.getCacheOperation().?);
    try testing.expectEqual(CacheEviction.no_allocate, store.getCacheEviction().?);
}

test "MemrefDialect.FenceOp carries scope and ordering side effect" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, MemrefDialect.spec);

    const loc = ir.Location.getUnknown();
    const fence = try MemrefDialect.FenceOp.create(&ctx, loc, .device, .acq_rel);

    try testing.expectEqualStrings("memref.fence", fence.op.name.name);
    try testing.expectEqual(FenceScope.device, fence.getScope().?);
    try testing.expectEqual(FenceOrdering.acq_rel, fence.getOrdering().?);
    try testing.expectEqual(@as(?FenceScope, null), FenceScope.fromString("thread"));
    try testing.expectEqual(@as(?FenceOrdering, null), FenceOrdering.fromString("consume"));
}

test "MemrefDialect atomic load and store refuse orderings, widths, and types they cannot carry" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, MemrefDialect.spec);

    const loc = ir.Location.getUnknown();
    const i64_type = try arith.ArithDialect.getScalarType(&ctx, .i64);
    const i32_type = try arith.ArithDialect.getScalarType(&ctx, .i32);
    const i16_type = try arith.ArithDialect.getScalarType(&ctx, .i16);
    const f64_type = try arith.ArithDialect.getScalarType(&ctx, .f64);
    const index_type = try arith.ArithDialect.getIndexType(&ctx);
    const words = try MemrefDialect.AllocOp.createStatic(&ctx, loc, try MemrefDialect.getMemrefType1D(&ctx, 4, i64_type, .host));
    const shorts = try MemrefDialect.AllocOp.createStatic(
        &ctx,
        loc,
        try MemrefDialect.getMemrefType1D(&ctx, 4, i16_type, .host),
    );
    const doubles = try MemrefDialect.AllocOp.createStatic(
        &ctx,
        loc,
        try MemrefDialect.getMemrefType1D(&ctx, 4, f64_type, .host),
    );
    const slot = try arith.ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 1);
    const word = try arith.ArithDialect.ConstantOp.createInt(&ctx, loc, i64_type, 9);
    const half = try arith.ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 9);
    const baseline = ConstructorResourceCounts.capture(&ctx);

    try testing.expectError(error.AtomicOrderingInvalid, expectConstructorCleanup(
        baseline,
        &ctx,
        MemrefDialect.AtomicLoadOp.create(
            &ctx,
            loc,
            words.getResult(),
            slot.getResult(),
            i64_type,
            .release,
        ),
    ));
    try testing.expectError(error.AtomicOrderingInvalid, expectConstructorCleanup(
        baseline,
        &ctx,
        MemrefDialect.AtomicLoadOp.create(
            &ctx,
            loc,
            words.getResult(),
            slot.getResult(),
            i64_type,
            .acq_rel,
        ),
    ));
    try testing.expectError(error.AtomicOrderingInvalid, expectConstructorCleanup(
        baseline,
        &ctx,
        MemrefDialect.AtomicStoreOp.create(
            &ctx,
            loc,
            word.getResult(),
            words.getResult(),
            slot.getResult(),
            .acquire,
        ),
    ));
    try testing.expectError(error.AtomicElementNotWordOrHalfWord, expectConstructorCleanup(
        baseline,
        &ctx,
        MemrefDialect.AtomicLoadOp.create(
            &ctx,
            loc,
            shorts.getResult(),
            slot.getResult(),
            i16_type,
            .acquire,
        ),
    ));
    try testing.expectError(error.AtomicElementNotWordOrHalfWord, expectConstructorCleanup(
        baseline,
        &ctx,
        MemrefDialect.AtomicLoadOp.create(
            &ctx,
            loc,
            doubles.getResult(),
            slot.getResult(),
            f64_type,
            .seq_cst,
        ),
    ));
    try testing.expectError(error.AtomicTypeMismatch, expectConstructorCleanup(
        baseline,
        &ctx,
        MemrefDialect.AtomicLoadOp.create(
            &ctx,
            loc,
            words.getResult(),
            slot.getResult(),
            i32_type,
            .acquire,
        ),
    ));
    try testing.expectError(error.AtomicTypeMismatch, expectConstructorCleanup(
        baseline,
        &ctx,
        MemrefDialect.AtomicStoreOp.create(
            &ctx,
            loc,
            half.getResult(),
            words.getResult(),
            slot.getResult(),
            .release,
        ),
    ));
    try testing.expectError(error.AtomicOperandNotMemref, expectConstructorCleanup(
        baseline,
        &ctx,
        MemrefDialect.AtomicStoreOp.create(
            &ctx,
            loc,
            word.getResult(),
            word.getResult(),
            slot.getResult(),
            .seq_cst,
        ),
    ));

    const load = try MemrefDialect.AtomicLoadOp.create(
        &ctx,
        loc,
        words.getResult(),
        slot.getResult(),
        i64_type,
        .seq_cst,
    );
    const store = try MemrefDialect.AtomicStoreOp.create(
        &ctx,
        loc,
        word.getResult(),
        words.getResult(),
        slot.getResult(),
        .release,
    );
    const cas = try MemrefDialect.AtomicCasOp.create(
        &ctx,
        loc,
        word.getResult(),
        load.getResult(),
        words.getResult(),
        slot.getResult(),
        i64_type,
    );
    const ordered_cas = try MemrefDialect.AtomicCasOp.createOrdered(
        &ctx,
        loc,
        word.getResult(),
        load.getResult(),
        words.getResult(),
        slot.getResult(),
        i64_type,
        .acquire,
    );
    const fence = try MemrefDialect.FenceOp.create(&ctx, loc, .system, .release);
    try testing.expectEqual(FenceOrdering.seq_cst, load.getOrdering().?);
    try testing.expectEqual(FenceOrdering.release, store.getOrdering().?);
    try testing.expectEqual(FenceOrdering.seq_cst, cas.getOrdering());
    try testing.expectEqual(FenceOrdering.acquire, ordered_cas.getOrdering());

    const operations = [_]*ir.Operation{ load.op, store.op, cas.op, ordered_cas.op, fence.op };
    for (operations) |op| {
        try ir.verifyOperation(op, .{});
        var declaration = try effects.inspect(std.testing.allocator, op);
        defer declaration.deinit(std.testing.allocator);
        try testing.expect(!effects.discard(declaration.facts));
        try testing.expect(
            !effects.duplicate(declaration.facts, .{
                .read_values = true,
                .execution_context = true,
            }),
        );
    }
}

test "MemrefDialect subview/transpose attach layout attrs" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try arith.ArithDialect.getScalarType(&ctx, .f32);
    const src_type = try MemrefDialect.getMemrefType1D(&ctx, 8, f32_type, .host);
    const view_type = try MemrefDialect.getMemrefType1D(&ctx, 4, f32_type, .host);

    var alloc = try MemrefDialect.AllocOp.createStatic(&ctx, loc, src_type);
    var subview = try MemrefDialect.SubviewOp.create(&ctx, loc, alloc.getResult(), view_type);
    try MemrefDialect.setLayoutAttrs(subview.op, &ctx, .{
        .offset = 1,
        .shape = &.{ 2, 2 },
        .stride = &.{ 2, 1 },
    });

    try testing.expectEqualStrings("1", subview.getOffsetPayload().?);
    try testing.expectEqualStrings("2,2", subview.getShapePayload().?);
    try testing.expectEqualStrings("2,1", subview.getStridePayload().?);

    var transpose = try MemrefDialect.TransposeOp.create(&ctx, loc, alloc.getResult(), view_type);
    try MemrefDialect.setLayoutAttrs(transpose.op, &ctx, .{
        .shape = &.{ 2, 2 },
        .stride = &.{ 1, 2 },
    });

    try testing.expectEqualStrings("2,2", transpose.getShapePayload().?);
    try testing.expectEqualStrings("1,2", transpose.getStridePayload().?);
}

test "MemrefDialect.AtomicRmwOp carries kind, operands, and old-value result" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try arith.ArithDialect.getScalarType(&ctx, .f32);
    const i32_type = try arith.ArithDialect.getScalarType(&ctx, .i32);
    const index_type = try arith.ArithDialect.getIndexType(&ctx);
    const memref_type = try MemrefDialect.getMemrefType1D(&ctx, 64, f32_type, .device);

    var alloc = try MemrefDialect.AllocOp.createStatic(&ctx, loc, memref_type);
    var idx = try arith.ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 7);
    var val = try arith.ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 2.5);

    var atomic = try MemrefDialect.AtomicRmwOp.create(
        &ctx,
        loc,
        .add,
        val.getResult(),
        alloc.getResult(),
        idx.getResult(),
        f32_type,
    );
    try testing.expectEqualStrings("memref.atomic_rmw", atomic.op.name.name);
    try testing.expectEqual(AtomicRmwKind.add, atomic.getKind().?);
    try testing.expect(atomic.getValue() == val.getResult());
    try testing.expect(atomic.getMemref() == alloc.getResult());
    try testing.expect(atomic.getIndex() == idx.getResult());
    try testing.expect(atomic.getResult().type.eql(f32_type));

    var ival = try arith.ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 3);
    inline for (.{ AtomicRmwKind.min, AtomicRmwKind.max, AtomicRmwKind.bit_and, AtomicRmwKind.bit_or, AtomicRmwKind.bit_xor, AtomicRmwKind.exchange }) |kind| {
        var op = try MemrefDialect.AtomicRmwOp.create(
            &ctx,
            loc,
            kind,
            ival.getResult(),
            alloc.getResult(),
            idx.getResult(),
            i32_type,
        );
        try testing.expectEqual(kind, op.getKind().?);
    }

    try testing.expectEqual(@as(?AtomicRmwKind, null), AtomicRmwKind.fromString("nand"));
    try testing.expectEqual(AtomicRmwKind.bit_xor, AtomicRmwKind.fromString("bit_xor").?);
}

test "MemrefDialect.AtomicCasOp carries operands and old-value result" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try arith.ArithDialect.getScalarType(&ctx, .i32);
    const index_type = try arith.ArithDialect.getIndexType(&ctx);
    const memref_type = try MemrefDialect.getMemrefType1D(&ctx, 64, i32_type, .device);

    var alloc = try MemrefDialect.AllocOp.createStatic(&ctx, loc, memref_type);
    var idx = try arith.ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 7);
    var expected = try arith.ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 3);
    var desired = try arith.ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 5);

    var atomic = try MemrefDialect.AtomicCasOp.create(
        &ctx,
        loc,
        expected.getResult(),
        desired.getResult(),
        alloc.getResult(),
        idx.getResult(),
        i32_type,
    );
    try testing.expectEqualStrings("memref.atomic_cas", atomic.op.name.name);
    try testing.expect(atomic.getExpected() == expected.getResult());
    try testing.expect(atomic.getDesired() == desired.getResult());
    try testing.expect(atomic.getMemref() == alloc.getResult());
    try testing.expect(atomic.getIndex() == idx.getResult());
    try testing.expect(atomic.getResult().type.eql(i32_type));
}

/// THE LIST IS EXHAUSTIVE, WHICH IS WHAT `complete` STATES. An allocation
/// allocates, may fail in its domain, and hands back one fresh identity. It
/// reads nothing, writes nothing, and frees nothing, so there is no fact left
/// unsaid. Completeness is a claim about the list and not a permission: an
/// allocate event is not a read or a write and a fresh identity is not
/// ownership none, so `total` still refuses, and every permission derived
/// through it still refuses.
fn allocationEffects(comptime domain: []const u8) ir.interfaces.InterfaceEntry {
    return effects.EffectOpInterface.entryFor(.{ .complete = true, .facts = &.{
        .{ .event = .{ .kind = .allocate, .resource = .{
            .subject = .{ .result = 0 },
            .allocator_domain = domain,
        } } },
        .{ .event = .{ .kind = .failure, .resource = .{
            .allocator_domain = domain,
        } } },
        .{ .result = .{ .index = 0, .fresh_identity = true, .ownership = .owned } },
    } });
}

/// Largest alignment a global may request.
///
/// A loader places a section on a page boundary, so an offset aligned within a section is also
/// aligned in memory up to one page and no further. `lib/compiler/choir/src/backends/machine.zig` states
/// the same bound for the symbols this becomes, and a test there pins the two together rather
/// than this dialect depending on a backend.
pub const max_global_alignment = 4096;

/// The memref parameters of `ty`, or null when `ty` is not a memref type.
pub fn paramsOf(ty: ir.Type) ?MemrefDialect.MemrefParams {
    const name = ty.getDialectTypeName() orelse return null;
    if (!std.mem.eql(u8, name, MemrefDialect.name)) return null;
    const key = ty.getDialectParamKey() orelse return null;
    return MemrefDialect.parseMemrefParams(key);
}

/// The number of bytes one value of `element_type_name` occupies.
///
/// The width comes from `arith`, which owns the scalar types, rather than from a switch this
/// dialect keeps beside it. An element whose width is not a whole number of bytes has no byte
/// size here rather than a rounded one, so storage of such elements is refused by name instead
/// of quietly taking more room than it asked for.
pub fn elementByteSize(element_type_name: []const u8) ?u64 {
    const kind = arith.scalarKindFromTypeName(element_type_name) orelse return null;
    const bits = arith.scalarBitWidth(kind);
    if (bits == 0 or bits % 8 != 0) return null;
    return bits / 8;
}

/// The number of bytes a statically shaped memref occupies once loaded.
pub fn staticByteSize(memref_type: ir.Type) ?u64 {
    const params = paramsOf(memref_type) orelse return null;
    const count = params.size orelse return null;
    const width = elementByteSize(params.element_type_name) orelse return null;
    return std.math.mul(u64, count, width) catch null;
}

/// The `memref.global` that `sym_name` names, searched outward from `from`.
///
/// A global is a module level declaration and its uses sit inside functions, so resolution walks
/// outward through enclosing operations rather than down from a root this dialect cannot name.
/// The walk is bounded by nesting depth and reads each enclosing body once.
pub fn findGlobal(from: *const ir.Operation, sym_name: []const u8) ?MemrefDialect.GlobalOp {
    var current = from.getParentOp();
    while (current) |ancestor| : (current = ancestor.getParentOp()) {
        if (globalInBody(ancestor, sym_name)) |found| return found;
    }
    return null;
}

fn globalInBody(container: *ir.Operation, sym_name: []const u8) ?MemrefDialect.GlobalOp {
    const region = container.getRegion(0) orelse return null;
    const block = region.getEntryBlock() orelse return null;
    var cursor = block.operations.head;
    while (cursor) |node| {
        const op: *ir.Operation = @ptrCast(@alignCast(node));
        cursor = op.next_op;
        if (!std.mem.eql(u8, op.name.name, MemrefDialect.GlobalOp.operation_name)) continue;
        const candidate = MemrefDialect.GlobalOp{ .op = op };
        const name = candidate.getSymName() orelse continue;
        if (std.mem.eql(u8, name, sym_name)) return candidate;
    }
    return null;
}

fn verifyGlobal(op: *ir.Operation) MemrefVerifyError!void {
    const self = MemrefDialect.GlobalOp{ .op = op };
    const name = self.getSymName() orelse return MemrefVerifyError.GlobalMissingName;
    if (name.len == 0) return MemrefVerifyError.GlobalMissingName;
    const memref_type = self.getType() orelse return MemrefVerifyError.GlobalMissingType;
    const params = paramsOf(memref_type) orelse return MemrefVerifyError.GlobalTypeNotMemref;
    if (params.size == null) return MemrefVerifyError.GlobalTypeNotStatic;
    const alignment = self.getAlignment() orelse return MemrefVerifyError.GlobalMissingAlignment;
    if (alignment == 0 or alignment > max_global_alignment) {
        return MemrefVerifyError.GlobalInvalidAlignment;
    }
    if (!std.math.isPowerOfTwo(alignment)) return MemrefVerifyError.GlobalInvalidAlignment;
    const constant = self.isConstant() orelse return MemrefVerifyError.GlobalMissingConstant;
    const size = staticByteSize(memref_type) orelse return MemrefVerifyError.GlobalTypeNotStatic;
    const initial = self.getInitial() orelse {
        if (constant) return MemrefVerifyError.GlobalConstantWithoutInitial;
        return;
    };
    if (initial.len != size) return MemrefVerifyError.GlobalInitialLengthMismatch;
}

fn verifyGlobalOp(op_ptr: *const anyopaque) anyerror!void {
    const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
    try verifyGlobal(op);
}

fn verifyGetGlobal(op: *ir.Operation) MemrefVerifyError!void {
    const self = MemrefDialect.GetGlobalOp{ .op = op };
    const name = self.getSymName() orelse return MemrefVerifyError.GetGlobalMissingName;
    if (name.len == 0) return MemrefVerifyError.GetGlobalMissingName;
    if (op.results.items.len != 1) return MemrefVerifyError.GetGlobalResultNotMemref;
    if (paramsOf(op.results.items[0].type) == null) {
        return MemrefVerifyError.GetGlobalResultNotMemref;
    }
}

fn verifyGetGlobalOp(op_ptr: *const anyopaque) anyerror!void {
    const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
    try verifyGetGlobal(op);
}

fn verifyView(op: *ir.Operation) MemrefVerifyError!void {
    if (op.operands.items.len != 2) return MemrefVerifyError.ViewBaseNotMemref;
    const base_params = paramsOf(op.operands.items[0].value.type) orelse
        return MemrefVerifyError.ViewBaseNotMemref;
    const width = elementByteSize(base_params.element_type_name) orelse
        return MemrefVerifyError.ViewBaseNotBytes;
    if (width != 1) return MemrefVerifyError.ViewBaseNotBytes;
    if (op.results.items.len != 1) return MemrefVerifyError.ViewResultNotMemref;
    const result_params = paramsOf(op.results.items[0].type) orelse
        return MemrefVerifyError.ViewResultNotMemref;
    if (result_params.size == null) return MemrefVerifyError.ViewResultNotStatic;
}

fn verifyViewOp(op_ptr: *const anyopaque) anyerror!void {
    const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
    try verifyView(op);
}

/// Whether `element_type_name` names an integer a single x86 instruction reads or writes
/// atomically when aligned: a machine word or a 32-bit half of one.
fn atomicElementSupported(element_type_name: []const u8) bool {
    const kind = arith.scalarKindFromTypeName(element_type_name) orelse return false;
    if (!arith.scalarKindIsInteger(kind)) return false;
    const bits = arith.scalarBitWidth(kind);
    return bits == 32 or bits == 64;
}

fn verifyAtomicAccess(
    op: *ir.Operation,
    memref_index: usize,
    value_type: ir.Type,
) MemrefVerifyError!void {
    if (op.operands.items.len <= memref_index) return MemrefVerifyError.AtomicOperandNotMemref;
    const params = paramsOf(op.operands.items[memref_index].value.type) orelse
        return MemrefVerifyError.AtomicOperandNotMemref;
    if (!atomicElementSupported(params.element_type_name)) {
        return MemrefVerifyError.AtomicElementNotWordOrHalfWord;
    }
    const value_name = value_type.getDialectTypeName() orelse
        return MemrefVerifyError.AtomicTypeMismatch;
    if (!std.mem.eql(u8, value_name, params.element_type_name)) {
        return MemrefVerifyError.AtomicTypeMismatch;
    }
}

fn verifyAtomicOrdering(
    op: *const ir.Operation,
    legal: []const FenceOrdering,
) MemrefVerifyError!void {
    if (op.getAttr("ordering") == null) return MemrefVerifyError.AtomicOrderingMissing;
    const ordering = MemrefDialect.getFenceOrderingAttr(op) orelse
        return MemrefVerifyError.AtomicOrderingInvalid;
    for (legal) |allowed| {
        if (ordering == allowed) return;
    }
    return MemrefVerifyError.AtomicOrderingInvalid;
}

fn verifyAtomicLoad(op: *ir.Operation) MemrefVerifyError!void {
    try verifyAtomicOrdering(op, &.{ .acquire, .seq_cst });
    if (op.results.items.len != 1) return MemrefVerifyError.AtomicTypeMismatch;
    try verifyAtomicAccess(op, 0, op.results.items[0].type);
}

fn verifyAtomicLoadOp(op_ptr: *const anyopaque) anyerror!void {
    const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
    try verifyAtomicLoad(op);
}

fn verifyAtomicStore(op: *ir.Operation) MemrefVerifyError!void {
    try verifyAtomicOrdering(op, &.{ .release, .seq_cst });
    if (op.operands.items.len != 3) return MemrefVerifyError.AtomicOperandNotMemref;
    try verifyAtomicAccess(op, 1, op.operands.items[0].value.type);
}

fn verifyAtomicStoreOp(op_ptr: *const anyopaque) anyerror!void {
    const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
    try verifyAtomicStore(op);
}

fn verifyAtomicCasOp(op_ptr: *const anyopaque) anyerror!void {
    const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
    if (op.getAttr("ordering") == null) return;
    try verifyAtomicOrdering(op, &.{ .acquire, .release, .acq_rel, .seq_cst });
}

fn aliasEffects() ir.interfaces.InterfaceEntry {
    return effects.EffectOpInterface.entryFor(.{ .facts = &.{
        .{ .event = .{ .kind = .borrow, .resource = .{ .subject = .{ .operand = 0 } } } },
        .{ .result = .{ .index = 0, .alias = .{ .operand = 0 }, .ownership = .borrowed } },
    } });
}

/// THE LIST IS EXHAUSTIVE. An access requires its base live and its index in
/// bounds, and it reads or writes that base. Its results are values carrying
/// no identity. Nothing else happens, so the enumeration states `complete`.
/// The requirements are what still refuse every permission: `total` refuses
/// any requirement, so a load or a store is no more discardable, duplicable
/// or reorderable than it was before this line.
/// Whether the index operand is a literal the declared extent already admits.
///
/// A REQUIREMENT IS A PREMISE TO PROVE AT THE USE, SO A PREMISE THE OPERANDS
/// THEMSELVES SETTLE IS NOT ONE. `arith` states the same thing about division
/// by a literal that is not zero and about a literal shift count: the
/// declaration omits the requirement rather than restating what the operand
/// says. This omits `in_bounds` only when the extent is a static size and the
/// index is a literal below it, which is decided from the two operands alone
/// and needs nothing about the program around them.
///
/// It says nothing about liveness. `live` stays declared for every access,
/// literal index or not, because an extent cannot prove that the base is
/// still there to be read.
fn indexProvenInBounds(
    op: *const ir.Operation,
    comptime base_index: usize,
    comptime index_index: usize,
) bool {
    const key = op.operands.items[base_index].value.type.getDialectParamKey() orelse return false;
    const params = MemrefDialect.parseMemrefParams(key) orelse return false;
    const extent = params.size orelse return false;
    const index = literalIndex(op.operands.items[index_index].value) orelse return false;
    if (index < 0) return false;
    return @as(u128, @intCast(index)) < @as(u128, extent);
}

/// The value a literal index carries, or null when the operand is not one.
fn literalIndex(value: *ir.Value) ?i64 {
    const raw = value.getDefiningOp() orelse return null;
    const definition: *ir.Operation = @ptrCast(@alignCast(raw));
    if (!std.mem.eql(u8, definition.name.name, arith.ArithDialect.ConstantOp.operation_name)) {
        return null;
    }
    const attr = definition.getAttr("value") orelse return null;
    return (attr.cast(ir.Attribute.IntegerAttr) orelse return null).getValue();
}

fn accessEffects(
    comptime base_index: usize,
    comptime index_index: usize,
    comptime reads: bool,
    comptime writes: bool,
    comptime ordered: bool,
) ir.interfaces.InterfaceEntry {
    const Declaration = struct {
        fn enumerate(op: *const ir.Operation, collector: *effects.Collector) void {
            collector.valueResults(op);
            if (op.getNumOperands() <= @max(base_index, index_index)) return;
            var resource = effects.Resource{ .subject = .{ .operand = base_index } };
            if (op.operands.items[base_index].value.type.getDialectParamKey()) |key| {
                if (MemrefDialect.parseMemrefParams(key)) |params| {
                    resource.address_space = @intCast(@backingInt(params.addr_space));
                }
            }
            collector.append(.{ .requirement = .{ .kind = .live, .subject = resource.subject } });
            if (!indexProvenInBounds(op, base_index, index_index)) {
                collector.append(.{ .requirement = .{
                    .kind = .in_bounds,
                    .subject = resource.subject,
                    .related = .{ .operand = index_index },
                } });
            }
            if (reads) collector.append(.{ .event = .{
                .kind = .read,
                .resource = resource,
                .ordered = ordered,
            } });
            if (writes) collector.append(.{ .event = .{
                .kind = .write,
                .resource = resource,
                .ordered = ordered,
            } });
        }
    };
    return effects.EffectOpInterface.entryFor(.{
        .complete = true,
        .capacity = .{ .entries = 4, .per_result = 1 },
        .enumerate = Declaration.enumerate,
    });
}

test "memref effect declarations preserve checked accesses and allocation identity" {
    const arithmetic = arith.ArithDialect;
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    const typ = try arithmetic.getI32Type(&ctx);
    const memref_type = try MemrefDialect.getMemrefType1D(&ctx, 4, typ, .host);
    const allocation = try MemrefDialect.AllocOp.createStatic(&ctx, .unknown, memref_type);
    const index = try arithmetic.ConstantOp.createInt(&ctx, .unknown, typ, 0);
    const load = try MemrefDialect.LoadOp.create(
        &ctx,
        .unknown,
        allocation.getResult(),
        index.getResult(),
        typ,
    );
    var load_facts = try effects.inspect(std.testing.allocator, load.op);
    defer load_facts.deinit(std.testing.allocator);
    try std.testing.expect(load_facts.facts.complete);
    try std.testing.expect(!effects.total(load_facts.facts));
    try std.testing.expect(!effects.discard(load_facts.facts));
    try std.testing.expect(!effects.duplicate(load_facts.facts, .{
        .read_values = true,
        .execution_context = true,
    }));
    try std.testing.expect(!effects.reorder(load_facts.facts, load_facts.facts, .{
        .no_dependencies = true,
        .concurrency_exclusive = true,
    }));
    try std.testing.expectEqual(
        effects.RequirementKind.live,
        load_facts.facts.records[1].requirement.kind,
    );
    try std.testing.expectEqual(effects.EventKind.read, load_facts.facts.records[2].event.kind);
    try std.testing.expectEqual(
        @as(usize, 0),
        load_facts.facts.records[2].event.resource.subject.operand,
    );
    for (load_facts.facts.records) |record| {
        if (record != .requirement) continue;
        try std.testing.expect(record.requirement.kind != .in_bounds);
    }

    const computed = try MemrefDialect.LoadOp.create(
        &ctx,
        .unknown,
        allocation.getResult(),
        load.getResult(),
        typ,
    );
    var computed_facts = try effects.inspect(std.testing.allocator, computed.op);
    defer computed_facts.deinit(std.testing.allocator);
    try std.testing.expect(computed_facts.facts.complete);
    try std.testing.expectEqual(
        effects.RequirementKind.in_bounds,
        computed_facts.facts.records[2].requirement.kind,
    );

    const past = try arithmetic.ConstantOp.createInt(&ctx, .unknown, typ, 4);
    const outside = try MemrefDialect.LoadOp.create(
        &ctx,
        .unknown,
        allocation.getResult(),
        past.getResult(),
        typ,
    );
    var outside_facts = try effects.inspect(std.testing.allocator, outside.op);
    defer outside_facts.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        effects.RequirementKind.in_bounds,
        outside_facts.facts.records[2].requirement.kind,
    );
    var allocation_facts = try effects.inspect(std.testing.allocator, allocation.op);
    defer allocation_facts.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        effects.EventKind.allocate,
        allocation_facts.facts.records[0].event.kind,
    );
    try std.testing.expect(allocation_facts.facts.records[2].result.fresh_identity);
    try std.testing.expect(allocation_facts.facts.complete);
    try std.testing.expect(!effects.total(allocation_facts.facts));
    try std.testing.expect(!effects.discard(allocation_facts.facts));
    try std.testing.expect(!effects.duplicate(allocation_facts.facts, .{}));
}

test "MemrefDialect.GlobalOp maps declarations onto the three placements" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i64_type = try arith.ArithDialect.getScalarType(&ctx, .i64);
    const u8_type = try arith.ArithDialect.getScalarType(&ctx, .u8);
    const word_type = try MemrefDialect.getMemrefType1D(&ctx, 1, i64_type, .host);
    const arena_type = try MemrefDialect.getMemrefType1D(&ctx, 4096, u8_type, .host);
    const word: []const u8 = &.{ 1, 2, 3, 4, 5, 6, 7, 8 };

    const zeroed = try MemrefDialect.GlobalOp.create(&ctx, loc, .{
        .sym_name = "arena",
        .memref_type = arena_type,
        .alignment = 16,
    });
    try testing.expectEqualStrings("memref.global", zeroed.op.name.name);
    try testing.expectEqualStrings("arena", zeroed.getSymName().?);
    try testing.expectEqual(@as(u64, 16), zeroed.getAlignment().?);
    try testing.expect(zeroed.getInitial() == null);
    try testing.expectEqual(GlobalPlacement.zeroed, zeroed.getPlacement().?);

    const writable = try MemrefDialect.GlobalOp.create(&ctx, loc, .{
        .sym_name = "seed",
        .memref_type = word_type,
        .alignment = 8,
        .initial = word,
    });
    try testing.expectEqual(GlobalPlacement.writable, writable.getPlacement().?);
    try testing.expectEqualSlices(u8, word, writable.getInitial().?);

    const read_only = try MemrefDialect.GlobalOp.create(&ctx, loc, .{
        .sym_name = "table",
        .memref_type = word_type,
        .alignment = 8,
        .constant = true,
        .initial = word,
    });
    try testing.expectEqual(GlobalPlacement.read_only, read_only.getPlacement().?);
}

test "MemrefDialect.GlobalOp refuses a declaration no section can hold" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i64_type = try arith.ArithDialect.getScalarType(&ctx, .i64);
    const word_type = try MemrefDialect.getMemrefType1D(&ctx, 1, i64_type, .host);

    try testing.expectError(
        MemrefVerifyError.GlobalConstantWithoutInitial,
        MemrefDialect.GlobalOp.create(&ctx, loc, .{
            .sym_name = "table",
            .memref_type = word_type,
            .alignment = 8,
            .constant = true,
        }),
    );
    try testing.expectError(
        MemrefVerifyError.GlobalInitialLengthMismatch,
        MemrefDialect.GlobalOp.create(&ctx, loc, .{
            .sym_name = "table",
            .memref_type = word_type,
            .alignment = 8,
            .constant = true,
            .initial = &.{ 1, 2, 3 },
        }),
    );
    try testing.expectError(
        MemrefVerifyError.GlobalInvalidAlignment,
        MemrefDialect.GlobalOp.create(&ctx, loc, .{
            .sym_name = "table",
            .memref_type = word_type,
            .alignment = 3,
        }),
    );
}

test "memref global declarations and address computations declare their effects" {
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const loc = ir.Location.getUnknown();
    const u8_type = try arith.ArithDialect.getScalarType(&ctx, .u8);
    const arena_type = try MemrefDialect.getMemrefType1D(&ctx, 4096, u8_type, .host);

    const global = try MemrefDialect.GlobalOp.create(&ctx, loc, .{
        .sym_name = "arena",
        .memref_type = arena_type,
        .alignment = 16,
    });
    var global_facts = try effects.inspect(testing.allocator, global.op);
    defer global_facts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), global_facts.facts.records.len);
    try testing.expect(effects.memoryFree(global_facts.facts));
    try testing.expect(effects.total(global_facts.facts));

    const address = try MemrefDialect.GetGlobalOp.create(&ctx, loc, "arena", arena_type);
    var address_facts = try effects.inspect(testing.allocator, address.op);
    defer address_facts.deinit(testing.allocator);
    try testing.expect(effects.memoryFree(address_facts.facts));
    try testing.expect(effects.total(address_facts.facts));
    try testing.expectEqual(
        effects.Ownership.none,
        address_facts.facts.records[0].result.ownership,
    );
}

test "MemrefDialect.ViewOp offsets a byte base and refuses any other" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i64_type = try arith.ArithDialect.getScalarType(&ctx, .i64);
    const u8_type = try arith.ArithDialect.getScalarType(&ctx, .u8);
    const index_type = try arith.ArithDialect.getIndexType(&ctx);
    const word_type = try MemrefDialect.getMemrefType1D(&ctx, 1, i64_type, .host);
    const arena_type = try MemrefDialect.getMemrefType1D(&ctx, 4096, u8_type, .host);
    const words_type = try MemrefDialect.getMemrefType1D(&ctx, 4, i64_type, .host);

    var offset = try arith.ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 8);
    var bytes = try MemrefDialect.AllocaOp.createStatic(&ctx, loc, arena_type);
    const view = try MemrefDialect.ViewOp.create(
        &ctx,
        loc,
        bytes.getResult(),
        offset.getResult(),
        word_type,
    );
    try testing.expectEqualStrings("memref.view", view.op.name.name);
    try testing.expect(view.getBase() == bytes.getResult());
    try testing.expect(view.getByteOffset() == offset.getResult());
    try testing.expect(view.getResult().type.eql(word_type));

    var words = try MemrefDialect.AllocaOp.createStatic(&ctx, loc, words_type);
    try testing.expectError(MemrefVerifyError.ViewBaseNotBytes, MemrefDialect.ViewOp.create(
        &ctx,
        loc,
        words.getResult(),
        offset.getResult(),
        word_type,
    ));

    var view_facts = try effects.inspect(testing.allocator, view.op);
    defer view_facts.deinit(testing.allocator);
    try testing.expect(!view_facts.facts.complete);
    try testing.expectEqual(effects.EventKind.borrow, view_facts.facts.records[0].event.kind);
    try testing.expectEqual(
        @as(usize, 0),
        view_facts.facts.records[0].event.resource.subject.operand,
    );
    try testing.expectEqual(
        effects.Ownership.borrowed,
        view_facts.facts.records[1].result.ownership,
    );
    try testing.expectEqual(@as(usize, 0), view_facts.facts.records[1].result.alias.?.operand);
}
