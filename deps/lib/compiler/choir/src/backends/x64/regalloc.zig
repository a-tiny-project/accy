const std = @import("std");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const shared = @import("../root.zig").regalloc;
const registers = @import("registers/root.zig");
const abi = @import("abi.zig");
const call_plan = @import("calls.zig");
const scalar = @import("scalar.zig");

const GPR = registers.GPR;
const XMM = registers.XMM;
const ArithDialect = dialects.ArithDialect;
const FuncDialect = dialects.FuncDialect;
const MemrefDialect = dialects.MemrefDialect;
const ScfDialect = dialects.ScfDialect;

const caller_saved_homes = registers.allocatable_gprs;
const callee_saved_homes = [_]GPR{ .rbx, .r12, .r13, .r14, .r15 };
const interval_homes = caller_saved_homes ++ callee_saved_homes;

const i64_type_name = "arith.i64";
const index_type_name = "arith.index";
const bool_type_name = "arith.bool";

const eligible_mnemonics = [_][]const u8{
    "arith.add",
    "arith.sub",
    "arith.mul",
    "arith.neg",
    "arith.abs",
    "arith.div",
    "arith.rem",
    "arith.max",
    "arith.min",
    "arith.and",
    "arith.or",
    "arith.xor",
    "arith.not",
    "arith.shl",
    "arith.shr",
    "arith.ushr",
    "arith.cmp",
    "arith.select",
    "arith.constant",
    "func.call",
    "func.syscall",
    "scf.while",
    "scf.condition",
    "scf.yield",
    "arith.addo",
    "arith.subo",
    "arith.mulo",
};

fn isOverflowOp(op: *const ir.Operation) bool {
    inline for (.{ ArithDialect.AddoOp, ArithDialect.SuboOp, ArithDialect.MuloOp }) |Op| {
        if (std.mem.eql(u8, op.name.name, Op.operation_name)) return true;
    }
    return false;
}

fn isEligibleOp(name: []const u8) bool {
    if (std.mem.eql(u8, name, "func.return")) return true;
    for (eligible_mnemonics) |mnemonic| {
        if (std.mem.eql(u8, name, mnemonic)) return true;
    }
    return false;
}

const float_eligible_mnemonics = [_][]const u8{
    "arith.add",
    "arith.sub",
    "arith.mul",
    "arith.div",
    "arith.neg",
    "arith.max",
    "arith.min",
};

fn isFloatEligibleOp(name: []const u8) bool {
    for (float_eligible_mnemonics) |mnemonic| {
        if (std.mem.eql(u8, name, mnemonic)) return true;
    }
    return false;
}

fn typeName(value: *const ir.Value) ?[]const u8 {
    return value.type.getDialectTypeName();
}

fn isBool(value: *const ir.Value) bool {
    const name = typeName(value) orelse return false;
    return std.mem.eql(u8, name, bool_type_name);
}

fn isRegisterScalar(value: *const ir.Value) bool {
    const name = typeName(value) orelse return false;
    return std.mem.eql(u8, name, i64_type_name) or
        std.mem.eql(u8, name, index_type_name) or
        std.mem.eql(u8, name, bool_type_name) or
        std.mem.eql(u8, name, "arith.i32") or
        std.mem.eql(u8, name, "arith.u32");
}

fn isMemref(value: *const ir.Value) bool {
    const name = typeName(value) orelse return false;
    return std.mem.eql(u8, name, MemrefDialect.name);
}

fn isFloatScalar(value: *const ir.Value) bool {
    const name = typeName(value) orelse return false;
    return std.mem.eql(u8, name, "arith.f32") or std.mem.eql(u8, name, "arith.f64");
}

fn isPacked128(value: *const ir.Value) bool {
    const name = typeName(value) orelse return false;
    return packedTypeName(name);
}

fn packedTypeName(name: []const u8) bool {
    const info = dialects.arith.parseVectorTypeName(name) orelse return false;
    if (info.width == 4) {
        return std.mem.eql(u8, info.elem_type_name, "arith.f32") or
            std.mem.eql(u8, info.elem_type_name, "arith.i32") or
            std.mem.eql(u8, info.elem_type_name, "arith.u32");
    }
    if (info.width == 2) {
        return std.mem.eql(u8, info.elem_type_name, "arith.f64") or
            std.mem.eql(u8, info.elem_type_name, "arith.i64") or
            std.mem.eql(u8, info.elem_type_name, "arith.u64");
    }
    return false;
}

fn isPackedFloat128(value: *const ir.Value) bool {
    const name = typeName(value) orelse return false;
    const info = dialects.arith.parseVectorTypeName(name) orelse return false;
    return (info.width == 4 and std.mem.eql(u8, info.elem_type_name, "arith.f32")) or
        (info.width == 2 and std.mem.eql(u8, info.elem_type_name, "arith.f64"));
}

fn isXmmHomeable(value: *const ir.Value) bool {
    return isFloatScalar(value) or isPacked128(value);
}

/// Whether the value an operation defines is the frame address a `memref.alloca` reserved.
///
/// `memory.emitAlloca` computes that address into the frame slot the value was given and writes it
/// nowhere else, so a register home for it would be read before anything wrote it.
fn isAllocaAddress(value: *const ir.Value) bool {
    const owner = value.getDefiningOp() orelse return false;
    const op: *ir.Operation = @ptrCast(@alignCast(owner));
    return std.mem.eql(u8, op.name.name, MemrefDialect.AllocaOp.operation_name);
}

fn isGprHomeable(value: *const ir.Value) bool {
    if (isAllocaAddress(value)) return false;
    return isRegisterScalar(value) or isMemref(value);
}

fn isCarriedScalar(value: *const ir.Value) bool {
    return isGprHomeable(value) or isFloatScalar(value);
}

fn isBlockArgumentEligible(value: *const ir.Value) bool {
    return isCarriedScalar(value);
}

fn allResultsRegisterScalar(op: *ir.Operation) bool {
    for (op.results.items) |*result| {
        if (!isRegisterScalar(result)) return false;
    }
    return true;
}

fn allOperandsRegisterScalar(op: *ir.Operation) bool {
    for (op.operands.items) |operand| {
        if (!isRegisterScalar(operand.value)) return false;
    }
    return true;
}

fn allResultsFloatScalar(op: *ir.Operation) bool {
    for (op.results.items) |*result| {
        if (!isFloatScalar(result)) return false;
    }
    return true;
}

fn allOperandsFloatScalar(op: *ir.Operation) bool {
    for (op.operands.items) |operand| {
        if (!isFloatScalar(operand.value)) return false;
    }
    return true;
}

fn allOperandsCarriedScalar(op: *ir.Operation) bool {
    for (op.operands.items) |operand| {
        if (!isCarriedScalar(operand.value)) return false;
    }
    return true;
}

fn allResultsCarriedScalar(op: *ir.Operation) bool {
    for (op.results.items) |*result| {
        if (!isCarriedScalar(result)) return false;
    }
    return true;
}

fn allResultsPacked128(op: *ir.Operation) bool {
    for (op.results.items) |*result| {
        if (!isPacked128(result)) return false;
    }
    return true;
}

fn allOperandsPacked128(op: *ir.Operation) bool {
    for (op.operands.items) |operand| {
        if (!isPacked128(operand.value)) return false;
    }
    return true;
}

fn isPackedEligibleOp(op: *ir.Operation) bool {
    const name = op.name.name;
    if (std.mem.eql(u8, name, ArithDialect.AddOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.SubOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.AndOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.OrOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.XorOp.operation_name))
    {
        return allResultsPacked128(op) and allOperandsPacked128(op);
    }
    if (std.mem.eql(u8, name, ArithDialect.MulOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.DivOp.operation_name))
    {
        if (!allResultsPacked128(op) or !allOperandsPacked128(op)) return false;
        if (std.mem.eql(u8, name, ArithDialect.DivOp.operation_name)) {
            const result = op.getResult(0) orelse return false;
            return isPackedFloat128(result);
        }
        return true;
    }
    if (std.mem.eql(u8, name, ArithDialect.SplatOp.operation_name)) {
        if (op.operands.items.len != 1 or op.results.items.len != 1) return false;
        const operand = op.getOperand(0) orelse return false;
        const result = op.getResult(0) orelse return false;
        return (isFloatScalar(operand) or isRegisterScalar(operand)) and isPacked128(result);
    }
    if (std.mem.eql(u8, name, ArithDialect.VecConstantOp.operation_name)) {
        return op.operands.items.len == 0 and allResultsPacked128(op);
    }
    return false;
}

fn isEligibleCast(op: *ir.Operation) bool {
    if (op.operands.items.len != 1 or op.results.items.len != 1) return false;
    return allOperandsRegisterScalar(op) and allResultsRegisterScalar(op);
}

fn isScalarWord(value: *const ir.Value) bool {
    const name = typeName(value) orelse return false;
    return std.mem.eql(u8, name, "arith.i32") or std.mem.eql(u8, name, "arith.u32") or
        std.mem.eql(u8, name, "arith.i64") or std.mem.eql(u8, name, "arith.u64");
}

fn isEligibleBitcast(op: *ir.Operation) bool {
    if (op.operands.items.len != 1 or op.results.items.len != 1) return false;
    const operand = op.getOperand(0) orelse return false;
    const result = op.getResult(0) orelse return false;
    if (isScalarWord(operand) and isFloatScalar(result)) return true;
    if (isFloatScalar(operand) and isScalarWord(result)) return true;
    return false;
}

/// A static `memref.alloca` reserves a frame slot and computes its address. It costs the frame the
/// bytes its type states whether or not this allocator runs, because `Emitter.collectSlotsInRegion`
/// reserves the payload after allocation is over, so admitting it here moves no byte of the cell
/// and only stops the rest of the function from being refused over it.
///
/// A dynamic `memref.alloca` carries the size as its one operand and moves the stack pointer, which
/// this allocator's frame reasoning does not model, so it stays refused.
fn isEligibleStaticAlloca(op: *ir.Operation) bool {
    if (op.operands.items.len != 0) return false;
    if (op.results.items.len != 1) return false;
    const result = op.getResult(0) orelse return false;
    return isMemref(result);
}

