const std = @import("std");

const tracy = @import("../../root.zig");
const cli_args = @import("../args/root.zig");
const text = @import("text.zig");

const context_mod = tracy.context;
const fiber_mod = tracy.fibers;
const gpu_mod = tracy.gpu;
const lock_mod = tracy.locks;
const memory_mod = tracy.memory;
const message_mod = tracy.messages;
const plot_mod = tracy.plots;
const sample_mod = tracy.samples;
const system_mod = tracy.system;

pub fn context(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.context.parse, context_mod.writeTextFromJsonlPath, context_mod.writeJsonlFromJsonlPath);
}

pub fn memory(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.memory.parse, memory_mod.writeTextFromJsonlPath, memory_mod.writeJsonlFromJsonlPath);
}

pub fn locks(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.lock.parse, lock_mod.writeTextFromJsonlPath, lock_mod.writeJsonlFromJsonlPath);
}

pub fn messages(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.message.parse, message_mod.writeTextFromJsonlPath, message_mod.writeJsonlFromJsonlPath);
}

pub fn samples(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.sample.parse, sample_mod.writeTextFromJsonlPath, sample_mod.writeJsonlFromJsonlPath);
}

pub fn fibers(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.fiber.parse, fiber_mod.writeTextFromJsonlPath, fiber_mod.writeJsonlFromJsonlPath);
}

pub fn gpu(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.gpu.parse, gpu_mod.writeTextFromJsonlPath, gpu_mod.writeJsonlFromJsonlPath);
}

pub fn system(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.system.parse, system_mod.writeTextFromJsonlPath, system_mod.writeJsonlFromJsonlPath);
}

pub fn plots(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    return text.run(allocator, args, cli_args.plot.parse, plot_mod.writeTextFromJsonlPath, plot_mod.writeJsonlFromJsonlPath);
}
