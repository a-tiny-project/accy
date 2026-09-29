const std = @import("std");
const core = @import("../root.zig");
const Value = core.Value;
const OpOperand = core.OpOperand;
const Type = core.Type;
const Attribute = core.Attribute;
const NamedAttribute = core.NamedAttribute;
const NamedAttributeList = core.NamedAttributeList;
const Location = core.Location;
const Block = core.Block;
const Region = core.Region;
const diagnostics = @import("../../diagnostics/root.zig");
const operation_attributes = @import("attributes.zig");
const operation_lifecycle = @import("lifecycle.zig");
const operation_name = @import("name.zig");
const operation_properties = @import("properties.zig");
const operation_registered = @import("registration.zig");
const operation_state = @import("state.zig");
const operation_storage = @import("storage.zig");
const context_mod = @import("../context/root.zig");

pub const Context = context_mod.Context;

const LifecycleState = packed struct(u32) {
    creation_id: u31,
    successor_storage_owned: bool,
};

pub const Operation = struct {
    allocator: std.mem.Allocator,

    storage: operation_storage.Storage,

    operand_storage: ?operation_storage.Handle,

    context: *Context,

    name: OperationName,

    location: Location,

    operands: operation_storage.List(OpOperand),

    operand_values: []*Value,

    results: operation_storage.List(Value),

    result_types: []const Type,

    raw_dictionary_attrs: NamedAttributeList,

    properties: PropertyStorage,

    regions: operation_storage.List(Region),

    successors: operation_storage.List(*Block),

    parent_block: ?*Block,

    prev_op: ?*Operation,
    next_op: ?*Operation,

    order: u32,
    lifecycle_state: LifecycleState,

    tracking_prev: ?*Operation,
    tracking_next: ?*Operation,

    pub const WalkOrder = enum {
        pre_order,
        post_order,
    };

    pub const WalkResult = enum {
        advance,
        skip,
        interrupt,

        pub fn wasSkipped(self: WalkResult) bool {
            return self == .skip;
        }

        pub fn wasInterrupted(self: WalkResult) bool {
            return self == .interrupt;
        }
    };

    pub const WalkOptions = struct {
        order: WalkOrder = .post_order,
    };

    pub const PropertyRef: type = operation_properties.Ref;
    pub const PropertyStorage: type = operation_properties.Storage(Operation);
    pub const StoragePlan: type = operation_storage.Plan(
        Operation,
        *Value,
        Type,
        OpOperand,
        Value,
        Region,
        *Block,
    );
    const leaf_property_storage_capacity = StoragePlan.Capacity.derive(.{
        .operands = 0,
        .results = 1,
        .regions = 0,
        .successors = 0,
        .properties = @sizeOf(?Attribute),
        .properties_alignment = .fromByteUnits(@alignOf(?Attribute)),
    }) catch unreachable;
    const nullary_storage_capacity = StoragePlan.Capacity.derive(.{
        .operands = 0,
        .results = 1,
        .regions = 0,
        .successors = 0,
        .properties = 0,
        .properties_alignment = .@"1",
    }) catch unreachable;
    const unary_storage_capacity = StoragePlan.Capacity.derive(.{
        .operands = 1,
        .results = 1,
        .regions = 0,
        .successors = 0,
        .properties = 0,
        .properties_alignment = .@"1",
    }) catch unreachable;
    const binary_storage_capacity = StoragePlan.Capacity.derive(.{
        .operands = 2,
        .results = 1,
        .regions = 0,
        .successors = 0,
        .properties = 0,
        .properties_alignment = .@"1",
    }) catch unreachable;
    pub const StorageAllocator: type = operation_storage.PoolAllocator(
        leaf_property_storage_capacity,
        binary_storage_capacity,
        nullary_storage_capacity,
        unary_storage_capacity,
    );
    pub const OperationName: type = operation_name.OperationName;
    pub const CloneOptions = struct {
        clone_operands: bool = true,
    };
    pub const State: type = operation_state.State(Operation);
    const lifecycle = operation_lifecycle.Methods(Operation);
    pub const create = lifecycle.create;
    pub const cloneWithoutRegions = lifecycle.cloneWithoutRegions;
    pub const cloneWithoutRegionsMapped = lifecycle.cloneWithoutRegionsMapped;
    pub const clone = lifecycle.clone;
    pub const dropAllReferences = lifecycle.dropAllReferences;
    pub const hasNoDefinedValueUses = lifecycle.hasNoDefinedValueUses;
    pub const dropAllDefinedValueUses = lifecycle.dropAllDefinedValueUses;
    pub const removeFromBlock = lifecycle.removeFromBlock;
    pub const moveBefore = lifecycle.moveBefore;
    pub const moveToEnd = lifecycle.moveToEnd;
    pub const replaceOperands = lifecycle.replaceOperands;
    pub const deinit = lifecycle.deinit;
    pub const destroy = lifecycle.destroy;
    pub const setOperandValue = lifecycle.setOperandValue;
    pub const setSuccessors = lifecycle.setSuccessors;
    pub const erase = lifecycle.erase;
    const registered = operation_registered.Methods(Operation);
    pub const getRegisteredInfo = registered.getRegisteredInfo;
    pub const getInherentAttributeNames = registered.getInherentAttributeNames;
    pub const hasInherentAttributeName = registered.hasInherentAttributeName;
    pub const isDiscardableAttrName = registered.isDiscardableAttrName;
    pub const isRegistered = registered.isRegistered;
    pub const getInterface = registered.getInterface;
    pub const interface_handle = registered.InterfaceHandle;
    pub const interface = registered.interface;
    pub const hasInterface = registered.hasInterface;
    pub const getTraits = registered.getTraits;
    pub const hasTrait = registered.hasTrait;
    pub const hasTraitId = registered.hasTraitId;
    pub const hasTraitName = registered.hasTraitName;
    const attributes = operation_attributes.Methods(Operation);
    pub const AttributeIterator: type = attributes.AttributeIterator;
    pub const DiscardableAttrIterator: type = attributes.DiscardableAttrIterator;
    pub const SetDiscardableAttrError: type = attributes.SetDiscardableAttrError;
    pub const getAttrs = attributes.getAttrs;
    pub const getNumAttrs = attributes.getNumAttrs;
    pub const getRawDictionaryAttrs = attributes.getRawDictionaryAttrs;
    pub const getDiscardableAttrs = attributes.getDiscardableAttrs;
    pub const countDiscardableAttrs = attributes.countDiscardableAttrs;
    pub const getDiscardableAttr = attributes.getDiscardableAttr;
    pub const getDiscardableAttrAs = attributes.getDiscardableAttrAs;
    pub const setDiscardableAttr = attributes.setDiscardableAttr;
    pub const removeDiscardableAttr = attributes.removeDiscardableAttr;
    pub const getAttr = attributes.getAttr;
    pub const getAttrAs = attributes.getAttrAs;
    pub const setAttr = attributes.setAttr;
    pub const removeAttr = attributes.removeAttr;
    pub const getPropertiesAsAttr = attributes.getPropertiesAsAttr;
    pub const getPropertiesRef = attributes.getPropertiesRef;
    pub const setPropertiesFromAttr = attributes.setPropertiesFromAttr;
    pub const copyProperties = attributes.copyProperties;

    pub fn walk(
        self: *Operation,
        options: WalkOptions,
        context: anytype,
        callback: anytype,
    ) anyerror!WalkResult {
        return walkOperation(self, options, context, callback);
    }

    fn walkOperation(
        op: *Operation,
        options: WalkOptions,
        context: anytype,
        callback: anytype,
    ) anyerror!WalkResult {
        if (options.order == .pre_order) {
            const result = try invokeWalkCallback(context, callback, op);
            if (result.wasInterrupted()) return .interrupt;
            if (result.wasSkipped()) return .advance;
        }

        for (op.regions.items) |*region| {
            const result = try region.walkOperations(options, context, callback);
            if (result.wasInterrupted()) return .interrupt;
        }

        if (options.order == .post_order) {
            return try invokeWalkCallback(context, callback, op);
        }

        return .advance;
    }

    fn invokeWalkCallback(context: anytype, callback: anytype, op: *Operation) anyerror!WalkResult {
        const result = callback(context, op);
        return try normalizeWalkResult(result);
    }

    fn normalizeWalkResult(result: anytype) anyerror!WalkResult {
        const Result = @TypeOf(result);
        return switch (@typeInfo(Result)) {
            .error_union => |info| blk: {
                const payload = try result;
                if (info.payload == void) break :blk .advance;
                break :blk payload;
            },
            .void => .advance,
            else => result,
        };
    }

    pub fn getName(self: Operation) OperationName {
        return self.name;
    }

    pub fn getLoc(self: Operation) Location {
        return self.location;
    }

    pub fn createdBefore(self: Operation, boundary: u31) bool {
        return self.lifecycle_state.creation_id < boundary;
    }

    pub fn setCreationId(self: *Operation, creation_id: u31) void {
        self.lifecycle_state.creation_id = creation_id;
    }

    pub fn getNumOperands(self: Operation) usize {
        return self.operands.items.len;
    }

    pub fn getOperand(self: Operation, index: usize) ?*Value {
        if (index >= self.operand_values.len) return null;
        return self.operand_values[index];
    }

    pub fn getOpOperand(self: *Operation, index: usize) ?*OpOperand {
        if (index >= self.operands.items.len) return null;
        return &self.operands.items[index];
    }

    pub fn getNumResults(self: Operation) usize {
        return self.result_types.len;
    }

    pub fn getResult(self: *Operation, index: usize) ?*Value {
        if (index >= self.results.items.len) return null;
        return &self.results.items[index];
    }

    pub fn getOperandValues(self: Operation) []const *Value {
        return self.operand_values;
    }

    pub fn getResultTypes(self: Operation) []const Type {
        return self.result_types;
    }

    pub fn getNumRegions(self: Operation) usize {
        return self.regions.items.len;
    }

    pub fn getRegion(self: *Operation, index: usize) ?*Region {
        if (index >= self.regions.items.len) return null;
        return &self.regions.items[index];
    }

    pub fn getNumSuccessors(self: Operation) usize {
        return self.successors.items.len;
    }

    pub fn getSuccessor(self: Operation, index: usize) ?*Block {
        if (index >= self.successors.items.len) return null;
        return self.successors.items[index];
    }

    pub fn getBlock(self: Operation) ?*Block {
        return self.parent_block;
    }

    pub fn getParentRegion(self: *const Operation) ?*Region {
        const block = self.parent_block orelse return null;
        return block.getParentRegion();
    }

    pub fn getParentOp(self: *const Operation) ?*Operation {
        const region = self.getParentRegion() orelse return null;
        return region.getParentOperation();
    }

    pub fn isProperAncestor(self: *const Operation, other: *const Operation) bool {
        var current = other.getParentOp();
        while (current) |op| {
            if (op == self) return true;
            current = op.getParentOp();
        }
        return false;
    }

    pub fn isAncestor(self: *const Operation, other: *const Operation) bool {
        return self == other or self.isProperAncestor(other);
    }

    pub fn isBeforeInBlock(self: *const Operation, other: *const Operation) bool {
        const block = self.parent_block orelse return false;
        if (other.parent_block != block) return false;
        if (self == other) return false;

        return block.operationPrecedes(self, other);
    }

    pub fn getContext(self: *const Operation) *Context {
        return self.context;
    }

    pub fn emitDiagnostic(
        self: *Operation,
        severity: diagnostics.Severity,
        message: []const u8,
    ) Context.InFlightDiagnostic {
        return self.context.emitDiagnostic(diagnostics.operationDiagnostic(self, severity, message));
    }

    pub fn emitError(self: *Operation, message: []const u8) Context.InFlightDiagnostic {
        return self.emitDiagnostic(.err, message);
    }

    pub fn emitWarning(self: *Operation, message: []const u8) Context.InFlightDiagnostic {
        return self.emitDiagnostic(.warning, message);
    }

    pub fn emitRemark(self: *Operation, message: []const u8) Context.InFlightDiagnostic {
        return self.emitDiagnostic(.remark, message);
    }

    pub fn emitOpError(self: *Operation, message: []const u8) !Context.InFlightDiagnostic {
        const full_message = try std.fmt.allocPrint(
            context_mod.diagnosticPayloadAllocator(self.context),
            "'{s}' op {s}",
            .{ self.name.name, message },
        );
        var diagnostic = self.emitError(full_message);
        diagnostic.ownMessage(full_message);
        return diagnostic;
    }

    pub fn hasNoUses(self: Operation) bool {
        for (self.results.items) |result| {
            if (!result.hasNoUses()) {
                return false;
            }
        }
        return true;
    }

    pub fn hasOneUse(self: Operation) bool {
        if (self.results.items.len == 0) return false;
        for (self.results.items) |result| {
            if (!result.hasOneUse()) {
                return false;
            }
        }
        return true;
    }

    pub fn format(self: Operation, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.results.items.len > 0) {
            for (self.results.items, 0..) |result, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{f}", .{result});
            }
            try writer.writeAll(" = ");
        }

        try writer.print("{f}", .{self.name});

        if (self.operands.items.len > 0) {
            try writer.writeAll("(");
            for (self.operands.items, 0..) |operand, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{f}", .{operand.value.*});
            }
            try writer.writeAll(")");
        } else {
            try writer.writeAll("()");
        }

        try self.formatAttrs(writer);

        if (self.results.items.len > 0) {
            try writer.writeAll(" : ");
            for (self.results.items, 0..) |result, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{f}", .{result.type});
            }
        }

        for (self.regions.items) |region| {
            try writer.writeAll(" ");
            try writer.print("{f}", .{region});
        }
    }

    fn formatAttrs(self: *const Operation, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var attrs = self.getAttrs();
        var first = true;
        while (attrs.next()) |attr| {
            try formatAttr(writer, &first, attr);
        }

        if (!first) try writer.writeAll("}");
    }

    fn formatAttr(
        writer: *std.Io.Writer,
        first: *bool,
        attr: NamedAttribute,
    ) std.Io.Writer.Error!void {
        if (first.*) {
            try writer.writeAll(" {");
            first.* = false;
        } else {
            try writer.writeAll(", ");
        }
        try writer.print("{f}", .{attr});
    }
};

