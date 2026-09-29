const std = @import("std");
const tracy = @import("../../root.zig");
const scalar = @import("scalar.zig");
const types = @import("types.zig");

pub fn parse(args: []const []const u8) !types.FrameArgs {
    if (args.len == 0) return error.InvalidArguments;
    var parsed = types.FrameArgs{ .path = args[0] };
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
        } else if (std.mem.eql(u8, args[index], "--sort")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.sort = tracy.frame.Sort.fromName(args[index]) orelse
                return error.UnsupportedSort;
        } else if (std.mem.eql(u8, args[index], "--min-frame-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_frame_ns = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--budget-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.budget_ns = try scalar.parsePositiveU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--set")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.set = args[index];
        } else {
            return error.UnknownArgument;
        }
    }
    return parsed;
}

test "frame args parse filters and sort" {
    const parsed = try parse(&.{
        "events.jsonl",
        "--format",
        "jsonl",
        "--top",
        "12",
        "--sort",
        "mean",
        "--min-frame-ns",
        "100",
        "--budget-ns",
        "80",
        "--set",
        "main",
    });
    try std.testing.expectEqualStrings("events.jsonl", parsed.path);
    try std.testing.expectEqual(types.Format.jsonl, parsed.format);
    try std.testing.expectEqual(@as(usize, 12), parsed.options.top);
    try std.testing.expectEqual(tracy.frame.Sort.mean, parsed.options.sort);
    try std.testing.expectEqual(@as(u64, 100), parsed.options.min_frame_ns);
    try std.testing.expectEqual(@as(?u64, 80), parsed.options.budget_ns);
    try std.testing.expectEqualStrings("main", parsed.options.set.?);
}

test "frame args reject a zero budget" {
    try std.testing.expectError(
        error.InvalidArguments,
        parse(&.{ "events.jsonl", "--budget-ns", "0" }),
    );
}
