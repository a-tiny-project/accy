const std = @import("std");
const hypothesis = @import("hypothesis");
const wayland = @import("wayland");

const properties = @import("root.zig");

const protocol_properties = properties.protocol;
const shm_properties = properties.shm;
const storage_properties = properties.storage;

const maximum_messages = 6;
const maximum_payload = 32;

fn settings(seed: u64) hypothesis.Settings {
    return hypothesis.Settings.quick()
        .withSeed(seed)
        .withDatabase("zig-out/hypothesis-failures/wayland");
}

fn drawUsize(data: *hypothesis.ConjectureData, min: usize, max: usize, towards: usize) !usize {
    return @intCast(try data.drawInteger(@intCast(min), @intCast(max), @intCast(towards)));
}

const HeaderRoundTrip = struct {
    pub fn property(data: *hypothesis.ConjectureData, _: std.mem.Allocator) !void {
        const object_id: u32 = @intCast(try data.drawInteger(1, std.math.maxInt(u32), 1));
        const opcode: u16 = @intCast(try data.drawInteger(0, std.math.maxInt(u16), 0));
        const payload_size = 4 * try drawUsize(data, 0, maximum_payload / 4, 0);
        const expected = try wayland.wire.Header.init(object_id, opcode, payload_size);
        var encoded: [wayland.wire.header_size]u8 = undefined;
        try expected.encode(&encoded);
        try std.testing.expectEqual(expected, try wayland.wire.decode(&encoded));
    }
};

const ChunkEquivalence = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: std.mem.Allocator) !void {
        const message_count = try drawUsize(data, 1, maximum_messages, 2);
        var headers: [maximum_messages]wayland.wire.Header = undefined;
        var payload_offsets: [maximum_messages]usize = undefined;
        var payload_lengths: [maximum_messages]usize = undefined;
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(allocator);

        for (0..message_count) |message_index| {
            const payload_len = 4 * try drawUsize(data, 0, maximum_payload / 4, 1);
            const opcode: u16 = @intCast(try data.drawInteger(0, std.math.maxInt(u16), 0));
            const payload = try data.drawBytes(payload_len, payload_len);
            const header = try wayland.wire.Header.init(
                @intCast(message_index + 2),
                opcode,
                payload.len,
            );
            var header_bytes: [wayland.wire.header_size]u8 = undefined;
            try header.encode(&header_bytes);
            try encoded.appendSlice(allocator, &header_bytes);
            payload_offsets[message_index] = encoded.items.len;
            payload_lengths[message_index] = payload.len;
            try encoded.appendSlice(allocator, payload);
            headers[message_index] = header;
        }

        const capacity = try wayland.stream.Capacity.derive(.{
            .inbound_byte_count = encoded.items.len,
        });
        var inbox = try wayland.stream.Inbox.init(allocator, capacity);
        defer inbox.deinit();
        var source_offset: usize = 0;
        var decoded_count: usize = 0;
        while (source_offset < encoded.items.len) {
            const remaining = encoded.items.len - source_offset;
            const chunk_len = try drawUsize(data, 1, @min(remaining, 19), 1);
            try inbox.appendOwned(encoded.items[source_offset..][0..chunk_len], &.{});
            source_offset += chunk_len;
            while (try inbox.peek()) |frame| {
                try std.testing.expectEqual(headers[decoded_count], frame.header);
                const payload_offset = payload_offsets[decoded_count];
                const payload_len = payload_lengths[decoded_count];
                try std.testing.expectEqualSlices(
                    u8,
                    encoded.items[payload_offset..][0..payload_len],
                    frame.payload,
                );
                try inbox.consume();
                decoded_count += 1;
            }
        }
        try std.testing.expectEqual(message_count, decoded_count);
        try std.testing.expectEqual(@as(usize, 0), inbox.queuedByteCount());
    }
};

test "property: Wayland headers round trip" {
    try hypothesis.checkNamed(HeaderRoundTrip, "wayland-header-round-trip", settings(0x5741_594c_414e_4401));
}

test "property: fragmented input matches contiguous message decoding" {
    try hypothesis.checkNamed(ChunkEquivalence, "wayland-chunk-equivalence", settings(0x5741_594c_414e_4402));
}

test {
    _ = protocol_properties;
    _ = shm_properties;
    _ = storage_properties;
    std.testing.refAllDecls(@This());
}
