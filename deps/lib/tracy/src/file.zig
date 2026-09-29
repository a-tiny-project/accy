const std = @import("std");
const sys = @import("sys");

pub const File = struct {
    file: std.Io.File = undefined,
    buffer: [8192]u8 = undefined,
    writer: std.Io.File.Writer = undefined,
    opened: bool = false,

    pub fn open(self: *File, path: []const u8) !void {
        if (self.opened) return error.TraceFileAlreadyOpen;
        self.file = try sys.fs.cwd().createFile(sys.fs.debugIo(), path, .{ .truncate = true });
        errdefer self.file.close(sys.fs.debugIo());
        self.writer = self.file.writer(sys.fs.debugIo(), &self.buffer);
        self.opened = true;
    }

    pub fn interface(self: *File) ?*std.Io.Writer {
        if (!self.opened) return null;
        return &self.writer.interface;
    }

    pub fn finish(self: *File) !void {
        if (!self.opened) return;
        defer {
            self.file.close(sys.fs.debugIo());
            self.opened = false;
        }
        try self.writer.flush();
    }

    pub fn close(self: *File) void {
        self.finish() catch {};
    }
};

test "trace file owns a buffered writer in place" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "tracy.jsonl" });
    defer allocator.free(path);

    var file: File = .{};
    try file.open(path);
    try file.interface().?.writeAll("one\n");
    try file.finish();

    const contents = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), path, allocator, .limited(128));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("one\n", contents);
    try std.testing.expect(file.interface() == null);
    file.close();
}

test "trace file rejects double open" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "tracy.jsonl" });
    defer allocator.free(path);

    var file: File = .{};
    try file.open(path);
    defer file.close();

    try std.testing.expectError(error.TraceFileAlreadyOpen, file.open(path));
}
