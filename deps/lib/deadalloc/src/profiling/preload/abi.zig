const std = @import("std");
const coz = @import("coz");
const deadalloc = @import("deadalloc");
const sys = @import("sys");
const state = @import("state.zig");

const posix_einval = 22;
const posix_enomem = 12;

pub fn malloc(size: usize) callconv(.c) ?*anyopaque {
    return state.allocate(size, state.c_alignment);
}

pub fn free(ptr: ?*anyopaque) callconv(.c) void {
    state.deallocate(ptr);
}

pub fn calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    const phase = coz.scope("deadalloc.preload.calloc");
    defer phase.end();

    const total = std.math.mul(usize, count, size) catch return null;
    const ptr = state.allocate(total, state.c_alignment) orelse return null;
    @memset(state.asBytes(ptr, total), 0);
    return ptr;
}

pub fn __libc_malloc(size: usize) callconv(.c) ?*anyopaque {
    return malloc(size);
}

pub fn __libc_calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    return calloc(count, size);
}

pub fn __libc_free(ptr: ?*anyopaque) callconv(.c) void {
    free(ptr);
}

pub fn cfree(ptr: ?*anyopaque) callconv(.c) void {
    free(ptr);
}

pub fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return state.reallocate(ptr, size);
}

pub fn reallocarray(ptr: ?*anyopaque, count: usize, size: usize) callconv(.c) ?*anyopaque {
    const total = std.math.mul(usize, count, size) catch return null;
    return realloc(ptr, total);
}

pub fn aligned_alloc(alignment: usize, size: usize) callconv(.c) ?*anyopaque {
    if (!state.validAlignment(alignment)) return null;
    if (size % alignment != 0) return null;
    return state.allocate(size, alignment);
}

pub fn posix_memalign(out_ptr: *?*anyopaque, alignment: usize, size: usize) callconv(.c) c_int {
    if (!state.validAlignment(alignment) or alignment % @sizeOf(*anyopaque) != 0) {
        out_ptr.* = null;
        return posix_einval;
    }
    const ptr = state.allocate(size, alignment) orelse {
        out_ptr.* = null;
        return posix_enomem;
    };
    out_ptr.* = ptr;
    return 0;
}

pub fn memalign(alignment: usize, size: usize) callconv(.c) ?*anyopaque {
    if (!state.validAlignment(alignment)) return null;
    return state.allocate(size, alignment);
}

pub fn __libc_memalign(alignment: usize, size: usize) callconv(.c) ?*anyopaque {
    return memalign(alignment, size);
}

pub fn valloc(size: usize) callconv(.c) ?*anyopaque {
    return state.allocate(size, deadalloc.page_size);
}

pub fn pvalloc(size: usize) callconv(.c) ?*anyopaque {
    const rounded = state.alignPageLen(size) orelse return null;
    return valloc(rounded);
}

pub fn __libc_realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return realloc(ptr, size);
}

pub fn malloc_usable_size(ptr: ?*anyopaque) callconv(.c) usize {
    return state.usableSize(ptr);
}

pub fn mallopt(number: c_int, value: c_int) callconv(.c) c_int {
    _ = number;
    _ = value;
    return 0;
}

pub fn strdup(s: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const source = s orelse return null;
    const len = std.mem.len(source);
    const allocation_len = std.math.add(usize, len, 1) catch return null;
    const ptr = malloc(allocation_len) orelse return null;
    const dest: [*]u8 = @ptrCast(ptr);
    @memcpy(dest[0..len], source[0..len]);
    dest[len] = 0;
    return @ptrCast(dest);
}

pub fn strndup(s: ?[*]const u8, max_len: usize) callconv(.c) ?[*:0]u8 {
    const source = s orelse return null;
    const len = state.boundedStringLen(source, max_len);
    const allocation_len = std.math.add(usize, len, 1) catch return null;
    const ptr = malloc(allocation_len) orelse return null;
    const dest: [*]u8 = @ptrCast(ptr);
    @memcpy(dest[0..len], source[0..len]);
    dest[len] = 0;
    return @ptrCast(dest);
}

pub fn _Znwm(size: usize) callconv(.c) ?*anyopaque {
    return malloc(size);
}

pub fn _Znam(size: usize) callconv(.c) ?*anyopaque {
    return malloc(size);
}

pub fn _ZnwmRKSt9nothrow_t(size: usize, nothrow: ?*const anyopaque) callconv(.c) ?*anyopaque {
    _ = nothrow;
    return malloc(size);
}

