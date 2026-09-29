const std = @import("std");
const pretty = @import("pretty");
const sys = @import("sys");
const render = @import("render.zig");
const types = @import("types.zig");

const Help = types.Help;
const TerminalOptions = types.TerminalOptions;

pub fn layoutOptions(file: std.Io.File, options: TerminalOptions) pretty.LayoutOptions {
    return .{
        .width = terminalWidth(file, options),
        .color = terminalColorMode(file),
    };
}

pub fn terminalWidth(file: std.Io.File, options: TerminalOptions) usize {
    if (sys.terminal.columnsFromEnvironment()) |width| return clampTerminalWidth(width, options);
    if (!sys.terminal.isTty(file)) return clampTerminalWidth(options.default_width, options);
    if (sys.terminal.querySize(file)) |size| {
        if (size.cols > 0) return clampTerminalWidth(size.cols, options);
    }
    return clampTerminalWidth(options.default_width, options);
}

pub fn terminalColorMode(file: std.Io.File) pretty.ColorMode {
    return terminalColorModeFromEnvironment(
        sys.terminal.isTty(file),
        sys.env.getConstant("NO_COLOR"),
        sys.env.getConstant("CLICOLOR_FORCE"),
        sys.env.getConstant("CLICOLOR"),
        sys.env.getConstant("TERM"),
    );
}

fn terminalColorModeFromEnvironment(
    is_tty: bool,
    no_color: ?[]const u8,
    clicolor_force: ?[]const u8,
    clicolor: ?[]const u8,
    term: ?[]const u8,
) pretty.ColorMode {
    if (no_color != null) return .none;
    if (clicolor_force) |value| {
        if (!std.mem.eql(u8, value, "0")) return .ansi;
    }
    if (clicolor) |value| {
        if (std.mem.eql(u8, value, "0")) return .none;
    }
    if (term) |value| {
        if (std.mem.eql(u8, value, "dumb")) return .none;
    }
    return if (is_tty) .ansi else .none;
}

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    options: TerminalOptions = .{},

    pub fn init(allocator: std.mem.Allocator, file: std.Io.File, options: TerminalOptions) Terminal {
        return .{
            .allocator = allocator,
            .file = file,
            .options = options,
        };
    }

    pub fn stdout(allocator: std.mem.Allocator, options: TerminalOptions) Terminal {
        return init(allocator, sys.stdio.stdout(), options);
    }

    pub fn stderr(allocator: std.mem.Allocator, options: TerminalOptions) Terminal {
        return init(allocator, sys.stdio.stderr(), options);
    }

    pub fn layout(self: Terminal) pretty.LayoutOptions {
        return layoutOptions(self.file, self.options);
    }

    pub fn writeDoc(self: Terminal, doc: pretty.Doc) !void {
        var buffer: [8192]u8 = undefined;
        var file_writer = self.file.writerStreaming(std.Options.debug_io, &buffer);
        defer file_writer.interface.flush() catch {};
        try pretty.write(&file_writer.interface, doc, self.layout());
    }

    pub fn writeText(self: Terminal, text: []const u8) !void {
        try self.writeDoc(.{ .text = text });
    }

    pub fn writeTextFmt(
        self: Terminal,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);
        try self.writeText(text);
    }

    pub fn writeUsageText(self: Terminal, usage_text: []const u8) !void {
        try writeFileUsageText(self.allocator, self.file, usage_text, self.options);
    }

    pub fn writeUsageTextFmt(
        self: Terminal,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try writeFileUsageTextFmt(self.allocator, self.file, fmt, args, self.options);
    }

    pub fn writeHelp(self: Terminal, help: Help) !void {
        try writeFileHelp(self.allocator, self.file, help, self.options);
    }

    pub fn writeErrorText(self: Terminal, prefix: []const u8, text: []const u8) !void {
        try writeFileErrorText(self.allocator, self.file, prefix, text, self.options);
    }

    pub fn writeErrorTextFmt(
        self: Terminal,
        prefix: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try writeFileErrorTextFmt(self.allocator, self.file, prefix, fmt, args, self.options);
    }

    pub fn writeWarningText(self: Terminal, text: []const u8) !void {
        try writeFileWarningText(self.allocator, self.file, text, self.options);
    }

    pub fn writeWarningTextFmt(
        self: Terminal,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try writeFileWarningTextFmt(self.allocator, self.file, fmt, args, self.options);
    }
};

pub fn writeStdoutUsageText(allocator: std.mem.Allocator, usage_text: []const u8) !void {
    try Terminal.stdout(allocator, .{}).writeUsageText(usage_text);
}

pub fn writeStderrUsageText(allocator: std.mem.Allocator, usage_text: []const u8) !void {
    try Terminal.stderr(allocator, .{}).writeUsageText(usage_text);
}

pub fn writeStdoutHelp(allocator: std.mem.Allocator, help: Help) !void {
    try Terminal.stdout(allocator, .{}).writeHelp(help);
}

pub fn writeStderrHelp(allocator: std.mem.Allocator, help: Help) !void {
    try Terminal.stderr(allocator, .{}).writeHelp(help);
}

pub fn writeFileUsageText(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    usage_text: []const u8,
    terminal_options: TerminalOptions,
) !void {
    var buffer: [8192]u8 = undefined;
    var file_writer = file.writerStreaming(std.Options.debug_io, &buffer);
    defer file_writer.interface.flush() catch {};
    try render.writeUsageText(
        allocator,
        &file_writer.interface,
        usage_text,
        .{ .layout = layoutOptions(file, terminal_options) },
    );
}

