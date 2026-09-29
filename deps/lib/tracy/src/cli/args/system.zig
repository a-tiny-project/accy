const std = @import("std");
const tracy = @import("../../root.zig");
const scalar = @import("scalar.zig");
const types = @import("types.zig");

pub fn parse(args: []const []const u8) !types.SystemArgs {
    if (args.len == 0) return error.InvalidArguments;
    var parsed = types.SystemArgs{ .path = args[0] };
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
            } else {
                return error.UnsupportedFormat;
            }
        } else if (std.mem.eql(u8, args[index], "--top")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.top = try scalar.parsePositiveUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--occurrences")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.occurrences = try scalar.parseUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--group")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.group = tracy.system.Group.fromName(args[index]) orelse return error.UnsupportedGroup;
        } else if (std.mem.eql(u8, args[index], "--sort")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.sort = tracy.system.Sort.fromName(args[index]) orelse return error.UnsupportedSort;
        } else if (std.mem.eql(u8, args[index], "--thread")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.thread = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--cpu")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.cpu = @intCast(try scalar.parseU64(args[index]));
        } else if (std.mem.eql(u8, args[index], "--address")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.address = try scalar.parseAddress(args[index]);
        } else if (std.mem.eql(u8, args[index], "--kind")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.kind = args[index];
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
        } else if (std.mem.eql(u8, args[index], "--ignore-case")) {
            parsed.options.ignore_case = true;
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

test "system args parse filters window grouping and address" {
    const parsed = try parse(&.{
        "events.jsonl",
        "--format",
        "jsonl",
        "--top",
        "12",
        "--occurrences",
        "4",
        "--group",
        "address",
        "--sort",
        "value",
        "--thread",
        "7",
        "--cpu",
        "2",
        "--address",
        "0x1234",
        "--kind",
        "hw",
        "--around-ns",
        "1000",
        "--window-ns",
        "200",
        "--match",
        "cache",
        "--ignore-case",
    });
    try std.testing.expectEqualStrings("events.jsonl", parsed.path);
    try std.testing.expectEqual(types.Format.jsonl, parsed.format);
    try std.testing.expectEqual(@as(usize, 12), parsed.options.top);
    try std.testing.expectEqual(@as(usize, 4), parsed.options.occurrences);
    try std.testing.expectEqual(tracy.system.Group.address, parsed.options.group);
    try std.testing.expectEqual(tracy.system.Sort.value, parsed.options.sort);
    try std.testing.expectEqual(@as(?u64, 7), parsed.options.thread);
    try std.testing.expectEqual(@as(?u32, 2), parsed.options.cpu);
    try std.testing.expectEqual(@as(?u64, 0x1234), parsed.options.address);
    try std.testing.expectEqualStrings("hw", parsed.options.kind.?);
    try std.testing.expectEqual(@as(?u64, 900), parsed.options.since_ns);
    try std.testing.expectEqual(@as(?u64, 1100), parsed.options.until_ns);
    try std.testing.expectEqualStrings("cache", parsed.options.match.?);
    try std.testing.expect(parsed.options.ignore_case);
}