fn isEligibleMemrefLoad(op: *ir.Operation) bool {
    if (op.operands.items.len != 2 or op.results.items.len != 1) return false;
    const memref_val = op.getOperand(0) orelse return false;
    const index_val = op.getOperand(1) orelse return false;
    if (!isMemref(memref_val) or !isRegisterScalar(index_val)) return false;
    const result = op.getResult(0) orelse return false;
    return isRegisterScalar(result) or isFloatScalar(result) or isPacked128(result);
}

fn isEligibleMemrefStore(op: *ir.Operation) bool {
    if (op.operands.items.len != 3 or op.results.items.len != 0) return false;
    const value = op.getOperand(0) orelse return false;
    const memref_val = op.getOperand(1) orelse return false;
    const index_val = op.getOperand(2) orelse return false;
    if (!isMemref(memref_val) or !isRegisterScalar(index_val)) return false;
    return isRegisterScalar(value) or isFloatScalar(value) or isPacked128(value);
}

fn isEligibleScalarOp(op: *ir.Operation) bool {
    const name = op.name.name;
    if (std.mem.eql(u8, name, ArithDialect.ConstantOp.operation_name)) {
        for (op.results.items) |*result| {
            if (!isRegisterScalar(result) and !isFloatScalar(result)) return false;
        }
        return op.operands.items.len == 0;
    }
    if (std.mem.eql(u8, name, ArithDialect.CastOp.operation_name)) {
        return isEligibleCast(op);
    }
    if (std.mem.eql(u8, name, ArithDialect.BitcastOp.operation_name)) {
        return isEligibleBitcast(op);
    }
    if (std.mem.eql(u8, name, MemrefDialect.AllocaOp.operation_name)) {
        return isEligibleStaticAlloca(op);
    }
    if (std.mem.eql(u8, name, MemrefDialect.LoadOp.operation_name)) {
        return isEligibleMemrefLoad(op);
    }
    if (std.mem.eql(u8, name, MemrefDialect.StoreOp.operation_name)) {
        return isEligibleMemrefStore(op);
    }

    if (isEligibleOp(name) and allResultsRegisterScalar(op) and allOperandsRegisterScalar(op)) return true;
    if (isFloatEligibleOp(name) and allResultsFloatScalar(op) and allOperandsFloatScalar(op)) return true;
    return isPackedEligibleOp(op);
}

const BlockKind = enum {
    entry,
    nested,
    if_branch,
};

fn isEligibleOperation(op: *ir.Operation, kind: BlockKind) bool {
    if (op.successors.items.len != 0) return false;

    const name = op.name.name;
    if (op.regions.items.len != 0) return false;
    if (std.mem.eql(u8, name, FuncDialect.ReturnOp.operation_name)) {
        return kind == .entry and allOperandsRegisterScalar(op);
    }
    if (std.mem.eql(u8, name, ScfDialect.YieldOp.operation_name)) {
        return kind != .entry and allOperandsCarriedScalar(op);
    }
    if (std.mem.eql(u8, name, ScfDialect.ConditionOp.operation_name)) {
        return kind == .nested and allOperandsRegisterScalar(op);
    }
    return isEligibleScalarOp(op);
}

/// The facts one operation may declare that this probe reads without allocating. An operation
/// declaring more is refused, which costs it register allocation and never changes what it means.
/// No allocator or configurable limit reaches this probe, so the side an operation falls on is
/// a property of the program alone.
pub const ordered_probe_facts = 32;

/// Whether an operation declares an ordered event, which is the effect record an atomic or a
/// volatile access carries (`memref.atomic_load` and `memref.atomic_store` today).
///
/// A function holding one is refused by `isEligibleBlock`, so every value in it stays in its frame
/// slot. `memory.zig` relies on exactly that: its atomic path addresses memory through the fixed
/// scratch registers rcx, rdx and r8, which clobber nothing only while nothing is register homed.
/// The test is the effect record and not the mnemonic, so an ordered operation added after this
/// line inherits the refusal instead of quietly falling through a list it was never added to.
///
/// An operation this cannot read (no interface capacity, more facts than the probe holds, or a
/// collection that refuses) is treated as ordered. The conservative answer costs allocation and
/// never emits a different program.
fn holdsOrderedEffect(op: *ir.Operation) bool {
    const vtable = op.getInterface(ir.interfaces.EffectOpInterface) orelse return false;
    const count = vtable.capacity.count(
        op.getNumOperands(),
        op.getNumResults(),
        op.getNumRegions(),
    ) orelse return true;
    if (count > ordered_probe_facts) return true;
    var storage: [ordered_probe_facts]ir.interfaces.effects.Fact = undefined;
    const facts = ir.interfaces.effects.collectInto(op, storage[0..count]) catch return true;
    for (facts.records) |record| switch (record) {
        .event => |event| if (event.ordered) return true,
        else => {},
    };
    return false;
}

fn singleRegionBlock(region: *ir.Region) ?*ir.Block {
    const block = region.blocks.head orelse return null;
    if (block.next != null) return null;
    return block;
}

fn isEligibleBlock(block: *ir.Block, kind: BlockKind) bool {
    for (block.arguments.items) |arg| {
        if (!isBlockArgumentEligible(arg)) return false;
    }

    var saw_terminator = false;
    var op_iter = block.operations.head;
    while (op_iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        const name = op.name.name;

        if (holdsOrderedEffect(op)) return false;

        if (std.mem.eql(u8, name, ScfDialect.IfOp.operation_name)) {
            if (op.successors.items.len != 0) return false;
            if (!allResultsRegisterScalar(op)) return false;
            if (op.operands.items.len != 1) return false;
            if (!isBool(op.operands.items[0].value)) return false;
            if (op.results.items.len != 0 and op.regions.items.len != 2) return false;

            const if_op = ScfDialect.IfOp{ .op = op };
            if (!isEligibleBlock(if_op.getThenBlock(), .if_branch)) return false;
            if (if_op.getElseBlock()) |else_block| {
                if (!isEligibleBlock(else_block, .if_branch)) return false;
            } else if (op.results.items.len != 0) {
                return false;
            }

            op_iter = op.next_op;
            continue;
        }

        if (std.mem.eql(u8, name, ScfDialect.WhileOp.operation_name)) {
            if (op.successors.items.len != 0) return false;
            if (!allResultsRegisterScalar(op)) return false;
            if (!allOperandsRegisterScalar(op)) return false;
            for (op.regions.items) |*nested| {
                const nested_block = singleRegionBlock(nested) orelse return false;
                if (!isEligibleBlock(nested_block, .nested)) return false;
            }

            op_iter = op.next_op;
            continue;
        }

        if (std.mem.eql(u8, name, ScfDialect.ForOp.operation_name)) {
            if (op.successors.items.len != 0) return false;
            if (op.operands.items.len < 3) return false;
            if (!allResultsCarriedScalar(op)) return false;
            if (!allOperandsCarriedScalar(op)) return false;
            for (0..3) |bound_index| {
                const bound = op.getOperand(bound_index) orelse return false;
                if (!isRegisterScalar(bound)) return false;
            }
            for (op.regions.items) |*nested| {
                const nested_block = singleRegionBlock(nested) orelse return false;
                if (!isEligibleBlock(nested_block, .nested)) return false;
            }

            op_iter = op.next_op;
            continue;
        }

        if (!isEligibleOperation(op, kind)) return false;
        if (kind == .entry and std.mem.eql(u8, name, FuncDialect.ReturnOp.operation_name)) {
            saw_terminator = true;
        }
        if (kind == .if_branch and std.mem.eql(u8, name, ScfDialect.YieldOp.operation_name)) {
            saw_terminator = true;
        }
        op_iter = op.next_op;
    }
    return switch (kind) {
        .entry, .if_branch => saw_terminator,
        .nested => true,
    };
}

fn isEligibleFunction(region: *ir.Region) bool {
    const block = singleRegionBlock(region) orelse return false;
    return isEligibleBlock(block, .entry);
}

const GprMask = u16;
const XmmMask = u16;

pub const PositionPhase = shared.PositionPhase;

const ReloadRangeEnd = struct {
    end: u32,
    phase: PositionPhase,
};
pub const PositionPoint = shared.PositionPoint;
pub const ValueLocationRangeEntry = shared.ValueLocationRangeEntry;
pub const ValueLocationRangeExit = shared.ValueLocationRangeExit;
pub const ValueLocationRange = shared.ValueLocationRange(GPR);
pub const XmmValueLocationRange = shared.ValueLocationRange(XMM);
pub const ValueLocationIndex = shared.ValueLocationIndex(GPR);
pub const XmmValueLocationIndex = shared.ValueLocationIndex(XMM);

const FixedPositionKind = shared.FixedPositionKind;

