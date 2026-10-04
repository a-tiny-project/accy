const std = @import("std");
const alloc_arena = @import("alloc_arena");
const Operation = @import("operation/root.zig").Operation;
const Block = @import("block.zig").Block;
const Region = @import("region.zig").Region;
const Location = @import("location.zig").Location;
const Value = @import("value.zig").Value;
const OpOperand = @import("value.zig").OpOperand;
const Attribute = @import("attribute.zig").Attribute;
const cfg = @import("cfg.zig");
const interfaces = @import("interfaces/root.zig");
const trait_definitions = @import("traits.zig");
const context_mod = @import("context/root.zig");
const structure_item_limit = 1_000_000;

pub const VerifyError = error{
    OutOfMemory,
    ParentBlockMismatch,
    OperationListCorrupted,
    SuccessorPredecessorMismatch,
    SuccessorRegionMismatch,
    EntryBlockSuccessor,
    RegionParentMismatch,
    UseDefChainBroken,
    BlockParentMismatch,
    BlockListCorrupted,
    BlockArgumentOwnerMismatch,
    RegionParentOpMismatch,
    RegionSizeMismatch,
    MissingTerminator,
    OperationAfterTerminator,
    InvalidPredecessor,
    UseChainValueMismatch,
    UseChainCycle,
    InvalidLocalDominance,
    OperandCountMismatch,
    ResultCountMismatch,
    RegionCountMismatch,
    SuccessorCountMismatch,
    InvalidOperandSegmentSizeAttribute,
    InvalidResultSegmentSizeAttribute,
    OperandSegmentSizeMismatch,
    ResultSegmentSizeMismatch,
    MissingRequiredAttribute,
    OperandTypeConstraintMismatch,
    ResultTypeConstraintMismatch,
    GraphRegionMultipleBlocks,
};

pub const VerifyOptions = struct {
    check_terminators: bool = false,

    require_terminators: bool = false,

    recursive: bool = true,

    check_use_def: bool = true,

    check_local_dominance: bool = true,

    check_cfg: bool = true,

    max_depth: usize = 0,
};

pub const default_options = VerifyOptions{
    .check_terminators = true,
    .recursive = true,
    .check_use_def = true,
    .check_local_dominance = true,
    .check_cfg = true,
};

pub fn verifyOperationStructure(op: *Operation, options: VerifyOptions) VerifyError!void {
    return verifyStructureWithDepth(.{ .operation = op }, options, 0, null);
}

const StructureTarget = union(enum) {
    operation: *Operation,
    region: *Region,
    block: *Block,
};

fn verifyStructureWithDepth(
    target: StructureTarget,
    options: VerifyOptions,
    depth: usize,
    known_region_ssa_dominance: ?bool,
) VerifyError!void {
    if (options.max_depth > 0 and depth >= options.max_depth) {
        return;
    }

    switch (target) {
        .operation => |op| {
            if (options.check_use_def) {
                for (op.operands.items) |*operand| {
                    try verifyOperandUse(operand);
                }
            }

            if (options.check_local_dominance) {
                const may_have_ssa_dominance = known_region_ssa_dominance orelse block: {
                    const parent_block = op.parent_block orelse break :block true;
                    break :block blockMayHaveSSADominance(parent_block);
                };
                for (op.operands.items) |operand| {
                    try verifyOperandLocalDominance(op, operand.value, may_have_ssa_dominance);
                }
            }

            if (options.check_cfg) {
                try verifyOperationSuccessors(op);
            }

            for (op.regions.items) |*region| {
                const expected_parent: *anyopaque = @ptrCast(op);
                if (region.parent != expected_parent) {
                    return error.RegionParentMismatch;
                }

                if (options.recursive) {
                    try verifyStructureWithDepth(.{ .region = region }, options, depth + 1, null);
                }
            }
        },
        .region => |region| {
            const may_have_ssa_dominance = if (options.check_local_dominance)
                regionMayHaveSSADominance(region)
            else
                null;
            var actual_count: usize = 0;
            var current = region.blocks.head;
            var prev_block: ?*Block = null;

            while (current) |block| {
                actual_count += 1;

                if (actual_count > structure_item_limit) {
                    return error.BlockListCorrupted;
                }

                if (block.parent != @as(*anyopaque, @ptrCast(region))) {
                    return error.BlockParentMismatch;
                }

                if (block.prev != prev_block) {
                    return error.BlockListCorrupted;
                }

                if (options.recursive) {
                    try verifyStructureWithDepth(.{ .block = block }, options, depth, may_have_ssa_dominance);
                }

                prev_block = block;
                current = block.next;
            }

            if (actual_count != region.blocks.size) {
                return error.RegionSizeMismatch;
            }

            if (actual_count > 1 and regionKind(region) == .graph) {
                return error.GraphRegionMultipleBlocks;
            }

            if (options.check_cfg and regionKind(region) == .ssacfg) {
                if (region.getEntryBlock()) |entry| {
                    if (entry.predecessors.items.len != 0) return error.EntryBlockSuccessor;
                }
            }

            if (region.blocks.tail != prev_block) {
                return error.BlockListCorrupted;
            }
        },
        .block => |block| {
            if (options.check_local_dominance) _ = block.sealOperationOrder();
            const may_have_ssa_dominance = if (options.check_local_dominance)
                known_region_ssa_dominance orelse blockMayHaveSSADominance(block)
            else
                null;
            for (block.arguments.items) |arg| {
                if (arg.kind == .block_argument) {
                    const owner: *Block = @ptrCast(@alignCast(arg.kind.block_argument.owner));
                    if (owner != block) {
                        return error.BlockArgumentOwnerMismatch;
                    }
                }
            }

            if (!block.operations.isEmpty()) {
                const head: *Operation = @ptrCast(@alignCast(block.operations.head.?));
                const tail: *Operation = @ptrCast(@alignCast(block.operations.tail.?));

                if (head.prev_op != null) {
                    return error.OperationListCorrupted;
                }

                if (tail.next_op != null) {
                    return error.OperationListCorrupted;
                }

                var op: ?*Operation = head;
                var prev: ?*Operation = null;
                var saw_terminator = false;
                var count: usize = 0;

                while (op) |current| {
                    count += 1;

                    if (count > structure_item_limit) {
                        return error.OperationListCorrupted;
                    }

                    if (current.parent_block != block) {
                        return error.ParentBlockMismatch;
                    }

                    if (current.prev_op != prev) {
                        return error.OperationListCorrupted;
                    }

                    if (options.check_terminators) {
                        if (saw_terminator) {
                            return error.OperationAfterTerminator;
                        }
                        if (current.getTraits().is_terminator) {
                            saw_terminator = true;
                        }
                    }

                    if (options.recursive) {
                        try verifyStructureWithDepth(.{ .operation = current }, options, depth, may_have_ssa_dominance);
                    }

                    prev = current;
                    op = current.next_op;
                }

                if (prev != tail) {
                    return error.OperationListCorrupted;
                }

                if (options.check_terminators and
                    options.require_terminators and
                    count > 0 and
                    !saw_terminator and
                    !blockAllowsMissingTerminator(block))
                {
                    return error.MissingTerminator;
                }
            }

            if (options.check_cfg) {
                try verifyPredecessors(block);
            }
        },
    }
}

fn verifyOperationSuccessors(op: *Operation) VerifyError!void {
    const parent = op.parent_block orelse return;
    const parent_region = blockParentRegion(parent);

    for (op.successors.items) |successor| {
        if (!successor.hasPredecessor(parent)) {
            return error.SuccessorPredecessorMismatch;
        }

        const region = parent_region orelse continue;
        const successor_region = blockParentRegion(successor) orelse return error.SuccessorRegionMismatch;
        if (successor_region != region) {
            return error.SuccessorRegionMismatch;
        }
        if (regionKind(region) == .ssacfg and region.getEntryBlock() == successor) {
            return error.EntryBlockSuccessor;
        }
    }
}

fn verifyOperandUse(operand: *const OpOperand) VerifyError!void {
    const back = operand.back orelse return error.UseDefChainBroken;
    const linked = back.* orelse return error.UseDefChainBroken;
    if (linked != operand) {
        return error.UseDefChainBroken;
    }
    if (operand.next_use) |next| {
        const next_back = next.back orelse return error.UseDefChainBroken;
        if (next_back != &linked.next_use) {
            return error.UseDefChainBroken;
        }
        if (next.value != operand.value) {
            return error.UseChainValueMismatch;
        }
    }
}

fn verifyOperandLocalDominance(user: *const Operation, value: *const Value, may_have_ssa_dominance: bool) VerifyError!void {
    const user_block = user.parent_block orelse return;
    return switch (value.kind) {
        .block_argument => |info| {
            const defining_block: *const Block = @ptrCast(@alignCast(info.owner));
            try verifyBlockDominatesUse(defining_block, user_block, may_have_ssa_dominance);
        },
        .op_result => |info| {
            const defining_op: *const Operation = @ptrCast(@alignCast(info.owner));
            const defining_block = defining_op.parent_block orelse return;
            if (user_block != defining_block) {
                return verifyBlockDominatesUse(defining_block, user_block, may_have_ssa_dominance);
            }
            if (defining_op == user) return error.InvalidLocalDominance;
            if (!may_have_ssa_dominance) return;

            if (!defining_op.isBeforeInBlock(user)) {
                return error.InvalidLocalDominance;
            }
            return;
        },
    };
}

