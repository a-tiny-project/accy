const std = @import("std");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const call_plan = @import("calls.zig");
const data = @import("data.zig");
const encoding = @import("encoding.zig");
const registers = @import("registers/root.zig");
const simd = @import("vector.zig");
const slot_layout = @import("slots.zig");

const memref = dialects.memref;
const ArithDialect = dialects.arith.ArithDialect;
const MemrefDialect = dialects.memref.MemrefDialect;
const Mem = encoding.Mem;

/// The registers an element access may use as scratch. They are the ones
/// `regalloc.recordScalarScratchClobbers` declares clobbered at a `memref.load` and a
/// `memref.store`, so the allocator keeps nothing live across the access in them and choosing
/// among them can overwrite nothing it planned.
const load_scratch = [_]registers.GPR{ .rax, .rcx };
const store_scratch = [_]registers.GPR{ .rax, .rcx, .rdx };

/// A scratch register that is none of the registers this access already holds.
///
/// A register the allocator does not keep live across the access can still hold an operand OF the
/// access, because an interval ending at the access is allowed to sit in a register clobbered
/// there. So a fixed choice can destroy the very value it is about to read: an index rematerialised
/// into rax, then a base loaded into rax, addresses `base + base * 8`. The registers in hand are
/// passed in and the choice avoids every one of them.
fn scratchAvoiding(taken: []const ?registers.GPR, candidates: []const registers.GPR) !registers.GPR {
    candidate: for (candidates) |candidate| {
        for (taken) |maybe_reg| {
            if (maybe_reg) |reg| {
                if (reg == candidate) continue :candidate;
            }
        }
        return candidate;
    }
    return error.NoScratchRegister;
}

/// One element's address, with the registers it reads it from, so a caller placing a third value
/// (the stored one) can avoid them too.
const ElementAddress = struct {
    mem: Mem,
    base: registers.GPR,
    index: registers.GPR,
};

/// `reserved` names registers holding values this access still needs and that it does not address
/// through, which is the stored value of a `memref.store`. They are avoided for the same reason the
/// index and the base avoid each other.
fn elementAddress(
    self: anytype,
    memref_val: *ir.Value,
    index_val: *ir.Value,
    scale: encoding.Scale,
    candidates: []const registers.GPR,
    reserved: ?registers.GPR,
) !ElementAddress {
    const index_home = self.registerHome(index_val);
    const base_reg = self.registerHome(memref_val) orelse base: {
        const scratch = try scratchAvoiding(&.{ index_home, reserved }, candidates);
        try self.loadSlot(try self.slotFor(memref_val), scratch);
        break :base scratch;
    };
    const index_reg = index_home orelse index: {
        const scratch = try scratchAvoiding(&.{ base_reg, reserved }, candidates);
        try self.loadSlot(try self.slotFor(index_val), scratch);
        break :index scratch;
    };
    return .{
        .mem = Mem.baseIndex(base_reg, index_reg, scale, 0),
        .base = base_reg,
        .index = index_reg,
    };
}