pub fn Core(
    comptime Register: type,
    comptime Mask: type,
    comptime promotable: fn (value: *const ir.Value) bool,
) type {
    return struct {
        const Requirement: type = shared.Requirement(Register);
        const UsePosition: type = shared.UsePosition(Register, Mask);
        const FixedPosition: type = shared.FixedPosition(Register);
        const FixedPositionIndex: type = shared.FixedPositionIndex(Register);
        pub const Candidate: type = shared.Candidate(Register, Mask);
        pub const Candidates: type = shared.Candidates(Register, Mask);
        const Active: type = shared.Active(Register);
        const ActiveSet: type = shared.ActiveSet(Register);
        const AvailableRegister: type = shared.AvailableRegister(Register);
        const LocationRange: type = shared.ValueLocationRange(Register);
        const LocationIndex: type = shared.ValueLocationIndex(Register);

        const ReloadChoice = struct {
            reg: Register,
            end: ReloadRangeEnd,
        };

        const RegisterSelectionPolicy = struct {
            candidate: Candidate,
            fixed_positions: FixedPositionIndex,
            loop_intervals: []const shared.LoopInterval,

            pub fn blocksRegister(self: @This(), reg: Register) bool {
                return candidateConflictsWithRegisterConstraints(self.candidate, self.fixed_positions, reg);
            }

            pub fn availableUntil(self: @This(), reg: Register) ?PositionPoint {
                const until = residentAvailableUntil(self.candidate, self.fixed_positions, reg) orelse return null;
                if (shared.rangeCrossesLoopEntry(self.candidate.start(), self.candidate.end(), self.loop_intervals) and
                    until.lessThan(self.candidate.endPoint())) return null;
                return until;
            }

            pub fn canEvict(self: @This(), victim: Candidate) bool {
                if (shared.evictionUnsafeAt(victim.start(), self.candidate.start(), self.loop_intervals)) return false;
                return candidateHasHigherSpillPriority(self.candidate, victim);
            }

            pub fn prefersVictim(_: @This(), victim: Candidate, current: Candidate) bool {
                return candidateHasLowerSpillPriority(victim, current);
            }
        };

        inline fn locations(emitter: anytype) *std.AutoHashMapUnmanaged(*ir.Value, Register) {
            if (comptime Register == GPR) return &emitter.value_locations;
            return &emitter.xmm_locations;
        }

        inline fn locationRanges(emitter: anytype) *std.ArrayListUnmanaged(LocationRange) {
            if (comptime Register == GPR) return &emitter.value_location_ranges;
            return &emitter.xmm_location_ranges;
        }

        inline fn locationIndex(emitter: anytype) *LocationIndex {
            if (comptime Register == GPR) return &emitter.value_location_index;
            return &emitter.xmm_location_index;
        }

        fn appendCandidate(
            candidates: *Candidates,
            allocator: std.mem.Allocator,
            value: *ir.Value,
            start: u32,
            order: *u32,
            is_constant: bool,
            definition_requirement: Requirement,
            definition_source: Requirement,
        ) !void {
            if (!promotable(value)) return;
            const start_phase = shared.valueStartPhase(value);
            try candidates.append(allocator, .{
                .value = value,
                .range = .{
                    .start = start,
                    .end = start,
                    .end_phase = start_phase,
                },
                .use_positions = .empty,
                .definition = .{
                    .point = .{ .position = start, .phase = start_phase },
                    .requirement = definition_requirement,
                    .source = definition_source,
                },
                .order = order.*,
                .is_constant = is_constant,
            });
            order.* += 1;
        }

        fn appendFixedPosition(
            fixed_positions: *std.ArrayListUnmanaged(FixedPosition),
            allocator: std.mem.Allocator,
            position: u32,
            kind: FixedPositionKind,
            requirement: Requirement,
        ) !void {
            switch (requirement) {
                .any => {},
                .fixed => |reg| {
                    try fixed_positions.append(allocator, .{
                        .point = shared.fixedPositionPoint(position, kind),
                        .reg = reg,
                        .kind = kind,
                    });
                },
            }
        }
        fn regBit(reg: Register) Mask {
            return @as(Mask, 1) << @intCast(reg.id());
        }

        fn maskHasReg(mask: Mask, reg: Register) bool {
            return (mask & regBit(reg)) != 0;
        }
        fn recordUse(
            candidates: *Candidates,
            allocator: std.mem.Allocator,
            value: *ir.Value,
            point: PositionPoint,
            requirement: Requirement,
            source_blockers: Mask,
        ) !void {
            const candidate = candidates.getPtr(value) orelse return;
            try candidate.recordUse(allocator, point, requirement, source_blockers);
        }

        fn recordFixedSourceUse(
            candidates: *Candidates,
            fixed_positions: *std.ArrayListUnmanaged(FixedPosition),
            allocator: std.mem.Allocator,
            value: *ir.Value,
            point: PositionPoint,
            reg: Register,
            kind: FixedPositionKind,
            source_blockers: Mask,
        ) !void {
            const requirement: Requirement = .{ .fixed = reg };
            try recordUse(candidates, allocator, value, point, requirement, source_blockers);
            try appendFixedPosition(fixed_positions, allocator, point.position, kind, requirement);
        }
        fn appendScratchClobbers(
            fixed_positions: *std.ArrayListUnmanaged(FixedPosition),
            allocator: std.mem.Allocator,
            position: u32,
            regs: []const Register,
        ) !void {
            for (regs) |reg| {
                try fixed_positions.append(allocator, .{ .point = shared.fixedPositionPoint(position, .clobber), .reg = reg, .kind = .clobber });
            }
        }
        fn verifyAllocation(emitter: anytype, candidates: []const Candidate, fixed_positions: FixedPositionIndex) !void {
            const Verifier = shared.AllocationVerifier(Register, Mask);
            var verifier = try Verifier.init(emitter.allocator, .{
                .ranges = locationRanges(emitter).items,
                .candidates = candidates,
                .fixed_positions = fixed_positions,
            });
            defer verifier.deinit(emitter.allocator);
            verifier.activate() catch unreachable;
            try verifier.verify();
        }

        fn appendValueLocationRange(
            emitter: anytype,
            value: *ir.Value,
            start: u32,
            end: u32,
            reg: Register,
            entry: ValueLocationRangeEntry,
            end_phase: PositionPhase,
            exit: ValueLocationRangeExit,
        ) !void {
            const ranges = locationRanges(emitter);
            const old_len = ranges.items.len;
            try shared.appendValueLocationRange(
                Register,
                ranges,
                emitter.allocator,
                value,
                start,
                end,
                reg,
                entry,
                end_phase,
                exit,
            );
            if (ranges.items.len != old_len) {
                locationIndex(emitter).append(old_len, ranges.items[old_len]);
            }
        }

        fn closeActiveRange(
            emitter: anytype,
            candidates: []const Candidate,
            active: Active,
            end: u32,
            end_phase: PositionPhase,
            exit: ValueLocationRangeExit,
        ) !void {
            const candidate = candidates[active.candidate_index];
            try appendValueLocationRange(emitter, candidate.value, active.start, end, active.reg, .resident, end_phase, exit);
        }

        fn expireActive(emitter: anytype, active: *ActiveSet, candidates: []const Candidate, point: PositionPoint) !void {
            while (active.takeExpiredBefore(point)) |expired| {
                const candidate = candidates[expired.candidate_index];
                try closeActiveRange(emitter, candidates, expired, expired.end + 1, expired.end_phase, activeRangeExit(expired, candidate));
            }
        }

        fn closeRemainingActiveRanges(emitter: anytype, active: *ActiveSet, candidates: []const Candidate) !void {
            while (active.pop()) |entry| {
                const candidate = candidates[entry.candidate_index];
                try closeActiveRange(emitter, candidates, entry, entry.end + 1, entry.end_phase, activeRangeExit(entry, candidate));
            }
        }

        fn activeRangeExit(active: Active, candidate: Candidate) ValueLocationRangeExit {
            return if (active.endPoint().rank() == candidate.endPoint().rank()) .retain else .spill;
        }

        fn valueHasRangeAtPoint(emitter: anytype, value: *ir.Value, point: PositionPoint) bool {
            return locationIndex(emitter).valueHasRangeAtPoint(locationRanges(emitter).items, value, point);
        }

        fn registerBlocksAt(emitter: anytype, reg: Register, point: PositionPoint) bool {
            return locationIndex(emitter).registerBlocksAt(reg, point);
        }

        fn reloadRegisterAvailableAtUse(emitter: anytype, use: UsePosition, reg: Register) bool {
            if (maskHasReg(use.source_blockers, reg)) return false;
            if (registerBlocksAt(emitter, reg, use.point)) return false;
            return true;
        }

        fn reloadLocationRange(
            candidate: Candidate,
            use: UsePosition,
            end: u32,
            end_phase: PositionPhase,
            reg: Register,
        ) LocationRange {
            return .{
                .value = candidate.value,
                .start = use.point.position,
                .end = end,
                .reg = reg,
                .entry = .reload,
                .end_phase = end_phase,
            };
        }

        fn reloadRangeEndPoint(end: ReloadRangeEnd) PositionPoint {
            return .{ .position = end.end - 1, .phase = end.phase };
        }

        fn reloadRangeEndBeforePoint(point: PositionPoint) ReloadRangeEnd {
            return switch (point.phase) {
                .source => .{ .end = point.position, .phase = .definition },
                .definition => .{ .end = point.position + 1, .phase = .source },
            };
        }

        fn limitReloadRangeEnd(limit: *ReloadRangeEnd, point: PositionPoint) void {
            const candidate = reloadRangeEndBeforePoint(point);
            if (candidate.end == 0) return;
            if (reloadRangeEndPoint(candidate).lessThan(reloadRangeEndPoint(limit.*))) limit.* = candidate;
        }

        fn firstReloadRangeUseBlocker(
            candidate: Candidate,
            use: UsePosition,
            end: u32,
            end_phase: PositionPhase,
            reg: Register,
        ) ?PositionPoint {
            const proposed = reloadLocationRange(candidate, use, end, end_phase, reg);
            for (candidate.usesBetween(proposed.startPoint(), proposed.endPoint())) |candidate_use| {
                if (!maskHasReg(candidate_use.source_blockers, reg)) continue;
                return candidate_use.point;
            }
            return null;
        }

        fn reloadRangeEnd(
            emitter: anytype,
            candidate: Candidate,
            fixed_positions: FixedPositionIndex,
            use: UsePosition,
            reg: Register,
            loop_intervals: []const shared.LoopInterval,
        ) ReloadRangeEnd {
            const full_end = candidate.locationRangeEnd();
            const full_phase = candidate.endPhase();
            var limit = ReloadRangeEnd{ .end = full_end, .phase = full_phase };

            if (shared.innermostTrailing(use.point.position, loop_intervals)) |trailing| {
                const clamp = ReloadRangeEnd{ .end = trailing + 1, .phase = .source };
                if (reloadRangeEndPoint(clamp).lessThan(reloadRangeEndPoint(limit))) limit = clamp;
            }

            if (locationIndex(emitter).registerRangeFirstOverlapStart(
                locationRanges(emitter).items,
                candidate.value,
                use.point.position,
                full_end,
                reg,
                .reload,
                full_phase,
            )) |point| {
                limitReloadRangeEnd(&limit, point);
            }
            if (shared.candidateRangeFixedConflictStart(
                Register,
                Mask,
                candidate,
                fixed_positions,
                reloadLocationRange(candidate, use, full_end, full_phase, reg),
            )) |point| {
                limitReloadRangeEnd(&limit, point);
            }
            if (firstReloadRangeUseBlocker(candidate, use, full_end, full_phase, reg)) |point| {
                limitReloadRangeEnd(&limit, point);
            }

            const single_use = ReloadRangeEnd{ .end = use.point.position + 1, .phase = use.point.phase };
            if (reloadRangeEndPoint(limit).lessThan(reloadRangeEndPoint(single_use))) return single_use;
            return limit;
        }

        fn chooseBetterReloadChoice(best: ?ReloadChoice, choice: ReloadChoice) ReloadChoice {
            return if (best) |current| choice: {
                break :choice if (reloadRangeEndPoint(current.end).lessThan(reloadRangeEndPoint(choice.end))) choice else current;
            } else choice;
        }

        fn reloadChoiceForRegister(
            emitter: anytype,
            candidate: Candidate,
            fixed_positions: FixedPositionIndex,
            use: UsePosition,
            reg: Register,
            loop_intervals: []const shared.LoopInterval,
        ) ?ReloadChoice {
            if (!reloadRegisterAvailableAtUse(emitter, use, reg)) return null;
            const end = reloadRangeEnd(emitter, candidate, fixed_positions, use, reg, loop_intervals);
            if (shared.candidateRangeConflictsWithFixedPositions(
                Register,
                Mask,
                candidate,
                fixed_positions,
                reloadLocationRange(candidate, use, end.end, end.phase, reg),
            )) return null;
            return .{ .reg = reg, .end = end };
        }

        fn reloadChoiceForUse(
            emitter: anytype,
            candidate: Candidate,
            fixed_positions: FixedPositionIndex,
            use: UsePosition,
            homes: []const Register,
            loop_intervals: []const shared.LoopInterval,
        ) ?ReloadChoice {
            switch (use.requirement) {
                .fixed => |reg| {
                    return reloadChoiceForRegister(emitter, candidate, fixed_positions, use, reg, loop_intervals);
                },
                .any => {
                    var best: ?ReloadChoice = null;
                    for (homes) |reg| {
                        const choice = reloadChoiceForRegister(emitter, candidate, fixed_positions, use, reg, loop_intervals) orelse continue;
                        best = chooseBetterReloadChoice(best, choice);
                    }
                    return best;
                },
            }
        }

        fn appendReloadRanges(
            emitter: anytype,
            candidates: []const Candidate,
            fixed_positions: FixedPositionIndex,
            homes: []const Register,
            loop_intervals: []const shared.LoopInterval,
        ) !void {
            for (candidates) |candidate| {
                if (candidate.useCount() == 0) continue;
                if (locations(emitter).contains(candidate.value)) continue;
                for (candidate.use_positions.items) |use| {
                    if (valueHasRangeAtPoint(emitter, candidate.value, use.point)) continue;
                    const choice = reloadChoiceForUse(emitter, candidate, fixed_positions, use, homes, loop_intervals) orelse continue;
                    try appendValueLocationRange(emitter, candidate.value, use.point.position, choice.end.end, choice.reg, .reload, choice.end.phase, .retain);
                    markUsed(emitter, choice.reg);
                }
            }
        }

        fn candidateConflictsWithRegisterConstraints(candidate: Candidate, fixed_positions: FixedPositionIndex, reg: Register) bool {
            for (candidate.use_positions.items) |use| {
                if (maskHasReg(use.source_blockers, reg)) return true;
            }
            return candidate.conflictsWithFixedPositions(fixed_positions, reg);
        }

        fn residentLocationRange(candidate: Candidate, reg: Register) LocationRange {
            return .{
                .value = candidate.value,
                .start = candidate.start(),
                .end = candidate.locationRangeEnd(),
                .reg = reg,
                .entry = .resident,
                .end_phase = candidate.endPhase(),
            };
        }

        fn firstCandidateSourceBlocker(candidate: Candidate, reg: Register) ?PositionPoint {
            for (candidate.use_positions.items) |use| {
                if (!maskHasReg(use.source_blockers, reg)) continue;
                return use.point;
            }
            return null;
        }

        fn firstResidentConstraintStart(candidate: Candidate, fixed_positions: FixedPositionIndex, reg: Register) ?PositionPoint {
            var first = shared.candidateRangeFixedConflictStart(
                Register,
                Mask,
                candidate,
                fixed_positions,
                residentLocationRange(candidate, reg),
            );
            if (firstCandidateSourceBlocker(candidate, reg)) |point| {
                first = earlierPoint(first, point);
            }
            return first;
        }

        fn residentAvailableUntil(candidate: Candidate, fixed_positions: FixedPositionIndex, reg: Register) ?PositionPoint {
            const first_constraint = firstResidentConstraintStart(candidate, fixed_positions, reg) orelse return candidate.endPoint();
            if (!candidate.startPoint().lessThan(first_constraint)) return null;
            if (first_constraint.position == 0) return null;
            const until = PositionPoint.definition(first_constraint.position - 1);
            if (until.lessThan(candidate.startPoint())) return null;
            return until;
        }

        fn requirementSpillWeight(requirement: Requirement) u64 {
            return switch (requirement) {
                .any => 1,
                .fixed => 4,
            };
        }

        fn candidateSpillWeight(candidate: Candidate) u64 {
            var weight: u64 = if (candidate.is_constant) 1 else 2;
            weight += requirementSpillWeight(candidate.definition.requirement);
            weight += requirementSpillWeight(candidate.definition.source);
            for (candidate.use_positions.items) |use| {
                weight += 8 * requirementSpillWeight(use.requirement);
                weight += @popCount(use.source_blockers);
            }
            return weight;
        }

        fn candidateLength(candidate: Candidate) u64 {
            return @max(1, @as(u64, candidate.end() - candidate.start()));
        }

        fn candidateHasEarlierFutureUse(candidate: Candidate, victim: Candidate) ?bool {
            const point = candidate.startPoint();
            const candidate_use = candidate.firstUseAtOrAfter(point) orelse return false;
            const victim_use = victim.firstUseAtOrAfter(point) orelse return true;
            if (candidate_use.point.rank() == victim_use.point.rank()) return null;
            return candidate_use.point.lessThan(victim_use.point);
        }

        fn candidateHasHigherSpillPriority(candidate: Candidate, victim: Candidate) bool {
            if (candidateHasEarlierFutureUse(candidate, victim)) |higher| return higher;
            const candidate_weight = candidateSpillWeight(candidate);
            const victim_weight = candidateSpillWeight(victim);
            const candidate_score = candidate_weight * candidateLength(victim);
            const victim_score = victim_weight * candidateLength(candidate);
            if (candidate_score != victim_score) return candidate_score > victim_score;
            if (candidate_weight != victim_weight) return candidate_weight > victim_weight;
            return candidate.end() < victim.end();
        }

        fn candidateHasLowerSpillPriority(candidate: Candidate, victim: Candidate) bool {
            return candidateHasHigherSpillPriority(victim, candidate);
        }

        fn registerSelectionPolicy(
            candidate: Candidate,
            fixed_positions: FixedPositionIndex,
            loop_intervals: []const shared.LoopInterval,
        ) RegisterSelectionPolicy {
            return .{ .candidate = candidate, .fixed_positions = fixed_positions, .loop_intervals = loop_intervals };
        }

        fn bestFree(
            active: ActiveSet,
            fixed_positions: FixedPositionIndex,
            candidate: Candidate,
            homes: []const Register,
            loop_intervals: []const shared.LoopInterval,
        ) ?AvailableRegister {
            return shared.bestAvailableRegister(Register, active, homes, registerSelectionPolicy(candidate, fixed_positions, loop_intervals));
        }

        fn evictionCandidate(
            active: []const Active,
            candidates: []const Candidate,
            fixed_positions: FixedPositionIndex,
            candidate: Candidate,
            loop_intervals: []const shared.LoopInterval,
        ) ?usize {
            return shared.evictionCandidateIndex(Register, Candidate, active, candidates, registerSelectionPolicy(candidate, fixed_positions, loop_intervals));
        }

        fn markUsed(emitter: anytype, reg: Register) void {
            if (comptime Register != GPR) return;
            if (!reg.isCalleeSaved() or reg == .rbp) return;
            for (emitter.used_callee_saved_regs[0..emitter.reserved_callee_saved]) |used| {
                if (used == reg) return;
            }
            emitter.used_callee_saved_regs[emitter.reserved_callee_saved] = reg;
            emitter.reserved_callee_saved += 1;
        }

        fn prepareLocationIndex(
            emitter: anytype,
            candidates: []const Candidate,
            homes: []const Register,
        ) !void {
            var value_capacity: usize = 0;
            var position_count: usize = 0;
            var range_capacity: usize = 0;
            for (candidates) |candidate| {
                const use_count = candidate.useCount();
                if (use_count == 0) continue;
                value_capacity = std.math.add(usize, value_capacity, 1) catch
                    return error.OutOfMemory;
                position_count = @max(
                    position_count,
                    @as(usize, candidate.locationRangeEnd()) + 1,
                );
                const candidate_capacity = std.math.add(usize, use_count, 1) catch
                    return error.OutOfMemory;
                range_capacity = std.math.add(usize, range_capacity, candidate_capacity) catch
                    return error.OutOfMemory;
            }
            try locationIndex(emitter).prepare(
                emitter.allocator,
                value_capacity,
                position_count,
                range_capacity,
                homes.len,
            );
            for (candidates) |candidate| {
                if (candidate.useCount() != 0) locationIndex(emitter).includeValue(candidate.value);
            }
            try locationIndex(emitter).sealValues(emitter.allocator);
        }

        fn allocateIntervalHomes(
            emitter: anytype,
            candidates: *Candidates,
            fixed_positions: []FixedPosition,
            homes: []const Register,
            loop_intervals: []const shared.LoopInterval,
        ) !void {
            candidates.sort();
            const ordered = candidates.slice();
            try prepareLocationIndex(emitter, ordered, homes);
            var fixed_position_index_storage: FixedPositionIndex.Storage = undefined;
            const fixed_position_index = FixedPositionIndex.init(fixed_positions, &fixed_position_index_storage);

            var active = ActiveSet{};
            defer active.deinit(emitter.allocator);

            for (ordered, 0..) |candidate, candidate_index| {
                if (candidate.useCount() == 0) continue;
                try expireActive(emitter, &active, ordered, candidate.startPoint());
                const choice = bestFree(active, fixed_position_index, candidate, homes, loop_intervals) orelse choice: {
                    const victim_index = evictionCandidate(active.slice(), ordered, fixed_position_index, candidate, loop_intervals) orelse continue;
                    const victim = active.swapRemove(victim_index);
                    const evicted = ordered[victim.candidate_index];
                    try closeActiveRange(emitter, ordered, victim, candidate.start(), .definition, .spill);
                    _ = locations(emitter).remove(evicted.value);
                    break :choice AvailableRegister{ .reg = victim.reg, .until = candidate.endPoint() };
                };
                try active.append(emitter.allocator, .{
                    .start = candidate.start(),
                    .end = choice.until.position,
                    .end_phase = choice.until.phase,
                    .reg = choice.reg,
                    .candidate_index = candidate_index,
                });
                if (choice.until.rank() == candidate.endPoint().rank()) {
                    try locations(emitter).put(emitter.allocator, candidate.value, choice.reg);
                }
                markUsed(emitter, choice.reg);
            }
            try closeRemainingActiveRanges(emitter, &active, ordered);
            try appendReloadRanges(emitter, ordered, fixed_position_index, homes, loop_intervals);
            try verifyAllocation(emitter, ordered, fixed_position_index);
        }
    };
}