fn verifyBlockDominatesUse(defining_block: *const Block, user_block: *const Block, may_have_ssa_dominance: bool) VerifyError!void {
    if (defining_block == user_block) return;
    const defining_region = blockParentRegion(defining_block) orelse return;
    const user_region = blockParentRegion(user_block) orelse return;
    if (defining_region != user_region) return;
    if (!may_have_ssa_dominance) return;
    if (!try blockDominates(defining_region, defining_block, user_block)) {
        return error.InvalidLocalDominance;
    }
}

fn blockMayHaveSSADominance(block: *const Block) bool {
    const region = block.getParentRegion() orelse return true;
    return regionMayHaveSSADominance(region);
}

fn blockParentRegion(block: *const Block) ?*const Region {
    return block.getParentRegion();
}

pub fn regionMayHaveSSADominance(region: *const Region) bool {
    const parent_op = regionParentOperation(region) orelse return true;
    const index = regionIndex(parent_op, region) orelse return true;
    if (parent_op.getInterface(interfaces.RegionKindInterface)) |vtable| {
        return vtable.hasSSADominance(@ptrCast(parent_op), index);
    }
    return !parent_op.getTraits().has_only_graph_regions;
}

pub fn regionKind(region: *const Region) interfaces.RegionKind {
    const parent_op = regionParentOperation(region) orelse return .ssacfg;
    const index = regionIndex(parent_op, region) orelse return .ssacfg;
    if (parent_op.getInterface(interfaces.RegionKindInterface)) |vtable| {
        return vtable.getRegionKind(@ptrCast(parent_op), index);
    }
    if (parent_op.getTraits().has_only_graph_regions) return .graph;
    return .ssacfg;
}

fn regionParentOperation(region: *const Region) ?*Operation {
    return region.getParentOperation();
}

fn regionIndex(parent_op: *Operation, region: *const Region) ?usize {
    for (parent_op.regions.items, 0..) |*candidate, index| {
        if (candidate == region) return index;
    }
    return null;
}

fn blockDominates(region: *const Region, defining_block: *const Block, user_block: *const Block) VerifyError!bool {
    const entry = region.getEntryBlock() orelse return false;
    if (entry == defining_block) return true;
    if (entry == user_block) return false;

    var visited: std.AutoHashMap(*const Block, void) = .init(region.allocator);
    defer visited.deinit();
    var stack: std.ArrayList(*const Block) = .empty;
    defer stack.deinit(region.allocator);

    try visited.put(entry, {});
    try stack.append(region.allocator, entry);

    while (stack.pop()) |block| {
        const terminator_any = block.getTerminator() orelse continue;
        const terminator: *const Operation = @ptrCast(@alignCast(terminator_any));
        for (terminator.successors.items) |successor| {
            if (successor == defining_block) continue;
            if (successor == user_block) return false;
            if (blockParentRegion(successor) != region) continue;
            const gop = try visited.getOrPut(successor);
            if (!gop.found_existing) try stack.append(region.allocator, successor);
        }
    }

    return true;
}

pub fn verifyBlockStructure(block: *Block, options: VerifyOptions) VerifyError!void {
    return verifyStructureWithDepth(.{ .block = block }, options, 0, null);
}

fn blockAllowsMissingTerminator(block: *const Block) bool {
    const region = block.getParentRegion() orelse return false;
    if (!region.hasOneBlock()) return false;
    const parent_op = region.getParentOperation() orelse return false;
    return parent_op.getTraits().has_no_terminator;
}

fn verifyPredecessors(block: *Block) VerifyError!void {
    const region = blockParentRegion(block);
    for (block.predecessors.items, 0..) |pred, index| {
        for (block.predecessors.items[0..index]) |prior| {
            if (prior == pred) return error.InvalidPredecessor;
        }
        if (blockParentRegion(pred) != region) {
            return error.SuccessorRegionMismatch;
        }
        if (!try cfg.containsBounded(
            pred,
            block,
            structure_item_limit,
        )) return error.InvalidPredecessor;
    }
}

pub fn verifyRegionStructure(region: *Region, options: VerifyOptions) VerifyError!void {
    return verifyStructureWithDepth(.{ .region = region }, options, 0, null);
}

pub fn verifyOperation(op: *Operation, options: VerifyOptions) !void {
    try verifyOperationStructure(op, options);
    try runOperationVerifiers(op, options);
}

pub fn verifyBlock(block: *Block, options: VerifyOptions) VerifyError!void {
    return verifyBlockStructure(block, options);
}

pub fn verifyRegion(region: *Region, options: VerifyOptions) VerifyError!void {
    return verifyRegionStructure(region, options);
}

pub fn verify(op: *Operation, options: VerifyOptions) !void {
    return verifyOperation(op, options);
}

pub fn verifyValue(value: *const Value) VerifyError!void {
    var slow = value.first_use;
    var fast = value.first_use;
    var count: usize = 0;

    while (slow) |use| {
        count += 1;

        if (use.value != value) {
            return error.UseChainValueMismatch;
        }

        slow = use.next_use;

        if (fast) |f| {
            fast = f.next_use;
            if (fast) |ff| fast = ff.next_use;
        }
        if (slow != null and slow == fast) {
            return error.UseChainCycle;
        }

        if (count > structure_item_limit) {
            return error.UseChainCycle;
        }
    }
}

pub const VerifyOpInterface = struct {
    pub const interface_name = "ir.interface.verify_op";
    pub const id: interfaces.InterfaceId = interfaces.interfaceId(interface_name);

    pub const VTable = struct {
        verify: *const fn (op_ptr: *const anyopaque) anyerror!void,
    };

    pub fn entry(vtable: *const VTable) interfaces.InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(comptime verify_fn: *const fn (op_ptr: *const anyopaque) anyerror!void) *const VTable {
        return &.{ .verify = verify_fn };
    }

    pub fn entryFor(comptime verify_fn: *const fn (op_ptr: *const anyopaque) anyerror!void) interfaces.InterfaceEntry {
        return entry(vtableFor(verify_fn));
    }
};

pub const VerifyRegionOpInterface = struct {
    pub const interface_name = "ir.interface.verify_region_op";
    pub const id: interfaces.InterfaceId = interfaces.interfaceId(interface_name);

    pub const VTable = struct {
        verify: *const fn (op_ptr: *const anyopaque) anyerror!void,
    };

    pub fn entry(vtable: *const VTable) interfaces.InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(comptime verify_fn: *const fn (op_ptr: *const anyopaque) anyerror!void) *const VTable {
        return &.{ .verify = verify_fn };
    }

    pub fn entryFor(comptime verify_fn: *const fn (op_ptr: *const anyopaque) anyerror!void) interfaces.InterfaceEntry {
        return entry(vtableFor(verify_fn));
    }
};

fn resolveOpInfo(op: *Operation) ?*const interfaces.OperationInfo {
    return op.getRegisteredInfo();
}

fn test_segment_attribute(context: anytype, comptime values: []const i64) !Attribute {
    var attributes: [values.len]Attribute = undefined;
    for (values, 0..) |value, index| {
        attributes[index] = try context.getI64Attr(value);
    }
    return context.getArrayAttr(attributes[0..]);
}

pub fn runTraitVerifiers(op: *Operation) !void {
    const info = resolveOpInfo(op) orelse return;
    for (info.getDynamicTraitIds()) |trait_id| {
        const vtable = op.context.lookupTrait(trait_id) orelse continue;
        if (vtable.verify) |verify_fn| {
            try verify_fn(@ptrCast(op));
        }
    }
}

pub fn runRegionTraitVerifiers(op: *Operation) !void {
    return runRegionTraitVerifiersWithIsolation(op, null);
}

const IsolationFrame = struct {
    root: *const Operation,
    invalid: bool = false,
};

fn runRegionTraitVerifiersWithIsolation(op: *Operation, isolation: ?*const IsolationFrame) !void {
    const info = resolveOpInfo(op) orelse return;
    for (info.getDynamicTraitIds()) |trait_id| {
        const vtable = op.context.lookupTrait(trait_id) orelse continue;
        if (trait_id == trait_definitions.IsolatedFromAbove.id and vtable == &trait_definitions.IsolatedFromAbove.vtable) {
            if (isolation) |frame| {
                if (frame.invalid) return trait_definitions.TraitError.IsolatedFromAbove;
                continue;
            }
        }
        if (vtable.verify_regions) |verify_fn| {
            try verify_fn(@ptrCast(op));
        }
    }
}

pub fn verifyRegisteredOperationShape(op: *Operation) VerifyError!void {
    const info = resolveOpInfo(op) orelse return;
    const shape = info.shape;
    if (!shape.hasConstraints()) return;

    if (!shape.operands.allows(op.operands.items.len)) {
        return error.OperandCountMismatch;
    }
    if (!shape.results.allows(op.results.items.len)) {
        return error.ResultCountMismatch;
    }
    if (!shape.regions.allows(op.regions.items.len)) {
        return error.RegionCountMismatch;
    }
    if (!shape.successors.allows(op.successors.items.len)) {
        return error.SuccessorCountMismatch;
    }
}

