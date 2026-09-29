const std = @import("std");
const sys = @import("../root.zig");

const env = sys.env;
const fs = sys.fs;

pub const cookie_name = "MIT-MAGIC-COOKIE-1";
pub const cookie_length = 16;
pub const maximum_authority_file_byte_count = 64 * 1024;

const family_local: u16 = 256;
const family_wild: u16 = 65535;

pub const Cookie = struct {
    data: [cookie_length]u8,
};

const Record = struct {
    family: u16,
    address: []const u8,
    number: []const u8,
    name: []const u8,
    data: []const u8,
};

const Reader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn u16be(self: *Reader) ?u16 {
        if (self.index + 2 > self.bytes.len) return null;
        const value = std.mem.readInt(u16, self.bytes[self.index..][0..2], .big);
        self.index += 2;
        return value;
    }

    fn counted(self: *Reader) ?[]const u8 {
        const len = self.u16be() orelse return null;
        if (self.index + len > self.bytes.len) return null;
        const slice = self.bytes[self.index .. self.index + len];
        self.index += len;
        return slice;
    }

    fn record(self: *Reader) ?Record {
        const family = self.u16be() orelse return null;
        const address = self.counted() orelse return null;
        const number = self.counted() orelse return null;
        const name = self.counted() orelse return null;
        const data = self.counted() orelse return null;
        return .{
            .family = family,
            .address = address,
            .number = number,
            .name = name,
            .data = data,
        };
    }
};

pub fn findCookie(bytes: []const u8, display: u32) ?Cookie {
    var number_buffer: [10]u8 = undefined;
    const number = std.fmt.bufPrint(&number_buffer, "{d}", .{display}) catch return null;

    var reader = Reader{ .bytes = bytes };
    while (reader.record()) |record| {
        if (record.family != family_local and record.family != family_wild) continue;
        if (record.number.len != 0 and !std.mem.eql(u8, record.number, number)) continue;
        if (!std.mem.eql(u8, record.name, cookie_name)) continue;
        if (record.data.len != cookie_length) continue;
        var cookie: Cookie = undefined;
        @memcpy(&cookie.data, record.data);
        return cookie;
    }
    return null;
}

pub fn loadCookie(storage: []u8, display: u32) ?Cookie {
    std.debug.assert(storage.len >= maximum_authority_file_byte_count);
    var path_buffer: [512]u8 = undefined;
    const path = authorityPath(&path_buffer) orelse return null;
    var file = fs.cwd().openFile(fs.debugIo(), path, .{}) catch return null;
    defer file.close(fs.debugIo());
    const bytes = readAuthorityFile(file, storage[0..maximum_authority_file_byte_count]) orelse
        return null;
    return findCookie(bytes, display);
}

fn readAuthorityFile(file: std.Io.File, storage: []u8) ?[]const u8 {
    var filled: usize = 0;
    while (filled < storage.len) {
        const count = fs.readHandle(file, storage[filled..]) catch return null;
        if (count == 0) return storage[0..filled];
        filled += count;
    }
    var probe: [1]u8 = undefined;
    if ((fs.readHandle(file, &probe) catch return null) != 0) return null;
    return storage;
}

fn authorityPath(buffer: []u8) ?[]const u8 {
    if (env.get("XAUTHORITY")) |explicit| {
        if (explicit.len == 0 or explicit.len > buffer.len) return null;
        @memcpy(buffer[0..explicit.len], explicit);
        return buffer[0..explicit.len];
    }
    const home = env.get("HOME") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.Xauthority", .{home}) catch null;
}

fn appendU16Be(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var scratch: [2]u8 = undefined;
    std.mem.writeInt(u16, &scratch, value, .big);
    try list.appendSlice(allocator, &scratch);
}

fn appendCounted(list: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try appendU16Be(list, allocator, @intCast(bytes.len));
    try list.appendSlice(allocator, bytes);
}

fn appendRecord(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    family: u16,
    address: []const u8,
    number: []const u8,
    name: []const u8,
    data: []const u8,
) !void {
    try appendU16Be(list, allocator, family);
    try appendCounted(list, allocator, address);
    try appendCounted(list, allocator, number);
    try appendCounted(list, allocator, name);
    try appendCounted(list, allocator, data);
}

test "findCookie matches the display record" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    const other = @as([cookie_length]u8, @splat(0xAA));
    const wanted = @as([cookie_length]u8, @splat(0x5A));
    try appendRecord(&bytes, allocator, family_local, "host", "0", cookie_name, &other);
    try appendRecord(&bytes, allocator, family_local, "host", "7", cookie_name, &wanted);

    const cookie = findCookie(bytes.items, 7) orelse return error.TestExpectedCookie;
    try std.testing.expectEqualSlices(u8, &wanted, &cookie.data);
}

test "findCookie skips foreign families and short data" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    const cookie = @as([cookie_length]u8, @splat(0x11));
    try appendRecord(&bytes, allocator, 0, "10.0.0.1", "0", cookie_name, &cookie);
    try appendRecord(&bytes, allocator, family_local, "host", "0", cookie_name, cookie[0..4]);
    try std.testing.expect(findCookie(bytes.items, 0) == null);
}

test "findCookie accepts wildcard records and truncated files" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    const cookie = @as([cookie_length]u8, @splat(0x77));
    try appendRecord(&bytes, allocator, family_wild, "", "", cookie_name, &cookie);
    try std.testing.expect(findCookie(bytes.items, 3) != null);

    try std.testing.expect(findCookie(bytes.items[0 .. bytes.items.len - 1], 99) == null);
}

test "authority file read accepts exact storage and rejects max plus one" {
    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var exact = try tmp.dir.createFile(io, "exact", .{});
    try fs.writeHandleAll(exact, "four");
    exact.close(io);
    var exact_reader = try tmp.dir.openFile(io, "exact", .{});
    defer exact_reader.close(io);
    var storage: [4]u8 = undefined;
    try std.testing.expectEqualStrings(
        "four",
        readAuthorityFile(exact_reader, &storage).?,
    );

    var oversized = try tmp.dir.createFile(io, "oversized", .{});
    try fs.writeHandleAll(oversized, "fives");
    oversized.close(io);
    var oversized_reader = try tmp.dir.openFile(io, "oversized", .{});
    defer oversized_reader.close(io);
    try std.testing.expect(readAuthorityFile(oversized_reader, &storage) == null);
}