const GprCore = Core(GPR, GprMask, isGprHomeable);
const XmmCore = Core(XMM, XmmMask, isXmmHomeable);

const xmm_interval_homes = registers.allocatable_xmms;

const Books = struct {
    gpr_candidates: *GprCore.Candidates,
    gpr_fixed: *std.ArrayListUnmanaged(GprCore.FixedPosition),
    xmm_candidates: *XmmCore.Candidates,
    xmm_fixed: *std.ArrayListUnmanaged(XmmCore.FixedPosition),
};

fn xmmRequirementFromValueLocation(location: abi.ValueLocation) XmmCore.Requirement {
    return switch (location) {
        .fp_reg => |reg| .{ .fixed = reg },
        .int_reg, .stack => .any,
    };
}

fn requirementFromValueLocation(location: abi.ValueLocation) GprCore.Requirement {
    return switch (location) {
        .int_reg => |reg| .{ .fixed = reg },
        .fp_reg, .stack => .any,
    };
}

fn entryArgumentSources(
    block: *ir.Block,
    allocator: std.mem.Allocator,
    gpr_sources: []GprCore.Requirement,
    xmm_sources: []XmmCore.Requirement,
) !void {
    const function = entryFunction(block) orelse {
        @memset(gpr_sources, .any);
        @memset(xmm_sources, .any);
        return;
    };

    const hidden: usize = @intFromBool(abi.returnsThroughRecord(function.results.items.len));
    const arg_count = block.arguments.items.len + hidden;
    const arg_type_names = try allocator.alloc([]const u8, arg_count);
    defer allocator.free(arg_type_names);
    const arg_locations = try allocator.alloc(abi.ValueLocation, arg_count);
    defer allocator.free(arg_locations);

    if (hidden != 0) arg_type_names[0] = index_type_name;
    for (block.arguments.items, hidden..) |arg, i| {
        arg_type_names[i] = arg.type.getDialectTypeName() orelse return error.UnsupportedType;
    }
    abi.computeArgLocations(arg_type_names, arg_locations);

    for (arg_locations[hidden..], 0..) |location, i| {
        gpr_sources[i] = requirementFromValueLocation(location);
        xmm_sources[i] = xmmRequirementFromValueLocation(location);
    }
}

