const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");

const model = root.model;
const Rela = elf.format.Rela;
const readU32 = elf.format.readU32;

pub const Cursor = struct {
    relocations: []const Rela,
    index: usize = 0,
    sorted: bool,

    pub fn init(relocations: []const Rela) Cursor {
        return .{
            .relocations = relocations,
            .sorted = sortedByOffset(relocations),
        };
    }

    pub fn at(self: *Cursor, offset: u64) ?Rela {
        if (!self.sorted) return scanAt(self.relocations, offset);
        while (self.index < self.relocations.len and self.relocations[self.index].offset < offset) self.index += 1;
        var run = self.index;
        while (run < self.relocations.len and self.relocations[run].offset == offset) : (run += 1) {
            if (!elf.relocation.isNone(self.relocations[run])) return self.relocations[run];
        }
        return null;
    }

    pub fn window(self: *Cursor, start_offset: u64, end_offset: u64) ?[]const Rela {
        if (!self.sorted) return null;
        while (self.index < self.relocations.len and self.relocations[self.index].offset < start_offset) self.index += 1;
        const window_start = self.index;
        while (self.index < self.relocations.len and self.relocations[self.index].offset < end_offset) self.index += 1;
        return self.relocations[window_start..self.index];
    }
};

pub fn hasHeaderEntry(
    bytes: []const u8,
    input_offset: u64,
    size: u64,
    output_offset: u64,
    cursor: *Cursor,
) model.Error!bool {
    if (size < 4) return error.InvalidObject;
    const start: usize = @intCast(input_offset);
    if (bytes.len - start < 4) return error.InvalidObject;
    const record_length = readU32(bytes, start);
    if (record_length == 0) return false;
    if (record_length == 0xffffffff) return error.UnsupportedFormat;
    if (size < @as(u64, record_length) + 4) return error.InvalidObject;
    if (record_length < 4) return error.InvalidObject;
    const record_id = readU32(bytes, start + 4);
    if (record_id == 0) return false;
    return cursor.at(output_offset + 8) != null;
}

fn sortedByOffset(relocations: []const Rela) bool {
    if (relocations.len < 2) return true;
    for (relocations[0 .. relocations.len - 1], relocations[1..]) |previous, next| {
        if (next.offset < previous.offset) return false;
    }
    return true;
}

fn scanAt(relocations: []const Rela, offset: u64) ?Rela {
    for (relocations) |relocation| {
        if (relocation.offset == offset and !elf.relocation.isNone(relocation)) return relocation;
    }
    return null;
}
