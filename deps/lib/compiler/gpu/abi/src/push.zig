const std = @import("std");
const assert = std.debug.assert;
const ScalarArgument = @import("launch.zig").ScalarArgument;

/// Push-constant bytes every Vulkan device guarantees.
pub const max_push_constant_bytes: u32 = 128;

/// One-byte scalars are the narrowest members, so a full block holds at most
/// this many. Offsets, widths and the block size are stored as `u8`.
pub const max_push_constant_members: u32 = max_push_constant_bytes;

comptime {
    assert(max_push_constant_bytes <= std.math.maxInt(u8));
}

/// Target facts that bound what an emitter may place in a compiled module.
pub const Limits = struct {
    push_constant_bytes: u32 = max_push_constant_bytes,

    pub fn valid(self: Limits) bool {
        return self.push_constant_bytes % 4 == 0 and
            self.push_constant_bytes <= max_push_constant_bytes;
    }
};

/// Offset of the next push-constant scalar: natural alignment in argument order.
pub fn pushConstantOffset(cursor: u32, byte_size: u32) u32 {
    return std.mem.alignForward(u32, cursor, byte_size);
}

/// Byte range of one push-constant member.
pub const PushConstantMember = struct {
    offset: u32,
    byte_size: u32,
};

/// Push-constant block of one compiled kernel entry, in argument order. The
/// emitter builds it while it lays out the block, the artifact carries it,
/// and the runtime packs launch scalars through it without recomputing it.
pub const PushConstants = struct {
    count: u8 = 0,
    /// Block size, rounded up to 4 bytes as Vulkan requires of push ranges.
    byte_size: u8 = 0,
    offsets: [max_push_constant_members]u8 = @splat(0),
    sizes: [max_push_constant_members]u8 = @splat(0),

    /// Places the next scalar and returns its offset, or refuses when the
    /// block would exceed `limits`.
    pub fn append(
        self: *PushConstants,
        member_byte_size: u32,
        limits: Limits,
    ) error{CapabilityMismatch}!u32 {
        assert(limits.valid());
        assert(memberSizeValid(member_byte_size));
        if (self.count == max_push_constant_members) return error.CapabilityMismatch;
        const offset = pushConstantOffset(self.end(), member_byte_size);
        const block_size = std.mem.alignForward(u32, offset + member_byte_size, 4);
        if (block_size > limits.push_constant_bytes) return error.CapabilityMismatch;
        self.offsets[self.count] = @intCast(offset);
        self.sizes[self.count] = @intCast(member_byte_size);
        self.count += 1;
        self.byte_size = @intCast(block_size);
        assert(self.valid());
        return offset;
    }

    pub fn member(self: *const PushConstants, index: u32) PushConstantMember {
        assert(index < self.count);
        return .{ .offset = self.offsets[index], .byte_size = self.sizes[index] };
    }

    /// Reports whether members are aligned, ordered, disjoint and inside the
    /// block. Decoders call it before trusting a layout read from storage.
    pub fn valid(self: *const PushConstants) bool {
        if (self.byte_size > max_push_constant_bytes or self.byte_size % 4 != 0) return false;
        var cursor: u32 = 0;
        for (self.offsets[0..self.count], self.sizes[0..self.count]) |offset, size| {
            if (!memberSizeValid(size) or offset % size != 0 or offset < cursor) return false;
            cursor = @as(u32, offset) + size;
        }
        if (std.mem.alignForward(u32, cursor, 4) != self.byte_size) return false;
        for (self.offsets[self.count..], self.sizes[self.count..]) |offset, size| {
            if (offset != 0 or size != 0) return false;
        }
        return true;
    }

    /// Writes `scalars` at their recorded offsets and returns the block size.
    /// Each scalar must match its member's width; the bits are copied as is.
    pub fn pack(
        self: *const PushConstants,
        scalars: []const ScalarArgument,
        out: *[max_push_constant_bytes]u8,
    ) error{LaunchArgumentMismatch}!u32 {
        assert(self.valid());
        if (scalars.len != self.count) return error.LaunchArgumentMismatch;
        @memset(out[0..self.byte_size], 0);
        for (scalars, 0..) |scalar, index| {
            const slot = self.member(@intCast(index));
            if (scalar.byteSize() != slot.byte_size) return error.LaunchArgumentMismatch;
            const bytes = out[slot.offset..];
            switch (scalar) {
                .i32 => |value| std.mem.writeInt(i32, bytes[0..4], value, .little),
                .u32 => |value| std.mem.writeInt(u32, bytes[0..4], value, .little),
                .f32 => |value| std.mem.writeInt(u32, bytes[0..4], @bitCast(value), .little),
                .i64 => |value| std.mem.writeInt(i64, bytes[0..8], value, .little),
                .u64 => |value| std.mem.writeInt(u64, bytes[0..8], value, .little),
                .f64 => |value| std.mem.writeInt(u64, bytes[0..8], @bitCast(value), .little),
            }
        }
        return self.byte_size;
    }

    fn end(self: *const PushConstants) u32 {
        if (self.count == 0) return 0;
        const last = self.member(self.count - 1);
        return last.offset + last.byte_size;
    }

    fn memberSizeValid(byte_size: u32) bool {
        return byte_size == 1 or byte_size == 2 or byte_size == 4 or byte_size == 8;
    }
};

