const std = @import("std");

const tracy = @import("../../root.zig");
const cli_args = @import("../args/root.zig");
const text = @import("text.zig");

const frame_mod = tracy.frame;
const stats_mod = tracy.stats;
const summary_mod = tracy.summary;
const tree_mod = tracy.tree;

pub fn summary(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.summary.parse, summary_mod.writeSummaryFromJsonlPath, summary_mod.writeSummaryJsonlFromJsonlPath);
}

pub fn tree(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.tree.parse, tree_mod.writeTextFromJsonlPath, tree_mod.writeJsonlFromJsonlPath);
}

pub fn stats(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.stats.parse, stats_mod.writeTextFromJsonlPath, stats_mod.writeJsonlFromJsonlPath);
}

pub fn frames(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.frame.parse, frame_mod.writeTextFromJsonlPath, frame_mod.writeJsonlFromJsonlPath);
}