pub fn emitLoad(self: anytype, op: *ir.Operation) !void {
    const load_op = MemrefDialect.LoadOp{ .op = op };
    const result = load_op.getResult();
    const memref_val = load_op.getMemref();
    const index_val = load_op.getIndex();

    const layout = try parseParams(self, memref_val.type);
    try requireHost(self, layout);
    const elem_size = try elementByteSize(self, layout.element_type_name);
    const scale = try scaleForSize(elem_size);

    const address = try elementAddress(self, memref_val, index_val, scale, &load_scratch, null);
    const mem = address.mem;
    if (try vectorSlotForOptional(self, result)) |result_vector| {
        const kind = try packedMemrefKind(layout, result_vector);
        if (self.xmmHomeForPhase(result, .definition)) |home| {
            try simd.emitPackedLoadFromMem(self, kind, mem, home);
        } else {
            try simd.emitPackedLoadFromMem(self, kind, mem, .xmm0);
            try simd.emitPackedStore(self, result_vector, .xmm0);
        }
        return;
    }

    const result_slot = try self.slotFor(result);
    const result_home = self.registerHomeForPhase(result, .definition);
    const dest = result_home orelse registers.GPR.rax;
    if (elem_size == 1) {
        if (!std.mem.eql(u8, layout.element_type_name, "arith.i8") and
            !std.mem.eql(u8, layout.element_type_name, "arith.u8") and
            !std.mem.eql(u8, layout.element_type_name, "arith.bool")) return error.UnsupportedType;
        try self.emitEncoding(encoding.movzxRegMem8(dest, mem));
        if (result_home == null) try self.storeSlot(result_slot, dest);
    } else if (elem_size == 2) {
        if (!std.mem.eql(u8, layout.element_type_name, "arith.i16") and
            !std.mem.eql(u8, layout.element_type_name, "arith.u16")) return error.UnsupportedType;
        try self.emitEncoding(encoding.movzxRegMem16(dest, mem));
        if (result_home == null) try self.storeSlot(result_slot, dest);
    } else if (elem_size == 4) {
        if (result_slot.width == 32 and std.mem.eql(u8, layout.element_type_name, "arith.f32")) {
            if (self.xmmHomeForPhase(result, .definition)) |home| {
                try self.emitEncoding(encoding.movss(home, .{ .mem = mem }));
            } else {
                try self.emitEncoding(encoding.movss(.xmm0, .{ .mem = mem }));
                try self.storeSlotXmm(result_slot, .xmm0);
            }
        } else {
            try self.emitEncoding(encoding.movRegMem32(dest, mem));
            if (result_home == null) try self.storeSlot(result_slot, dest);
        }
    } else if (elem_size == 8) {
        if (result_slot.width == 64 and std.mem.eql(u8, layout.element_type_name, "arith.f64")) {
            if (self.xmmHomeForPhase(result, .definition)) |home| {
                try self.emitEncoding(encoding.movsd(home, .{ .mem = mem }));
            } else {
                try self.emitEncoding(encoding.movsd(.xmm0, .{ .mem = mem }));
                try self.storeSlotXmm(result_slot, .xmm0);
            }
        } else {
            try self.emitEncoding(encoding.movRegMem(dest, mem));
            if (result_home == null) try self.storeSlot(result_slot, dest);
        }
    } else {
        return error.UnsupportedType;
    }
}

