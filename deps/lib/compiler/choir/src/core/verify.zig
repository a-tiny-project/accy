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