pub fn verifyRegisteredOperationRequiredAttributes(op: *Operation) VerifyError!void {
    const info = resolveOpInfo(op) orelse return;
    for (info.getRequiredAttributeNames()) |attr_name| {
        if (op.getAttr(attr_name) == null) return error.MissingRequiredAttribute;
    }
}

pub fn verifyRegisteredOperationSegments(op: *Operation) VerifyError!void {
    const info = resolveOpInfo(op) orelse return;
    if (info.getOperandSegments()) |segment_spec| {
        try verifyRegisteredOperationSegmentSpec(
            op,
            segment_spec,
            op.operands.items.len,
            error.InvalidOperandSegmentSizeAttribute,
            error.OperandSegmentSizeMismatch,
        );
    }
    if (info.getResultSegments()) |segment_spec| {
        try verifyRegisteredOperationSegmentSpec(
            op,
            segment_spec,
            op.results.items.len,
            error.InvalidResultSegmentSizeAttribute,
            error.ResultSegmentSizeMismatch,
        );
    }
}

fn verifyRegisteredOperationSegmentSpec(
    op: *Operation,
    segment_spec: interfaces.OperationSegmentSpec,
    actual_count: usize,
    invalid_error: VerifyError,
    mismatch_error: VerifyError,
) VerifyError!void {
    const attr = op.getAttrAs(Attribute.ArrayAttr, segment_spec.attribute_name) orelse return invalid_error;
    const values = attr.getValues();
    if (values.len != segment_spec.segments.len) return invalid_error;

    var total: usize = 0;
    for (values, segment_spec.segments) |value, range| {
        const int_attr = value.cast(Attribute.IntegerAttr) orelse return invalid_error;
        const size = std.math.cast(usize, int_attr.getValue()) orelse return invalid_error;
        if (!range.allows(size)) return mismatch_error;
        total = std.math.add(usize, total, size) catch return mismatch_error;
    }

    if (total != actual_count) return mismatch_error;
}

pub fn verifyRegisteredOperationTypeConstraints(op: *Operation) VerifyError!void {
    const info = resolveOpInfo(op) orelse return;
    for (info.getOperandTypeConstraints()) |constraint| {
        if (constraint.index >= op.operands.items.len) return error.OperandTypeConstraintMismatch;
        if (!operationTypeConstraintAllows(constraint, op.operands.items[constraint.index].value.type)) {
            return error.OperandTypeConstraintMismatch;
        }
    }
    for (info.getResultTypeConstraints()) |constraint| {
        if (constraint.index >= op.results.items.len) return error.ResultTypeConstraintMismatch;
        if (!operationTypeConstraintAllows(constraint, op.results.items[constraint.index].type)) {
            return error.ResultTypeConstraintMismatch;
        }
    }
}

fn operationTypeConstraintAllows(constraint: interfaces.OperationTypeConstraint, typ: @import("type.zig").Type) bool {
    const type_name = typ.getDialectTypeName() orelse return false;
    if (!std.mem.eql(u8, type_name, constraint.type_name)) return false;
    return constraint.allow_parameterized or typ.getDialectParamKey() == null;
}

fn runOperationVerifiers(op: *Operation, options: VerifyOptions) !void {
    return runOperationVerifiersWithinIsolation(op, options, null);
}

fn runOperationVerifiersWithinIsolation(op: *Operation, options: VerifyOptions, active_isolation: ?*IsolationFrame) !void {
    if (active_isolation) |frame| {
        trait_definitions.verifyOperandsWithin(frame.root, op) catch |err| switch (err) {
            trait_definitions.TraitError.IsolatedFromAbove => frame.invalid = true,
            else => return err,
        };
    }

    try verifyRegisteredOperationShape(op);
    try verifyRegisteredOperationSegments(op);
    try verifyRegisteredOperationRequiredAttributes(op);
    try verifyRegisteredOperationTypeConstraints(op);
    try interfaces.effects.verify(op);
    try runTraitVerifiers(op);

    if (op.getInterface(VerifyOpInterface)) |vtable| {
        try vtable.verify(@ptrCast(op));
    }

    const info = resolveOpInfo(op);
    const starts_isolation = if (info) |registered|
        registered.hasTraitId(trait_definitions.IsolatedFromAbove.id) and
            op.context.lookupTrait(trait_definitions.IsolatedFromAbove.id) == &trait_definitions.IsolatedFromAbove.vtable
    else
        false;
    var isolation = IsolationFrame{ .root = op };
    const nested_isolation = if (starts_isolation) &isolation else active_isolation;

    if (options.recursive) {
        for (op.regions.items) |*region| {
            var block_iter = region.getBlocks();
            while (block_iter.next()) |block| {
                var op_node: ?*anyopaque = block.operations.head;
                while (op_node) |node| {
                    const nested_op: *Operation = @ptrCast(@alignCast(node));
                    try runOperationVerifiersWithinIsolation(nested_op, options, nested_isolation);
                    op_node = nested_op.next_op;
                }
            }
        }
    }

    if (options.recursive) {
        try runRegionTraitVerifiersWithIsolation(op, if (starts_isolation) &isolation else null);

        if (op.getInterface(VerifyRegionOpInterface)) |vtable| {
            try vtable.verify(@ptrCast(op));
        }
    }
}

test "verify empty operation" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const state = Operation.State.init("test.empty", .unknown);
    const op = try ctx.createOperation(state);

    try verifyOperation(op, default_options);
}

test "verify operation with result" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const ty = try ctx.getDialectTypeFromName("test.i32");
    var state = Operation.State.init("test.const", .unknown);
    state.addTypes(&.{ty});

    const op = try ctx.createOperation(state);
    try verifyOperation(op, default_options);
}

test "verify operation with operand use-def chain" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const ty = try ctx.getDialectTypeFromName("test.i32");

    var producer_state = Operation.State.init("test.producer", .unknown);
    producer_state.addTypes(&.{ty});
    const producer = try ctx.createOperation(producer_state);

    const result = producer.getResult(0).?;
    var consumer_state = Operation.State.init("test.consumer", .unknown);
    consumer_state.addOperands(&.{result});
    const consumer = try ctx.createOperation(consumer_state);

    try verifyOperation(producer, default_options);
    try verifyOperation(consumer, default_options);
}

test "verify block with operations" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var block = Block.init(testing.allocator);
    defer block.deinit();

    const state1 = Operation.State.init("test.op1", .unknown);
    const op1 = try ctx.createOperation(state1);
    try block.addOperation(op1);

    const state2 = Operation.State.init("test.op2", .unknown);
    const op2 = try ctx.createOperation(state2);
    try block.addOperation(op2);

    var options = default_options;
    options.check_terminators = false;
    try verifyBlock(&block, options);
}

test "verify region with blocks" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var region = context_mod.initRegion(&ctx);
    defer region.deinit();

    _ = try region.addBlock();
    _ = try region.addBlock();

    var options = default_options;
    options.check_terminators = false;
    try verifyRegion(&region, options);

    try testing.expectEqual(@as(usize, 2), region.blocks.size);
}

test "verify use-def chain consistency" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const ty = try ctx.getDialectTypeFromName("test.i32");

    var producer_state = Operation.State.init("test.producer", .unknown);
    producer_state.addTypes(&.{ty});
    const producer = try ctx.createOperation(producer_state);

    const result = producer.getResult(0).?;

    var consumer1_state = Operation.State.init("test.consumer1", .unknown);
    consumer1_state.addOperands(&.{result});
    const consumer1 = try ctx.createOperation(consumer1_state);

    var consumer2_state = Operation.State.init("test.consumer2", .unknown);
    consumer2_state.addOperands(&.{result});
    _ = try ctx.createOperation(consumer2_state);

    try verifyValue(result);

    try testing.expectEqual(@as(usize, 2), result.getNumUses());

    try verifyOperandUse(consumer1.getOpOperand(0).?);
}

test "verify accepts same-block use after definition" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var block = Block.init(testing.allocator);
    defer block.deinit();

    const ty = try ctx.getDialectTypeFromName("test.i32");
    var producer_state = Operation.State.init("test.producer", .unknown);
    producer_state.addTypes(&.{ty});
    const producer = try ctx.createOperation(producer_state);
    try block.addOperation(producer);

    var consumer_state = Operation.State.init("test.consumer", .unknown);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    const consumer = try ctx.createOperation(consumer_state);
    try block.addOperation(consumer);

    var options = default_options;
    options.check_terminators = false;
    try verifyBlock(&block, options);
}

test "verify detects same-block use before definition" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var block = Block.init(testing.allocator);
    defer block.deinit();

    const ty = try ctx.getDialectTypeFromName("test.i32");
    var producer_state = Operation.State.init("test.producer", .unknown);
    producer_state.addTypes(&.{ty});
    const producer = try ctx.createOperation(producer_state);

    var consumer_state = Operation.State.init("test.consumer", .unknown);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    const consumer = try ctx.createOperation(consumer_state);

    try block.addOperation(consumer);
    try block.addOperation(producer);

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(error.InvalidLocalDominance, verifyBlock(&block, options));
}

