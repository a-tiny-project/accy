const std = @import("std");
const pretty = @import("pretty");
const sys = @import("sys");

const stats = @import("stats/root.zig");
const OutputTestEvaluation = union(enum) {
    automatic: struct { evals: u32 },
    fixed: u32,
};
const OutputTestAllocationAttribution = enum {
    none,
    sample_call,
    prepare_owner,
};
const result_header =
    "benchmark                               samples        batch       median" ++
    "          median ci        p75        p99        mean/sd" ++
    "            min..max   alloc owner   alloc/free  alloc bytes";
const result_rule =
    "--------------------------------------------------------------------------------" ++
    "--------------------------------------------------------------------------------" ++
    "--------------------------";

pub fn writeHeader() !void {
    const parts = [_]pretty.Doc{
        pretty.hardline,
        .{ .text = result_header },
        pretty.hardline,
        .{ .text = result_rule },
        pretty.hardline,
    };
    try writeStdoutDoc(.{ .concat = &parts });
}

pub fn writeResult(result: anytype) !void {
    var line_buf: [512]u8 = undefined;
    const line = try formatResultLine(&line_buf, result);
    try writeStdoutDoc(.{ .text = line });
}

pub fn section(comptime name: []const u8) void {
    const parts = [_]pretty.Doc{
        pretty.hardline,
        .{ .text = "== " },
        .{ .text = name },
        .{ .text = " ==" },
        pretty.hardline,
    };
    writeStdoutDoc(.{ .concat = &parts }) catch {};
    writeHeader() catch {};
}

pub fn stdout(comptime fmt: []const u8, args: anytype) void {
    writeStdoutFmt(fmt, args) catch {};
}

pub fn stderr(comptime fmt: []const u8, args: anytype) void {
    writeStderrFmt(fmt, args) catch {};
}

pub fn writeStdoutFmt(comptime fmt: []const u8, args: anytype) !void {
    try writeFileFmt(.stdout, fmt, args);
}

pub fn writeStderrFmt(comptime fmt: []const u8, args: anytype) !void {
    try writeFileFmt(.stderr, fmt, args);
}

pub fn writeStdoutDoc(doc: pretty.Doc) !void {
    try writeFileDoc(.stdout, doc);
}

pub fn writeStderrDoc(doc: pretty.Doc) !void {
    try writeFileDoc(.stderr, doc);
}

fn formatResultLine(line_buf: []u8, result: anytype) ![]u8 {
    var avg_buf: [16]u8 = undefined;
    var sd_buf: [16]u8 = undefined;
    var median_buf: [16]u8 = undefined;
    var median_ci_buf: [40]u8 = undefined;
    var min_buf: [16]u8 = undefined;
    var max_buf: [16]u8 = undefined;
    var p75_buf: [16]u8 = undefined;
    var p99_buf: [16]u8 = undefined;
    var alloc_buf: [32]u8 = undefined;
    var bytes_buf: [32]u8 = undefined;
    var evaluation_buf: [32]u8 = undefined;

    const avg_str = fmtTime(&avg_buf, result.mean_ns);
    const sd_str = fmtTime(&sd_buf, result.stddev_ns);
    const median_str = fmtTime(&median_buf, @floatFromInt(result.median_ns));
    const median_ci_str = fmtMedianInterval(&median_ci_buf, result);
    const min_str = fmtTime(&min_buf, @floatFromInt(result.min_ns));
    const max_str = fmtTime(&max_buf, @floatFromInt(result.max_ns));
    const p75_str = fmtTime(&p75_buf, @floatFromInt(result.p75_ns));
    const p99_str = fmtTime(&p99_buf, @floatFromInt(result.p99_ns));
    const alloc_count = if (@hasField(@TypeOf(result), "alloc_count_per_eval"))
        result.alloc_count_per_eval orelse result.alloc_count
    else
        result.alloc_count;
    const free_count = if (@hasField(@TypeOf(result), "free_count_per_eval"))
        result.free_count_per_eval orelse result.free_count
    else
        result.free_count;
    const alloc_bytes = if (@hasField(@TypeOf(result), "alloc_bytes_per_eval"))
        result.alloc_bytes_per_eval orelse result.alloc_bytes
    else
        result.alloc_bytes;
    const alloc_str = fmtAllocPair(&alloc_buf, alloc_count, free_count);
    const bytes_str = fmtOptionalBytes(&bytes_buf, alloc_bytes);
    const evaluation_str = fmtEvaluation(&evaluation_buf, result);
    const allocation_attribution = fmtAllocationAttribution(result);

    var avg_sd_buf: [40]u8 = undefined;
    const avg_sd = std.fmt.bufPrint(&avg_sd_buf, "{s} +/- {s}", .{ avg_str, sd_str }) catch "???";

    var range_buf: [40]u8 = undefined;
    const range = std.fmt.bufPrint(&range_buf, "({s} ... {s})", .{ min_str, max_str }) catch "???";

    return try std.fmt.bufPrint(
        line_buf,
        "{s:<39} {d:>10} {s:>12} {s:>12} {s:>18} {s:>10} {s:>10} {s:>22} {s:>20} {s:>13} {s:>12} {s:>12}\n",
        .{
            result.name,
            result.iterations,
            evaluation_str,
            median_str,
            median_ci_str,
            p75_str,
            p99_str,
            avg_sd,
            range,
            allocation_attribution,
            alloc_str,
            bytes_str,
        },
    );
}

