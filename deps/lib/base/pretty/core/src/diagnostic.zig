const std = @import("std");
const builder_mod = @import("builder.zig");
const render = @import("render.zig");
const stream = @import("stream.zig");
const types = @import("types.zig");

const Builder = builder_mod.Builder;
const Doc = types.Doc;
const hardline = types.hardline;
const fs_io = std.Options.debug_io;

pub const Report = struct {
    allocator: std.mem.Allocator,
    builder: Builder,
    parts: std.ArrayListUnmanaged(Doc) = .empty,

    pub fn init(allocator: std.mem.Allocator, title: []const u8) !Report {
        var self = Report{
            .allocator = allocator,
            .builder = Builder.init(allocator),
        };
        try self.parts.append(allocator, try self.builder.styledText(.danger, title));
        return self;
    }

    pub fn deinit(self: *Report) void {
        self.parts.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn field(
        self: *Report,
        name: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.parts.append(self.allocator, hardline);
        try self.parts.append(self.allocator, try self.builder.concat(&.{
            try self.builder.styledText(.name, name),
            try self.builder.punct(": "),
            try self.builder.styledFmt(.value, fmt, args),
        }));
    }

    pub fn section(self: *Report, name: []const u8) !void {
        try self.parts.append(self.allocator, hardline);
        try self.parts.append(self.allocator, hardline);
        try self.parts.append(self.allocator, try self.builder.styledText(.title, name));
    }

    pub fn line(
        self: *Report,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.parts.append(self.allocator, hardline);
        try self.parts.append(self.allocator, try self.builder.concat(&.{
            self.builder.text("  "),
            try self.builder.textFmt(fmt, args),
        }));
    }

    pub fn doc(self: *Report) !Doc {
        return try self.builder.concat(self.parts.items);
    }

    pub fn write(
        self: *Report,
        writer: *std.Io.Writer,
        options: types.LayoutOptions,
    ) !void {
        try render.write(writer, try self.doc(), options);
    }

    pub fn renderAlloc(
        self: *Report,
        options: types.LayoutOptions,
    ) ![]u8 {
        return try render.renderAlloc(self.allocator, try self.doc(), options);
    }
};

/// Renders one report to standard error and suppresses I/O failures.
///
/// A standard stream is written in streaming mode. The positional writer starts every
/// instance at offset 0, so when the stream is a regular file it overwrites whatever the
/// process wrote before it rather than appending, and the report's own first field is the
/// first thing lost.
pub fn writeStderr(report: *Report, options: types.LayoutOptions) void {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(fs_io, &buffer);
    defer writer.interface.flush() catch {};
    report.write(&writer.interface, options) catch {};
    writer.interface.writeByte('\n') catch {};
}

/// Renders one document to standard output and reports I/O failures.
pub fn writeStdoutDoc(doc: Doc, options: types.LayoutOptions) !void {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(fs_io, &buffer);
    try render.write(&writer.interface, doc, options);
    try writer.interface.flush();
}

/// Renders one document to standard error and reports I/O failures.
pub fn writeStderrDoc(doc: Doc, options: types.LayoutOptions) !void {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(fs_io, &buffer);
    try render.write(&writer.interface, doc, options);
    try writer.interface.flush();
}

pub fn writeStderrText(comptime fmt: []const u8, args: anytype) void {
    var file_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stderr().writerStreaming(fs_io, &file_buffer);
    defer file_writer.interface.flush() catch {};
    var text_buffer: [4096]u8 = undefined;
    var text = stream.TextWriter.init(&file_writer.interface, &text_buffer, .{});
    defer text.writer.flush() catch {};
    text.writer.print(fmt, args) catch {};
}

/// Writes plain formatted text to standard output and suppresses I/O failures.
pub fn writeStdoutText(comptime fmt: []const u8, args: anytype) void {
    var file_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(fs_io, &file_buffer);
    defer file_writer.interface.flush() catch {};
    var text_buffer: [4096]u8 = undefined;
    var text = stream.TextWriter.init(&file_writer.interface, &text_buffer, .{});
    defer text.writer.flush() catch {};
    text.writer.print(fmt, args) catch {};
}

test "diagnostic report renders fields and sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var report = try Report.init(arena.allocator(), "property failed");
    defer report.deinit();

    try report.field("seed", "{}", .{42});
    try report.section("expected");
    try report.line("row {d} score {d}", .{ 7, 3 });

    const rendered = try report.renderAlloc(.{ .width = 80 });
    try std.testing.expect(std.mem.indexOf(u8, rendered, "property failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "seed") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "row 7 score 3") != null);
}

test "diagnostic stderr helpers type check" {
    writeStderrText("", .{});
}

test "diagnostic stdout helpers type check" {
    writeStdoutText("", .{});
    try writeStdoutDoc(.{ .text = "" }, .{});
    try writeStderrDoc(.{ .text = "" }, .{});
}
