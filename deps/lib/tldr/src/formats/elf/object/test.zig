const std = @import("std");

const tldr = @import("../../../root.zig");
const elf = @import("../root.zig");
const object = @import("root.zig");

const Section = object.Section;
const Symbol = object.Symbol;
const Relocation = object.Relocation;

test {
    std.testing.refAllDecls(object);
}

const text_bytes = "\x31\xc0\xc3\x90";
const data_bytes = "\x01\x02\x03\x04\x05\x06\x07\x08";

test "ELF object round trips through the parser and the linker" {
    const allocator = std.testing.allocator;
    const bytes = try object.build(allocator, .{
        .sections = &.{
            Section.progbits(".text", text_bytes, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".data", data_bytes, std.elf.SHF_WRITE, 8),
            Section.nobits(".bss", 32, std.elf.SHF_WRITE, 8),
        },
        .symbols = &.{
            Symbol.section(1),
            Symbol.section(2),
            Symbol.function("_start", 1, 0, 4),
            Symbol.object("counter", 2, 0, 8),
        },
        .relocations = &.{Relocation.x86_64(2, 0, 3, .@"64", 0)},
    });
    defer allocator.free(bytes);

    var parsed = try tldr.parseObject(allocator, .{ .name = "object.o", .bytes = bytes });
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(tldr.model.Architecture.x86_64, parsed.target.architecture);
    try std.testing.expect(findSection(parsed, ".text") != null);
    try std.testing.expect(findSection(parsed, ".bss") != null);
    try std.testing.expect(findSymbol(parsed, "_start") != null);
    try std.testing.expect(findSymbol(parsed, "counter") != null);

    const inputs = [_]tldr.Input{.{ .name = "object.o", .bytes = bytes }};
    var linked = try elf.linkExecutable(allocator, &inputs, .{});
    defer linked.deinit(allocator);

    const image = try elf.view.View.parse(linked.bytes);
    try std.testing.expectEqual(std.elf.ET.EXEC, image.header.type);
    try std.testing.expect(image.header.phnum != 0);
    try std.testing.expect((try image.find(".text")) != null);
}

fn findSection(parsed: tldr.Object, name: []const u8) ?tldr.ObjectSection {
    for (parsed.sections) |section| {
        if (std.mem.eql(u8, section.name, name)) return section;
    }
    return null;
}

fn findSymbol(parsed: tldr.Object, name: []const u8) ?tldr.ObjectSymbol {
    for (parsed.symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return symbol;
    }
    return null;
}