pub fn _ZnamRKSt9nothrow_t(size: usize, nothrow: ?*const anyopaque) callconv(.c) ?*anyopaque {
    _ = nothrow;
    return malloc(size);
}

pub fn _ZnwmSt11align_val_t(size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return memalign(alignment, size);
}

pub fn _ZnamSt11align_val_t(size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return memalign(alignment, size);
}

pub fn _ZnwmSt11align_val_tRKSt9nothrow_t(size: usize, alignment: usize, nothrow: ?*const anyopaque) callconv(.c) ?*anyopaque {
    _ = nothrow;
    return memalign(alignment, size);
}

pub fn _ZnamSt11align_val_tRKSt9nothrow_t(size: usize, alignment: usize, nothrow: ?*const anyopaque) callconv(.c) ?*anyopaque {
    _ = nothrow;
    return memalign(alignment, size);
}

pub fn _ZdlPv(ptr: ?*anyopaque) callconv(.c) void {
    free(ptr);
}

pub fn _ZdaPv(ptr: ?*anyopaque) callconv(.c) void {
    free(ptr);
}

pub fn _ZdlPvm(ptr: ?*anyopaque, size: usize) callconv(.c) void {
    _ = size;
    free(ptr);
}

pub fn _ZdaPvm(ptr: ?*anyopaque, size: usize) callconv(.c) void {
    _ = size;
    free(ptr);
}

pub fn _ZdlPvSt11align_val_t(ptr: ?*anyopaque, alignment: usize) callconv(.c) void {
    _ = alignment;
    free(ptr);
}

pub fn _ZdaPvSt11align_val_t(ptr: ?*anyopaque, alignment: usize) callconv(.c) void {
    _ = alignment;
    free(ptr);
}

pub fn _ZdlPvmSt11align_val_t(ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
    _ = size;
    _ = alignment;
    free(ptr);
}

pub fn _ZdaPvmSt11align_val_t(ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
    _ = size;
    _ = alignment;
    free(ptr);
}

pub fn _ZdlPvSt11align_val_tRKSt9nothrow_t(ptr: ?*anyopaque, alignment: usize, nothrow: ?*const anyopaque) callconv(.c) void {
    _ = alignment;
    _ = nothrow;
    free(ptr);
}

pub fn _ZdaPvSt11align_val_tRKSt9nothrow_t(ptr: ?*anyopaque, alignment: usize, nothrow: ?*const anyopaque) callconv(.c) void {
    _ = alignment;
    _ = nothrow;
    free(ptr);
}

test "preload allocator preserves usable size and alignment" {
    const ptr = malloc(32) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 32), malloc_usable_size(ptr));
    free(ptr);
    try std.testing.expectEqual(@as(usize, 0), malloc_usable_size(ptr));

    const aligned = aligned_alloc(64, 256) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned) % 64);
    try std.testing.expectEqual(@as(usize, 256), malloc_usable_size(aligned));
    free(aligned);
}

test "preload allocator records invalid and double frees" {
    const invalid_before = state.report().counters.invalid_free;
    const double_before = state.report().counters.double_free;

    const ptr = malloc(32) orelse return error.OutOfMemory;
    const bytes = state.asBytes(ptr, 32);
    free(@ptrCast(bytes[1..].ptr));
    free(ptr);
    free(ptr);

    const got = state.report();
    if (state.diagnosticsEnabled()) {
        try std.testing.expect(got.counters.invalid_free >= invalid_before + 1);
        try std.testing.expect(got.counters.double_free >= double_before + 1);
    } else {
        try std.testing.expectEqual(invalid_before, got.counters.invalid_free);
        try std.testing.expectEqual(double_before, got.counters.double_free);
    }
}

test "preload allocator realloc preserves contents" {
    const ptr = malloc(16) orelse return error.OutOfMemory;
    const bytes = state.asBytes(ptr, 16);
    @memset(bytes, 0x5a);

    const grown = realloc(ptr, 128) orelse return error.OutOfMemory;
    const grown_bytes = state.asBytes(grown, 128);
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0x5a))), grown_bytes[0..16]);
    try std.testing.expectEqual(@as(usize, 128), malloc_usable_size(grown));
    free(grown);
}