test "verify can skip local dominance while preserving use-def checks" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var block = Block.init(testing.allocator);
    defer block.deinit();

    const ty = try ctx.getDialectTypeFromName("test.i32");
    var producer_state = Operation.State.init("test.producer", .unknown);
    producer_state.addTypes(&.{ty});
    const producer = try ctx.createOperation(producer_state);

    var consumer_state = Operation.State.init("test.consumer", .unknown);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    const consumer = try ctx.createOperation(consumer_state);

    try block.addOperation(consumer);
    try block.addOperation(producer);

    var options = default_options;
    options.check_terminators = false;
    options.check_local_dominance = false;
    try verifyBlock(&block, options);
}

test "graph region accepts same-block use before definition" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const core_traits = @import("traits.zig");

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const owner_name = "region_kind.graph_owner";
    try core_traits.registerOperationTrait(&ctx, owner_name, core_traits.HasOnlyGraphRegion);

    var owner_state = Operation.State.init(owner_name, .unknown);
    owner_state.addRegion();
    const owner = try ctx.createOperation(owner_state);
    const region = owner.getRegion(0).?;
    const block = try region.addBlock();

    const ty = try ctx.getDialectTypeFromName("test.i32");
    var producer_state = Operation.State.init("region_kind.producer", .unknown);
    producer_state.addTypes(&.{ty});
    const producer = try ctx.createOperation(producer_state);

    var consumer_state = Operation.State.init("region_kind.consumer", .unknown);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    const consumer = try ctx.createOperation(consumer_state);

    try block.addOperation(consumer);
    try block.addOperation(producer);

    try testing.expectEqual(interfaces.RegionKind.graph, regionKind(region));
    try testing.expect(!regionMayHaveSSADominance(region));

    var options = default_options;
    options.check_terminators = false;
    try verifyOperation(owner, options);
}

test "ssacfg region keeps same-block dominance requirement" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var owner_state = Operation.State.init("region_kind.ssacfg_owner", .unknown);
    owner_state.addRegion();
    const owner = try ctx.createOperation(owner_state);
    const region = owner.getRegion(0).?;
    const block = try region.addBlock();

    const ty = try ctx.getDialectTypeFromName("test.i32");
    var producer_state = Operation.State.init("region_kind.producer", .unknown);
    producer_state.addTypes(&.{ty});
    const producer = try ctx.createOperation(producer_state);

    var consumer_state = Operation.State.init("region_kind.consumer", .unknown);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    const consumer = try ctx.createOperation(consumer_state);

    try block.addOperation(consumer);
    try block.addOperation(producer);

    try testing.expectEqual(interfaces.RegionKind.ssacfg, regionKind(region));
    try testing.expect(regionMayHaveSSADominance(region));

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(error.InvalidLocalDominance, verifyOperation(owner, options));
}

test "ssacfg region accepts cross-block use dominated by entry definition" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var owner_state = Operation.State.init("dominance.owner", .unknown);
    owner_state.addRegion();
    const owner = try ctx.createOperation(owner_state);
    const region = owner.getRegion(0).?;
    const entry = try region.addBlock();
    const then_block = try region.addBlock();
    const else_block = try region.addBlock();
    const merge = try region.addBlock();

    const ty = try ctx.getDialectTypeFromName("dominance.i32");
    var producer_state = Operation.State.init("dominance.producer", .unknown);
    producer_state.addTypes(&.{ty});
    const producer = try ctx.createOperation(producer_state);
    try entry.addOperation(producer);

    var entry_branch_state = Operation.State.init("dominance.entry_branch", .unknown);
    entry_branch_state.addSuccessors(&.{ then_block, else_block });
    try entry.addOperation(try ctx.createOperation(entry_branch_state));

    var then_branch_state = Operation.State.init("dominance.then_branch", .unknown);
    then_branch_state.addSuccessors(&.{merge});
    try then_block.addOperation(try ctx.createOperation(then_branch_state));

    var else_branch_state = Operation.State.init("dominance.else_branch", .unknown);
    else_branch_state.addSuccessors(&.{merge});
    try else_block.addOperation(try ctx.createOperation(else_branch_state));

    var consumer_state = Operation.State.init("dominance.consumer", .unknown);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    try merge.addOperation(try ctx.createOperation(consumer_state));

    var options = default_options;
    options.check_terminators = false;
    try verifyOperation(owner, options);
}

test "ssacfg region rejects cross-block use without dominance" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var owner_state = Operation.State.init("dominance.owner", .unknown);
    owner_state.addRegion();
    const owner = try ctx.createOperation(owner_state);
    const region = owner.getRegion(0).?;
    const entry = try region.addBlock();
    const then_block = try region.addBlock();
    const else_block = try region.addBlock();
    const merge = try region.addBlock();

    var entry_branch_state = Operation.State.init("dominance.entry_branch", .unknown);
    entry_branch_state.addSuccessors(&.{ then_block, else_block });
    try entry.addOperation(try ctx.createOperation(entry_branch_state));

    const ty = try ctx.getDialectTypeFromName("dominance.i32");
    var producer_state = Operation.State.init("dominance.producer", .unknown);
    producer_state.addTypes(&.{ty});
    const producer = try ctx.createOperation(producer_state);
    try then_block.addOperation(producer);

    var then_branch_state = Operation.State.init("dominance.then_branch", .unknown);
    then_branch_state.addSuccessors(&.{merge});
    try then_block.addOperation(try ctx.createOperation(then_branch_state));

    var else_branch_state = Operation.State.init("dominance.else_branch", .unknown);
    else_branch_state.addSuccessors(&.{merge});
    try else_block.addOperation(try ctx.createOperation(else_branch_state));

    var consumer_state = Operation.State.init("dominance.consumer", .unknown);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    try merge.addOperation(try ctx.createOperation(consumer_state));

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(error.InvalidLocalDominance, verifyOperation(owner, options));
}

test "ssacfg region rejects cross-block block argument use without dominance" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var owner_state = Operation.State.init("dominance.owner", .unknown);
    owner_state.addRegion();
    const owner = try ctx.createOperation(owner_state);
    const region = owner.getRegion(0).?;
    const entry = try region.addBlock();
    const then_block = try region.addBlock();
    const else_block = try region.addBlock();
    const merge = try region.addBlock();

    var entry_branch_state = Operation.State.init("dominance.entry_branch", .unknown);
    entry_branch_state.addSuccessors(&.{ then_block, else_block });
    try entry.addOperation(try ctx.createOperation(entry_branch_state));

    const ty = try ctx.getDialectTypeFromName("dominance.i32");
    const then_arg = try then_block.addArgument(ty, .unknown);

    var then_branch_state = Operation.State.init("dominance.then_branch", .unknown);
    then_branch_state.addSuccessors(&.{merge});
    try then_block.addOperation(try ctx.createOperation(then_branch_state));

    var else_branch_state = Operation.State.init("dominance.else_branch", .unknown);
    else_branch_state.addSuccessors(&.{merge});
    try else_block.addOperation(try ctx.createOperation(else_branch_state));

    var consumer_state = Operation.State.init("dominance.consumer", .unknown);
    consumer_state.addOperands(&.{then_arg});
    try merge.addOperation(try ctx.createOperation(consumer_state));

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(error.InvalidLocalDominance, verifyOperation(owner, options));
}

test "graph region rejects multiple blocks" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const core_traits = @import("traits.zig");

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const owner_name = "region_kind.multi_block_graph_owner";
    try core_traits.registerOperationTrait(&ctx, owner_name, core_traits.HasOnlyGraphRegion);

    var owner_state = Operation.State.init(owner_name, .unknown);
    owner_state.addRegion();
    const owner = try ctx.createOperation(owner_state);
    const region = owner.getRegion(0).?;
    _ = try region.addBlock();
    _ = try region.addBlock();

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(error.GraphRegionMultipleBlocks, verifyOperation(owner, options));
}

test "verify successor/predecessor consistency" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);

    var pred = Block.init(testing.allocator);
    defer pred.deinit();
    var succ = Block.init(testing.allocator);
    defer succ.deinit();
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var br_state = Operation.State.init("test.br", Location.getUnknown());
    br_state.addSuccessors(&.{&succ});
    const br_op = try ctx.createOperation(br_state);
    try pred.addOperation(br_op);

    var options = default_options;
    options.check_terminators = false;
    try verifyBlock(&pred, options);
    try verifyBlock(&succ, options);

    try verifyOperation(br_op, options);
}

test "verify rejects reverse-only predecessor entries" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    var source = Block.init(testing.allocator);
    var target = Block.init(testing.allocator);
    defer {
        ctx.deinit(testing.allocator);
        source.deinit();
        target.deinit();
    }
    try ctx.allowUnregistered();

    try target.predecessors.append(target.allocator, &source);

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(error.InvalidPredecessor, verifyBlock(&target, options));

    try source.addOperation(try ctx.createOperation(
        Operation.State.init("test.zero_successor_tail", .unknown),
    ));
    try testing.expectError(error.InvalidPredecessor, verifyBlock(&target, options));
}

