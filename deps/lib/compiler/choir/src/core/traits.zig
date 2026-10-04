const std = @import("std");
const Operation = @import("operation/root.zig").Operation;
const Block = @import("block.zig").Block;
const Value = @import("value.zig").Value;
const Context = @import("context/root.zig").Context;
const interfaces = @import("interfaces/root.zig");

pub const TraitError = error{
    OperandCountMismatch,
    ResultCountMismatch,
    RegionCountMismatch,
    SingleBlockRegionMismatch,
    ImplicitTerminatorMismatch,
    TerminatorNotLast,
    IsolatedFromAbove,
    SameOperandsAndResultTypeMismatch,
    SameTypeOperandsMismatch,
    TypesMatchWithMismatch,
};

fn isValueWithin(root: *const Operation, value: *const Value) bool {
    return switch (value.kind) {
        .block_argument => |info| blk: {
            const block: *const Block = @ptrCast(@alignCast(info.owner));
            const parent_op = block.getParentOperation() orelse break :blk false;
            break :blk root.isAncestor(parent_op);
        },
        .op_result => |info| root.isProperAncestor(@ptrCast(@alignCast(info.owner))),
    };
}

pub fn verifyOperandsWithin(root: *const Operation, candidate: *const Operation) TraitError!void {
    for (candidate.operands.items) |operand| {
        if (!isValueWithin(root, operand.value)) {
            return TraitError.IsolatedFromAbove;
        }
    }
}

fn verifyOperationOperandsWithin(root: *const Operation, candidate: *const Operation, check_candidate: bool) TraitError!void {
    if (check_candidate) {
        try verifyOperandsWithin(root, candidate);
    }

    for (candidate.regions.items) |*region| {
        var block = region.blocks.head;
        while (block) |current_block| {
            var op_node = current_block.operations.head;
            while (op_node) |node| {
                const nested_op: *const Operation = @ptrCast(@alignCast(node));
                try verifyOperationOperandsWithin(root, nested_op, true);
                op_node = nested_op.next_op;
            }
            block = current_block.next;
        }
    }
}

fn verifySingleBlockRegions(op: *const Operation) TraitError!void {
    for (op.regions.items) |region| {
        if (!region.hasOneBlock()) return TraitError.SingleBlockRegionMismatch;
    }
}

pub fn registerOperationTrait(ctx: *Context, op_name: []const u8, comptime Trait: type) anyerror!void {
    if (@hasDecl(Trait, "traits")) {
        _ = try ctx.registerOperation(op_name, Trait.traits);
    }

    ctx.registerTraitDefinition(Trait.entry()) catch |err| switch (err) {
        error.DuplicateTrait => {},
        else => return err,
    };

    try ctx.registerOperationTraitId(op_name, Trait.id);
}

pub fn NOperands(comptime count: usize) type {
    return struct {
        pub const trait_name = std.fmt.comptimePrint("ir.trait.n_operands.{d}", .{count});
        pub const id: interfaces.TraitId = interfaces.traitId(trait_name);

        fn verify(op_ptr: *const anyopaque) anyerror!void {
            const op: *const Operation = @ptrCast(@alignCast(op_ptr));
            if (op.operands.items.len != count) return TraitError.OperandCountMismatch;
        }

        pub const vtable: interfaces.TraitVTable = .{ .verify = verify };

        pub fn entry() interfaces.TraitEntry {
            return .{ .id = id, .vtable = &vtable };
        }
    };
}

pub fn NResults(comptime count: usize) type {
    return struct {
        pub const trait_name = std.fmt.comptimePrint("ir.trait.n_results.{d}", .{count});
        pub const id: interfaces.TraitId = interfaces.traitId(trait_name);

        fn verify(op_ptr: *const anyopaque) anyerror!void {
            const op: *const Operation = @ptrCast(@alignCast(op_ptr));
            if (op.results.items.len != count) return TraitError.ResultCountMismatch;
        }

        pub const vtable: interfaces.TraitVTable = .{ .verify = verify };

        pub fn entry() interfaces.TraitEntry {
            return .{ .id = id, .vtable = &vtable };
        }
    };
}

pub const ZeroOperands = NOperands(0);
pub const OneOperand = NOperands(1);
pub const ZeroResults = NResults(0);
pub const OneResult = NResults(1);

pub fn NRegions(comptime count: usize) type {
    return struct {
        pub const trait_name = std.fmt.comptimePrint("ir.trait.n_regions.{d}", .{count});
        pub const id: interfaces.TraitId = interfaces.traitId(trait_name);

        fn verify(op_ptr: *const anyopaque) anyerror!void {
            const op: *const Operation = @ptrCast(@alignCast(op_ptr));
            if (op.regions.items.len != count) return TraitError.RegionCountMismatch;
        }

        pub const vtable: interfaces.TraitVTable = .{ .verify = verify };

        pub fn entry() interfaces.TraitEntry {
            return .{ .id = id, .vtable = &vtable };
        }
    };
}