fn fmtAllocationAttribution(result: anytype) []const u8 {
    if (comptime @hasField(@TypeOf(result), "allocation_attribution")) {
        return switch (result.allocation_attribution) {
            .none => "-",
            .sample_call => "sample-call",
            .prepare_owner => "prepare-owner",
        };
    }
    return "-";
}

fn fmtEvaluation(buf: []u8, result: anytype) []const u8 {
    if (comptime @hasField(@TypeOf(result), "evaluation")) {
        return switch (result.evaluation) {
            .automatic => |selection| std.fmt.bufPrint(
                buf,
                "auto:{d}",
                .{selection.evals},
            ) catch "?",
            .fixed => |evals| std.fmt.bufPrint(buf, "fixed:{d}", .{evals}) catch "?",
        };
    }
    if (comptime @hasField(@TypeOf(result), "evals")) {
        return std.fmt.bufPrint(buf, "{d}", .{result.evals}) catch "?";
    }
    return "-";
}

fn fmtMedianInterval(buf: []u8, result: anytype) []const u8 {
    if (comptime @hasField(@TypeOf(result), "confidence_intervals")) {
        if (result.confidence_intervals) |intervals| {
            return fmtTimeInterval(buf, intervals.median_ns.low_ns, intervals.median_ns.high_ns);
        }
    }
    return "-";
}

fn fmtTimeInterval(buf: []u8, low_ns: f64, high_ns: f64) []const u8 {
    var low_buf: [16]u8 = undefined;
    var high_buf: [16]u8 = undefined;
    const low = fmtTime(&low_buf, low_ns);
    const high = fmtTime(&high_buf, high_ns);
    return std.fmt.bufPrint(buf, "{s}..{s}", .{ low, high }) catch "?";
}

fn fmtAllocPair(buf: []u8, alloc_count: ?u64, free_count: ?u64) []const u8 {
    const allocs = alloc_count orelse return "-";
    const frees = free_count orelse return "-";
    return std.fmt.bufPrint(buf, "{d}/{d}", .{ allocs, frees }) catch "?";
}

fn fmtOptionalBytes(buf: []u8, alloc_bytes: ?u64) []const u8 {
    const bytes = alloc_bytes orelse return "-";
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch "?";
    if (bytes < 1024 * 1024) {
        const kib = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.1}KiB", .{kib}) catch "?";
    }
    if (bytes < 1024 * 1024 * 1024) {
        const mib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1}MiB", .{mib}) catch "?";
    }
    const gib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
    return std.fmt.bufPrint(buf, "{d:.1}GiB", .{gib}) catch "?";
}

fn fmtTime(buf: []u8, ns: f64) []const u8 {
    if (ns < 1_000) {
        return std.fmt.bufPrint(buf, "{d:.0}ns", .{ns}) catch "?";
    } else if (ns < 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.1}us", .{ns / 1_000.0}) catch "?";
    } else if (ns < 1_000_000_000) {
        return std.fmt.bufPrint(buf, "{d:.2}ms", .{ns / 1_000_000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.2}s", .{ns / 1_000_000_000.0}) catch "?";
    }
}

const OutputTarget = enum {
    stdout,
    stderr,
};

fn writeFileFmt(target: OutputTarget, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [8192]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, fmt, args);
    try writeFileDoc(target, .{ .text = text });
}

fn writeFileDoc(target: OutputTarget, doc: pretty.Doc) !void {
    const file = switch (target) {
        .stdout => sys.stdio.stdout(),
        .stderr => sys.stdio.stderr(),
    };
    try writeDocToFile(file, doc);
}

fn writeDocToFile(file: std.Io.File, doc: pretty.Doc) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writerStreaming(sys.stdio.debugIo(), &buffer);
    try pretty.write(&file_writer.interface, doc, .{});
    try file_writer.interface.flush();
}