test "operation lifecycle identity retains the 64-bit header footprint" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 4), @sizeOf(LifecycleState));
    if (@sizeOf(usize) == 8) {
        try testing.expectEqual(@as(usize, 568), @sizeOf(Operation));
        try testing.expectEqual(@as(usize, 560), @offsetOf(Operation, "order"));
    }
}
test "common operation storage classes match profiled layouts" {
    try std.testing.expectEqual(
        @as(usize, 672),
        Operation.leaf_property_storage_capacity.total_bytes,
    );
    try std.testing.expectEqual(@as(usize, 640), Operation.nullary_storage_capacity.total_bytes);
    try std.testing.expectEqual(@as(usize, 696), Operation.unary_storage_capacity.total_bytes);
    try std.testing.expectEqual(@as(usize, 752), Operation.binary_storage_capacity.total_bytes);
    try std.testing.expectEqual(
        std.mem.Alignment.@"8",
        Operation.leaf_property_storage_capacity.allocation_alignment,
    );
    try std.testing.expectEqual(
        std.mem.Alignment.@"8",
        Operation.nullary_storage_capacity.allocation_alignment,
    );
    try std.testing.expectEqual(
        std.mem.Alignment.@"8",
        Operation.unary_storage_capacity.allocation_alignment,
    );
    try std.testing.expectEqual(
        std.mem.Alignment.@"8",
        Operation.binary_storage_capacity.allocation_alignment,
    );
    try std.testing.expectEqual(@as(usize, 21_520), Operation.StorageAllocator.first_chunk_bytes);
    try std.testing.expectEqual(@as(usize, 24_080), Operation.StorageAllocator.second_chunk_bytes);
    try std.testing.expectEqual(@as(usize, 20_496), Operation.StorageAllocator.third_chunk_bytes);
    try std.testing.expectEqual(@as(usize, 22_288), Operation.StorageAllocator.fourth_chunk_bytes);
}
