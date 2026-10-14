const std = @import("std");
const sys = @import("sys");

pub const Writer = struct {
    file: std.Io.File = undefined,
    buffer: [8192]u8 = undefined,
    writer: std.Io.File.Writer = undefined,
    opened: bool = false,

    pub fn open(self: *Writer, path: []const u8) !void {
        if (self.opened) return error.ProfileFileAlreadyOpen;
        self.file = try sys.fs.createFile(path, .{ .truncate = true });
        errdefer self.file.close(sys.fs.debugIo());
        self.writer = self.file.writer(sys.fs.debugIo(), &self.buffer);
        self.opened = true;
    }

    pub fn interface(self: *Writer) ?*std.Io.Writer {
        if (!self.opened) return null;
        return &self.writer.interface;
    }

    pub fn finish(self: *Writer) !void {
        if (!self.opened) return;
        defer {
            self.file.close(sys.fs.debugIo());
            self.opened = false;
        }
        try self.writer.flush();
    }

    pub fn close(self: *Writer) void {
        self.finish() catch {};
    }
};
