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

test "profile file owns a buffered writer in place" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "coz.jsonl" });
    defer allocator.free(path);

    var file: Writer = .{};
    try file.open(path);
    try file.interface().?.writeAll("one\n");
    try file.finish();

    const contents = try sys.fs.readFileAlloc(allocator, path, 128);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("one\n", contents);
    try std.testing.expect(file.interface() == null);
    file.close();
}

test "profile file rejects double open" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "coz.jsonl" });
    defer allocator.free(path);

    var file: Writer = .{};
    try file.open(path);
    defer file.close();

    try std.testing.expectError(error.ProfileFileAlreadyOpen, file.open(path));
}
