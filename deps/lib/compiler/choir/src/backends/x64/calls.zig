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

/// The stack one call needs beyond the caller's own frame, which is its stack arguments and
/// whatever padding realigns the stack pointer for the call.
pub const Frame = struct {
    /// What the arguments themselves need.
    stack_arg_bytes: u32,
    /// What the stack pointer moves by, which is the arguments plus realignment.
    total_bytes: u32,
};

pub fn computeFrame(frame_layout: abi.FrameLayout, stack_arg_bytes: u32) Frame {
    const no_save_area = 0;
    const pad_bytes = abi.computeCallStackPadding(stack_arg_bytes, no_save_area, frame_layout.call_aligned);
    return .{
        .stack_arg_bytes = stack_arg_bytes,
        .total_bytes = stack_arg_bytes + pad_bytes,
    };
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

fn argUsesXmm(args: []const ExternArg, reg: XMM) bool {
    for (args) |arg| {
        switch (arg.source) {
            .xmm => |src| if (src == reg) return true,
            else => {},
        }
    }
    return false;
}

fn pickScratchGpr(args: []const ExternArg) GPR {
    const candidates = [_]GPR{ .r11, .r10, .rax };
    for (candidates) |reg| {
        if (!argUsesGpr(args, reg)) return reg;
    }
    return .r11;
}

fn pickScratchXmm(args: []const ExternArg) XMM {
    const candidates = [_]XMM{ .xmm15, .xmm14, .xmm13, .xmm12 };
    for (candidates) |reg| {
        if (!argUsesXmm(args, reg)) return reg;
    }
    return .xmm15;
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

    const scratch_gpr = pickScratchGpr(args);
    const scratch_xmm = pickScratchXmm(args);

    for (args, 0..) |arg, i| {
        if (locations[i] != .stack) continue;
        const offset = locations[i].stack;
        const info = try emitter.typeInfoFromName(arg.type_name);
        const mem = Mem.baseDisp(.rsp, offset);

        if (info.is_float) {
            switch (arg.source) {
                .slot => |slot| {
                    try emitter.loadSlotXmm(slot, scratch_xmm);
                    if (info.width == 32) {
                        try emitter.emitEncoding(encoding.movssStore(mem, scratch_xmm));
                    } else if (info.width == 64) {
                        try emitter.emitEncoding(encoding.movsdStore(mem, scratch_xmm));
                    } else {
                        return error.UnsupportedType;
                    }
                },
                .xmm => |src| {
                    if (info.width == 32) {
                        try emitter.emitEncoding(encoding.movssStore(mem, src));
                    } else if (info.width == 64) {
                        try emitter.emitEncoding(encoding.movsdStore(mem, src));
                    } else {
                        return error.UnsupportedType;
                    }
                },
                else => return error.UnsupportedType,
            }
        } else {
            switch (arg.source) {
                .slot => |slot| {
                    try emitter.loadSlot(slot, scratch_gpr);
                    switch (info.width) {
                        8 => try emitter.emitEncoding(encoding.movMemReg8(mem, scratch_gpr)),
                        16 => try emitter.emitEncoding(encoding.movMemReg16(mem, scratch_gpr)),
                        32 => try emitter.emitEncoding(encoding.movMemReg32(mem, scratch_gpr)),
                        64 => try emitter.emitEncoding(encoding.movMemReg(mem, scratch_gpr)),
                        else => return error.UnsupportedType,
                    }
                },
                .addr_of_slot => |slot| {
                    if (info.width != 64) return error.UnsupportedType;
                    try emitter.emitEncoding(encoding.movRegReg(scratch_gpr, .rbp));
                    if (slot.offset != 0) {
                        try emitter.emitEncoding(encoding.addRegImm(scratch_gpr, slot.offset));
                    }
                    try emitter.emitEncoding(encoding.movMemReg(mem, scratch_gpr));
                },
                .gpr => |src| {
                    switch (info.width) {
                        8 => try emitter.emitEncoding(encoding.movMemReg8(mem, src)),
                        16 => try emitter.emitEncoding(encoding.movMemReg16(mem, src)),
                        32 => try emitter.emitEncoding(encoding.movMemReg32(mem, src)),
                        64 => try emitter.emitEncoding(encoding.movMemReg(mem, src)),
                        else => return error.UnsupportedType,
                    }
                },
                .imm => |imm| {
                    switch (info.width) {
                        8 => {
                            if (imm > std.math.maxInt(u8)) return error.InvalidConstant;
                            try emitter.emitEncoding(encoding.movRegImm32(scratch_gpr, @intCast(imm)));
                            try emitter.emitEncoding(encoding.movMemReg8(mem, scratch_gpr));
                        },
                        16 => {
                            if (imm > std.math.maxInt(u16)) return error.InvalidConstant;
                            try emitter.emitEncoding(encoding.movRegImm32(scratch_gpr, @intCast(imm)));
                            try emitter.emitEncoding(encoding.movMemReg16(mem, scratch_gpr));
                        },
                        32 => {
                            if (imm > std.math.maxInt(u32)) return error.InvalidConstant;
                            try emitter.emitEncoding(encoding.movRegImm32(scratch_gpr, @intCast(imm)));
                            try emitter.emitEncoding(encoding.movMemReg32(mem, scratch_gpr));
                        },
                        64 => {
                            try emitter.emitEncoding(encoding.movRegImm64(scratch_gpr, imm));
                            try emitter.emitEncoding(encoding.movMemReg(mem, scratch_gpr));
                        },
                        else => return error.UnsupportedType,
                    }
                },
                .xmm => return error.UnsupportedType,
            }
        }
    }

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
            .fp_reg => |dst| {
                if (!info.is_float) return error.UnsupportedType;
                switch (arg.source) {
                    .slot => |slot| {
                        try emitter.loadSlotXmm(slot, dst);
                    },
                    .xmm => |src| {
                        if (src == dst) break;
                        if (info.width == 32) {
                            try emitter.emitEncoding(encoding.movss(dst, .{ .reg = src }));
                        } else if (info.width == 64) {
                            try emitter.emitEncoding(encoding.movsd(dst, .{ .reg = src }));
                        } else {
                            return error.UnsupportedType;
                        }
                    },
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

    const mov = encoding.movRegImm64(.rax, 0);
    const mov_offset = emitter.code.items.len;
    try emitter.emitEncoding(mov);
    const imm_offset = mov_offset + (mov.len - 8);
    try emitter.call_relocations.append(emitter.allocator, .{ .offset = imm_offset, .target = callee });
    try emitter.emitEncoding(encoding.callReg(.rax));

    if (abi.returnsThroughRecord(results.len)) {
        try canonicalizeRecordResults(emitter, results);
    } else {
        try storeRegisterResults(emitter, results);
    }

    try emitFrameEpilogue(emitter, frame);
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