test "preload allocator realloc shrink updates usable size" {
    const ptr = malloc(128) orelse return error.OutOfMemory;
    const bytes = state.asBytes(ptr, 128);
    @memset(bytes, 0x3c);

    const shrunk = realloc(ptr, 16) orelse return error.OutOfMemory;
    try std.testing.expectEqual(ptr, shrunk);
    const shrunk_bytes = state.asBytes(shrunk, 16);
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0x3c))), shrunk_bytes);
    try std.testing.expectEqual(@as(usize, 16), malloc_usable_size(shrunk));
    free(shrunk);
}

test "preload allocator exposes glibc compatibility entry points" {
    const libc_allocated = __libc_malloc(48) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 48), malloc_usable_size(libc_allocated));
    __libc_free(libc_allocated);
    try std.testing.expectEqual(@as(usize, 0), malloc_usable_size(libc_allocated));

    const libc_zeroed = __libc_calloc(4, 8) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 32), malloc_usable_size(libc_zeroed));
    for (state.asBytes(libc_zeroed, 32)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    __libc_free(libc_zeroed);

    const aligned = __libc_memalign(128, 96) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned) % 128);
    try std.testing.expectEqual(@as(usize, 96), malloc_usable_size(aligned));

    const grown = __libc_realloc(aligned, 160) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 160), malloc_usable_size(grown));
    cfree(grown);
    try std.testing.expectEqual(@as(usize, 0), malloc_usable_size(grown));

    const page = pvalloc(17) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(page) % deadalloc.page_size);
    try std.testing.expectEqual(deadalloc.page_size, malloc_usable_size(page));
    free(page);

    const array = reallocarray(null, 4, 8) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 32), malloc_usable_size(array));
    try std.testing.expect(reallocarray(null, std.math.maxInt(usize), 2) == null);
    free(array);

    try std.testing.expectEqual(@as(c_int, 0), mallopt(0, 0));
}

test "preload allocator duplicates strings through intercepted allocation" {
    const whole = strdup("deadalloc") orelse return error.OutOfMemory;
    defer free(@ptrCast(whole));
    try std.testing.expectEqualStrings("deadalloc", std.mem.span(whole));
    try std.testing.expectEqual(@as(usize, 10), malloc_usable_size(@ptrCast(whole)));

    const prefix = strndup("deadalloc", 4) orelse return error.OutOfMemory;
    defer free(@ptrCast(prefix));
    try std.testing.expectEqualStrings("dead", std.mem.span(prefix));
    try std.testing.expectEqual(@as(usize, 5), malloc_usable_size(@ptrCast(prefix)));

    try std.testing.expect(strdup(null) == null);
    try std.testing.expect(strndup(null, 4) == null);
}

test "preload allocator exposes C++ allocation entry points" {
    var token: usize = 0;

    const scalar = _Znwm(24) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 24), malloc_usable_size(scalar));
    _ZdlPv(scalar);
    try std.testing.expectEqual(@as(usize, 0), malloc_usable_size(scalar));

    const array = _Znam(40) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 40), malloc_usable_size(array));
    _ZdaPvm(array, 40);
    try std.testing.expectEqual(@as(usize, 0), malloc_usable_size(array));

    const nothrow_scalar = _ZnwmRKSt9nothrow_t(33, &token) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 33), malloc_usable_size(nothrow_scalar));
    _ZdlPvm(nothrow_scalar, 33);

    const nothrow_array = _ZnamRKSt9nothrow_t(41, &token) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 41), malloc_usable_size(nothrow_array));
    _ZdaPv(nothrow_array);

    const aligned_scalar = _ZnwmSt11align_val_t(57, 64) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned_scalar) % 64);
    try std.testing.expectEqual(@as(usize, 57), malloc_usable_size(aligned_scalar));
    _ZdlPvSt11align_val_t(aligned_scalar, 64);

    const aligned_array = _ZnamSt11align_val_t(65, 128) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned_array) % 128);
    try std.testing.expectEqual(@as(usize, 65), malloc_usable_size(aligned_array));
    _ZdaPvmSt11align_val_t(aligned_array, 65, 128);

    const aligned_nothrow_scalar = _ZnwmSt11align_val_tRKSt9nothrow_t(73, 256, &token) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned_nothrow_scalar) % 256);
    try std.testing.expectEqual(@as(usize, 73), malloc_usable_size(aligned_nothrow_scalar));
    _ZdlPvSt11align_val_tRKSt9nothrow_t(aligned_nothrow_scalar, 256, &token);

    const aligned_nothrow_array = _ZnamSt11align_val_tRKSt9nothrow_t(81, 512, &token) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned_nothrow_array) % 512);
    try std.testing.expectEqual(@as(usize, 81), malloc_usable_size(aligned_nothrow_array));
    _ZdaPvSt11align_val_tRKSt9nothrow_t(aligned_nothrow_array, 512, &token);
}

