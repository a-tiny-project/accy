const std = @import("std");
const tracy = @import("../../root.zig");
const scalar = @import("scalar.zig");
const types = @import("types.zig");

pub fn parse(args: []const []const u8) !types.FlameArgs {
    if (args.len == 0) return error.InvalidArguments;
    var parsed = types.FlameArgs{ .path = args[0] };
    var around_ns: ?u64 = null;
    var window_ns: ?u64 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--format")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            if (std.mem.eql(u8, args[index], "text")) {
                parsed.format = .text;
            } else if (std.mem.eql(u8, args[index], "jsonl")) {
                parsed.format = .jsonl;
            } else if (std.mem.eql(u8, args[index], "folded")) {
                parsed.format = .folded;
            } else {
                return error.UnsupportedFormat;
            }
        } else if (std.mem.eql(u8, args[index], "--top")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.top = try scalar.parsePositiveUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--sort")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.sort = tracy.flame.Sort.fromName(args[index]) orelse return error.UnsupportedSort;
        } else if (std.mem.eql(u8, args[index], "--max-depth")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.max_depth = try scalar.parseUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--min-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_ns = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--thread")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.thread = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--since-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.since_ns = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--until-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.until_ns = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--around-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            around_ns = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--window-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            window_ns = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--match")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.match = args[index];
        } else {
            return error.UnknownArgument;
        }
    }
    if (around_ns) |center| {
        if (parsed.options.since_ns != null or parsed.options.until_ns != null) return error.InvalidArguments;
        const width = window_ns orelse 1_000_000;
        const half = width / 2;
        parsed.options.since_ns = if (center > half) center - half else 0;
        parsed.options.until_ns = center +| (width - half);
    } else if (window_ns != null) {
        return error.InvalidArguments;
    }
    if (parsed.options.since_ns != null and parsed.options.until_ns != null and parsed.options.since_ns.? > parsed.options.until_ns.?) {
        return error.InvalidArguments;
    }
    return parsed;
}

test "flame args parse filters window and folded format" {
    const parsed = try parse(&.{
        "events.jsonl",
        "--format",
        "folded",
        "--top",
        "12",
        "--sort",
        "name",
        "--max-depth",
        "4",
        "--min-ns",
        "50",
        "--thread",
        "7",
        "--around-ns",
        "1000",
        "--window-ns",
        "200",
        "--match",
        "phase",
    });
    try std.testing.expectEqualStrings("events.jsonl", parsed.path);
    try std.testing.expectEqual(types.FlameFormat.folded, parsed.format);
    try std.testing.expectEqual(@as(usize, 12), parsed.options.top);
    try std.testing.expectEqual(tracy.flame.Sort.name, parsed.options.sort);
    try std.testing.expectEqual(@as(usize, 4), parsed.options.max_depth);
    try std.testing.expectEqual(@as(u64, 50), parsed.options.min_ns);
    try std.testing.expectEqual(@as(?u64, 7), parsed.options.thread);
    try std.testing.expectEqual(@as(?u64, 900), parsed.options.since_ns);
    try std.testing.expectEqual(@as(?u64, 1100), parsed.options.until_ns);
    try std.testing.expectEqualStrings("phase", parsed.options.match.?);
}
