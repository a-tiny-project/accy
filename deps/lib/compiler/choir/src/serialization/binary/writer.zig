const std = @import("std");
const binary = @import("root.zig");

const Storage = enum { allocated, borrowed };

pub fn Writer(comptime limits: binary.Limits) type {
    return BufferWriter(limits, .allocated);
}

/// Has no allocator capability. Its finished bytes borrow the caller's buffer.
pub fn FixedWriter(comptime limits: binary.Limits) type {
    return BufferWriter(limits, .borrowed);
}

fn BufferWriter(comptime limits: binary.Limits, comptime ownership: Storage) type {
    return struct {
        allocator: if (ownership == .allocated) std.mem.Allocator else void,
        bytes: std.ArrayListUnmanaged(u8) = .empty,
        total_entries: usize = 0,

        const Self = @This();

        pub fn init(input: if (ownership == .allocated) std.mem.Allocator else []u8) Self {
            return if (ownership == .allocated)
                .{ .allocator = input }
            else
                .{ .allocator = {}, .bytes = .initBuffer(input) };
        }

        pub fn deinit(self: *Self) void {
            if (ownership == .allocated) self.bytes.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn finish(self: *Self) std.mem.Allocator.Error![]u8 {
            if (ownership == .allocated) return self.bytes.toOwnedSlice(self.allocator);
            const bytes = self.bytes.items;
            self.bytes = .empty;
            return bytes;
        }

        pub fn writeRaw(self: *Self, value: []const u8) binary.WriteError!void {
            const new_length = std.math.add(usize, self.bytes.items.len, value.len) catch
                return error.LimitExceeded;
            if (new_length > limits.serialized_bytes) return error.LimitExceeded;
            if (ownership == .allocated) {
                try self.bytes.appendSlice(self.allocator, value);
            } else {
                if (new_length > self.bytes.capacity) return error.LimitExceeded;
                self.bytes.appendSliceAssumeCapacity(value);
            }
        }

        pub const writeInt = encodeInt;

        pub const writeBool = encodeBool;

        pub const writeTag = encodeTag;

        pub fn writeCount(self: *Self, count: usize) binary.WriteError!void {
            if (count > limits.collection_entries or count > std.math.maxInt(u32)) {
                return error.LimitExceeded;
            }
            self.total_entries = std.math.add(usize, self.total_entries, count) catch
                return error.LimitExceeded;
            if (self.total_entries > limits.total_entries) return error.LimitExceeded;
            try self.writeInt(u32, @intCast(count));
        }

        pub fn writeString(self: *Self, value: []const u8) binary.WriteError!void {
            try writeLengthPrefixed(self, value, limits.string_bytes);
        }

        pub fn writeBlob(self: *Self, value: []const u8) binary.WriteError!void {
            try writeLengthPrefixed(self, value, limits.blob_bytes);
        }

        pub const writeOptionalString = encodeOptionalString;

        pub const writeOptionalU16 = encodeOptionalU16;
    };
}

fn encodeInt(self: anytype, comptime T: type, value: T) binary.WriteError!void {
    var storage: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &storage, value, .little);
    try self.writeRaw(&storage);
}

fn encodeBool(self: anytype, value: bool) binary.WriteError!void {
    try self.writeInt(u8, if (value) 1 else 0);
}

fn encodeTag(self: anytype, value: anytype) binary.WriteError!void {
    try self.writeInt(u8, try binary.encodeTag(value));
}

fn encodeOptionalString(self: anytype, value: ?[]const u8) binary.WriteError!void {
    try self.writeBool(value != null);
    if (value) |present| try self.writeString(present);
}

fn encodeOptionalU16(self: anytype, value: ?u16) binary.WriteError!void {
    try self.writeBool(value != null);
    if (value) |present| try self.writeInt(u16, present);
}

fn writeLengthPrefixed(
    self: anytype,
    value: []const u8,
    maximum: usize,
) binary.WriteError!void {
    if (value.len > maximum or value.len > std.math.maxInt(u32)) return error.LimitExceeded;
    try self.writeInt(u32, @intCast(value.len));
    try self.writeRaw(value);
}
