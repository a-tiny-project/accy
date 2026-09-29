const std = @import("std");
const options = @import("transport_options");

test "custom target dependency options preserve object format and dynamic linker" {
    try std.testing.expectEqualStrings(
        options.expected_dynamic_linker,
        options.actual_dynamic_linker,
    );
    try std.testing.expectEqual(options.expected_ofmt, options.actual_ofmt);
}
