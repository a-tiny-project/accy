const std = @import("std");

const profile = @import("profile.zig");

pub const Interval = struct {
    base: usize,
    limit: usize,

    pub fn init(base: usize, limit: usize) !Interval {
        if (limit <= base) return error.InvalidInterval;
        return .{ .base = base, .limit = limit };
    }

    pub fn unit(address: usize) Interval {
        return .{ .base = address, .limit = address +| 1 };
    }

    pub fn shifted(self: Interval, offset: usize) Interval {
        return .{ .base = self.base +% offset, .limit = self.limit +% offset };
    }

    pub fn contains(self: Interval, address: usize) bool {
        return self.base <= address and address < self.limit;
    }

    pub fn overlaps(self: Interval, other: Interval) bool {
        return self.base < other.limit and other.base < self.limit;
    }
};

pub const Line = struct {
    file: *File,
    number: u64,
    samples: std.atomic.Value(u64) = .init(0),

    pub fn addSample(self: *Line) void {
        _ = self.samples.fetchAdd(1, .monotonic);
    }

    pub fn sampleCount(self: *const Line) u64 {
        return self.samples.load(.monotonic);
    }

    pub fn location(self: *const Line) profile.Location {
        return .{ .file = self.file.name, .line = self.number };
    }
};

pub const File = struct {
    name: []const u8,
    lines: std.AutoHashMapUnmanaged(u64, *Line) = .empty,

    fn getLine(self: *File, allocator: std.mem.Allocator, number: u64) !*Line {
        if (self.lines.get(number)) |line| return line;

        const line = try allocator.create(Line);
        errdefer allocator.destroy(line);
        line.* = .{ .file = self, .number = number };

        try self.lines.put(allocator, number, line);
        return line;
    }

    fn hasLine(self: *const File, number: u64) bool {
        return self.lines.contains(number);
    }

    fn findLine(self: *const File, number: u64) ?*Line {
        return self.lines.get(number);
    }

    fn deinit(self: *File, allocator: std.mem.Allocator) void {
        var iter = self.lines.valueIterator();
        while (iter.next()) |line| allocator.destroy(line.*);
        self.lines.deinit(allocator);
        self.* = undefined;
    }
};

pub const QueuedRange = struct {
    filename: []const u8,
    line: u64,
    range: Interval,
    preferred: bool = false,
};

pub const RangeEntry = struct {
    range: Interval,
    line: *Line,
};

pub const Sample = struct {
    ip: usize,
    callchain: []const usize = &.{},
};

pub const Match = struct {
    line: ?*Line = null,
    selected_hit: bool = false,
};