pub fn writeFileUsageTextFmt(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    comptime fmt: []const u8,
    args: anytype,
    terminal_options: TerminalOptions,
) !void {
    const usage_text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(usage_text);
    try writeFileUsageText(allocator, file, usage_text, terminal_options);
}

pub fn writeFileHelp(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    help: Help,
    terminal_options: TerminalOptions,
) !void {
    var buffer: [8192]u8 = undefined;
    var file_writer = file.writerStreaming(std.Options.debug_io, &buffer);
    defer file_writer.interface.flush() catch {};
    try render.writeHelp(
        allocator,
        &file_writer.interface,
        help,
        .{ .layout = layoutOptions(file, terminal_options) },
    );
}

pub fn writeFileErrorText(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    prefix: []const u8,
    text: []const u8,
    terminal_options: TerminalOptions,
) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writerStreaming(std.Options.debug_io, &buffer);
    defer file_writer.interface.flush() catch {};
    try render.writeErrorText(
        allocator,
        &file_writer.interface,
        prefix,
        text,
        .{ .layout = layoutOptions(file, terminal_options) },
    );
}

pub fn writeFileErrorTextFmt(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    prefix: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    terminal_options: TerminalOptions,
) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try writeFileErrorText(allocator, file, prefix, text, terminal_options);
}

pub fn writeFileWarningText(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    text: []const u8,
    terminal_options: TerminalOptions,
) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writerStreaming(std.Options.debug_io, &buffer);
    defer file_writer.interface.flush() catch {};
    try render.writeErrorText(
        allocator,
        &file_writer.interface,
        "warning",
        text,
        .{
            .layout = layoutOptions(file, terminal_options),
            .prefix_style = .warning,
        },
    );
}

pub fn writeFileWarningTextFmt(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    comptime fmt: []const u8,
    args: anytype,
    terminal_options: TerminalOptions,
) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try writeFileWarningText(allocator, file, text, terminal_options);
}

fn clampTerminalWidth(width: usize, options: TerminalOptions) usize {
    return @min(options.max_width, @max(options.min_width, width));
}

test "terminal width clamp uses caller limits" {
    try std.testing.expectEqual(@as(usize, 48), clampTerminalWidth(12, .{}));
    try std.testing.expectEqual(@as(usize, 88), clampTerminalWidth(88, .{}));
    try std.testing.expectEqual(@as(usize, 120), clampTerminalWidth(200, .{}));
    try std.testing.expectEqual(@as(usize, 30), clampTerminalWidth(20, .{
        .default_width = 40,
        .min_width = 30,
        .max_width = 60,
    }));
}

test "terminal color policy follows environment precedence" {
    try std.testing.expectEqual(pretty.ColorMode.none, terminalColorModeFromEnvironment(true, "", null, null, null));
    try std.testing.expectEqual(pretty.ColorMode.ansi, terminalColorModeFromEnvironment(false, null, "1", "0", "dumb"));
    try std.testing.expectEqual(pretty.ColorMode.none, terminalColorModeFromEnvironment(true, null, null, "0", null));
    try std.testing.expectEqual(pretty.ColorMode.none, terminalColorModeFromEnvironment(true, null, null, null, "dumb"));
    try std.testing.expectEqual(pretty.ColorMode.ansi, terminalColorModeFromEnvironment(true, null, "0", null, null));
    try std.testing.expectEqual(pretty.ColorMode.none, terminalColorModeFromEnvironment(false, null, "0", null, null));
}

test "file usage writers stream consecutive writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const file = try tmp.dir.createFile(std.Options.debug_io, "stderr.txt", .{ .read = true });
    defer file.close(std.Options.debug_io);

    try writeFileErrorTextFmt(allocator, file, "error", "{s} issue", .{"first"}, .{});
    try writeFileUsageTextFmt(allocator, file, "Run `{s} --help` for usage.\n", .{"tool"}, .{});

    const contents = try tmp.dir.readFileAlloc(std.Options.debug_io, "stderr.txt", allocator, .limited(1024));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings(
        \\error: first issue
        \\Run `tool --help` for usage.
        \\
        \\
    , contents);
}

test "terminal handle writes usage messages and docs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const file = try tmp.dir.createFile(std.Options.debug_io, "terminal.txt", .{ .read = true });
    defer file.close(std.Options.debug_io);
    const terminal = Terminal.init(allocator, file, .{
        .default_width = 24,
        .min_width = 16,
        .max_width = 32,
    });

    try terminal.writeTextFmt("plain {s}\n", .{"status"});
    try terminal.writeErrorText("tool", "alpha beta gamma delta epsilon");
    try terminal.writeWarningTextFmt("{s} record", .{"bad"});

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const builder = pretty.Builder.init(arena_state.allocator());
    try terminal.writeDoc(try builder.concat(&.{
        try builder.styledText(.keyword, "done"),
        pretty.hardline,
    }));

    const contents = try tmp.dir.readFileAlloc(std.Options.debug_io, "terminal.txt", allocator, .limited(1024));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings(
        \\plain status
        \\tool: alpha beta gamma
        \\      delta epsilon
        \\warning: bad record
        \\done
        \\
    , contents);
}
