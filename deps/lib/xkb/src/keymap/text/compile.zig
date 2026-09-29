const std = @import("std");
const xkb = @import("../../root.zig");
const parse = @import("parse/root.zig");
const resolve = @import("resolve.zig");

pub const Error = parse.Error || resolve.Error;

pub const Compiled = struct {
    arena: std.heap.ArenaAllocator,
    value: *const xkb.keymap.Keymap,

    pub fn keymap(self: *const Compiled) *const xkb.keymap.Keymap {
        return self.value;
    }

    pub fn deinit(self: *Compiled) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn compile(allocator: std.mem.Allocator, input: []const u8) Error!Compiled {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    const parsed_document = try parse.parse(arena_allocator, input);
    const value = try resolve.resolve(arena_allocator, parsed_document);
    return .{ .arena = arena, .value = value };
}
