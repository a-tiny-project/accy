const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys");
const value = @import("root.zig");

pub const Limits = struct {
    payload_byte_count: usize = value.maximum_payload_size,
    descriptor_count: usize = sys.ancillary.maximum_descriptors,
};

pub const CapacityError = error{
    PayloadStorageTooLarge,
    DescriptorStorageTooLarge,
    CapacityOverflow,
};

pub const Capacity = struct {
    payload_byte_count: usize,
    descriptor_count: usize,
    descriptor_bytes: usize,
    total_requested_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        if (limits.payload_byte_count > value.maximum_payload_size) {
            return error.PayloadStorageTooLarge;
        }
        if (limits.descriptor_count > sys.ancillary.maximum_descriptors) {
            return error.DescriptorStorageTooLarge;
        }
        const descriptor_bytes = std.math.mul(
            usize,
            limits.descriptor_count,
            @sizeOf(sys.fd.Descriptor),
        ) catch return error.CapacityOverflow;
        const total_requested_bytes = std.math.add(
            usize,
            limits.payload_byte_count,
            descriptor_bytes,
        ) catch return error.CapacityOverflow;
        return .{
            .payload_byte_count = limits.payload_byte_count,
            .descriptor_count = limits.descriptor_count,
            .descriptor_bytes = descriptor_bytes,
            .total_requested_bytes = total_requested_bytes,
        };
    }
};

pub const StorageError = error{
    PayloadCapacityExceeded,
    DescriptorCapacityExceeded,
};

pub const Status = struct {
    payload_capacity_rejection_count: u64 = 0,
    descriptor_capacity_rejection_count: u64 = 0,
};

pub const default_capacity = Capacity.derive(.{}) catch unreachable;

const ProtocolError = error{
    InvalidDescriptor,
    InvalidInterface,
    InvalidString,
    InvalidUtf8,
    InvalidVersion,
    MessageTooLarge,
    DescriptorCountMismatch,
    PayloadTooSmall,
    TooManyDescriptors,
};

pub const Error = StorageError || ProtocolError;