pub fn emitStore(self: anytype, op: *ir.Operation) !void {
    const store_op = MemrefDialect.StoreOp{ .op = op };
    const value = store_op.getValue();
    const memref_val = store_op.getMemref();
    const index_val = store_op.getIndex();

    const layout = try parseParams(self, memref_val.type);
    try requireHost(self, layout);
    const elem_size = try elementByteSize(self, layout.element_type_name);
    const scale = try scaleForSize(elem_size);

    const value_home = self.registerHome(value);
    const address = try elementAddress(self, memref_val, index_val, scale, &store_scratch, value_home);
    const mem = address.mem;
    const value_scratch = try scratchAvoiding(&.{ address.base, address.index }, &store_scratch);
    if (try vectorSlotForOptional(self, value)) |value_vector| {
        const kind = try packedMemrefKind(layout, value_vector);
        if (self.xmmHome(value)) |home| {
            try simd.emitPackedStoreToMem(self, kind, mem, home);
        } else {
            try simd.emitPackedLoad(self, value_vector, .xmm0);
            try simd.emitPackedStoreToMem(self, kind, mem, .xmm0);
        }
        return;
    }

    const value_slot = try self.slotFor(value);
    if (elem_size == 1) {
        if (!std.mem.eql(u8, layout.element_type_name, "arith.i8") and
            !std.mem.eql(u8, layout.element_type_name, "arith.u8") and
            !std.mem.eql(u8, layout.element_type_name, "arith.bool")) return error.UnsupportedType;
        try self.loadInto(value, value_scratch);
        try self.emitEncoding(encoding.movMemReg8(mem, value_scratch));
    } else if (elem_size == 2) {
        if (!std.mem.eql(u8, layout.element_type_name, "arith.i16") and
            !std.mem.eql(u8, layout.element_type_name, "arith.u16")) return error.UnsupportedType;
        try self.loadInto(value, value_scratch);
        try self.emitEncoding(encoding.movMemReg16(mem, value_scratch));
    } else if (elem_size == 4) {
        if (value_slot.width == 32 and std.mem.eql(u8, layout.element_type_name, "arith.f32")) {
            if (self.xmmHome(value)) |home| {
                try self.emitEncoding(encoding.movssStore(mem, home));
            } else {
                try self.loadSlotXmm(value_slot, .xmm0);
                try self.emitEncoding(encoding.movssStore(mem, .xmm0));
            }
        } else {
            const value_reg = self.registerHome(value) orelse reg: {
                try self.loadSlot(value_slot, value_scratch);
                break :reg value_scratch;
            };
            try self.emitEncoding(encoding.movMemReg32(mem, value_reg));
        }
    } else if (elem_size == 8) {
        if (value_slot.width == 64 and std.mem.eql(u8, layout.element_type_name, "arith.f64")) {
            if (self.xmmHome(value)) |home| {
                try self.emitEncoding(encoding.movsdStore(mem, home));
            } else {
                try self.loadSlotXmm(value_slot, .xmm0);
                try self.emitEncoding(encoding.movsdStore(mem, .xmm0));
            }
        } else {
            const value_reg = self.registerHome(value) orelse reg: {
                try self.loadSlot(value_slot, value_scratch);
                break :reg value_scratch;
            };
            try self.emitEncoding(encoding.movMemReg(mem, value_reg));
        }
    } else {
        return error.UnsupportedType;
    }
}

pub fn emitAlloc(self: anytype, op: *ir.Operation) !void {
    const alloc_op = MemrefDialect.AllocOp{ .op = op };
    const result = alloc_op.getResult();
    const layout = try parseParams(self, result.type);
    try requireHost(self, layout);
    const elem_size = try elementByteSize(self, layout.element_type_name);

    const result_slot = try self.slotFor(result);
    const args = [_]call_plan.ExternArg{
        .{ .type_name = "arith.index", .source = .{ .gpr = .rdi } },
    };

    if (alloc_op.getDynamicSize()) |dyn_size| {
        const size_slot = try self.slotFor(dyn_size);
        try self.loadSlot(size_slot, .rax);
        if (elem_size != 1) {
            try self.emitEncoding(encoding.movRegImm64(.rcx, elem_size));
            try self.emitEncoding(encoding.imulRegReg(.rax, .rcx));
        }
        try self.emitEncoding(encoding.movRegReg(.rdi, .rax));
    } else {
        const bytes = try staticByteSize(self, layout);
        try self.emitEncoding(encoding.movRegImm64(.rdi, bytes));
    }

    const allocation = [_]call_plan.ExternResult{
        .{ .type_name = MemrefDialect.name, .slot = result_slot },
    };
    try call_plan.emitExtern(self, "malloc", &args, &allocation);
    try self.allocation_kinds.put(self.allocator, result, .heap);
}

/// Materializes the address of a global as a memref value.
///
/// The address is a 64-bit immediate a relocation fills, which is the mechanism the read only
/// data path already uses. Registering the symbol here is what puts a global the code actually
/// reaches into the image, so a JIT compiling one function needs no module walk.
pub fn emitGetGlobal(self: anytype, op: *ir.Operation) !void {
    const get_op = MemrefDialect.GetGlobalOp{ .op = op };
    const name = get_op.getSymName() orelse return error.InvalidDataSymbol;
    const global = memref.findGlobal(op, name) orelse return error.InvalidDataSymbol;
    const symbol = try data.symbolOfGlobal(global);
    try data.emitAddress(self, get_op.getResult(), symbol);
}