pub const Index = struct {
    files: std.StringHashMapUnmanaged(*File) = .empty,
    ranges: std.ArrayListUnmanaged(RangeEntry) = .empty,
    unresolved: std.AutoHashMapUnmanaged(usize, void) = .empty,

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
            allocator.destroy(entry.value_ptr.*);
            allocator.free(entry.key_ptr.*);
        }
        self.files.deinit(allocator);
        self.ranges.deinit(allocator);
        self.unresolved.deinit(allocator);
        self.* = .{};
    }

    pub fn markUnresolved(self: *Index, allocator: std.mem.Allocator, address: usize) !void {
        try self.unresolved.put(allocator, address, {});
    }

    pub fn isUnresolved(self: *const Index, address: usize) bool {
        return self.unresolved.contains(address);
    }

    pub fn getFile(self: *Index, allocator: std.mem.Allocator, filename: []const u8) !*File {
        if (self.files.get(filename)) |file| return file;

        const owned_name = try allocator.dupe(u8, filename);
        errdefer allocator.free(owned_name);

        const file = try allocator.create(File);
        errdefer allocator.destroy(file);
        file.* = .{ .name = owned_name };

        try self.files.put(allocator, owned_name, file);
        return file;
    }

    pub fn getLine(self: *Index, allocator: std.mem.Allocator, filename: []const u8, line_no: u64) !*Line {
        return (try self.getFile(allocator, filename)).getLine(allocator, line_no);
    }

    pub fn addRange(
        self: *Index,
        allocator: std.mem.Allocator,
        filename: []const u8,
        line_no: u64,
        range: Interval,
    ) !*Line {
        if (self.findOverlappingRange(range)) |entry| return entry.line;

        const line = try self.getLine(allocator, filename, line_no);
        const index = self.rangeInsertIndex(range);
        try self.ranges.insert(allocator, index, .{ .range = range, .line = line });
        return line;
    }

    pub fn addQueuedRanges(self: *Index, allocator: std.mem.Allocator, queued: []QueuedRange) !void {
        std.mem.sort(QueuedRange, queued, {}, queuedRangeLessThan);
        for (queued) |entry| {
            _ = try self.addRange(allocator, entry.filename, entry.line, entry.range);
        }
    }

    pub fn findLineByAddress(self: *const Index, address: usize) ?*Line {
        var low: usize = 0;
        var high: usize = self.ranges.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry = self.ranges.items[mid];
            if (address < entry.range.base) {
                high = mid;
            } else if (address >= entry.range.limit) {
                low = mid + 1;
            } else {
                return entry.line;
            }
        }
        return null;
    }

    pub fn findLineByName(self: *Index, text: []const u8) ?*Line {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
        const filename = text[0..colon];
        const line_no = std.fmt.parseUnsigned(u64, text[colon + 1 ..], 10) catch return null;

        var iter = self.files.valueIterator();
        while (iter.next()) |file| {
            if (std.mem.endsWith(u8, file.*.name, filename) and file.*.hasLine(line_no)) {
                return file.*.findLine(line_no);
            }
        }
        return null;
    }

    pub fn matchSample(self: *const Index, sample: Sample, selected: ?*const Line) Match {
        var result: Match = .{};
        var first_hit = false;

        if (self.findLineByAddress(sample.ip)) |line| {
            result.line = line;
            first_hit = true;
            if (selectedLineMatches(selected, line)) return .{ .line = line, .selected_hit = true };
        }

        for (sample.callchain) |pc| {
            const address = pc -| 1;
            if (self.findLineByAddress(address)) |line| {
                if (!first_hit) {
                    first_hit = true;
                    result.line = line;
                }
                if (selectedLineMatches(selected, line)) return .{ .line = line, .selected_hit = true };
            }
        }

        return result;
    }

    fn findOverlappingRange(self: *const Index, range: Interval) ?RangeEntry {
        for (self.ranges.items) |entry| {
            if (entry.range.overlaps(range)) return entry;
            if (entry.range.base >= range.limit) return null;
        }
        return null;
    }

    fn rangeInsertIndex(self: *const Index, range: Interval) usize {
        for (self.ranges.items, 0..) |entry, index| {
            if (range.base < entry.range.base) return index;
        }
        return self.ranges.items.len;
    }
};

fn selectedLineMatches(selected: ?*const Line, line: *const Line) bool {
    return if (selected) |expected| expected == line else false;
}

fn queuedRangeLessThan(_: void, lhs: QueuedRange, rhs: QueuedRange) bool {
    if (lhs.range.base != rhs.range.base) return lhs.range.base < rhs.range.base;
    if (lhs.range.limit != rhs.range.limit) return lhs.range.limit < rhs.range.limit;
    if (lhs.preferred != rhs.preferred) return lhs.preferred and !rhs.preferred;
    if (lhs.line != rhs.line) return lhs.line < rhs.line;
    return std.mem.lessThan(u8, lhs.filename, rhs.filename);
}

test "interval contains points in half-open range" {
    const interval = try Interval.init(10, 20);

    try std.testing.expect(!interval.contains(9));
    try std.testing.expect(interval.contains(10));
    try std.testing.expect(interval.contains(19));
    try std.testing.expect(!interval.contains(20));
    try std.testing.expect(interval.overlaps(try Interval.init(19, 30)));
    try std.testing.expect(!interval.overlaps(try Interval.init(20, 30)));
}

test "map remembers addresses marked unresolvable" {
    var map: Index = .{};
    defer map.deinit(std.testing.allocator);

    try std.testing.expect(!map.isUnresolved(0x1000));
    try map.markUnresolved(std.testing.allocator, 0x1000);
    try map.markUnresolved(std.testing.allocator, 0x1000);
    try std.testing.expect(map.isUnresolved(0x1000));
    try std.testing.expect(!map.isUnresolved(0x1001));
}