pub fn AtLeastNRegions(comptime count: usize) type {
    return struct {
        pub const trait_name = std.fmt.comptimePrint("ir.trait.at_least_n_regions.{d}", .{count});
        pub const id: interfaces.TraitId = interfaces.traitId(trait_name);

        fn verify(op_ptr: *const anyopaque) anyerror!void {
            const op: *const Operation = @ptrCast(@alignCast(op_ptr));
            if (op.regions.items.len < count) return TraitError.RegionCountMismatch;
        }

        pub const vtable: interfaces.TraitVTable = .{ .verify = verify };

        pub fn entry() interfaces.TraitEntry {
            return .{ .id = id, .vtable = &vtable };
        }
    };
}

pub fn AtMostNRegions(comptime count: usize) type {
    return struct {
        pub const trait_name = std.fmt.comptimePrint("ir.trait.at_most_n_regions.{d}", .{count});
        pub const id: interfaces.TraitId = interfaces.traitId(trait_name);

        fn verify(op_ptr: *const anyopaque) anyerror!void {
            const op: *const Operation = @ptrCast(@alignCast(op_ptr));
            if (op.regions.items.len > count) return TraitError.RegionCountMismatch;
        }

        pub const vtable: interfaces.TraitVTable = .{ .verify = verify };

        pub fn entry() interfaces.TraitEntry {
            return .{ .id = id, .vtable = &vtable };
        }
    };
}

pub const ZeroRegions = NRegions(0);
pub const OneRegion = NRegions(1);

pub const SingleBlock = struct {
    pub const trait_name = "ir.trait.single_block";
    pub const id: interfaces.TraitId = interfaces.traitId(trait_name);

    fn verify(op_ptr: *const anyopaque) anyerror!void {
        const op: *const Operation = @ptrCast(@alignCast(op_ptr));
        try verifySingleBlockRegions(op);
    }

    pub const vtable: interfaces.TraitVTable = .{ .verify_regions = verify };

    pub fn entry() interfaces.TraitEntry {
        return .{ .id = id, .vtable = &vtable };
    }
};

pub fn SingleBlockImplicitTerminator(comptime terminator_name: []const u8) type {
    return struct {
        pub const trait_name = std.fmt.comptimePrint(
            "ir.trait.single_block_implicit_terminator.{s}",
            .{terminator_name},
        );
        pub const id: interfaces.TraitId = interfaces.traitId(trait_name);

        fn verify(op_ptr: *const anyopaque) anyerror!void {
            const op: *const Operation = @ptrCast(@alignCast(op_ptr));
            try verifySingleBlockRegions(op);
            for (op.regions.items) |region| {
                const block = region.getEntryBlock() orelse return TraitError.SingleBlockRegionMismatch;
                const term_any = block.getTerminator() orelse return TraitError.ImplicitTerminatorMismatch;
                const term: *const Operation = @ptrCast(@alignCast(term_any));
                if (!std.mem.eql(u8, term.name.name, terminator_name)) {
                    return TraitError.ImplicitTerminatorMismatch;
                }
            }
        }

        pub const vtable: interfaces.TraitVTable = .{ .verify_regions = verify };

        pub fn entry() interfaces.TraitEntry {
            return .{ .id = id, .vtable = &vtable };
        }
    };
}

pub const Terminator = struct {
    pub const trait_name = "ir.trait.terminator";
    pub const id: interfaces.TraitId = interfaces.traitId(trait_name);
    pub const traits = interfaces.OperationTraits{ .is_terminator = true };

    fn verify(op_ptr: *const anyopaque) anyerror!void {
        const op: *const Operation = @ptrCast(@alignCast(op_ptr));
        if (op.getBlock() == null) return;
        if (op.next_op != null) return TraitError.TerminatorNotLast;
    }

    pub const vtable: interfaces.TraitVTable = .{ .verify = verify };

    pub fn entry() interfaces.TraitEntry {
        return .{ .id = id, .vtable = &vtable };
    }
};

pub const NoTerminator = struct {
    pub const trait_name = "ir.trait.no_terminator";
    pub const id: interfaces.TraitId = interfaces.traitId(trait_name);
    pub const traits = interfaces.OperationTraits{ .has_no_terminator = true };

    fn verify(op_ptr: *const anyopaque) anyerror!void {
        const op: *const Operation = @ptrCast(@alignCast(op_ptr));
        try verifySingleBlockRegions(op);
    }

    pub const vtable: interfaces.TraitVTable = .{ .verify_regions = verify };

    pub fn entry() interfaces.TraitEntry {
        return .{ .id = id, .vtable = &vtable };
    }
};

pub const HasOnlyGraphRegion = struct {
    pub const trait_name = "ir.trait.has_only_graph_region";
    pub const id: interfaces.TraitId = interfaces.traitId(trait_name);
    pub const traits = interfaces.OperationTraits{ .has_only_graph_regions = true };

    pub const vtable: interfaces.TraitVTable = .{};

    pub fn entry() interfaces.TraitEntry {
        return .{ .id = id, .vtable = &vtable };
    }
};