/// Adds an unscaled byte offset to a byte addressed base.
///
/// One `add`, because the offset is already in bytes. The x86 addressing mode cannot help here:
/// its scale field only multiplies by 1, 2, 4 or 8 and `elementAddress` fixes the displacement
/// at zero, so the sum is formed in a register and the result is an ordinary memref value.
pub fn emitView(self: anytype, op: *ir.Operation) !void {
    const view_op = MemrefDialect.ViewOp{ .op = op };
    const base = view_op.getBase();
    try requireHost(self, try parseParams(self, base.type));
    try requireHost(self, try parseParams(self, view_op.getResult().type));
    try self.loadInto(base, .rax);
    try self.loadInto(view_op.getByteOffset(), .rcx);
    try self.emitEncoding(encoding.addRegReg(.rax, .rcx));
    try self.storeFrom(view_op.getResult(), .rax);
}

pub fn emitAlloca(self: anytype, op: *ir.Operation) !void {
    const alloca_op = MemrefDialect.AllocaOp{ .op = op };
    const result = alloca_op.getResult();
    const result_slot = try self.slotFor(result);
    const payload_slot = self.alloca_payload_slots.get(result) orelse return error.MissingSlot;

    try self.emitEncoding(encoding.movRegReg(.rax, .rbp));
    if (payload_slot.offset != 0) {
        try self.emitEncoding(encoding.addRegImm(.rax, payload_slot.offset));
    }
    try self.storeSlot(result_slot, .rax);
    try self.allocation_kinds.put(self.allocator, result, .stack_emulated);
}

pub fn emitDealloc(self: anytype, op: *ir.Operation) !void {
    const dealloc_op = MemrefDialect.DeallocOp{ .op = op };
    const memref_val = dealloc_op.getMemref();
    const allocation_kind = self.allocation_kinds.get(memref_val) orelse return error.UnsupportedDeallocTarget;
    if (allocation_kind == .stack_emulated) return;

    const memref_slot = try self.slotFor(memref_val);
    try self.loadSlot(memref_slot, .rdi);
    const args = [_]call_plan.ExternArg{
        .{ .type_name = MemrefDialect.name, .source = .{ .gpr = .rdi } },
    };
    try call_plan.emitExtern(self, "free", &args, &.{});
}

/// Atomic accesses address memory through fixed scratch registers: the base in rcx, the index in
/// rdx, and the operand in r8, leaving rax free for the value `cmpxchg` compares and answers.
const atomic_base = registers.GPR.rcx;
const atomic_index = registers.GPR.rdx;
const atomic_operand = registers.GPR.r8;

/// The two widths one x86 instruction reads or writes atomically when aligned.
const AtomicWidth = enum { word, half };

fn atomicWidth(self: anytype, layout: MemrefDialect.MemrefParams) !AtomicWidth {
    try requireHost(self, layout);
    const name = layout.element_type_name;
    if (std.mem.eql(u8, name, "arith.i64") or
        std.mem.eql(u8, name, "arith.u64") or
        std.mem.eql(u8, name, "arith.index")) return .word;
    if (std.mem.eql(u8, name, "arith.i32") or
        std.mem.eql(u8, name, "arith.u32")) return .half;
    return error.UnsupportedType;
}

