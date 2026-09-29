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

test "self address resolution never allocates resolution scratch from the caller" {
    if (comptime std.debug.SelfInfo == void) return error.SkipZigTest;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var map: source_map.Index = .{};
    defer map.deinit(failing.allocator());

    const patterns = [_][]const u8{"/coz-scratch-test-no-such-scope/%"};
    const line = resolveSelfAddress(
        failing.allocator(),
        &map,
        @returnAddress(),
        .{ .patterns = &patterns },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.ResolutionScratchUsedCallerAllocator,
        else => return error.SkipZigTest,
    };

    try std.testing.expect(line == null);
    try std.testing.expectEqual(@as(usize, 0), map.ranges.items.len);
}

test "self address resolution memoizes unresolvable addresses" {
    if (comptime std.debug.SelfInfo == void) return error.SkipZigTest;

    var map: source_map.Index = .{};
    defer map.deinit(std.testing.allocator);

    const patterns = [_][]const u8{"/coz-memo-test-no-such-scope/%"};
    const address = @returnAddress();
    const line = resolveSelfAddress(std.testing.allocator, &map, address, .{ .patterns = &patterns }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.SkipZigTest,
    };
    try std.testing.expect(line == null);
    try std.testing.expect(map.isUnresolved(address));

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const memoized = try resolveSelfAddress(failing.allocator(), &map, address, .{ .patterns = &patterns });
    try std.testing.expect(memoized == null);
}

test "debug symbols resolve source locations into the source map" {
    var map: source_map.Index = .{};
    defer map.deinit(std.testing.allocator);

    const symbols = [_]std.debug.Symbol{.{
        .name = "sample",
        .compile_unit_name = "unit",
        .source_location = .{
            .file_name = "/tmp/app/main.zig",
            .line = 42,
            .column = 7,
        },
    }};
    const line = (try resolveSymbols(std.testing.allocator, &map, 0x1000, &symbols, .{})).?;

    try std.testing.expectEqualStrings("/tmp/app/main.zig", line.file.name);
    try std.testing.expectEqual(@as(u64, 42), line.number);
    try std.testing.expectEqual(line, map.findLineByAddress(0x1000).?);
}

test "debug symbol resolution honors source scope filtering" {
    var map: source_map.Index = .{};
    defer map.deinit(std.testing.allocator);

    const patterns = [_][]const u8{"/definitely/not/coz/%"};
    const line = try resolveLocation(
        std.testing.allocator,
        &map,
        0x1000,
        .{
            .file_name = "/tmp/app/main.zig",
            .line = 42,
            .column = 7,
        },
        .{ .patterns = &patterns },
    );

    try std.testing.expect(line == null);
    try std.testing.expectEqual(@as(usize, 0), map.ranges.items.len);
}