fn entryFunction(block: *ir.Block) ?*ir.Operation {
    const region = block.getParentRegion() orelse return null;
    if (region.getEntryBlock() != block) return null;
    const parent = region.getParentOperation() orelse return null;
    if (!std.mem.eql(u8, parent.name.name, FuncDialect.FuncOp.operation_name)) return null;
    return parent;
}

fn appendBlockArgumentCandidates(
    books: Books,
    allocator: std.mem.Allocator,
    block: *ir.Block,
    start: u32,
    order: *u32,
) !void {
    const gpr_sources = try allocator.alloc(GprCore.Requirement, block.arguments.items.len);
    defer allocator.free(gpr_sources);
    const xmm_sources = try allocator.alloc(XmmCore.Requirement, block.arguments.items.len);
    defer allocator.free(xmm_sources);
    try entryArgumentSources(block, allocator, gpr_sources, xmm_sources);

    for (block.arguments.items, 0..) |arg, i| {
        try GprCore.appendCandidate(books.gpr_candidates, allocator, arg, start, order, false, .any, gpr_sources[i]);
        try GprCore.appendFixedPosition(books.gpr_fixed, allocator, start, .source, gpr_sources[i]);
        try XmmCore.appendCandidate(books.xmm_candidates, allocator, arg, start, order, false, .any, xmm_sources[i]);
        try XmmCore.appendFixedPosition(books.xmm_fixed, allocator, start, .source, xmm_sources[i]);
    }
}

/// The register the Linux x86-64 kernel reads the call number from, and answers through.
pub const syscall_number_gpr: GPR = .rax;

/// The registers the Linux x86-64 kernel reads its arguments from, in argument order.
///
/// Argument three is r10 and not rcx. `syscall` writes the return address into rcx before the
/// kernel runs, so a number placed there would be destroyed by the instruction that reads it.
/// The C ABI's third argument register IS rcx (`registers.GPR.arg3`), which is why the
/// `arg0..arg5` alias set cannot stand in for this table.
pub const syscall_argument_gprs = [_]GPR{ .rdi, .rsi, .rdx, .r10, .r8, .r9 };

/// The registers `syscall` destroys without being told to: it stores rip in rcx and rflags in
/// r11. rax is not listed because the op defines it, and a definition already excludes every
/// other live range from it.
pub const syscall_clobbered_gprs = [_]GPR{ .rcx, .r11 };

/// The register operand `index` must reach, or null when no such operand exists.
fn syscallOperandGpr(index: usize) ?GPR {
    if (index == 0) return syscall_number_gpr;
    if (index - 1 >= syscall_argument_gprs.len) return null;
    return syscall_argument_gprs[index - 1];
}

/// Pins every operand of one `func.syscall` to the register the kernel reads it from and
/// records the two registers the instruction destroys.
///
/// The operands are recorded as plain uses rather than ordered scratch uses because the
/// emitter settles them with one parallel move, the way it settles a call's arguments, so no
/// operand can be overwritten by an earlier one.
fn recordSyscallUses(
    books: Books,
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    position: u32,
) !void {
    const point = PositionPoint.source(position);
    for (op.operands.items, 0..) |operand, index| {
        const reg = syscallOperandGpr(index) orelse return error.UnsupportedOperation;
        const requirement = GprCore.Requirement{ .fixed = reg };
        try GprCore.recordUse(books.gpr_candidates, allocator, operand.value, point, requirement, 0);
        try GprCore.appendFixedPosition(books.gpr_fixed, allocator, position, .use, requirement);
    }
    try GprCore.appendScratchClobbers(books.gpr_fixed, allocator, position, &syscall_clobbered_gprs);
}

fn recordCallClobbers(
    fixed_positions: *std.ArrayListUnmanaged(GprCore.FixedPosition),
    allocator: std.mem.Allocator,
    position: u32,
) !void {
    try fixed_positions.append(allocator, .{ .point = shared.fixedPositionPoint(position, .clobber), .reg = abi.int_return_reg, .kind = .clobber });
    for (call_plan.call_clobbered_gprs) |reg| {
        try fixed_positions.append(allocator, .{ .point = shared.fixedPositionPoint(position, .clobber), .reg = reg, .kind = .clobber });
    }
}

fn hasI32ImmediateRhs(op: *ir.Operation) !bool {
    const rhs = op.getOperand(1) orelse return error.MissingOperand;
    return scalar.constantIntI32(rhs) != null;
}

