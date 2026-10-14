const std = @import("std");
const abi = @import("abi.zig");
const encoding = @import("encoding.zig");
const moves = @import("moves.zig");
const registers = @import("registers/root.zig");
const slot_layout = @import("slots.zig");

const GPR = registers.GPR;
const XMM = registers.XMM;
const Mem = encoding.Mem;

/// One call site whose target address the linker writes. The same record every writer of
/// machine code uses, so an emitted function's calls reach a runtime or an object file unchanged.
pub const CallRelocation = @import("../machine.zig").CallRelocation;

pub const ArgSource = union(enum) {
    slot: slot_layout.Slot,
    addr_of_slot: slot_layout.Slot,
    gpr: GPR,
    xmm: XMM,
    imm: u64,
};

pub const ExternArg = struct {
    type_name: []const u8,
    source: ArgSource,
};

pub const ExternResult = struct {
    type_name: []const u8,
    /// Where the call site settles this result, or null to leave it in its return register.
    ///
    /// Null says one of two things, and the call site knows which: nothing reads the result, so
    /// it was given no frame slot at all, or the caller settles it itself into a register home
    /// right after the call. Either way the result is still normalized in its return register
    /// first, because a SysV callee defines only the low byte of a boolean.
    slot: ?slot_layout.Slot,
};

const GeneratedIntArg = struct {
    dst: GPR,
    type_name: []const u8,
    source: ArgSource,
};

/// The registers a `call` destroys, which SysV names caller saved.
///
/// This is a statement about the callee, not an instruction to the call site. Nothing here saves
/// them, because nothing live is ever in them: the register allocator records each one as
/// clobbered at a call (`regalloc.recordCallClobbers`), so a value whose live range crosses a
/// call is given a callee saved home or a frame slot instead. Saving them at the call site as
/// well cost sixteen moves and sixty four bytes of stack per call to preserve values that the
/// allocator had already guaranteed were not there.
///
/// The one consumer that must read this is the allocator's clobber model. If that model is ever
/// weakened, this list stops being a description and a call site has to save again, which is
/// what the fixture in `execution.zig` over values live across a call is there to catch.
pub const call_clobbered_gprs = [_]GPR{
    .rcx,
    .rdx,
    .rsi,
    .rdi,
    .r8,
    .r9,
    .r10,
    .r11,
};

/// Every general register a call destroys: its return register and `call_clobbered_gprs`. The
/// allocator clobbers each of these at every call, and a call's setup writes no other.
///
/// ONE OF THESE THAT NO ARGUMENT READS HOLDS NOTHING LIVE AT A CALL'S SETUP. No value used after
/// the call can be in one, because the allocator clobbers it there, and a value in one that dies
/// at the call is an argument the call reads. Both halves rest on this one list.
pub const destroyed_gprs = [_]GPR{abi.int_return_reg} ++ call_clobbered_gprs;

/// The stack one call needs beyond the caller's own frame, which is its stack arguments and
/// whatever padding realigns the stack pointer for the call.
pub const Frame = struct {
    /// What the arguments themselves need.
    stack_arg_bytes: u32,
    /// What the stack pointer moves by, which is the arguments plus realignment.
    total_bytes: u32,
};

pub fn computeFrame(frame_layout: abi.FrameLayout, stack_arg_bytes: u32) Frame {
    std.debug.assert(stack_arg_bytes <= abi.max_argument_words * abi.stack_slot_size);
    const no_save_area = 0;
    const pad_bytes = abi.computeCallStackPadding(stack_arg_bytes, no_save_area, frame_layout.call_aligned);
    const frame: Frame = .{
        .stack_arg_bytes = stack_arg_bytes,
        .total_bytes = stack_arg_bytes + pad_bytes,
    };
    std.debug.assert(frame.total_bytes <= abi.max_argument_stack_bytes);
    return frame;
}

fn emitFramePrologue(emitter: anytype, frame: Frame) !void {
    if (frame.total_bytes == 0) return;
    try emitter.emitEncoding(encoding.subRegImm(.rsp, @intCast(frame.total_bytes)));
}

