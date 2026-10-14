const std = @import("std");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const machine = @import("../root.zig").machine_code;
const cast = @import("cast.zig");
const scalar = @import("scalar.zig");
const memory = @import("memory.zig");
const encoding = @import("encoding.zig");
const registers = @import("registers/root.zig");
const abi = @import("abi.zig");
const call_plan = @import("calls.zig");
const debug_info = @import("../root.zig").debug_info;
const labels = @import("labels.zig");
const slot_layout = @import("slots.zig");
const vector = @import("vector.zig");
const regalloc = @import("regalloc.zig");
const moves = @import("moves.zig");
const effects = @import("../../passes/effects.zig");
const sys = @import("sys");
const target_bounds = @import("../execution/bounds.zig");
const Bound = target_bounds.Bound;
const Excess = target_bounds.Excess;
const profile = sys.capabilities.current;
const executes = (profile.os == .linux or profile.os == .macos) and
    profile.arch == .x86_64 and profile.pointerWidthBits() == 64;
/// The publication these witnesses' test product declares: Linux's, or the non-hardened Mac's.
const test_publication_policy: sys.memory.ExecutablePolicy = if (profile.os == .macos)
    .macos_non_hardened
else
    .linux;

const arith = dialects.arith;
const memref = dialects.memref;
const scf = dialects.scf;
const func_dialect = dialects.func;
const builtin = dialects.builtin;

const ArithDialect = arith.ArithDialect;
const MemrefDialect = memref.MemrefDialect;
const ScfDialect = scf.ScfDialect;
const FuncDialect = func_dialect.FuncDialect;
const BuiltinDialect = builtin.BuiltinDialect;

const GPR = registers.GPR;
const XMM = registers.XMM;
const Mem = encoding.Mem;
const Condition = encoding.Condition;

/// The registers a `func.syscall` operand reaches, in operand order: the number first, then the
/// kernel's arguments. The allocator owns the convention and this is its operand-order reading.
const syscall_operand_regs = [_]GPR{regalloc.syscall_number_gpr} ++ regalloc.syscall_argument_gprs;

/// Arguments one `func.syscall` passes beside its number: the argument registers the kernel's
/// convention reads.
pub const max_syscall_arguments: u64 = regalloc.syscall_argument_gprs.len;

/// Largest number of values one `scf.while` carries through this emitter: its
/// operands, its before and after block arguments, its results and the
/// arguments its condition hands back are all this many or fewer. A while that
/// carries more is refused with `error.TooManyWhileValues` before its blocks
/// are walked.
///
/// A BOUND AND NOT A CAPACITY. This is not memory a caller buys and no limit
/// raises it, because the buffer it sizes lives on the host stack for the
/// length of one while. The side a program falls on is a property of the
/// program alone. A consumer that refuses a wider program in its own words
/// reads this figure here rather than copying it, so the two cannot drift.
pub const max_while_carried_values: usize = 16;

pub const CallRelocation = call_plan.CallRelocation;
const Slot = slot_layout.Slot;
const VectorSlot = slot_layout.VectorSlot;
const SretInfo = slot_layout.SretInfo;
const AllocationKind = slot_layout.AllocationKind;
const ArgSource = call_plan.ArgSource;
const ExternArg = call_plan.ExternArg;
const ExternResult = call_plan.ExternResult;
const TypeInfo = slot_layout.TypeInfo;
const IntExtension = slot_layout.IntExtension;
const Label = labels.Label;

/// What a type contributes to its slot, before the slot has a place.
///
/// Width and form travel together from `slotShapeFromName` to the one site
/// that reserves a slot, so that a reader cannot take the width and leave the
/// form behind, which once made a reload interpret an unsigned byte as signed.
const SlotShape = struct {
    width: u8,
    ext: IntExtension,
};

const MoveScratchSlots = struct {
    cycle: Slot,
    save: Slot,
};

const StackMoveScratch = struct {
    slots: MoveScratchSlots,
    memory_reg: GPR,
};

const MoveScratch = union(enum) {
    reg: GPR,
    stack: StackMoveScratch,
};

const BlockResult = enum {
    fell_through,
    yielded,
    returned,
    conditioned,
};

const IfYield = struct {
    op: *ir.Operation,
    merge_label: *Label,
};

const ForYield = struct {
    body_block: *ir.Block,
    iv: *ir.Value,
    step: *ir.Value,
    entry_position: u32,
    header_label: *Label,
};

const WhileCondition = struct {
    value: *?*ir.Value,
    args: []*ir.Value,
    arg_count: *usize,
    position: *u32,
};

const WhileYield = struct {
    before_block: *ir.Block,
    header_label: *Label,
};

const BlockTerminator = union(enum) {
    function_return,
    if_yield: IfYield,
    for_yield: ForYield,
    while_condition: WhileCondition,
    while_yield: WhileYield,
};

