const std = @import("std");

const config = @import("config.zig");
const Marsaglia = @import("rng.zig").Marsaglia;

const Allocator = std.mem.Allocator;
const StackConfig = config.StackConfig;

pub const StackPad = struct {
    unit: u8,
    bytes: usize,
};

pub const StackPads = struct {
    allocator: Allocator,
    config: StackConfig,
    entries: []u8 = &.{},
    index: usize = 0,

    pub fn init(allocator: Allocator, stack_config: StackConfig, rng: *Marsaglia) !StackPads {
        var self: StackPads = .{
            .allocator = allocator,
            .config = normalizeStackConfig(stack_config),
        };
        if (self.config.enabled) {
            self.entries = try allocator.alloc(u8, self.config.entries);
            self.refill(rng);
        }
        return self;
    }

    pub fn deinit(self: *StackPads) void {
        if (self.entries.len > 0) self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn refill(self: *StackPads, rng: *Marsaglia) void {
        for (self.entries) |*entry| entry.* = rng.nextByte();
        self.index = 0;
    }

    pub fn next(self: *StackPads, rng: *Marsaglia) StackPad {
        if (!self.config.enabled) return .{ .unit = 0, .bytes = 0 };
        if (self.index >= self.entries.len) self.refill(rng);
        const unit = self.entries[self.index];
        self.index += 1;
        return .{ .unit = unit, .bytes = @as(usize, unit) * self.config.alignment };
    }
};

fn normalizeStackConfig(stack_config: StackConfig) StackConfig {
    var out = stack_config;
    if (out.entries == 0) out.entries = 1;
    out.alignment = config.stack_alignment;
    return out;
}
