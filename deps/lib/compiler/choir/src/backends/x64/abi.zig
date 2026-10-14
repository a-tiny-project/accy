const std = @import("std");
const artifact = @import("../root.zig").artifact;
const registers = @import("registers/root.zig");
const encoding = @import("encoding.zig");
const Excess = @import("../execution/bounds.zig").Excess;

const GPR = registers.GPR;
const XMM = registers.XMM;

pub const max_int_arg_regs = 6;

pub const max_fp_arg_regs = 8;

pub const int_arg_regs = [_]GPR{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };

pub const fp_arg_regs = [_]XMM{ .xmm0, .xmm1, .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7 };

pub const int_return_reg = GPR.rax;

/// Largest result count one function, call, or return carries.
/// Bounds a result record to 128 bytes; wider products travel through memory references.
pub const max_result_count: usize = 16;

/// Largest result count returned in registers; more results travel through a caller record.
pub const max_register_results: usize = 2;

/// Integer-class result registers in SysV assignment order.
pub const int_return_regs = [max_register_results]GPR{ .rax, .rdx };

/// Floating-point result registers in SysV assignment order.
pub const fp_return_regs = [max_register_results]XMM{ .xmm0, .xmm1 };

pub const fp_return_reg = XMM.xmm0;

pub const stack_alignment = 16;

/// Largest argument count one call passes or one function takes: the parameters a signature
/// records, so a call to any function this target defines fits. A call returning through a
/// record passes one more word, the record's address.
pub const max_call_arguments: usize = artifact.Signature.max_parameters;
pub const max_argument_words: usize = max_call_arguments + 1;

/// The most stack one argument list and its realignment take, with every word on the stack.
/// The figure is static, so neither the argument layout's offsets nor the `sub rsp, imm32` that
/// makes room for a call can overflow, and no call checks it as it is emitted.
pub const max_argument_stack_bytes: u32 = max_argument_words * stack_slot_size +
    (stack_alignment - stack_slot_size);
comptime {
    std.debug.assert(max_argument_stack_bytes <= std.math.maxInt(i32));
}

pub const stack_slot_size = 8;

/// The most bytes one frame occupies below its saved frame pointer: the callee-saved pushes, the
/// local slots, and the padding that realigns the stack for a call.
///
/// THIS IS THE INSTRUCTION SET'S FIGURE, NOT A POLICY. Every local is addressed by a signed 32-bit
/// displacement from rbp, so the deepest slot must lie within 2^31 bytes of it, and the prologue
/// moves rsp by a sign-extended 32-bit immediate, so the locals and padding must come to at most
/// 2^31 - 1. A frame below rbp is a multiple of 16 bytes, and the largest such figure that keeps
/// both is 2^31 - 16: exact when no callee-saved register is pushed, where the immediate binds,
/// and within 16 bytes of exact otherwise. How much stack a program may use is a separate
/// question its host and its caller answer; this figure only says what the encoding can state.
pub const max_frame_bytes: u64 = (1 << 31) - 16;

pub const FrameError = error{FrameTooLarge};

/// The excess when a frame holding `held` bytes below rbp grows by `requested`, or null when the
/// grown frame fits `max_frame_bytes`. It names `frame_bytes`, so a report states the figure, the
/// bytes already laid out below the saved frame pointer, and the bytes the refused step asked for.
pub fn frameExcess(held: u64, requested: u64) ?Excess {
    return Excess.of(.frame_bytes, max_frame_bytes, held, requested);
}

/// The padding slots that put a frame of `local_slots` locals beneath `saved` callee-saved pushes
/// on the alignment a call needs: the return address and every push are one slot each, so the
/// pushes, the locals and the padding together come to an even count of slots past rbp.
pub fn framePaddingSlots(local_slots: u64, saved: u64) u64 {
    return (local_slots +% saved) % 2;
}

pub const callee_saved_gprs = registers.callee_saved_gprs;

pub const PassingKind = enum {
    int_reg,
    fp_reg,
    stack,
};

