const std = @import("std");
const composition = @import("root.zig");
const abi = @import("abi/test.zig");
const diagnostic = @import("diagnostic/test.zig");
const loaded = @import("loaded/test.zig");
const module = @import("module/test.zig");
const source = @import("source/test.zig");

test {
    std.testing.refAllDecls(composition);
    _ = abi;
    _ = diagnostic;
    _ = loaded;
    _ = module;
    _ = source;
}