pub const SameOperandsAndResultType = struct {
    pub const trait_name = "ir.trait.same_operands_and_result_type";
    pub const id: interfaces.TraitId = interfaces.traitId(trait_name);

    fn verify(op_ptr: *const anyopaque) anyerror!void {
        const op: *const Operation = @ptrCast(@alignCast(op_ptr));
        if (op.results.items.len == 0) return TraitError.SameOperandsAndResultTypeMismatch;
        if (op.operands.items.len == 0) return TraitError.SameOperandsAndResultTypeMismatch;

        const ref_type = op.results.items[0].type;
        for (op.results.items) |result| {
            if (!result.type.eql(ref_type)) return TraitError.SameOperandsAndResultTypeMismatch;
        }
        for (op.operands.items) |operand| {
            if (!operand.value.type.eql(ref_type)) return TraitError.SameOperandsAndResultTypeMismatch;
        }
    }

    pub const vtable: interfaces.TraitVTable = .{ .verify = verify };

    pub fn entry() interfaces.TraitEntry {
        return .{ .id = id, .vtable = &vtable };
    }
};

pub const SameTypeOperands = struct {
    pub const trait_name = "ir.trait.same_type_operands";
    pub const id: interfaces.TraitId = interfaces.traitId(trait_name);

    fn verify(op_ptr: *const anyopaque) anyerror!void {
        const op: *const Operation = @ptrCast(@alignCast(op_ptr));
        if (op.operands.items.len < 2) return;

        const ref_type = op.operands.items[0].value.type;
        for (op.operands.items[1..]) |operand| {
            if (!operand.value.type.eql(ref_type)) {
                return TraitError.SameTypeOperandsMismatch;
            }
        }
    }

    pub const vtable: interfaces.TraitVTable = .{ .verify = verify };

    pub fn entry() interfaces.TraitEntry {
        return .{ .id = id, .vtable = &vtable };
    }
};

pub const TypeRef = union(enum) {
    operand: usize,
    result: usize,
};

pub const TypesMatchWithConfig = struct {
    label: []const u8,
    target: TypeRef,
    source: TypeRef,
};

pub fn TypesMatchWith(comptime config: TypesMatchWithConfig) type {
    return struct {
        pub const trait_name = std.fmt.comptimePrint(
            "ir.trait.types_match_with.{s}.{s}{d}_{s}{d}",
            .{
                config.label,
                @tagName(config.target),
                switch (config.target) {
                    inline else => |idx| idx,
                },
                @tagName(config.source),
                switch (config.source) {
                    inline else => |idx| idx,
                },
            },
        );
        pub const id: interfaces.TraitId = interfaces.traitId(trait_name);

        fn typeAt(op: *const Operation, ref: TypeRef) ?@import("type.zig").Type {
            return switch (ref) {
                .operand => |idx| if (idx < op.operands.items.len)
                    op.operands.items[idx].value.type
                else
                    null,
                .result => |idx| if (idx < op.results.items.len)
                    op.results.items[idx].type
                else
                    null,
            };
        }

        fn verify(op_ptr: *const anyopaque) anyerror!void {
            const op: *const Operation = @ptrCast(@alignCast(op_ptr));
            const target_type = typeAt(op, config.target) orelse
                return TraitError.TypesMatchWithMismatch;
            const source_type = typeAt(op, config.source) orelse
                return TraitError.TypesMatchWithMismatch;
            if (!target_type.eql(source_type)) {
                return TraitError.TypesMatchWithMismatch;
            }
        }

        pub const vtable: interfaces.TraitVTable = .{ .verify = verify };

        pub fn entry() interfaces.TraitEntry {
            return .{ .id = id, .vtable = &vtable };
        }
    };
}

pub const IsolatedFromAbove = struct {
    pub const trait_name = "ir.trait.isolated_from_above";
    pub const id: interfaces.TraitId = interfaces.traitId(trait_name);

    fn verify(op_ptr: *const anyopaque) anyerror!void {
        const op: *const Operation = @ptrCast(@alignCast(op_ptr));
        try verifyOperationOperandsWithin(op, op, false);
    }

    pub const vtable: interfaces.TraitVTable = .{ .verify_regions = verify };

    pub fn entry() interfaces.TraitEntry {
        return .{ .id = id, .vtable = &vtable };
    }
};

pub const SymbolTable = struct {
    pub const trait_name = "ir.trait.symbol_table";
    pub const id: interfaces.TraitId = interfaces.traitId(trait_name);
    pub const traits = interfaces.OperationTraits{ .is_symbol_table = true };

    fn verify(op_ptr: *const anyopaque) anyerror!void {
        const op: *Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        try @import("symbols.zig").SymbolTable.verifyOperation(op);
    }

    pub const vtable: interfaces.TraitVTable = .{ .verify_regions = verify };

    pub fn entry() interfaces.TraitEntry {
        return .{ .id = id, .vtable = &vtable };
    }
};