/// A function holding an ordered access runs every value from its frame slot, so the fixed scratch
/// registers above clobber nothing live. `regalloc.holdsOrderedEffect` is what keeps that true: it
/// refuses such a function by its effect record rather than by the absence of a mnemonic from a
/// list, so an ordered operation added later inherits the refusal.
///
/// This is the check that the premise still holds when an atomic is emitted. It REFUSES rather than
/// asserts, because an assertion is nothing in ReleaseFast and what follows a violation there is a
/// scratch register written over a live value, which is a wrong answer and not a crash.
fn requireFrameSlotsOnly(self: anytype) !void {
    if (self.value_locations.count() != 0 or
        self.value_location_ranges.items.len != 0 or
        self.xmm_locations.count() != 0 or
        self.xmm_location_ranges.items.len != 0)
    {
        return error.OrderedAccessWithAllocatedValues;
    }
}

fn atomicAddress(self: anytype, memref_val: *ir.Value, index_val: *ir.Value, width: AtomicWidth) !Mem {
    try requireFrameSlotsOnly(self);
    try self.loadSlot(try self.slotFor(memref_val), atomic_base);
    try self.loadSlot(try self.slotFor(index_val), atomic_index);
    const scale: encoding.Scale = switch (width) {
        .word => .eight,
        .half => .four,
    };
    return Mem.baseIndex(atomic_base, atomic_index, scale, 0);
}

/// An aligned `mov` is already an acquire load under x86 TSO, and a sequentially consistent load
/// needs nothing more because every sequentially consistent store is an `xchg`.
pub fn emitAtomicLoad(self: anytype, op: *ir.Operation) !void {
    const load_op = MemrefDialect.AtomicLoadOp{ .op = op };
    _ = load_op.getOrdering() orelse return error.MissingOrdering;
    const layout = try parseParams(self, load_op.getMemref().type);
    const width = try atomicWidth(self, layout);
    const mem = try atomicAddress(self, load_op.getMemref(), load_op.getIndex(), width);
    switch (width) {
        .word => try self.emitEncoding(encoding.movRegMem(.rax, mem)),
        .half => try self.emitEncoding(encoding.movRegMem32(.rax, mem)),
    }
    try self.storeSlot(try self.slotFor(load_op.getResult()), .rax);
}

/// A release store is a plain `mov` under x86 TSO. A sequentially consistent store is an `xchg`,
/// whose implicit lock orders it before every later load.
pub fn emitAtomicStore(self: anytype, op: *ir.Operation) !void {
    const store_op = MemrefDialect.AtomicStoreOp{ .op = op };
    const ordering = store_op.getOrdering() orelse return error.MissingOrdering;
    const layout = try parseParams(self, store_op.getMemref().type);
    const width = try atomicWidth(self, layout);
    const mem = try atomicAddress(self, store_op.getMemref(), store_op.getIndex(), width);
    try self.loadSlot(try self.slotFor(store_op.getValue()), atomic_operand);
    const sequential = ordering == .seq_cst;
    switch (width) {
        .word => try self.emitEncoding(if (sequential)
            encoding.xchgMemReg(mem, atomic_operand)
        else
            encoding.movMemReg(mem, atomic_operand)),
        .half => try self.emitEncoding(if (sequential)
            encoding.xchgMemReg32(mem, atomic_operand)
        else
            encoding.movMemReg32(mem, atomic_operand)),
    }
}

/// Every ordering lowers to `lock cmpxchg`, which is a full barrier on x86. The instruction
/// leaves the observed word in rax whether or not the exchange happened, and that word is the
/// result: the exchange succeeded exactly when it equals the expected value.
pub fn emitAtomicCas(self: anytype, op: *ir.Operation) !void {
    const cas_op = MemrefDialect.AtomicCasOp{ .op = op };
    const layout = try parseParams(self, cas_op.getMemref().type);
    const width = try atomicWidth(self, layout);
    const mem = try atomicAddress(self, cas_op.getMemref(), cas_op.getIndex(), width);
    try self.loadSlot(try self.slotFor(cas_op.getExpected()), .rax);
    try self.loadSlot(try self.slotFor(cas_op.getDesired()), atomic_operand);
    switch (width) {
        .word => try self.emitEncoding(encoding.lockCmpxchgMemReg(mem, atomic_operand)),
        .half => try self.emitEncoding(encoding.lockCmpxchgMemReg32(mem, atomic_operand)),
    }
    try self.storeSlot(try self.slotFor(cas_op.getResult()), .rax);
}