fn emitFrameEpilogue(emitter: anytype, frame: Frame) !void {
    if (frame.total_bytes == 0) return;
    try emitter.emitEncoding(encoding.addRegImm(.rsp, @intCast(frame.total_bytes)));
}

fn argUsesGpr(args: []const ExternArg, reg: GPR) bool {
    for (args) |arg| {
        switch (arg.source) {
            .gpr => |src| if (src == reg) return true,
            else => {},
        }
    }
    return false;
}

/// Where a call's setup stages a stack argument that is not already in a register.
const StackScratch = union(enum) {
    /// A destroyed register that no argument reads.
    free: GPR,
    /// Every destroyed register holds an argument, so the setup borrows `moves.stack_scratch_gpr`,
    /// keeping its argument in this frame slot around each copy.
    borrowed: slot_layout.Slot,
};

/// Every destroyed register can hold an argument only in a function the allocator placed, and
/// placing one reserves `save`.
fn stackScratch(
    args: []const ExternArg,
    save: ?slot_layout.Slot,
) error{NoScratchRegister}!StackScratch {
    for (destroyed_gprs) |reg| {
        if (!argUsesGpr(args, reg)) return .{ .free = reg };
    }
    return .{ .borrowed = save orelse return error.NoScratchRegister };
}

/// Writes one stack argument at `mem`. A register stores itself, and anything else passes through
/// `scratch`, a real as its raw bits, so the setup writes no XMM register an argument may hold.
fn storeStackArg(emitter: anytype, arg: ExternArg, mem: Mem, scratch: StackScratch) !void {
    const info = try emitter.typeInfoFromName(arg.type_name);
    if (info.is_float and info.width != 32 and info.width != 64) return error.UnsupportedType;
    switch (arg.source) {
        .xmm => |src| {
            if (!info.is_float) return error.UnsupportedType;
            try emitter.emitEncoding(switch (info.width) {
                32 => encoding.movssStore(mem, src),
                else => encoding.movsdStore(mem, src),
            });
            return;
        },
        .gpr => |src| {
            if (info.is_float) return error.UnsupportedType;
            return storeWord(emitter, mem, src, info.width);
        },
        .slot => {},
        .imm, .addr_of_slot => if (info.is_float) return error.UnsupportedType,
    }
    const reg = switch (scratch) {
        .free => |reg| reg,
        .borrowed => |save| reg: {
            try emitter.storeSlot(save, moves.stack_scratch_gpr);
            break :reg moves.stack_scratch_gpr;
        },
    };
    switch (arg.source) {
        .slot => |slot| try emitter.loadSlot(slot, reg),
        .imm, .addr_of_slot => try emitGeneratedIntArg(emitter, .{
            .dst = reg,
            .type_name = arg.type_name,
            .source = arg.source,
        }),
        .gpr, .xmm => unreachable,
    }
    try storeWord(emitter, mem, reg, info.width);
    switch (scratch) {
        .free => {},
        .borrowed => |save| try emitter.loadSlot(save, moves.stack_scratch_gpr),
    }
}

fn storeWord(emitter: anytype, mem: Mem, reg: GPR, width: u8) !void {
    try emitter.emitEncoding(switch (width) {
        8 => encoding.movMemReg8(mem, reg),
        16 => encoding.movMemReg16(mem, reg),
        32 => encoding.movMemReg32(mem, reg),
        64 => encoding.movMemReg(mem, reg),
        else => return error.UnsupportedType,
    });
}

fn emitGeneratedIntArg(emitter: anytype, arg: GeneratedIntArg) !void {
    const info = try emitter.typeInfoFromName(arg.type_name);
    switch (arg.source) {
        .addr_of_slot => |slot| {
            if (info.width != 64) return error.UnsupportedType;
            try emitter.emitEncoding(encoding.movRegReg(arg.dst, .rbp));
            if (slot.offset != 0) {
                try emitter.emitEncoding(encoding.addRegImm(arg.dst, slot.offset));
            }
        },
        .imm => |imm| {
            if (info.width == 8) {
                if (imm > std.math.maxInt(u8)) return error.InvalidConstant;
                try emitter.emitEncoding(encoding.movRegImm32(arg.dst, @intCast(imm)));
            } else if (info.width == 16) {
                if (imm > std.math.maxInt(u16)) return error.InvalidConstant;
                try emitter.emitEncoding(encoding.movRegImm32(arg.dst, @intCast(imm)));
            } else if (info.width == 32) {
                if (imm > std.math.maxInt(u32)) return error.InvalidConstant;
                try emitter.emitEncoding(encoding.movRegImm32(arg.dst, @intCast(imm)));
            } else if (info.width == 64) {
                try emitter.emitEncoding(encoding.movRegImm64(arg.dst, imm));
            } else {
                return error.UnsupportedType;
            }
        },
        else => return error.UnsupportedType,
    }
}

