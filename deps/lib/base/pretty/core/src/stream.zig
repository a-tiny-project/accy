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
