const std = @import("std");

const elf_suite = @import("elf/test.zig");
const formats = @import("root.zig");

test {
    std.testing.refAllDecls(elf_suite);
    std.testing.refAllDecls(formats);
}
