const std = @import("std");
const sys = @import("sys");
const wayland = @import("../root.zig");

const wire = wayland.wire;

pub const default_byte_count: usize = wire.maximum_message_size;
pub const default_descriptor_count: usize = sys.ancillary.maximum_descriptors;

pub const Limits = struct {
    inbound_byte_count: usize = default_byte_count,
    inbound_descriptor_count: usize = default_descriptor_count,
    outbound_byte_count: usize = default_byte_count,
    outbound_descriptor_count: usize = default_descriptor_count,
};

pub const CapacityError = error{
    InboundByteStorageTooSmall,
    OutboundByteStorageTooSmall,
    CapacityOverflow,
};

pub const Capacity = struct {
    inbound_byte_count: usize,
    inbound_descriptor_count: usize,
    inbound_descriptor_bytes: usize,
    inbound_storage_bytes: usize,
    outbound_byte_count: usize,
    outbound_descriptor_count: usize,
    outbound_descriptor_bytes: usize,
    outbound_storage_bytes: usize,
    total_requested_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        if (limits.inbound_byte_count < wire.header_size) {
            return error.InboundByteStorageTooSmall;
        }
        if (limits.outbound_byte_count < wire.header_size) {
            return error.OutboundByteStorageTooSmall;
        }
        const inbound_descriptor_bytes = std.math.mul(
            usize,
            limits.inbound_descriptor_count,
            @sizeOf(sys.fd.Descriptor),
        ) catch return error.CapacityOverflow;
        const inbound_storage_bytes = std.math.add(
            usize,
            limits.inbound_byte_count,
            inbound_descriptor_bytes,
        ) catch return error.CapacityOverflow;
        const outbound_descriptor_bytes = std.math.mul(
            usize,
            limits.outbound_descriptor_count,
            @sizeOf(sys.fd.Descriptor),
        ) catch return error.CapacityOverflow;
        const outbound_storage_bytes = std.math.add(
            usize,
            limits.outbound_byte_count,
            outbound_descriptor_bytes,
        ) catch return error.CapacityOverflow;
        const total_requested_bytes = std.math.add(
            usize,
            inbound_storage_bytes,
            outbound_storage_bytes,
        ) catch return error.CapacityOverflow;
        return .{
            .inbound_byte_count = limits.inbound_byte_count,
            .inbound_descriptor_count = limits.inbound_descriptor_count,
            .inbound_descriptor_bytes = inbound_descriptor_bytes,
            .inbound_storage_bytes = inbound_storage_bytes,
            .outbound_byte_count = limits.outbound_byte_count,
            .outbound_descriptor_count = limits.outbound_descriptor_count,
            .outbound_descriptor_bytes = outbound_descriptor_bytes,
            .outbound_storage_bytes = outbound_storage_bytes,
            .total_requested_bytes = total_requested_bytes,
        };
    }
};

pub const StorageError = error{
    InboundByteCapacityExceeded,
    InboundDescriptorCapacityExceeded,
    OutboundByteCapacityExceeded,
    OutboundDescriptorCapacityExceeded,
};

pub const Status = struct {
    inbound_byte_capacity_rejection_count: u64 = 0,
    inbound_descriptor_capacity_rejection_count: u64 = 0,
    outbound_byte_capacity_rejection_count: u64 = 0,
    outbound_descriptor_capacity_rejection_count: u64 = 0,
};

pub fn compactSlice(
    comptime T: type,
    items: []T,
    count: *usize,
    offset: *usize,
) void {
    std.debug.assert(offset.* <= count.*);
    std.debug.assert(count.* <= items.len);
    if (offset.* == 0) return;
    const remaining = count.* - offset.*;
    std.mem.copyForwards(T, items[0..remaining], items[offset.*..count.*]);
    count.* = remaining;
    offset.* = 0;
}

test "transport capacity derives four exact storage regions" {
    const capacity = try Capacity.derive(.{
        .inbound_byte_count = 13,
        .inbound_descriptor_count = 2,
        .outbound_byte_count = 17,
        .outbound_descriptor_count = 3,
    });
    const descriptor_size = @sizeOf(sys.fd.Descriptor);
    try std.testing.expectEqual(@as(usize, 13), capacity.inbound_byte_count);
    try std.testing.expectEqual(@as(usize, 2), capacity.inbound_descriptor_count);
    try std.testing.expectEqual(2 * descriptor_size, capacity.inbound_descriptor_bytes);
    try std.testing.expectEqual(13 + 2 * descriptor_size, capacity.inbound_storage_bytes);
    try std.testing.expectEqual(@as(usize, 17), capacity.outbound_byte_count);
    try std.testing.expectEqual(@as(usize, 3), capacity.outbound_descriptor_count);
    try std.testing.expectEqual(3 * descriptor_size, capacity.outbound_descriptor_bytes);
    try std.testing.expectEqual(17 + 3 * descriptor_size, capacity.outbound_storage_bytes);
    try std.testing.expectEqual(30 + 5 * descriptor_size, capacity.total_requested_bytes);
}

test "transport defaults cover one maximum message and ancillary batch" {
    const capacity = try Capacity.derive(.{});
    try std.testing.expectEqual(
        @as(usize, wire.maximum_message_size),
        capacity.inbound_byte_count,
    );
    try std.testing.expectEqual(
        @as(usize, sys.ancillary.maximum_descriptors),
        capacity.inbound_descriptor_count,
    );
    try std.testing.expectEqual(
        @as(usize, wire.maximum_message_size),
        capacity.outbound_byte_count,
    );
    try std.testing.expectEqual(
        @as(usize, sys.ancillary.maximum_descriptors),
        capacity.outbound_descriptor_count,
    );
}

test "transport capacity rejects unusable and overflowing limits" {
    try std.testing.expectError(error.InboundByteStorageTooSmall, Capacity.derive(.{
        .inbound_byte_count = wire.header_size - 1,
    }));
    try std.testing.expectError(error.OutboundByteStorageTooSmall, Capacity.derive(.{
        .outbound_byte_count = wire.header_size - 1,
    }));
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .inbound_descriptor_count = std.math.maxInt(usize),
    }));
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .inbound_byte_count = std.math.maxInt(usize),
    }));
}
