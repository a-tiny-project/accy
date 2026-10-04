const std = @import("std");
const testing = std.testing;
const macho = @import("root.zig");
const machine = @import("../root.zig").machine_code;

const text: [64]u8 = @splat(0xaa);
const words: [16]u8 = @splat(0xbb);
const definitions = [_]macho.TextSymbol{
    .{ .name = "_entry", .offset = 32, .size = 32, .binding = .global },
    .{ .name = "Lhelper", .offset = 0, .size = 32, .binding = .local },
};
const data = [_]machine.DataSymbol{
    .{ .name = "_image", .bytes = &words, .alignment = 8, .binding = .global },
    .{ .name = "_mutable", .bytes = &words, .alignment = 16, .section = .data },
    .{ .name = "Lreadonly", .bytes = "r", .alignment = 4096 },
    .{ .name = "_zero", .reserved_size = 1 << 40, .alignment = 16, .section = .bss },
};
const relocations = [_]macho.Relocation{
    .{ .offset = 0, .symbol = "_entry", .kind = .call },
    .{ .offset = 8, .symbol = "_external", .kind = .call },
    .{ .offset = 16, .symbol = "Lreadonly", .kind = .absolute, .addend = -8 },
    .{ .offset = 24, .symbol = "_zero", .kind = .absolute, .addend = 17 },
    .{ .offset = 56, .symbol = "_mutable", .kind = .absolute },
    .{ .section = .rodata, .offset = 0, .symbol = "Lhelper", .kind = .absolute, .addend = -1 },
    .{ .section = .data, .offset = 8, .symbol = "_external", .kind = .absolute, .addend = 3 },
};

fn fixture() macho.RelocatableObject {
    return .{
        .text = &text,
        .text_symbols = &definitions,
        .data_symbols = &data,
        .relocations = &relocations,
    };
}

fn value(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.bytesToValue(T, bytes[offset..][0..@sizeOf(T)]);
}

test "Choir Mach-O exact accounting and independent standard records" {
    var layout = try macho.Layout.init(testing.allocator, fixture());
    defer layout.deinit(testing.allocator);
    const bytes = try macho.buildRelocatableObject(testing.allocator, fixture());
    defer testing.allocator.free(bytes);
    const repeated = try macho.buildRelocatableObject(testing.allocator, fixture());
    defer testing.allocator.free(repeated);
    try testing.expectEqualSlices(u8, bytes, repeated);
    const counts = layout.byteCounts();
    try testing.expectEqual(bytes.len, counts.file);
    try testing.expectEqual(counts.file, counts.header_commands + counts.initialized_payload +
        counts.padding + counts.relocations + counts.symbols + counts.strings);
    try testing.expectEqual(@as(u64, 448), counts.header_commands);
    try testing.expectEqual(@as(u64, 1 << 40), counts.bss_reservation);
    try testing.expect(bytes.len < 16384);
    const header = value(std.macho.mach_header_64, bytes, 0);
    try testing.expectEqual(std.macho.MH_MAGIC_64, header.magic);
    try testing.expectEqual(std.macho.CPU_TYPE_ARM64, header.cputype);
    try testing.expectEqual(std.macho.MH_OBJECT, header.filetype);
    try testing.expectEqual(@as(u32, 2), header.ncmds);
    try testing.expectEqual(@as(u32, 416), header.sizeofcmds);
    try testing.expectEqual(@as(u32, 0), header.flags);
    const segment = value(std.macho.segment_command_64, bytes, 32);
    try testing.expectEqual(@as(u32, 4), segment.nsects);
    for (layout.sections, 0..) |expected, index| {
        const section = value(std.macho.section_64, bytes, 104 + 80 * index);
        try testing.expectEqual(expected.address, section.addr);
        try testing.expectEqual(expected.size, section.size);
        try testing.expectEqual(expected.file_offset, section.offset);
        try testing.expectEqual(@as(u32, @intCast(@ctz(expected.alignment))), section.@"align");
        try testing.expectEqual(@as(u64, 0), section.addr % expected.alignment);
        try testing.expectEqual(
            @as(u32, 0),
            section.offset % @as(u32, @intCast(expected.alignment)),
        );
        try testing.expectEqual(expected.relocation_count, section.nreloc);
    }
    const bss = value(std.macho.section_64, bytes, 344);
    try testing.expectEqual(@as(u32, 0), bss.offset);
    try testing.expectEqual(@as(u32, 1), bss.flags);
    const symtab = value(std.macho.symtab_command, bytes, 424);
    const names = [_][]const u8{
        "_entry",
        "Lhelper",
        "_image",
        "_mutable",
        "Lreadonly",
        "_zero",
        "_external",
    };
    try testing.expectEqual(names.len, symtab.nsyms);
    for (names, 0..) |name, index| {
        const symbol = value(std.macho.nlist_64, bytes, symtab.symoff + index * 16);
        const tail = bytes[symtab.stroff + symbol.n_strx ..];
        try testing.expectEqualStrings(name, std.mem.sliceTo(tail, 0));
        const external = index == 0 or index == 2 or index == 6;
        try testing.expectEqual(external, symbol.n_type.bits.ext);
        if (index == 6) {
            try testing.expectEqual(@as(u8, 0), symbol.n_sect);
            try testing.expectEqual(@as(u64, 0), symbol.n_value);
        } else {
            try testing.expect(symbol.n_sect >= 1 and symbol.n_sect <= 4);
        }
    }
    const expected_offsets = [_]u32{ 56, 24, 16, 8, 0 };
    const expected_targets = [_]u32{ 3, 5, 4, 6, 0 };
    for (expected_offsets, expected_targets, 0..) |offset, target, index| {
        const record = layout.sections[0].relocation_offset + index * 8;
        const address = std.mem.readInt(u32, bytes[record..][0..4], .little);
        const flags = std.mem.readInt(u32, bytes[record + 4 ..][0..4], .little);
        try testing.expectEqual(offset, address);
        try testing.expectEqual(target | (3 << 25) | (1 << 27), flags);
    }
    const code = bytes[layout.sections[0].file_offset..];
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, code[0..8], .little));
    try testing.expectEqual(
        @as(u64, @bitCast(@as(i64, -8))),
        std.mem.readInt(u64, code[16..24], .little),
    );
    try testing.expectEqual(@as(u64, 17), std.mem.readInt(u64, code[24..32], .little));
    try testing.expectEqual(@as(u8, 0xaa), code[32]);
}

