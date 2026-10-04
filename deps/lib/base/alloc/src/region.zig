//! Preparation-only allocator for a fixed-address, read-only process image.
//! Small objects reuse size-class blocks. Large retained objects occupy page
//! extents above the small zone. Temporary objects at least 8 MiB occupy the
//! top of the reservation, so their lifetimes do not widen the saved image.
const std = @import("std");
const sys = @import("sys");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const page_bytes = 4096;
const large_threshold = 1 << 20;
const temporary_threshold = 8 << 20;
const maximum_extents = 8192;

const class_sizes = blk: {
    @setEvalBranchQuota(10_000);
    var sizes: [128]usize = undefined;
    var count: usize = 0;
    var size: usize = 16;
    while (size <= 128) : (size += 16) {
        sizes[count] = size;
        count += 1;
    }
    var power: usize = 128;
    while (power < large_threshold) : (power *= 2) {
        for ([_]usize{ 5, 6, 7, 8 }) |numerator| {
            sizes[count] = power * numerator / 4;
            count += 1;
        }
    }
    break :blk sizes[0..count].*;
};

const Extent = struct { start: usize, len: usize };
const Live = struct {
    requested: usize,
    class: ?u8,
    id: u32 = 0,
    reserved: usize = 0,
};

/// The profile has about 25,200 allocations and fewer than 60,000 allocator
/// events. Both bounds leave more than twice that observed demand. The trace
/// is caller-owned metadata and never becomes part of the prepared image.
pub const Trace = struct {
    pub const maximum_events = 131_072;
    pub const maximum_allocations = 65_536;

    pub const Kind = enum(u8) { alloc, resize, remap, free };
    pub const Event = extern struct {
        id: u32 = 0,
        kind: Kind = .alloc,
        success: u8 = 0,
        padding: [2]u8 = .{ 0, 0 },
        before: u64 = 0,
        after: u64 = 0,
        alignment: u64 = 0,
    };
    pub const Allocation = extern struct {
        maximum: u64 = 0,
        alignment: u64 = 0,
        live: u8 = 0,
        extent: u8 = 0,
        padding: [6]u8 = @splat(0),
    };

    events: [maximum_events]Event = undefined,
    allocations: [maximum_allocations]Allocation = undefined,
    event_count: usize = 0,
    allocation_count: usize = 0,

    pub fn compactedBytes(self: *const Trace, initial_used: usize, limit: usize) error{RegionCapacity}!usize {
        var used = initial_used;
        for (self.allocations[0..self.allocation_count]) |entry| {
            if (entry.live == 0) continue;
            const alignment: usize = @intCast(entry.alignment);
            const maximum: usize = @intCast(entry.maximum);
            const span = if (entry.extent != 0)
                pageSpan(maximum, limit) orelse return error.RegionCapacity
            else
                class_sizes[classFor(maximum, alignment)];
            used = alignForward(used, if (entry.extent != 0) @max(alignment, page_bytes) else classAlignment(span)) orelse
                return error.RegionCapacity;
            if (used > limit or span > limit - used) return error.RegionCapacity;
            used += span;
        }
        return used;
    }
};

