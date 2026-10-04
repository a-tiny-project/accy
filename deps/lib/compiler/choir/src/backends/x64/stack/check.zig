const std = @import("std");
const x86 = @import("isa").x86;
const frame = @import("frame.zig");

const CheckError = error{
    StackWorkspaceExceeded,
    UnsupportedStackInstruction,
    InvalidStackBranch,
    StackFallthrough,
};

pub const Error = frame.Error || CheckError;

/// Bounds stack-pointer reservation, including the entry return-address word.
/// Memory safety, return-address integrity, caller frames, and interrupts remain premises.
pub const Evidence = struct {
    bytes: u32,
    instructions: u32,
};

pub fn workspaceBytes(code_bytes: usize) Error!usize {
    if (code_bytes == 0 or code_bytes > std.math.maxInt(u32)) {
        return error.StackWorkspaceExceeded;
    }
    const bytes = code_bytes / 8 + @as(usize, if (code_bytes % 8 == 0) 0 else 1);
    std.debug.assert(bytes > 0);
    std.debug.assert(bytes <= code_bytes);
    return bytes;
}

/// Uses caller storage for one boundary bit per machine-code byte, without allocation.
/// Only direct local control flow and matching fixed-frame exits pass admission.
/// Workspace storage must not overlap the code.
pub fn check(code: []const u8, workspace: []u8) Error!Evidence {
    if (code.len != 0 and workspace.len != 0) {
        const source = @intFromPtr(code.ptr);
        const destination = @intFromPtr(workspace.ptr);
        const overlap = if (source <= destination)
            destination - source < code.len
        else
            source - destination < workspace.len;
        std.debug.assert(!overlap);
    }
    const required = try workspaceBytes(code.len);
    if (workspace.len < required) return error.StackWorkspaceExceeded;
    const boundaries = workspace[0..required];
    @memset(boundaries, 0);
    const layout = try frame.Frame.read(code);
    _ = try scan(code, layout, boundaries, false);
    const instructions = try scan(code, layout, boundaries, true);
    std.debug.assert(instructions > 0);
    std.debug.assert(instructions <= code.len);
    return .{ .bytes = layout.bytes(), .instructions = instructions };
}

fn scan(code: []const u8, layout: frame.Frame, boundaries: []u8, validate: bool) Error!u32 {
    std.debug.assert(layout.body <= code.len);
    var offset: usize = layout.body;
    var instructions: u32 = layout.instructions;
    var terminal = false;
    while (offset < code.len) {
        const start = offset;
        std.debug.assert(start / 8 < boundaries.len);
        if (!validate) boundaries[start / 8] |= @as(u8, 1) << @intCast(start % 8);
        if (layout.exit(code[start..])) |bytes| {
            offset += bytes;
            instructions += layout.exitInstructions();
            terminal = true;
            continue;
        }
        const decoded = try x86.decode(code[start..]);
        try body(decoded);
        offset += decoded.bytes;
        instructions += 1;
        if (validate) try branch(decoded, offset, code.len, boundaries);
        terminal = decoded.operation == .jmp or decoded.operation == .ud2;
    }
    if (!terminal) return error.StackFallthrough;
    std.debug.assert(offset == code.len);
    return instructions;
}

fn body(decoded: x86.Instruction) Error!void {
    switch (decoded.family) {
        .move,
        .extend,
        .address,
        .arithmetic,
        .logic,
        .unary,
        .shift,
        .multiply,
        .divide,
        .condition,
        .swap,
        .carry,
        .nop,
        .vector,
        .exchange,
        => {},
        .control => if (decoded.operation != .jmp or decoded.relative == null) {
            return error.UnsupportedStackInstruction;
        },
        .boundary => if (decoded.operation != .ud2) return error.UnsupportedStackInstruction,
        else => return error.UnsupportedStackInstruction,
    }
    if (writesFrame(decoded.register, decoded.register_access) or
        writesFrame(decoded.embedded, decoded.embedded_access))
    {
        return error.UnsupportedStackInstruction;
    }
    if (decoded.operand == .register and
        writesFrame(decoded.operand.register, decoded.operand_access))
    {
        return error.UnsupportedStackInstruction;
    }
    for (decoded.implicitRegisters()) |access| {
        if (writesFrame(access.register, access.access)) return error.UnsupportedStackInstruction;
    }
}

fn writesFrame(register: ?x86.Register, access: x86.Access) bool {
    if (access != .write and access != .read_write) return false;
    const value = register orelse return false;
    return value.bank == .gpr and (value.number == 4 or value.number == 5);
}

fn branch(decoded: x86.Instruction, next: usize, code_bytes: usize, boundaries: []const u8) !void {
    const relative = decoded.relative orelse return;
    const destination = @as(i64, @intCast(next)) + relative;
    if (destination < 0 or destination >= code_bytes) return error.InvalidStackBranch;
    const offset: usize = @intCast(destination);
    const mask = @as(u8, 1) << @intCast(offset % 8);
    if (boundaries[offset / 8] & mask == 0) return error.InvalidStackBranch;
}