/// Only a sequentially consistent fence emits code on x86, an `mfence` that keeps earlier stores
/// ahead of later loads. TSO already gives acquire, release, and acquire-release fences. Every
/// scope is treated as the whole system, the strongest reading of each.
pub fn emitFence(self: anytype, op: *ir.Operation) !void {
    const fence_op = MemrefDialect.FenceOp{ .op = op };
    _ = fence_op.getScope() orelse return error.MissingOrdering;
    const ordering = fence_op.getOrdering() orelse return error.MissingOrdering;
    if (ordering == .seq_cst) try self.emitEncoding(encoding.mfence());
}

fn parseParams(self: anytype, memref_type: ir.Type) !MemrefDialect.MemrefParams {
    _ = self;
    const param_key = memref_type.getDialectParamKey() orelse return error.MemrefTypeMissingParams;
    return MemrefDialect.parseMemrefParams(param_key) orelse return error.InvalidMemrefType;
}

fn elementByteSize(self: anytype, element_type_name: []const u8) !u64 {
    _ = self;
    if (std.mem.eql(u8, element_type_name, "arith.i32") or
        std.mem.eql(u8, element_type_name, "arith.u32") or
        std.mem.eql(u8, element_type_name, "arith.f32")) return 4;
    if (std.mem.eql(u8, element_type_name, "arith.i64") or
        std.mem.eql(u8, element_type_name, "arith.u64") or
        std.mem.eql(u8, element_type_name, "arith.f64") or
        std.mem.eql(u8, element_type_name, "arith.index"))
    {
        return 8;
    }
    if (std.mem.eql(u8, element_type_name, "arith.i8") or
        std.mem.eql(u8, element_type_name, "arith.u8") or
        std.mem.eql(u8, element_type_name, "arith.bool")) return 1;
    if (std.mem.eql(u8, element_type_name, "arith.i16") or
        std.mem.eql(u8, element_type_name, "arith.u16") or
        std.mem.eql(u8, element_type_name, "arith.f16") or
        std.mem.eql(u8, element_type_name, "arith.bf16")) return 2;
    return error.UnsupportedType;
}

fn staticByteSize(self: anytype, layout: MemrefDialect.MemrefParams) !u64 {
    const size = layout.size orelse return error.DynamicMemref;
    const elem_bytes = try elementByteSize(self, layout.element_type_name);
    return size * elem_bytes;
}

pub fn allocaByteSize(self: anytype, alloca_op: MemrefDialect.AllocaOp) !u64 {
    const result = alloca_op.getResult();
    const layout = try parseParams(self, result.type);
    try requireHost(self, layout);
    if (layout.size) |_| return staticByteSize(self, layout);

    const dyn_size = alloca_op.getDynamicSize() orelse return error.DynamicMemref;
    const count = try constantIndexValue(self, dyn_size);
    const elem_bytes = try elementByteSize(self, layout.element_type_name);
    if (count > std.math.maxInt(u64) / elem_bytes) return error.DynamicMemref;
    return count * elem_bytes;
}

pub fn allocaAlignment(self: anytype, alloca_op: MemrefDialect.AllocaOp) !u64 {
    const result = alloca_op.getResult();
    const layout = try parseParams(self, result.type);
    try requireHost(self, layout);
    const alignment = layout.alignment orelse abiDefaultAlignment(try elementByteSize(self, layout.element_type_name));
    if (alignment == 0) return error.InvalidMemrefType;
    return alignment;
}

fn abiDefaultAlignment(size: u64) u64 {
    if (size <= 1) return 1;
    if (size <= 2) return 2;
    if (size <= 4) return 4;
    return 8;
}

