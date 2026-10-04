const std = @import("std");

pub const Index = struct {
    entries: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        var iter = self.entries.keyIterator();
        while (iter.next()) |key| allocator.free(key.*);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn count(self: *const Index) usize {
        return self.entries.count();
    }

    pub fn get(self: *const Index, path: []const u8) ?usize {
        return self.entries.get(path);
    }

    pub fn put(self: *Index, allocator: std.mem.Allocator, path: []const u8, load_address: usize) !void {
        if (self.entries.getPtr(path)) |existing| {
            existing.* = load_address;
            return;
        }

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        try self.entries.put(allocator, owned_path, load_address);
    }
};

pub fn parseProcMaps(allocator: std.mem.Allocator, text: []const u8) !Index {
    var result: Index = .{};
    errdefer result.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try parseProcMapsLine(allocator, &result, line);
    }

    return result;
}

fn parseProcMapsLine(allocator: std.mem.Allocator, result: *Index, raw_line: []const u8) !void {
    const line = trimLeft(raw_line, " \t\r");
    if (line.len == 0) return;

    var cursor: usize = 0;
    const address_field = nextField(line, &cursor) orelse return error.InvalidProcMapsLine;
    const perms = nextField(line, &cursor) orelse return error.InvalidProcMapsLine;
    const offset_field = nextField(line, &cursor) orelse return error.InvalidProcMapsLine;
    const dev = nextField(line, &cursor) orelse return error.InvalidProcMapsLine;
    const inode = nextField(line, &cursor) orelse return error.InvalidProcMapsLine;
    const path = trimRight(trimLeft(line[cursor..], " \t"), "\r");

    if (std.mem.indexOfScalar(u8, dev, ':') == null) return error.InvalidProcMapsLine;
    _ = try parseDecimal(u64, inode);

    if (perms.len < 3 or perms[2] != 'x') return;
    if (path.len == 0 or path[0] != '/') return;

    const dash = std.mem.indexOfScalar(u8, address_field, '-') orelse return error.InvalidProcMapsLine;
    const base = try parseHex(usize, address_field[0..dash]);
    _ = try parseHex(usize, address_field[dash + 1 ..]);
    const offset = try parseHex(usize, offset_field);
    const load_address = std.math.sub(usize, base, offset) catch return error.InvalidMappingAddress;

    try result.put(allocator, path, load_address);
}

fn nextField(line: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < line.len and isSpace(line[cursor.*])) cursor.* += 1;
    if (cursor.* >= line.len) return null;

    const start = cursor.*;
    while (cursor.* < line.len and !isSpace(line[cursor.*])) cursor.* += 1;
    return line[start..cursor.*];
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn parseHex(comptime T: type, text: []const u8) !T {
    return std.fmt.parseUnsigned(T, text, 16) catch return error.InvalidProcMapsLine;
}

fn parseDecimal(comptime T: type, text: []const u8) !T {
    return std.fmt.parseUnsigned(T, text, 10) catch return error.InvalidProcMapsLine;
}

fn trimLeft(bytes: []const u8, values: []const u8) []const u8 {
    var start: usize = 0;
    while (start < bytes.len and std.mem.indexOfScalar(u8, values, bytes[start]) != null) start += 1;
    return bytes[start..];
}

fn trimRight(bytes: []const u8, values: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and std.mem.indexOfScalar(u8, values, bytes[end - 1]) != null) end -= 1;
    return bytes[0..end];
}
