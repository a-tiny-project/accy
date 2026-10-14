const std = @import("std");
const sys = @import("sys");

const path_filter = @import("filter.zig");
const source_map = @import("map.zig");

pub const default_source_scope = [_][]const u8{"%"};

pub const Scope = struct {
    patterns: []const []const u8 = &default_source_scope,
    allow_system_sources: bool = true,
};

pub const ResolveError = error{UnsupportedTarget} ||
    std.debug.SelfInfoError ||
    std.mem.Allocator.Error;

pub fn resolveSelfAddress(
    allocator: std.mem.Allocator,
    map: *source_map.Index,
    address: usize,
    scope: Scope,
) ResolveError!?*source_map.Line {
    if (comptime std.debug.SelfInfo == void) return error.UnsupportedTarget;
    return resolveAddress(allocator, map, try std.debug.getSelfDebugInfo(), address, scope);
}

pub fn resolveAddress(
    allocator: std.mem.Allocator,
    map: *source_map.Index,
    debug_info: *std.debug.SelfInfo,
    address: usize,
    scope: Scope,
) ResolveError!?*source_map.Line {
    if (comptime std.debug.SelfInfo == void) {
        return error.UnsupportedTarget;
    }

    if (map.findLineByAddress(address)) |line| return line;
    if (map.isUnresolved(address)) return null;

    const scratch = sys.allocator.debugInfoScratchAllocator();
    var text_arena_state = std.heap.ArenaAllocator.init(scratch);
    defer text_arena_state.deinit();

    var symbols = try std.ArrayList(std.debug.Symbol).initCapacity(scratch, 1);
    defer symbols.deinit(scratch);

    try debug_info.getSymbols(
        sys.stdio.debugIo(),
        scratch,
        text_arena_state.allocator(),
        address,
        true,
        &symbols,
    );

    const line = try resolveSymbols(allocator, map, address, symbols.items, scope);
    if (line == null) map.markUnresolved(allocator, address) catch {};
    return line;
}

pub fn resolveSymbols(
    allocator: std.mem.Allocator,
    map: *source_map.Index,
    address: usize,
    symbols: []const std.debug.Symbol,
    scope: Scope,
) std.mem.Allocator.Error!?*source_map.Line {
    for (symbols) |symbol| {
        const location = symbol.source_location orelse continue;
        if (try resolveLocation(allocator, map, address, location, scope)) |line| return line;
    }

    return null;
}

pub fn resolveLocation(
    allocator: std.mem.Allocator,
    map: *source_map.Index,
    address: usize,
    location: std.debug.SourceLocation,
    scope: Scope,
) std.mem.Allocator.Error!?*source_map.Line {
    if (location.line == 0) return null;
    const in_scope = path_filter.fileMatchesScopeNormalized(location.file_name, scope.patterns, scope.allow_system_sources);
    if (!in_scope) return null;
    return try map.addRange(allocator, location.file_name, location.line, source_map.Interval.unit(address));
}

pub fn resolveSample(
    allocator: std.mem.Allocator,
    map: *source_map.Index,
    sample: source_map.Sample,
    scope: Scope,
) ResolveError!void {
    _ = try resolveSelfAddress(allocator, map, sample.ip, scope);
    for (sample.callchain) |pc| {
        _ = try resolveSelfAddress(allocator, map, pc -| 1, scope);
    }
}
