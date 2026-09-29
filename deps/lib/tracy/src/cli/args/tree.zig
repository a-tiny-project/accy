const std = @import("std");
const scalar = @import("scalar.zig");
const types = @import("types.zig");

pub fn parse(args: []const []const u8) !types.TreeArgs {
    if (args.len == 0) return error.InvalidArguments;
    var parsed = types.TreeArgs{ .path = args[0] };
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
        } else if (std.mem.eql(u8, args[index], "--max-depth")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.max_depth = try scalar.parseUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--min-duration-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_duration_ns = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--thread")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.thread = try scalar.parseU64(args[index]);
        } else {
            return error.UnknownArgument;
        }
    }
    return parsed;
}

test "tree args parse filters and format" {
    const parsed = try parse(&.{
        "events.jsonl",
        "--format",
        "jsonl",
        "--top",
        "12",
        "--max-depth",
        "3",
        "--min-duration-ns",
        "100",
        "--thread",
        "7",
    });
    try std.testing.expectEqualStrings("events.jsonl", parsed.path);
    try std.testing.expectEqual(types.Format.jsonl, parsed.format);
    try std.testing.expectEqual(@as(usize, 12), parsed.options.top);
    try std.testing.expectEqual(@as(usize, 3), parsed.options.max_depth);
    try std.testing.expectEqual(@as(u64, 100), parsed.options.min_duration_ns);
    try std.testing.expectEqual(@as(?u64, 7), parsed.options.thread);
}