const EmitError = error{
    OutOfMemory,
    CapacityOverflow,
    FrameTooLarge,
    NoFunctionBody,
    NoEntryBlock,
    UnsupportedType,
    MissingSlot,
    MissingOperand,
    MissingResult,
    MissingPredicate,
    MissingIndex,
    IndexOutOfBounds,
    VectorArityMismatch,
    MissingCallee,
    MissingInductionVariable,
    MissingCondition,
    MissingYield,
    MissingOrdering,
    /// An ordered access was reached in a function whose values are not all in frame slots.
    /// `memory.requireFrameSlotsOnly` raises it and `regalloc.holdsOrderedEffect` is what keeps
    /// it unreachable, by refusing to allocate such a function at all.
    OrderedAccessWithAllocatedValues,
    InvalidWhileArity,
    UnexpectedOperationAfterCondition,
    UnexpectedYield,
    TooManyArguments,
    TooManyResults,
    TooManyWhileValues,
    ResultCountMismatch,
    InvalidConstant,
    InvalidDataSymbol,
    ConflictingDataSymbol,
    InvalidAllocation,
    MemrefTypeMissingParams,
    InvalidMemrefType,
    DynamicMemref,
    MemrefTooLarge,
    UnsupportedMemrefAddressSpace,
    UnsupportedDeallocTarget,
    UnsupportedOperation,
    InvalidParallelMove,
    NoScratchRegister,
    /// A function's emission ended with a forward jump whose label was never bound. Such a
    /// jump keeps displacement zero and falls into the next instruction.
    UnboundLabel,
};

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    code: std.ArrayListUnmanaged(u8),
    call_relocations: std.ArrayListUnmanaged(CallRelocation),
    data_symbols: machine.DataSymbolSet,
    data_relocations: std.ArrayListUnmanaged(machine.DataRelocation),
    omitted_ops: std.AutoHashMapUnmanaged(*ir.Operation, void),
    flag_conditions: std.AutoHashMapUnmanaged(*ir.Value, Condition),
    slot_map: std.AutoHashMapUnmanaged(*ir.Value, Slot),
    vector_slot_map: std.AutoHashMapUnmanaged(*ir.Value, VectorSlot),
    alloca_payload_slots: std.AutoHashMapUnmanaged(*ir.Value, Slot),
    slot_count: usize,
    allocation_kinds: std.AutoHashMapUnmanaged(*ir.Value, AllocationKind),
    frame_layout: abi.FrameLayout,
    saw_return: bool,
    sret_info: ?SretInfo,
    sret_slot: ?Slot,
    result_count: usize,
    line_table: debug_info.LineTableBuilder,
    value_locations: std.AutoHashMapUnmanaged(*ir.Value, GPR),
    value_location_ranges: std.ArrayListUnmanaged(regalloc.ValueLocationRange),
    value_location_index: regalloc.ValueLocationIndex,
    xmm_locations: std.AutoHashMapUnmanaged(*ir.Value, XMM),
    xmm_location_ranges: std.ArrayListUnmanaged(regalloc.XmmValueLocationRange),
    xmm_location_index: regalloc.XmmValueLocationIndex,
    operation_positions: std.AutoHashMapUnmanaged(*ir.Operation, u32),
    allocation_position: u32,
    move_scratch_slots: ?MoveScratchSlots,
    reserved_callee_saved: usize,
    used_callee_saved_regs: [registers.callee_saved_gprs.len]GPR,
    /// The innermost operation whose emission failed in the current function, or `null`.
    failed_operation: ?*ir.Operation,
    /// The bound the current function was refused past, with its figures, set exactly when
    /// emission fails with an error `failures.namesBound` accepts.
    excess: ?Excess,
    /// The operation that kept every value of the current function in its frame slot, as
    /// `regalloc.refusal` names it, or `null` when the allocator placed the function.
    framed_by: ?*ir.Operation,
    /// Forward jumps of the current function whose label is not bound yet.
    unbound_fixups: u32,
    /// The bytes of code reserved for the function being emitted. The reservation rests on
    /// a measured ratio rather than a bound, so code past it grows the buffer by copies.
    code_reservation: usize,
    /// Whether emission records a line table. A host that reads neither the debug map nor
    /// the debugger registration declines it, and the table costs it nothing.
    record_lines: bool,
    /// Whether the allocator places values in registers. Off, every value of every function
    /// lives in its frame slot, so a test can hold a function's placed code against the code
    /// that places nothing. It stays as the host set it from one function to the next.
    place_values: bool,
    /// The functions sharing this emitter's code image, which a call reaches by `call rel32`.
    /// Without it every call loads its callee's absolute address. The host that lays the image
    /// out sets it, and it stays from one function to the next.
    image_functions: ?*const machine.ImageFunctions,

    /// What one function's region tree holds, counted before anything is emitted, so that
    /// each table growing with the function is sized once rather than grown by copies.
    const Census = struct {
        /// Every operation, omitted or not. Emission begins each at most once, and the line
        /// table records at most one entry per beginning.
        operations: u32,
        /// Block arguments and results of scalar form. Each takes at most one slot.
        scalars: u32,
        /// Block arguments and results of vector form. Each takes at most one run of slots.
        vectors: u32,
    };

    pub fn init(allocator: std.mem.Allocator) Emitter {
        return .{
            .allocator = allocator,
            .code = .empty,
            .call_relocations = .empty,
            .data_symbols = .{},
            .data_relocations = .empty,
            .omitted_ops = .{},
            .flag_conditions = .{},
            .slot_map = .{},
            .vector_slot_map = .{},
            .alloca_payload_slots = .{},
            .slot_count = 0,
            .allocation_kinds = .empty,
            .frame_layout = abi.computeFrameLayout(0, &.{}, true) catch unreachable,
            .saw_return = false,
            .sret_info = null,
            .sret_slot = null,
            .result_count = 0,
            .line_table = debug_info.LineTableBuilder.init(allocator),
            .value_locations = .empty,
            .value_location_ranges = .empty,
            .value_location_index = .{},
            .xmm_locations = .empty,
            .xmm_location_ranges = .empty,
            .xmm_location_index = .{},
            .operation_positions = .empty,
            .allocation_position = 0,
            .move_scratch_slots = null,
            .reserved_callee_saved = 0,
            .used_callee_saved_regs = undefined,
            .failed_operation = null,
            .excess = null,
            .framed_by = null,
            .unbound_fixups = 0,
            .code_reservation = 0,
            .record_lines = true,
            .place_values = true,
            .image_functions = null,
        };
    }

    pub fn deinit(self: *Emitter) void {
        self.code.deinit(self.allocator);
        self.call_relocations.deinit(self.allocator);
        self.data_symbols.deinit(self.allocator);
        self.data_relocations.deinit(self.allocator);
        self.omitted_ops.deinit(self.allocator);
        self.flag_conditions.deinit(self.allocator);
        self.slot_map.deinit(self.allocator);
        self.vector_slot_map.deinit(self.allocator);
        self.alloca_payload_slots.deinit(self.allocator);
        self.allocation_kinds.deinit(self.allocator);
        self.line_table.deinit();
        self.value_locations.deinit(self.allocator);
        self.value_location_ranges.deinit(self.allocator);
        self.value_location_index.deinit(self.allocator);
        self.xmm_locations.deinit(self.allocator);
        self.xmm_location_ranges.deinit(self.allocator);
        self.xmm_location_index.deinit(self.allocator);
        self.operation_positions.deinit(self.allocator);
    }

    /// Whether `callee` lands in the same code image as the function being emitted.
    pub fn sharesImage(self: *const Emitter, callee: []const u8) bool {
        const functions = self.image_functions orelse return false;
        return functions.contains(callee);
    }

    pub fn getCode(self: *const Emitter) []const u8 {
        return self.code.items;
    }

    pub fn emitFunction(self: *Emitter, func: *ir.Operation) EmitError!void {
        self.resetForFunction();

        const region = func.getRegion(0) orelse return error.NoFunctionBody;
        const entry = region.getEntryBlock() orelse return error.NoEntryBlock;
        try self.admitCount(.results, abi.max_result_count, func.results.items.len, error.TooManyResults);
        // Both the register allocator and the argument spills lay the parameters out.
        try self.admitCount(.parameters, abi.max_call_arguments, entry.arguments.items.len, error.TooManyArguments);
        self.result_count = func.results.items.len;

        try self.markOmittedOps(region);
        try self.markFlagConditions(region);
        self.framed_by = if (self.place_values) try regalloc.allocate(self, region) else null;
        const census = try self.takeCensus(region);
        try self.slot_map.ensureTotalCapacity(self.allocator, census.scalars);
        try self.vector_slot_map.ensureTotalCapacity(self.allocator, census.vectors);
        const slot_capacity = self.slot_map.capacity();
        const vector_capacity = self.vector_slot_map.capacity();
        try self.collectSlotsInRegion(region);
        std.debug.assert(self.slot_map.count() <= census.scalars);
        std.debug.assert(self.vector_slot_map.count() <= census.vectors);
        std.debug.assert(self.slot_map.capacity() == slot_capacity);
        std.debug.assert(self.vector_slot_map.capacity() == vector_capacity);
        if (self.record_lines) try self.line_table.reserve(census.operations);
        try self.reserveResultAddress(func);

        if (self.value_locations.count() != 0 or self.value_location_ranges.items.len != 0 or
            self.xmm_location_ranges.items.len != 0)
        {
            try self.reserveMoveScratchSlots();
        }

        const saved = self.used_callee_saved_regs[0..self.reserved_callee_saved];
        self.frame_layout = abi.computeFrameLayout(self.slot_count, saved, true) catch |err| {
            const padding = abi.framePaddingSlots(self.slot_count, saved.len) * abi.stack_slot_size;
            self.excess = abi.frameExcess(self.frameHeldBytes(), padding).?;
            return err;
        };

        self.code_reservation = frame_code_bytes + @as(usize, census.operations) * code_bytes_per_operation;
        try self.code.ensureTotalCapacityPrecise(self.allocator, self.code_reservation);
        try self.frame_layout.emitPrologue(self.allocator, &self.code);
        try self.emitArgumentSpills(entry);

        _ = try self.emitBlockOps(entry, .function_return);
        if (self.unbound_fixups != 0) return error.UnboundLabel;

        if (!self.saw_return) {
            try self.emitEpilogue();
        }
        std.debug.assert(self.line_table.entries.items.len <= census.operations);
    }

    /// Bytes of code reserved per operation before a function is emitted. Measured over the
    /// 895 functions church-test and the RePPL Choir package compile: the most any emitted
    /// per operation was 29.5 bytes. This is a measured ratio, not a bound. A function past
    /// it says so in `Emitted.outgrew_reservation`, and the runtime counts it.
    const code_bytes_per_operation = 32;
    /// Bytes reserved for a prologue and one epilogue: at most 21 bytes each, for the frame
    /// pointer, five callee-saved registers and the stack adjustment.
    const frame_code_bytes = 64;

    fn takeCensus(self: *Emitter, region: *ir.Region) EmitError!Census {
        var census: Census = .{ .operations = 0, .scalars = 0, .vectors = 0 };
        try self.countRegion(region, &census);
        return census;
    }

    fn countRegion(self: *Emitter, region: *ir.Region, census: *Census) EmitError!void {
        var block_iter = region.blocks.head;
        while (block_iter) |block| {
            for (block.arguments.items) |arg| try self.countValue(arg, census);
            var op_iter = block.operations.head;
            while (op_iter) |op_ptr| {
                const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
                census.operations += 1;
                for (op.results.items) |*result| try self.countValue(result, census);
                for (op.regions.items) |*nested| try self.countRegion(nested, census);
                op_iter = op.next_op;
            }
            block_iter = block.next;
        }
    }

    fn countValue(self: *Emitter, value: *ir.Value, census: *Census) EmitError!void {
        if (try self.vectorTypeInfoFromType(value.type) != null) {
            census.vectors += 1;
        } else {
            census.scalars += 1;
        }
    }

    /// Reserves the slot holding a hidden result address for vector and record returns.
    /// Several results carry scalars only; a vector result returns alone.
    fn reserveResultAddress(self: *Emitter, func: *ir.Operation) EmitError!void {
        const results = func.results.items;
        std.debug.assert(results.len <= abi.max_result_count);
        std.debug.assert(self.sret_info == null);
        if (results.len == 1) {
            if (try self.vectorTypeInfoFromType(results[0].type)) |vec_info| {
                self.sret_info = .{ .vector = vec_info };
                self.sret_slot = try self.reserveSlot(64, .unsigned);
            }
            return;
        }
        for (results) |result| {
            if (try self.vectorTypeInfoFromType(result.type) != null) return error.UnsupportedType;
        }
        if (!abi.returnsThroughRecord(results.len)) return;
        self.sret_info = .{ .record = results.len };
        self.sret_slot = try self.reserveSlot(64, .unsigned);
    }

    pub fn discardFunctionState(self: *Emitter) void {
        self.resetForFunction();
    }

    fn resetForFunction(self: *Emitter) void {
        self.code.clearRetainingCapacity();
        self.call_relocations.clearRetainingCapacity();
        self.data_symbols.clearRetainingCapacity();
        self.data_relocations.clearRetainingCapacity();
        self.slot_map.clearRetainingCapacity();
        self.vector_slot_map.clearRetainingCapacity();
        self.alloca_payload_slots.clearRetainingCapacity();
        self.slot_count = 0;
        self.allocation_kinds.clearRetainingCapacity();
        self.saw_return = false;
        self.sret_info = null;
        self.sret_slot = null;
        self.result_count = 0;
        self.line_table.reset();
        self.value_locations.clearRetainingCapacity();
        self.value_location_ranges.clearRetainingCapacity();
        self.value_location_index.clearRetainingCapacity();
        self.xmm_locations.clearRetainingCapacity();
        self.xmm_location_ranges.clearRetainingCapacity();
        self.xmm_location_index.clearRetainingCapacity();
        self.operation_positions.clearRetainingCapacity();
        self.omitted_ops.clearRetainingCapacity();
        self.flag_conditions.clearRetainingCapacity();
        self.allocation_position = 0;
        self.move_scratch_slots = null;
        self.reserved_callee_saved = 0;
        self.failed_operation = null;
        self.excess = null;
        self.framed_by = null;
        self.unbound_fixups = 0;
    }

    fn recordLocation(self: *Emitter, op: *ir.Operation) EmitError!void {
        if (!self.record_lines) return;
        const offset: u32 = @intCast(self.code.items.len);
        try self.line_table.record(offset, op.getLoc(), op.name.name);
    }

    fn enterOperationPosition(self: *Emitter, op: *ir.Operation) EmitError!void {
        if (self.operation_positions.get(op)) |position| {
            self.allocation_position = position;
        }
        try self.emitRangeEndSpills();
        try self.emitRangeStartReloads();
        try self.emitXmmRangeEndSpills();
        try self.emitXmmRangeStartReloads();
    }

    fn beginOperation(self: *Emitter, op: *ir.Operation) EmitError!void {
        try self.enterOperationPosition(op);
        try self.recordLocation(op);
    }

    fn plannedValueLocationAtPoint(self: *const Emitter, value: *ir.Value, point: regalloc.PositionPoint) ?GPR {
        return self.value_location_index.valueLocationAtPoint(self.value_location_ranges.items, value, point);
    }

    fn plannedValueLocationAt(self: *const Emitter, value: *ir.Value, position: u32) ?GPR {
        return self.plannedValueLocationAtPoint(value, .{ .position = position, .phase = .source });
    }

    /// Returns the position where allocation defines the results of an operation with regions.
    /// Results follow every nested position, so they sit just before the next operation.
    fn mergePosition(self: *const Emitter, op: *ir.Operation) ?u32 {
        std.debug.assert(op.regions.items.len != 0);
        const next = op.next_op orelse return null;
        const next_position = self.operation_positions.get(next) orelse return null;
        const op_position = self.operation_positions.get(op) orelse return null;
        std.debug.assert(next_position > op_position + 1);
        return next_position - 1;
    }

    /// A linear allocation order visits both arms, but execution visits only one. Materialize
    /// every incoming register value before the branch so a spill or reload in either arm has
    /// a valid slot, then restore the register homes expected by the common successor.
    fn saveIfIncomingValues(self: *Emitter, op: *ir.Operation) EmitError!void {
        const branch_position = self.operation_positions.get(op) orelse return;
        const point = regalloc.PositionPoint.source(branch_position);
        const value_found = self.value_location_index.rangesAtPoint(self.value_location_ranges.items, point);
        for (value_found) |range_index| {
            const range = self.value_location_ranges.items[range_index];
            if (!self.valueDefinedBefore(range.value, branch_position)) continue;
            const slot = self.slotForOptional(range.value) orelse continue;
            try self.storeSlot(slot, range.reg);
        }
        const xmm_found = self.xmm_location_index.rangesAtPoint(self.xmm_location_ranges.items, point);
        for (xmm_found) |range_index| {
            const range = self.xmm_location_ranges.items[range_index];
            if (!self.valueDefinedBefore(range.value, branch_position)) continue;
            if (self.vector_slot_map.get(range.value)) |slot| {
                try vector.emitPackedStore(self, slot, range.reg);
            } else {
                try self.storeSlotXmm(try self.slotFor(range.value), range.reg);
            }
        }
    }

    /// Entry reloads wait for enterOperationPosition to spill the old register occupant.
    fn restoreIfValuesAt(self: *Emitter, op: *ir.Operation, position: u32) EmitError!void {
        const branch_position = self.operation_positions.get(op) orelse return;
        const point = regalloc.PositionPoint.source(position);
        const value_found = self.value_location_index.rangesAtPoint(self.value_location_ranges.items, point);
        for (value_found) |range_index| {
            const range = self.value_location_ranges.items[range_index];
            if (range.entry == .reload and range.start == position) continue;
            if (!self.valueDefinedBefore(range.value, branch_position)) continue;
            const slot = self.slotForOptional(range.value) orelse continue;
            try self.loadSlot(slot, range.reg);
        }
        const xmm_found = self.xmm_location_index.rangesAtPoint(self.xmm_location_ranges.items, point);
        for (xmm_found) |range_index| {
            const range = self.xmm_location_ranges.items[range_index];
            if (range.entry == .reload and range.start == position) continue;
            if (!self.valueDefinedBefore(range.value, branch_position)) continue;
            if (self.vector_slot_map.get(range.value)) |slot| {
                try vector.emitPackedLoad(self, slot, range.reg);
            } else {
                try self.loadSlotXmm(try self.slotFor(range.value), range.reg);
            }
        }
    }

    fn restoreIfArmValues(self: *Emitter, op: *ir.Operation, block: *ir.Block) EmitError!void {
        const first: *ir.Operation = @ptrCast(@alignCast(block.operations.head orelse return));
        const position = self.operation_positions.get(first) orelse return;
        try self.restoreIfValuesAt(op, position);
    }

    fn restoreIfOutgoingValues(self: *Emitter, op: *ir.Operation) EmitError!void {
        const merge_position = self.mergePosition(op) orelse return;
        try self.restoreIfValuesAt(op, merge_position + 1);
    }

    fn valueDefinedBefore(self: *const Emitter, value: *ir.Value, position: u32) bool {
        const defining = value.getDefiningOp() orelse return true;
        const operation: *ir.Operation = @ptrCast(@alignCast(defining));
        const definition_position = self.operation_positions.get(operation) orelse return false;
        return definition_position < position;
    }

    /// Moves allocation to the merge position of a region operation and spills ranges ending
    /// there. A result whose first range reloads later then resolves to its slot, not a register.
    fn enterMergePosition(self: *Emitter, op: *ir.Operation) EmitError!void {
        if (op.results.items.len == 0) return;
        const merge_position = self.mergePosition(op) orelse return;
        self.allocation_position = merge_position;
        try self.emitRangeEndSpills();
        try self.emitXmmRangeEndSpills();
    }

    fn plannedValueStart(self: *const Emitter, value: *ir.Value) ?u32 {
        if (valueIsFloatScalar(value)) {
            return self.xmm_location_index.valueLocationStart(self.xmm_location_ranges.items, value);
        }
        return self.value_location_index.valueLocationStart(self.value_location_ranges.items, value);
    }

    fn plannedValueLocation(self: *const Emitter, value: *ir.Value) ?GPR {
        return self.plannedValueLocationAt(value, self.allocation_position);
    }

    fn plannedValueLocationForPhase(self: *const Emitter, value: *ir.Value, phase: regalloc.PositionPhase) ?GPR {
        return self.plannedValueLocationAtPoint(value, .{ .position = self.allocation_position, .phase = phase });
    }

    fn hasPlannedValueLocation(self: *const Emitter, value: *ir.Value) bool {
        return self.value_location_index.valueHasLocationRange(value);
    }

    fn canUsePlannedValueLocation(value: *ir.Value) bool {
        return switch (value.kind) {
            .op_result => true,
            .block_argument => true,
        };
    }

    fn registerHomeAtPoint(self: *const Emitter, value: *ir.Value, point: regalloc.PositionPoint) ?GPR {
        if (canUsePlannedValueLocation(value)) {
            if (self.plannedValueLocationAtPoint(value, point)) |home| return home;
            if (self.hasPlannedValueLocation(value)) return null;
        }
        return self.value_locations.get(value);
    }

    fn registerHomeAt(self: *const Emitter, value: *ir.Value, position: u32) ?GPR {
        return self.registerHomeAtPoint(value, .{ .position = position, .phase = .source });
    }

    pub fn registerHome(self: *const Emitter, value: *ir.Value) ?GPR {
        return self.registerHomeAt(value, self.allocation_position);
    }

    pub fn registerHomeForPhase(self: *const Emitter, value: *ir.Value, phase: regalloc.PositionPhase) ?GPR {
        return self.registerHomeAtPoint(value, .{ .position = self.allocation_position, .phase = phase });
    }

    fn valueIsFloatScalar(value: *const ir.Value) bool {
        const name = value.type.getDialectTypeName() orelse return false;
        return std.mem.eql(u8, name, "arith.f32") or std.mem.eql(u8, name, "arith.f64");
    }

    fn plannedXmmLocationAtPoint(self: *const Emitter, value: *ir.Value, point: regalloc.PositionPoint) ?XMM {
        return self.xmm_location_index.valueLocationAtPoint(self.xmm_location_ranges.items, value, point);
    }

    fn hasPlannedXmmLocation(self: *const Emitter, value: *ir.Value) bool {
        return self.xmm_location_index.valueHasLocationRange(value);
    }

    fn xmmHomeAtPoint(self: *const Emitter, value: *ir.Value, point: regalloc.PositionPoint) ?XMM {
        if (canUsePlannedValueLocation(value)) {
            if (self.plannedXmmLocationAtPoint(value, point)) |home| return home;
            if (self.hasPlannedXmmLocation(value)) return null;
        }
        return self.xmm_locations.get(value);
    }

    pub fn xmmHome(self: *const Emitter, value: *ir.Value) ?XMM {
        return self.xmmHomeAtPoint(value, .{ .position = self.allocation_position, .phase = .source });
    }

    pub fn xmmHomeForPhase(self: *const Emitter, value: *ir.Value, phase: regalloc.PositionPhase) ?XMM {
        return self.xmmHomeAtPoint(value, .{ .position = self.allocation_position, .phase = phase });
    }

    fn emitRangeEndSpills(self: *Emitter) EmitError!void {
        var iterator = self.value_location_index.rangesEndingAt(self.allocation_position);
        while (iterator.next()) |range_index| {
            const range = self.value_location_ranges.items[range_index];
            if (range.exit != .spill) continue;
            if (!canUsePlannedValueLocation(range.value)) continue;
            const slot = self.slotForOptional(range.value) orelse continue;
            try self.storeSlot(slot, range.reg);
        }
    }

    fn emitRangeStartReloads(self: *Emitter) EmitError!void {
        var iterator = self.value_location_index.rangesStartingAt(self.allocation_position);
        while (iterator.next()) |range_index| {
            const range = self.value_location_ranges.items[range_index];
            if (range.entry != .reload) continue;
            if (!canUsePlannedValueLocation(range.value)) continue;
            const slot = self.slotForOptional(range.value) orelse continue;
            try self.loadSlot(slot, range.reg);
        }
    }

    fn emitXmmRangeEndSpills(self: *Emitter) EmitError!void {
        var iterator = self.xmm_location_index.rangesEndingAt(self.allocation_position);
        while (iterator.next()) |range_index| {
            const range = self.xmm_location_ranges.items[range_index];
            if (range.exit != .spill) continue;
            if (!canUsePlannedValueLocation(range.value)) continue;
            if (self.vector_slot_map.get(range.value)) |vslot| {
                try vector.emitPackedStore(self, vslot, range.reg);
            } else {
                try self.storeSlotXmm(try self.slotFor(range.value), range.reg);
            }
        }
    }

    fn emitXmmRangeStartReloads(self: *Emitter) EmitError!void {
        var iterator = self.xmm_location_index.rangesStartingAt(self.allocation_position);
        while (iterator.next()) |range_index| {
            const range = self.xmm_location_ranges.items[range_index];
            if (range.entry != .reload) continue;
            if (!canUsePlannedValueLocation(range.value)) continue;
            if (self.vector_slot_map.get(range.value)) |vslot| {
                try vector.emitPackedLoad(self, vslot, range.reg);
            } else {
                try self.loadSlotXmm(try self.slotFor(range.value), range.reg);
            }
        }
    }

    pub fn emitEncoding(self: *Emitter, enc: encoding.Encoding) EmitError!void {
        try self.code.appendSlice(self.allocator, enc.slice());
    }

    fn emitEpilogue(self: *Emitter) EmitError!void {
        try self.frame_layout.emitEpilogue(self.allocator, &self.code);
    }

    /// Marks every operation this function will leave out, before anything is allocated.
    ///
    /// ONE DROP MAKES MORE. An addition nothing reads is droppable, and dropping it is what
    /// makes the two constants feeding it unread in turn. A single sweep would leave those
    /// constants behind, because their use count still names the addition. So this repeats
    /// until a sweep marks nothing new.
    ///
    /// It terminates because a sweep only ever adds to the set and the set is bounded by the
    /// operations in the region, so the loop runs at most that many times plus the sweep that
    /// finds nothing. The assertion states it rather than trusting it.
    fn markOmittedOps(self: *Emitter, region: *ir.Region) EmitError!void {
        const ceiling = countOperations(region) + 1;
        var sweeps: usize = 0;
        while (true) {
            sweeps += 1;
            std.debug.assert(sweeps <= ceiling);
            if (!try self.sweepOmittedOps(region)) break;
        }
        std.debug.assert(self.omitted_ops.count() <= ceiling);
    }

    fn countOperations(region: *ir.Region) usize {
        var total: usize = 0;
        var block_iter = region.blocks.head;
        while (block_iter) |block| {
            var op_iter = block.operations.head;
            while (op_iter) |op_ptr| {
                const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
                total += 1;
                for (op.regions.items) |*nested| total += countOperations(nested);
                op_iter = op.next_op;
            }
            block_iter = block.next;
        }
        return total;
    }

    fn sweepOmittedOps(self: *Emitter, region: *ir.Region) EmitError!bool {
        var marked = false;
        var block_iter = region.blocks.head;
        while (block_iter) |block| {
            var op_iter = block.operations.head;
            while (op_iter) |op_ptr| {
                const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
                for (op.regions.items) |*nested| {
                    if (try self.sweepOmittedOps(nested)) marked = true;
                }
                if (!self.omitted_ops.contains(op) and self.omitsOperation(op)) {
                    try self.omitted_ops.put(self.allocator, op, {});
                    marked = true;
                }
                op_iter = op.next_op;
            }
            block_iter = block.next;
        }
        return marked;
    }

    /// Whether the backend may leave this operation out of the function entirely.
    ///
    /// Three things must hold. The operation defines at least one result and nothing that
    /// survives reads any of them, so leaving it out removes no value another instruction
    /// needs. Its declared effects permit discarding it. And it is a leaf.
    ///
    /// PURITY IS NOT DECIDED HERE. `effects.permitsDiscard` reads the EffectOpInterface that
    /// arith, func, memref, rc, scf and tile each already implement, and answers from what the
    /// operation declared: discardable means total and read only, so an operation that writes,
    /// traps, diverges, allocates, borrows, or hands back anything it owns is refused. Asking a
    /// second mechanism the same question is how the two come to disagree.
    ///
    /// THE LEAF TEST IS A COST BOUND, NOT A SAFETY ONE. `EffectSummary` walks a region or a
    /// callee to decide, and sizes itself from the whole module's operation count when it must.
    /// This is asked of every operation in every sweep, so a region operation or a call is
    /// refused here rather than answered expensively. Refusing costs a slot and keeps a value.
    /// A leaf is answered from its own declaration without allocating, so the context's
    /// capacity never decides which values get a slot and never moves the frame.
    ///
    /// An operation that declares no effects is refused too, because `permitsDiscard` answers
    /// false without the interface. Undeclared and unregistered both mean keep.
    fn omitsOperation(self: *const Emitter, op: *ir.Operation) bool {
        if (op.results.items.len == 0) return false;
        for (op.results.items) |*result| {
            if (self.valueIsRead(result)) return false;
        }
        if (!effects.isLeaf(op)) return false;
        return effects.permitsDiscard(op);
    }

    /// Records the exact boolean left in flags and the condition for its false edge.
    /// Only syntactically adjacent branches qualify. Overflow additionally admits one
    /// single-use boolean not. Wrapped result 0 keeps its ordinary home.
    ///
    /// Between the writer and branch, storeFrom and enterOperationPosition emit only
    /// mov/movsx/movzx and scalar or packed SSE moves. The elided not still enters its
    /// allocation position. Parallel edge moves run after the jump. Calls, arithmetic
    /// zeroing and rsp adjustments require an intervening operation and cannot qualify.
    /// Flags-only values have no slot, so range transitions cannot spill or reload their
    /// unmaterialized register contents. Their allocator reservations stay conservative.
    fn markFlagConditions(self: *Emitter, region: *ir.Region) EmitError!void {
        var block_iter = region.blocks.head;
        while (block_iter) |block| {
            var op_iter = block.operations.head;
            while (op_iter) |op_ptr| {
                const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
                op_iter = op.next_op;
                for (op.regions.items) |*nested| try self.markFlagConditions(nested);
                if (self.omitted_ops.contains(op)) continue;
                if (std.mem.eql(u8, op.name.name, ArithDialect.CmpOp.operation_name)) {
                    const result = op.getResult(0) orelse continue;
                    const lhs = op.getOperand(0) orelse continue;
                    const kind = arith.scalarKindFromType(lhs.type) orelse continue;
                    if (arith.scalarKindIsFloat(kind)) continue;
                    if (!adjacentCondition(op, result)) continue;
                    const predicate = (ArithDialect.CmpOp{ .op = op }).getPredicate() orelse
                        return error.MissingPredicate;
                    try self.flag_conditions.put(self.allocator, result, invertCondition(scalar.conditionForIntPredicate(predicate)));
                } else if (overflowOperation(op)) {
                    const overflow = op.getResult(1) orelse continue;
                    if (!valueHasSingleUse(overflow)) continue;
                    if (adjacentCondition(op, overflow)) {
                        try self.flag_conditions.put(self.allocator, overflow, .no);
                        continue;
                    }
                    const negation = op.next_op orelse continue;
                    if (!std.mem.eql(u8, negation.name.name, ArithDialect.NotOp.operation_name)) continue;
                    if (negation.getNumOperands() != 1 or negation.getNumResults() != 1) continue;
                    if (negation.getOperand(0) != overflow) continue;
                    const inverted = negation.getResult(0).?;
                    if (arith.scalarKindFromType(inverted.type) != .bool) continue;
                    if (!adjacentCondition(negation, inverted)) continue;
                    try self.flag_conditions.put(self.allocator, overflow, .no);
                    try self.flag_conditions.put(self.allocator, inverted, .o);
                }
            }
            block_iter = block.next;
        }
    }

    fn overflowOperation(op: *ir.Operation) bool {
        inline for (.{ ArithDialect.AddoOp, ArithDialect.SuboOp, ArithDialect.MuloOp }) |Op| {
            if (std.mem.eql(u8, op.name.name, Op.operation_name)) return true;
        }
        return false;
    }

    fn adjacentCondition(op: *ir.Operation, value: *ir.Value) bool {
        if (!valueHasSingleUse(value)) return false;
        const next = op.next_op orelse return false;
        if (std.mem.eql(u8, next.name.name, ScfDialect.IfOp.operation_name)) {
            return (ScfDialect.IfOp{ .op = next }).getCondition() == value;
        }
        if (std.mem.eql(u8, next.name.name, ScfDialect.ConditionOp.operation_name)) {
            return (ScfDialect.ConditionOp{ .op = next }).getCondition() == value;
        }
        return false;
    }

    pub fn flagsOnly(self: *const Emitter, value: *ir.Value) bool {
        return self.flag_conditions.contains(value);
    }

    /// Whether any operation that survives names this value as an operand.
    ///
    /// A use held only by an operation already marked is not a read, because that operation
    /// will emit nothing. This is what carries one drop into the next.
    fn valueIsRead(self: *const Emitter, value: *ir.Value) bool {
        var use = value.first_use;
        while (use) |operand| {
            const user: *ir.Operation = @ptrCast(@alignCast(operand.owner));
            if (!self.omitted_ops.contains(user)) return true;
            use = operand.next_use;
        }
        return false;
    }

    fn collectSlotsInRegion(self: *Emitter, region: *ir.Region) EmitError!void {
        var block_iter = region.blocks.head;
        while (block_iter) |block| {
            for (block.arguments.items) |arg| {
                try self.addSlot(arg);
            }

            var op_iter = block.operations.head;
            while (op_iter) |op_ptr| {
                const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
                if (self.omitted_ops.contains(op)) {
                    op_iter = op.next_op;
                    continue;
                }
                try self.addResultSlots(op);
                if (std.mem.eql(u8, op.name.name, MemrefDialect.AllocaOp.operation_name)) {
                    try self.addAllocaPayloadSlot(MemrefDialect.AllocaOp{ .op = op });
                }
                for (op.regions.items) |*nested| {
                    try self.collectSlotsInRegion(nested);
                }
                op_iter = op.next_op;
            }

            block_iter = block.next;
        }
    }

    /// A record call reserves its result slots last to first, so each result sits one
    /// eightbyte above the previous one and the first slot addresses the whole record.
    ///
    /// A result nothing reads is given no slot, when the operation defining it can do without
    /// one. The frame is sized from the slots handed out, so such a value was charging the
    /// function eight bytes of stack plus a store writing a number nothing could ever load.
    ///
    /// Every other value keeps a slot, including one that lives its whole life in a register:
    /// the allocator may spill it at a range end, and the reload has to find it somewhere.
    ///
    /// A record result is exempt even when it is dead. Those slots are not independent. The
    /// callee writes the record through a hidden pointer into a run of adjacent eightbytes and
    /// the first slot addresses the whole run, so dropping a member would move the ones above
    /// it. `slotCoversRecord` asserts the run survived.
    fn addResultSlots(self: *Emitter, op: *ir.Operation) EmitError!void {
        const results = op.results.items;
        const is_call = std.mem.eql(u8, op.name.name, FuncDialect.CallOp.operation_name);
        if (!is_call or !abi.returnsThroughRecord(results.len)) {
            const droppable = resultSlotIsDroppable(op);
            for (results) |*result| {
                if (self.flagsOnly(result)) continue;
                if (droppable and result.hasNoUses()) continue;
                try self.addSlot(result);
                std.debug.assert(self.hasAnySlot(result));
            }
            return;
        }
        var index = results.len;
        while (index > 0) {
            index -= 1;
            try self.addSlot(&results[index]);
        }
        std.debug.assert(self.slotCoversRecord(results));
    }

    fn vectorTypeInfoFromType(self: *Emitter, typ: ir.Type) EmitError!?VectorSlot {
        const name = typ.getDialectTypeName() orelse return null;
        const info = arith.parseVectorTypeName(name) orelse return null;
        const elem = try self.slotShapeFromName(info.elem_type_name);
        const is_float = std.mem.eql(u8, info.elem_type_name, "arith.f32") or std.mem.eql(u8, info.elem_type_name, "arith.f64");
        return .{
            .base = .{ .offset = 0, .width = elem.width, .ext = elem.ext },
            .lanes = @intCast(info.width),
            .elem_type_name = info.elem_type_name,
            .is_float = is_float,
        };
    }

    fn resultIsVector(op: *ir.Operation) EmitError!bool {
        const result = op.getResult(0) orelse return error.MissingResult;
        const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
        return arith.parseVectorTypeName(type_name) != null;
    }

    /// Reserves the frame bytes one value lives in, at most once per value.
    ///
    /// The frame is sized from `slot_count`, so every call here costs the function stack. A
    /// caller that has decided a value needs no slot simply does not call this: there is no
    /// way to hand out a slot and then take it back, because the next reservation would sit
    /// where the withdrawn one did and every offset already published would be wrong.
    /// Whether this operation can define a result that has no frame slot at all.
    ///
    /// The answer turns on where the operation puts its result, not on whether the result is
    /// wanted. A call and a syscall return in a fixed register, so the slot is only a home for
    /// a value that already exists, and a result nothing reads needs no home. A region
    /// operation receives its result from a move emitted at the region's exit, and that move is
    /// skipped for a result nothing reads by the same argument.
    ///
    /// Everything else keeps its slot. Arithmetic emitters name the slot directly as an
    /// instruction's destination, so withdrawing it there would not delete a store, it would
    /// delete the computation, and choir carries no purity model that could say when deleting a
    /// computation is sound. An operation this function does not recognise keeps its slot,
    /// because a wrong yes costs a wrong address and a wrong no costs eight bytes.
    fn resultSlotIsDroppable(op: *ir.Operation) bool {
        const name = op.name.name;
        inline for (.{
            FuncDialect.CallOp,
            FuncDialect.SyscallOp,
            ScfDialect.IfOp,
            ScfDialect.ForOp,
            ScfDialect.WhileOp,
        }) |Op| {
            if (std.mem.eql(u8, name, Op.operation_name)) return true;
        }
        return false;
    }

    /// Whether a value holds frame bytes of either kind, a scalar slot or a vector run.
    fn hasAnySlot(self: *const Emitter, value: *ir.Value) bool {
        if (self.slot_map.contains(value)) return true;
        return self.vector_slot_map.contains(value);
    }

    fn addSlot(self: *Emitter, value: *ir.Value) EmitError!void {
        if (self.slot_map.contains(value) or self.vector_slot_map.contains(value)) return;

        if (try self.vectorTypeInfoFromType(value.type)) |vector_info| {
            const first = try self.claimSlots(vector_info.lanes);
            var info = vector_info;
            info.base.offset = self.slotDisplacement(first);
            try self.vector_slot_map.put(self.allocator, value, info);
            return;
        }

        const shape = try self.slotShape(value.type);
        try self.slot_map.put(self.allocator, value, try self.reserveSlot(shape.width, shape.ext));
    }

    /// The bytes the frame holds below the saved rbp so far: the callee-saved pushes and every
    /// slot given out. `claimSlots` keeps it within `abi.max_frame_bytes`, so it cannot wrap.
    fn frameHeldBytes(self: *const Emitter) u64 {
        return (self.slot_count + self.reserved_callee_saved) * abi.stack_slot_size;
    }

    /// Refuses a function, in every build mode, whose construct holds `count` on `bound`, a count
    /// the emitter takes whole, past `limit`, and records the figures for the failure report.
    fn admitCount(self: *Emitter, bound: Bound, limit: u64, count: u64, err: EmitError) EmitError!void {
        if (Excess.of(bound, limit, 0, count)) |excess| {
            self.excess = excess;
            return err;
        }
    }

    /// Refuses the frame, in every build mode, when `count` more slots would take it past
    /// `abi.max_frame_bytes`, and records the figures for the failure report.
    fn admitSlots(self: *Emitter, count: u64) EmitError!void {
        const requested = count *| abi.stack_slot_size;
        if (abi.frameExcess(self.frameHeldBytes(), requested)) |excess| {
            self.excess = excess;
            return error.FrameTooLarge;
        }
    }

    /// Gives out `count` slots past every slot already given out and returns the first.
    ///
    /// EVERY SLOT COMES FROM HERE, AND THE CHECK COMES FIRST. An offset is a product of the slot
    /// count, so a count admitted past the figure would wrap the product in a release build and
    /// address the wrong bytes. A count that fits keeps every product below 2^31.
    fn claimSlots(self: *Emitter, count: u64) EmitError!usize {
        try self.admitSlots(count);
        const first = self.slot_count;
        self.slot_count += @intCast(count);
        return first;
    }

    /// The rbp displacement of slot `index`, past the callee-saved pushes.
    fn slotDisplacement(self: *const Emitter, index: usize) i32 {
        const depth = (index + self.reserved_callee_saved + 1) * abi.stack_slot_size;
        std.debug.assert(depth <= abi.max_frame_bytes);
        return -@as(i32, @intCast(depth));
    }

    /// THE ONE PLACE A VALUE'S FORM IS FIXED. Everything downstream reads it
    /// off the slot rather than deciding it again.
    fn reserveSlot(self: *Emitter, width: u8, ext: IntExtension) EmitError!Slot {
        std.debug.assert(width >= 8);
        std.debug.assert(width <= abi.stack_slot_size * 8);
        std.debug.assert(std.math.isPowerOfTwo(width));
        const offset = self.slotDisplacement(try self.claimSlots(1));
        std.debug.assert(offset < 0);
        return .{ .offset = offset, .width = width, .ext = ext };
    }

    fn reserveMoveScratchSlots(self: *Emitter) EmitError!void {
        if (self.move_scratch_slots != null) return;
        self.move_scratch_slots = .{
            .cycle = try self.reserveSlot(64, .unsigned),
            .save = try self.reserveSlot(64, .unsigned),
        };
    }

    /// Reserves the frame cell a static `memref.alloca` names, past every slot already given out.
    ///
    /// THE SAVED REGISTERS ARE PART OF THE OFFSET. The callee-saved registers the allocator
    /// reserved sit between rbp and the first local, and `reserveSlot` counts them in every slot
    /// offset it hands out, so a payload measured from `slot_count` alone overlaps the last scalar
    /// slot, the saved registers, and the return address above them. Both the padding base and the
    /// payload's own offset therefore count `reserved_callee_saved` as well. Nothing could reach
    /// that overlap before a function holding an alloca could be register allocated, because only
    /// allocation reserves a callee-saved register.
    fn addAllocaPayloadSlot(self: *Emitter, alloca_op: MemrefDialect.AllocaOp) EmitError!void {
        const result = alloca_op.getResult();
        if (self.alloca_payload_slots.contains(result)) return;

        const bytes = try memory.allocaByteSize(self, alloca_op);
        const payload_slots = std.math.divCeil(u64, @max(bytes, 1), abi.stack_slot_size) catch unreachable;
        const alignment = try memory.allocaAlignment(self, alloca_op);
        // The payload alone is admitted before the padding is measured from it, so the padding's
        // own product of slots cannot wrap either.
        try self.admitSlots(payload_slots);
        const payload_base = self.slot_count + self.reserved_callee_saved;
        const padding_slots = allocaPaddingSlots(payload_base, @intCast(payload_slots), alignment);
        const first = try self.claimSlots(padding_slots + payload_slots);
        const deepest = first + padding_slots + @as(usize, @intCast(payload_slots)) - 1;
        const base_offset = self.slotDisplacement(deepest);
        try self.alloca_payload_slots.put(self.allocator, result, .{
            .offset = base_offset,
            .width = 64,
            .ext = .unsigned,
        });
    }

    /// Whether the slots just reserved for a record call form the contiguous run the ABI needs.
    ///
    /// `canonicalizeRecordResults` and the hidden pointer argument both read the first slot as
    /// the address of the whole record, so a gap here is a call writing over a neighbour.
    fn slotCoversRecord(self: *Emitter, results: []ir.Value) bool {
        const first = self.slotForOptional(&results[0]) orelse return false;
        for (results, 0..) |*result, i| {
            const slot = self.slotForOptional(result) orelse return false;
            if (slot.offset != first.offset + abi.recordFieldOffset(i)) return false;
        }
        return true;
    }

    fn allocaPaddingSlots(slot_count: usize, payload_slots: usize, alignment: u64) usize {
        if (alignment <= abi.stack_slot_size) return 0;
        const effective = @min(alignment, abi.stack_alignment);
        const payload_bytes = @as(u64, @intCast((slot_count + payload_slots) * abi.stack_slot_size));
        const remainder = payload_bytes % effective;
        if (remainder == 0) return 0;
        const padding_bytes = effective - remainder;
        return @intCast((padding_bytes + abi.stack_slot_size - 1) / abi.stack_slot_size);
    }

    /// What one type looks like in a slot: how wide, and which form a reload
    /// puts it back in.
    ///
    /// THIS IS ONE TABLE BECAUSE IT USED TO BE TWO ANSWERS AND ONE OF THEM WAS
    /// THROWN AWAY. `arith.i8` and `arith.u8` sat on adjacent lines here,
    /// were told apart, and both answered 8, so the signedness was in hand at
    /// the moment it was dropped and `Slot` had nowhere to put it. A `u8` of
    /// 200 then came back out of its slot as -56. Width and
    /// form leave this function together so that neither can be read without
    /// the other.
    ///
    /// The form of a float, a memref or a `bool` is `unsigned` and is never
    /// consulted, because only widths 8 and 16 branch on it.
    fn slotShapeFromName(self: *Emitter, name: []const u8) EmitError!SlotShape {
        _ = self;
        if (std.mem.eql(u8, name, "arith.i64") or
            std.mem.eql(u8, name, "arith.index") or
            std.mem.eql(u8, name, "arith.bool"))
        {
            return .{ .width = 64, .ext = .signed };
        }
        if (std.mem.eql(u8, name, "arith.u64")) return .{ .width = 64, .ext = .unsigned };
        if (std.mem.eql(u8, name, "arith.i8")) return .{ .width = 8, .ext = .signed };
        if (std.mem.eql(u8, name, "arith.i16")) return .{ .width = 16, .ext = .signed };
        if (std.mem.eql(u8, name, "arith.i32")) return .{ .width = 32, .ext = .signed };
        if (std.mem.eql(u8, name, "arith.u8")) return .{ .width = 8, .ext = .unsigned };
        if (std.mem.eql(u8, name, "arith.u16")) return .{ .width = 16, .ext = .unsigned };
        if (std.mem.eql(u8, name, "arith.u32")) return .{ .width = 32, .ext = .unsigned };
        if (std.mem.eql(u8, name, MemrefDialect.name)) return .{ .width = 64, .ext = .unsigned };
        if (std.mem.eql(u8, name, "arith.f64")) return .{ .width = 64, .ext = .unsigned };
        if (std.mem.eql(u8, name, "arith.f32")) return .{ .width = 32, .ext = .unsigned };
        if (std.mem.eql(u8, name, "arith.f16") or std.mem.eql(u8, name, "arith.bf16")) return error.UnsupportedType;
        return error.UnsupportedType;
    }

    /// The same answer for a value's own type.
    fn slotShape(self: *Emitter, typ: ir.Type) EmitError!SlotShape {
        const name = typ.getDialectTypeName() orelse return error.UnsupportedType;
        return self.slotShapeFromName(name);
    }

    fn valueWidthFromName(self: *Emitter, name: []const u8) EmitError!u8 {
        return (try self.slotShapeFromName(name)).width;
    }

    pub fn typeInfoFromName(self: *Emitter, name: []const u8) EmitError!TypeInfo {
        if (std.mem.eql(u8, name, "arith.f32")) return .{ .width = 32, .is_float = true };
        if (std.mem.eql(u8, name, "arith.f64")) return .{ .width = 64, .is_float = true };
        if (std.mem.eql(u8, name, "arith.f16") or std.mem.eql(u8, name, "arith.bf16")) return error.UnsupportedType;
        const width = try self.valueWidthFromName(name);
        return .{ .width = width, .is_float = false };
    }

    pub fn slotFor(self: *Emitter, value: *ir.Value) EmitError!Slot {
        return self.slot_map.get(value) orelse error.MissingSlot;
    }

    /// The slot a value was given, or null when it was given none because nothing reads it.
    ///
    /// Callers that settle a value they are defining use this. Callers that read an operand
    /// use `slotFor` and keep its refusal, because an operand is by definition a use and so
    /// always had a slot reserved for it.
    pub fn slotForOptional(self: *Emitter, value: *ir.Value) ?Slot {
        return self.slot_map.get(value);
    }

    pub fn vectorSlotFor(self: *Emitter, value: *ir.Value) EmitError!VectorSlot {
        return self.vector_slot_map.get(value) orelse error.MissingSlot;
    }

    fn emitArgumentSpills(self: *Emitter, entry: *ir.Block) EmitError!void {
        const arg_count = entry.arguments.items.len;
        const sret_count: usize = if (self.sret_info != null) 1 else 0;
        const total_count = arg_count + sret_count;
        if (total_count == 0) return;

        var arg_type_names = std.ArrayListUnmanaged([]const u8).empty;
        defer arg_type_names.deinit(self.allocator);

        if (sret_count != 0) {
            try arg_type_names.append(self.allocator, "arith.index");
        }
        for (entry.arguments.items) |arg| {
            const name = arg.type.getDialectTypeName() orelse return error.UnsupportedType;
            try arg_type_names.append(self.allocator, name);
        }

        const locations = try self.allocator.alloc(abi.ValueLocation, total_count);
        defer self.allocator.free(locations);
        abi.computeArgLocations(arg_type_names.items, locations);

        if (sret_count != 0) {
            const sret_slot = self.sret_slot orelse return error.MissingSlot;
            switch (locations[0]) {
                .int_reg => |reg| {
                    try self.storeSlot(sret_slot, reg);
                },
                .fp_reg => return error.UnsupportedType,
                .stack => |offset| {
                    const mem = Mem.baseDisp(.rbp, 16 + offset);
                    try self.emitEncoding(encoding.movRegMem(.rax, mem));
                    try self.storeSlot(sret_slot, .rax);
                },
            }
        }

        var parallel: std.ArrayListUnmanaged(moves.Move) = .empty;
        defer parallel.deinit(self.allocator);

        for (entry.arguments.items, 0..) |arg, i| {
            const slot = try self.slotFor(arg);
            switch (locations[i + sret_count]) {
                .int_reg => |reg| {
                    try parallel.append(self.allocator, .{
                        .src = .{ .reg = reg },
                        .dst = try self.placeFor(arg),
                    });
                },
                .fp_reg => |reg| {
                    try parallel.append(self.allocator, .{
                        .src = .{ .xmm = reg },
                        .dst = try self.placeFor(arg),
                    });
                },
                .stack => |offset| {
                    try parallel.append(self.allocator, .{
                        .src = .{ .slot = .{ .offset = 16 + offset, .width = slot.width, .ext = slot.ext } },
                        .dst = try self.placeFor(arg),
                    });
                },
            }
        }
        try self.emitParallelMoves(parallel.items);
    }

    /// Reads a value back in the form it was spelled with.
    ///
    /// This used to pass `.signed` whatever the value was, which is the whole
    /// failure: a `u8` was stored by a `movzbq` that read its byte
    /// as 200 and returned by a `movsbq` that read the same byte as -56. The
    /// slot now carries the answer, so nothing here decides it.
    pub fn loadSlot(self: *Emitter, slot: Slot, reg: GPR) EmitError!void {
        try self.loadSlotWithExt(slot, reg, slot.ext);
    }

    /// Reads a value zero extended REGARDLESS of how it was spelled.
    ///
    /// This is a statement about the operation and not about the value, and
    /// only an operation whose semantics demand the unsigned form may make
    /// it. A logical shift right is the clear case: it reads its input as a
    /// bit pattern, so an `i8` of -56 shifts as 200 and `loadSlot` would be
    /// wrong. A site that calls this merely because its operand happens to be
    /// unsigned is asking the slot a question the slot already answers, and
    /// should call `loadSlot`.
    pub fn loadSlotUnsigned(self: *Emitter, slot: Slot, reg: GPR) EmitError!void {
        try self.loadSlotWithExt(slot, reg, .unsigned);
    }

    /// Reads an 8 or 16 bit slot sign extended whatever its kind. A 32 or 64 bit slot is read
    /// as it is, since its comparison runs at its own width and needs no extension. As with
    /// `loadSlotUnsigned`, only an operation whose meaning demands the signed form may ask: a
    /// signed ordering reads its operands as signed integers, so a `u8` of 200 orders as -56.
    pub fn loadSlotSigned(self: *Emitter, slot: Slot, reg: GPR) EmitError!void {
        try self.loadSlotWithExt(slot, reg, .signed);
    }

    fn loadSlotWithExt(self: *Emitter, slot: Slot, reg: GPR, ext: IntExtension) EmitError!void {
        const mem = Mem.baseDisp(.rbp, slot.offset);
        switch (slot.width) {
            8 => {
                if (ext == .signed) {
                    try self.emitEncoding(encoding.movsxRegMem8(reg, mem));
                } else {
                    try self.emitEncoding(encoding.movzxRegMem8(reg, mem));
                }
            },
            16 => {
                if (ext == .signed) {
                    try self.emitEncoding(encoding.movsxRegMem16(reg, mem));
                } else {
                    try self.emitEncoding(encoding.movzxRegMem16(reg, mem));
                }
            },
            32 => {
                try self.emitEncoding(encoding.movRegMem32(reg, mem));
            },
            64 => {
                try self.emitEncoding(encoding.movRegMem(reg, mem));
            },
            else => return error.UnsupportedType,
        }
    }

    pub fn storeSlot(self: *Emitter, slot: Slot, reg: GPR) EmitError!void {
        try self.storeMemory(Mem.baseDisp(.rbp, slot.offset), slot.width, reg);
    }

    fn storeMemory(self: *Emitter, mem: Mem, width: u8, reg: GPR) EmitError!void {
        switch (width) {
            8 => try self.emitEncoding(encoding.movMemReg8(mem, reg)),
            16 => try self.emitEncoding(encoding.movMemReg16(mem, reg)),
            32 => try self.emitEncoding(encoding.movMemReg32(mem, reg)),
            64 => try self.emitEncoding(encoding.movMemReg(mem, reg)),
            else => return error.UnsupportedType,
        }
    }

    pub fn loadSlotXmm(self: *Emitter, slot: Slot, reg: XMM) EmitError!void {
        const mem = Mem.baseDisp(.rbp, slot.offset);
        if (slot.width == 32) {
            try self.emitEncoding(encoding.movss(reg, .{ .mem = mem }));
        } else if (slot.width == 64) {
            try self.emitEncoding(encoding.movsd(reg, .{ .mem = mem }));
        } else {
            return error.UnsupportedType;
        }
    }

    pub fn storeSlotXmm(self: *Emitter, slot: Slot, reg: XMM) EmitError!void {
        try self.storeMemoryXmm(Mem.baseDisp(.rbp, slot.offset), slot.width, reg);
    }

    fn storeMemoryXmm(self: *Emitter, mem: Mem, width: u8, reg: XMM) EmitError!void {
        switch (width) {
            32 => try self.emitEncoding(encoding.movssStore(mem, reg)),
            64 => try self.emitEncoding(encoding.movsdStore(mem, reg)),
            else => return error.UnsupportedType,
        }
    }

    pub fn loadInto(self: *Emitter, value: *ir.Value, reg: GPR) EmitError!void {
        if (self.registerHome(value)) |home| {
            try self.copyHome(value, home, reg);
        } else {
            try self.loadSlot(try self.slotFor(value), reg);
        }
    }

    /// Reads a value for a signed ordering. A register home is copied with no extension,
    /// because its slot is compared at 32 or 64 bits: the allocator gives no 8 or 16 bit
    /// integer a register home. The assertion fails if that rule changes.
    pub fn loadIntoSigned(self: *Emitter, value: *ir.Value, reg: GPR) EmitError!void {
        if (self.registerHome(value)) |home| {
            const width = (try self.slotFor(value)).width;
            std.debug.assert(width == 32 or width == 64);
            try self.copyHome(value, home, reg);
        } else {
            try self.loadSlotSigned(try self.slotFor(value), reg);
        }
    }

    pub fn loadIntoUnsigned(self: *Emitter, value: *ir.Value, reg: GPR) EmitError!void {
        if (self.registerHome(value)) |home| {
            try self.copyHome(value, home, reg);
        } else {
            try self.loadSlotUnsigned(try self.slotFor(value), reg);
        }
    }

    fn copyHome(self: *Emitter, value: *ir.Value, home: GPR, reg: GPR) EmitError!void {
        const slot = try self.slotFor(value);
        if (slot.width == 32) {
            try self.emitEncoding(encoding.movRegReg32(reg, home));
            return;
        }
        if (home != reg) try self.emitEncoding(encoding.movRegReg(reg, home));
    }

    pub fn storeFrom(self: *Emitter, value: *ir.Value, reg: GPR) EmitError!void {
        if (self.registerHomeForPhase(value, .definition)) |home| {
            if (home != reg) try self.emitEncoding(encoding.movRegReg(home, reg));
            return;
        }
        const slot = self.slotForOptional(value) orelse {
            std.debug.assert(value.hasNoUses());
            return;
        };
        try self.storeSlot(slot, reg);
    }

    pub fn loadIntoXmm(self: *Emitter, value: *ir.Value, reg: XMM) EmitError!void {
        if (self.xmmHome(value)) |home| {
            if (home != reg) try self.emitEncoding(encoding.movaps(reg, .{ .reg = home }));
        } else {
            try self.loadSlotXmm(try self.slotFor(value), reg);
        }
    }

    pub fn storeFromXmm(self: *Emitter, value: *ir.Value, reg: XMM) EmitError!void {
        if (self.xmmHomeForPhase(value, .definition)) |home| {
            if (home != reg) try self.emitEncoding(encoding.movaps(home, .{ .reg = reg }));
            return;
        }
        const slot = self.slotForOptional(value) orelse {
            std.debug.assert(value.hasNoUses());
            return;
        };
        try self.storeSlotXmm(slot, reg);
    }

    pub fn loadIntoXmmPacked(self: *Emitter, value: *ir.Value, reg: XMM) EmitError!void {
        if (self.xmmHome(value)) |home| {
            if (home != reg) try self.emitEncoding(encoding.movaps(reg, .{ .reg = home }));
        } else {
            try vector.emitPackedLoad(self, try self.vectorSlotFor(value), reg);
        }
    }

    pub fn storeFromXmmPacked(self: *Emitter, value: *ir.Value, reg: XMM) EmitError!void {
        if (self.xmmHomeForPhase(value, .definition)) |home| {
            if (home != reg) try self.emitEncoding(encoding.movaps(home, .{ .reg = reg }));
        } else {
            try vector.emitPackedStore(self, try self.vectorSlotFor(value), reg);
        }
    }

    fn placeFor(self: *Emitter, value: *ir.Value) EmitError!moves.Place {
        return self.placeForAt(value, self.allocation_position);
    }

    fn placeForAt(self: *Emitter, value: *ir.Value, position: u32) EmitError!moves.Place {
        return self.placeForAtPoint(value, regalloc.PositionPoint.source(position));
    }

    fn placeForAtPoint(self: *Emitter, value: *ir.Value, point: regalloc.PositionPoint) EmitError!moves.Place {
        if (valueIsFloatScalar(value)) {
            if (self.xmmHomeAtPoint(value, point)) |home| {
                return .{ .xmm = home };
            }
            return .{ .slot = try self.slotFor(value) };
        }
        if (self.registerHomeAtPoint(value, point)) |home| {
            return .{ .reg = home };
        }
        return .{ .slot = try self.slotFor(value) };
    }

    fn valueHasReloadRange(self: *const Emitter, value: *ir.Value) bool {
        if (valueIsFloatScalar(value)) {
            return self.xmm_location_index.valueHasEntry(self.xmm_location_ranges.items, value, .reload);
        }
        return self.value_location_index.valueHasEntry(self.value_location_ranges.items, value, .reload);
    }

    fn mirrorValueToSlotIfReloaded(self: *Emitter, value: *ir.Value, place: moves.Place) EmitError!void {
        if (!self.valueHasReloadRange(value)) return;
        switch (place) {
            .reg => |reg| try self.storeSlot(self.slotForOptional(value) orelse return, reg),
            .xmm => |reg| try self.storeSlotXmm(self.slotForOptional(value) orelse return, reg),
            .slot => {},
        }
    }

    fn emitPlaceMove(self: *Emitter, source: moves.Place, target: moves.Place) EmitError!void {
        if (moves.samePlace(source, target)) return;
        if (source != .slot or target != .slot) {
            try self.copyPlace(source, target, .{ .reg = moves.stack_scratch_gpr });
            return;
        }
        const scratch = if (self.scratchAt(self.allocation_position, &.{})) |reg|
            MoveScratch{ .reg = reg }
        else if (self.move_scratch_slots) |slots|
            MoveScratch{ .stack = .{ .slots = slots, .memory_reg = moves.stack_scratch_gpr } }
        else
            return error.NoScratchRegister;
        try self.copyPlace(source, target, scratch);
    }

    fn callArgSourceFor(self: *Emitter, value: *ir.Value) EmitError!ArgSource {
        if (self.registerHome(value)) |home| {
            return .{ .gpr = home };
        }
        if (self.xmmHome(value)) |home| {
            return .{ .xmm = home };
        }
        return .{ .slot = try self.slotFor(value) };
    }

    fn appendParallelValueMoveAt(
        self: *Emitter,
        parallel: *std.ArrayListUnmanaged(moves.Move),
        source: *ir.Value,
        source_position: u32,
        target: *ir.Value,
        target_position: u32,
    ) EmitError!void {
        try self.appendParallelValueMoveAtPoints(
            parallel,
            source,
            regalloc.PositionPoint.source(source_position),
            target,
            regalloc.PositionPoint.source(target_position),
        );
    }

    /// Whether a region's result is worth settling when the region exits.
    ///
    /// A result nothing reads was given no slot, so the move that would carry the region's
    /// value into it has nowhere to land. Skipping it is the same decision slot allocation
    /// already made, one step later.
    ///
    /// THIS TEST IS SOUND FOR A RESULT AND NOT FOR A BLOCK ARGUMENT. A result is read only
    /// through its uses, so no use means no reader. A loop's block argument is different: the
    /// backend itself reads one at the loop exit to produce the loop's result, and that read is
    /// not an operand of any operation, so `hasNoUses` would call a live value dead.
    fn resultNeedsSettling(self: *const Emitter, result: *ir.Value) bool {
        _ = self;
        return !result.hasNoUses();
    }

    /// Whether a value arrives in its frame slot rather than in a register.
    ///
    /// A value allocation gave no home of its own carries only ranges a reload enters, and a
    /// reload's register holds nothing until the reload itself runs. Between the point the
    /// value arrives and that range's start the value lives in its slot and nowhere else, so
    /// the slot is the only place a writer at the arrival point may use.
    fn arrivesInSlot(self: *const Emitter, value: *ir.Value) bool {
        if (valueIsFloatScalar(value)) {
            if (!self.hasPlannedXmmLocation(value)) return false;
            return !self.xmm_location_index.valueHasEntry(self.xmm_location_ranges.items, value, .resident);
        }
        if (!self.hasPlannedValueLocation(value)) return false;
        return !self.value_location_index.valueHasEntry(self.value_location_ranges.items, value, .resident);
    }

    /// THE PLACE A LOOP EDGE WRITES FOR ONE CARRIED VALUE.
    ///
    /// A LOOP EDGE WRITES THE PLACE THE VALUE OCCUPIES WHERE CONTROL ARRIVES, NEVER A PLACE IT
    /// OCCUPIES LATER. A carried value is defined by the edge itself, so a range a resident
    /// entry opens begins where control arrives and names the register to write. A value with
    /// no such range arrives in its slot, and the reload allocation planned then loads what the
    /// edge wrote there.
    ///
    /// Reading the register of a later reload range instead leaves the arrival slot unwritten.
    /// The planned reload reads a frame cell nothing ever stored, while intervening operations
    /// may clobber the register holding the value. It can also let two carried values name one
    /// register, since
    /// two places read at two different future positions need not differ, which is the
    /// `InvalidParallelMove` a flat `scf.while` met at fifteen and sixteen carried values.
    fn arrivalPlaceFor(self: *Emitter, value: *ir.Value, fallback_position: u32, phase: regalloc.PositionPhase) EmitError!moves.Place {
        if (self.arrivesInSlot(value)) return .{ .slot = try self.slotFor(value) };
        const position = self.plannedValueStart(value) orelse fallback_position;
        return self.placeForAtPoint(value, .{ .position = position, .phase = phase });
    }

    /// Appends the move one loop edge makes for one carried value.
    fn appendCarriedValueMove(
        self: *Emitter,
        parallel: *std.ArrayListUnmanaged(moves.Move),
        source: *ir.Value,
        source_point: regalloc.PositionPoint,
        target: *ir.Value,
        arrival_position: u32,
        arrival_phase: regalloc.PositionPhase,
    ) EmitError!void {
        const source_slot = try self.slotFor(source);
        const target_slot = try self.slotFor(target);
        if (source_slot.width != target_slot.width) return error.InvalidParallelMove;
        try parallel.append(self.allocator, .{
            .src = try self.placeForAtPoint(source, source_point),
            .dst = try self.arrivalPlaceFor(target, arrival_position, arrival_phase),
        });
    }

    fn appendParallelValueMoveAtPoints(
        self: *Emitter,
        parallel: *std.ArrayListUnmanaged(moves.Move),
        source: *ir.Value,
        source_point: regalloc.PositionPoint,
        target: *ir.Value,
        target_point: regalloc.PositionPoint,
    ) EmitError!void {
        const source_slot = try self.slotFor(source);
        const target_slot = try self.slotFor(target);
        if (source_slot.width != target_slot.width) return error.InvalidParallelMove;
        try parallel.append(self.allocator, .{
            .src = try self.placeForAtPoint(source, source_point),
            .dst = try self.placeForAtPoint(target, target_point),
        });
    }

    pub fn emitParallelMoves(self: *Emitter, parallel: []const moves.Move) EmitError!void {
        if (parallel.len == 0) return;

        var int_moves: std.ArrayListUnmanaged(moves.Move) = .empty;
        defer int_moves.deinit(self.allocator);
        var float_moves: std.ArrayListUnmanaged(moves.Move) = .empty;
        defer float_moves.deinit(self.allocator);
        try moves.split(self.allocator, parallel, &int_moves, &float_moves);
        // The general side breaks a cycle in the first free scratch register, and both sides
        // copy slot to slot through another, so no copy overwrites a value a cycle holds.
        const cycle = self.selectScratchReg(parallel, null);
        const copy = try self.moveScratch(parallel, cycle);
        try self.emitIntParallelMoves(int_moves.items, cycle, copy);
        try self.emitFloatParallelMoves(float_moves.items, copy);
    }

    /// The scratch that copies one frame slot to another during a parallel assignment: a scratch
    /// register other than `cycle` that the assignment neither reads nor writes and no value
    /// occupies, or else `r11` saved to the frame's save slot around each copy, which keeps a
    /// cycle's value even in r11. Two free scratch registers are missing only in a function the
    /// allocator placed, and placing one reserves that slot.
    fn moveScratch(
        self: *const Emitter,
        parallel: []const moves.Move,
        cycle: ?GPR,
    ) EmitError!MoveScratch {
        if (cycle) |held| {
            if (self.selectScratchReg(parallel, held)) |reg| return .{ .reg = reg };
        }
        const slots = self.move_scratch_slots orelse return error.NoScratchRegister;
        return .{ .stack = .{ .slots = slots, .memory_reg = moves.stack_scratch_gpr } };
    }

    /// Resolves the general side of a parallel assignment, breaking a cycle in `cycle` or the
    /// frame's cycle slot, and copies slot to slot through `copy`.
    ///
    /// A BROKEN CYCLE'S VALUE NEVER WAITS IN THE REGISTER THE COPIES PASS THROUGH. It once did,
    /// so a swap of two frame slots copied one slot through the register holding the other's
    /// value, and both ended with the second value. `moveScratch` never answers `cycle`.
    fn emitIntParallelMoves(
        self: *Emitter,
        parallel: []const moves.Move,
        cycle: ?GPR,
        copy: MoveScratch,
    ) EmitError!void {
        if (parallel.len == 0) return;
        const waiting: moves.Place = if (cycle) |reg|
            .{ .reg = reg }
        else if (self.move_scratch_slots) |slots|
            .{ .slot = slots.cycle }
        else
            return error.NoScratchRegister;

        var resolved: std.ArrayListUnmanaged(moves.Move) = .empty;
        defer resolved.deinit(self.allocator);
        try moves.resolve(self.allocator, parallel, waiting, &resolved);
        for (resolved.items) |move| {
            try self.copyPlace(move.src, move.dst, copy);
        }
    }

    /// Resolves the moves `moves.split` gave the XMM side, whose places are XMM registers and the
    /// frame slots of reals, and copies slot to slot through `copy`.
    fn emitFloatParallelMoves(
        self: *Emitter,
        parallel: []const moves.Move,
        copy: MoveScratch,
    ) EmitError!void {
        if (parallel.len == 0) return;
        // A cycle needs one place outside it: a free XMM register, or the frame's cycle slot
        // when every XMM register holds a value here, as at a call passing eight reals. The slot
        // is one 64 bit word, which holds any scalar real; a packed value never reaches here.
        const scratch: moves.Place = if (self.selectXmmScratchReg(parallel)) |reg|
            .{ .xmm = reg }
        else if (self.move_scratch_slots) |slots|
            .{ .slot = slots.cycle }
        else
            return error.NoScratchRegister;
        var resolved: std.ArrayListUnmanaged(moves.Move) = .empty;
        defer resolved.deinit(self.allocator);
        try moves.resolve(self.allocator, parallel, scratch, &resolved);
        for (resolved.items) |move| {
            try self.copyPlace(move.src, move.dst, copy);
        }
    }

    fn xmmHostsRangeAt(self: *const Emitter, reg: XMM, position: u32) bool {
        return self.xmm_location_index.registerBlocksAt(reg, .{ .position = position, .phase = .source }) or
            self.xmm_location_index.registerBlocksAt(reg, .{ .position = position, .phase = .definition });
    }

    fn selectXmmScratchReg(self: *const Emitter, parallel: []const moves.Move) ?XMM {
        for (registers.allocatable_xmms) |reg| {
            var used = false;
            for (parallel) |move| {
                if (moves.usesXmm(move.src, reg) or moves.usesXmm(move.dst, reg)) {
                    used = true;
                    break;
                }
            }
            if (used) continue;
            if (self.xmmHostsRangeAt(reg, self.allocation_position)) continue;
            return reg;
        }
        return null;
    }

    fn registerHostsRangeAt(self: *const Emitter, reg: GPR, position: u32) bool {
        return self.value_location_index.registerBlocksAt(reg, .{ .position = position, .phase = .source }) or
            self.value_location_index.registerBlocksAt(reg, .{ .position = position, .phase = .definition });
    }

    fn scratchAt(self: *const Emitter, position: u32, excluded: []const GPR) ?GPR {
        scan: for (moves.scratch_gprs) |reg| {
            for (excluded) |exclude| {
                if (exclude == reg) continue :scan;
            }
            if (self.registerHostsRangeAt(reg, position)) continue;
            return reg;
        }
        return null;
    }

    fn selectScratchReg(self: *const Emitter, parallel: []const moves.Move, excluded: ?GPR) ?GPR {
        for (moves.scratch_gprs) |reg| {
            if (excluded == reg) continue;
            var used = false;
            for (parallel) |move| {
                if (moves.usesReg(move.src, reg) or moves.usesReg(move.dst, reg)) {
                    used = true;
                    break;
                }
            }
            if (used) continue;
            if (self.registerHostsRangeAt(reg, self.allocation_position)) continue;
            return reg;
        }
        return null;
    }

    /// Whether `slot` is the frame's cycle slot, the one 64 bit word a parallel assignment's
    /// cycle waits in when no register is free.
    fn isCycleSlot(self: *const Emitter, slot: Slot) bool {
        const slots = self.move_scratch_slots orelse return false;
        return slot.offset == slots.cycle.offset;
    }

    fn copyPlace(self: *Emitter, src: moves.Place, dst: moves.Place, scratch: MoveScratch) EmitError!void {
        if (moves.samePlace(src, dst)) return;
        switch (src) {
            .reg => |source_reg| switch (dst) {
                .reg => |dest_reg| try self.emitEncoding(encoding.movRegReg(dest_reg, source_reg)),
                .slot => |dest_slot| try self.storeSlot(dest_slot, source_reg),
                .xmm => return error.InvalidParallelMove,
            },
            .xmm => |source_reg| switch (dst) {
                .xmm => |dest_reg| try self.emitEncoding(encoding.movaps(dest_reg, .{ .reg = source_reg })),
                .slot => |dest_slot| try self.storeSlotXmm(dest_slot, source_reg),
                .reg => return error.InvalidParallelMove,
            },
            .slot => |source_slot| switch (dst) {
                .reg => |dest_reg| try self.loadSlot(source_slot, dest_reg),
                .xmm => |dest_reg| try self.loadSlotXmm(source_slot, dest_reg),
                .slot => |dest_slot| {
                    // Only the frame's cycle slot takes a value of another width: it is one 64
                    // bit word, and a cycle waits there whichever value it breaks, a 32 bit
                    // one included. The load reads the source's width and the store writes the
                    // destination's, so the value's own bits make the round trip.
                    if (source_slot.width != dest_slot.width) {
                        const waits = self.isCycleSlot(source_slot) or self.isCycleSlot(dest_slot);
                        if (!waits) return error.InvalidParallelMove;
                        const widest = @max(source_slot.width, dest_slot.width);
                        if (widest > 64) return error.InvalidParallelMove;
                    }
                    switch (scratch) {
                        .reg => |scratch_reg| {
                            try self.loadSlot(source_slot, scratch_reg);
                            try self.storeSlot(dest_slot, scratch_reg);
                        },
                        .stack => |stack| {
                            try self.storeSlot(stack.slots.save, stack.memory_reg);
                            try self.loadSlot(source_slot, stack.memory_reg);
                            try self.storeSlot(dest_slot, stack.memory_reg);
                            try self.loadSlot(stack.slots.save, stack.memory_reg);
                        },
                    }
                },
            },
        }
    }

    /// Branch lookup uses the value, never just its producer: overflow result 0 is data.
    fn emitFalseBranchForConditionValue(self: *Emitter, value: *ir.Value, exit_label: *Label) EmitError!bool {
        const condition = self.flag_conditions.get(value) orelse return false;
        try self.emitJccLabel(condition, exit_label);
        return true;
    }

    /// Sets the flags for a comparison of a materialized condition with zero, reading it where
    /// it lives: its register home when it has one, otherwise its frame slot.
    ///
    /// NO SCRATCH REGISTER IS TOUCHED, AND THAT IS THE POINT. The allocator records no clobber
    /// at a `scf.if` or a `scf.condition`, so a value it placed in any register may still be
    /// live across the branch. Loading the condition into rax first would destroy such a value,
    /// which is how a loop once forwarded its own condition in place of the value it carried.
    fn emitCompareWithZero(self: *Emitter, value: *ir.Value) EmitError!void {
        const slot = try self.slotFor(value);
        if (self.registerHome(value)) |home| {
            try self.emitEncoding(if (slot.width == 32)
                encoding.cmpRegImm32(home, 0)
            else
                encoding.cmpRegImm(home, 0));
            return;
        }
        const mem = Mem.baseDisp(.rbp, slot.offset);
        switch (slot.width) {
            32 => try self.emitEncoding(encoding.cmpMemImm8_32(mem, 0)),
            64 => try self.emitEncoding(encoding.cmpMemImm8(mem, 0)),
            else => return error.UnsupportedType,
        }
    }

    fn valueHasSingleUse(value: *ir.Value) bool {
        const first = value.first_use orelse return false;
        return first.next_use == null;
    }

    fn invertCondition(cond: Condition) Condition {
        return @fromBackingInt(@intCast(@backingInt(cond) ^ 1));
    }

    fn recordFailure(self: *Emitter, op: *ir.Operation) void {
        if (self.failed_operation == null) self.failed_operation = op;
    }

    fn emitBlockOps(self: *Emitter, block: *ir.Block, terminator: BlockTerminator) EmitError!BlockResult {
        var op_iter = block.operations.head;
        while (op_iter) |op_ptr| {
            const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
            errdefer self.recordFailure(op);
            const name = op.name.name;

            if (std.mem.eql(u8, name, ScfDialect.ConditionOp.operation_name)) {
                switch (terminator) {
                    .while_condition => |ctx| {
                        try self.enterOperationPosition(op);
                        ctx.position.* = self.allocation_position;
                        const cond_op = ScfDialect.ConditionOp{ .op = op };
                        ctx.value.* = cond_op.getCondition();
                        for (cond_op.getArgs()) |arg| {
                            if (ctx.arg_count.* >= ctx.args.len) return error.InvalidWhileArity;
                            ctx.args[ctx.arg_count.*] = arg;
                            ctx.arg_count.* += 1;
                        }
                        if (op.next_op != null) return error.UnexpectedOperationAfterCondition;
                        return .conditioned;
                    },
                    else => return error.UnsupportedOperation,
                }
            }

            if (op.getResult(0)) |result| {
                if (self.flagsOnly(result)) {
                    try self.beginOperation(op);
                    if (std.mem.eql(u8, name, ArithDialect.CmpOp.operation_name)) {
                        const emitted = try scalar.emitArithCmpFlags(self, op);
                        std.debug.assert(emitted);
                    } else {
                        std.debug.assert(std.mem.eql(u8, name, ArithDialect.NotOp.operation_name));
                    }
                    op_iter = op.next_op;
                    continue;
                }
            }

            if (self.omitted_ops.contains(op)) {
                try self.enterOperationPosition(op);
                op_iter = op.next_op;
                continue;
            }

            try self.beginOperation(op);

            if (std.mem.eql(u8, name, FuncDialect.ReturnOp.operation_name)) {
                try self.emitReturn(op);
                return .returned;
            }
            if (std.mem.eql(u8, name, ScfDialect.YieldOp.operation_name)) {
                switch (terminator) {
                    .function_return, .while_condition => return error.UnexpectedYield,
                    .if_yield => |ctx| {
                        try self.emitIfYield(op, ctx.op);
                        try self.emitJmpLabel(ctx.merge_label);
                        return .yielded;
                    },
                    .for_yield => |ctx| {
                        try self.emitForYield(op, ctx.body_block, ctx.iv, ctx.step, ctx.entry_position, ctx.header_label);
                        return .yielded;
                    },
                    .while_yield => |ctx| {
                        try self.emitWhileYield(op, ctx.before_block, ctx.header_label);
                        return .yielded;
                    },
                }
            }

            if (std.mem.eql(u8, name, ScfDialect.IfOp.operation_name)) {
                const if_op = ScfDialect.IfOp{ .op = op };
                const cond_val = if_op.getCondition();

                try self.saveIfIncomingValues(op);

                var else_label = Label{};
                defer else_label.deinit(self.allocator);
                var merge_label = Label{};
                defer merge_label.deinit(self.allocator);

                if (!try self.emitFalseBranchForConditionValue(cond_val, &else_label)) {
                    try self.emitCompareWithZero(cond_val);
                    try self.emitJccLabel(.e, &else_label);
                }

                const then_block = if_op.getThenBlock();
                try self.restoreIfArmValues(op, then_block);
                _ = try self.emitBlockOps(then_block, .{ .if_yield = .{
                    .op = op,
                    .merge_label = &merge_label,
                } });

                if (if_op.getElseBlock()) |else_block| {
                    try self.bindLabel(&else_label);
                    try self.restoreIfArmValues(op, else_block);
                    _ = try self.emitBlockOps(else_block, .{ .if_yield = .{
                        .op = op,
                        .merge_label = &merge_label,
                    } });
                } else {
                    try self.bindLabel(&else_label);
                }

                try self.bindLabel(&merge_label);
                try self.restoreIfOutgoingValues(op);
                op_iter = op.next_op;
                continue;
            }

            if (std.mem.eql(u8, name, ScfDialect.ForOp.operation_name)) {
                const for_op = ScfDialect.ForOp{ .op = op };
                const lower = for_op.getLowerBound();
                const upper = for_op.getUpperBound();
                const step = for_op.getStep();

                const body_block = for_op.getBodyBlock();
                if (body_block.arguments.items.len == 0) return error.MissingInductionVariable;

                const iv = body_block.arguments.items[0];
                const for_position = self.allocation_position;
                const entry_position = for_position + 1;

                const num_inits = op.operands.items.len - 3;
                var entry_moves: std.ArrayListUnmanaged(moves.Move) = .empty;
                defer entry_moves.deinit(self.allocator);
                try self.appendCarriedValueMove(
                    &entry_moves,
                    lower,
                    regalloc.PositionPoint.source(for_position),
                    iv,
                    entry_position,
                    .source,
                );
                for (0..num_inits) |i| {
                    const init_val = op.operands.items[3 + i].value;
                    const iter_arg = body_block.arguments.items[1 + i];
                    try self.appendCarriedValueMove(
                        &entry_moves,
                        init_val,
                        regalloc.PositionPoint.source(for_position),
                        iter_arg,
                        entry_position,
                        .source,
                    );
                }
                try self.emitParallelMoves(entry_moves.items);
                try self.mirrorValueToSlotIfReloaded(iv, try self.arrivalPlaceFor(iv, entry_position, .source));
                for (0..num_inits) |i| {
                    const iter_arg = body_block.arguments.items[1 + i];
                    try self.mirrorValueToSlotIfReloaded(iter_arg, try self.arrivalPlaceFor(iter_arg, entry_position, .source));
                }

                var header_label = Label{};
                defer header_label.deinit(self.allocator);
                var exit_label = Label{};
                defer exit_label.deinit(self.allocator);

                try self.bindLabel(&header_label);
                try self.emitForGuard(iv, upper, entry_position, &exit_label);

                const body_result = try self.emitBlockOps(body_block, .{ .for_yield = .{
                    .body_block = body_block,
                    .iv = iv,
                    .step = step,
                    .entry_position = entry_position,
                    .header_label = &header_label,
                } });
                if (body_result == .returned) return .returned;

                try self.bindLabel(&exit_label);
                try self.enterMergePosition(op);

                var exit_moves: std.ArrayListUnmanaged(moves.Move) = .empty;
                defer exit_moves.deinit(self.allocator);
                for (0..num_inits) |i| {
                    const result = op.getResult(i) orelse continue;
                    if (!self.resultNeedsSettling(result)) continue;
                    const iter_arg = body_block.arguments.items[1 + i];
                    const source_slot = try self.slotFor(iter_arg);
                    const result_slot = try self.slotFor(result);
                    if (source_slot.width != result_slot.width) return error.InvalidParallelMove;
                    try exit_moves.append(self.allocator, .{
                        .src = try self.arrivalPlaceFor(iter_arg, entry_position, .source),
                        .dst = try self.arrivalPlaceFor(result, self.allocation_position, .definition),
                    });
                }
                try self.emitParallelMoves(exit_moves.items);

                op_iter = op.next_op;
                continue;
            }

            if (std.mem.eql(u8, name, ScfDialect.WhileOp.operation_name)) {
                const while_op = ScfDialect.WhileOp{ .op = op };
                const before_block = while_op.getBeforeBlock();
                const after_block = while_op.getAfterBlock();

                const init_count = op.operands.items.len;
                try self.admitCount(.while_values, max_while_carried_values, init_count, error.TooManyWhileValues);
                if (before_block.arguments.items.len != init_count) return error.InvalidWhileArity;
                if (after_block.arguments.items.len != init_count) return error.InvalidWhileArity;
                if (op.results.items.len != init_count) return error.InvalidWhileArity;

                var init_moves: std.ArrayListUnmanaged(moves.Move) = .empty;
                defer init_moves.deinit(self.allocator);
                for (0..init_count) |i| {
                    const init_val = op.operands.items[i].value;
                    const before_arg = before_block.arguments.items[i];
                    try self.appendCarriedValueMove(
                        &init_moves,
                        init_val,
                        regalloc.PositionPoint.source(self.allocation_position),
                        before_arg,
                        self.allocation_position,
                        .source,
                    );
                }
                try self.emitParallelMoves(init_moves.items);

                var header_label = Label{};
                defer header_label.deinit(self.allocator);
                var exit_label = Label{};
                defer exit_label.deinit(self.allocator);

                try self.emitJmpLabel(&header_label);
                try self.bindLabel(&header_label);

                var cond_val: ?*ir.Value = null;
                var cond_args_buf: [max_while_carried_values]*ir.Value = undefined;
                var cond_arg_count: usize = 0;
                var condition_position: u32 = self.allocation_position;

                const before_result = try self.emitBlockOps(before_block, .{ .while_condition = .{
                    .value = &cond_val,
                    .args = cond_args_buf[0..],
                    .arg_count = &cond_arg_count,
                    .position = &condition_position,
                } });
                if (before_result == .returned) return .returned;

                const cond_value = cond_val orelse return error.MissingCondition;
                if (cond_arg_count != init_count) return error.InvalidWhileArity;

                if (!try self.emitFalseBranchForConditionValue(cond_value, &exit_label)) {
                    try self.emitCompareWithZero(cond_value);
                    try self.emitJccLabel(.e, &exit_label);
                }

                var condition_moves: std.ArrayListUnmanaged(moves.Move) = .empty;
                defer condition_moves.deinit(self.allocator);
                for (0..cond_arg_count) |i| {
                    const cond_arg_slot = try self.slotFor(cond_args_buf[i]);
                    const after_arg = after_block.arguments.items[i];
                    const after_slot = self.slot_map.getPtr(after_arg) orelse return error.MissingSlot;
                    after_slot.* = cond_arg_slot;
                    try self.appendCarriedValueMove(
                        &condition_moves,
                        cond_args_buf[i],
                        regalloc.PositionPoint.source(self.allocation_position),
                        after_arg,
                        self.allocation_position,
                        .source,
                    );
                }
                try self.emitParallelMoves(condition_moves.items);

                const after_result = try self.emitBlockOps(after_block, .{ .while_yield = .{
                    .before_block = before_block,
                    .header_label = &header_label,
                } });
                if (after_result == .returned) return .returned;

                try self.bindLabel(&exit_label);
                try self.enterMergePosition(op);

                var exit_moves: std.ArrayListUnmanaged(moves.Move) = .empty;
                defer exit_moves.deinit(self.allocator);
                for (0..cond_arg_count) |i| {
                    const result = op.getResult(i) orelse continue;
                    if (!self.resultNeedsSettling(result)) continue;
                    try self.appendCarriedValueMove(
                        &exit_moves,
                        cond_args_buf[i],
                        regalloc.PositionPoint.source(condition_position),
                        result,
                        self.allocation_position,
                        .definition,
                    );
                }
                try self.emitParallelMoves(exit_moves.items);

                op_iter = op.next_op;
                continue;
            }

            try self.dispatchOp(op);
            op_iter = op.next_op;
        }

        return switch (terminator) {
            .function_return, .while_condition => .fell_through,
            .if_yield, .for_yield, .while_yield => error.MissingYield,
        };
    }

    fn dispatchOp(self: *Emitter, op: *ir.Operation) EmitError!void {
        const name = op.name.name;

        if (std.mem.eql(u8, name, ArithDialect.ConstantOp.operation_name)) {
            if (scalar.shouldSkipArithConstant(op)) return;
            return scalar.emitArithConstant(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.VecConstantOp.operation_name)) {
            return vector.emitConstant(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.SplatOp.operation_name)) {
            return vector.emitSplat(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.ExtractOp.operation_name)) {
            return vector.emitExtract(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.InsertOp.operation_name)) {
            return vector.emitInsert(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.VecShuffleOp.operation_name)) {
            return vector.emitShuffle(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.VecCmpOp.operation_name)) {
            return vector.emitCmp(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.AddOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitBinaryOp(self, op, .add);
            return scalar.emitBinaryIntOp(self, op, .add);
        }
        if (std.mem.eql(u8, name, ArithDialect.SubOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitBinaryOp(self, op, .sub);
            return scalar.emitBinaryIntOp(self, op, .sub);
        }
        if (std.mem.eql(u8, name, ArithDialect.MulOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitBinaryOp(self, op, .mul);
            return scalar.emitBinaryIntOp(self, op, .mul);
        }
        if (std.mem.eql(u8, name, ArithDialect.UmulhiOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitUmulhi(self, op);
            return scalar.emitArithUmulhi(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.DivOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitBinaryOp(self, op, .div);
            return scalar.emitBinaryIntOp(self, op, .div);
        }
        if (std.mem.eql(u8, name, ArithDialect.RemOp.operation_name)) {
            return scalar.emitBinaryIntOp(self, op, .rem);
        }
        if (std.mem.eql(u8, name, ArithDialect.NegOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitNeg(self, op);
            return scalar.emitArithNeg(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.MaxOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitMinMax(self, op, .max);
            return scalar.emitArithMax(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.MinOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitMinMax(self, op, .min);
            return scalar.emitArithMin(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.SqrtOp.operation_name)) {
            return scalar.emitArithSqrt(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.FloorOp.operation_name)) {
            return scalar.emitArithLibmUnary(self, op, .floor);
        }
        if (std.mem.eql(u8, name, ArithDialect.AbsOp.operation_name)) {
            return scalar.emitArithAbs(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.PopCountOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitPopCount(self, op);
            return scalar.emitArithPopCount(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.SinOp.operation_name)) {
            return scalar.emitArithLibmUnary(self, op, .sin);
        }
        if (std.mem.eql(u8, name, ArithDialect.CosOp.operation_name)) {
            return scalar.emitArithLibmUnary(self, op, .cos);
        }
        if (std.mem.eql(u8, name, ArithDialect.TanOp.operation_name)) {
            return scalar.emitArithLibmUnary(self, op, .tan);
        }
        if (std.mem.eql(u8, name, ArithDialect.ExpOp.operation_name)) {
            return scalar.emitArithLibmUnary(self, op, .exp);
        }
        if (std.mem.eql(u8, name, ArithDialect.LogOp.operation_name)) {
            return scalar.emitArithLibmUnary(self, op, .log);
        }
        if (std.mem.eql(u8, name, ArithDialect.Log1pOp.operation_name)) {
            return scalar.emitArithLibmUnary(self, op, .log1p);
        }
        if (std.mem.eql(u8, name, ArithDialect.Expm1Op.operation_name)) {
            return scalar.emitArithLibmUnary(self, op, .expm1);
        }
        if (std.mem.eql(u8, name, ArithDialect.TanhOp.operation_name)) {
            return scalar.emitArithLibmUnary(self, op, .tanh);
        }
        if (std.mem.eql(u8, name, ArithDialect.PowOp.operation_name)) {
            return scalar.emitArithLibmBinary(self, op, .pow);
        }
        if (std.mem.eql(u8, name, ArithDialect.FmaOp.operation_name)) {
            return scalar.emitArithFma(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.AndOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitBitwiseBinary(self, op, .band);
            return scalar.emitArithBitwiseBinary(self, op, .band);
        }
        if (std.mem.eql(u8, name, ArithDialect.OrOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitBitwiseBinary(self, op, .bor);
            return scalar.emitArithBitwiseBinary(self, op, .bor);
        }
        if (std.mem.eql(u8, name, ArithDialect.XorOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitBitwiseBinary(self, op, .bxor);
            return scalar.emitArithBitwiseBinary(self, op, .bxor);
        }
        if (std.mem.eql(u8, name, ArithDialect.NotOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitNot(self, op);
            return scalar.emitArithNot(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.ShlOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitShift(self, op, .shl);
            return scalar.emitArithShift(self, op, .shl);
        }
        if (std.mem.eql(u8, name, ArithDialect.ShrOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitShift(self, op, .shr);
            return scalar.emitArithShift(self, op, .shr);
        }
        if (std.mem.eql(u8, name, ArithDialect.UshrOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitShift(self, op, .ushr);
            return scalar.emitArithShift(self, op, .ushr);
        }
        if (std.mem.eql(u8, name, ArithDialect.CastOp.operation_name)) {
            return cast.emitCast(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.BitcastOp.operation_name)) {
            return cast.emitBitcast(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.SelectOp.operation_name)) {
            if (try resultIsVector(op)) return vector.emitSelect(self, op);
            return scalar.emitArithSelect(self, op);
        }
        if (std.mem.eql(u8, name, ArithDialect.CmpOp.operation_name)) {
            return scalar.emitArithCmp(self, op);
        }

        if (std.mem.eql(u8, name, FuncDialect.CallOp.operation_name)) {
            return self.emitCall(op);
        }
        if (std.mem.eql(u8, name, FuncDialect.SyscallOp.operation_name)) {
            return self.emitSyscall(op);
        }

        if (std.mem.eql(u8, name, MemrefDialect.LoadOp.operation_name)) {
            return memory.emitLoad(self, op);
        }
        if (std.mem.eql(u8, name, MemrefDialect.StoreOp.operation_name)) {
            return memory.emitStore(self, op);
        }
        if (std.mem.eql(u8, name, MemrefDialect.AllocOp.operation_name)) {
            return memory.emitAlloc(self, op);
        }
        if (std.mem.eql(u8, name, MemrefDialect.AllocaOp.operation_name)) {
            return memory.emitAlloca(self, op);
        }
        if (std.mem.eql(u8, name, MemrefDialect.DeallocOp.operation_name)) {
            return memory.emitDealloc(self, op);
        }
        if (std.mem.eql(u8, name, MemrefDialect.GetGlobalOp.operation_name)) {
            return memory.emitGetGlobal(self, op);
        }
        if (std.mem.eql(u8, name, MemrefDialect.ViewOp.operation_name)) {
            return memory.emitView(self, op);
        }
        if (std.mem.eql(u8, name, MemrefDialect.AtomicLoadOp.operation_name)) {
            return memory.emitAtomicLoad(self, op);
        }
        if (std.mem.eql(u8, name, MemrefDialect.AtomicStoreOp.operation_name)) {
            return memory.emitAtomicStore(self, op);
        }
        if (std.mem.eql(u8, name, MemrefDialect.AtomicCasOp.operation_name)) {
            return memory.emitAtomicCas(self, op);
        }
        if (std.mem.eql(u8, name, MemrefDialect.FenceOp.operation_name)) {
            return memory.emitFence(self, op);
        }

        if (std.mem.eql(u8, name, ArithDialect.AddoOp.operation_name)) {
            return scalar.emitOverflow(self, op, .add);
        }
        if (std.mem.eql(u8, name, ArithDialect.SuboOp.operation_name)) {
            return scalar.emitOverflow(self, op, .sub);
        }
        if (std.mem.eql(u8, name, ArithDialect.MuloOp.operation_name)) {
            return scalar.emitOverflow(self, op, .mul);
        }

        return error.UnsupportedOperation;
    }

    fn emitCall(self: *Emitter, op: *ir.Operation) EmitError!void {
        const call_op = FuncDialect.CallOp{ .op = op };
        const callee = call_op.getCallee() orelse return error.MissingCallee;
        try self.admitCount(.results, abi.max_result_count, op.results.items.len, error.TooManyResults);
        try self.admitCount(.call_arguments, abi.max_call_arguments, op.operands.items.len, error.TooManyArguments);
        if (op.results.items.len > 1) return self.emitProductCall(op, callee);

        const arg_count = op.operands.items.len;
        var uses_sret = false;
        var sret_slot: ?Slot = null;

        if (op.getResult(0)) |result_val| {
            const type_name = result_val.type.getDialectTypeName() orelse return error.UnsupportedType;
            if (arith.parseVectorTypeName(type_name) != null) {
                const vec_slot = try self.vectorSlotFor(result_val);
                uses_sret = true;
                sret_slot = vec_slot.base;
            }
        }

        const total_args: usize = arg_count + @as(usize, @intFromBool(uses_sret));
        const args = try self.allocator.alloc(ExternArg, total_args);
        defer self.allocator.free(args);

        var arg_index: usize = 0;
        if (uses_sret) {
            const slot = sret_slot orelse return error.MissingSlot;
            args[arg_index] = .{ .type_name = "arith.index", .source = .{ .addr_of_slot = slot } };
            arg_index += 1;
        }

        for (op.operands.items) |operand| {
            const arg_val = operand.value;
            const type_name = arg_val.type.getDialectTypeName() orelse return error.UnsupportedType;
            args[arg_index] = .{ .type_name = type_name, .source = try self.callArgSourceFor(arg_val) };
            arg_index += 1;
        }

        var results: [1]ExternResult = undefined;
        var result_count: usize = 0;
        if (!uses_sret) {
            if (op.getResult(0)) |result_val| {
                const type_name = result_val.type.getDialectTypeName() orelse return error.UnsupportedType;
                results[0] = .{ .type_name = type_name, .slot = self.callResultSlot(result_val) };
                result_count = 1;
            }
        }

        try call_plan.emitExtern(self, callee, args, results[0..result_count]);
        if (!uses_sret) {
            if (op.getResult(0)) |result_val| {
                if (self.registerHomeForPhase(result_val, .definition) != null) {
                    try self.storeFrom(result_val, .rax);
                } else if (self.xmmHomeForPhase(result_val, .definition) != null) {
                    try self.storeFromXmm(result_val, .xmm0);
                }
            }
        }
    }

    /// Where the call plan settles a single scalar result, or null to leave it in rax or xmm0.
    ///
    /// Two results want nothing written to the frame. One the allocator gave a register home:
    /// `emitCall` moves rax or xmm0 into that home right after the call, and a later range end
    /// spills the home to the slot at the point the spill belongs, so writing the slot here as
    /// well would be the same number stored twice. One nothing reads at all, which was given no
    /// slot.
    fn callResultSlot(self: *Emitter, value: *ir.Value) ?Slot {
        if (self.registerHomeForPhase(value, .definition) != null) return null;
        if (self.xmmHomeForPhase(value, .definition) != null) return null;
        return self.slotForOptional(value);
    }

    /// Calls a function with several scalar results and settles each result in its home.
    /// Results reach their slots inside the call plan, before volatile registers are restored.
    fn emitProductCall(self: *Emitter, op: *ir.Operation, callee: []const u8) EmitError!void {
        const result_count = op.results.items.len;
        std.debug.assert(result_count > 1);
        std.debug.assert(result_count <= abi.max_result_count);
        var results: [abi.max_result_count]ExternResult = undefined;
        const record = abi.returnsThroughRecord(result_count);
        for (op.results.items, 0..) |*result, i| {
            if (try self.vectorTypeInfoFromType(result.type) != null) return error.UnsupportedType;
            const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
            const slot: ?Slot = if (record) try self.slotFor(result) else self.slotForOptional(result);
            if (slot == null) std.debug.assert(result.hasNoUses());
            results[i] = .{ .type_name = type_name, .slot = slot };
        }

        const hidden: usize = @intFromBool(record);
        const args = try self.allocator.alloc(ExternArg, op.operands.items.len + hidden);
        defer self.allocator.free(args);
        if (hidden != 0) {
            const record_slot = results[0].slot.?;
            args[0] = .{ .type_name = "arith.index", .source = .{ .addr_of_slot = record_slot } };
        }
        for (op.operands.items, args[hidden..]) |operand, *arg| {
            const value = operand.value;
            const type_name = value.type.getDialectTypeName() orelse return error.UnsupportedType;
            arg.* = .{ .type_name = type_name, .source = try self.callArgSourceFor(value) };
        }

        try call_plan.emitExtern(self, callee, args, results[0..result_count]);
        for (op.results.items, results[0..result_count]) |*result, settled| {
            const slot = settled.slot orelse continue;
            if (self.registerHomeForPhase(result, .definition)) |home| {
                try self.loadSlot(slot, home);
            } else if (self.xmmHomeForPhase(result, .definition)) |home| {
                try self.loadSlotXmm(slot, home);
            }
        }
    }

    /// Places every operand in the register the kernel reads it from, enters the kernel, and
    /// takes the kernel's answer out of rax.
    ///
    /// The placement is one parallel move, the way a call settles its arguments, so an operand
    /// already living in another operand's destination survives the trip in. Every operand must
    /// be a 64-bit integer: the kernel reads whole registers, and a narrower value would leave
    /// the upper half of an argument register holding whatever the last instruction put there.
    fn emitSyscall(self: *Emitter, op: *ir.Operation) EmitError!void {
        const operand_count = op.operands.items.len;
        if (operand_count == 0) return error.MissingOperand;
        try self.admitCount(.syscall_arguments, max_syscall_arguments, operand_count - 1, error.TooManyArguments);

        var placements: [syscall_operand_regs.len]moves.Move = undefined;
        const destinations = syscall_operand_regs[0..operand_count];
        for (op.operands.items, destinations, placements[0..operand_count]) |operand, destination, *placement| {
            try self.requireSyscallWord(operand.value);
            placement.* = .{
                .src = try self.placeFor(operand.value),
                .dst = .{ .reg = destination },
            };
        }

        try self.emitParallelMoves(placements[0..operand_count]);
        try self.emitEncoding(encoding.syscall());

        const result = op.getResult(0) orelse return error.MissingResult;
        try self.requireSyscallWord(result);
        try self.storeFrom(result, regalloc.syscall_number_gpr);
    }

    /// Refuses a syscall operand or result that is not a 64-bit integer, by name rather than by
    /// silently widening it.
    fn requireSyscallWord(self: *Emitter, value: *ir.Value) EmitError!void {
        const type_name = value.type.getDialectTypeName() orelse return error.UnsupportedType;
        const info = try self.typeInfoFromName(type_name);
        if (info.is_float or info.width != 64) return error.UnsupportedType;
    }

    fn emitReturn(self: *Emitter, op: *ir.Operation) EmitError!void {
        const count = op.operands.items.len;
        try self.admitCount(.results, abi.max_result_count, count, error.TooManyResults);
        if ((count > 1 or self.result_count > 1) and count != self.result_count) {
            return error.ResultCountMismatch;
        }
        if (self.sret_info) |sret| {
            switch (sret) {
                .vector => try self.emitVectorReturn(op),
                .record => |record_count| {
                    std.debug.assert(record_count == count);
                    try self.emitRecordReturn(op);
                },
            }
        } else if (count == 1) {
            try self.emitScalarReturn(op.operands.items[0].value);
        } else if (count > 1) {
            try self.emitRegisterResults(op);
        }

        try self.emitEpilogue();
        self.saw_return = true;
    }

    fn emitVectorReturn(self: *Emitter, op: *ir.Operation) EmitError!void {
        if (op.operands.items.len == 0) return error.MissingOperand;
        const vec = try self.vectorSlotFor(op.operands.items[0].value);
        const sret_slot = self.sret_slot orelse return error.MissingSlot;
        try self.loadSlot(sret_slot, .rax);

        var lane_index: usize = 0;
        while (lane_index < vec.lanes) : (lane_index += 1) {
            const lane = slot_layout.laneSlot(vec.base, lane_index);
            const mem = Mem.baseDisp(.rax, slot_layout.laneDisplacement(vec.base, lane_index));
            if (vec.is_float) {
                try self.loadSlotXmm(lane, .xmm0);
                try self.storeMemoryXmm(mem, lane.width, .xmm0);
            } else {
                try self.loadSlot(lane, .rcx);
                try self.storeMemory(mem, lane.width, .rcx);
            }
        }
    }

    fn emitScalarReturn(self: *Emitter, value: *ir.Value) EmitError!void {
        const type_name = value.type.getDialectTypeName() orelse return error.UnsupportedType;
        if (std.mem.eql(u8, type_name, "arith.f32") or std.mem.eql(u8, type_name, "arith.f64")) {
            try self.loadIntoXmm(value, .xmm0);
            return;
        }
        try self.loadInto(value, .rax);
        if (std.mem.eql(u8, type_name, "arith.i32")) {
            try self.emitEncoding(encoding.movsxdRegReg(.rax, .rax));
        }
    }

    /// Moves a result pair into its SysV result registers as one parallel assignment.
    fn emitRegisterResults(self: *Emitter, op: *ir.Operation) EmitError!void {
        const count = op.operands.items.len;
        std.debug.assert(count > 1);
        std.debug.assert(!abi.returnsThroughRecord(count));
        var type_names: [abi.max_register_results][]const u8 = undefined;
        var locations: [abi.max_register_results]abi.ValueLocation = undefined;
        for (op.operands.items, 0..) |operand, i| {
            const operand_type = operand.value.type;
            type_names[i] = operand_type.getDialectTypeName() orelse return error.UnsupportedType;
        }
        abi.computeReturnLocations(type_names[0..count], locations[0..count]);

        var parallel: [abi.max_register_results]moves.Move = undefined;
        for (op.operands.items, locations[0..count], 0..) |operand, location, i| {
            const target: moves.Place = switch (location) {
                .int_reg => |reg| .{ .reg = reg },
                .fp_reg => |reg| .{ .xmm = reg },
                .stack => unreachable,
            };
            parallel[i] = .{ .src = try self.placeFor(operand.value), .dst = target };
        }
        try self.emitParallelMoves(parallel[0..count]);

        for (type_names[0..count], locations[0..count]) |type_name, location| {
            if (location != .int_reg or !std.mem.eql(u8, type_name, "arith.i32")) continue;
            try self.emitEncoding(encoding.movsxdRegReg(location.int_reg, location.int_reg));
        }
    }

    /// Settles every result in its own slot, then copies each one into the caller's record.
    fn emitRecordReturn(self: *Emitter, op: *ir.Operation) EmitError!void {
        const count = op.operands.items.len;
        std.debug.assert(abi.returnsThroughRecord(count));
        std.debug.assert(count <= abi.max_result_count);
        const record = self.sret_slot orelse return error.MissingSlot;

        var parallel: [abi.max_result_count]moves.Move = undefined;
        for (op.operands.items, 0..) |operand, i| {
            const value = operand.value;
            const source = try self.placeFor(value);
            parallel[i] = .{ .src = source, .dst = .{ .slot = try self.slotFor(value) } };
        }
        try self.emitParallelMoves(parallel[0..count]);

        try self.loadSlot(record, .rax);
        for (op.operands.items, 0..) |operand, i| {
            const slot = try self.slotFor(operand.value);
            const field = Mem.baseDisp(.rax, abi.recordFieldOffset(i));
            if (valueIsFloatScalar(operand.value)) {
                try self.loadSlotXmm(slot, .xmm0);
                try self.storeMemoryXmm(field, slot.width, .xmm0);
            } else {
                try self.loadSlot(slot, .rcx);
                try self.storeMemory(field, slot.width, .rcx);
            }
        }
    }

    fn emitIfYield(self: *Emitter, yield_op: *ir.Operation, if_op: *ir.Operation) EmitError!void {
        var parallel: std.ArrayListUnmanaged(moves.Move) = .empty;
        defer parallel.deinit(self.allocator);
        for (yield_op.operands.items, 0..) |operand, i| {
            const result = if_op.getResult(i) orelse return error.MissingResult;
            if (!self.resultNeedsSettling(result)) continue;
            const result_position = self.mergePosition(if_op) orelse self.allocation_position;
            try self.appendParallelValueMoveAtPoints(
                &parallel,
                operand.value,
                regalloc.PositionPoint.source(self.allocation_position),
                result,
                regalloc.PositionPoint.definition(result_position),
            );
        }
        try self.emitParallelMoves(parallel.items);
    }

    pub fn takeLineTable(self: *Emitter) !debug_info.LineTable {
        return self.line_table.finish();
    }

    fn emitForGuard(self: *Emitter, iv: *ir.Value, upper: *ir.Value, entry_position: u32, exit_label: *Label) EmitError!void {
        const point = regalloc.PositionPoint.source(entry_position);
        const wide = (try self.slotFor(iv)).width != 32;
        const iv_place = try self.arrivalPlaceFor(iv, entry_position, .source);
        const upper_place = try self.placeForAtPoint(upper, point);
        if (self.value_location_index.valueRangeAtPoint(self.value_location_ranges.items, upper, point)) |range| {
            if (range.entry == .reload) try self.loadSlot(try self.slotFor(upper), range.reg);
        }
        switch (iv_place) {
            .reg => |iv_reg| switch (upper_place) {
                .reg => |upper_reg| {
                    try self.emitEncoding(if (wide) encoding.cmpRegReg(iv_reg, upper_reg) else encoding.cmpRegReg32(iv_reg, upper_reg));
                },
                .slot => |upper_slot| {
                    const mem = Mem.baseDisp(.rbp, upper_slot.offset);
                    try self.emitEncoding(if (wide) encoding.cmpRegMem(iv_reg, mem) else encoding.cmpRegMem32(iv_reg, mem));
                },
                .xmm => return error.UnsupportedType,
            },
            .slot => |iv_slot| switch (upper_place) {
                .reg => |upper_reg| {
                    const mem = Mem.baseDisp(.rbp, iv_slot.offset);
                    try self.emitEncoding(if (wide) encoding.cmpMemReg(mem, upper_reg) else encoding.cmpMemReg32(mem, upper_reg));
                },
                .slot => |upper_slot| {
                    const scratch = self.scratchAt(entry_position, &.{}) orelse return error.NoScratchRegister;
                    try self.loadSlot(iv_slot, scratch);
                    const mem = Mem.baseDisp(.rbp, upper_slot.offset);
                    try self.emitEncoding(if (wide) encoding.cmpRegMem(scratch, mem) else encoding.cmpRegMem32(scratch, mem));
                },
                .xmm => return error.UnsupportedType,
            },
            .xmm => return error.UnsupportedType,
        }
        try self.emitJccLabel(.ge, exit_label);
    }

    fn emitForYield(
        self: *Emitter,
        yield_op: *ir.Operation,
        body_block: *ir.Block,
        iv: *ir.Value,
        step: *ir.Value,
        entry_position: u32,
        header_label: *Label,
    ) EmitError!void {
        const iter_count = body_block.arguments.items.len - 1;
        var parallel: std.ArrayListUnmanaged(moves.Move) = .empty;
        defer parallel.deinit(self.allocator);
        for (0..iter_count) |i| {
            const iter_arg = body_block.arguments.items[1 + i];
            const yield_val = yield_op.operands.items[i].value;
            try self.appendCarriedValueMove(
                &parallel,
                yield_val,
                regalloc.PositionPoint.source(self.allocation_position),
                iter_arg,
                entry_position,
                .source,
            );
        }
        try self.emitParallelMoves(parallel.items);
        for (0..iter_count) |i| {
            const iter_arg = body_block.arguments.items[1 + i];
            try self.mirrorValueToSlotIfReloaded(iter_arg, try self.arrivalPlaceFor(iter_arg, entry_position, .source));
        }

        try self.emitForIvIncrement(iv, step, entry_position);
        try self.emitJmpLabel(header_label);
    }

    fn emitAddToPlace(self: *Emitter, target: moves.Place, step: moves.Place, wide: bool) EmitError!void {
        switch (target) {
            .reg => |iv_reg| switch (step) {
                .reg => |step_reg| {
                    try self.emitEncoding(if (wide) encoding.addRegReg(iv_reg, step_reg) else encoding.addRegReg32(iv_reg, step_reg));
                },
                .slot => |step_slot| {
                    const mem = Mem.baseDisp(.rbp, step_slot.offset);
                    try self.emitEncoding(if (wide) encoding.addRegMem(iv_reg, mem) else encoding.addRegMem32(iv_reg, mem));
                },
                .xmm => return error.UnsupportedType,
            },
            .slot => |iv_slot| switch (step) {
                .reg => |step_reg| {
                    const mem = Mem.baseDisp(.rbp, iv_slot.offset);
                    try self.emitEncoding(if (wide) encoding.addMemReg(mem, step_reg) else encoding.addMemReg32(mem, step_reg));
                },
                .slot => |step_slot| {
                    const scratch = self.scratchAt(self.allocation_position, &.{}) orelse return error.NoScratchRegister;
                    try self.loadSlot(step_slot, scratch);
                    const mem = Mem.baseDisp(.rbp, iv_slot.offset);
                    try self.emitEncoding(if (wide) encoding.addMemReg(mem, scratch) else encoding.addMemReg32(mem, scratch));
                },
                .xmm => return error.UnsupportedType,
            },
            .xmm => return error.UnsupportedType,
        }
    }

    fn emitForIvIncrement(self: *Emitter, iv: *ir.Value, step: *ir.Value, entry_position: u32) EmitError!void {
        const step_point = regalloc.PositionPoint.source(self.allocation_position);
        const current_point = regalloc.PositionPoint.source(self.allocation_position);
        const wide = (try self.slotFor(iv)).width != 32;
        const current_iv_place = try self.placeForAtPoint(iv, current_point);
        const step_place = try self.placeForAtPoint(step, step_point);
        try self.emitAddToPlace(current_iv_place, step_place, wide);
        const entry_iv_place = try self.arrivalPlaceFor(iv, entry_position, .source);
        try self.emitPlaceMove(current_iv_place, entry_iv_place);
        try self.mirrorValueToSlotIfReloaded(iv, entry_iv_place);
    }

    fn emitWhileYield(
        self: *Emitter,
        yield_op: *ir.Operation,
        before_block: *ir.Block,
        header_label: *Label,
    ) EmitError!void {
        const iter_count = before_block.arguments.items.len;
        if (yield_op.operands.items.len != iter_count) return error.InvalidWhileArity;

        var parallel: std.ArrayListUnmanaged(moves.Move) = .empty;
        defer parallel.deinit(self.allocator);
        for (0..iter_count) |i| {
            const iter_arg = before_block.arguments.items[i];
            const yield_val = yield_op.operands.items[i].value;
            try self.appendCarriedValueMove(
                &parallel,
                yield_val,
                regalloc.PositionPoint.source(self.allocation_position),
                iter_arg,
                self.allocation_position,
                .source,
            );
        }
        try self.emitParallelMoves(parallel.items);

        try self.emitJmpLabel(header_label);
    }

    pub fn emitJmpLabel(self: *Emitter, label: *Label) EmitError!void {
        const offset = self.code.items.len;
        if (label.offset) |target| {
            const disp = @as(i32, @intCast(target)) - @as(i32, @intCast(offset + 5));
            try self.emitEncoding(encoding.jmpRel32(disp));
        } else {
            try self.emitEncoding(encoding.jmpRel32(0));
            const disp_offset: u32 = @intCast(offset + 1);
            try label.fixups.append(self.allocator, disp_offset);
            self.unbound_fixups += 1;
        }
    }

    pub fn emitJccLabel(self: *Emitter, cond: Condition, label: *Label) EmitError!void {
        const offset = self.code.items.len;
        if (label.offset) |target| {
            const disp = @as(i32, @intCast(target)) - @as(i32, @intCast(offset + 6));
            try self.emitEncoding(encoding.jccRel32(cond, disp));
        } else {
            try self.emitEncoding(encoding.jccRel32(cond, 0));
            const disp_offset: u32 = @intCast(offset + 2);
            try label.fixups.append(self.allocator, disp_offset);
            self.unbound_fixups += 1;
        }
    }

    pub fn bindLabel(self: *Emitter, label: *Label) EmitError!void {
        const target: u32 = @intCast(self.code.items.len);
        label.offset = target;
        for (label.fixups.items) |fixup| {
            const disp = @as(i32, @intCast(target)) - @as(i32, @intCast(fixup + 4));
            std.mem.writeInt(i32, self.code.items[fixup..][0..4], disp, .little);
        }
        self.unbound_fixups -= @intCast(label.fixups.items.len);
        label.fixups.clearRetainingCapacity();
    }
};

/// The reload one slot must emit, spelled as the bytes rather than as an
/// answer a program gives.
///
/// THIS PINS THE SLOT SIGNEDNESS CONTRACT. A `u8` of 200 was stored by a `movzbq`
/// that read its byte as 200 and returned by a `movsbq` that read the same
/// byte as -56, because the slot carried no signedness and the reload
/// guessed. Only widths 8 and 16 branch, so the four rows below are the whole
/// surface.
///
/// THE SIGNED ROWS MATTER AS MUCH AS THE UNSIGNED ONES. They are what makes
/// this a rule about the value's own type rather than a flip of the default,
/// so a change that simply made every narrow reload unsigned fails here.
const narrow_reload_pins = [_]struct {
    width: u8,
    ext: IntExtension,
    want: encoding.Encoding,
}{
    .{ .width = 8, .ext = .unsigned, .want = encoding.movzxRegMem8(.rax, Mem.baseDisp(.rbp, -8)) },
    .{ .width = 8, .ext = .signed, .want = encoding.movsxRegMem8(.rax, Mem.baseDisp(.rbp, -8)) },
    .{ .width = 16, .ext = .unsigned, .want = encoding.movzxRegMem16(.rax, Mem.baseDisp(.rbp, -8)) },
    .{ .width = 16, .ext = .signed, .want = encoding.movsxRegMem16(.rax, Mem.baseDisp(.rbp, -8)) },
};

/// The form each type hands its slot.
///
/// `slotShapeFromName` used to tell `arith.i8` from `arith.u8` and answer the
/// same width for both, dropping the one fact a reload needs. Each pair here
/// shares a width and differs only in form, which is exactly the drop.
const slot_shape_pins = [_]struct { name: []const u8, width: u8, ext: IntExtension }{
    .{ .name = "arith.i8", .width = 8, .ext = .signed },
    .{ .name = "arith.u8", .width = 8, .ext = .unsigned },
    .{ .name = "arith.i16", .width = 16, .ext = .signed },
    .{ .name = "arith.u16", .width = 16, .ext = .unsigned },
    .{ .name = "arith.i32", .width = 32, .ext = .signed },
    .{ .name = "arith.u32", .width = 32, .ext = .unsigned },
    .{ .name = "arith.i64", .width = 64, .ext = .signed },
    .{ .name = "arith.u64", .width = 64, .ext = .unsigned },
};

/// Runs `parallel` on the machine. Every place in `places` starts with the word at its index in
/// `words` and leaves there whatever the moves wrote it. The words' address arrives in rdi, which
/// no place may be, and rax stages the slots before it is loaded itself.
fn runParallelMoves(
    emitter: *Emitter,
    parallel: []const moves.Move,
    places: []const moves.Place,
    words: []u64,
) !void {
    std.debug.assert(places.len == words.len);
    const frame_bytes = std.mem.alignForward(usize, emitter.slot_count * abi.stack_slot_size, 16);
    try emitter.emitEncoding(encoding.pushReg(.rbp));
    try emitter.emitEncoding(encoding.movRegReg(.rbp, .rsp));
    try emitter.emitEncoding(encoding.subRegImm(.rsp, @intCast(frame_bytes)));
    for (places, 0..) |place, i| switch (place) {
        .slot => |slot| {
            try emitter.emitEncoding(encoding.movRegMem(.rax, wordAt(i)));
            try emitter.storeSlot(slot, .rax);
        },
        .reg, .xmm => {},
    };
    for (places, 0..) |place, i| switch (place) {
        .reg => |reg| try emitter.emitEncoding(encoding.movRegMem(reg, wordAt(i))),
        .xmm => |reg| try emitter.emitEncoding(encoding.movsd(reg, .{ .mem = wordAt(i) })),
        .slot => {},
    };
    try emitter.emitParallelMoves(parallel);
    for (places, 0..) |place, i| switch (place) {
        .reg => |reg| try emitter.emitEncoding(encoding.movMemReg(wordAt(i), reg)),
        .xmm => |reg| try emitter.emitEncoding(encoding.movsdStore(wordAt(i), reg)),
        .slot => {},
    };
    for (places, 0..) |place, i| switch (place) {
        .slot => |slot| {
            try emitter.loadSlot(slot, .rax);
            try emitter.emitEncoding(encoding.movMemReg(wordAt(i), .rax));
        },
        .reg, .xmm => {},
    };
    try emitter.emitEncoding(encoding.movRegReg(.rsp, .rbp));
    try emitter.emitEncoding(encoding.popReg(.rbp));
    try emitter.emitEncoding(encoding.ret());

    const code = emitter.getCode();
    var mapping = try sys.memory.ExecutableMapping.init(code.len, test_publication_policy);
    defer mapping.deinit();
    try mapping.publish(code, &.{});
    const run: *const fn ([*]u64) callconv(.c) void = @ptrFromInt(try mapping.callableAddress());
    run(words.ptr);
}

fn wordAt(index: usize) Mem {
    return Mem.baseDisp(.rdi, @intCast(index * 8));
}

/// Moves that keep every scratch register's value where it is, so a resolution may write none of
/// them, as when values the parallel assignment does not move occupy all seven.
fn holdScratchRegisters(
    parallel: *std.ArrayListUnmanaged(moves.Move),
    places: *std.ArrayListUnmanaged(moves.Place),
) !void {
    for (moves.scratch_gprs) |reg| {
        const place: moves.Place = .{ .reg = reg };
        try parallel.append(std.testing.allocator, .{ .src = place, .dst = place });
        try places.append(std.testing.allocator, place);
    }
}

/// What the last call into a recording callee passed, one word per argument, a real as its bits.
var recorded_arguments: [17]u64 = @splat(0);

fn recordTenWords(
    a0: u64,
    a1: u64,
    a2: u64,
    a3: u64,
    a4: u64,
    a5: u64,
    a6: u64,
    a7: u64,
    a8: u64,
    a9: u64,
) callconv(.c) void {
    recorded_arguments[0..10].* = .{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9 };
}

fn recordSeventeenReals(
    a0: f64,
    a1: f64,
    a2: f64,
    a3: f64,
    a4: f64,
    a5: f64,
    a6: f64,
    a7: f64,
    a8: f64,
    a9: f64,
    a10: f64,
    a11: f64,
    a12: f64,
    a13: f64,
    a14: f64,
    a15: f64,
    a16: f64,
) callconv(.c) void {
    const reals = [_]f64{
        a0, a1,  a2,  a3,  a4,  a5,  a6,  a7,  a8,
        a9, a10, a11, a12, a13, a14, a15, a16,
    };
    for (reals, 0..) |real, i| recorded_arguments[i] = @bitCast(real);
}

/// Runs one call to `callee` that `call_plan.emitExtern` sets up from `args`. Each argument's
/// source starts with the word at its index in `words`. The words' address arrives in rdi, so
/// slots stage through rax before any register is loaded, and rdi is loaded last.
fn runCall(emitter: *Emitter, args: []const ExternArg, words: []const u64, callee: usize) !void {
    std.debug.assert(args.len == words.len);
    std.debug.assert(emitter.call_relocations.items.len == 0);
    const frame_bytes = std.mem.alignForward(usize, emitter.slot_count * abi.stack_slot_size, 16);
    try emitter.emitEncoding(encoding.pushReg(.rbp));
    try emitter.emitEncoding(encoding.movRegReg(.rbp, .rsp));
    try emitter.emitEncoding(encoding.subRegImm(.rsp, @intCast(frame_bytes)));
    for (args, 0..) |arg, i| switch (arg.source) {
        .slot => |slot| {
            try emitter.emitEncoding(encoding.movRegMem(.rax, wordAt(i)));
            try emitter.storeSlot(slot, .rax);
        },
        else => {},
    };
    for (args, 0..) |arg, i| switch (arg.source) {
        .gpr => |reg| if (reg != .rdi) try emitter.emitEncoding(encoding.movRegMem(reg, wordAt(i))),
        .xmm => |reg| try emitter.emitEncoding(encoding.movsd(reg, .{ .mem = wordAt(i) })),
        else => {},
    };
    for (args, 0..) |arg, i| switch (arg.source) {
        .gpr => |reg| if (reg == .rdi) {
            try emitter.emitEncoding(encoding.movRegMem(.rdi, wordAt(i)));
        },
        else => {},
    };
    try call_plan.emitExtern(emitter, "recorder", args, &.{});
    try emitter.emitEncoding(encoding.movRegReg(.rsp, .rbp));
    try emitter.emitEncoding(encoding.popReg(.rbp));
    try emitter.emitEncoding(encoding.ret());

    std.debug.assert(emitter.call_relocations.items.len == 1);
    const at = emitter.call_relocations.items[0].offset;
    std.mem.writeInt(u64, emitter.code.items[at..][0..8], callee, .little);
    const code = emitter.getCode();
    var mapping = try sys.memory.ExecutableMapping.init(code.len, test_publication_policy);
    defer mapping.deinit();
    try mapping.publish(code, &.{});
    const Run = *const fn ([*]const u64) callconv(.c) void;
    const run: Run = @ptrFromInt(try mapping.callableAddress());
    run(words.ptr);
}

/// The bytes a synthesized entry point costs, as an upper bound rather than an exact figure.
///
/// A program that yikes builds gets a four operation `_start`: call the entry, load the exit
/// number, enter the kernel, return. That function preserves nothing, spills nothing a caller
/// can see, and its whole job is twelve instructions of setup, so its text is the smallest
/// honest measure of what a call site costs. It stood at 140 bytes while every call site saved
/// eight caller saved registers whether or not one held anything.
///
/// This is a ceiling, not a golden. A change that emits fewer bytes should lower the number
/// here rather than be reported as a failure, and a change that raises it is asking a reader of
/// the footprint page to budget for bytes the program does not need.
const start_shape_ceiling_bytes = 64;

/// Builds `_start`'s shape with the call result either read by the exit syscall or ignored.
///
/// Both programs run the same call and the same syscall. The only difference is whether any
/// operation names the call's result, which is the one input the slot rule reads.
fn buildStartShape(ctx: *ir.Context, reads_call_result: bool) !FuncDialect.FuncOp {
    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);

    const func = try FuncDialect.FuncOp.create(ctx, loc, "_start", &.{}, &.{});
    const entry = func.getEntryBlock();
    const call = try FuncDialect.CallOp.create(ctx, loc, "main", &.{}, &.{i64_type});
    try entry.addOperation(call.op);
    const number = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 60);
    try entry.addOperation(number.op);
    const status = if (reads_call_result) call.getResult(0).? else number.getResult();
    const exit = try FuncDialect.SyscallOp.create(ctx, loc, number.getResult(), &.{status}, i64_type);
    try entry.addOperation(exit.op);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{});
    try entry.addOperation(ret.op);
    return func;
}

/// Builds a function that exits with a constant, optionally computing a second value first
/// that nothing reads. The dead value is an addition, so the shape covers a folded constant
/// and an arithmetic result that has to be computed before it can be thrown away.
fn buildDeadArithShape(ctx: *ir.Context, computes_dead_value: bool) !FuncDialect.FuncOp {
    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);

    const func = try FuncDialect.FuncOp.create(ctx, loc, "_start", &.{}, &.{});
    const entry = func.getEntryBlock();
    const status = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 0);
    try entry.addOperation(status.op);
    if (computes_dead_value) {
        const left = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 111);
        try entry.addOperation(left.op);
        const right = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 222);
        try entry.addOperation(right.op);
        const sum = try ArithDialect.AddOp.create(ctx, loc, left.getResult(), right.getResult());
        try entry.addOperation(sum.op);
    }
    const number = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 60);
    try entry.addOperation(number.op);
    const exit = try FuncDialect.SyscallOp.create(ctx, loc, number.getResult(), &.{status.getResult()}, i64_type);
    try entry.addOperation(exit.op);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{});
    try entry.addOperation(ret.op);
    return func;
}

/// Builds one function whose body is a single `scf.while` carrying `count`
/// values, and emits it. This is the shape `max_while_carried_values` bounds,
/// and the whole of what a test needs to ask which side of the figure a
/// program falls on.
fn emitWhileCarrying(allocator: std.mem.Allocator, count: usize) !void {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);

    const func = try FuncDialect.FuncOp.create(&ctx, loc, "carry", &.{i64_type}, &.{i64_type});
    const entry = func.getEntryBlock();

    var inits: std.ArrayListUnmanaged(*ir.Value) = .empty;
    defer inits.deinit(allocator);
    var result_types: std.ArrayListUnmanaged(ir.Type) = .empty;
    defer result_types.deinit(allocator);
    for (0..count) |_| {
        try inits.append(allocator, func.getArgument(0));
        try result_types.append(allocator, i64_type);
    }

    var while_op = try ScfDialect.WhileOp.create(&ctx, loc, inits.items, result_types.items);
    try entry.addOperation(while_op.op);

    const before = while_op.getBeforeBlock();
    const after = while_op.getAfterBlock();
    const condition = try ScfDialect.ConditionOp.create(
        &ctx,
        loc,
        before.arguments.items[0],
        before.arguments.items,
    );
    try before.addOperation(condition.op);
    const yield = try ScfDialect.YieldOp.create(&ctx, loc, after.arguments.items);
    try after.addOperation(yield.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{while_op.op.getResult(0).?});
    try entry.addOperation(ret.op);

    var emitter = Emitter.init(allocator);
    defer emitter.deinit();
    try emitter.emitFunction(func.op);
}
