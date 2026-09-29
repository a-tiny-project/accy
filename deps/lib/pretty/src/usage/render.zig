const std = @import("std");
const pretty = @import("pretty");
const types = @import("types.zig");
const helpdoc = @import("help.zig");
const usage = @import("usage.zig");
const errordoc = @import("error.zig");

const UsageTextOptions = types.UsageTextOptions;
const HelpOptions = types.HelpOptions;
const ErrorTextOptions = types.ErrorTextOptions;
const HelpErrorOptions = types.HelpErrorOptions;
const CommandSuggestionOptions = types.CommandSuggestionOptions;
const CommandSuggestionWriteOptions = types.CommandSuggestionWriteOptions;
const CommandHelpErrorOptions = types.CommandHelpErrorOptions;
const CommandPathHelpErrorOptions = types.CommandPathHelpErrorOptions;
const Help = types.Help;

pub fn writeUsageText(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    usage_text: []const u8,
    options: UsageTextOptions,
) !void {
    const text = try renderUsageTextAlloc(allocator, usage_text, options);
    defer allocator.free(text);
    try writer.writeAll(text);
}

pub fn writeHelp(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    help: Help,
    options: HelpOptions,
) !void {
    const text = try renderHelpAlloc(allocator, help, options);
    defer allocator.free(text);
    try writer.writeAll(text);
}

pub fn writeHelpError(
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
    prefix: []const u8,
    message: []const u8,
    help: *const Help,
    options: HelpErrorOptions,
) !u8 {
    try writeErrorText(
        allocator,
        stderr,
        prefix,
        message,
        .{
            .layout = options.layout,
            .prefix_style = options.error_prefix_style,
        },
    );
    try writeHelp(
        allocator,
        stderr,
        help.*,
        .{
            .layout = options.layout,
            .styles = options.help_styles,
        },
    );
    return options.exit_code;
}

pub fn writeCommandHelpOrError(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    help: Help,
    command: []const u8,
    options: CommandHelpErrorOptions,
) !u8 {
    if (help.commandHelp(command)) |command_help| {
        try writeHelp(
            allocator,
            stdout,
            command_help.*,
            .{
                .layout = options.layout,
                .styles = options.help_styles,
            },
        );
        return 0;
    }

    const message = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ options.unknown_label, command });
    defer allocator.free(message);
    try writeErrorText(
        allocator,
        stderr,
        options.error_prefix,
        message,
        .{
            .layout = options.layout,
            .prefix_style = options.error_prefix_style,
        },
    );
    try writeSuggestedCommand(allocator, stderr, help, command, options.suggestions, options.layout);
    if (options.fallback_note) |note| {
        try writeUsageText(allocator, stderr, note, .{ .layout = options.layout });
    }
    if (options.fallback_help) |fallback_help| {
        try writeHelp(
            allocator,
            stderr,
            fallback_help.*,
            .{
                .layout = options.layout,
                .styles = options.help_styles,
            },
        );
    }
    return options.exit_code;
}

pub fn writeCommandPathHelpOrError(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    help: Help,
    args: []const []const u8,
    options: CommandPathHelpErrorOptions,
) !u8 {
    if (help.commandPathHelp(args)) |command_help| {
        try writeHelp(
            allocator,
            stdout,
            command_help.*,
            .{
                .layout = options.layout,
                .styles = options.help_styles,
            },
        );
        return 0;
    }

    if ((&help).commandPathMissing(args)) |missing| {
        const label = if (missing.depth == 0) options.unknown_label else options.nested_unknown_label;
        const message = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ label, missing.arg });
        defer allocator.free(message);
        try writeErrorText(
            allocator,
            stderr,
            options.error_prefix orelse missing.parent.name,
            message,
            .{
                .layout = options.layout,
                .prefix_style = options.error_prefix_style,
            },
        );
        try writeSuggestedCommand(allocator, stderr, missing.parent.*, missing.arg, options.suggestions, options.layout);
        if (options.fallback_note) |note| {
            try writeUsageText(allocator, stderr, note, .{ .layout = options.layout });
        }
        if (options.parent_fallback_help) {
            try writeHelp(
                allocator,
                stderr,
                missing.parent.*,
                .{
                    .layout = options.layout,
                    .styles = options.help_styles,
                },
            );
        } else if (options.fallback_help) |fallback_help| {
            try writeHelp(
                allocator,
                stderr,
                fallback_help.*,
                .{
                    .layout = options.layout,
                    .styles = options.help_styles,
                },
            );
        }
        return options.exit_code;
    }

    if (options.fallback_note) |note| {
        try writeUsageText(allocator, stderr, note, .{ .layout = options.layout });
    }
    if (options.fallback_help) |fallback_help| {
        try writeHelp(
            allocator,
            stderr,
            fallback_help.*,
            .{
                .layout = options.layout,
                .styles = options.help_styles,
            },
        );
    }
    return options.exit_code;
}

pub fn writeCommandSuggestion(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    parent_name: []const u8,
    suggestion_name: []const u8,
    options: CommandSuggestionWriteOptions,
) !void {
    const command_text = if (parent_name.len == 0)
        try allocator.dupe(u8, suggestion_name)
    else
        try std.fmt.allocPrint(allocator, "{s} {s}", .{ parent_name, suggestion_name });
    defer allocator.free(command_text);
    const text = try std.fmt.allocPrint(allocator, "{s} `{s}`?\n", .{ options.intro, command_text });
    defer allocator.free(text);
    try writeUsageText(allocator, writer, text, .{ .layout = options.layout });
}

