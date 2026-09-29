const std = @import("std");
const Allocator = std.mem.Allocator;
const artifact = @import("root.zig");
const slice = artifact.slice;

pub const OptionValueTag = enum(u8) {
    flag = 1,
    signed = 2,
    unsigned = 3,
    text = 4,
    bytes = 5,
};

pub const OptionValue = union(OptionValueTag) {
    flag: bool,
    signed: i64,
    unsigned: u64,
    text: []const u8,
    bytes: []const u8,

    pub fn dupe(self: OptionValue, allocator: Allocator) Allocator.Error!OptionValue {
        return switch (self) {
            .flag => |value| .{ .flag = value },
            .signed => |value| .{ .signed = value },
            .unsigned => |value| .{ .unsigned = value },
            .text => |value| .{ .text = try slice.dupe(allocator, value) },
            .bytes => |value| .{ .bytes = try slice.dupe(allocator, value) },
        };
    }

    pub fn deinit(self: OptionValue, allocator: Allocator) void {
        switch (self) {
            .text => |value| slice.free(allocator, value),
            .bytes => |value| slice.free(allocator, value),
            else => {},
        }
    }

    pub fn eql(self: OptionValue, other: OptionValue) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .flag => |value| value == other.flag,
            .signed => |value| value == other.signed,
            .unsigned => |value| value == other.unsigned,
            .text => |value| std.mem.eql(u8, value, other.text),
            .bytes => |value| std.mem.eql(u8, value, other.bytes),
        };
    }
};

pub const BuildOption = struct {
    key: []const u8,
    value: OptionValue,

    pub fn dupe(self: BuildOption, allocator: Allocator) Allocator.Error!BuildOption {
        const key = try slice.dupe(allocator, self.key);
        errdefer slice.free(allocator, key);
        return .{ .key = key, .value = try self.value.dupe(allocator) };
    }

    pub fn deinit(self: BuildOption, allocator: Allocator) void {
        slice.free(allocator, self.key);
        self.value.deinit(allocator);
    }

    pub fn eql(self: BuildOption, other: BuildOption) bool {
        return std.mem.eql(u8, self.key, other.key) and self.value.eql(other.value);
    }
};

pub const Options = struct {
    allocator: Allocator,
    values: std.ArrayListUnmanaged(BuildOption) = .empty,

    pub fn init(allocator: Allocator) Options {
        return .{ .allocator = allocator };
    }

    pub fn add(self: *Options, option: BuildOption) Allocator.Error!void {
        try self.values.ensureTotalCapacity(self.allocator, self.values.items.len + 1);
        const owned = try option.dupe(self.allocator);
        self.values.appendAssumeCapacity(owned);
    }

    pub fn cloneInto(self: Options, target: *Options) Allocator.Error!void {
        for (self.values.items) |option| try target.add(option);
    }

    pub fn deinit(self: *Options) void {
        for (self.values.items) |option| option.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn eql(self: Options, other: Options) bool {
        if (self.values.items.len != other.values.items.len) return false;
        for (self.values.items, other.values.items) |left, right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }
};