test "preload allocator realloc reports non-live pointers" {
    const invalid_before = state.report().counters.invalid_free;
    const double_before = state.report().counters.double_free;

    const ptr = malloc(32) orelse return error.OutOfMemory;
    const bytes = state.asBytes(ptr, 32);
    try std.testing.expect(realloc(@ptrCast(bytes[1..].ptr), 64) == null);
    free(ptr);
    try std.testing.expect(realloc(ptr, 64) == null);

    const got = state.report();
    if (state.diagnosticsEnabled()) {
        try std.testing.expect(got.counters.invalid_free >= invalid_before + 1);
        try std.testing.expect(got.counters.double_free >= double_before + 1);
    } else {
        try std.testing.expectEqual(invalid_before, got.counters.invalid_free);
        try std.testing.expectEqual(double_before, got.counters.double_free);
    }
}

const RemoteFreeWork = struct {
    ptr: ?*anyopaque = null,
    ready: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

fn remoteFreeWorker(work: *RemoteFreeWork) void {
    while (!work.ready.load(.acquire)) std.atomic.spinLoopHint();
    free(work.ptr);
    work.done.store(true, .release);
}

test "dieharder preload allocator defers remote frees until owner allocation" {
    if (!state.dieharderPreload()) return;

    const ptr = malloc(64) orelse return error.OutOfMemory;
    const bytes = state.asBytes(ptr, 64);
    @memset(bytes, 0xab);

    var work = RemoteFreeWork{ .ptr = ptr };
    const thread = try sys.thread.spawn(remoteFreeWorker, .{&work});
    work.ready.store(true, .release);
    while (!work.done.load(.acquire)) std.atomic.spinLoopHint();
    thread.join();

    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);

    const scratch = malloc(16) orelse return error.OutOfMemory;
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    free(scratch);
}

test "dieharder preload allocator owner free consumes pending remote free" {
    if (!state.dieharderPreload()) return;

    const live_before = state.report().live_allocations;
    const pending_before = state.pendingRemoteFreeCount();
    const ptr = malloc(64) orelse return error.OutOfMemory;
    const bytes = state.asBytes(ptr, 64);
    @memset(bytes, 0xab);

    var work = RemoteFreeWork{ .ptr = ptr };
    const thread = try sys.thread.spawn(remoteFreeWorker, .{&work});
    work.ready.store(true, .release);
    while (!work.done.load(.acquire)) std.atomic.spinLoopHint();
    thread.join();

    try std.testing.expectEqual(live_before + 1, state.report().live_allocations);
    try std.testing.expectEqual(pending_before + 1, state.pendingRemoteFreeCount());

    free(ptr);

    try std.testing.expectEqual(live_before, state.report().live_allocations);
    try std.testing.expectEqual(pending_before, state.pendingRemoteFreeCount());

    const scratch = malloc(16) orelse return error.OutOfMemory;
    try std.testing.expectEqual(pending_before, state.pendingRemoteFreeCount());
    free(scratch);
}

test "dieharder preload allocator owner realloc consumes pending remote free" {
    if (!state.dieharderPreload()) return;

    const live_before = state.report().live_allocations;
    const pending_before = state.pendingRemoteFreeCount();
    const ptr = malloc(64) orelse return error.OutOfMemory;
    const bytes = state.asBytes(ptr, 64);
    @memset(bytes, 0xbc);

    var work = RemoteFreeWork{ .ptr = ptr };
    const thread = try sys.thread.spawn(remoteFreeWorker, .{&work});
    work.ready.store(true, .release);
    while (!work.done.load(.acquire)) std.atomic.spinLoopHint();
    thread.join();

    try std.testing.expectEqual(live_before + 1, state.report().live_allocations);
    try std.testing.expectEqual(pending_before + 1, state.pendingRemoteFreeCount());
    try std.testing.expect(realloc(ptr, 128) == null);
    try std.testing.expectEqual(live_before, state.report().live_allocations);
    try std.testing.expectEqual(pending_before, state.pendingRemoteFreeCount());

    const scratch = malloc(16) orelse return error.OutOfMemory;
    try std.testing.expectEqual(pending_before, state.pendingRemoteFreeCount());
    free(scratch);
}
