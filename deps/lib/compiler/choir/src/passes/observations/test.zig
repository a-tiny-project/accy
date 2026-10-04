//! When these observations are regenerated, review each changed IR, trace
//! event, and diagnostic before accepting it.
//! Each file retains input IR, every after-pass IR, ordered pipeline/pass/
//! analysis/statistic events, the result, and structured diagnostics.

const std = @import("std");
const fixture = @import("fixture/root.zig");

test "rewrite observations canonicalization select inverse IR trace and diagnostics" {
    try compare(.canonicalization_select_inverse, @embedFile("fixture/canonicalization.txt"));
}

test "rewrite observations CSE dominating and incomparable blocks IR trace and diagnostics" {
    try compare(.cse_dominating_and_incomparable_blocks, @embedFile("fixture/cse.txt"));
}

test "rewrite observations saturation identity extraction IR trace and diagnostics" {
    try compare(.saturation_identity_extraction, @embedFile("fixture/saturation.txt"));
}

test "rewrite observations verifier yield type diagnostic IR and trace" {
    try compare(.verifier_yield_type_diagnostic, @embedFile("fixture/diagnostic.txt"));
}

fn compare(selected: fixture.Fixture, expected: []const u8) !void {
    const actual = try fixture.collect(std.testing.allocator, selected);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