test "verify rejects duplicate predecessor entries" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    var source = Block.init(testing.allocator);
    var target = Block.init(testing.allocator);
    defer {
        ctx.deinit(testing.allocator);
        source.deinit();
        target.deinit();
    }
    try ctx.allowUnregistered();

    var state = Operation.State.init("test.duplicate_predecessor", .unknown);
    state.addSuccessors(&.{&target});
    const operation = try ctx.createOperation(state);
    try source.addOperation(operation);
    try target.predecessors.append(target.allocator, &source);

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(error.InvalidPredecessor, verifyBlock(&target, options));
    source.removeOperation(operation);
    try testing.expect(target.hasNoPredecessors());
}

test "verify rejects predecessor outside the target region" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    var source = Block.init(testing.allocator);
    defer {
        ctx.deinit(testing.allocator);
        source.deinit();
    }
    try ctx.allowUnregistered();

    var owner_state = Operation.State.init("test.region_owner", .unknown);
    owner_state.addRegion();
    const owner = try ctx.createOperation(owner_state);
    const region = owner.getRegion(0).?;
    _ = try region.addBlock();
    const target = try region.addBlock();

    var state = Operation.State.init("test.external_branch", .unknown);
    state.addSuccessors(&.{target});
    try source.addOperation(try ctx.createOperation(state));

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(
        error.SuccessorRegionMismatch,
        verifyRegionStructure(region, options),
    );
}

test "verify bounds corrupt predecessor operation traversal" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    var source = Block.init(testing.allocator);
    var target = Block.init(testing.allocator);
    defer {
        ctx.deinit(testing.allocator);
        source.deinit();
        target.deinit();
    }
    try ctx.allowUnregistered();

    const operation = try ctx.createOperation(
        Operation.State.init("test.cyclic_predecessor_source", .unknown),
    );
    try source.addOperation(operation);
    operation.next_op = operation;
    defer operation.next_op = null;
    try target.predecessors.append(target.allocator, &source);

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(
        error.OperationListCorrupted,
        verifyBlock(&target, options),
    );
}

test "verify accepts predecessors justified by non-tail operations" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    var source = Block.init(testing.allocator);
    var first_target = Block.init(testing.allocator);
    var tail_target = Block.init(testing.allocator);
    defer {
        ctx.deinit(testing.allocator);
        source.deinit();
        first_target.deinit();
        tail_target.deinit();
    }
    try ctx.allowUnregistered();

    var first_state = Operation.State.init("test.first_branch", .unknown);
    first_state.addSuccessors(&.{&first_target});
    try source.addOperation(try ctx.createOperation(first_state));
    var tail_state = Operation.State.init("test.tail_branch", .unknown);
    tail_state.addSuccessors(&.{&tail_target});
    try source.addOperation(try ctx.createOperation(tail_state));

    var options = default_options;
    options.check_terminators = false;
    try verifyBlock(&first_target, options);
}

test "ssacfg region rejects successor to entry block" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var owner_state = Operation.State.init("cfg.entry_successor_owner", .unknown);
    owner_state.addRegion();
    const owner = try ctx.createOperation(owner_state);
    const region = owner.getRegion(0).?;
    const entry = try region.addBlock();
    const body = try region.addBlock();

    var entry_branch_state = Operation.State.init("cfg.entry_branch", .unknown);
    entry_branch_state.addSuccessors(&.{body});
    try entry.addOperation(try ctx.createOperation(entry_branch_state));

    var backedge_state = Operation.State.init("cfg.backedge", .unknown);
    backedge_state.addSuccessors(&.{entry});
    try body.addOperation(try ctx.createOperation(backedge_state));

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(error.EntryBlockSuccessor, verifyOperation(owner, options));
}

test "ssacfg region rejects successor outside containing region" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var source_owner_state = Operation.State.init("cfg.source_owner", .unknown);
    source_owner_state.addRegion();
    const source_owner = try ctx.createOperation(source_owner_state);
    const source_block = try source_owner.getRegion(0).?.addBlock();

    var target_owner_state = Operation.State.init("cfg.target_owner", .unknown);
    target_owner_state.addRegion();
    const target_owner = try ctx.createOperation(target_owner_state);
    const target_block = try target_owner.getRegion(0).?.addBlock();

    var branch_state = Operation.State.init("cfg.cross_region_branch", .unknown);
    branch_state.addSuccessors(&.{target_block});
    try source_block.addOperation(try ctx.createOperation(branch_state));

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(error.SuccessorRegionMismatch, verifyOperation(source_owner, options));
}

test "verify nested regions" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var state = Operation.State.init("test.module", .unknown);
    state.addRegion();
    const module_op = try ctx.createOperation(state);

    const region = module_op.getRegion(0).?;
    _ = try region.addBlock();
    try testing.expect(region.parent == @as(*anyopaque, @ptrCast(module_op)));

    var options = default_options;
    options.check_terminators = false;
    try verifyOperation(module_op, options);
}

test "verify detects parent block mismatch" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var block1 = Block.init(testing.allocator);
    defer block1.deinit();
    var block2 = Block.init(testing.allocator);
    defer block2.deinit();

    const state = Operation.State.init("test.op", .unknown);
    const op = try ctx.createOperation(state);

    try block1.addOperation(op);
    op.parent_block = &block2;

    var options = default_options;
    options.check_terminators = false;
    const result = verifyBlock(&block1, options);
    try testing.expectError(error.ParentBlockMismatch, result);

    op.parent_block = &block1;
}

test "verify detects use-def chain corruption" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const ty = try ctx.getDialectTypeFromName("test.i32");

    var producer1_state = Operation.State.init("test.producer1", .unknown);
    producer1_state.addTypes(&.{ty});
    const producer1 = try ctx.createOperation(producer1_state);

    var producer2_state = Operation.State.init("test.producer2", .unknown);
    producer2_state.addTypes(&.{ty});
    const producer2 = try ctx.createOperation(producer2_state);

    const result1 = producer1.getResult(0).?;
    const result2 = producer2.getResult(0).?;

    var consumer_state = Operation.State.init("test.consumer", .unknown);
    consumer_state.addOperands(&.{result1});
    const consumer = try ctx.createOperation(consumer_state);

    consumer.operands.items[0].value = result2;

    const verify_result = verifyValue(result1);
    try testing.expectError(error.UseChainValueMismatch, verify_result);

    consumer.operands.items[0].value = result1;
}

test "verify empty region" {
    const testing = std.testing;

    var region = Region.init(testing.allocator);
    defer region.deinit();

    var options = default_options;
    options.check_terminators = false;
    try verifyRegion(&region, options);

    try testing.expectEqual(@as(usize, 0), region.blocks.size);
}

test "verifyValue on unused value" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const ty = try ctx.getDialectTypeFromName("test.i32");

    var state = Operation.State.init("test.producer", .unknown);
    state.addTypes(&.{ty});
    const producer = try ctx.createOperation(state);

    const result = producer.getResult(0).?;

    try verifyValue(result);
    try testing.expect(result.hasNoUses());
}

test "verify region size consistency" {
    const testing = std.testing;

    var region = Region.init(testing.allocator);
    defer region.deinit();

    _ = try region.addBlock();
    _ = try region.addBlock();
    _ = try region.addBlock();

    const correct_size = region.blocks.size;
    region.blocks.size = 999;

    var options = default_options;
    options.check_terminators = false;
    const result = verifyRegion(&region, options);
    try testing.expectError(error.RegionSizeMismatch, result);

    region.blocks.size = correct_size;
}

test "verify operation list forward/backward consistency" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var block = Block.init(testing.allocator);
    defer block.deinit();

    const state1 = Operation.State.init("test.op1", .unknown);
    const op1 = try ctx.createOperation(state1);
    try block.addOperation(op1);

    const state2 = Operation.State.init("test.op2", .unknown);
    const op2 = try ctx.createOperation(state2);
    try block.addOperation(op2);

    const state3 = Operation.State.init("test.op3", .unknown);
    const op3 = try ctx.createOperation(state3);
    try block.addOperation(op3);

    try testing.expectEqual(op1.next_op, op2);
    try testing.expectEqual(op2.prev_op, op1);
    try testing.expectEqual(op2.next_op, op3);
    try testing.expectEqual(op3.prev_op, op2);

    var options = default_options;
    options.check_terminators = false;
    try verifyBlock(&block, options);
}

test "verify MissingTerminator error when require_terminators enabled" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var block = Block.init(testing.allocator);
    defer block.deinit();

    const state = Operation.State.init("test.noop", .unknown);
    const op = try ctx.createOperation(state);
    try block.addOperation(op);

    var options = default_options;
    options.check_terminators = true;
    options.require_terminators = false;
    try verifyBlock(&block, options);

    options.require_terminators = true;
    const result = verifyBlock(&block, options);
    try testing.expectError(error.MissingTerminator, result);
}

