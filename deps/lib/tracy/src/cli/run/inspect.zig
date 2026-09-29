const std = @import("std");

const tracy = @import("../../root.zig");
const cli_args = @import("../args/root.zig");
const text = @import("text.zig");

const find_mod = tracy.find;
const source_mod = tracy.source;
const timeline_mod = tracy.timeline;

pub fn find(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.find.parse, find_mod.writeTextFromJsonlPath, find_mod.writeJsonlFromJsonlPath);
}

pub fn source(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.source.parse, source_mod.writeTextFromJsonlPath, source_mod.writeJsonlFromJsonlPath);
}

pub fn timeline(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.timeline.parse, timeline_mod.writeTextFromJsonlPath, timeline_mod.writeJsonlFromJsonlPath);
}