pub const ValueLocation = union(PassingKind) {
    int_reg: GPR,
    fp_reg: XMM,
    stack: i32,
};

pub const TypeClass = enum {
    integer,
    floating_point,
};

pub fn classifyType(type_name: []const u8) TypeClass {
    if (std.mem.eql(u8, type_name, "arith.i8") or
        std.mem.eql(u8, type_name, "arith.i16") or
        std.mem.eql(u8, type_name, "arith.i32") or
        std.mem.eql(u8, type_name, "arith.i64") or
        std.mem.eql(u8, type_name, "arith.u8") or
        std.mem.eql(u8, type_name, "arith.u16") or
        std.mem.eql(u8, type_name, "arith.u32") or
        std.mem.eql(u8, type_name, "arith.u64") or
        std.mem.eql(u8, type_name, "arith.index") or
        std.mem.eql(u8, type_name, "arith.bool"))
    {
        return .integer;
    }

    if (std.mem.eql(u8, type_name, "arith.f16") or
        std.mem.eql(u8, type_name, "arith.bf16") or
        std.mem.eql(u8, type_name, "arith.f32") or
        std.mem.eql(u8, type_name, "arith.f64"))
    {
        return .floating_point;
    }

    return .integer;
}

pub fn computeArgLocations(arg_types: []const []const u8, locations: []ValueLocation) void {
    std.debug.assert(locations.len >= arg_types.len);
    std.debug.assert(arg_types.len <= max_argument_words);

    var next_int_reg: usize = 0;
    var next_fp_reg: usize = 0;
    var stack_offset: i32 = 0;

    for (arg_types, 0..) |type_name, i| {
        const class = classifyType(type_name);
        switch (class) {
            .integer => {
                if (next_int_reg < max_int_arg_regs) {
                    locations[i] = .{ .int_reg = int_arg_regs[next_int_reg] };
                    next_int_reg += 1;
                } else {
                    locations[i] = .{ .stack = stack_offset };
                    stack_offset += stack_slot_size;
                }
            },
            .floating_point => {
                if (next_fp_reg < max_fp_arg_regs) {
                    locations[i] = .{ .fp_reg = fp_arg_regs[next_fp_reg] };
                    next_fp_reg += 1;
                } else {
                    locations[i] = .{ .stack = stack_offset };
                    stack_offset += stack_slot_size;
                }
            },
        }
    }
}

pub fn computeCallStackPadding(stack_arg_bytes: u32, save_bytes: u32, call_aligned: bool) u32 {
    _ = call_aligned;
    const total = stack_arg_bytes + save_bytes;
    const rem = total % stack_alignment;
    if (rem == 0) return 0;
    return stack_alignment - rem;
}

pub fn computeReturnLocation(type_name: []const u8) ValueLocation {
    return switch (classifyType(type_name)) {
        .integer => .{ .int_reg = int_return_reg },
        .floating_point => .{ .fp_reg = fp_return_reg },
    };
}

/// Reports whether results travel through a caller-provided record instead of registers.
/// Results form a struct whose fields each occupy one eightbyte; SysV returns a struct
/// wider than two eightbytes in memory, with the record address as the first argument.
pub fn returnsThroughRecord(result_count: usize) bool {
    return result_count > max_register_results;
}

/// Assigns each register-returned result the next register of its SysV class.
pub fn computeReturnLocations(result_types: []const []const u8, locations: []ValueLocation) void {
    std.debug.assert(result_types.len <= max_register_results);
    std.debug.assert(locations.len >= result_types.len);

    var next_int_reg: usize = 0;
    var next_fp_reg: usize = 0;
    for (result_types, 0..) |type_name, i| {
        switch (classifyType(type_name)) {
            .integer => {
                locations[i] = .{ .int_reg = int_return_regs[next_int_reg] };
                next_int_reg += 1;
            },
            .floating_point => {
                locations[i] = .{ .fp_reg = fp_return_regs[next_fp_reg] };
                next_fp_reg += 1;
            },
        }
    }
    std.debug.assert(next_int_reg + next_fp_reg == result_types.len);
}

