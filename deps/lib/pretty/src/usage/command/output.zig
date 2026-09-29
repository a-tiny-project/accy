const std = @import("std");
const sys = @import("sys");
const pretty = @import("pretty");
const usage_root = @import("../root.zig");

pub const Mode = enum {
    human,
    json,
    json_pretty,
    quiet,
    summary,
};

pub const Output = struct {
    file: std.Io.File,
    mode: Mode,
    allocator: std.mem.Allocator,

    pub fn initWithAllocator(allocator: std.mem.Allocator) Output {
        return .{
            .file = std.Io.File.stdout(),
            .mode = .human,
            .allocator = allocator,
        };
    }

    pub fn initWithFile(file: std.Io.File, allocator: std.mem.Allocator) Output {
        return .{
            .file = file,
            .mode = .human,
            .allocator = allocator,
        };
    }

    pub fn setMode(self: *Output, mode: Mode) void {
        self.mode = mode;
    }

    pub fn setModeFromFlags(self: *Output, json: bool, quiet: bool, summary: bool, pretty_json: bool) void {
        if (quiet) {
            self.mode = .quiet;
        } else if (json) {
            self.mode = if (pretty_json) .json_pretty else .json;
        } else if (summary) {
            self.mode = .summary;
        } else {
            self.mode = .human;
        }
    }

    pub fn record(self: *Output, value: anytype) !void {
        switch (self.mode) {
            .json, .json_pretty => try self.writeJson(value),
            .quiet => try self.writeQuiet(value),
            .human, .summary => try self.writeHuman(value),
        }
    }

    pub fn list(self: *Output, comptime T: type, values: []const T) !void {
        switch (self.mode) {
            .json, .json_pretty => try self.writeJson(values),
            .quiet => for (values) |value| try self.writeQuiet(value),
            .human, .summary => for (values) |value| try self.writeHuman(value),
        }
    }

    pub fn info(self: *Output, comptime fmt: []const u8, args: anytype) !void {
        switch (self.mode) {
            .json, .json_pretty, .quiet => return,
            .human, .summary => try self.print(fmt ++ "\n", args),
        }
    }

    pub fn success(self: *Output, comptime fmt: []const u8, args: anytype) !void {
        try self.info(fmt, args);
    }

    pub fn write(self: *Output, bytes: []const u8) !void {
        try sys.fs.writeHandleAll(self.file, bytes);
    }

    pub fn writeTable(self: *Output, bytes: []const u8) !void {
        const rendered = try renderTableAlloc(self.allocator, bytes, usage_root.terminalColorMode(self.file));
        defer self.allocator.free(rendered);
        try self.write(rendered);
    }

    pub fn print(self: *Output, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);
        try self.write(text);
    }

    fn writeJson(self: *Output, value: anytype) !void {
        const options: std.json.Stringify.Options = if (self.mode == .json_pretty)
            .{ .whitespace = .indent_2 }
        else
            .{};
        const text = try std.json.Stringify.valueAlloc(self.allocator, value, options);
        defer self.allocator.free(text);
        try self.write(text);
        try self.write("\n");
    }

    fn writeQuiet(self: *Output, value: anytype) !void {
        const T = @TypeOf(value);
        if (@typeInfo(T) == .@"struct") {
            inline for (@typeInfo(T).@"struct".field_names) |field_name| {
                if (comptime std.mem.eql(u8, field_name, "id")) {
                    return try self.printValueLine(@field(value, field_name));
                }
            }
        }
        try self.writeJson(value);
    }

    fn writeHuman(self: *Output, value: anytype) !void {
        const T = @TypeOf(value);
        if (@typeInfo(T) == .@"struct") {
            inline for (@typeInfo(T).@"struct".field_names, 0..) |field_name, index| {
                if (index > 0) try self.write("  ");
                try self.printFieldPair(field_name, @field(value, field_name));
            }
            try self.write("\n");
            return;
        }
        try self.printValueLine(value);
    }

    fn printFieldPair(self: *Output, name: []const u8, value: anytype) !void {
        const T = @TypeOf(value);
        if (comptime T == []const u8 or T == []u8) {
            try self.print("{s}: {s}", .{ name, value });
        } else if (comptime @typeInfo(T) == .int) {
            try self.print("{s}: {d}", .{ name, value });
        } else {
            try self.print("{s}: {any}", .{ name, value });
        }
    }

    fn printValueLine(self: *Output, value: anytype) !void {
        const T = @TypeOf(value);
        if (comptime T == []const u8 or T == []u8) {
            try self.print("{s}\n", .{value});
        } else if (comptime @typeInfo(T) == .int) {
            try self.print("{d}\n", .{value});
        } else {
            try self.print("{any}\n", .{value});
        }
    }
};

