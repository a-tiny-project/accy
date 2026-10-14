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
