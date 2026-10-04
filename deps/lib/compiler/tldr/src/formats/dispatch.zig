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

test "object format detection recognizes supported object containers" {
    var coff_header = @as([@sizeOf(std.coff.Header)]u8, @splat(0));
    std.mem.writeInt(u16, coff_header[0..2], @backingInt(std.coff.IMAGE.FILE.MACHINE.AMD64), .little);

    try std.testing.expectEqual(root.model.ObjectFormat.elf, try detectObjectFormat(std.elf.MAGIC ++ "rest"));
    try std.testing.expectEqual(root.model.ObjectFormat.coff, try detectObjectFormat(&coff_header));
    try std.testing.expectError(error.UnsupportedFormat, detectObjectFormat("not an object"));
}

test "object format detection recognizes Mach-O container magics" {
    const macho_magics = [_]u32{
        std.macho.MH_MAGIC,
        std.macho.MH_CIGAM,
        std.macho.MH_MAGIC_64,
        std.macho.MH_CIGAM_64,
        std.macho.FAT_MAGIC,
        std.macho.FAT_CIGAM,
        std.macho.FAT_MAGIC_64,
        std.macho.FAT_CIGAM_64,
    };

    for (macho_magics) |magic| {
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, magic, .little);
        try std.testing.expectEqual(root.model.ObjectFormat.macho, try detectObjectFormat(&header));
    }
}

test "object parser dispatches ELF metadata" {
    const allocator = std.testing.allocator;
    const text = [_]u8{0xc3};
    const text_index: u16 = 1;
    const bytes = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(text_index),
            elf_object.Symbol.function("_start", text_index, 0, text.len),
        },
    });
    defer allocator.free(bytes);

    var parsed = try parseObject(allocator, .{ .name = "start.o", .bytes = bytes });
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(root.model.ObjectFormat.elf, parsed.target.object_format);
    try std.testing.expect(parsed.sections.len > text_index);
    try std.testing.expectEqualStrings(".text", parsed.sections[text_index].name);
    try std.testing.expectEqual(@as(u64, 16), parsed.sections[text_index].alignment);
    for (parsed.symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, "_start")) {
            try std.testing.expect(symbol.external);
            try std.testing.expect(!symbol.undefined);
            return;
        }
    }
    return error.MissingEntrySymbol;
}
