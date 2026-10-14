const std = @import("std");
const binary = @import("root.zig");

pub fn Reader(comptime limits: binary.Limits) type {
    return struct {
        bytes: []const u8,
        offset: usize = 0,
        total_entries: usize = 0,

        const Self = @This();

        pub fn init(bytes: []const u8) binary.Error!Self {
            if (bytes.len > limits.serialized_bytes) return error.LimitExceeded;
            return .{ .bytes = bytes };
        }

        pub fn atEnd(self: Self) bool {
            return self.offset == self.bytes.len;
        }

        pub fn readRaw(self: *Self, length: usize) binary.Error![]const u8 {
            if (length > self.bytes.len - self.offset) return error.Truncated;
            const value = self.bytes[self.offset..][0..length];
            self.offset += length;
            return value;
        }

        pub fn readInt(self: *Self, comptime T: type) binary.Error!T {
            const value = try self.readRaw(@sizeOf(T));
            return std.mem.readInt(T, value[0..@sizeOf(T)], .little);
        }

        pub fn readBool(self: *Self) binary.Error!bool {
            return switch (try self.readInt(u8)) {
                0 => false,
                1 => true,
                else => error.InvalidValue,
            };
        }

        pub fn readTag(self: *Self, comptime T: type) binary.Error!T {
            return try binary.decodeTag(T, try self.readInt(u8));
        }

        pub fn readCount(self: *Self) binary.Error!usize {
            const count: usize = @intCast(try self.readInt(u32));
            if (count > limits.collection_entries) return error.LimitExceeded;
            if (count > self.bytes.len - self.offset) return error.Truncated;
            self.total_entries = std.math.add(usize, self.total_entries, count) catch return error.LimitExceeded;
            if (self.total_entries > limits.total_entries) return error.LimitExceeded;
            return count;
        }

        pub fn readString(self: *Self) binary.Error![]const u8 {
            return try self.readLengthPrefixed(limits.string_bytes);
        }

        pub fn readBlob(self: *Self) binary.Error![]const u8 {
            return try self.readLengthPrefixed(limits.blob_bytes);
        }

        pub fn readOptionalString(self: *Self) binary.Error!?[]const u8 {
            if (!try self.readBool()) return null;
            return try self.readString();
        }

        pub fn readOptionalU16(self: *Self) binary.Error!?u16 {
            if (!try self.readBool()) return null;
            return try self.readInt(u16);
        }

        fn readLengthPrefixed(self: *Self, maximum: usize) binary.Error![]const u8 {
            const length: usize = @intCast(try self.readInt(u32));
            if (length > maximum) return error.LimitExceeded;
            return try self.readRaw(length);
        }
    };
}
