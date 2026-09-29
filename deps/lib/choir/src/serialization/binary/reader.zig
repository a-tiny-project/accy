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

test "binary reader rejects malformed primitive and aggregate fields" {
    const limits = binary.Limits{
        .serialized_bytes = 128,
        .string_bytes = 8,
        .blob_bytes = 16,
        .collection_entries = 4,
        .total_entries = 8,
    };
    const TestReader = Reader(limits);

    var invalid_bool = try TestReader.init(&.{2});
    try std.testing.expectError(error.InvalidValue, invalid_bool.readBool());

    var invalid_string_length: [@sizeOf(u32)]u8 = undefined;
    std.mem.writeInt(u32, &invalid_string_length, limits.string_bytes + 1, .little);
    var invalid_string = try TestReader.init(&invalid_string_length);
    try std.testing.expectError(error.LimitExceeded, invalid_string.readString());

    var invalid_blob_length: [@sizeOf(u32)]u8 = undefined;
    std.mem.writeInt(u32, &invalid_blob_length, limits.blob_bytes + 1, .little);
    var invalid_blob = try TestReader.init(&invalid_blob_length);
    try std.testing.expectError(error.LimitExceeded, invalid_blob.readBlob());

    const count_fields = limits.total_entries / limits.collection_entries + 1;
    var aggregate_bytes: [limits.collection_entries + count_fields * @sizeOf(u32)]u8 = @splat(0);
    for (0..count_fields) |index| {
        const offset = index * @sizeOf(u32);
        std.mem.writeInt(u32, aggregate_bytes[offset..][0..@sizeOf(u32)], limits.collection_entries, .little);
    }
    var aggregate = try TestReader.init(&aggregate_bytes);
    for (0..count_fields - 1) |_| _ = try aggregate.readCount();
    try std.testing.expectError(error.LimitExceeded, aggregate.readCount());
}
