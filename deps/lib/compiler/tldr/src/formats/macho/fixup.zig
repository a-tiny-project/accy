const std = @import("std");
const root = @import("../../root.zig");

pub const literal_bytes = 8;
pub const instruction_bytes = 4;
pub const CellKind = enum { rebase, bind };

pub const Neighborhood = struct {
    start: usize,
    end: usize,
    slot: usize,
    register: u5,
    call: bool,
};

/// N5 UNSIGNED64 drops the semantic call/address tag. Recover it only from the
/// complete unique emitter neighborhood, never from a symbol's spelling/type.
pub fn neighborhood(text: []const u8, slot: usize) root.Error!Neighborhood {
    if (slot % literal_bytes != 0 or slot > text.len or text.len - slot < literal_bytes) {
        return error.UnsupportedMachOInputProtocol;
    }
    // Both positive and negative signed addends are outside this first product.
    const addend: i64 = @bitCast(std.mem.readInt(u64, text[slot..][0..8], .little));
    if (addend != 0) return error.UnsupportedMachOAddend;
    var match: ?Neighborhood = null;
    for ([_]usize{ 8, 12, 16 }) |distance| {
        if (slot < distance) continue;
        const start = slot - distance;
        const ldr = word(text, start);
        if (ldr & 0xff000000 != 0x58000000) continue;
        const immediate: i19 = @bitCast(@as(u19, @truncate(ldr >> 5)));
        if (@as(i64, immediate) * 4 != @as(i64, @intCast(distance))) continue;
        const register: u5 = @truncate(ldr);
        for ([_]bool{ false, true }) |call| {
            const branch_offset = start + if (call) @as(usize, 8) else @as(usize, 4);
            const prefix_bytes: usize = if (call) 12 else 8;
            if (std.mem.alignForward(usize, start + prefix_bytes, 8) != slot) continue;
            if (call and (register != 16 or word(text, start + 4) != 0xd63f0200)) continue;
            const branch = word(text, branch_offset);
            if (branch & 0xfc000000 != 0x14000000) continue;
            const branch_immediate: i26 = @bitCast(@as(u26, @truncate(branch)));
            if (@as(i64, branch_immediate) * 4 != @as(i64, @intCast(slot + literal_bytes - branch_offset))) continue;
            if (start + prefix_bytes != slot and word(text, start + prefix_bytes) != 0xd503201f) continue;
            if (match != null) return error.AmbiguousMachOLiteral;
            match = .{ .start = start, .end = slot + literal_bytes, .slot = slot, .register = register, .call = call };
        }
    }
    return match orelse error.UnsupportedMachOInputProtocol;
}

/// Register homes and all instruction positions survive; only imm19 changes.
pub fn redirectedLdr(original: u32, instruction_vm: u64, cell_vm: u64) root.Error!u32 {
    if (original & 0xff000000 != 0x58000000) return error.UnsupportedMachOInputProtocol;
    const delta: i128 = @as(i128, cell_vm) - @as(i128, instruction_vm);
    if (@mod(delta, 4) != 0 or delta < -1048576 or delta > 1048572) return error.RelocationOverflow;
    const words: i19 = @intCast(@divExact(delta, 4));
    return (original & ~@as(u32, 0x00ffffe0)) | (@as(u32, @as(u19, @bitCast(words))) << 5);
}

/// Each instruction-class LDR literal must have one accepted relocation. Slots
/// are excluded as data, and overlapping neighborhoods are rejected at admission.
pub fn census(text: []const u8, owners: []const u8) root.Error!void {
    if (text.len % instruction_bytes != 0 or owners.len != text.len / instruction_bytes) {
        return error.UnsupportedMachOInputProtocol;
    }
    for (owners, 0..) |owner, index| {
        if (owner == 2) continue; // The retained zero literal word.
        const instruction = word(text, index * instruction_bytes);
        if (instruction & 0x3b000000 == 0x18000000 and owner != 1) {
            return error.UnsupportedMachOInputProtocol;
        }
    }
}

pub fn word(bytes: []const u8, offset: usize) u32 {
    std.debug.assert(offset <= bytes.len and bytes.len - offset >= instruction_bytes);
    return std.mem.readInt(u32, bytes[offset..][0..instruction_bytes], .little);
}

pub fn putWord(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..instruction_bytes], value, .little);
}

pub fn appendUleb(allocator: std.mem.Allocator, bytes: *std.ArrayListUnmanaged(u8), value: u64) root.Error!void {
    var remaining = value;
    // A u64 takes at most ten seven-bit groups.
    for (0..10) |_| {
        const byte: u8 = @truncate(remaining & 0x7f);
        remaining >>= 7;
        try bytes.append(allocator, byte | if (remaining == 0) @as(u8, 0) else 0x80);
        if (remaining == 0) return;
    }
    unreachable;
}