test "NoTerminator trait allows single-block region without terminator" {
    const Context = @import("context/root.zig").Context;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try Context.init(allocator, Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const i64_type = try test_dialect.TestDialect.getI64Type(&ctx);
    const constant = try test_dialect.TestDialect.ConstantOp.create(&ctx, loc, i64_type, 1);
    try block.addOperation(constant.op);

    var options = default_options;
    options.require_terminators = true;
    try verifyOperation(module.op, options);
}

test "NoTerminator trait does not exempt multi-block regions" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const core_traits = @import("traits.zig");

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const owner_name = "terminator.no_terminator_owner";
    try core_traits.registerOperationTrait(&ctx, owner_name, core_traits.NoTerminator);

    const loc = Location.getUnknown();
    var owner_state = Operation.State.init(owner_name, loc);
    owner_state.addRegion();
    const owner = try ctx.createOperation(owner_state);

    const region = owner.getRegion(0).?;
    const first = try region.addBlock();
    _ = try region.addBlock();
    const child = try ctx.createOperation(Operation.State.init("terminator.child", loc));
    try first.addOperation(child);

    var options = default_options;
    options.require_terminators = true;
    try testing.expectError(error.MissingTerminator, verifyOperation(owner, options));
}

test "NoTerminator trait rejects multi-block regions with terminators" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const core_traits = @import("traits.zig");

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const owner_name = "terminator.no_terminator_multi_block_owner";
    const terminator_name = "terminator.no_terminator_multi_block_term";
    try core_traits.registerOperationTrait(&ctx, owner_name, core_traits.NoTerminator);
    try core_traits.registerOperationTrait(&ctx, terminator_name, core_traits.Terminator);

    const loc = Location.getUnknown();
    var owner_state = Operation.State.init(owner_name, loc);
    owner_state.addRegion();
    const owner = try ctx.createOperation(owner_state);

    const region = owner.getRegion(0).?;
    const first = try region.addBlock();
    const second = try region.addBlock();
    try first.addOperation(try ctx.createOperation(Operation.State.init(terminator_name, loc)));
    try second.addOperation(try ctx.createOperation(Operation.State.init(terminator_name, loc)));

    try testing.expectError(core_traits.TraitError.SingleBlockRegionMismatch, verifyOperation(owner, default_options));
}

test "trait verification enforces operand counts" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const core_traits = @import("traits.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try Context.init(allocator, Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    try core_traits.registerOperationTrait(&ctx, test_dialect.TestDialect.BinaryOp.operation_name, core_traits.NOperands(2));
    try core_traits.registerOperationTrait(&ctx, test_dialect.TestDialect.BinaryOp.operation_name, core_traits.NResults(1));

    const loc = Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    const i64_type = try test_dialect.TestDialect.getI64Type(&ctx);
    _ = try block.addArgument(i64_type, loc);
    _ = try block.addArgument(i64_type, loc);
    const arg0 = block.arguments.items[0];
    const arg1 = block.arguments.items[1];

    const good_op = try test_dialect.TestDialect.BinaryOp.create(&ctx, loc, arg0, arg1);
    try block.addOperation(good_op.op);

    try verifyOperation(module.op, default_options);

    var bad_state = Operation.State.init(test_dialect.TestDialect.BinaryOp.operation_name, loc);
    bad_state.addOperands(&.{arg0});
    bad_state.addTypes(&.{i64_type});
    const bad_op = try ctx.createOperation(bad_state);
    try block.addOperation(bad_op);

    const result = verifyOperation(module.op, default_options);
    try testing.expectError(core_traits.TraitError.OperandCountMismatch, result);
}

test "trait verification enforces result counts" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const core_traits = @import("traits.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try Context.init(allocator, Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    try core_traits.registerOperationTrait(&ctx, test_dialect.TestDialect.BinaryOp.operation_name, core_traits.NResults(1));

    const loc = Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    const i64_type = try test_dialect.TestDialect.getI64Type(&ctx);
    _ = try block.addArgument(i64_type, loc);
    _ = try block.addArgument(i64_type, loc);
    const arg0 = block.arguments.items[0];
    const arg1 = block.arguments.items[1];

    var bad_state = Operation.State.init(test_dialect.TestDialect.BinaryOp.operation_name, loc);
    bad_state.addOperands(&.{ arg0, arg1 });
    const bad_op = try ctx.createOperation(bad_state);
    try block.addOperation(bad_op);

    const result = verifyOperation(module.op, default_options);
    try testing.expectError(core_traits.TraitError.ResultCountMismatch, result);
}

test "structural verification does not run operation trait verifiers" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const core_traits = @import("traits.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try Context.init(allocator, Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    try core_traits.registerOperationTrait(&ctx, test_dialect.TestDialect.BinaryOp.operation_name, core_traits.NOperands(2));

    const loc = Location.getUnknown();
    const i64_type = try test_dialect.TestDialect.getI64Type(&ctx);
    var producer_state = Operation.State.init(test_dialect.TestDialect.ConstantOp.operation_name, loc);
    producer_state.addTypes(&.{i64_type});
    const producer = try ctx.createOperation(producer_state);

    var bad_state = Operation.State.init(test_dialect.TestDialect.BinaryOp.operation_name, loc);
    bad_state.addOperands(&.{producer.getResult(0).?});
    bad_state.addTypes(&.{i64_type});
    const bad_op = try ctx.createOperation(bad_state);

    try verifyOperationStructure(bad_op, .{ .recursive = false });
    try testing.expectError(core_traits.TraitError.OperandCountMismatch, verifyOperation(bad_op, .{ .recursive = false }));
}

test "registered operation shape runs before custom verifiers" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("shape.checked", .{});
    try ctx.registerOperationShape("shape.checked", .{
        .operands = interfaces.CountRange.exactly(2),
        .results = interfaces.CountRange.exactly(1),
        .regions = interfaces.CountRange.exactly(0),
        .successors = interfaces.CountRange.exactly(0),
    });

    const hooks = struct {
        fn verify(_: *const anyopaque) anyerror!void {
            return error.CustomVerifierRan;
        }
    };
    try ctx.registerOperationInterface("shape.checked", VerifyOpInterface.entryFor(hooks.verify));

    const ty = try ctx.getDialectTypeFromName("shape.i32");
    var producer_state = Operation.State.init("shape.producer", .unknown);
    producer_state.addTypes(&.{ty});
    const producer = try ctx.createOperation(producer_state);

    var bad_state = Operation.State.init("shape.checked", .unknown);
    bad_state.addOperands(&.{producer.getResult(0).?});
    bad_state.addTypes(&.{ty});
    const bad_op = try ctx.createOperation(bad_state);

    try verifyOperationStructure(bad_op, .{ .recursive = false });
    try testing.expectError(error.OperandCountMismatch, verifyOperation(bad_op, .{ .recursive = false }));

    var good_state = Operation.State.init("shape.checked", .unknown);
    good_state.addOperands(&.{ producer.getResult(0).?, producer.getResult(0).? });
    good_state.addTypes(&.{ty});
    const good_op = try ctx.createOperation(good_state);
    try testing.expectError(error.CustomVerifierRan, verifyOperation(good_op, .{ .recursive = false }));
}

test "registered operation segments verify before custom verifiers" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("segments.checked", .{});
    try ctx.registerOperationShape("segments.checked", .{
        .operands = interfaces.CountRange.between(1, 4),
        .results = interfaces.CountRange.between(1, 2),
    });
    try ctx.registerOperationOperandSegments("segments.checked", .{
        .attribute_name = "operand_segment_sizes",
        .segments = &.{ interfaces.CountRange.exactly(1), interfaces.CountRange.atMost(1), interfaces.CountRange.atMost(2) },
    });
    try ctx.registerOperationResultSegments("segments.checked", .{
        .attribute_name = "result_segment_sizes",
        .segments = &.{ interfaces.CountRange.exactly(1), interfaces.CountRange.atMost(1) },
    });

    const hooks = struct {
        fn verify(_: *const anyopaque) anyerror!void {
            return error.CustomVerifierRan;
        }
    };
    try ctx.registerOperationInterface("segments.checked", VerifyOpInterface.entryFor(hooks.verify));

    const ty = try ctx.getDialectTypeFromName("segments.i32");
    var producer_state = Operation.State.init("segments.producer", .unknown);
    producer_state.addTypes(&.{ty});
    const producer = try ctx.createOperation(producer_state);
    const value = producer.getResult(0).?;

    var bad_operand_sum_state = Operation.State.init("segments.checked", .unknown);
    bad_operand_sum_state.addOperands(&.{ value, value });
    bad_operand_sum_state.addTypes(&.{ty});
    const bad_operand_sum = try ctx.createOperation(bad_operand_sum_state);
    try bad_operand_sum.setAttr(
        "operand_segment_sizes",
        try test_segment_attribute(&ctx, &.{ 1, 0, 0 }),
    );
    try bad_operand_sum.setAttr(
        "result_segment_sizes",
        try test_segment_attribute(&ctx, &.{ 1, 0 }),
    );
    try testing.expectError(error.OperandSegmentSizeMismatch, verifyOperation(bad_operand_sum, .{ .recursive = false }));

    var bad_operand_attr_state = Operation.State.init("segments.checked", .unknown);
    bad_operand_attr_state.addOperands(&.{value});
    bad_operand_attr_state.addTypes(&.{ty});
    const bad_operand_attr = try ctx.createOperation(bad_operand_attr_state);
    try bad_operand_attr.setAttr(
        "operand_segment_sizes",
        try test_segment_attribute(&ctx, &.{ 1, 0 }),
    );
    try bad_operand_attr.setAttr(
        "result_segment_sizes",
        try test_segment_attribute(&ctx, &.{ 1, 0 }),
    );
    try testing.expectError(error.InvalidOperandSegmentSizeAttribute, verifyOperation(bad_operand_attr, .{ .recursive = false }));

    var bad_result_sum_state = Operation.State.init("segments.checked", .unknown);
    bad_result_sum_state.addOperands(&.{value});
    bad_result_sum_state.addTypes(&.{ty});
    const bad_result_sum = try ctx.createOperation(bad_result_sum_state);
    try bad_result_sum.setAttr(
        "operand_segment_sizes",
        try test_segment_attribute(&ctx, &.{ 1, 0, 0 }),
    );
    try bad_result_sum.setAttr(
        "result_segment_sizes",
        try test_segment_attribute(&ctx, &.{ 1, 1 }),
    );
    try testing.expectError(error.ResultSegmentSizeMismatch, verifyOperation(bad_result_sum, .{ .recursive = false }));

    var good_state = Operation.State.init("segments.checked", .unknown);
    good_state.addOperands(&.{ value, value, value });
    good_state.addTypes(&.{ ty, ty });
    const good_op = try ctx.createOperation(good_state);
    try good_op.setAttr("operand_segment_sizes", try test_segment_attribute(&ctx, &.{ 1, 1, 1 }));
    try good_op.setAttr("result_segment_sizes", try test_segment_attribute(&ctx, &.{ 1, 1 }));
    try testing.expectError(error.CustomVerifierRan, verifyOperation(good_op, .{ .recursive = false }));
}