test "push-constant scalars align to their own size" {
    try std.testing.expectEqual(@as(u32, 8), pushConstantOffset(4, 8));
    try std.testing.expectEqual(@as(u32, 4), pushConstantOffset(4, 4));
}

test "push-constant layout packs scalars at the offsets it recorded" {
    var layout: PushConstants = .{};
    try std.testing.expectEqual(@as(u32, 0), try layout.append(4, .{}));
    try std.testing.expectEqual(@as(u32, 8), try layout.append(8, .{}));
    try std.testing.expectEqual(@as(u32, 16), try layout.append(4, .{}));
    try std.testing.expectEqual(@as(u8, 20), layout.byte_size);

    var out: [max_push_constant_bytes]u8 = undefined;
    const scalars = [_]ScalarArgument{ .{ .u32 = 7 }, .{ .i64 = -2 }, .{ .f32 = 1.5 } };
    try std.testing.expectEqual(@as(u32, 20), try layout.pack(scalars[0..], &out));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, out[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[4..8], .little));
    try std.testing.expectEqual(@as(i64, -2), std.mem.readInt(i64, out[8..16], .little));
    const float_bits = std.mem.readInt(u32, out[16..20], .little);
    try std.testing.expectEqual(@as(f32, 1.5), @as(f32, @bitCast(float_bits)));
}

test "push-constant layout refuses mismatched launch scalars" {
    var layout: PushConstants = .{};
    _ = try layout.append(4, .{});
    var out: [max_push_constant_bytes]u8 = undefined;
    const wide = [_]ScalarArgument{.{ .u64 = 1 }};
    try std.testing.expectError(error.LaunchArgumentMismatch, layout.pack(wide[0..], &out));
    try std.testing.expectError(error.LaunchArgumentMismatch, layout.pack(&.{}, &out));
}

test "push-constant layout refuses blocks over the target limit" {
    var layout: PushConstants = .{};
    for (0..4) |_| _ = try layout.append(4, .{ .push_constant_bytes = 16 });
    try std.testing.expectError(
        error.CapabilityMismatch,
        layout.append(4, .{ .push_constant_bytes = 16 }),
    );
    try std.testing.expectEqual(@as(u8, 16), layout.byte_size);
}

test "push-constant layout validation rejects misaligned members" {
    var layout: PushConstants = .{};
    _ = try layout.append(8, .{});
    try std.testing.expect(layout.valid());
    layout.offsets[0] = 4;
    try std.testing.expect(!layout.valid());
}