test "Choir Mach-O short buffer and BSS extent do not publish or allocate file bytes" {
    var layout = try macho.Layout.init(testing.allocator, fixture());
    defer layout.deinit(testing.allocator);
    var short: [32]u8 = @splat(0x77);
    const outcome = layout.write(&short);
    try testing.expectEqual(layout.requiredBytes(), outcome.short_buffer.required);
    try testing.expectEqual(short.len, outcome.short_buffer.available);
    try testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0x77))), &short);
    var small_data = data;
    small_data[3].reserved_size = 1;
    var input = fixture();
    input.data_symbols = &small_data;
    var small = try macho.Layout.init(testing.allocator, input);
    defer small.deinit(testing.allocator);
    try testing.expectEqual(layout.requiredBytes(), small.requiredBytes());
    const empty = try macho.buildRelocatableObject(testing.allocator, .{ .text = &text });
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(u32, 0), value(std.macho.symtab_command, empty, 424).nsyms);
}

test "Choir Mach-O relocation and symbol admission refuses invalid source" {
    var input = fixture();
    var bad = relocations;
    input.relocations = &bad;
    for ([_]macho.Section{ .text, .rodata, .data }) |section| {
        bad = relocations;
        bad[0].section = section;
        bad[0].offset = if (section == .text) 57 else if (section == .rodata) 4090 else 9;
        try testing.expectError(
            error.InvalidRelocationOffset,
            macho.Layout.init(testing.allocator, input),
        );
    }
    for ([_]@TypeOf(bad[0].kind){ .unknown, .relative, .got, .plt }) |kind| {
        bad = relocations;
        bad[0].kind = kind;
        try testing.expectError(
            error.UnsupportedRelocation,
            macho.Layout.init(testing.allocator, input),
        );
    }
    bad = relocations;
    bad[0].section = .bss;
    try testing.expectError(
        error.UnsupportedRelocation,
        macho.Layout.init(testing.allocator, input),
    );
    bad = relocations;
    bad[0].width_bits = 32;
    try testing.expectError(
        error.UnsupportedRelocation,
        macho.Layout.init(testing.allocator, input),
    );
    bad = relocations;
    bad[0].addend = 1;
    try testing.expectError(
        error.UnsupportedRelocation,
        macho.Layout.init(testing.allocator, input),
    );
    for ([_]u64{ 0, 1, 7 }) |offset| {
        bad = relocations;
        bad[1].offset = offset;
        try testing.expectError(
            error.OverlappingRelocations,
            macho.Layout.init(testing.allocator, input),
        );
    }
    bad = relocations;
    bad[0].symbol = "bad\x00name";
    try testing.expectError(error.InvalidName, macho.Layout.init(testing.allocator, input));
    input = fixture();
    var duplicate = definitions;
    duplicate[1].name = duplicate[0].name;
    input.text_symbols = &duplicate;
    try testing.expectError(error.DuplicateSymbol, macho.Layout.init(testing.allocator, input));
    duplicate = definitions;
    duplicate[1].offset = 31;
    try testing.expectError(error.InvalidTextSymbol, macho.Layout.init(testing.allocator, input));
    input = fixture();
    input.text_alignment = 3;
    try testing.expectError(error.InvalidAlignment, macho.Layout.init(testing.allocator, input));
    var wrong_data = data;
    input = fixture();
    input.data_symbols = &wrong_data;
    wrong_data[0].reserved_size = 17;
    try testing.expectError(error.InvalidDataSymbol, macho.Layout.init(testing.allocator, input));
    wrong_data = data;
    wrong_data[3].reserved_size = std.math.maxInt(usize);
    try testing.expectError(error.ObjectSizeOverflow, macho.Layout.init(testing.allocator, input));
}

test "Choir Mach-O construction frees every failed allocation" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const bytes = try macho.buildRelocatableObject(allocator, fixture());
            defer allocator.free(bytes);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Harness.run, .{});
}

test "Choir Mach-O accounts and zeroes actual post-relocation alignment padding" {
    const input: macho.RelocatableObject = .{
        .text = text[0..9],
        .relocations = &.{.{ .offset = 0, .symbol = "address", .kind = .absolute }},
    };
    var layout = try macho.Layout.init(testing.allocator, input);
    defer layout.deinit(testing.allocator);
    const bytes = try macho.buildRelocatableObject(testing.allocator, input);
    defer testing.allocator.free(bytes);
    const section = value(std.macho.section_64, bytes, 104);
    const symtab = value(std.macho.symtab_command, bytes, 424);
    try testing.expectEqual(@as(u32, 448), section.offset);
    try testing.expectEqual(@as(u64, 9), section.size);
    try testing.expectEqual(@as(u32, 460), section.reloff);
    try testing.expectEqual(@as(u32, 1), section.nreloc);
    try testing.expectEqual(@as(u32, 472), symtab.symoff);
    for (bytes[457..460]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    for (bytes[468..472]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expectEqual(@as(u64, 7), layout.byteCounts().padding);
}
