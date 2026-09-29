const std = @import("std");
const sys = @import("sys");

pub fn writeFromJsonlPath(
    comptime Analyzer: type,
    comptime write: anytype,
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    options: anytype,
) !void {
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try ingestJsonlPath(&analyzer, path);
    try write(allocator, &analyzer, writer, options);
}

pub fn ingestJsonlPath(analyzer: anytype, path: []const u8) !void {
    var file = try sys.fs.cwd().openFile(sys.fs.debugIo(), path, .{});
    defer file.close(sys.fs.debugIo());

    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(sys.fs.debugIo(), &buffer);
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        const actual = line orelse break;
        try analyzer.ingestJsonLine(actual);
    }
}

test "report ingests JSONL path and writes through analyzer" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "trace.jsonl" });
    defer allocator.free(path);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = path, .data = "one\ntwo\n" });

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeFromJsonlPath(TestAnalyzer, writeTestAnalyzer, allocator, path, &out.writer, {});
    try std.testing.expectEqualStrings("lines=2 first=one", out.written());
}

const TestAnalyzer = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) TestAnalyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TestAnalyzer) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
    }

    pub fn ingestJsonLine(self: *TestAnalyzer, line: []const u8) !void {
        try self.lines.append(self.allocator, try self.allocator.dupe(u8, line));
    }
};

fn writeTestAnalyzer(
    allocator: std.mem.Allocator,
    analyzer: *TestAnalyzer,
    writer: *std.Io.Writer,
    _: void,
) !void {
    _ = allocator;
    try writer.print("lines={d} first={s}", .{ analyzer.lines.items.len, analyzer.lines.items[0] });
}
