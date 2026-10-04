const std = @import("std");

const macho_suite = @import("macho/test.zig");
const elf_suite = @import("elf/test.zig");
const formats = @import("root.zig");

test {
    std.testing.refAllDecls(elf_suite);
    std.testing.refAllDecls(macho_suite);
    std.testing.refAllDecls(formats);
}
