const std = @import("std");
const render = @import("render.zig");
const types = @import("types.zig");

/// Adapts incremental text production to the Pretty renderer without allocating.
/// Flushes propagate to the wrapped writer so process-boundary ordering is preserved.
pub const TextWriter = struct {
    writer: std.Io.Writer,
    output: *std.Io.Writer,
    options: types.LayoutOptions,

    pub fn init(
        output: *std.Io.Writer,
        buffer: []u8,
        options: types.LayoutOptions,
    ) TextWriter {
        return .{
            .writer = .{
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                },
                .buffer = buffer,
            },
            .output = output,
            .options = options,
        };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *TextWriter = @alignCast(@fieldParentPtr("writer", writer));
        std.debug.assert(data.len > 0);
        try self.write(writer.buffered());
        writer.end = 0;

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.write(bytes);
            consumed += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.write(pattern);
            consumed += pattern.len;
        }
        return consumed;
    }

    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *TextWriter = @alignCast(@fieldParentPtr("writer", writer));
        try self.write(writer.buffered());
        writer.end = 0;
        try self.output.flush();
    }

    fn write(self: *TextWriter, bytes: []const u8) std.Io.Writer.Error!void {
        render.write(
            self.output,
            .{ .text = bytes },
            self.options,
        ) catch return error.WriteFailed;
    }
};

test "text writer routes incremental output through the renderer" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var buffer: [4]u8 = undefined;
    var text = TextWriter.init(&output.writer, &buffer, .{ .width = 20 });
    try text.writer.print("alpha {d}\n", .{7});
    try text.writer.writeAll("omega");
    try text.writer.flush();
    try std.testing.expectEqualStrings("alpha 7\nomega", output.writer.buffered());
}

test "text writer preserves fragmented UTF-8 and terminal bytes" {
    const expected = "{\"value\":\"λ\"}\n\x1b[31mred\x1b[0m\n";
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var buffer: [3]u8 = undefined;
    var text = TextWriter.init(&output.writer, &buffer, .{ .width = 20 });
    try text.writer.writeAll(expected);
    try text.writer.flush();
    try std.testing.expectEqualStrings(expected, output.writer.buffered());
}

test "text writer flush reaches its output" {
    const Probe = struct {
        writer: std.Io.Writer,
        flushed: *bool,

        fn init(buffer: []u8, flushed: *bool) @This() {
            return .{
                .writer = .{
                    .vtable = &.{
                        .drain = drain,
                        .flush = flush,
                    },
                    .buffer = buffer,
                },
                .flushed = flushed,
            };
        }

        fn drain(
            _: *std.Io.Writer,
            _: []const []const u8,
            _: usize,
        ) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }

        fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *@This() = @alignCast(@fieldParentPtr("writer", writer));
            writer.end = 0;
            self.flushed.* = true;
        }
    };

    var flushed = false;
    var output_buffer: [32]u8 = undefined;
    var output = Probe.init(&output_buffer, &flushed);
    var text_buffer: [8]u8 = undefined;
    var text = TextWriter.init(&output.writer, &text_buffer, .{});
    try text.writer.writeAll("alpha");
    try text.writer.flush();
    try std.testing.expect(flushed);
}
