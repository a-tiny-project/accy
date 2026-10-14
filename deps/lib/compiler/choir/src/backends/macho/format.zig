const std = @import("std");
const backends = @import("../root.zig");
const machine = backends.machine_code;

pub const header_bytes = 448;
pub const symbol_bytes = 16;
pub const relocation_bytes = 8;
pub const max_alignment = machine.max_data_alignment;
pub const ObjectError = std.mem.Allocator.Error || ValidationError;
pub const ValidationError = error{
    InvalidName,
    DuplicateSymbol,
    InvalidAlignment,
    InvalidTextSymbol,
    InvalidDataSymbol,
    InvalidRelocationOffset,
    OverlappingRelocations,
    UnsupportedRelocation,
    ObjectSizeOverflow,
};

pub const Section = enum(u8) {
    text,
    rodata,
    data,
    bss,

    pub fn ordinal(self: Section) u8 {
        return @backingInt(self) + 1;
    }

    pub fn ofData(section: machine.DataSection) Section {
        return switch (section) {
            .rodata => .rodata,
            .data => .data,
            .bss => .bss,
        };
    }
};

pub const TextSymbol = struct {
    name: []const u8,
    offset: u64,
    size: u64,
    /// Export visibility is explicit and independent of symbol spelling.
    binding: machine.DataSymbolBinding = .global,
};

pub const Relocation = struct {
    section: Section = .text,
    offset: u64,
    symbol: []const u8,
    kind: backends.artifact.RelocationKind,
    addend: i64 = 0,
    width_bits: u16 = 64,
};

/// Input descriptors, names, and initialized bytes are borrowed through write and deinit.
/// This owner emits only little-endian arm64 MH_OBJECT, never an executable.
pub const RelocatableObject = struct {
    text: []const u8,
    text_alignment: usize = 16,
    text_symbols: []const TextSymbol = &.{},
    data_symbols: []const machine.DataSymbol = &.{},
    relocations: []const Relocation = &.{},
};

pub fn add(left: u64, right: u64) ObjectError!u64 {
    return std.math.add(u64, left, right) catch error.ObjectSizeOverflow;
}

pub fn multiply(left: u64, right: u64) ObjectError!u64 {
    return std.math.mul(u64, left, right) catch error.ObjectSizeOverflow;
}

pub fn alignForward(value: u64, alignment: u64) ObjectError!u64 {
    const mask = alignment - 1;
    return (try add(value, mask)) & ~mask;
}

pub fn validateAlignment(alignment: usize) ObjectError!void {
    if (alignment == 0 or alignment > max_alignment or !std.math.isPowerOfTwo(alignment)) {
        return error.InvalidAlignment;
    }
}

pub fn validateName(bytes: []const u8) ObjectError!void {
    if (bytes.len == 0 or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidName;
}

pub fn put(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

pub fn name(out: []u8, offset: usize, bytes: []const u8) void {
    std.debug.assert(bytes.len <= 16);
    @memcpy(out[offset..][0..bytes.len], bytes);
}
