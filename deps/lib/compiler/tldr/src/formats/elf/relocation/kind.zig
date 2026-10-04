const std = @import("std");
const elf = @import("../root.zig");

const ObjectFile = elf.parser.ObjectFile;
const Symbol = elf.format.Symbol;
const Rela = elf.format.Rela;

pub fn isNone(relocation: Rela) bool {
    return relocation.relocationType() == @backingInt(std.elf.R_X86_64.NONE);
}

pub fn applicationSupported(relocation_type: u32) bool {
    return switch (relocation_type) {
        @backingInt(std.elf.R_X86_64.NONE),
        @backingInt(std.elf.R_X86_64.@"64"),
        @backingInt(std.elf.R_X86_64.@"32"),
        @backingInt(std.elf.R_X86_64.@"32S"),
        @backingInt(std.elf.R_X86_64.@"16"),
        @backingInt(std.elf.R_X86_64.@"8"),
        @backingInt(std.elf.R_X86_64.PC64),
        @backingInt(std.elf.R_X86_64.PC32),
        @backingInt(std.elf.R_X86_64.PLT32),
        @backingInt(std.elf.R_X86_64.PC16),
        @backingInt(std.elf.R_X86_64.PC8),
        @backingInt(std.elf.R_X86_64.GOTPCREL),
        @backingInt(std.elf.R_X86_64.GOTPCRELX),
        @backingInt(std.elf.R_X86_64.REX_GOTPCRELX),
        @backingInt(std.elf.R_X86_64.SIZE32),
        @backingInt(std.elf.R_X86_64.SIZE64),
        @backingInt(std.elf.R_X86_64.TPOFF32),
        @backingInt(std.elf.R_X86_64.TPOFF64),
        @backingInt(std.elf.R_X86_64.DTPOFF32),
        @backingInt(std.elf.R_X86_64.DTPOFF64),
        @backingInt(std.elf.R_X86_64.GOTTPOFF),
        @backingInt(std.elf.R_X86_64.TLSGD),
        @backingInt(std.elf.R_X86_64.TLSLD),
        => true,
        else => false,
    };
}

test "application support pins the apply switch arms" {
    try std.testing.expect(applicationSupported(@backingInt(std.elf.R_X86_64.NONE)));
    try std.testing.expect(applicationSupported(@backingInt(std.elf.R_X86_64.PC32)));
    try std.testing.expect(applicationSupported(@backingInt(std.elf.R_X86_64.REX_GOTPCRELX)));
    try std.testing.expect(applicationSupported(@backingInt(std.elf.R_X86_64.TLSLD)));
    try std.testing.expect(!applicationSupported(@backingInt(std.elf.R_X86_64.GOT32)));
    try std.testing.expect(!applicationSupported(@backingInt(std.elf.R_X86_64.COPY)));
    try std.testing.expect(!applicationSupported(@backingInt(std.elf.R_X86_64.JUMP_SLOT)));
    try std.testing.expect(!applicationSupported(@backingInt(std.elf.R_X86_64.TLSDESC)));
}

pub fn isRelaxedTlsRuntimeResolver(object: ObjectFile, relocations: []const Rela, relocation_index: usize) bool {
    const relocation = relocations[relocation_index];
    if (!isTlsRuntimeResolverRelocationType(relocation.relocationType())) return false;
    if (relocation.symbolIndex() >= object.symbols.len) return false;
    if (!isTlsRuntimeResolverSymbol(object.symbols[@intCast(relocation.symbolIndex())])) return false;

    var index = relocation_index;
    while (index > 0) {
        index -= 1;
        const marker = relocations[index];
        if (isNone(marker)) continue;
        if (!isTlsDynamicModelRelocationType(marker.relocationType())) return false;
        if (relocation.offset <= marker.offset) return false;
        return relocation.offset - marker.offset <= 12;
    }
    return false;
}

fn isTlsRuntimeResolverRelocationType(relocation_type: u32) bool {
    return switch (relocation_type) {
        @backingInt(std.elf.R_X86_64.PLT32),
        @backingInt(std.elf.R_X86_64.GOTPCREL),
        @backingInt(std.elf.R_X86_64.GOTPCRELX),
        @backingInt(std.elf.R_X86_64.REX_GOTPCRELX),
        => true,
        else => false,
    };
}

fn isTlsDynamicModelRelocationType(relocation_type: u32) bool {
    return switch (relocation_type) {
        @backingInt(std.elf.R_X86_64.TLSGD),
        @backingInt(std.elf.R_X86_64.TLSLD),
        => true,
        else => false,
    };
}

fn isTlsRuntimeResolverSymbol(symbol: Symbol) bool {
    return std.mem.eql(u8, symbol.name, "__tls_get_addr");
}