pub fn die(comptime fmt: []const u8, args: anytype) noreturn {
    var stderr_writer = std.Io.File.stderr().writerStreaming(std.Options.debug_io, &.{});
    stderr_writer.interface.print("error: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(1);
}

test "output record honors json, quiet, and human modes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = sys.fs.debugIo();

    const allocator = std.testing.allocator;
    var file = try tmp.dir.createFile(io, "record.txt", .{ .read = true });
    defer file.close(io);

    var output = Output.initWithFile(file, allocator);
    try output.record(.{ .id = @as([]const u8, "tiny-1"), .status = @as([]const u8, "open") });
    output.setModeFromFlags(true, false, false, false);
    try output.record(.{ .id = @as([]const u8, "tiny-1") });
    output.setModeFromFlags(false, true, false, false);
    try output.record(.{ .id = @as([]const u8, "tiny-1") });

    const contents = try sys.fs.readHandleToEndAlloc(allocator, file, 4096);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings(
        "id: tiny-1  status: open\n{\"id\":\"tiny-1\"}\ntiny-1\n",
        contents,
    );
}

pub fn renderTableAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    color: pretty.ColorMode,
) std.mem.Allocator.Error![]u8 {
    const frame_len = tableFrameLength(bytes);
    if (color == .none or frame_len == 0) return allocator.dupe(u8, bytes);
    const frame_doc = pretty.Doc{ .text = bytes[0..frame_len] };
    const styled_frame = pretty.Doc{ .styled = .{ .style = .muted, .doc = &frame_doc } };
    const body_doc = pretty.Doc{ .text = bytes[frame_len..] };
    const parts = [_]pretty.Doc{ styled_frame, body_doc };
    return pretty.renderAlloc(allocator, .{ .concat = parts[0..] }, .{ .width = bytes.len + 1, .color = color }) catch error.OutOfMemory;
}

pub fn tableFrameLength(bytes: []const u8) usize {
    const header_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse return 0;
    const separator_end = std.mem.indexOfScalarPos(u8, bytes, header_end + 1, '\n') orelse bytes.len;
    const separator = bytes[header_end + 1 .. separator_end];
    if (separator.len == 0) return 0;
    if (std.mem.indexOfNone(u8, separator, "- ") != null) return 0;
    return @min(separator_end + 1, bytes.len);
}

test "tableFrameLength finds header and dash separator" {
    const framed = "id  name\n--  ----\nrow one\n";
    try std.testing.expectEqual(@as(usize, 18), tableFrameLength(framed));
    try std.testing.expectEqual(@as(usize, 0), tableFrameLength("plain text\nno separator\n"));
    try std.testing.expectEqual(@as(usize, 0), tableFrameLength("single line"));
}

test "renderTableAlloc styles the frame only under color" {
    const framed = "id  name\n--  ----\nrow one\n";
    const plain = try renderTableAlloc(std.testing.allocator, framed, .none);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings(framed, plain);
    const styled = try renderTableAlloc(std.testing.allocator, framed, .ansi);
    defer std.testing.allocator.free(styled);
    try std.testing.expect(std.mem.startsWith(u8, styled, "\x1b[2m"));
    try std.testing.expect(std.mem.indexOf(u8, styled, "row one") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[0mrow one") != null);
}
