const std = @import("std");
const artifact = @import("../root.zig").artifact;
const registers = @import("registers/root.zig");
const encoding = @import("encoding.zig");

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

pub const stack_slot_size = 8;

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

pub fn computeFrameLayout(
    local_size: u32,
    used_callee_saved: []const GPR,
    ensure_call_alignment: bool,
) FrameLayout {
    var used: [callee_saved_gprs.len]GPR = callee_saved_gprs;
    var count: usize = 0;
    for (used_callee_saved) |reg| {
        used[count] = reg;
        count += 1;
    }

    var aligned_locals = local_size;
    if (aligned_locals % stack_slot_size != 0) {
        aligned_locals = aligned_locals + (stack_slot_size - (aligned_locals % stack_slot_size));
    }

    const push_bytes: u32 = stack_slot_size * @as(u32, @intCast(1 + count));
    var stack_alloc: u32 = aligned_locals;

    if (ensure_call_alignment) {
        const desired: u32 = stack_alignment / 2;
        const total = push_bytes + stack_alloc;
        const rem = total % stack_alignment;
        if (rem != desired) {
            const delta = (stack_alignment + desired - rem) % stack_alignment;
            stack_alloc += delta;
        }
    }

    const padding = stack_alloc - aligned_locals;

    return .{
        .stack_alloc = stack_alloc,
        .padding = padding,
        .num_callee_saved = @intCast(count),
        .used_callee_saved = used,
        .call_aligned = ensure_call_alignment,
    };
}

fn appendEncoding(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, enc: encoding.Encoding) !void {
    try out.appendSlice(allocator, enc.slice());
}