test "map interns files and lines and accumulates samples" {
    var map: Index = .{};
    defer map.deinit(std.testing.allocator);

    const first = try map.getLine(std.testing.allocator, "/tmp/app.zig", 12);
    const second = try map.getLine(std.testing.allocator, "/tmp/app.zig", 12);
    first.addSample();
    first.addSample();

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqualStrings("/tmp/app.zig", first.file.name);
    try std.testing.expectEqual(@as(u64, 12), first.number);
    try std.testing.expectEqual(@as(u64, 2), second.sampleCount());
}

test "queued ranges prefer inline attribution for identical ranges" {
    var map: Index = .{};
    defer map.deinit(std.testing.allocator);

    var queued = [_]QueuedRange{
        .{ .filename = "/tmp/original.zig", .line = 8, .range = try Interval.init(100, 120) },
        .{ .filename = "/tmp/inline.zig", .line = 4, .range = try Interval.init(100, 120), .preferred = true },
    };

    try map.addQueuedRanges(std.testing.allocator, &queued);

    const line = map.findLineByAddress(110).?;
    try std.testing.expectEqualStrings("/tmp/inline.zig", line.file.name);
    try std.testing.expectEqual(@as(u64, 4), line.number);
    try std.testing.expectEqual(@as(usize, 1), map.ranges.items.len);
}

test "overlapping ranges keep the first inserted attribution" {
    var map: Index = .{};
    defer map.deinit(std.testing.allocator);

    const first = try map.addRange(std.testing.allocator, "/tmp/first.zig", 1, try Interval.init(10, 20));
    const second = try map.addRange(std.testing.allocator, "/tmp/second.zig", 2, try Interval.init(15, 25));

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqualStrings("/tmp/first.zig", map.findLineByAddress(16).?.file.name);
}

test "address lookup uses sorted half-open ranges" {
    var map: Index = .{};
    defer map.deinit(std.testing.allocator);

    _ = try map.addRange(std.testing.allocator, "/tmp/b.zig", 2, try Interval.init(30, 40));
    _ = try map.addRange(std.testing.allocator, "/tmp/a.zig", 1, try Interval.init(10, 20));

    try std.testing.expectEqualStrings("/tmp/a.zig", map.findLineByAddress(10).?.file.name);
    try std.testing.expect(map.findLineByAddress(20) == null);
    try std.testing.expectEqualStrings("/tmp/b.zig", map.findLineByAddress(39).?.file.name);
}

test "name lookup matches file suffix only when the line exists" {
    var map: Index = .{};
    defer map.deinit(std.testing.allocator);

    _ = try map.getLine(std.testing.allocator, "/home/me/src/main.zig", 42);

    try std.testing.expect(map.findLineByName("src/main.zig:42") != null);
    try std.testing.expect(map.findLineByName("src/main.zig:41") == null);
    try std.testing.expect(map.findLineByName("main.zig") == null);
    try std.testing.expect(map.findLineByName("main.zig:not-a-line") == null);
}

test "sample matching prefers selected callchain line over first ip hit" {
    var map: Index = .{};
    defer map.deinit(std.testing.allocator);

    const ip_line = try map.addRange(std.testing.allocator, "/tmp/ip.zig", 1, try Interval.init(100, 110));
    const selected = try map.addRange(std.testing.allocator, "/tmp/selected.zig", 2, try Interval.init(200, 210));

    const matched = map.matchSample(.{ .ip = 105, .callchain = &.{206} }, selected);

    try std.testing.expectEqual(selected, matched.line.?);
    try std.testing.expect(matched.selected_hit);
    try std.testing.expect(ip_line != matched.line.?);
}

test "sample matching keeps first line when selected line is absent" {
    var map: Index = .{};
    defer map.deinit(std.testing.allocator);

    const first = try map.addRange(std.testing.allocator, "/tmp/first.zig", 1, try Interval.init(100, 110));
    _ = try map.addRange(std.testing.allocator, "/tmp/second.zig", 2, try Interval.init(200, 210));

    const matched = map.matchSample(.{ .ip = 0, .callchain = &.{ 110, 210 } }, null);

    try std.testing.expectEqual(first, matched.line.?);
    try std.testing.expect(!matched.selected_hit);
}
