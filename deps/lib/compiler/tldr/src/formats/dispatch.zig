const std = @import("std");
const root = @import("../root.zig");

const coff = @import("coff.zig");
const elf = @import("elf/root.zig");
const macho = @import("macho/root.zig");

const elf_object = elf.object;

pub fn parseObject(
    allocator: std.mem.Allocator,
    input: root.Input,
) root.Error!root.Object {
    return switch (try detectObjectFormat(input.bytes)) {
        .elf => try elf.parseObjectMetadata(allocator, input),
        .coff => try coff.parseObjectMetadata(allocator, input.bytes),
        .macho => try macho.parseObjectMetadata(allocator, input.bytes),
        .wasm => error.UnsupportedFormat,
    };
}

pub fn detectObjectFormat(bytes: []const u8) root.Error!root.model.ObjectFormat {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], std.elf.MAGIC)) return .elf;
    if (isMachO(bytes)) return .macho;
    if (coff.isObject(bytes)) return .coff;
    return error.UnsupportedFormat;
}

pub fn validateInputFormats(inputs: []const root.Input, options: root.LinkOptions) root.Error!void {
    for (inputs) |input| {
        if (root.archive.isArchive(input.bytes)) continue;
        const input_format = try detectObjectFormat(input.bytes);
        if (input_format == options.target.object_format) continue;
        if (options.diagnostics) |diagnostics| {
            diagnostics.recordUnsupportedInputFormat(
                input.name,
                input_format,
                options.target.object_format,
            );
        }
        return error.UnsupportedFormat;
    }
}

fn isMachO(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    return switch (std.mem.readInt(u32, bytes[0..4], .little)) {
        std.macho.MH_MAGIC,
        std.macho.MH_CIGAM,
        std.macho.MH_MAGIC_64,
        std.macho.MH_CIGAM_64,
        std.macho.FAT_MAGIC,
        std.macho.FAT_CIGAM,
        std.macho.FAT_MAGIC_64,
        std.macho.FAT_CIGAM_64,
        => true,
        else => false,
    };
}
