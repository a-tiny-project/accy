const std = @import("std");
const tracy = @import("../../root.zig");
const scalar = @import("scalar.zig");
const types = @import("types.zig");

pub fn parse(args: []const []const u8) !types.GpuArgs {
    if (args.len == 0) return error.InvalidArguments;
    var parsed = types.GpuArgs{ .path = args[0] };
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
            parsed.options.group = tracy.gpu.Group.fromName(args[index]) orelse return error.UnsupportedGroup;
        } else if (std.mem.eql(u8, args[index], "--sort")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.sort = tracy.gpu.Sort.fromName(args[index]) orelse return error.UnsupportedSort;
        } else if (std.mem.eql(u8, args[index], "--context")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.context = @intCast(try scalar.parseU64(args[index]));
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
        } else if (std.mem.eql(u8, args[index], "--min-gpu-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_gpu_ns = try scalar.parseU64(args[index]);
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

test "gpu args parse filters window grouping and context id" {
    const parsed = try parse(&.{
        "events.jsonl",
        "--format",
        "jsonl",
        "--top",
        "12",
        "--occurrences",
        "4",
        "--group",
        "annotation",
        "--sort",
        "annotations",
        "--context",
        "2",
        "--thread",
        "7",
        "--around-ns",
        "1000",
        "--window-ns",
        "200",
        "--min-gpu-ns",
        "50",
        "--match",
        "draw",
        "--ignore-case",
    });
    try std.testing.expectEqualStrings("events.jsonl", parsed.path);
    try std.testing.expectEqual(types.Format.jsonl, parsed.format);
    try std.testing.expectEqual(@as(usize, 12), parsed.options.top);
    try std.testing.expectEqual(@as(usize, 4), parsed.options.occurrences);
    try std.testing.expectEqual(tracy.gpu.Group.annotation, parsed.options.group);
    try std.testing.expectEqual(tracy.gpu.Sort.annotations, parsed.options.sort);
    try std.testing.expectEqual(@as(?u32, 2), parsed.options.context);
    try std.testing.expectEqual(@as(?u64, 7), parsed.options.thread);
    try std.testing.expectEqual(@as(?u64, 900), parsed.options.since_ns);
    try std.testing.expectEqual(@as(?u64, 1100), parsed.options.until_ns);
    try std.testing.expectEqual(@as(u64, 50), parsed.options.min_gpu_ns);
    try std.testing.expectEqualStrings("draw", parsed.options.match.?);
    try std.testing.expect(parsed.options.ignore_case);
}

test "gpu args parse tail sorts" {
    const gpu_tail = try parse(&.{ "events.jsonl", "--sort", "gpu-tail" });
    try std.testing.expectEqual(tracy.gpu.Sort.gpu_tail, gpu_tail.options.sort);
    const cpu_tail = try parse(&.{ "events.jsonl", "--sort", "cpu-tail" });
    try std.testing.expectEqual(tracy.gpu.Sort.cpu_tail, cpu_tail.options.sort);
}