fn recordScalarScratchClobbers(
    fixed_positions: *std.ArrayListUnmanaged(GprCore.FixedPosition),
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    position: u32,
) !void {
    const name = op.name.name;
    if (std.mem.eql(u8, name, ArithDialect.ConstantOp.operation_name)) {
        try GprCore.appendScratchClobbers(fixed_positions, allocator, position, &.{.rax});
    } else if (std.mem.eql(u8, name, ArithDialect.AddOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.MulOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.MaxOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.MinOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.AndOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.OrOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.XorOp.operation_name))
    {
        try GprCore.appendScratchClobbers(fixed_positions, allocator, position, &.{.rax});
    } else if (std.mem.eql(u8, name, ArithDialect.NegOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.NotOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.ShlOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.ShrOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.UshrOp.operation_name))
    {
        try GprCore.appendScratchClobbers(fixed_positions, allocator, position, &.{.rax});
    } else if (std.mem.eql(u8, name, ArithDialect.AbsOp.operation_name)) {
        try GprCore.appendScratchClobbers(fixed_positions, allocator, position, &.{ .rax, .rcx });
    } else if (std.mem.eql(u8, name, ArithDialect.SubOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.CmpOp.operation_name))
    {
        try GprCore.appendScratchClobbers(fixed_positions, allocator, position, &.{.rax});
    } else if (std.mem.eql(u8, name, ArithDialect.DivOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.RemOp.operation_name))
    {
        try GprCore.appendScratchClobbers(fixed_positions, allocator, position, &.{ .rax, .rdx });
    } else if (std.mem.eql(u8, name, ArithDialect.SelectOp.operation_name)) {
        try GprCore.appendScratchClobbers(fixed_positions, allocator, position, &.{.rdx});
    } else if (std.mem.eql(u8, name, ArithDialect.CastOp.operation_name)) {
        try GprCore.appendScratchClobbers(fixed_positions, allocator, position, &.{ .rax, .rcx });
    } else if (std.mem.eql(u8, name, ArithDialect.BitcastOp.operation_name)) {
        try GprCore.appendScratchClobbers(fixed_positions, allocator, position, &.{.rax});
    } else if (std.mem.eql(u8, name, MemrefDialect.LoadOp.operation_name)) {
        try GprCore.appendScratchClobbers(fixed_positions, allocator, position, &.{ .rax, .rcx });
    } else if (std.mem.eql(u8, name, MemrefDialect.StoreOp.operation_name)) {
        try GprCore.appendScratchClobbers(fixed_positions, allocator, position, &.{ .rax, .rcx, .rdx });
    } else if (std.mem.eql(u8, name, MemrefDialect.AllocaOp.operation_name)) {
        try GprCore.appendScratchClobbers(fixed_positions, allocator, position, &.{.rax});
    } else if (isOverflowOp(op)) {
        try GprCore.appendScratchClobbers(fixed_positions, allocator, position, &.{ .rax, .rcx });
    }
}

fn recordOrderedScalarSources(
    candidates: *GprCore.Candidates,
    fixed_positions: *std.ArrayListUnmanaged(GprCore.FixedPosition),
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    position: u32,
    sources: []const GPR,
) !void {
    var source_blockers: GprMask = 0;
    const point = PositionPoint.source(position);
    for (sources, 0..) |source, index| {
        const operand = op.getOperand(index) orelse return error.MissingOperand;
        try GprCore.recordFixedSourceUse(candidates, fixed_positions, allocator, operand, point, source, .scratch_use, source_blockers);
        source_blockers |= GprCore.regBit(source);
    }
}

fn recordScalarSourceOrder(
    candidates: *GprCore.Candidates,
    fixed_positions: *std.ArrayListUnmanaged(GprCore.FixedPosition),
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    position: u32,
) !bool {
    const name = op.name.name;
    if (std.mem.eql(u8, name, ArithDialect.AddOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.MulOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.MaxOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.MinOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.AndOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.OrOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.XorOp.operation_name))
    {
        try recordOrderedScalarSources(candidates, fixed_positions, allocator, op, position, &.{ .rax, .rcx });
        return true;
    }
    if (std.mem.eql(u8, name, ArithDialect.NegOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.AbsOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.NotOp.operation_name))
    {
        try recordOrderedScalarSources(candidates, fixed_positions, allocator, op, position, &.{.rax});
        return true;
    }
    if (std.mem.eql(u8, name, ArithDialect.ShlOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.ShrOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.UshrOp.operation_name))
    {
        try recordOrderedScalarSources(candidates, fixed_positions, allocator, op, position, &.{ .rax, .rcx });
        return true;
    }
    if (std.mem.eql(u8, name, ArithDialect.SubOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.CmpOp.operation_name))
    {
        if (try hasI32ImmediateRhs(op)) {
            try recordOrderedScalarSources(candidates, fixed_positions, allocator, op, position, &.{.rax});
        } else {
            try recordOrderedScalarSources(candidates, fixed_positions, allocator, op, position, &.{ .rax, .rcx });
        }
        return true;
    }
    if (std.mem.eql(u8, name, ArithDialect.DivOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.RemOp.operation_name))
    {
        try recordOrderedScalarSources(candidates, fixed_positions, allocator, op, position, &.{ .rax, .rcx });
        return true;
    }
    if (std.mem.eql(u8, name, ArithDialect.SelectOp.operation_name)) {
        try recordOrderedScalarSources(candidates, fixed_positions, allocator, op, position, &.{ .rax, .rcx, .rdx });
        return true;
    }
    if (isOverflowOp(op)) {
        try recordOrderedScalarSources(candidates, fixed_positions, allocator, op, position, &.{ .rax, .rcx });
        return true;
    }
    return false;
}

fn recordXmmOrderedSources(
    candidates: *XmmCore.Candidates,
    fixed_positions: *std.ArrayListUnmanaged(XmmCore.FixedPosition),
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    position: u32,
    sources: []const XMM,
) !void {
    var source_blockers: XmmMask = 0;
    const point = PositionPoint.source(position);
    for (sources, 0..) |source, index| {
        const operand = op.getOperand(index) orelse return error.MissingOperand;
        try XmmCore.recordFixedSourceUse(candidates, fixed_positions, allocator, operand, point, source, .scratch_use, source_blockers);
        source_blockers |= XmmCore.regBit(source);
    }
}

fn isFloatArithOp(op: *ir.Operation) bool {
    if (op.operands.items.len == 0) return false;
    if (!isFloatEligibleOp(op.name.name)) return false;
    return allOperandsFloatScalar(op);
}

fn recordFloatOperation(
    books: Books,
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    position: u32,
) !void {
    const name = op.name.name;
    if (std.mem.eql(u8, name, ArithDialect.NegOp.operation_name)) {
        try recordXmmOrderedSources(books.xmm_candidates, books.xmm_fixed, allocator, op, position, &.{.xmm0});
        try XmmCore.appendScratchClobbers(books.xmm_fixed, allocator, position, &.{ .xmm0, .xmm1 });
        return;
    }
    if (std.mem.eql(u8, name, ArithDialect.MaxOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.MinOp.operation_name))
    {
        try recordXmmOrderedSources(books.xmm_candidates, books.xmm_fixed, allocator, op, position, &.{ .xmm0, .xmm1 });
        try XmmCore.appendScratchClobbers(books.xmm_fixed, allocator, position, &.{ .xmm0, .xmm1, .xmm2 });
        return;
    }
    try recordXmmOrderedSources(books.xmm_candidates, books.xmm_fixed, allocator, op, position, &.{ .xmm0, .xmm1 });
    try XmmCore.appendScratchClobbers(books.xmm_fixed, allocator, position, &.{ .xmm0, .xmm1 });
}

fn recordPackedOperation(
    books: Books,
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    position: u32,
) !void {
    const name = op.name.name;
    if (std.mem.eql(u8, name, ArithDialect.SplatOp.operation_name)) {
        const operand = op.getOperand(0) orelse return error.MissingOperand;
        if (isFloatScalar(operand)) {
            try recordXmmOrderedSources(books.xmm_candidates, books.xmm_fixed, allocator, op, position, &.{.xmm0});
        } else {
            try recordOrderedScalarSources(books.gpr_candidates, books.gpr_fixed, allocator, op, position, &.{.rax});
            try GprCore.appendScratchClobbers(books.gpr_fixed, allocator, position, &.{.rax});
        }
        try XmmCore.appendScratchClobbers(books.xmm_fixed, allocator, position, &.{.xmm0});
        return;
    }
    if (std.mem.eql(u8, name, ArithDialect.VecConstantOp.operation_name)) {
        try GprCore.appendScratchClobbers(books.gpr_fixed, allocator, position, &.{.rax});
        try XmmCore.appendScratchClobbers(books.xmm_fixed, allocator, position, &.{.xmm0});
        return;
    }

    try recordXmmOrderedSources(books.xmm_candidates, books.xmm_fixed, allocator, op, position, &.{ .xmm0, .xmm1 });
    if (std.mem.eql(u8, name, ArithDialect.MulOp.operation_name)) {
        const result = op.getResult(0) orelse return error.MissingResult;
        if (!isPackedFloat128(result)) {
            try XmmCore.appendScratchClobbers(books.xmm_fixed, allocator, position, &.{ .xmm0, .xmm1, .xmm2, .xmm3, .xmm4 });
            return;
        }
    }
    try XmmCore.appendScratchClobbers(books.xmm_fixed, allocator, position, &.{ .xmm0, .xmm1 });
}

fn memrefElementValue(op: *ir.Operation) ?*ir.Value {
    const name = op.name.name;
    if (std.mem.eql(u8, name, MemrefDialect.LoadOp.operation_name)) return op.getResult(0);
    if (std.mem.eql(u8, name, MemrefDialect.StoreOp.operation_name)) return op.getOperand(0);
    return null;
}

fn recordMemrefXmmClobbers(
    books: Books,
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    position: u32,
) !void {
    const element = memrefElementValue(op) orelse return;
    if (!isFloatScalar(element) and !isPacked128(element)) return;
    try XmmCore.appendScratchClobbers(books.xmm_fixed, allocator, position, &.{.xmm0});
}

fn recordXmmCallClobbers(
    fixed_positions: *std.ArrayListUnmanaged(XmmCore.FixedPosition),
    allocator: std.mem.Allocator,
    position: u32,
) !void {
    for (registers.allocatable_xmms) |reg| {
        try fixed_positions.append(allocator, .{ .point = shared.fixedPositionPoint(position, .clobber), .reg = reg, .kind = .clobber });
    }
}

