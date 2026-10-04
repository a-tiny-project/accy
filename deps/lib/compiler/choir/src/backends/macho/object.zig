const std = @import("std");
const macho = @import("root.zig");

/// Allocates exactly the measured file extent. Every scratch owner is released before return.
pub fn buildRelocatableObject(
    allocator: std.mem.Allocator,
    input: macho.RelocatableObject,
) macho.ObjectError![]u8 {
    var layout = try macho.Layout.init(allocator, input);
    defer layout.deinit(allocator);
    const output = try allocator.alloc(u8, layout.requiredBytes());
    errdefer allocator.free(output);
    switch (layout.write(output)) {
        .written => {},
        .short_buffer => unreachable,
    }
    return output;
}
