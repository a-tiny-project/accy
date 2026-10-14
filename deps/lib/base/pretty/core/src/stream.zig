const std = @import("std");
const render = @import("render.zig");
const types = @import("types.zig");

/// Adapts incremental text production to the Pretty renderer without allocating.
/// Flushes propagate to the wrapped writer so process-boundary ordering is preserved.
pub const TextWriter = struct {
    writer: std.Io.Writer,
    output: *std.Io.Writer,
    options: types.LayoutOptions,
    workspace: ?*types.Workspace = null,
    failure: ?*?types.RenderFailure = null,
    last_failure: ?types.RenderFailure = null,

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

    pub fn initBounded(
        output: *std.Io.Writer,
        buffer: []u8,
        options: types.LayoutOptions,
        workspace: *types.Workspace,
        sink: ?*?types.RenderFailure,
    ) TextWriter {
        var result = init(output, buffer, options);
        result.workspace = workspace;
        result.failure = sink;
        return result;
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
        self.last_failure = null;
        defer if (self.failure) |sink| {
            const active_alias = if (self.workspace) |workspace|
                workspace.in_use and sink == &workspace.last_failure
            else
                false;
            if (!active_alias) sink.* = self.last_failure;
        };
        if (self.workspace) |workspace| {
            render.writeBounded(
                self.output,
                .{ .text = bytes },
                self.options,
                workspace,
                &self.last_failure,
            ) catch
                return error.WriteFailed;
        } else {
            render.writeWithFailure(
                self.output,
                .{ .text = bytes },
                self.options,
                &self.last_failure,
            ) catch
                return error.WriteFailed;
        }
    }
};
