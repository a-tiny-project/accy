const std = @import("std");

const cli_filter_discovery_names = [_][]const u8{
    "namespace",
    "test_0",
};

pub fn merged(
    b: *std.Build,
    package_filters: []const []const u8,
) []const []const u8 {
    return mergeFilters(b.allocator, package_filters, requested(b));
}

pub fn focused(b: *std.Build) []const []const u8 {
    return mergeFilters(b.allocator, &.{}, requested(b));
}

pub fn requested(b: *std.Build) []const []const u8 {
    return optionFilters(b);
}

fn optionFilters(b: *std.Build) []const []const u8 {
    if (!b.available_options_map.contains("test-filter")) {
        return b.option(
            []const []const u8,
            "test-filter",
            "Filter tests by name; repeatable",
        ) orelse &.{};
    }
    const option = b.user_input_options.get("test-filter") orelse return &.{};
    return switch (option) {
        .scalar => |value| b.allocator.dupe(
            []const u8,
            &.{value},
        ) catch @panic("OOM"),
        .list => |values| values.items,
        else => &.{},
    };
}

pub fn mergeFilters(
    allocator: std.mem.Allocator,
    package_filters: []const []const u8,
    cli_filters: []const []const u8,
) []const []const u8 {
    if (cli_filters.len == 0) return package_filters;
    var filters: std.ArrayList([]const u8) = .empty;
    appendUnique(allocator, &filters, package_filters);
    appendUnique(allocator, &filters, cli_filters);
    appendUnique(allocator, &filters, &cli_filter_discovery_names);
    return filters.toOwnedSlice(allocator) catch @panic("OOM");
}

fn appendUnique(
    allocator: std.mem.Allocator,
    filters: *std.ArrayList([]const u8),
    candidates: []const []const u8,
) void {
    for (candidates) |candidate| {
        for (filters.items) |existing| {
            if (std.mem.eql(u8, existing, candidate)) break;
        } else {
            filters.append(allocator, candidate) catch @panic("OOM");
        }
    }
}

test "CLI test filters preserve namespace discovery filters" {
    const filters = mergeFilters(
        std.testing.allocator,
        &.{"source lowering"},
        &.{ "tensor type owns validated shape and computes byte count", "package namespace" },
    );
    defer std.testing.allocator.free(filters);

    try std.testing.expectEqual(@as(usize, 5), filters.len);
    try std.testing.expectEqualStrings("source lowering", filters[0]);
    try std.testing.expectEqualStrings("tensor type owns validated shape and computes byte count", filters[1]);
    try std.testing.expectEqualStrings("package namespace", filters[2]);
    try std.testing.expectEqualStrings("namespace", filters[3]);
    try std.testing.expectEqualStrings("test_0", filters[4]);
}

test "repeated option filters retain their order" {
    const filters = mergeFilters(
        std.testing.allocator,
        &.{ "parent first", "parent second" },
        &.{ "direct first", "direct second" },
    );
    defer std.testing.allocator.free(filters);

    try std.testing.expectEqual(@as(usize, 6), filters.len);
    try std.testing.expectEqualStrings("parent first", filters[0]);
    try std.testing.expectEqualStrings("parent second", filters[1]);
    try std.testing.expectEqualStrings("direct first", filters[2]);
    try std.testing.expectEqualStrings("direct second", filters[3]);
    try std.testing.expectEqualStrings("namespace", filters[4]);
    try std.testing.expectEqualStrings("test_0", filters[5]);
}
