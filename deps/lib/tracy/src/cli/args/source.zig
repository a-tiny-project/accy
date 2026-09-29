const std = @import("std");
const tracy = @import("../../root.zig");
const scalar = @import("scalar.zig");
const types = @import("types.zig");

pub fn parse(args: []const []const u8) !types.SourceArgs {
    if (args.len == 0) return error.InvalidArguments;
    var parsed = types.SourceArgs{ .path = args[0] };
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
            parsed.options.sort = tracy.source.Sort.fromName(args[index]) orelse return error.UnsupportedSort;
        } else if (std.mem.eql(u8, args[index], "--min-total-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_total_ns = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--min-self-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_self_ns = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--thread")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.thread = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--match")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.match = args[index];
        } else if (std.mem.eql(u8, args[index], "--root")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.root = args[index];
        } else if (std.mem.eql(u8, args[index], "--context")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.context = try scalar.parseUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--context-back")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.context_back = try scalar.parseUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--ignore-case")) {
            parsed.options.ignore_case = true;
        } else {
            return error.UnknownArgument;
        }
    }
    return parsed;
}

test "source args parse filters and local context" {
    const parsed = try parse(&.{
        "events.jsonl",
        "--format",
        "jsonl",
        "--top",
        "12",
        "--sort",
        "file",
        "--min-total-ns",
        "100",
        "--min-self-ns",
        "20",
        "--thread",
        "7",
        "--match",
        "parse",
        "--root",
        "/tmp/project",
        "--context",
        "4",
        "--context-back",
        "1",
        "--ignore-case",
    });
    try std.testing.expectEqualStrings("events.jsonl", parsed.path);
    try std.testing.expectEqual(types.Format.jsonl, parsed.format);
    try std.testing.expectEqual(@as(usize, 12), parsed.options.top);
    try std.testing.expectEqual(tracy.source.Sort.file, parsed.options.sort);
    try std.testing.expectEqual(@as(u64, 100), parsed.options.min_total_ns);
    try std.testing.expectEqual(@as(u64, 20), parsed.options.min_self_ns);
    try std.testing.expectEqual(@as(?u64, 7), parsed.options.thread);
    try std.testing.expectEqualStrings("parse", parsed.options.match.?);
    try std.testing.expectEqualStrings("/tmp/project", parsed.options.root.?);
    try std.testing.expectEqual(@as(usize, 4), parsed.options.context);
    try std.testing.expectEqual(@as(usize, 1), parsed.options.context_back);
    try std.testing.expect(parsed.options.ignore_case);
}