test "registered required attributes verify before custom verifiers" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("required.checked", .{});
    try ctx.registerOperationRequiredAttributeName("required.checked", "value");

    const hooks = struct {
        fn verify(_: *const anyopaque) anyerror!void {
            return error.CustomVerifierRan;
        }
    };
    try ctx.registerOperationInterface("required.checked", VerifyOpInterface.entryFor(hooks.verify));

    const missing_op = try ctx.createOperation(Operation.State.init("required.checked", .unknown));
    try testing.expectError(error.MissingRequiredAttribute, verifyOperation(missing_op, .{ .recursive = false }));

    const present_op = try ctx.createOperation(Operation.State.init("required.checked", .unknown));
    try present_op.setAttr("value", try ctx.getI64Attr(42));
    try testing.expectError(error.CustomVerifierRan, verifyOperation(present_op, .{ .recursive = false }));
}

test "registered required attributes accept property-backed inherent storage" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("required.properties", .{});
    try ctx.registerOperationRequiredAttributeName("required.properties", "value");
    try ctx.registerOperationPropertiesModel(
        "required.properties",
        interfaces.singleAttributePropertiesModel("required.properties.model", "value"),
    );

    var state = Operation.State.init("required.properties", .unknown);
    try state.setPropertiesAttr(try ctx.getI64Attr(7));
    const op = try ctx.createOperation(state);

    try verifyOperation(op, .{ .recursive = false });
}

test "registered type constraints verify before custom verifiers" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("types.checked", .{});
    try ctx.registerOperationShape("types.checked", .{
        .operands = interfaces.CountRange.exactly(1),
        .results = interfaces.CountRange.exactly(1),
    });
    try ctx.registerOperationOperandTypeConstraint("types.checked", .{
        .index = 0,
        .type_name = "types.i32",
    });
    try ctx.registerOperationResultTypeConstraint("types.checked", .{
        .index = 0,
        .type_name = "types.bool",
    });

    const hooks = struct {
        fn verify(_: *const anyopaque) anyerror!void {
            return error.CustomVerifierRan;
        }
    };
    try ctx.registerOperationInterface("types.checked", VerifyOpInterface.entryFor(hooks.verify));

    const i32_type = try ctx.getDialectTypeFromName("types.i32");
    const f32_type = try ctx.getDialectTypeFromName("types.f32");
    const bool_type = try ctx.getDialectTypeFromName("types.bool");

    var good_operand_state = Operation.State.init("types.good_operand", .unknown);
    good_operand_state.addTypes(&.{i32_type});
    const good_operand = try ctx.createOperation(good_operand_state);

    var bad_operand_state = Operation.State.init("types.bad_operand", .unknown);
    bad_operand_state.addTypes(&.{f32_type});
    const bad_operand = try ctx.createOperation(bad_operand_state);

    var bad_operand_use_state = Operation.State.init("types.checked", .unknown);
    bad_operand_use_state.addOperands(&.{bad_operand.getResult(0).?});
    bad_operand_use_state.addTypes(&.{bool_type});
    const bad_operand_use = try ctx.createOperation(bad_operand_use_state);
    try testing.expectError(error.OperandTypeConstraintMismatch, verifyOperation(bad_operand_use, .{ .recursive = false }));

    var bad_result_state = Operation.State.init("types.checked", .unknown);
    bad_result_state.addOperands(&.{good_operand.getResult(0).?});
    bad_result_state.addTypes(&.{f32_type});
    const bad_result = try ctx.createOperation(bad_result_state);
    try testing.expectError(error.ResultTypeConstraintMismatch, verifyOperation(bad_result, .{ .recursive = false }));

    var good_state = Operation.State.init("types.checked", .unknown);
    good_state.addOperands(&.{good_operand.getResult(0).?});
    good_state.addTypes(&.{bool_type});
    const good_op = try ctx.createOperation(good_state);
    try testing.expectError(error.CustomVerifierRan, verifyOperation(good_op, .{ .recursive = false }));
}

test "registered type constraints can allow parameterized dialect types" {
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(std.testing.allocator, Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("types.parameterized", .{});
    try ctx.registerOperationOperandTypeConstraint("types.parameterized", .{
        .index = 0,
        .type_name = "types.param",
        .allow_parameterized = true,
    });
    try ctx.registerOperationResultTypeConstraint("types.parameterized", .{
        .index = 0,
        .type_name = "types.param",
        .allow_parameterized = true,
    });

    const param_type = try ctx.getDialectTypeFromNameWithKey("types.param", "64");
    var producer_state = Operation.State.init("types.producer", .unknown);
    producer_state.addTypes(&.{param_type});
    const producer = try ctx.createOperation(producer_state);

    var consumer_state = Operation.State.init("types.parameterized", .unknown);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    consumer_state.addTypes(&.{param_type});
    const consumer = try ctx.createOperation(consumer_state);

    try verifyOperation(consumer, .{ .recursive = false });
}

test "trait verification enforces region counts" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const core_traits = @import("traits.zig");

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const op_name = "test.region_owner";
    try core_traits.registerOperationTrait(&ctx, op_name, core_traits.OneRegion);

    const bad_state = Operation.State.init(op_name, Location.getUnknown());
    const bad_op = try ctx.createOperation(bad_state);

    const result = verifyOperation(bad_op, default_options);
    try testing.expectError(core_traits.TraitError.RegionCountMismatch, result);
}

test "trait verification enforces single-block regions" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const core_traits = @import("traits.zig");

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const op_name = "test.single_block_owner";
    try core_traits.registerOperationTrait(&ctx, op_name, core_traits.SingleBlock);

    const loc = Location.getUnknown();
    var state = Operation.State.init(op_name, loc);
    state.addRegion();
    const op = try ctx.createOperation(state);

    const region = op.getRegion(0).?;
    _ = try region.addBlock();
    _ = try region.addBlock();

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(core_traits.TraitError.SingleBlockRegionMismatch, verifyOperation(op, options));
}

test "trait verification enforces implicit terminator name" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const core_traits = @import("traits.zig");

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const owner_name = "test.implicit_terminator_owner";
    const terminator_name = "test.implicit_terminator";
    try core_traits.registerOperationTrait(
        &ctx,
        owner_name,
        core_traits.SingleBlockImplicitTerminator(terminator_name),
    );

    const loc = Location.getUnknown();
    var good_state = Operation.State.init(owner_name, loc);
    good_state.addRegion();
    const good = try ctx.createOperation(good_state);
    const good_block = try good.getRegion(0).?.addBlock();
    try good_block.addOperation(try ctx.createOperation(Operation.State.init(terminator_name, loc)));
    try verifyOperation(good, default_options);

    var bad_state = Operation.State.init(owner_name, loc);
    bad_state.addRegion();
    const bad = try ctx.createOperation(bad_state);
    const bad_block = try bad.getRegion(0).?.addBlock();
    try bad_block.addOperation(try ctx.createOperation(Operation.State.init("test.wrong_terminator", loc)));
    try testing.expectError(
        core_traits.TraitError.ImplicitTerminatorMismatch,
        verifyOperation(bad, default_options),
    );
}

test "trait verification enforces terminator placement" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const core_traits = @import("traits.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try Context.init(allocator, Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    try core_traits.registerOperationTrait(&ctx, test_dialect.TestDialect.ReturnOp.operation_name, core_traits.Terminator);

    const loc = Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    const ret_op = try test_dialect.TestDialect.ReturnOp.create(&ctx, loc, &.{});
    try block.addOperation(ret_op.op);

    const i64_type = try test_dialect.TestDialect.getI64Type(&ctx);
    const const_op = try test_dialect.TestDialect.ConstantOp.create(&ctx, loc, i64_type, 1);
    try block.addOperation(const_op.op);

    var options = default_options;
    options.check_terminators = false;

    const result = verifyOperation(module.op, options);
    try testing.expectError(core_traits.TraitError.TerminatorNotLast, result);
}

