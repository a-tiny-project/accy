const std = @import("std");

pub const DependencyOptions = struct {
    test_allocator_mode: []const u8,
    allocator_diagnostics: []const u8,
    allocator_phase: []const u8,
};

pub const Inputs = struct {
    alloc_locked: ?*std.Build.Module = null,
    alloc_limit: ?*std.Build.Module = null,
    alloc_phase: *std.Build.Module,
    build_options: *std.Build.Module,
    deadalloc: *std.Build.Module,
    gpalloc: *std.Build.Module,
    sys: *std.Build.Module,
};