fn writeSuggestedCommand(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    help: Help,
    input: []const u8,
    options: CommandSuggestionOptions,
    layout: pretty.LayoutOptions,
) !void {
    const suggestion = help.suggestCommand(input, options) orelse return;
    try writeCommandSuggestion(
        allocator,
        writer,
        help.name,
        suggestion.name,
        .{
            .layout = layout,
            .intro = options.intro,
        },
    );
}

pub fn renderUsageTextAlloc(
    allocator: std.mem.Allocator,
    usage_text: []const u8,
    options: UsageTextOptions,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const builder = pretty.Builder.init(arena_state.allocator());
    const doc = try usage.docAlloc(builder, usage_text, options.styles);
    return try pretty.renderAlloc(allocator, doc, options.layout);
}

pub fn renderHelpAlloc(
    allocator: std.mem.Allocator,
    help: Help,
    options: HelpOptions,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const builder = pretty.Builder.init(arena_state.allocator());
    const doc = try helpdoc.docAlloc(builder, help, options);
    return try pretty.renderAlloc(allocator, doc, options.layout);
}

pub fn writeErrorText(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    prefix: []const u8,
    text: []const u8,
    options: ErrorTextOptions,
) !void {
    const rendered = try renderErrorTextAlloc(allocator, prefix, text, options);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

pub fn renderErrorTextAlloc(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    text: []const u8,
    options: ErrorTextOptions,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const builder = pretty.Builder.init(arena_state.allocator());
    const doc = try errordoc.docAlloc(builder, prefix, text, options.prefix_style);
    return try pretty.renderAlloc(allocator, doc, options.layout);
}

test "structured help writes command detail or unknown command fallback" {
    const capture_help = Help{
        .name = "records capture",
        .summary = "Record a work packet.",
    };
    const help = Help{
        .name = "records",
        .groups = &.{
            .{ .commands = &.{
                .{ .name = "capture", .summary = "Record a work packet.", .detail = &capture_help },
            } },
        },
    };

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(u8, 0), try writeCommandHelpOrError(
        std.testing.allocator,
        &stdout.writer,
        &stderr.writer,
        help,
        "capture",
        .{ .layout = .{ .width = 88 } },
    ));
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "usage: records capture") != null);
    try std.testing.expectEqualStrings("", stderr.written());

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 2), try writeCommandHelpOrError(
        std.testing.allocator,
        &stdout.writer,
        &stderr.writer,
        help,
        "captur",
        .{
            .layout = .{ .width = 88 },
            .error_prefix = "records",
            .suggestions = .{ .enabled = true },
            .fallback_help = &help,
        },
    ));
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "records: unknown command: captur\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "Did you mean `records capture`?\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "Commands:\n  capture") != null);
}

test "structured help writes nested command detail or parent fallback" {
    const surprise_help = Help{
        .name = "intent query surprise",
        .summary = "Score action surprise.",
    };
    const query_help = Help{
        .name = "intent query",
        .groups = &.{
            .{ .commands = &.{
                .{ .name = "surprise", .summary = "Score action surprise.", .detail = &surprise_help },
            } },
        },
    };
    const adapt_help = Help{
        .name = "intent adapt",
        .summary = "Adapt a session.",
    };
    const help = Help{
        .name = "intent",
        .groups = &.{
            .{ .commands = &.{
                .{ .name = "adapt", .summary = "Adapt a session.", .detail = &adapt_help },
                .{ .name = "query", .args = "<name>", .summary = "Inspect model state.", .detail = &query_help },
            } },
        },
    };

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(u8, 0), try writeCommandPathHelpOrError(
        std.testing.allocator,
        &stdout.writer,
        &stderr.writer,
        help,
        &.{ "query", "surprise", "--help" },
        .{ .layout = .{ .width = 88 } },
    ));
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "usage: intent query surprise") != null);
    try std.testing.expectEqualStrings("", stderr.written());

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 2), try writeCommandPathHelpOrError(
        std.testing.allocator,
        &stdout.writer,
        &stderr.writer,
        help,
        &.{ "query", "surprse", "--help" },
        .{
            .layout = .{ .width = 88 },
            .nested_unknown_label = "unknown query",
            .suggestions = .{ .enabled = true },
            .parent_fallback_help = true,
        },
    ));
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "intent query: unknown query: surprse\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "Did you mean `intent query surprise`?\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "Commands:\n  surprise") != null);

    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 2), try writeCommandPathHelpOrError(
        std.testing.allocator,
        &stdout.writer,
        &stderr.writer,
        help,
        &.{ "missing", "--help" },
        .{ .layout = .{ .width = 88 }, .parent_fallback_help = true },
    ));
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "intent: unknown command: missing\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "Commands:\n  adapt") != null);
}

test "structured help writes usage errors with help page" {
    const help = Help{
        .name = "web site serve",
        .summary = "Serve a rendered static site locally.",
        .arguments = &.{
            .{ .name = "root", .summary = "Rendered site directory to serve." },
        },
    };

    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    try std.testing.expectEqual(@as(u8, 2), try writeHelpError(
        std.testing.allocator,
        &stderr.writer,
        "web site serve",
        "serve expects <root>",
        &help,
        .{ .layout = .{ .width = 88 } },
    ));
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "web site serve: serve expects <root>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "Arguments:\n  root  Rendered site directory to serve.") != null);
}
