const std = @import("std");
const tracy = @import("../../root.zig");
const scalar = @import("scalar.zig");
const types = @import("types.zig");

pub fn parse(args: []const []const u8) !types.MemoryArgs {
    if (args.len == 0) return error.InvalidArguments;
    var parsed = types.MemoryArgs{ .path = args[0] };
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
            parsed.options.occurrences = try scalar.parsePositiveUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--sort")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.sort = tracy.memory.Sort.fromName(args[index]) orelse return error.UnsupportedSort;
        } else if (std.mem.eql(u8, args[index], "--min-live-bytes")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_live_bytes = try scalar.parseU64(args[index]);
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

test "memory args parse filters and sort" {
    const parsed = try parse(&.{
        "events.jsonl",
        "--format",
        "jsonl",
        "--top",
        "12",
        "--occurrences",
        "7",
        "--sort",
        "lifetime-tail",
        "--min-live-bytes",
        "100",
        "--name",
        "arena",
    });
    try std.testing.expectEqualStrings("events.jsonl", parsed.path);
    try std.testing.expectEqual(types.Format.jsonl, parsed.format);
    try std.testing.expectEqual(@as(usize, 12), parsed.options.top);
    try std.testing.expectEqual(@as(usize, 7), parsed.options.occurrences);
    try std.testing.expectEqual(tracy.memory.Sort.lifetime_tail, parsed.options.sort);
    try std.testing.expectEqual(@as(u64, 100), parsed.options.min_live_bytes);
    try std.testing.expectEqualStrings("arena", parsed.options.name.?);
}