test "time formatting ranges" {
    var buf: [16]u8 = undefined;
    const ns = fmtTime(&buf, 500);
    try std.testing.expect(std.mem.endsWith(u8, ns, "ns"));

    var buf2: [16]u8 = undefined;
    const us = fmtTime(&buf2, 5_000);
    try std.testing.expect(std.mem.endsWith(u8, us, "us"));

    var buf3: [16]u8 = undefined;
    const ms = fmtTime(&buf3, 5_000_000);
    try std.testing.expect(std.mem.endsWith(u8, ms, "ms"));
}

test "streaming document writes preserve regular file contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = sys.stdio.debugIo();
    const file = try tmp.dir.createFile(io, "output.txt", .{ .read = true });
    defer file.close(io);

    try writeDocToFile(file, .{ .text = "first" });
    try writeDocToFile(file, .{ .text = " second" });

    var contents: [32]u8 = undefined;
    const length = try file.readPositionalAll(io, &contents, 0);
    try std.testing.expectEqualStrings("first second", contents[0..length]);
}

test "result line renders timing and allocation columns" {
    const row = .{
        .name = "alloc",
        .iterations = @as(u32, 2),
        .evaluation = OutputTestEvaluation{ .automatic = .{ .evals = 4 } },
        .mean_ns = @as(f64, 1_500),
        .median_ns = @as(u64, 1_500),
        .stddev_ns = @as(f64, 500),
        .min_ns = @as(u64, 1_000),
        .max_ns = @as(u64, 2_000),
        .p75_ns = @as(u64, 1_750),
        .p99_ns = @as(u64, 2_000),
        .confidence_intervals = @as(?stats.BootstrapConfidenceIntervals, null),
        .allocation_attribution = OutputTestAllocationAttribution.prepare_owner,
        .alloc_count = @as(?u64, 2),
        .free_count = @as(?u64, 2),
        .alloc_bytes = @as(?u64, 64),
    };
    var line_buf: [512]u8 = undefined;
    const line = try formatResultLine(&line_buf, row);

    try std.testing.expect(std.mem.indexOf(u8, line, "alloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "auto:4") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "1.5us") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "1.5us +/- 500ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "(1.0us ... 2.0us)") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "prepare-owner") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "2/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "64B") != null);
}

test "result line renders median confidence interval when present" {
    const row = .{
        .name = "uncertain",
        .iterations = @as(u32, 4),
        .mean_ns = @as(f64, 1_500),
        .median_ns = @as(u64, 1_500),
        .stddev_ns = @as(f64, 500),
        .min_ns = @as(u64, 1_000),
        .max_ns = @as(u64, 2_000),
        .p75_ns = @as(u64, 1_750),
        .p99_ns = @as(u64, 2_000),
        .confidence_intervals = @as(?stats.BootstrapConfidenceIntervals, .{
            .confidence = 0.95,
            .iterations = 1000,
            .seed = 7,
            .mean_ns = .{ .low_ns = 1_000, .high_ns = 2_000 },
            .median_ns = .{ .low_ns = 1_000, .high_ns = 2_000 },
            .p75_ns = .{ .low_ns = 1_500, .high_ns = 2_000 },
            .p95_ns = .{ .low_ns = 2_000, .high_ns = 2_000 },
            .p99_ns = .{ .low_ns = 2_000, .high_ns = 2_000 },
        }),
        .alloc_count = @as(?u64, null),
        .free_count = @as(?u64, null),
        .alloc_bytes = @as(?u64, null),
    };
    var line_buf: [512]u8 = undefined;
    const line = try formatResultLine(&line_buf, row);

    try std.testing.expect(std.mem.indexOf(u8, line, "1.0us..2.0us") != null);
}

test "missing allocation columns render as dashes" {
    const row = .{
        .name = "noop",
        .iterations = @as(u32, 1),
        .mean_ns = @as(f64, 10),
        .median_ns = @as(u64, 10),
        .stddev_ns = @as(f64, 0),
        .min_ns = @as(u64, 10),
        .max_ns = @as(u64, 10),
        .p75_ns = @as(u64, 10),
        .p99_ns = @as(u64, 10),
        .alloc_count = @as(?u64, null),
        .free_count = @as(?u64, null),
        .alloc_bytes = @as(?u64, null),
    };
    var line_buf: [512]u8 = undefined;
    const line = try formatResultLine(&line_buf, row);

    try std.testing.expect(std.mem.indexOf(u8, line, "noop") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, " -            -") != null);
}
