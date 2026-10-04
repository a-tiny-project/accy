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
    return optionFilters(b) catch |err|
        std.debug.panic("-Dtest-filter requires a non-empty value: {s}", .{@errorName(err)});
}

fn optionFilters(b: *std.Build) error{EmptyTestFilterValue}![]const []const u8 {
    const filters: []const []const u8 = if (!b.available_options_map.contains("test-filter"))
        b.option(
            []const []const u8,
            "test-filter",
            "Filter tests by name; repeatable",
        ) orelse &.{}
    else blk: {
        const option = b.user_input_options.get("test-filter") orelse return &.{};
        break :blk switch (option) {
            .scalar => |value| b.allocator.dupe([]const u8, &.{value}) catch @panic("OOM"),
            .list => |values| values.items,
            else => &.{},
        };
    };
    for (filters) |value| if (value.len == 0) return error.EmptyTestFilterValue;
    return filters;
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

fn testBuild(allocator: std.mem.Allocator) !*std.Build {
    const graph = try allocator.create(std.Build.Graph);
    graph.* = .{
        .io = std.Options.debug_io,
        .arena = allocator,
        .zig_exe = "zig",
        .environ_map = .init(allocator),
        .host = .{ .query = .{}, .result = @import("builtin").target },
        .generated_files = .empty,
        .wip_configuration = .init(allocator),
    };
    return std.Build.create(graph, .cwd(), &.{});
}