/// Returns the byte offset of one result inside a caller-provided result record.
pub fn recordFieldOffset(index: usize) i32 {
    std.debug.assert(index < max_result_count);
    return @intCast(index * stack_slot_size);
}

comptime {
    std.debug.assert(artifact.Signature.max_results == max_result_count);
}

/// Reports whether `signature` is valid and this backend passes and returns every type in it.
/// Parameters must be scalars or memrefs, and a vector result must be the only result.
pub fn admitsSignature(signature: *const artifact.Signature) bool {
    if (!signature.isValid()) return false;
    for (signature.parameters()) |parameter| {
        if (parameter == .vector) return false;
    }
    const results = signature.results();
    if (results.len < 2) return true;
    for (results) |result| {
        if (result == .vector) return false;
    }
    return true;
}

pub const FrameLayout = struct {
    stack_alloc: u32,
    padding: u32,
    num_callee_saved: u8,
    used_callee_saved: [callee_saved_gprs.len]GPR,
    call_aligned: bool,

    pub fn emitPrologue(self: FrameLayout, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try appendEncoding(out, allocator, encoding.pushReg(.rbp));
        try appendEncoding(out, allocator, encoding.movRegReg(.rbp, .rsp));

        var i: usize = 0;
        while (i < self.num_callee_saved) : (i += 1) {
            try appendEncoding(out, allocator, encoding.pushReg(self.used_callee_saved[i]));
        }

        if (self.stack_alloc != 0) {
            try appendEncoding(out, allocator, encoding.subRegImm(.rsp, @intCast(self.stack_alloc)));
        }
    }

    pub fn emitEpilogue(self: FrameLayout, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        if (self.stack_alloc != 0) {
            try appendEncoding(out, allocator, encoding.addRegImm(.rsp, @intCast(self.stack_alloc)));
        }

        var i: usize = self.num_callee_saved;
        while (i > 0) : (i -= 1) {
            try appendEncoding(out, allocator, encoding.popReg(self.used_callee_saved[i - 1]));
        }

        try appendEncoding(out, allocator, encoding.popReg(.rbp));
        try appendEncoding(out, allocator, encoding.ret());
    }
};

/// Lays out a frame of `local_slots` eight-byte locals beneath the pushes of `used_callee_saved`,
/// or refuses it when the frame below rbp would pass `max_frame_bytes`, in every build mode.
pub fn computeFrameLayout(
    local_slots: usize,
    used_callee_saved: []const GPR,
    ensure_call_alignment: bool,
) FrameError!FrameLayout {
    std.debug.assert(used_callee_saved.len <= callee_saved_gprs.len);
    var used: [callee_saved_gprs.len]GPR = callee_saved_gprs;
    @memcpy(used[0..used_callee_saved.len], used_callee_saved);

    const saved: u64 = used_callee_saved.len;
    const padding_slots: u64 = if (ensure_call_alignment) framePaddingSlots(local_slots, saved) else 0;
    const held_slots = std.math.add(u64, local_slots, saved) catch return error.FrameTooLarge;
    const held = std.math.mul(u64, held_slots, stack_slot_size) catch return error.FrameTooLarge;
    if (frameExcess(held, padding_slots * stack_slot_size) != null) return error.FrameTooLarge;

    const locals: u32 = @intCast(local_slots * stack_slot_size);
    const padding: u32 = @intCast(padding_slots * stack_slot_size);
    const stack_alloc = locals + padding;
    std.debug.assert(stack_alloc <= std.math.maxInt(i32));
    std.debug.assert(!ensure_call_alignment or
        (stack_slot_size * (1 + saved) + stack_alloc) % stack_alignment == stack_alignment / 2);

    return .{
        .stack_alloc = stack_alloc,
        .padding = padding,
        .num_callee_saved = @intCast(used_callee_saved.len),
        .used_callee_saved = used,
        .call_aligned = ensure_call_alignment,
    };
}

fn appendEncoding(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, enc: encoding.Encoding) !void {
    try out.appendSlice(allocator, enc.slice());
}
