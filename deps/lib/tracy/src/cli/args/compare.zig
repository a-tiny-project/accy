const std = @import("std");
const scalar = @import("scalar.zig");
const types = @import("types.zig");

pub fn parse(args: []const []const u8) !types.CompareArgs {
    if (args.len < 2) return error.InvalidArguments;
    var parsed = types.CompareArgs{
        .baseline_path = args[0],
        .run_path = args[1],
    };
    var index: usize = 2;
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
        } else if (std.mem.eql(u8, args[index], "--min-zone-delta-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_zone_delta_ns = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--frame-budget-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.frame_budget_ns = try scalar.parsePositiveU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--min-frame-delta-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_frame_delta_ns = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--min-gpu-delta-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_gpu_delta_ns = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--min-memory-delta-bytes")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_memory_delta_bytes = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--min-memory-lifetime-delta-ns")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_memory_lifetime_delta_ns = try scalar.parseU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--include-stable")) {
            parsed.options.include_stable = true;
        } else {
            return error.UnknownArgument;
        }
    }
    return parsed;
}

test "compare args parse filters and format" {
    const parsed = try parse(&.{
        "base.jsonl",
        "run.jsonl",
        "--format",
        "jsonl",
        "--top",
        "4",
        "--min-zone-delta-ns",
        "100",
        "--frame-budget-ns",
        "20",
        "--min-frame-delta-ns",
        "30",
        "--min-gpu-delta-ns",
        "40",
        "--min-memory-delta-bytes",
        "64",
        "--min-memory-lifetime-delta-ns",
        "80",
        "--include-stable",
    });
    try std.testing.expectEqualStrings("base.jsonl", parsed.baseline_path);
    try std.testing.expectEqualStrings("run.jsonl", parsed.run_path);
    try std.testing.expectEqual(types.Format.jsonl, parsed.format);
    try std.testing.expectEqual(@as(usize, 4), parsed.options.top);
    try std.testing.expectEqual(@as(u64, 100), parsed.options.min_zone_delta_ns);
    try std.testing.expectEqual(@as(?u64, 20), parsed.options.frame_budget_ns);
    try std.testing.expectEqual(@as(u64, 30), parsed.options.min_frame_delta_ns);
    try std.testing.expectEqual(@as(u64, 40), parsed.options.min_gpu_delta_ns);
    try std.testing.expectEqual(@as(u64, 64), parsed.options.min_memory_delta_bytes);
    try std.testing.expectEqual(
        @as(u64, 80),
        parsed.options.min_memory_lifetime_delta_ns,
    );
    try std.testing.expect(parsed.options.include_stable);
}
