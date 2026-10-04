const std = @import("std");
const document = @import("document.zig");
const escape = @import("escape.zig");
const field = @import("field.zig");
const format = @import("format.zig");
const scalar = @import("scalar.zig");
const sort = @import("sort.zig");
const stream = @import("stream.zig");

test {
    std.testing.refAllDecls(document);
    std.testing.refAllDecls(escape);
    std.testing.refAllDecls(field);
    std.testing.refAllDecls(format);
    std.testing.refAllDecls(scalar);
    std.testing.refAllDecls(sort);
    std.testing.refAllDecls(stream);
}