pub const Encoder = struct {
    session_allocator: std.mem.Allocator,
    bytes: []u8,
    descriptors: []sys.fd.Descriptor,
    byte_count: usize = 0,
    descriptor_count: usize = 0,
    payload_capacity_rejection_count: u64 = 0,
    descriptor_capacity_rejection_count: u64 = 0,

    pub fn init(
        session_allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!Encoder {
        const bytes = try session_allocator.alloc(u8, capacity.payload_byte_count);
        errdefer if (bytes.len != 0) session_allocator.free(bytes);
        return .{
            .session_allocator = session_allocator,
            .bytes = bytes,
            .descriptors = try session_allocator.alloc(
                sys.fd.Descriptor,
                capacity.descriptor_count,
            ),
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.assertValid();
        if (self.bytes.len != 0) self.session_allocator.free(self.bytes);
        if (self.descriptors.len != 0) self.session_allocator.free(self.descriptors);
        self.* = undefined;
    }

    pub fn reset(self: *Encoder) void {
        self.assertValid();
        self.byte_count = 0;
        self.descriptor_count = 0;
    }

    pub fn signed(self: *Encoder, item: i32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, item, builtin.cpu.arch.endian());
        try self.appendBytes(&bytes);
    }

    pub fn unsigned(self: *Encoder, item: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, item, builtin.cpu.arch.endian());
        try self.appendBytes(&bytes);
    }

    pub fn fixed(self: *Encoder, item: value.Fixed) Error!void {
        try self.signed(item.raw);
    }

    pub fn string(self: *Encoder, text: []const u8) Error!void {
        try validateString(text);
        try self.lengthDelimited(text, true);
    }

    pub fn optionalString(self: *Encoder, text: ?[]const u8) Error!void {
        if (text) |present| return self.string(present);
        try self.unsigned(0);
    }

    pub fn object(self: *Encoder, id: value.ObjectId) Error!void {
        try self.unsigned(id.raw);
    }

    pub fn optionalObject(self: *Encoder, id: ?value.ObjectId) Error!void {
        try self.unsigned(if (id) |present| present.raw else 0);
    }

    pub fn newId(self: *Encoder, id: value.NewId) Error!void {
        try self.unsigned(id.raw);
    }

    pub fn dynamicNewId(
        self: *Encoder,
        interface: []const u8,
        version: u32,
        id: value.NewId,
    ) Error!void {
        if (interface.len == 0) return error.InvalidInterface;
        if (version == 0) return error.InvalidVersion;
        const byte_mark = self.byte_count;
        errdefer self.byte_count = byte_mark;
        try self.string(interface);
        try self.unsigned(version);
        try self.newId(id);
    }

    pub fn array(self: *Encoder, bytes: []const u8) Error!void {
        try self.lengthDelimited(bytes, false);
    }

    pub fn descriptorBorrowed(self: *Encoder, descriptor: sys.fd.Descriptor) Error!void {
        self.assertValid();
        if (descriptor < 0) return error.InvalidDescriptor;
        if (self.descriptor_count == sys.ancillary.maximum_descriptors) {
            return error.TooManyDescriptors;
        }
        if (self.descriptor_count == self.descriptors.len) {
            self.descriptor_capacity_rejection_count +|= 1;
            return error.DescriptorCapacityExceeded;
        }
        self.descriptors[self.descriptor_count] = descriptor;
        self.descriptor_count += 1;
    }

    pub fn finish(
        self: *const Encoder,
        metadata: *const @import("../root.zig").schema.Message,
    ) Error!value.Encoded {
        self.assertValid();
        if (self.byte_count < metadata.minimum_payload_size) return error.PayloadTooSmall;
        if (self.byte_count % 4 != 0) unreachable;
        if (self.descriptor_count != metadata.descriptor_count) {
            return error.DescriptorCountMismatch;
        }
        return .{
            .metadata = metadata,
            .payload = self.bytes[0..self.byte_count],
            .descriptors = self.descriptors[0..self.descriptor_count],
        };
    }

    pub fn status(self: *const Encoder) Status {
        self.assertValid();
        return .{
            .payload_capacity_rejection_count = self.payload_capacity_rejection_count,
            .descriptor_capacity_rejection_count = self.descriptor_capacity_rejection_count,
        };
    }

    fn appendBytes(self: *Encoder, bytes: []const u8) Error!void {
        try self.ensurePayloadCapacity(bytes.len);
        @memcpy(self.bytes[self.byte_count..][0..bytes.len], bytes);
        self.byte_count += bytes.len;
    }

    fn lengthDelimited(self: *Encoder, bytes: []const u8, terminal_zero: bool) Error!void {
        const logical_len = std.math.add(usize, bytes.len, @intFromBool(terminal_zero)) catch {
            return error.MessageTooLarge;
        };
        if (logical_len > std.math.maxInt(u32)) return error.MessageTooLarge;
        const rounded_len = std.math.add(usize, logical_len, 3) catch return error.MessageTooLarge;
        const padded_len = rounded_len & ~@as(usize, 3);
        const encoded_len = std.math.add(usize, 4, padded_len) catch return error.MessageTooLarge;
        try self.ensurePayloadCapacity(encoded_len);

        var length_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &length_bytes, @intCast(logical_len), builtin.cpu.arch.endian());
        @memcpy(self.bytes[self.byte_count..][0..length_bytes.len], &length_bytes);
        self.byte_count += length_bytes.len;
        @memcpy(self.bytes[self.byte_count..][0..bytes.len], bytes);
        self.byte_count += bytes.len;
        if (terminal_zero) {
            self.bytes[self.byte_count] = 0;
            self.byte_count += 1;
        }
        const padding = padded_len - logical_len;
        @memset(self.bytes[self.byte_count..][0..padding], 0);
        self.byte_count += padding;
    }

    fn ensurePayloadCapacity(self: *Encoder, additional: usize) Error!void {
        self.assertValid();
        const total = std.math.add(usize, self.byte_count, additional) catch {
            return error.MessageTooLarge;
        };
        if (total > value.maximum_payload_size) return error.MessageTooLarge;
        if (total > self.bytes.len) {
            self.payload_capacity_rejection_count +|= 1;
            return error.PayloadCapacityExceeded;
        }
    }

    fn assertValid(self: *const Encoder) void {
        std.debug.assert(self.byte_count <= self.bytes.len);
        std.debug.assert(self.descriptor_count <= self.descriptors.len);
    }
};

fn validateString(text: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidString;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
}

test "encoder distinguishes null and empty strings" {
    const protocol = @import("../root.zig");
    const metadata: protocol.schema.Message = .{
        .name = "strings",
        .opcode = 0,
        .since = 1,
        .deprecated_since = null,
        .destructor = false,
        .signature = "?ss",
        .descriptor_count = 0,
        .minimum_payload_size = 12,
        .arguments = &.{},
    };
    var encoder = try Encoder.init(std.testing.allocator, default_capacity);
    defer encoder.deinit();
    try encoder.optionalString(null);
    try encoder.string("");
    const encoded = try encoder.finish(&metadata);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 },
        encoded.payload,
    );
}

