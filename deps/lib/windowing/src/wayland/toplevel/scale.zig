const std = @import("std");

pub const fractional_denominator: u32 = 120;

pub const State = struct {
    fractional_numerator: ?u32 = null,
    integer_scale: u32 = 1,

    pub fn setFractional(self: *State, value: ?u32) bool {
        const normalized = if (value) |raw| if (raw == 0) null else raw else null;
        if (self.fractional_numerator == normalized) return false;
        self.fractional_numerator = normalized;
        return true;
    }

    pub fn setInteger(self: *State, value: u32) bool {
        const normalized = @max(value, 1);
        if (self.integer_scale == normalized) return false;
        self.integer_scale = normalized;
        return true;
    }

    pub fn numerator(self: State) u64 {
        return self.fractional_numerator orelse @as(u64, self.integer_scale) * fractional_denominator;
    }

    pub fn factor(self: State) f32 {
        return @as(f32, @floatFromInt(self.numerator())) / @as(f32, fractional_denominator);
    }

    pub fn bufferScale(self: State) u32 {
        return if (self.fractional_numerator != null) 1 else self.integer_scale;
    }

    pub fn usesViewport(self: State) bool {
        return self.fractional_numerator != null;
    }

    pub fn framebufferDimension(self: State, logical: u32) error{DimensionOverflow}!u32 {
        const scaled = @as(u128, logical) * self.numerator() + fractional_denominator / 2;
        return std.math.cast(u32, scaled / fractional_denominator) orelse error.DimensionOverflow;
    }
};

test "fractional scale takes precedence and rounds half away from zero" {
    var state = State{};
    try std.testing.expectEqual(@as(f32, 1), state.factor());
    try std.testing.expectEqual(@as(u32, 101), try state.framebufferDimension(101));

    try std.testing.expect(state.setInteger(2));
    try std.testing.expectEqual(@as(f32, 2), state.factor());
    try std.testing.expectEqual(@as(u32, 202), try state.framebufferDimension(101));

    try std.testing.expect(state.setFractional(150));
    try std.testing.expectEqual(@as(f32, 1.25), state.factor());
    try std.testing.expectEqual(@as(u32, 126), try state.framebufferDimension(101));
    try std.testing.expectEqual(@as(u32, 1), state.bufferScale());
    try std.testing.expect(state.usesViewport());

    try std.testing.expect(state.setFractional(180));
    try std.testing.expectEqual(@as(f32, 1.5), state.factor());
    try std.testing.expectEqual(@as(u32, 152), try state.framebufferDimension(101));
}

test "zero scales normalize to valid fallbacks" {
    var state = State{};
    try std.testing.expect(!state.setInteger(0));
    try std.testing.expect(!state.setFractional(0));
    try std.testing.expect(state.setFractional(150));
    try std.testing.expect(state.setFractional(null));
    try std.testing.expectEqual(@as(f32, 1), state.factor());
}

test "framebuffer dimensions reject values beyond u32" {
    var state = State{ .integer_scale = std.math.maxInt(u32) };
    try std.testing.expectError(error.DimensionOverflow, state.framebufferDimension(2));
}