/// Emits one call and leaves every result in its slot before volatile registers are restored.
/// A result record, when present, is the first argument and addresses the first result slot.
pub fn emitExtern(
    emitter: anytype,
    callee: []const u8,
    args: []const ExternArg,
    results: []const ExternResult,
) !void {
    std.debug.assert(results.len <= abi.max_result_count);
    // Every entry refuses a call past `abi.max_call_arguments` before it reaches here.
    std.debug.assert(args.len <= abi.max_argument_words);
    const arg_count = args.len;
    const arg_type_names = try emitter.allocator.alloc([]const u8, arg_count);
    defer emitter.allocator.free(arg_type_names);

    for (args, 0..) |arg, i| {
        arg_type_names[i] = arg.type_name;
    }

    const locations = try emitter.allocator.alloc(abi.ValueLocation, arg_count);
    defer emitter.allocator.free(locations);
    if (arg_count > 0) {
        abi.computeArgLocations(arg_type_names, locations);
    }

    var stack_arg_bytes: u32 = 0;
    for (locations) |loc| {
        switch (loc) {
            .stack => |offset| {
                const end = @as(u32, @intCast(offset)) + abi.stack_slot_size;
                if (end > stack_arg_bytes) stack_arg_bytes = end;
            },
            else => {},
        }
    }

    const frame = computeFrame(emitter.frame_layout, stack_arg_bytes);
    try emitFramePrologue(emitter, frame);

    // Stack arguments go first, while every argument register still holds what it held.
    const save = if (emitter.move_scratch_slots) |slots| slots.save else null;
    const scratch = try stackScratch(args, save);
    for (args, locations) |arg, location| switch (location) {
        .stack => |offset| try storeStackArg(emitter, arg, Mem.baseDisp(.rsp, offset), scratch),
        .int_reg, .fp_reg => {},
    };

    var register_moves: std.ArrayListUnmanaged(moves.Move) = .empty;
    defer register_moves.deinit(emitter.allocator);
    var generated_int_args: std.ArrayListUnmanaged(GeneratedIntArg) = .empty;
    defer generated_int_args.deinit(emitter.allocator);

    for (args, 0..) |arg, i| {
        const info = try emitter.typeInfoFromName(arg.type_name);
        switch (locations[i]) {
            .int_reg => |dst| {
                if (info.is_float) return error.UnsupportedType;
                switch (arg.source) {
                    .slot => |slot| try register_moves.append(emitter.allocator, .{
                        .src = .{ .slot = slot },
                        .dst = .{ .reg = dst },
                    }),
                    .gpr => |src| try register_moves.append(emitter.allocator, .{
                        .src = .{ .reg = src },
                        .dst = .{ .reg = dst },
                    }),
                    .addr_of_slot, .imm => try generated_int_args.append(emitter.allocator, .{
                        .dst = dst,
                        .type_name = arg.type_name,
                        .source = arg.source,
                    }),
                    .xmm => return error.UnsupportedType,
                }
            },
            // A real moves with the rest, as one parallel assignment, so an argument already in
            // another's register is read before that register is written.
            .fp_reg => |dst| {
                if (!info.is_float) return error.UnsupportedType;
                if (info.width != 32 and info.width != 64) return error.UnsupportedType;
                switch (arg.source) {
                    .slot => |slot| try register_moves.append(emitter.allocator, .{
                        .src = .{ .slot = slot },
                        .dst = .{ .xmm = dst },
                    }),
                    .xmm => |src| try register_moves.append(emitter.allocator, .{
                        .src = .{ .xmm = src },
                        .dst = .{ .xmm = dst },
                    }),
                    else => return error.UnsupportedType,
                }
            },
            .stack => {},
        }
    }

    try emitter.emitParallelMoves(register_moves.items);
    for (generated_int_args.items) |arg| {
        try emitGeneratedIntArg(emitter, arg);
    }
    for (args, 0..) |arg, i| {
        const info = try emitter.typeInfoFromName(arg.type_name);
        switch (locations[i]) {
            .int_reg => |dst| if (info.width == 32) {
                try emitter.emitEncoding(encoding.movRegReg32(dst, dst));
            },
            else => {},
        }
    }

    try emitCallTo(emitter, callee);

    if (abi.returnsThroughRecord(results.len)) {
        try canonicalizeRecordResults(emitter, results);
    } else {
        try storeRegisterResults(emitter, results);
    }

    try emitFrameEpilogue(emitter, frame);
}