fn recordOperationUses(
    books: Books,
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    position: u32,
) !void {
    if (std.mem.eql(u8, op.name.name, FuncDialect.CallOp.operation_name)) {
        const hidden: usize = @intFromBool(abi.returnsThroughRecord(op.results.items.len));
        const arg_count = op.operands.items.len + hidden;
        const arg_type_names = try allocator.alloc([]const u8, arg_count);
        defer allocator.free(arg_type_names);
        const arg_locations = try allocator.alloc(abi.ValueLocation, arg_count);
        defer allocator.free(arg_locations);

        if (hidden != 0) arg_type_names[0] = index_type_name;
        for (op.operands.items, hidden..) |operand, i| {
            arg_type_names[i] = operand.value.type.getDialectTypeName() orelse return error.UnsupportedType;
        }
        abi.computeArgLocations(arg_type_names, arg_locations);

        for (op.operands.items, hidden..) |operand, i| {
            const requirement = requirementFromValueLocation(arg_locations[i]);
            try GprCore.recordUse(books.gpr_candidates, allocator, operand.value, PositionPoint.source(position), requirement, 0);
            try GprCore.appendFixedPosition(books.gpr_fixed, allocator, position, .use, requirement);
            const xmm_requirement = xmmRequirementFromValueLocation(arg_locations[i]);
            try XmmCore.recordUse(books.xmm_candidates, allocator, operand.value, PositionPoint.source(position), xmm_requirement, 0);
            try XmmCore.appendFixedPosition(books.xmm_fixed, allocator, position, .use, xmm_requirement);
        }
        try recordCallClobbers(books.gpr_fixed, allocator, position);
        try recordXmmCallClobbers(books.xmm_fixed, allocator, position);
        return;
    }

    if (std.mem.eql(u8, op.name.name, FuncDialect.SyscallOp.operation_name)) {
        return recordSyscallUses(books, allocator, op, position);
    }

    if (std.mem.eql(u8, op.name.name, FuncDialect.ReturnOp.operation_name) and
        op.operands.items.len == 1 and isFloatScalar(op.operands.items[0].value))
    {
        try XmmCore.recordFixedSourceUse(books.xmm_candidates, books.xmm_fixed, allocator, op.operands.items[0].value, PositionPoint.source(position), .xmm0, .use, 0);
        return;
    }

    if (isFloatArithOp(op)) {
        return recordFloatOperation(books, allocator, op, position);
    }

    if (isPackedEligibleOp(op)) {
        return recordPackedOperation(books, allocator, op, position);
    }

    if (try recordScalarSourceOrder(books.gpr_candidates, books.gpr_fixed, allocator, op, position)) {
        try recordScalarScratchClobbers(books.gpr_fixed, allocator, op, position);
        return;
    }

    for (op.operands.items) |operand| {
        try GprCore.recordUse(books.gpr_candidates, allocator, operand.value, PositionPoint.source(position), .any, 0);
        try XmmCore.recordUse(books.xmm_candidates, allocator, operand.value, PositionPoint.source(position), .any, 0);
    }
    try recordScalarScratchClobbers(books.gpr_fixed, allocator, op, position);
    try recordMemrefXmmClobbers(books, allocator, op, position);
}

fn recordOperationPosition(
    operation_positions: ?*std.AutoHashMapUnmanaged(*ir.Operation, u32),
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    position: u32,
) !void {
    if (operation_positions) |positions| {
        try positions.put(allocator, op, position);
    }
}

fn definitionRequirement(op: *ir.Operation, result_index: usize) GprCore.Requirement {
    if (result_index != 0) {
        if (result_index == 1 and isOverflowOp(op)) return .{ .fixed = .rcx };
        return .any;
    }
    if (op.getResult(result_index)) |result| {
        if (!isRegisterScalar(result) and !isMemref(result)) return .any;
    }
    const name = op.name.name;
    if (std.mem.eql(u8, name, FuncDialect.CallOp.operation_name)) {
        const result = op.getResult(result_index) orelse return .any;
        const type_name = result.type.getDialectTypeName() orelse return .any;
        return switch (abi.computeReturnLocation(type_name)) {
            .int_reg => |reg| .{ .fixed = reg },
            .fp_reg, .stack => .any,
        };
    }
    if (std.mem.eql(u8, name, FuncDialect.SyscallOp.operation_name)) {
        return .{ .fixed = syscall_number_gpr };
    }
    if (std.mem.eql(u8, name, ArithDialect.ConstantOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.AddOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.SubOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.MulOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.NegOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.AbsOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.DivOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.MaxOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.MinOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.AndOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.OrOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.XorOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.NotOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.ShlOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.ShrOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.UshrOp.operation_name) or
        std.mem.eql(u8, name, ArithDialect.CmpOp.operation_name))
    {
        return .{ .fixed = .rax };
    }
    if (std.mem.eql(u8, name, ArithDialect.SelectOp.operation_name)) {
        return .{ .fixed = .rdx };
    }
    if (std.mem.eql(u8, name, ArithDialect.RemOp.operation_name)) {
        return .{ .fixed = .rdx };
    }
    if (std.mem.eql(u8, name, ArithDialect.CastOp.operation_name)) {
        return .{ .fixed = .rax };
    }
    if (std.mem.eql(u8, name, ArithDialect.BitcastOp.operation_name)) {
        return .{ .fixed = .rax };
    }
    if (isOverflowOp(op)) return .{ .fixed = .rax };
    return .any;
}

fn xmmDefinitionRequirement(op: *ir.Operation, result_index: usize) XmmCore.Requirement {
    if (result_index != 0) return .any;
    const result = op.getResult(result_index) orelse return .any;
    if (isFloatScalar(result)) {
        if (isFloatEligibleOp(op.name.name)) return .{ .fixed = .xmm0 };
        return .any;
    }
    if (isPacked128(result)) {
        if (std.mem.eql(u8, op.name.name, MemrefDialect.LoadOp.operation_name)) return .any;
        if (isPackedEligibleOp(op)) return .{ .fixed = .xmm0 };
    }
    return .any;
}

fn collectBlockCandidates(
    books: Books,
    operation_positions: ?*std.AutoHashMapUnmanaged(*ir.Operation, u32),
    allocator: std.mem.Allocator,
    block: *ir.Block,
    position: *u32,
    order: *u32,
) !void {
    try appendBlockArgumentCandidates(books, allocator, block, 0, order);

    var op_iter = block.operations.head;
    while (op_iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));

        if (std.mem.eql(u8, op.name.name, ScfDialect.IfOp.operation_name)) {
            try recordOperationPosition(operation_positions, allocator, op, position.*);
            try recordOperationUses(books, allocator, op, position.*);
            position.* += 1;

            const if_op = ScfDialect.IfOp{ .op = op };
            try collectBlockCandidates(books, operation_positions, allocator, if_op.getThenBlock(), position, order);
            if (if_op.getElseBlock()) |else_block| {
                try collectBlockCandidates(books, operation_positions, allocator, else_block, position, order);
            }

            for (op.results.items, 0..) |*result, result_index| {
                const requirement = definitionRequirement(op, result_index);
                try GprCore.appendCandidate(books.gpr_candidates, allocator, result, position.*, order, false, requirement, requirement);
                try GprCore.appendFixedPosition(books.gpr_fixed, allocator, position.*, .def, requirement);
                const xmm_requirement = xmmDefinitionRequirement(op, result_index);
                try XmmCore.appendCandidate(books.xmm_candidates, allocator, result, position.*, order, false, xmm_requirement, xmm_requirement);
                try XmmCore.appendFixedPosition(books.xmm_fixed, allocator, position.*, .def, xmm_requirement);
            }
            position.* += 1;
        } else {
            const is_constant = std.mem.eql(u8, op.name.name, ArithDialect.ConstantOp.operation_name);
            try recordOperationPosition(operation_positions, allocator, op, position.*);
            try recordOperationUses(books, allocator, op, position.*);
            for (op.results.items, 0..) |*result, result_index| {
                const requirement = definitionRequirement(op, result_index);
                try GprCore.appendCandidate(books.gpr_candidates, allocator, result, position.*, order, is_constant, requirement, requirement);
                try GprCore.appendFixedPosition(books.gpr_fixed, allocator, position.*, .def, requirement);
                const xmm_requirement = xmmDefinitionRequirement(op, result_index);
                try XmmCore.appendCandidate(books.xmm_candidates, allocator, result, position.*, order, is_constant, xmm_requirement, xmm_requirement);
                try XmmCore.appendFixedPosition(books.xmm_fixed, allocator, position.*, .def, xmm_requirement);
            }
            position.* += 1;
        }

        op_iter = op.next_op;
    }
}

fn earlierPoint(current: ?PositionPoint, candidate: PositionPoint) PositionPoint {
    return if (current) |point| point: {
        break :point if (candidate.lessThan(point)) candidate else point;
    } else candidate;
}

pub fn allocate(emitter: anytype, region: *ir.Region) !void {
    if (!isEligibleFunction(region)) return;
    const block = region.blocks.head orelse return;

    var gpr_candidates: GprCore.Candidates = .empty;
    defer gpr_candidates.deinit(emitter.allocator);

    var gpr_fixed: std.ArrayListUnmanaged(GprCore.FixedPosition) = .empty;
    defer gpr_fixed.deinit(emitter.allocator);

    var xmm_candidates: XmmCore.Candidates = .empty;
    defer xmm_candidates.deinit(emitter.allocator);

    var xmm_fixed: std.ArrayListUnmanaged(XmmCore.FixedPosition) = .empty;
    defer xmm_fixed.deinit(emitter.allocator);

    var loop_intervals: std.ArrayListUnmanaged(shared.LoopInterval) = .empty;
    defer loop_intervals.deinit(emitter.allocator);

    const books = Books{
        .gpr_candidates = &gpr_candidates,
        .gpr_fixed = &gpr_fixed,
        .xmm_candidates = &xmm_candidates,
        .xmm_fixed = &xmm_fixed,
    };

    var order: u32 = 0;
    const has_non_if_regions = blockHasNonIfRegions(block);
    if (has_non_if_regions) {
        var position: u32 = 1;
        try collectRegionBlockCandidates(books, &loop_intervals, &emitter.operation_positions, emitter.allocator, block, 0, &position, &order);
    } else {
        var position: u32 = 1;
        try collectBlockCandidates(books, &emitter.operation_positions, emitter.allocator, block, &position, &order);
    }
    shared.extendAcrossLoops(GPR, GprMask, gpr_candidates.slice(), loop_intervals.items);
    shared.extendAcrossLoops(XMM, XmmMask, xmm_candidates.slice(), loop_intervals.items);
    try GprCore.allocateIntervalHomes(emitter, &gpr_candidates, gpr_fixed.items, &interval_homes, loop_intervals.items);
    try XmmCore.allocateIntervalHomes(emitter, &xmm_candidates, xmm_fixed.items, &xmm_interval_homes, loop_intervals.items);
}