fn constantIndexValue(self: anytype, value: *ir.Value) !u64 {
    _ = self;
    const defining_op_opaque = value.getDefiningOp() orelse return error.DynamicMemref;
    const defining_op: *ir.Operation = @ptrCast(@alignCast(defining_op_opaque));
    if (!std.mem.eql(u8, defining_op.name.name, ArithDialect.ConstantOp.operation_name)) {
        return error.DynamicMemref;
    }
    if (data.hasAttributes(defining_op)) return error.DynamicMemref;
    const int_value = (ArithDialect.ConstantOp{ .op = defining_op }).getIntValue() orelse return error.InvalidConstant;
    if (int_value < 0) return error.DynamicMemref;
    return @intCast(int_value);
}

fn requireHost(self: anytype, layout: MemrefDialect.MemrefParams) !void {
    _ = self;
    if (layout.addr_space != .host) return error.UnsupportedMemrefAddressSpace;
}

fn scaleForSize(size: u64) !encoding.Scale {
    return switch (size) {
        1 => .one,
        2 => .two,
        4 => .four,
        8 => .eight,
        else => error.UnsupportedType,
    };
}

fn vectorSlotForOptional(self: anytype, value: *ir.Value) !?slot_layout.VectorSlot {
    return self.vectorSlotFor(value) catch |err| switch (err) {
        error.MissingSlot => null,
        else => return err,
    };
}

fn packedMemrefKind(layout: MemrefDialect.MemrefParams, vector_slot: slot_layout.VectorSlot) !simd.PackedKind {
    if (!std.mem.eql(u8, layout.element_type_name, vector_slot.elem_type_name)) return error.UnsupportedType;
    return simd.packedKind(vector_slot) orelse error.UnsupportedType;
}

test "x86_64 memory owner classifies element sizes and scales" {
    try std.testing.expectEqual(@as(u64, 4), try elementByteSize({}, "arith.f32"));
    try std.testing.expectEqual(@as(u64, 8), try elementByteSize({}, "arith.index"));
    try std.testing.expectEqual(encoding.Scale.four, try scaleForSize(4));
    try std.testing.expectError(error.UnsupportedType, scaleForSize(3));
}

test "an ordered access refuses a function whose values are register homed" {
    const Homes = struct {
        count_value: usize,

        fn count(self: @This()) usize {
            return self.count_value;
        }
    };
    const Ranges = struct { items: []const u8 };
    const Emitter = struct {
        value_locations: Homes,
        value_location_ranges: Ranges,
        xmm_locations: Homes,
        xmm_location_ranges: Ranges,
    };

    const frame_slots_only = Emitter{
        .value_locations = .{ .count_value = 0 },
        .value_location_ranges = .{ .items = &.{} },
        .xmm_locations = .{ .count_value = 0 },
        .xmm_location_ranges = .{ .items = &.{} },
    };
    try requireFrameSlotsOnly(frame_slots_only);

    var one_value_homed = frame_slots_only;
    one_value_homed.value_locations.count_value = 1;
    try std.testing.expectError(
        error.OrderedAccessWithAllocatedValues,
        requireFrameSlotsOnly(one_value_homed),
    );

    var one_range_planned = frame_slots_only;
    one_range_planned.value_location_ranges.items = &.{0};
    try std.testing.expectError(
        error.OrderedAccessWithAllocatedValues,
        requireFrameSlotsOnly(one_range_planned),
    );

    var one_float_homed = frame_slots_only;
    one_float_homed.xmm_locations.count_value = 1;
    try std.testing.expectError(
        error.OrderedAccessWithAllocatedValues,
        requireFrameSlotsOnly(one_float_homed),
    );

    var one_float_range = frame_slots_only;
    one_float_range.xmm_location_ranges.items = &.{0};
    try std.testing.expectError(
        error.OrderedAccessWithAllocatedValues,
        requireFrameSlotsOnly(one_float_range),
    );
}
