const std = @import("std");
const pretty = @import("pretty");
const conjecture = @import("conjecture.zig");
const engine = @import("engine.zig");

const ChoiceNode = conjecture.ChoiceNode;
const TestResult = engine.TestResult;

pub fn printPropertyFailure(result: *const TestResult) void {
    var arena = std.heap.ArenaAllocator.init(result.allocator);
    defer arena.deinit();
    var report = propertyFailureReport(arena.allocator(), result) catch return;
    defer report.deinit();
    pretty.diagnostic.writeStderr(&report, .{ .width = 100 });
}

pub fn writePropertyFailure(writer: *std.Io.Writer, result: *const TestResult) !void {
    var arena = std.heap.ArenaAllocator.init(result.allocator);
    defer arena.deinit();
    var report = try propertyFailureReport(arena.allocator(), result);
    defer report.deinit();
    try report.write(writer, .{ .width = 100 });
    try writer.writeByte('\n');
}

fn propertyFailureReport(
    allocator: std.mem.Allocator,
    result: *const TestResult,
) !pretty.diagnostic.Report {
    var report = try pretty.diagnostic.Report.init(allocator, "Property failed");
    errdefer report.deinit();
    if (result.failing_error) |err| {
        try report.field("Error", "{s}", .{@errorName(err)});
    }
    try report.field("Seed", "{}", .{result.seed});
    try report.section("Settings");
    try report.line(".seed = {},", .{result.seed});
    if (result.database_path) |path| {
        try report.line(".database_path = \"{s}\",", .{path});
    } else {
        try report.line(".database_path = null,", .{});
    }
    if (result.database_namespace) |namespace| {
        try report.line(".database_namespace = \"{s}\",", .{namespace});
    } else {
        try report.line(".database_namespace = null,", .{});
    }
    try report.line(".max_examples = {},", .{result.max_examples});
    try report.line(".max_replays = {},", .{result.max_replays});
    try report.line(".max_choices = {},", .{result.max_choices});
    try report.line(".max_input_bytes = {},", .{result.max_input_bytes});
    try report.line(".max_shrinks = {},", .{result.max_shrinks});
    try report.line(".target_examples = {},", .{result.target_examples});
    try report.line(".per_example_leak_check = {},", .{result.per_example_leak_check});
    try report.field(
        "Replay corpus",
        "{} executed, {} entries scanned, {} rejected, saturated={}",
        .{
            result.replayed_examples,
            result.database_entries_scanned,
            result.database_failures_rejected,
            result.replay_budget_saturated,
        },
    );
    try addReplayHints(&report, result);
    if (result.failing_choices) |choices| {
        try addChoices(&report, "Minimal counterexample", choices);
    }
    if (result.failing_byte_blocks) |blocks| {
        try addByteBlocks(&report, blocks);
    }
    return report;
}

pub fn printStatefulFailure(result: *const TestResult) void {
    var arena = std.heap.ArenaAllocator.init(result.allocator);
    defer arena.deinit();
    var report = statefulFailureReport(arena.allocator(), result) catch return;
    defer report.deinit();
    pretty.diagnostic.writeStderr(&report, .{ .width = 100 });
}

pub fn writeStatefulFailure(writer: *std.Io.Writer, result: *const TestResult) !void {
    var arena = std.heap.ArenaAllocator.init(result.allocator);
    defer arena.deinit();
    var report = try statefulFailureReport(arena.allocator(), result);
    defer report.deinit();
    try report.write(writer, .{ .width = 100 });
    try writer.writeByte('\n');
}

fn statefulFailureReport(
    allocator: std.mem.Allocator,
    result: *const TestResult,
) !pretty.diagnostic.Report {
    var report = try pretty.diagnostic.Report.init(
        allocator,
        "Stateful test failed",
    );
    errdefer report.deinit();
    try report.field("Seed", "{}", .{result.seed});
    if (result.failing_choices) |choices| {
        try addChoices(&report, "Minimal command sequence", choices);
    }
    return report;
}

fn addChoices(
    report: *pretty.diagnostic.Report,
    label: []const u8,
    choices: []const ChoiceNode,
) !void {
    try report.section(label);
    try report.line("{} choices", .{choices.len});
    for (choices, 0..) |node, index| {
        switch (node.kind) {
            .integer => try report.line("[{d}] integer: {d}", .{ index, node.value }),
            .boolean => try report.line("[{d}] boolean: {}", .{ index, node.value != 0 }),
            .float => try report.line(
                "[{d}] float: {d}",
                .{ index, @as(f64, @bitCast(node.value)) },
            ),
            .bytes => try report.line("[{d}] bytes: len={d}", .{ index, node.value }),
        }
    }
}

fn addReplayHints(
    report: *pretty.diagnostic.Report,
    result: *const TestResult,
) !void {
    if (result.database_path != null) {
        try report.line(
            "Replay: rerun the same test; database replay runs before" ++
                " random generation.",
            .{},
        );
    }
    if (result.database_namespace) |namespace| {
        try report.line(
            "Filter: pass -- --test-filter \"{s}\" to the owning zig build step.",
            .{namespace},
        );
    }
}

fn addByteBlocks(report: *pretty.diagnostic.Report, blocks: []const u8) !void {
    try report.section("Minimal byte block");
    try report.line("{d} bytes", .{blocks.len});
    var storage: [3 * 64 + 32]u8 = undefined;
    var text = std.Io.Writer.fixed(&storage);
    const limit = @min(blocks.len, 64);
    try text.writeAll("hex:");
    for (blocks[0..limit]) |byte| {
        try text.print(" {x:0>2}", .{byte});
    }
    if (blocks.len > limit) {
        try text.print(" ... +{d} bytes", .{blocks.len - limit});
    }
    try report.line("{s}", .{text.buffered()});
}

test "property failure report is buffered writer friendly" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var choices = [_]ChoiceNode{.{
        .kind = .integer,
        .value = 7,
        .min = 0,
        .max = 10,
        .shrink_towards = 0,
    }};
    const result = TestResult{
        .passed = false,
        .valid_examples = 1,
        .invalid_examples = 0,
        .replayed_examples = 2,
        .database_entries_scanned = 3,
        .database_failures_rejected = 1,
        .replay_budget_saturated = false,
        .failing_choices = choices[0..],
        .failing_byte_blocks = &.{ 0x61, 0x62, 0xff },
        .seed = 42,
        .failing_error = error.PropertyFailed,
        .database_path = "zig-out/hypothesis-failures/example",
        .database_namespace = "example",
        .max_examples = 100,
        .max_replays = 100,
        .max_choices = 4096,
        .max_input_bytes = 1024 * 1024,
        .max_shrinks = 5000,
        .target_examples = 100,
        .per_example_leak_check = false,
        .allocator = std.testing.allocator,
    };

    try writePropertyFailure(&out.writer, &result);
    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Property failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "integer: 7") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "Filter: pass -- --test-filter \"example\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "hex: 61 62 ff") != null);
}