fn blockHasNonIfRegions(block: *ir.Block) bool {
    var op_iter = block.operations.head;
    while (op_iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (op.regions.items.len != 0) {
            if (!std.mem.eql(u8, op.name.name, ScfDialect.IfOp.operation_name)) return true;
            const if_op = ScfDialect.IfOp{ .op = op };
            if (blockHasNonIfRegions(if_op.getThenBlock())) return true;
            if (if_op.getElseBlock()) |else_block| {
                if (blockHasNonIfRegions(else_block)) return true;
            }
        }
        op_iter = op.next_op;
    }
    return false;
}

fn collectRegionBlockCandidates(
    books: Books,
    loop_intervals: *std.ArrayListUnmanaged(shared.LoopInterval),
    operation_positions: ?*std.AutoHashMapUnmanaged(*ir.Operation, u32),
    allocator: std.mem.Allocator,
    block: *ir.Block,
    block_start: u32,
    position: *u32,
    order: *u32,
) !void {
    try appendBlockArgumentCandidates(books, allocator, block, block_start, order);
    var op_iter = block.operations.head;
    while (op_iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        const is_constant = std.mem.eql(u8, op.name.name, "arith.constant");
        try recordOperationPosition(operation_positions, allocator, op, position.*);
        try recordOperationUses(books, allocator, op, position.*);
        if (op.regions.items.len == 0) {
            for (op.results.items, 0..) |*result, result_index| {
                const requirement = definitionRequirement(op, result_index);
                try GprCore.appendCandidate(books.gpr_candidates, allocator, result, position.*, order, is_constant, requirement, requirement);
                try GprCore.appendFixedPosition(books.gpr_fixed, allocator, position.*, .def, requirement);
                const xmm_requirement = xmmDefinitionRequirement(op, result_index);
                try XmmCore.appendCandidate(books.xmm_candidates, allocator, result, position.*, order, is_constant, xmm_requirement, xmm_requirement);
                try XmmCore.appendFixedPosition(books.xmm_fixed, allocator, position.*, .def, xmm_requirement);
            }
            position.* += 1;
        } else if (std.mem.eql(u8, op.name.name, ScfDialect.IfOp.operation_name)) {
            position.* += 1;
            for (op.regions.items) |*region| {
                const nested = region.blocks.head orelse continue;
                try collectRegionBlockCandidates(books, loop_intervals, operation_positions, allocator, nested, position.*, position, order);
            }
            for (op.results.items, 0..) |*result, result_index| {
                const requirement = definitionRequirement(op, result_index);
                try GprCore.appendCandidate(books.gpr_candidates, allocator, result, position.*, order, is_constant, requirement, requirement);
                try GprCore.appendFixedPosition(books.gpr_fixed, allocator, position.*, .def, requirement);
                const xmm_requirement = xmmDefinitionRequirement(op, result_index);
                try XmmCore.appendCandidate(books.xmm_candidates, allocator, result, position.*, order, is_constant, xmm_requirement, xmm_requirement);
                try XmmCore.appendFixedPosition(books.xmm_fixed, allocator, position.*, .def, xmm_requirement);
            }
            position.* += 1;
        } else {
            position.* += 1;
            const loop_entry = position.*;
            for (op.regions.items) |*region| {
                const nested = region.blocks.head orelse continue;
                try collectRegionBlockCandidates(books, loop_intervals, operation_positions, allocator, nested, position.*, position, order);
            }
            try loop_intervals.append(allocator, .{ .entry = loop_entry, .trailing = position.* });
            if (std.mem.eql(u8, op.name.name, ScfDialect.ForOp.operation_name)) {
                const trailing_point = PositionPoint.source(position.*);
                const body = (ScfDialect.ForOp{ .op = op }).getBodyBlock();
                for (body.arguments.items) |arg| {
                    try GprCore.recordUse(books.gpr_candidates, allocator, arg, trailing_point, .any, 0);
                    try XmmCore.recordUse(books.xmm_candidates, allocator, arg, trailing_point, .any, 0);
                }
                if (op.getOperand(1)) |upper| {
                    try GprCore.recordUse(books.gpr_candidates, allocator, upper, trailing_point, .any, 0);
                }
                if (op.getOperand(2)) |step| {
                    try GprCore.recordUse(books.gpr_candidates, allocator, step, trailing_point, .any, 0);
                }
            }
            for (op.results.items, 0..) |*result, result_index| {
                const requirement = definitionRequirement(op, result_index);
                try GprCore.appendCandidate(books.gpr_candidates, allocator, result, position.*, order, is_constant, requirement, requirement);
                try GprCore.appendFixedPosition(books.gpr_fixed, allocator, position.*, .def, requirement);
                const xmm_requirement = xmmDefinitionRequirement(op, result_index);
                try XmmCore.appendCandidate(books.xmm_candidates, allocator, result, position.*, order, is_constant, xmm_requirement, xmm_requirement);
                try XmmCore.appendFixedPosition(books.xmm_fixed, allocator, position.*, .def, xmm_requirement);
            }
            position.* += 1;
        }
        op_iter = op.next_op;
    }
}

const TestBooks = struct {
    xmm_candidates: XmmCore.Candidates = .empty,
    xmm_fixed: std.ArrayListUnmanaged(XmmCore.FixedPosition) = .empty,

    fn books(
        self: *TestBooks,
        candidates: *GprCore.Candidates,
        fixed: *std.ArrayListUnmanaged(GprCore.FixedPosition),
    ) Books {
        return .{
            .gpr_candidates = candidates,
            .gpr_fixed = fixed,
            .xmm_candidates = &self.xmm_candidates,
            .xmm_fixed = &self.xmm_fixed,
        };
    }

    fn deinit(self: *TestBooks, allocator: std.mem.Allocator) void {
        self.xmm_candidates.deinit(allocator);
        self.xmm_fixed.deinit(allocator);
    }
};

const TestEmitter = struct {
    allocator: std.mem.Allocator,
    value_locations: std.AutoHashMapUnmanaged(*ir.Value, GPR) = .empty,
    value_location_ranges: std.ArrayListUnmanaged(ValueLocationRange) = .empty,
    value_location_index: ValueLocationIndex = .{},
    xmm_locations: std.AutoHashMapUnmanaged(*ir.Value, XMM) = .empty,
    xmm_location_ranges: std.ArrayListUnmanaged(shared.ValueLocationRange(XMM)) = .empty,
    xmm_location_index: XmmValueLocationIndex = .{},
    operation_positions: std.AutoHashMapUnmanaged(*ir.Operation, u32) = .empty,
    reserved_callee_saved: usize = 0,
    used_callee_saved_regs: [registers.callee_saved_gprs.len]GPR = undefined,

    fn deinit(self: *TestEmitter) void {
        self.value_locations.deinit(self.allocator);
        self.value_location_ranges.deinit(self.allocator);
        self.value_location_index.deinit(self.allocator);
        self.xmm_locations.deinit(self.allocator);
        self.xmm_location_ranges.deinit(self.allocator);
        self.xmm_location_index.deinit(self.allocator);
        self.operation_positions.deinit(self.allocator);
    }
};

fn prepareTestValueLocationIndex(
    emitter: *TestEmitter,
    values: []const *ir.Value,
    position_count: usize,
    range_capacity: usize,
    register_capacity: usize,
) !void {
    try emitter.value_location_index.prepare(
        emitter.allocator,
        values.len,
        position_count,
        range_capacity,
        register_capacity,
    );
    for (values) |value| emitter.value_location_index.includeValue(value);
    try emitter.value_location_index.sealValues(emitter.allocator);
}

fn locationFor(emitter: *TestEmitter, value: *ir.Value) !GPR {
    return emitter.value_locations.get(value) orelse error.TestFailure;
}

fn hasCallerSavedHome(emitter: *TestEmitter) bool {
    var it = emitter.value_locations.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.isCallerSaved()) return true;
    }
    return false;
}

fn hasValueLocationRangeWithActions(
    emitter: *TestEmitter,
    value: *ir.Value,
    start: u32,
    end: u32,
    reg: GPR,
    entry: ValueLocationRangeEntry,
    end_phase: PositionPhase,
    exit: ValueLocationRangeExit,
) bool {
    for (emitter.value_location_ranges.items) |range| {
        if (range.value == value and
            range.start == start and
            range.end == end and
            range.reg == reg and
            range.entry == entry and
            range.end_phase == end_phase and
            range.exit == exit) return true;
    }
    return false;
}

fn hasValueLocationRange(emitter: *TestEmitter, value: *ir.Value, start: u32, end: u32, reg: GPR) bool {
    return hasValueLocationRangeWithActions(emitter, value, start, end, reg, .resident, .source, .retain);
}

fn expectFixedGpr(requirement: GprCore.Requirement, expected: GPR) !void {
    switch (requirement) {
        .fixed => |actual| try std.testing.expectEqual(expected, actual),
        .any => return error.TestFailure,
    }
}

fn expectAnyRequirement(requirement: GprCore.Requirement) !void {
    switch (requirement) {
        .any => {},
        .fixed => return error.TestFailure,
    }
}

fn hasFixedPosition(positions: []const GprCore.FixedPosition, position: u32, kind: FixedPositionKind, reg: GPR) bool {
    for (positions) |fixed| {
        if (fixed.point.position == position and fixed.kind == kind and fixed.reg == reg) return true;
    }
    return false;
}

fn expectUseBlockers(candidate: GprCore.Candidate, use_index: usize, blocked: []const GPR, clear: []const GPR) !void {
    const use = candidate.use_positions.items[use_index];
    for (blocked) |reg| {
        try std.testing.expect(GprCore.maskHasReg(use.source_blockers, reg));
    }
    for (clear) |reg| {
        try std.testing.expect(!GprCore.maskHasReg(use.source_blockers, reg));
    }
}
