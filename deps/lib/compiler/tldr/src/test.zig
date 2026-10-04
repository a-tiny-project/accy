const std = @import("std");

const formats_suite = @import("formats/test.zig");
const incremental_suite = @import("incremental/test.zig");
const linker = @import("link.zig");
const loader = @import("load.zig");
const tldr = @import("root.zig");

test {
    std.testing.refAllDecls(formats_suite);
    std.testing.refAllDecls(incremental_suite);
    std.testing.refAllDecls(linker);
    std.testing.refAllDecls(loader);
    std.testing.refAllDecls(tldr);
}