pub const RegionAllocator = struct {
    pub const ProfileTrace = Trace;
    /// The caller has already mapped the whole reservation read/write. Its
    /// first `section_bytes` become file-backed read-only storage after fill.
    base: usize,
    section_bytes: usize,
    reservation_bytes: usize,
    small_zone_bytes: usize,
    top: usize,
    temporary_top: usize = 0,
    extents: [maximum_extents]Extent = undefined,
    extent_count: usize = 1,
    free_heads: [class_sizes.len]usize = @splat(0),
    live: std.AutoHashMapUnmanaged(usize, Live) = .empty,
    metadata: Allocator,
    discard_pages: bool,
    failed: bool = false,
    sealed: bool = false,
    mode: enum { standard, profile, compact } = .standard,
    trace: ?*Trace = null,
    event_index: usize = 0,
    allocation_index: u32 = 0,
    trace_error: ?Error = null,

    pub const Error = error{ InvalidRegion, OutOfMemory, RegionCapacity, TraceCapacity, TraceDiverged };
    pub const maximum_live_allocations = 8192;
    pub const small_zone_default = 32 << 20;
    pub const reservation_default = 2 << 30;

    pub fn init(
        base: [*]u8,
        section_bytes: usize,
        reservation_bytes: usize,
        small_zone_bytes: usize,
        initial_used: usize,
        metadata: Allocator,
        discard_pages: bool,
    ) Error!RegionAllocator {
        var result: RegionAllocator = undefined;
        try result.initInPlace(base, section_bytes, reservation_bytes, small_zone_bytes, initial_used, metadata, discard_pages);
        return result;
    }

    pub fn initInPlace(
        self: *RegionAllocator,
        base: [*]u8,
        section_bytes: usize,
        reservation_bytes: usize,
        small_zone_bytes: usize,
        initial_used: usize,
        metadata: Allocator,
        discard_pages: bool,
    ) Error!void {
        const start = @intFromPtr(base);
        if (start % page_bytes != 0 or section_bytes % page_bytes != 0 or
            reservation_bytes % page_bytes != 0 or small_zone_bytes % page_bytes != 0 or
            initial_used > small_zone_bytes or small_zone_bytes > section_bytes or
            section_bytes > reservation_bytes or reservation_bytes > std.math.maxInt(usize) - start)
            return error.InvalidRegion;
        self.base = start;
        self.section_bytes = section_bytes;
        self.reservation_bytes = reservation_bytes;
        self.small_zone_bytes = small_zone_bytes;
        self.top = start + initial_used;
        self.temporary_top = 0;
        self.extent_count = 1;
        self.free_heads = @splat(0);
        self.live = .empty;
        self.metadata = metadata;
        self.discard_pages = discard_pages;
        self.failed = false;
        self.sealed = false;
        self.mode = .standard;
        self.trace = null;
        self.event_index = 0;
        self.allocation_index = 0;
        self.trace_error = null;
        self.extents[0] = .{
            .start = start + small_zone_bytes,
            .len = reservation_bytes - small_zone_bytes,
        };
        try self.live.ensureTotalCapacity(metadata, maximum_live_allocations);
    }

    pub fn initProfile(
        base: [*]u8,
        profile_section_bytes: usize,
        reservation_bytes: usize,
        initial_used: usize,
        metadata: Allocator,
        trace: *Trace,
    ) Error!RegionAllocator {
        var result: RegionAllocator = undefined;
        try result.initProfileInPlace(base, profile_section_bytes, reservation_bytes, initial_used, metadata, trace);
        return result;
    }

    pub fn initProfileInPlace(
        self: *RegionAllocator,
        base: [*]u8,
        profile_section_bytes: usize,
        reservation_bytes: usize,
        initial_used: usize,
        metadata: Allocator,
        trace: *Trace,
    ) Error!void {
        trace.event_count = 0;
        trace.allocation_count = 0;
        try self.initInPlace(base, profile_section_bytes, reservation_bytes, small_zone_default, initial_used, metadata, true);
        self.mode = .profile;
        self.trace = trace;
    }

    pub fn initCompact(
        base: [*]u8,
        section_bytes: usize,
        reservation_bytes: usize,
        initial_used: usize,
        metadata: Allocator,
        trace: *Trace,
    ) Error!RegionAllocator {
        var result: RegionAllocator = undefined;
        try result.initCompactInPlace(base, section_bytes, reservation_bytes, initial_used, metadata, trace);
        return result;
    }

    pub fn initCompactInPlace(
        self: *RegionAllocator,
        base: [*]u8,
        section_bytes: usize,
        reservation_bytes: usize,
        initial_used: usize,
        metadata: Allocator,
        trace: *Trace,
    ) Error!void {
        try self.initInPlace(base, section_bytes, reservation_bytes, section_bytes, initial_used, metadata, true);
        self.mode = .compact;
        self.trace = trace;
        self.temporary_top = self.base + reservation_bytes;
    }

    pub fn deinit(self: *RegionAllocator) void {
        self.live.deinit(self.metadata);
    }

    pub fn allocator(self: *RegionAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub const Census = struct {
        small_fill: usize,
        small_live: usize,
        large_live: usize,
        large_holes: usize,
        section_tail: usize,
        used: usize,
        compacted: usize,
        events: usize,
        allocations: usize,
    };

    pub fn census(self: *const RegionAllocator, initial_used: usize) Error!Census {
        if (self.mode != .profile) return error.InvalidRegion;
        const used = try self.usedBytes();
        var small_live: usize = 0;
        var large_live: usize = 0;
        var iterator = self.live.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.class) |class|
                small_live += class_sizes[class]
            else
                large_live += pageSpan(entry.value_ptr.requested, self.reservation_bytes) orelse
                    return error.RegionCapacity;
        }
        const trace = self.trace.?;
        const large_span = used - self.small_zone_bytes;
        if (large_live > large_span) return error.RegionCapacity;
        return .{
            .small_fill = self.top - self.base,
            .small_live = small_live,
            .large_live = large_live,
            .large_holes = large_span - large_live,
            .section_tail = self.section_bytes - used,
            .used = used,
            .compacted = try trace.compactedBytes(initial_used, self.reservation_bytes),
            .events = trace.event_count,
            .allocations = trace.allocation_count,
        };
    }

    fn append(self: *RegionAllocator, event: Trace.Event) void {
        const trace = self.trace.?;
        if (trace.event_count == Trace.maximum_events) {
            self.trace_error = error.TraceCapacity;
            return;
        }
        trace.events[trace.event_count] = event;
        trace.event_count += 1;
    }

    fn expect(self: *RegionAllocator, event: Trace.Event) bool {
        const trace = self.trace.?;
        if (self.event_index == trace.event_count) {
            self.trace_error = error.TraceDiverged;
            return false;
        }
        const recorded = trace.events[self.event_index];
        self.event_index += 1;
        if (recorded.id != event.id or recorded.kind != event.kind or
            recorded.before != event.before or recorded.after != event.after or
            recorded.alignment != event.alignment)
        {
            self.trace_error = error.TraceDiverged;
            return false;
        }
        return true;
    }

    /// Refuses a truncated image even when the reservation itself had room.
    pub fn usedBytes(self: *const RegionAllocator) Error!usize {
        if (self.trace_error) |err| return err;
        if (self.failed) return error.RegionCapacity;
        if (self.top < self.base or self.top - self.base > self.reservation_bytes)
            return error.RegionCapacity;
        var high = self.top - self.base;
        if (self.mode == .compact) {
            if (high > self.section_bytes) return error.RegionCapacity;
            return high;
        }
        var iterator = self.live.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.class == null) {
                const address = entry.key_ptr.*;
                if (address < self.base) return error.RegionCapacity;
                const offset = address - self.base;
                const span = pageSpan(entry.value_ptr.requested, self.reservation_bytes) orelse
                    return error.RegionCapacity;
                if (offset > self.reservation_bytes or span > self.reservation_bytes - offset)
                    return error.RegionCapacity;
                high = @max(high, offset + span);
            }
        }
        if (high > self.section_bytes) return error.RegionCapacity;
        return high;
    }

    /// Freed class blocks carry free-list links during preparation. Remove the
    /// links before the region becomes a deterministic image.
    pub fn seal(self: *RegionAllocator) Error!usize {
        if (self.trace_error) |err| return err;
        if (self.mode == .profile) {
            const trace = self.trace.?;
            var iterator = self.live.iterator();
            while (iterator.next()) |entry|
                trace.allocations[entry.value_ptr.id].live = 1;
        } else if (self.mode == .compact) {
            const trace = self.trace.?;
            if (self.event_index != trace.event_count) return error.TraceDiverged;
            var iterator = self.live.iterator();
            var live_count: usize = 0;
            while (iterator.next()) |entry| {
                if (trace.allocations[entry.value_ptr.id].live == 0)
                    return error.TraceDiverged;
                live_count += 1;
            }
            var expected_count: usize = 0;
            for (trace.allocations[0..trace.allocation_count]) |entry|
                expected_count += @intFromBool(entry.live != 0);
            if (live_count != expected_count) return error.TraceDiverged;
        }
        const used = try self.usedBytes();
        if (self.mode == .compact) {
            self.sealed = true;
            return used;
        }
        for (&self.free_heads, class_sizes) |*head, size| {
            var address = head.*;
            while (address != 0) {
                const next = @as(*const usize, @ptrFromInt(address)).*;
                @memset(@as([*]u8, @ptrFromInt(address))[0..size], 0);
                address = next;
            }
            head.* = 0;
        }
        self.sealed = true;
        return used;
    }

    const vtable: Allocator.VTable = .{
        .alloc = allocate,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocate(context: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const self: *RegionAllocator = @ptrCast(@alignCast(context));
        if (self.sealed or len > self.reservation_bytes or
            self.live.count() == maximum_live_allocations)
        {
            self.failed = true;
            return null;
        }
        const aligned = alignment.toByteUnits();
        const id = self.allocation_index;
        if (self.mode != .standard and id == Trace.maximum_allocations) {
            self.trace_error = error.TraceCapacity;
            return null;
        }
        const event = Trace.Event{
            .id = id,
            .kind = .alloc,
            .before = len,
            .alignment = aligned,
        };
        if (self.mode == .compact and !self.expect(event)) return null;
        const extent = len >= large_threshold or aligned > page_bytes;
        const address = if (self.mode == .compact)
            self.takeCompact(id)
        else if (extent)
            self.takeExtent(len, aligned, len >= temporary_threshold)
        else
            self.takeClass(len, aligned);
        const at = address orelse {
            self.failed = true;
            return null;
        };
        if (self.mode == .profile) {
            const trace = self.trace.?;
            trace.allocations[id] = .{
                .maximum = len,
                .alignment = aligned,
                .extent = @intFromBool(extent),
            };
            trace.allocation_count += 1;
            self.append(event);
        }
        self.allocation_index += 1;
        self.live.putAssumeCapacityNoClobber(at, .{
            .requested = len,
            .class = if (extent) null else classFor(len, aligned),
            .id = id,
            .reserved = if (self.mode == .compact) self.compactSpan(id) else 0,
        });
        return @ptrFromInt(at);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
        const self: *RegionAllocator = @ptrCast(@alignCast(context));
        return self.resizeTracked(memory, alignment, new_len, .resize);
    }

    fn resizeTracked(self: *RegionAllocator, memory: []u8, alignment: Alignment, new_len: usize, kind: Trace.Kind) bool {
        const record = self.live.getPtr(@intFromPtr(memory.ptr)) orelse return false;
        const id = record.id;
        const event = Trace.Event{
            .id = id,
            .kind = kind,
            .before = record.requested,
            .after = new_len,
            .alignment = alignment.toByteUnits(),
        };
        if (self.mode == .compact) {
            if (!self.expect(event)) return false;
            const expected = self.trace.?.events[self.event_index - 1].success != 0;
            if (!expected) return false;
            if (new_len > record.reserved) {
                self.trace_error = error.TraceDiverged;
                return false;
            }
            record.requested = new_len;
            return true;
        }
        const success = self.resizeOriginal(memory, new_len);
        if (self.mode == .profile) {
            var recorded = event;
            recorded.success = @intFromBool(success);
            self.append(recorded);
            if (success)
                self.trace.?.allocations[id].maximum = @max(self.trace.?.allocations[id].maximum, new_len);
        }
        return success;
    }

    fn resizeOriginal(self: *RegionAllocator, memory: []u8, new_len: usize) bool {
        if (self.sealed or new_len > self.reservation_bytes) return false;
        const at = @intFromPtr(memory.ptr);
        const record = self.live.getPtr(at) orelse return false;
        if (record.class) |class| {
            if (new_len > class_sizes[class]) return false;
            record.requested = new_len;
            return true;
        }
        const old_span = pageSpan(record.requested, self.reservation_bytes) orelse return false;
        const new_span = pageSpan(new_len, self.reservation_bytes) orelse return false;
        if (at < self.base) return false;
        const offset = at - self.base;
        if (offset > self.reservation_bytes or new_span > self.reservation_bytes - offset)
            return false;
        if (new_span > old_span) {
            const adjacent = std.math.add(usize, at, old_span) catch return false;
            for (self.extents[0..self.extent_count], 0..) |*extent, index| {
                if (extent.start != adjacent or extent.len < new_span - old_span) continue;
                extent.start = std.math.add(usize, extent.start, new_span - old_span) catch return false;
                extent.len -= new_span - old_span;
                if (extent.len == 0) self.removeExtent(index);
                record.requested = new_len;
                return true;
            }
            return false;
        }
        if (new_span < old_span)
            self.returnExtent(std.math.add(usize, at, new_span) catch return false, old_span - new_span);
        record.requested = new_len;
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        _ = ra;
        const self: *RegionAllocator = @ptrCast(@alignCast(context));
        return if (self.resizeTracked(memory, alignment, new_len, .remap)) memory.ptr else null;
    }

    fn free(context: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const self: *RegionAllocator = @ptrCast(@alignCast(context));
        if (self.sealed) return;
        const at = @intFromPtr(memory.ptr);
        const record = self.live.fetchRemove(at) orelse unreachable;
        const event = Trace.Event{ .id = record.value.id, .kind = .free, .before = record.value.requested };
        if (self.mode == .profile) self.append(event);
        if (self.mode == .compact) {
            _ = self.expect(event);
            return;
        }
        if (record.value.class) |class| {
            const size = class_sizes[class];
            @memset(@as([*]u8, @ptrFromInt(at))[0..size], 0);
            @as(*usize, @ptrFromInt(at)).* = self.free_heads[class];
            self.free_heads[class] = at;
        } else self.returnExtent(at, pageSpan(record.value.requested, self.reservation_bytes) orelse unreachable);
    }

    fn compactSpan(self: *const RegionAllocator, id: u32) usize {
        const entry = self.trace.?.allocations[id];
        const maximum: usize = @intCast(entry.maximum);
        const alignment: usize = @intCast(entry.alignment);
        return if (entry.extent != 0)
            pageSpan(maximum, self.reservation_bytes).?
        else
            class_sizes[classFor(maximum, alignment)];
    }

    /// The upper anonymous reservation begins zeroed and hands each temporary
    /// address out once, so freed temporary spans need no reset or reuse.
    fn takeCompact(self: *RegionAllocator, id: u32) ?usize {
        const entry = self.trace.?.allocations[id];
        const span = self.compactSpan(id);
        const alignment: usize = @intCast(entry.alignment);
        const required = if (entry.extent != 0) @max(alignment, page_bytes) else classAlignment(span);
        if (entry.live != 0) {
            const at = alignForward(self.top, required) orelse return null;
            const limit = self.base + self.section_bytes;
            if (at > limit or span > limit - at) return null;
            self.top = at + span;
            return at;
        }
        if (self.temporary_top < self.base + span) return null;
        const at = std.mem.alignBackward(usize, self.temporary_top - span, required);
        if (at < self.base + self.section_bytes) return null;
        self.temporary_top = at;
        return at;
    }

    fn takeClass(self: *RegionAllocator, len: usize, alignment: usize) ?usize {
        const class = classFor(len, alignment);
        const size = class_sizes[class];
        if (self.free_heads[class] != 0) {
            const at = self.free_heads[class];
            self.free_heads[class] = @as(*const usize, @ptrFromInt(at)).*;
            @as(*usize, @ptrFromInt(at)).* = 0;
            return at;
        }
        const at = alignForward(self.top, classAlignment(size)) orelse return null;
        const limit = self.base + self.small_zone_bytes;
        if (at > limit or size > limit - at) return null;
        self.top = at + size;
        return at;
    }

    fn takeExtent(self: *RegionAllocator, len: usize, alignment: usize, from_top: bool) ?usize {
        const span = pageSpan(len, self.reservation_bytes) orelse return null;
        const required_alignment = @max(alignment, page_bytes);
        var remaining = self.extent_count;
        while (remaining > 0) {
            remaining -= 1;
            const index = if (from_top) remaining else self.extent_count - remaining - 1;
            const extent = &self.extents[index];
            if (extent.len < span) continue;
            const end = std.math.add(usize, extent.start, extent.len) catch return null;
            const at = if (from_top)
                std.mem.alignBackward(usize, end - span, required_alignment)
            else
                alignForward(extent.start, required_alignment) orelse continue;
            if (at < extent.start) continue;
            const before = at - extent.start;
            if (before > extent.len or span > extent.len - before) continue;
            const after = extent.len - before - span;
            const right = std.math.add(usize, at, span) catch return null;
            if (before == 0 and after == 0) {
                self.removeExtent(index);
            } else if (before == 0) {
                extent.start = right;
                extent.len = after;
            } else {
                extent.len = before;
                if (after != 0) self.insertExtent(index + 1, .{ .start = right, .len = after });
            }
            return at;
        }
        return null;
    }

    fn returnExtent(self: *RegionAllocator, at: usize, span: usize) void {
        const bytes = @as([*]u8, @ptrFromInt(at))[0..span];
        if (self.discard_pages) {
            const pages: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(at);
            sys.memory.discardToZero(pages[0..span]) catch @memset(bytes, 0);
        } else @memset(bytes, 0);
        var index: usize = 0;
        while (index < self.extent_count and self.extents[index].start < at) : (index += 1) {}
        self.insertExtent(index, .{ .start = at, .len = span });
        if (self.failed) return;
        if (index + 1 < self.extent_count and
            self.extents[index].start + self.extents[index].len == self.extents[index + 1].start)
        {
            self.extents[index].len += self.extents[index + 1].len;
            self.removeExtent(index + 1);
        }
        if (index != 0 and self.extents[index - 1].start + self.extents[index - 1].len == self.extents[index].start) {
            self.extents[index - 1].len += self.extents[index].len;
            self.removeExtent(index);
        }
    }

    fn removeExtent(self: *RegionAllocator, index: usize) void {
        std.mem.copyForwards(Extent, self.extents[index .. self.extent_count - 1], self.extents[index + 1 .. self.extent_count]);
        self.extent_count -= 1;
    }

    fn insertExtent(self: *RegionAllocator, index: usize, extent: Extent) void {
        if (self.extent_count == maximum_extents) {
            self.failed = true;
            return;
        }
        std.mem.copyBackwards(Extent, self.extents[index + 1 .. self.extent_count + 1], self.extents[index..self.extent_count]);
        self.extents[index] = extent;
        self.extent_count += 1;
    }
};

fn pageSpan(len: usize, limit: usize) ?usize {
    if (len > limit) return null;
    const rounded = std.math.add(usize, len, page_bytes - 1) catch return null;
    const span = rounded & ~@as(usize, page_bytes - 1);
    return if (span <= limit) span else null;
}

fn alignForward(address: usize, alignment: usize) ?usize {
    const rounded = std.math.add(usize, address, alignment - 1) catch return null;
    return rounded & ~(alignment - 1);
}

fn classAlignment(size: usize) usize {
    return @min(page_bytes, size & (~size +% 1));
}

fn classFor(len: usize, alignment: usize) u8 {
    const needed = @max(len, alignment);
    for (class_sizes, 0..) |size, index|
        if (size >= needed and classAlignment(size) >= alignment) return @intCast(index);
    unreachable;
}