test "trait verification enforces isolation from above" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const core_traits = @import("traits.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try Context.init(allocator, Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    try core_traits.registerOperationTrait(&ctx, test_dialect.TestDialect.ModuleOp.operation_name, core_traits.IsolatedFromAbove);

    const loc = Location.getUnknown();
    const i64_type = try test_dialect.TestDialect.getI64Type(&ctx);

    const outer_module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const outer_block = outer_module.getBodyBlock();

    const outer_const = try test_dialect.TestDialect.ConstantOp.create(&ctx, loc, i64_type, 7);
    try outer_block.addOperation(outer_const.op);

    const inner_module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    try outer_block.addOperation(inner_module.op);

    const inner_block = inner_module.getBodyBlock();
    const inner_const = try test_dialect.TestDialect.ConstantOp.create(&ctx, loc, i64_type, 3);
    try inner_block.addOperation(inner_const.op);

    const bad_binary = try test_dialect.TestDialect.BinaryOp.create(&ctx, loc, outer_const.getResult(), inner_const.getResult());
    try inner_block.addOperation(bad_binary.op);

    const result = verifyOperation(outer_module.op, default_options);
    try testing.expectError(core_traits.TraitError.IsolatedFromAbove, result);
}

test "trait verification enforces recursive isolation from above" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const core_traits = @import("traits.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try Context.init(allocator, Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const isolated_name = "isolation.recursive_root";
    try core_traits.registerOperationTrait(&ctx, isolated_name, core_traits.IsolatedFromAbove);

    const loc = Location.getUnknown();
    const i64_type = try ctx.getDialectTypeFromName("isolation.i64");

    var outer_state = Operation.State.init("isolation.outer", loc);
    outer_state.addRegion();
    const outer = try ctx.createOperation(outer_state);
    const outer_block = try outer.getRegion(0).?.addBlock();

    var producer_state = Operation.State.init("isolation.producer", loc);
    producer_state.addTypes(&.{i64_type});
    const producer = try ctx.createOperation(producer_state);
    try outer_block.addOperation(producer);

    var isolated_state = Operation.State.init(isolated_name, loc);
    isolated_state.addRegion();
    const isolated = try ctx.createOperation(isolated_state);
    try outer_block.addOperation(isolated);
    const isolated_block = try isolated.getRegion(0).?.addBlock();

    var child_state = Operation.State.init("isolation.non_isolated_child", loc);
    child_state.addRegion();
    const child = try ctx.createOperation(child_state);
    try isolated_block.addOperation(child);
    const child_block = try child.getRegion(0).?.addBlock();

    var consumer_state = Operation.State.init("isolation.consumer", loc);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    const consumer = try ctx.createOperation(consumer_state);
    try child_block.addOperation(consumer);

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(core_traits.TraitError.IsolatedFromAbove, runRegionTraitVerifiers(isolated));
    try testing.expectError(core_traits.TraitError.IsolatedFromAbove, verifyOperation(isolated, options));
}

test "trait verification allows recursive uses inside isolated operation" {
    const Context = @import("context/root.zig").Context;
    const core_traits = @import("traits.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try Context.init(allocator, Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const isolated_name = "isolation.recursive_allowed_root";
    try core_traits.registerOperationTrait(&ctx, isolated_name, core_traits.IsolatedFromAbove);

    const loc = Location.getUnknown();
    const i64_type = try ctx.getDialectTypeFromName("isolation.i64");

    var isolated_state = Operation.State.init(isolated_name, loc);
    isolated_state.addRegion();
    const isolated = try ctx.createOperation(isolated_state);
    const isolated_block = try isolated.getRegion(0).?.addBlock();

    var producer_state = Operation.State.init("isolation.local_producer", loc);
    producer_state.addTypes(&.{i64_type});
    const producer = try ctx.createOperation(producer_state);
    try isolated_block.addOperation(producer);

    var child_state = Operation.State.init("isolation.local_non_isolated_child", loc);
    child_state.addRegion();
    const child = try ctx.createOperation(child_state);
    try isolated_block.addOperation(child);
    const child_block = try child.getRegion(0).?.addBlock();

    var consumer_state = Operation.State.init("isolation.local_consumer", loc);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    const consumer = try ctx.createOperation(consumer_state);
    try child_block.addOperation(consumer);

    var options = default_options;
    options.check_terminators = false;
    try verifyOperation(isolated, options);
}

test "isolation coordination preserves custom trait verifier" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const core_traits = @import("traits.zig");

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), Context.Limits.testing);
    defer ctx.deinit(arena.allocator());
    try ctx.allowUnregistered();

    const Hooks = struct {
        fn fail(_: *const anyopaque) anyerror!void {
            return error.CustomIsolationVerifierRan;
        }

        const vtable: interfaces.TraitVTable = .{ .verify_regions = fail };
    };
    try ctx.registerTraitDefinition(.{
        .id = core_traits.IsolatedFromAbove.id,
        .vtable = &Hooks.vtable,
    });
    const isolated_name = "isolation.custom_verifier";
    try ctx.registerOperationTraitId(isolated_name, core_traits.IsolatedFromAbove.id);

    var state = Operation.State.init(isolated_name, .unknown);
    state.addRegion();
    const isolated = try ctx.createOperation(state);
    _ = try isolated.getRegion(0).?.addBlock();

    var options = default_options;
    options.check_terminators = false;
    try testing.expectError(error.CustomIsolationVerifierRan, verifyOperation(isolated, options));
}

test "isolation failure preserves nested operation verifier precedence" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const core_traits = @import("traits.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try Context.init(allocator, Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const isolated_name = "isolation.precedence_root";
    const failing_name = "isolation.precedence_failing";
    try core_traits.registerOperationTrait(&ctx, isolated_name, core_traits.IsolatedFromAbove);
    const Hooks = struct {
        fn fail(_: *const anyopaque) anyerror!void {
            return error.NestedOperationVerifierRan;
        }
    };
    try ctx.registerOperationInterface(failing_name, VerifyOpInterface.entryFor(Hooks.fail));

    const value_type = try ctx.getDialectTypeFromName("isolation.i64");
    var outer_state = Operation.State.init("isolation.precedence_outer", .unknown);
    outer_state.addRegion();
    const outer = try ctx.createOperation(outer_state);
    const outer_block = try outer.getRegion(0).?.addBlock();
    var producer_state = Operation.State.init("isolation.precedence_producer", .unknown);
    producer_state.addTypes(&.{value_type});
    const producer = try ctx.createOperation(producer_state);
    try outer_block.addOperation(producer);

    var isolated_state = Operation.State.init(isolated_name, .unknown);
    isolated_state.addRegion();
    const isolated = try ctx.createOperation(isolated_state);
    try outer_block.addOperation(isolated);
    const isolated_block = try isolated.getRegion(0).?.addBlock();
    var consumer_state = Operation.State.init("isolation.precedence_consumer", .unknown);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    try isolated_block.addOperation(try ctx.createOperation(consumer_state));
    try isolated_block.addOperation(try ctx.createOperation(Operation.State.init(failing_name, .unknown)));

    const options = VerifyOptions{
        .recursive = true,
        .check_use_def = true,
        .check_local_dominance = false,
        .check_cfg = false,
    };
    try testing.expectError(error.NestedOperationVerifierRan, verifyOperation(isolated, options));
}

test "dialect region verifier runs after nested operation verifier" {
    const testing = std.testing;
    const dialects = @import("root.zig").dialects;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const Hooks = struct {
        fn verifyChild(_: *const anyopaque) anyerror!void {
            return error.ChildVerifierRan;
        }

        fn verifyParentRegions(_: *const anyopaque) anyerror!void {
            return error.ParentRegionVerifierRan;
        }
    };

    const DialectForTest = struct {
        pub const name = "phase";
        const op_specs = dialects.opSpec.dialect(@This());

        pub const ParentOp = struct {
            pub const operation_spec = op_specs.define(.{ .mnemonic = "parent" });
            pub const operation_name = operation_spec.name;
            pub const verifyRegions = Hooks.verifyParentRegions;
        };

        pub const ChildOp = struct {
            pub const operation_spec = op_specs.define(.{ .mnemonic = "child" });
            pub const operation_name = operation_spec.name;
            pub const verify = Hooks.verifyChild;
        };

        pub const spec = dialects.dialectSpec(@This(), .{});
    };

    try dialects.loadDialectSpec(&ctx, DialectForTest.spec);

    const loc = Location.getUnknown();
    var parent_state = Operation.State.init(DialectForTest.ParentOp.operation_name, loc);
    parent_state.addRegion();
    const parent = try ctx.createOperation(parent_state);
    const block = try parent.getRegion(0).?.addBlock();
    const child_state = Operation.State.init(DialectForTest.ChildOp.operation_name, loc);
    const child = try ctx.createOperation(child_state);
    try block.addOperation(child);

    const result = verifyOperation(parent, default_options);
    try testing.expectError(error.ChildVerifierRan, result);
}