/// A callee in the caller's code image takes `call rel32`, five bytes. Any other callee may sit
/// anywhere in the address space, so it takes its absolute address in rax and an indirect call.
fn emitCallTo(emitter: anytype, callee: []const u8) !void {
    try emitter.call_relocations.ensureUnusedCapacity(emitter.allocator, 1);
    if (emitter.sharesImage(callee)) {
        const call = encoding.callRel32(0);
        std.debug.assert(call.len == 5);
        const window = emitter.code.items.len + 1;
        try emitter.emitEncoding(call);
        emitter.call_relocations.appendAssumeCapacity(.{ .offset = window, .target = callee, .width_bits = 32 });
        return;
    }
    const mov = encoding.movRegImm64(.rax, 0);
    const window = emitter.code.items.len + (mov.len - 8);
    try emitter.emitEncoding(mov);
    emitter.call_relocations.appendAssumeCapacity(.{ .offset = window, .target = callee });
    try emitter.emitEncoding(encoding.callReg(.rax));
}

fn storeRegisterResults(emitter: anytype, results: []const ExternResult) !void {
    std.debug.assert(results.len <= abi.max_register_results);
    var type_names: [abi.max_register_results][]const u8 = undefined;
    var locations: [abi.max_register_results]abi.ValueLocation = undefined;
    for (results, 0..) |result, i| {
        type_names[i] = result.type_name;
    }
    abi.computeReturnLocations(type_names[0..results.len], locations[0..results.len]);

    for (results, locations[0..results.len]) |result, location| {
        const info = try emitter.typeInfoFromName(result.type_name);
        switch (location) {
            .fp_reg => |reg| {
                if (!info.is_float) return error.UnsupportedType;
                const slot = result.slot orelse continue;
                try emitter.storeSlotXmm(slot, reg);
            },
            .int_reg => |reg| {
                if (info.is_float) return error.UnsupportedType;
                if (std.mem.eql(u8, result.type_name, "arith.bool")) {
                    try emitter.emitEncoding(encoding.movzxReg8(reg, reg));
                }
                const slot = result.slot orelse continue;
                try emitter.storeSlot(slot, reg);
            },
            .stack => unreachable,
        }
    }
}

/// A SysV callee defines only the low byte of a boolean field, so widen each one in place.
///
/// Every record result carries a slot, even one nothing reads. The callee writes the record
/// through a hidden pointer into a run of adjacent eightbytes and the first slot addresses the
/// whole run, so a missing member would move the ones above it. The assertion below is what
/// states that, and slot allocation exempts record results from dropping a dead value's slot.
fn canonicalizeRecordResults(emitter: anytype, results: []const ExternResult) !void {
    std.debug.assert(abi.returnsThroughRecord(results.len));
    for (results, 0..) |result, i| {
        const slot = result.slot.?;
        std.debug.assert(slot.offset == results[0].slot.?.offset + abi.recordFieldOffset(i));
        if (!std.mem.eql(u8, result.type_name, "arith.bool")) continue;
        const record_field = Mem.baseDisp(.rbp, slot.offset);
        try emitter.emitEncoding(encoding.movzxRegMem8(.rax, record_field));
        try emitter.storeSlot(slot, .rax);
    }
}
