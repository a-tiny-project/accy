const std = @import("std");
const tracy = @import("../../root.zig");
const scalar = @import("scalar.zig");
const types = @import("types.zig");

pub fn parse(args: []const []const u8) !types.PlotArgs {
    if (args.len == 0) return error.InvalidArguments;
    var parsed = types.PlotArgs{ .path = args[0] };
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
            parsed.options.sort = tracy.plots.Sort.fromName(args[index]) orelse return error.UnsupportedSort;
        } else if (std.mem.eql(u8, args[index], "--min-samples")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_samples = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--name")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.name = args[index];
        } else {
            return error.UnknownArgument;
        }
    }
    return parsed;
}

test "plot args parse filters and sort" {
    const parsed = try parse(&.{
        "events.jsonl",
        "--format",
        "jsonl",
        "--top",
        "12",
        "--sort",
        "range",
        "--min-samples",
        "4",
        "--name",
        "latency.ns",
    });
    try std.testing.expectEqualStrings("events.jsonl", parsed.path);
    try std.testing.expectEqual(types.Format.jsonl, parsed.format);
    try std.testing.expectEqual(@as(usize, 12), parsed.options.top);
    try std.testing.expectEqual(tracy.plots.Sort.range, parsed.options.sort);
    try std.testing.expectEqual(@as(u64, 4), parsed.options.min_samples);
    try std.testing.expectEqualStrings("latency.ns", parsed.options.name.?);
}
