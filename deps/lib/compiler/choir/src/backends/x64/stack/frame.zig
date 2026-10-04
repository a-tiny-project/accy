const std = @import("std");
const x86 = @import("isa").x86;

pub const Error = x86.DecodeError || error{InvalidStackFrame};

/// Recognizes one SysV frame without consulting the emitter's layout calculation.
pub const Frame = struct {
    saved: [5]u4 = undefined,
    count: u3 = 0,
    allocation: u32 = 0,
    body: u32,
    instructions: u8,

    pub fn read(code: []const u8) Error!Frame {
        if (!std.mem.startsWith(u8, code, &.{ 0x55, 0x48, 0x89, 0xe5 })) {
            return error.InvalidStackFrame;
        }
        var result = Frame{ .body = 4, .instructions = 2 };
        var offset: usize = 4;
        for (0..result.saved.len) |_| {
            if (offset == code.len) break;
            const decoded = try x86.decode(code[offset..]);
            if (decoded.operation != .push) break;
            const register = decoded.embedded orelse return error.InvalidStackFrame;
            if (register.lane != .qword or !calleeSaved(register.number)) {
                return error.InvalidStackFrame;
            }
            for (result.saved[0..result.count]) |prior| {
                if (prior == register.number) return error.InvalidStackFrame;
            }
            result.saved[result.count] = register.number;
            result.count += 1;
            result.instructions += 1;
            offset += decoded.bytes;
        }
        if (offset < code.len) {
            const decoded = try x86.decode(code[offset..]);
            if (adjustment(decoded, .sub)) |allocation| {
                result.allocation = allocation;
                result.instructions += 1;
                offset += decoded.bytes;
            }
        }
        result.body = std.math.cast(u32, offset) orelse return error.InvalidStackFrame;
        std.debug.assert(result.count <= result.saved.len);
        std.debug.assert(result.body <= code.len);
        return result;
    }

    pub fn bytes(self: Frame) u32 {
        std.debug.assert(self.allocation <= std.math.maxInt(i32));
        std.debug.assert(self.count <= self.saved.len);
        return 16 + @as(u32, self.count) * 8 + self.allocation;
    }

    pub fn exit(self: Frame, code: []const u8) ?usize {
        var offset: usize = 0;
        if (self.allocation != 0) {
            const decoded = x86.decode(code) catch return null;
            if ((adjustment(decoded, .add) orelse return null) != self.allocation) return null;
            offset += decoded.bytes;
        }
        for (0..self.count) |index| {
            offset += pop(code[offset..], self.saved[self.count - 1 - index]) orelse return null;
        }
        offset += pop(code[offset..], 5) orelse return null;
        if (offset == code.len or code[offset] != 0xc3) return null;
        return offset + 1;
    }

    pub fn exitInstructions(self: Frame) u8 {
        return 2 + @as(u8, self.count) + @as(u8, if (self.allocation == 0) 0 else 1);
    }
};

fn calleeSaved(number: u4) bool {
    return number == 3 or number >= 12;
}

fn pop(code: []const u8, number: u4) ?usize {
    const decoded = x86.decode(code) catch return null;
    if (decoded.operation != .pop) return null;
    const register = decoded.embedded orelse return null;
    if (register.lane != .qword or register.number != number) return null;
    return decoded.bytes;
}

fn adjustment(decoded: x86.Instruction, operation: x86.Operation) ?u32 {
    if (decoded.operation != operation or decoded.operand != .register) return null;
    const register = decoded.operand.register;
    if (register.bank != .gpr or register.number != 4 or register.lane != .qword) return null;
    const immediate = decoded.immediate orelse return null;
    const value = immediate.signed();
    if (value < 0 or value > std.math.maxInt(i32)) return null;
    return @intCast(value);
}