test "encoder rejects invalid protocol strings and oversized payloads" {
    var encoder = try Encoder.init(std.testing.allocator, default_capacity);
    defer encoder.deinit();
    try std.testing.expectError(error.InvalidString, encoder.string("a\x00b"));
    try std.testing.expectError(error.InvalidUtf8, encoder.string("\xff"));
    var oversized: [value.maximum_payload_size]u8 = undefined;
    try std.testing.expectError(error.MessageTooLarge, encoder.array(&oversized));
}

test "encoder accounts for schema descriptors before exposing a message" {
    const protocol = @import("../root.zig");
    const metadata: protocol.schema.Message = .{
        .name = "descriptor",
        .opcode = 0,
        .since = 1,
        .deprecated_since = null,
        .destructor = false,
        .signature = "h",
        .descriptor_count = 1,
        .minimum_payload_size = 0,
        .arguments = &.{},
    };
    var encoder = try Encoder.init(std.testing.allocator, default_capacity);
    defer encoder.deinit();
    try std.testing.expectError(error.DescriptorCountMismatch, encoder.finish(&metadata));
    try std.testing.expectError(error.InvalidDescriptor, encoder.descriptorBorrowed(-1));
    try encoder.descriptorBorrowed(23);
    const encoded = try encoder.finish(&metadata);
    try std.testing.expectEqual(@as(usize, 0), encoded.payload.len);
    try std.testing.expectEqualSlices(sys.fd.Descriptor, &.{23}, encoded.descriptors);
}

test "encoder capacity derives exact payload and descriptor storage" {
    const capacity = try Capacity.derive(.{
        .payload_byte_count = 13,
        .descriptor_count = 3,
    });
    try std.testing.expectEqual(@as(usize, 13), capacity.payload_byte_count);
    try std.testing.expectEqual(@as(usize, 3), capacity.descriptor_count);
    try std.testing.expectEqual(
        3 * @sizeOf(sys.fd.Descriptor),
        capacity.descriptor_bytes,
    );
    try std.testing.expectEqual(
        13 + 3 * @sizeOf(sys.fd.Descriptor),
        capacity.total_requested_bytes,
    );
    try std.testing.expectError(error.PayloadStorageTooLarge, Capacity.derive(.{
        .payload_byte_count = value.maximum_payload_size + 1,
    }));
    try std.testing.expectError(error.DescriptorStorageTooLarge, Capacity.derive(.{
        .descriptor_count = sys.ancillary.maximum_descriptors + 1,
    }));
}

test "encoder acquires both regions before use" {
    const capacity = try Capacity.derive(.{
        .payload_byte_count = 8,
        .descriptor_count = 1,
    });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        Encoder.init(failing.allocator(), capacity),
    );
    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        Encoder.init(failing.allocator(), capacity),
    );
    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 2,
    });
    var encoder = try Encoder.init(failing.allocator(), capacity);
    defer encoder.deinit();
    try std.testing.expectEqual(@as(usize, 2), failing.allocations);
}

test "encoder max plus one preserves payload and saturates status" {
    const capacity = try Capacity.derive(.{
        .payload_byte_count = 4,
        .descriptor_count = 1,
    });
    var encoder = try Encoder.init(std.testing.allocator, capacity);
    defer encoder.deinit();
    try encoder.unsigned(7);
    try std.testing.expectError(error.PayloadCapacityExceeded, encoder.unsigned(8));
    try std.testing.expectEqual(@as(usize, 4), encoder.byte_count);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(
        u32,
        encoder.bytes[0..4],
        builtin.cpu.arch.endian(),
    ));
    try std.testing.expectEqual(@as(u64, 1), encoder.status().payload_capacity_rejection_count);

    encoder.payload_capacity_rejection_count = std.math.maxInt(u64);
    try std.testing.expectError(error.PayloadCapacityExceeded, encoder.unsigned(8));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        encoder.status().payload_capacity_rejection_count,
    );
}

test "encoder max plus one preserves borrowed descriptors" {
    const capacity = try Capacity.derive(.{
        .payload_byte_count = 0,
        .descriptor_count = 1,
    });
    var encoder = try Encoder.init(std.testing.allocator, capacity);
    defer encoder.deinit();
    try encoder.descriptorBorrowed(7);
    try std.testing.expectError(
        error.DescriptorCapacityExceeded,
        encoder.descriptorBorrowed(8),
    );
    try std.testing.expectEqualSlices(
        sys.fd.Descriptor,
        &.{7},
        encoder.descriptors[0..encoder.descriptor_count],
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        encoder.status().descriptor_capacity_rejection_count,
    );

    encoder.descriptor_capacity_rejection_count = std.math.maxInt(u64);
    try std.testing.expectError(
        error.DescriptorCapacityExceeded,
        encoder.descriptorBorrowed(8),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        encoder.status().descriptor_capacity_rejection_count,
    );
}
