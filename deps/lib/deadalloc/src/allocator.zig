const std = @import("std");
const sys_thread = @import("sys").thread;
const size_class = @import("class.zig");
const report_mod = @import("report.zig");
const exterminator = @import("exterminator.zig");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Mode = enum {
    diehard,
    dieharder,
    exterminator,
};

pub const DiagnosticConfig = struct {
    enabled: bool = false,
    red_zone_bytes: usize = 16,
    quarantine_epochs: u64 = 16,
};

pub const Config = struct {
    mode: Mode = .diehard,
    numerator: usize = 8,
    denominator: usize = 7,
    seed: u64 = 0xd1e4_a110_cafe_f00d,
    thread_safe: bool = true,
    min_chunk_blocks: usize = 64,
    diagnostics: DiagnosticConfig = .{},
    repairs: exterminator.RepairTable = .{},

    pub fn diagnostic(mode: Mode) Config {
        return .{
            .mode = mode,
            .diagnostics = .{ .enabled = true },
        };
    }

    pub fn repaired(current: Config, report: report_mod.Report) Config {
        var next = current;
        const policy = exterminator.RepairPolicy.fromReport(report, .{
            .red_zone_bytes = current.diagnosticRedZoneBytes(),
            .quarantine_epochs = current.quarantineEpochs(),
            .repairs = current.repairs,
        });
        next.mode = .exterminator;
        next.diagnostics.enabled = true;
        next.diagnostics.red_zone_bytes = policy.red_zone_bytes;
        next.diagnostics.quarantine_epochs = policy.quarantine_epochs;
        next.repairs = policy.repairs;
        return next;
    }

    fn diagnosticRedZoneBytes(self: Config) usize {
        if (self.diagnostics.enabled or self.mode == .exterminator) return self.diagnostics.red_zone_bytes;
        return 0;
    }

    fn quarantineEpochs(self: Config) u64 {
        return switch (self.mode) {
            .diehard => 0,
            .dieharder => @max(self.diagnostics.quarantine_epochs, 8),
            .exterminator => @max(self.diagnostics.quarantine_epochs, 1),
        };
    }

    fn repairPadding(self: Config, allocation_return_address: usize) usize {
        if (self.mode != .exterminator) return 0;
        return self.repairs.overflowPadding(allocation_return_address);
    }

    fn repairQuarantineEpochs(self: Config, allocation_return_address: usize, free_return_address: usize) u64 {
        const base = self.quarantineEpochs();
        if (self.mode != .exterminator) return base;
        return @max(base, self.repairs.lifeExtension(allocation_return_address, free_return_address));
    }
};

pub const Report = report_mod.Report;
pub const Issue = report_mod.Issue;
pub const IssueKind = report_mod.IssueKind;
pub const RepairTable = exterminator.RepairTable;

pub const min_alignment = size_class.min_alignment;
pub const page_size = size_class.page_size;
pub const max_small_size = size_class.max_small_size;
pub const class_sizes = size_class.sizes;

const canary_byte: u8 = 0xa9;
const freed_byte: u8 = 0xdf;
const allocated_byte: u8 = 0xcd;

const BlockState = enum(u8) {
    fresh,
    live,
    free,
};

const BlockRef = struct {
    chunk: *Chunk,
    index: usize,
};

const AllocationKind = enum {
    small,
    large,
};

const AllocationRecord = struct {
    kind: AllocationKind,
    address: usize,
    requested_len: usize,
    repair_padding: usize = 0,
    block_size: usize,
    backing_len: usize,
    alignment: Alignment,
    allocation_id: u64,
    allocation_return_address: usize,
    free_return_address: usize = 0,
    small_block: ?BlockRef = null,
    free_epoch: u64 = 0,
    free_quarantine_epochs: u64 = 0,
    free_pattern: u64 = 0,
    free_issue_reported: bool = false,
    canary_issue_reported: bool = false,
};

const Chunk = struct {
    class_index: usize,
    block_size: usize,
    block_stride: usize,
    capacity: usize,
    live_count: usize,
    base: [*]u8,
    area_len: usize,
    states: []BlockState,
    requested_lens: []usize,
    repair_paddings: []usize,
    allocation_ids: []u64,
    allocation_return_addresses: []usize,
    free_return_addresses: []usize,
    free_epochs: []u64,
    free_quarantine_epochs: []u64,
    free_patterns: []u64,
    free_issue_reported: []bool,

    fn blockPtr(chunk: *Chunk, index: usize) [*]u8 {
        return chunk.base + index * chunk.block_stride;
    }

    fn isAvailable(chunk: *Chunk, index: usize, epoch: u64) bool {
        return switch (chunk.states[index]) {
            .fresh => true,
            .live => false,
            .free => epoch -% chunk.free_epochs[index] >= chunk.free_quarantine_epochs[index],
        };
    }
};

const ClassState = struct {
    chunks: std.ArrayList(*Chunk) = .empty,
    capacity: usize = 0,
    live_count: usize = 0,
    next_chunk_blocks: usize = 0,

    fn deinit(class_state: *ClassState, allocator: Allocator, owner: *DeadAllocator) void {
        for (class_state.chunks.items) |chunk| owner.destroyChunk(chunk);
        class_state.chunks.deinit(allocator);
        class_state.* = .{};
    }
};

pub const DeadAllocator = struct {
    backing_allocator: Allocator,
    config: Config,
    classes: [size_class.count]ClassState = @as([size_class.count]ClassState, @splat(.{})),
    live: std.AutoHashMap(usize, AllocationRecord),
    known: std.AutoHashMap(usize, AllocationRecord),
    page_owners: std.AutoHashMap(usize, usize),
    large_quarantine: std.ArrayList(AllocationRecord) = .empty,
    prng: std.Random.DefaultPrng,
    mutex: std.atomic.Mutex = .unlocked,
    epoch: u64 = 1,
    next_allocation_id: u64 = 1,
    counters: report_mod.Counters = .{},
    last_issue: ?Issue = null,
    issues: report_mod.IssueLog = .{},

    const Self = @This();

    pub fn init(backing_allocator: Allocator, config: Config) Self {
        std.debug.assert(config.numerator >= config.denominator);
        std.debug.assert(config.denominator > 0);
        return .{
            .backing_allocator = backing_allocator,
            .config = config,
            .live = std.AutoHashMap(usize, AllocationRecord).init(backing_allocator),
            .known = std.AutoHashMap(usize, AllocationRecord).init(backing_allocator),
            .page_owners = std.AutoHashMap(usize, usize).init(backing_allocator),
            .prng = std.Random.DefaultPrng.init(config.seed),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.diagnosticsActive()) {
            self.counters.invalid_free += 0;
        }
        self.releaseLiveLargeAllocations(@returnAddress());
        for (self.large_quarantine.items) |record| self.releaseLarge(record, @returnAddress());
        self.large_quarantine.deinit(self.backing_allocator);
        for (&self.classes) |*class_state| class_state.deinit(self.backing_allocator, self);
        self.live.deinit();
        self.known.deinit();
        self.page_owners.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn report(self: *Self) Report {
        self.lock();
        defer self.unlock();
        const ret_addr = @returnAddress();
        self.scanLiveCanaries(ret_addr);
        self.scanFreedMemory(ret_addr);
        self.drainLargeQuarantine(ret_addr);
        return self.reportUnlocked(ret_addr);
    }

    fn reportUnlocked(self: *Self, ret_addr: usize) Report {
        var live_bytes: usize = 0;
        var leak_issue: ?Issue = null;
        var issues = self.issues;
        var iterator = self.live.valueIterator();
        while (iterator.next()) |record| {
            live_bytes += record.requested_len;
            const issue: Issue = .{
                .kind = .leak,
                .address = record.address,
                .requested_len = record.requested_len,
                .block_size = record.block_size,
                .allocation_id = record.allocation_id,
                .allocation_return_address = record.allocation_return_address,
                .return_address = ret_addr,
            };
            if (leak_issue == null) leak_issue = issue;
            issues.append(issue);
        }
        return .{
            .counters = self.counters,
            .live_allocations = self.live.count(),
            .live_bytes = live_bytes,
            .leak_count = self.live.count(),
            .leak_issue = leak_issue,
            .last_issue = self.last_issue,
            .issues = issues,
        };
    }

    pub fn rawAlloc(self: *Self, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        self.lock();
        defer self.unlock();
        self.drainLargeQuarantine(ret_addr);

        const repair_padding = self.config.repairPadding(ret_addr);
        const total_len = self.totalAllocationLen(len, repair_padding) orelse return null;
        const class_index = size_class.indexFor(total_len, alignment) orelse return self.allocateLarge(len, repair_padding, total_len, alignment, ret_addr);
        return self.allocateSmall(class_index, len, repair_padding, total_len, alignment, ret_addr) catch null;
    }

    pub fn rawResize(self: *Self, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        self.lock();
        defer self.unlock();
        self.drainLargeQuarantine(ret_addr);

        const address = @intFromPtr(memory.ptr);
        const record_ptr = self.live.getPtr(address) orelse {
            self.recordUnknownFree(address, memory.len, alignment, ret_addr);
            return false;
        };
        if (memory.len != record_ptr.requested_len) {
            self.recordIssue(.{
                .kind = .size_mismatch,
                .address = address,
                .requested_len = memory.len,
                .block_size = record_ptr.block_size,
                .allocation_id = record_ptr.allocation_id,
                .allocation_return_address = record_ptr.allocation_return_address,
                .free_return_address = record_ptr.free_return_address,
                .free_epoch = record_ptr.free_epoch,
                .return_address = ret_addr,
            });
        }

        _ = self.checkCanary(record_ptr, ret_addr);

        const total_len = self.totalAllocationLen(new_len, record_ptr.repair_padding) orelse return false;
        if (total_len > record_ptr.block_size) return false;

        if (record_ptr.kind == .small) {
            const block = record_ptr.small_block.?;
            block.chunk.requested_lens[block.index] = new_len;
        }
        record_ptr.requested_len = new_len;
        record_ptr.canary_issue_reported = false;
        if (self.known.getPtr(address)) |known| known.requested_len = new_len;
        self.installCanary(@ptrFromInt(address), new_len, record_ptr.repair_padding, record_ptr.block_size);
        return true;
    }

    pub fn rawRemap(self: *Self, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        if (self.rawResize(memory, alignment, new_len, ret_addr)) return memory.ptr;

        const address = @intFromPtr(memory.ptr);
        const old_len = old_len: {
            self.lock();
            defer self.unlock();
            const record = self.live.get(address) orelse return null;
            break :old_len record.requested_len;
        };

        const new_ptr = self.rawAlloc(new_len, alignment, ret_addr) orelse return null;
        const copy_len = @min(old_len, new_len);
        const old_ptr: [*]u8 = @ptrFromInt(address);
        @memcpy(new_ptr[0..copy_len], old_ptr[0..copy_len]);
        self.rawFree(old_ptr[0..old_len], alignment, ret_addr);
        return new_ptr;
    }

    pub fn rawFree(self: *Self, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        self.lock();
        defer self.unlock();

        const address = @intFromPtr(memory.ptr);
        var record = self.live.fetchRemove(address) orelse {
            self.recordUnknownFree(address, memory.len, alignment, ret_addr);
            return;
        };

        if (memory.len != record.value.requested_len) {
            self.recordIssue(.{
                .kind = .size_mismatch,
                .address = address,
                .requested_len = memory.len,
                .block_size = record.value.block_size,
                .allocation_id = record.value.allocation_id,
                .allocation_return_address = record.value.allocation_return_address,
                .free_return_address = record.value.free_return_address,
                .free_epoch = record.value.free_epoch,
                .return_address = ret_addr,
            });
        }

        _ = self.checkCanary(&record.value, ret_addr);

        switch (record.value.kind) {
            .small => self.freeSmall(&record.value, ret_addr),
            .large => self.freeLarge(&record.value, ret_addr),
        }

        if (self.known.getPtr(address)) |known| known.* = record.value;
    }

    fn allocateSmall(
        self: *Self,
        class_index: usize,
        requested_len: usize,
        repair_padding: usize,
        total_len: usize,
        alignment: Alignment,
        ret_addr: usize,
    ) ![*]u8 {
        const class_state = &self.classes[class_index];
        if (self.shouldGrow(class_state)) try self.addChunk(class_index, ret_addr);

        const total_capacity = class_state.capacity;
        if (total_capacity == 0) return error.OutOfMemory;

        var attempts: usize = 0;
        while (attempts < total_capacity) : (attempts += 1) {
            const ordinal = self.prng.random().int(usize) % total_capacity;
            if (try self.tryAllocateSmallBlock(
                class_state,
                ordinal,
                requested_len,
                repair_padding,
                total_len,
                alignment,
                ret_addr,
            )) |ptr| return ptr;
        }

        var ordinal = self.prng.random().int(usize) % total_capacity;
        var probes: usize = 0;
        while (probes < total_capacity) : (probes += 1) {
            if (try self.tryAllocateSmallBlock(
                class_state,
                ordinal,
                requested_len,
                repair_padding,
                total_len,
                alignment,
                ret_addr,
            )) |ptr| return ptr;
            ordinal = (ordinal + 1) % total_capacity;
        }

        try self.addChunk(class_index, ret_addr);
        return self.allocateSmall(class_index, requested_len, repair_padding, total_len, alignment, ret_addr);
    }

    fn tryAllocateSmallBlock(
        self: *Self,
        class_state: *ClassState,
        ordinal: usize,
        requested_len: usize,
        repair_padding: usize,
        total_len: usize,
        alignment: Alignment,
        ret_addr: usize,
    ) !?[*]u8 {
        const selected = self.blockByOrdinal(class_state, ordinal);
        const chunk = selected.chunk;
        const index = selected.index;
        if (!chunk.isAvailable(index, self.epoch)) return null;

        const ptr = chunk.blockPtr(index);
        if (!std.mem.isAligned(@intFromPtr(ptr), alignment.toByteUnits())) return null;

        if (self.diagnosticsActive() and chunk.states[index] == .free and !chunk.free_issue_reported[index]) {
            chunk.free_issue_reported[index] = self.checkFreedPattern(
                ptr,
                chunk.block_size,
                chunk.requested_lens[index],
                chunk.allocation_ids[index],
                chunk.allocation_return_addresses[index],
                chunk.free_return_addresses[index],
                chunk.free_epochs[index],
                chunk.free_patterns[index],
                ret_addr,
            );
        }

        try self.ensurePageOwnerCapacityFor(@intFromPtr(ptr), chunk.block_size);

        const allocation_id = self.nextAllocationId();
        chunk.states[index] = .live;
        chunk.free_issue_reported[index] = false;
        chunk.requested_lens[index] = requested_len;
        chunk.repair_paddings[index] = repair_padding;
        chunk.allocation_ids[index] = allocation_id;
        chunk.allocation_return_addresses[index] = ret_addr;
        chunk.free_return_addresses[index] = 0;
        chunk.live_count += 1;
        class_state.live_count += 1;
        self.epoch +%= 1;

        @memset(ptr[0..@min(requested_len, chunk.block_size)], allocated_byte);
        self.installCanary(ptr, requested_len, repair_padding, chunk.block_size);

        const record: AllocationRecord = .{
            .kind = .small,
            .address = @intFromPtr(ptr),
            .requested_len = requested_len,
            .repair_padding = repair_padding,
            .block_size = chunk.block_size,
            .backing_len = total_len,
            .alignment = alignment,
            .allocation_id = allocation_id,
            .allocation_return_address = ret_addr,
            .small_block = .{ .chunk = chunk, .index = index },
        };
        self.live.put(record.address, record) catch {
            var cleanup = record;
            self.freeSmall(&cleanup, ret_addr);
            return error.OutOfMemory;
        };
        self.known.put(record.address, record) catch {
            _ = self.live.remove(record.address);
            var cleanup = record;
            self.freeSmall(&cleanup, ret_addr);
            return error.OutOfMemory;
        };
        self.putPageOwnerAssumeCapacity(record);
        return ptr;
    }

    fn allocateLarge(self: *Self, requested_len: usize, repair_padding: usize, backing_len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const effective_backing_len = self.largeBackingLen(backing_len) orelse return null;
        const effective_alignment = self.largeAlignment(alignment);
        const ptr = self.backing_allocator.rawAlloc(effective_backing_len, effective_alignment, ret_addr) orelse return null;
        @memset(ptr[0..@min(requested_len, effective_backing_len)], allocated_byte);
        self.installCanary(ptr, requested_len, repair_padding, effective_backing_len);

        const allocation_id = self.nextAllocationId();
        const record: AllocationRecord = .{
            .kind = .large,
            .address = @intFromPtr(ptr),
            .requested_len = requested_len,
            .repair_padding = repair_padding,
            .block_size = effective_backing_len,
            .backing_len = effective_backing_len,
            .alignment = effective_alignment,
            .allocation_id = allocation_id,
            .allocation_return_address = ret_addr,
        };
        self.ensurePageOwnerCapacity(record) catch {
            self.backing_allocator.rawFree(ptr[0..effective_backing_len], effective_alignment, ret_addr);
            return null;
        };
        self.live.put(record.address, record) catch {
            self.backing_allocator.rawFree(ptr[0..effective_backing_len], effective_alignment, ret_addr);
            return null;
        };
        self.known.put(record.address, record) catch {
            _ = self.live.remove(record.address);
            self.backing_allocator.rawFree(ptr[0..effective_backing_len], effective_alignment, ret_addr);
            return null;
        };
        self.putPageOwnerAssumeCapacity(record);
        return ptr;
    }

    fn largeBackingLen(self: *const Self, backing_len: usize) ?usize {
        return switch (self.config.mode) {
            .dieharder => alignForwardChecked(backing_len, page_size),
            .diehard, .exterminator => backing_len,
        };
    }

    fn largeAlignment(self: *const Self, alignment: Alignment) Alignment {
        return switch (self.config.mode) {
            .dieharder => .fromByteUnits(@max(alignment.toByteUnits(), page_size)),
            .diehard, .exterminator => alignment,
        };
    }

    fn freeSmall(self: *Self, record: *AllocationRecord, ret_addr: usize) void {
        const block = record.small_block.?;
        const chunk = block.chunk;
        const ptr = chunk.blockPtr(block.index);
        record.free_pattern = self.nextFreedPattern();
        if (self.writeFreedPattern()) self.fillFreedPattern(ptr, chunk.block_size, record.free_pattern);
        record.free_return_address = ret_addr;
        record.free_epoch = self.epoch;
        record.free_quarantine_epochs = self.config.repairQuarantineEpochs(record.allocation_return_address, ret_addr);
        chunk.states[block.index] = .free;
        chunk.free_return_addresses[block.index] = ret_addr;
        chunk.free_epochs[block.index] = self.epoch;
        chunk.free_quarantine_epochs[block.index] = record.free_quarantine_epochs;
        chunk.free_patterns[block.index] = record.free_pattern;
        chunk.free_issue_reported[block.index] = false;
        chunk.live_count -= 1;
        self.classes[chunk.class_index].live_count -= 1;
        self.epoch +%= 1;
    }

    fn freeLarge(self: *Self, record: *AllocationRecord, ret_addr: usize) void {
        const ptr: [*]u8 = @ptrFromInt(record.address);
        record.free_pattern = self.nextFreedPattern();
        if (self.writeFreedPattern()) self.fillFreedPattern(ptr, record.backing_len, record.free_pattern);
        record.free_return_address = ret_addr;
        record.free_epoch = self.epoch;
        record.free_quarantine_epochs = self.config.repairQuarantineEpochs(record.allocation_return_address, ret_addr);
        if (record.free_quarantine_epochs > 0) {
            var quarantined = record.*;
            quarantined.free_issue_reported = false;
            self.large_quarantine.append(self.backing_allocator, quarantined) catch {
                self.releaseLarge(record.*, ret_addr);
                return;
            };
            self.epoch +%= 1;
            return;
        }
        self.releaseLarge(record.*, ret_addr);
    }

    fn releaseLarge(self: *Self, record: AllocationRecord, ret_addr: usize) void {
        const ptr: [*]u8 = @ptrFromInt(record.address);
        self.removePageOwner(record);
        self.backing_allocator.rawFree(ptr[0..record.backing_len], record.alignment, ret_addr);
    }

    fn releaseLiveLargeAllocations(self: *Self, ret_addr: usize) void {
        var iterator = self.live.valueIterator();
        while (iterator.next()) |record| {
            if (record.kind == .large) self.releaseLarge(record.*, ret_addr);
        }
    }

    fn addChunk(self: *Self, class_index: usize, ret_addr: usize) !void {
        const class_state = &self.classes[class_index];
        const block_size = size_class.size(class_index);
        const block_stride = self.blockStride(block_size);
        if (class_state.next_chunk_blocks == 0) {
            class_state.next_chunk_blocks = self.initialChunkBlocks(block_stride);
        }
        const capacity = class_state.next_chunk_blocks;
        const area_len = std.math.mul(usize, capacity, block_stride) catch return error.OutOfMemory;
        const alignment = Alignment.fromByteUnits(@max(block_stride, min_alignment));
        const base = self.backing_allocator.rawAlloc(area_len, alignment, ret_addr) orelse return error.OutOfMemory;
        errdefer self.backing_allocator.rawFree(base[0..area_len], alignment, ret_addr);

        const chunk = try self.backing_allocator.create(Chunk);
        errdefer self.backing_allocator.destroy(chunk);

        const states = try self.backing_allocator.alloc(BlockState, capacity);
        errdefer self.backing_allocator.free(states);
        const requested_lens = try self.backing_allocator.alloc(usize, capacity);
        errdefer self.backing_allocator.free(requested_lens);
        const allocation_ids = try self.backing_allocator.alloc(u64, capacity);
        errdefer self.backing_allocator.free(allocation_ids);
        const allocation_return_addresses = try self.backing_allocator.alloc(usize, capacity);
        errdefer self.backing_allocator.free(allocation_return_addresses);
        const free_return_addresses = try self.backing_allocator.alloc(usize, capacity);
        errdefer self.backing_allocator.free(free_return_addresses);
        const repair_paddings = try self.backing_allocator.alloc(usize, capacity);
        errdefer self.backing_allocator.free(repair_paddings);
        const free_epochs = try self.backing_allocator.alloc(u64, capacity);
        errdefer self.backing_allocator.free(free_epochs);
        const free_quarantine_epochs = try self.backing_allocator.alloc(u64, capacity);
        errdefer self.backing_allocator.free(free_quarantine_epochs);
        const free_patterns = try self.backing_allocator.alloc(u64, capacity);
        errdefer self.backing_allocator.free(free_patterns);
        const free_issue_reported = try self.backing_allocator.alloc(bool, capacity);
        errdefer self.backing_allocator.free(free_issue_reported);

        @memset(states, .fresh);
        @memset(requested_lens, 0);
        @memset(repair_paddings, 0);
        @memset(allocation_ids, 0);
        @memset(allocation_return_addresses, 0);
        @memset(free_return_addresses, 0);
        @memset(free_epochs, 0);
        @memset(free_quarantine_epochs, 0);
        @memset(free_patterns, 0);
        @memset(free_issue_reported, false);
        self.fillFreedPattern(base, area_len, self.freshFreedPattern());

        chunk.* = .{
            .class_index = class_index,
            .block_size = block_size,
            .block_stride = block_stride,
            .capacity = capacity,
            .live_count = 0,
            .base = base,
            .area_len = area_len,
            .states = states,
            .requested_lens = requested_lens,
            .repair_paddings = repair_paddings,
            .allocation_ids = allocation_ids,
            .allocation_return_addresses = allocation_return_addresses,
            .free_return_addresses = free_return_addresses,
            .free_epochs = free_epochs,
            .free_quarantine_epochs = free_quarantine_epochs,
            .free_patterns = free_patterns,
            .free_issue_reported = free_issue_reported,
        };

        try class_state.chunks.append(self.backing_allocator, chunk);
        class_state.capacity += capacity;
        class_state.next_chunk_blocks = std.math.mul(usize, capacity, 2) catch capacity;
    }

    fn destroyChunk(self: *Self, chunk: *Chunk) void {
        self.backing_allocator.rawFree(
            chunk.base[0..chunk.area_len],
            .fromByteUnits(@max(chunk.block_stride, min_alignment)),
            @returnAddress(),
        );
        self.backing_allocator.free(chunk.states);
        self.backing_allocator.free(chunk.requested_lens);
        self.backing_allocator.free(chunk.repair_paddings);
        self.backing_allocator.free(chunk.allocation_ids);
        self.backing_allocator.free(chunk.allocation_return_addresses);
        self.backing_allocator.free(chunk.free_return_addresses);
        self.backing_allocator.free(chunk.free_epochs);
        self.backing_allocator.free(chunk.free_quarantine_epochs);
        self.backing_allocator.free(chunk.free_patterns);
        self.backing_allocator.free(chunk.free_issue_reported);
        self.backing_allocator.destroy(chunk);
    }

    fn blockStride(self: *Self, block_size: usize) usize {
        return switch (self.config.mode) {
            .diehard, .exterminator => block_size,
            .dieharder => if (block_size < page_size) page_size else block_size,
        };
    }

    fn initialChunkBlocks(self: *Self, block_stride: usize) usize {
        const base = @max(self.config.min_chunk_blocks, 1);
        if (self.config.mode == .dieharder and block_stride >= page_size) return @max(@min(base, 16), 2);
        return base;
    }

    fn shouldGrow(self: *Self, class_state: *const ClassState) bool {
        if (class_state.capacity == 0) return true;
        return self.config.numerator * (class_state.live_count + 1) >= class_state.capacity * self.config.denominator;
    }

    fn blockByOrdinal(self: *Self, class_state: *ClassState, ordinal: usize) BlockRef {
        _ = self;
        var remaining = ordinal;
        for (class_state.chunks.items) |chunk| {
            if (remaining < chunk.capacity) return .{ .chunk = chunk, .index = remaining };
            remaining -= chunk.capacity;
        }
        unreachable;
    }

    fn totalAllocationLen(self: *Self, requested_len: usize, repair_padding: usize) ?usize {
        const occupied_len = std.math.add(usize, @max(requested_len, 1), repair_padding) catch return null;
        return std.math.add(usize, occupied_len, self.config.diagnosticRedZoneBytes()) catch null;
    }

    fn installCanary(self: *Self, ptr: [*]u8, requested_len: usize, repair_padding: usize, block_size: usize) void {
        const red_zone = self.config.diagnosticRedZoneBytes();
        const start = std.math.add(usize, @max(requested_len, 1), repair_padding) catch return;
        if (red_zone == 0 or start >= block_size) return;
        const canary_len = @min(red_zone, block_size - start);
        @memset(ptr[start .. start + canary_len], canary_byte);
    }

    fn checkCanary(self: *Self, record: *AllocationRecord, ret_addr: usize) bool {
        const red_zone = self.config.diagnosticRedZoneBytes();
        const start = std.math.add(usize, @max(record.requested_len, 1), record.repair_padding) catch return false;
        if (red_zone == 0 or start >= record.block_size) return false;
        const canary_len = @min(red_zone, record.block_size - start);
        const ptr: [*]u8 = @ptrFromInt(record.address);
        var offset = start;
        while (offset < start + canary_len) : (offset += 1) {
            if (ptr[offset] != canary_byte) {
                if (!record.canary_issue_reported) {
                    self.recordIssue(.{
                        .kind = .buffer_overflow,
                        .address = record.address,
                        .offset = offset,
                        .requested_len = record.requested_len,
                        .block_size = record.block_size,
                        .allocation_id = record.allocation_id,
                        .allocation_return_address = record.allocation_return_address,
                        .free_return_address = record.free_return_address,
                        .free_epoch = record.free_epoch,
                        .return_address = ret_addr,
                    });
                    record.canary_issue_reported = true;
                }
                return true;
            }
        }
        record.canary_issue_reported = false;
        return false;
    }

    fn scanLiveCanaries(self: *Self, ret_addr: usize) void {
        if (!self.diagnosticsActive()) return;
        var iterator = self.live.valueIterator();
        while (iterator.next()) |record| _ = self.checkCanary(record, ret_addr);
    }

    fn scanFreedMemory(self: *Self, ret_addr: usize) void {
        if (!self.diagnosticsActive()) return;
        for (&self.classes) |*class_state| {
            for (class_state.chunks.items) |chunk| {
                for (chunk.states, 0..) |state, index| {
                    if (state != .free or chunk.free_issue_reported[index]) continue;
                    chunk.free_issue_reported[index] = self.checkFreedPattern(
                        chunk.blockPtr(index),
                        chunk.block_size,
                        chunk.requested_lens[index],
                        chunk.allocation_ids[index],
                        chunk.allocation_return_addresses[index],
                        chunk.free_return_addresses[index],
                        chunk.free_epochs[index],
                        chunk.free_patterns[index],
                        ret_addr,
                    );
                }
            }
        }
        for (self.large_quarantine.items) |*record| {
            if (record.free_issue_reported) continue;
            const ptr: [*]u8 = @ptrFromInt(record.address);
            record.free_issue_reported = self.checkFreedPattern(
                ptr,
                record.block_size,
                record.requested_len,
                record.allocation_id,
                record.allocation_return_address,
                record.free_return_address,
                record.free_epoch,
                record.free_pattern,
                ret_addr,
            );
        }
    }

    fn drainLargeQuarantine(self: *Self, ret_addr: usize) void {
        var index: usize = 0;
        while (index < self.large_quarantine.items.len) {
            var record = &self.large_quarantine.items[index];
            if (!record.free_issue_reported) {
                const ptr: [*]u8 = @ptrFromInt(record.address);
                record.free_issue_reported = self.checkFreedPattern(
                    ptr,
                    record.block_size,
                    record.requested_len,
                    record.allocation_id,
                    record.allocation_return_address,
                    record.free_return_address,
                    record.free_epoch,
                    record.free_pattern,
                    ret_addr,
                );
            }
            if (self.epoch -% record.free_epoch < record.free_quarantine_epochs) {
                index += 1;
                continue;
            }
            const removed = self.large_quarantine.swapRemove(index);
            self.releaseLarge(removed, ret_addr);
        }
    }

    fn checkFreedPattern(
        self: *Self,
        ptr: [*]u8,
        block_size: usize,
        requested_len: usize,
        allocation_id: u64,
        allocation_return_address: usize,
        free_return_address: usize,
        free_epoch: u64,
        pattern: u64,
        ret_addr: usize,
    ) bool {
        var index: usize = 0;
        while (index < block_size) : (index += 1) {
            if (ptr[index] != patternByte(pattern, index)) {
                self.recordIssue(.{
                    .kind = .use_after_free,
                    .address = @intFromPtr(ptr),
                    .offset = index,
                    .requested_len = requested_len,
                    .block_size = block_size,
                    .allocation_id = allocation_id,
                    .allocation_return_address = allocation_return_address,
                    .free_return_address = free_return_address,
                    .free_epoch = free_epoch,
                    .return_address = ret_addr,
                });
                return true;
            }
        }
        return false;
    }

    fn freshFreedPattern(self: *Self) u64 {
        return switch (self.config.mode) {
            .dieharder => 0,
            .diehard, .exterminator => repeatedPattern(freed_byte),
        };
    }

    fn nextFreedPattern(self: *Self) u64 {
        return switch (self.config.mode) {
            .dieharder => 0,
            .diehard, .exterminator => sanitizedFreedPattern(self.prng.random().int(u64)),
        };
    }

    fn nextAllocationId(self: *Self) u64 {
        const id = self.next_allocation_id;
        self.next_allocation_id +%= 1;
        if (self.next_allocation_id == 0) self.next_allocation_id = 1;
        return id;
    }

    fn writeFreedPattern(self: *Self) bool {
        return switch (self.config.mode) {
            .diehard => self.diagnosticsActive(),
            .dieharder, .exterminator => true,
        };
    }

    fn fillFreedPattern(self: *Self, ptr: [*]u8, len: usize, pattern: u64) void {
        _ = self;
        var index: usize = 0;
        while (index < len) : (index += 1) ptr[index] = patternByte(pattern, index);
    }

    fn recordUnknownFree(self: *Self, address: usize, len: usize, alignment: Alignment, ret_addr: usize) void {
        _ = alignment;
        if (self.known.get(address)) |record| {
            self.recordIssue(.{
                .kind = .double_free,
                .address = address,
                .requested_len = len,
                .block_size = record.block_size,
                .allocation_id = record.allocation_id,
                .allocation_return_address = record.allocation_return_address,
                .free_return_address = record.free_return_address,
                .free_epoch = record.free_epoch,
                .return_address = ret_addr,
            });
            return;
        }
        if (self.pageOwnedRecord(address)) |record| {
            self.recordIssue(.{
                .kind = .invalid_free,
                .address = address,
                .offset = address - record.address,
                .requested_len = len,
                .block_size = record.block_size,
                .allocation_id = record.allocation_id,
                .allocation_return_address = record.allocation_return_address,
                .free_return_address = record.free_return_address,
                .free_epoch = record.free_epoch,
                .return_address = ret_addr,
            });
            return;
        }
        if (self.containingKnownRecord(address)) |record| {
            self.recordIssue(.{
                .kind = .invalid_free,
                .address = address,
                .offset = address - record.address,
                .requested_len = len,
                .block_size = record.block_size,
                .allocation_id = record.allocation_id,
                .allocation_return_address = record.allocation_return_address,
                .free_return_address = record.free_return_address,
                .free_epoch = record.free_epoch,
                .return_address = ret_addr,
            });
            return;
        }
        self.recordIssue(.{
            .kind = .invalid_free,
            .address = address,
            .requested_len = len,
            .return_address = ret_addr,
        });
    }

    fn pageOwnedRecord(self: *Self, address: usize) ?AllocationRecord {
        if (!self.usesPageOwners()) return null;
        const owner_address = self.page_owners.get(pageNumber(address)) orelse return null;
        const record = self.known.get(owner_address) orelse return null;
        if (address <= record.address) return null;
        const end = std.math.add(usize, record.address, record.block_size) catch std.math.maxInt(usize);
        if (address >= end) return null;
        return record;
    }

    fn containingKnownRecord(self: *Self, address: usize) ?AllocationRecord {
        var iterator = self.known.valueIterator();
        while (iterator.next()) |record| {
            if (address <= record.address) continue;
            const end = std.math.add(usize, record.address, record.block_size) catch std.math.maxInt(usize);
            if (address < end) return record.*;
        }
        return null;
    }

    fn ensurePageOwnerCapacity(self: *Self, record: AllocationRecord) !void {
        return self.ensurePageOwnerCapacityFor(record.address, record.block_size);
    }

    fn ensurePageOwnerCapacityFor(self: *Self, address: usize, block_size: usize) !void {
        if (!self.usesPageOwners()) return;
        const pages = std.math.cast(u32, pageSpan(address, block_size)) orelse return error.OutOfMemory;
        try self.page_owners.ensureUnusedCapacity(pages);
    }

    fn putPageOwnerAssumeCapacity(self: *Self, record: AllocationRecord) void {
        if (!self.usesPageOwners()) return;
        const first_page = pageNumber(record.address);
        const pages = pageSpan(record.address, record.block_size);
        var index: usize = 0;
        while (index < pages) : (index += 1) {
            self.page_owners.putAssumeCapacity(first_page + index, record.address);
        }
    }

    fn removePageOwner(self: *Self, record: AllocationRecord) void {
        if (!self.usesPageOwners()) return;
        const first_page = pageNumber(record.address);
        const pages = pageSpan(record.address, record.block_size);
        var index: usize = 0;
        while (index < pages) : (index += 1) {
            _ = self.page_owners.remove(first_page + index);
        }
    }

    fn usesPageOwners(self: *const Self) bool {
        return self.config.mode == .dieharder;
    }

    fn recordIssue(self: *Self, issue: Issue) void {
        if (!self.diagnosticsActive()) return;
        self.counters.increment(issue.kind);
        self.last_issue = issue;
        self.issues.append(issue);
    }

    fn diagnosticsActive(self: *const Self) bool {
        return self.config.diagnostics.enabled or self.config.mode == .exterminator;
    }

    fn lock(self: *Self) void {
        if (!self.config.thread_safe) return;
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Self) void {
        if (self.config.thread_safe) self.mutex.unlock();
    }
};

const vtable: Allocator.VTable = .{
    .alloc = rawAlloc,
    .resize = rawResize,
    .remap = rawRemap,
    .free = rawFree,
};

fn repeatedPattern(byte: u8) u64 {
    var pattern: u64 = 0;
    var index: u6 = 0;
    while (index < 8) : (index += 1) {
        pattern |= @as(u64, byte) << (index * 8);
    }
    return pattern;
}

fn sanitizedFreedPattern(raw: u64) u64 {
    var pattern = if (raw == 0) @as(u64, 0x9e37_79b9_7f4a_7c15) else raw;
    var index: u6 = 0;
    while (index < 8) : (index += 1) {
        const shift = index * 8;
        const mask = @as(u64, 0xff) << shift;
        const byte: u8 = @truncate(pattern >> shift);
        if (byte == 0 or byte == freed_byte or byte == allocated_byte or byte == canary_byte) {
            pattern = (pattern & ~mask) | (@as(u64, sanitizedPatternByte(byte)) << shift);
        }
    }
    return pattern;
}

fn sanitizedPatternByte(byte: u8) u8 {
    const first = byte ^ 0x5a;
    if (first != 0 and first != freed_byte and first != allocated_byte and first != canary_byte) return first;
    return 0x7b;
}

fn patternByte(pattern: u64, offset: usize) u8 {
    const shift: u6 = @intCast((offset & 7) * 8);
    return @truncate(pattern >> shift);
}

fn alignForwardChecked(value: usize, alignment: usize) ?usize {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    const adjusted = std.math.add(usize, value, alignment - 1) catch return null;
    return std.mem.alignBackward(usize, adjusted, alignment);
}

fn pageNumber(address: usize) usize {
    return address / page_size;
}

fn pageSpan(address: usize, len: usize) usize {
    const first_page = pageNumber(address);
    const last_byte = std.math.add(usize, address, @max(len, 1) - 1) catch std.math.maxInt(usize);
    return pageNumber(last_byte) - first_page + 1;
}

fn rawAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *DeadAllocator = @ptrCast(@alignCast(ctx));
    return self.rawAlloc(len, alignment, ret_addr);
}

fn rawResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *DeadAllocator = @ptrCast(@alignCast(ctx));
    return self.rawResize(memory, alignment, new_len, ret_addr);
}

fn rawRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *DeadAllocator = @ptrCast(@alignCast(ctx));
    return self.rawRemap(memory, alignment, new_len, ret_addr);
}

fn rawFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *DeadAllocator = @ptrCast(@alignCast(ctx));
    self.rawFree(memory, alignment, ret_addr);
}

test "diehard mode returns aligned disjoint allocations" {
    var heap = DeadAllocator.init(std.testing.allocator, .{ .seed = 1 });
    defer heap.deinit();
    const allocator = heap.allocator();

    const left = try allocator.alignedAlloc(u8, .fromByteUnits(64), 33);
    defer allocator.free(left);
    const right = try allocator.alloc(u8, 33);
    defer allocator.free(right);

    try std.testing.expect(std.mem.isAligned(@intFromPtr(left.ptr), 64));
    try std.testing.expect(@intFromPtr(left.ptr) + left.len <= @intFromPtr(right.ptr) or @intFromPtr(right.ptr) + right.len <= @intFromPtr(left.ptr));
}

test "random small block probes tolerate occupied collisions" {
    var heap = DeadAllocator.init(std.testing.allocator, .{ .seed = 3, .min_chunk_blocks = 2, .thread_safe = false });
    defer heap.deinit();

    const class_index = size_class.indexFor(8, .@"1").?;
    try heap.addChunk(class_index, @returnAddress());
    const class_state = &heap.classes[class_index];

    const first = (try heap.tryAllocateSmallBlock(class_state, 0, 8, 0, 8, .@"1", @returnAddress())).?;
    const collision = try heap.tryAllocateSmallBlock(class_state, 0, 8, 0, 8, .@"1", @returnAddress());
    try std.testing.expect(collision == null);
    try std.testing.expectEqual(@as(usize, 1), class_state.live_count);
    try std.testing.expectEqual(@as(usize, 1), class_state.chunks.items[0].live_count);

    const second = (try heap.tryAllocateSmallBlock(class_state, 1, 8, 0, 8, .@"1", @returnAddress())).?;
    try std.testing.expect(@intFromPtr(first) + 8 <= @intFromPtr(second) or @intFromPtr(second) + 8 <= @intFromPtr(first));
    try std.testing.expectEqual(@as(usize, 2), class_state.live_count);
    try std.testing.expectEqual(@as(usize, 2), class_state.chunks.items[0].live_count);
}

test "dieharder large allocations are page granular" {
    var heap = DeadAllocator.init(std.testing.allocator, .{ .mode = .dieharder, .thread_safe = false });
    defer heap.deinit();
    const allocator = heap.allocator();

    const len = max_small_size + 1;
    const rounded_len = alignForwardChecked(len, page_size).?;
    const ptr = allocator.rawAlloc(len, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    try std.testing.expect(std.mem.isAligned(@intFromPtr(ptr), page_size));

    const record = heap.live.get(@intFromPtr(ptr)).?;
    try std.testing.expectEqual(.large, record.kind);
    try std.testing.expectEqual(rounded_len, record.backing_len);
    try std.testing.expectEqual(rounded_len, record.block_size);
    try std.testing.expectEqual(page_size, record.alignment.toByteUnits());

    try std.testing.expect(allocator.rawResize(ptr[0..len], .@"1", rounded_len, @returnAddress()));
    allocator.rawFree(ptr[0..rounded_len], .@"1", @returnAddress());
}

test "dieharder page owners resolve interior small frees" {
    var heap = DeadAllocator.init(std.testing.allocator, .{
        .mode = .dieharder,
        .thread_safe = false,
        .diagnostics = .{ .enabled = true },
    });
    defer heap.deinit();

    const ptr = heap.rawAlloc(64, .@"1", 0x1000) orelse return error.OutOfMemory;
    const address = @intFromPtr(ptr);
    try std.testing.expectEqual(address, heap.page_owners.get(pageNumber(address + 16)).?);

    heap.rawFree(ptr[16..32], .@"1", 0x2000);

    const report = heap.report();
    const issue = report.last_issue.?;
    try std.testing.expectEqual(@as(usize, 1), report.counters.invalid_free);
    try std.testing.expectEqual(@as(usize, 1), report.live_allocations);
    try std.testing.expectEqual(.invalid_free, issue.kind);
    try std.testing.expectEqual(address + 16, issue.address);
    try std.testing.expectEqual(@as(usize, 16), issue.offset);
    try std.testing.expectEqual(@as(usize, 16), issue.requested_len);
    try std.testing.expectEqual(address, heap.page_owners.get(pageNumber(address + page_size - 1)).?);

    heap.rawFree(ptr[0..64], .@"1", 0x3000);
}

test "dieharder page owners cover large quarantined pages" {
    var heap = DeadAllocator.init(std.testing.allocator, .{
        .mode = .dieharder,
        .thread_safe = false,
        .diagnostics = .{ .enabled = true, .quarantine_epochs = 8 },
    });
    defer heap.deinit();

    const len = max_small_size + page_size + 17;
    const ptr = heap.rawAlloc(len, .@"1", 0x1000) orelse return error.OutOfMemory;
    const address = @intFromPtr(ptr);
    const interior = address + page_size + 8;
    try std.testing.expectEqual(address, heap.page_owners.get(pageNumber(interior)).?);

    heap.rawFree((ptr + page_size + 8)[0..16], .@"1", 0x2000);

    const report = heap.report();
    const issue = report.last_issue.?;
    try std.testing.expectEqual(@as(usize, 1), report.counters.invalid_free);
    try std.testing.expectEqual(.invalid_free, issue.kind);
    try std.testing.expectEqual(interior, issue.address);
    try std.testing.expectEqual(page_size + 8, issue.offset);

    heap.rawFree(ptr[0..len], .@"1", 0x3000);
    try std.testing.expect(heap.page_owners.get(pageNumber(address)) != null);

    var index: usize = 0;
    while (index < 9) : (index += 1) {
        const scratch = heap.rawAlloc(64, .@"1", @returnAddress()) orelse return error.OutOfMemory;
        heap.rawFree(scratch[0..64], .@"1", @returnAddress());
    }
    _ = heap.report();
    try std.testing.expect(heap.page_owners.get(pageNumber(address)) == null);
}

const SwitchFailAllocator = struct {
    inner: Allocator,
    fail_allocations: bool = false,

    fn allocator(self: *SwitchFailAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *SwitchFailAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail_allocations) return null;
        return self.inner.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *SwitchFailAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail_allocations) return false;
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *SwitchFailAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail_allocations) return null;
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *SwitchFailAllocator = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

test "dieharder releases large page owners when quarantine append fails" {
    var backing = SwitchFailAllocator{ .inner = std.testing.allocator };
    var heap = DeadAllocator.init(backing.allocator(), .{
        .mode = .dieharder,
        .thread_safe = false,
        .diagnostics = .{ .enabled = true, .quarantine_epochs = 8 },
    });
    defer heap.deinit();

    const len = max_small_size + page_size + 17;
    const ptr = heap.rawAlloc(len, .@"1", 0x1000) orelse return error.OutOfMemory;
    const address = @intFromPtr(ptr);
    const middle_page = pageNumber(address + page_size);
    try std.testing.expect(heap.page_owners.get(pageNumber(address)) != null);
    try std.testing.expect(heap.page_owners.get(middle_page) != null);

    backing.fail_allocations = true;
    heap.rawFree(ptr[0..len], .@"1", 0x2000);
    backing.fail_allocations = false;

    try std.testing.expectEqual(@as(usize, 0), heap.live.count());
    try std.testing.expectEqual(@as(usize, 0), heap.large_quarantine.items.len);
    try std.testing.expect(heap.page_owners.get(pageNumber(address)) == null);
    try std.testing.expect(heap.page_owners.get(middle_page) == null);
}

test "small quarantine availability survives epoch wraparound" {
    var heap = DeadAllocator.init(std.testing.allocator, .{
        .mode = .exterminator,
        .thread_safe = false,
        .min_chunk_blocks = 2,
        .diagnostics = .{ .enabled = true, .quarantine_epochs = 4 },
    });
    defer heap.deinit();

    heap.epoch = std.math.maxInt(u64) - 1;
    const ptr = heap.rawAlloc(16, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    const address = @intFromPtr(ptr);
    heap.rawFree(ptr[0..16], .@"1", @returnAddress());

    const block = heap.known.get(address).?.small_block.?;
    try std.testing.expectEqual(std.math.maxInt(u64), block.chunk.free_epochs[block.index]);
    try std.testing.expectEqual(@as(u64, 0), heap.epoch);
    try std.testing.expect(!block.chunk.isAvailable(block.index, heap.epoch));

    heap.epoch = 2;
    try std.testing.expect(!block.chunk.isAvailable(block.index, heap.epoch));

    heap.epoch = 3;
    try std.testing.expect(block.chunk.isAvailable(block.index, heap.epoch));
}

test "repair config adds overflow padding from nondiagnostic mode" {
    const report: report_mod.Report = .{
        .counters = .{
            .buffer_overflow = 1,
        },
    };
    const repaired = Config.repaired(.{ .mode = .diehard, .diagnostics = .{ .enabled = false, .red_zone_bytes = 0 } }, report);
    try std.testing.expectEqual(.exterminator, repaired.mode);
    try std.testing.expect(repaired.diagnostics.enabled);
    try std.testing.expectEqual(@as(usize, 16), repaired.diagnostics.red_zone_bytes);
}

test "repair config applies overflow padding by allocation site" {
    const alloc_site: usize = 0x1000;
    const report: report_mod.Report = .{
        .counters = .{ .buffer_overflow = 1 },
        .issues = .{
            .count = 1,
            .items = [_]report_mod.Issue{.{
                .kind = .buffer_overflow,
                .offset = 10,
                .requested_len = 8,
                .allocation_return_address = alloc_site,
            }} ++ @as([(report_mod.max_issues - 1)]report_mod.Issue, @splat(.{})),
        },
    };
    const repaired = Config.repaired(Config.diagnostic(.exterminator), report);
    try std.testing.expectEqual(@as(usize, 3), repaired.repairs.overflowPadding(alloc_site));

    var heap = DeadAllocator.init(std.testing.allocator, repaired);
    defer heap.deinit();
    const ptr = heap.rawAlloc(8, .@"1", alloc_site) orelse return error.OutOfMemory;
    const record = heap.live.get(@intFromPtr(ptr)).?;
    try std.testing.expectEqual(@as(usize, 3), record.repair_padding);

    ptr[10] = 0xee;
    try std.testing.expectEqual(@as(usize, 0), heap.report().counters.buffer_overflow);

    ptr[11] = 0xee;
    try std.testing.expectEqual(@as(usize, 1), heap.report().counters.buffer_overflow);
    heap.rawFree(ptr[0..8], .@"1", @returnAddress());
}

test "repair config applies dangle extension by allocation and free site" {
    const alloc_site: usize = 0x1111;
    const free_site: usize = 0x2222;
    const report: report_mod.Report = .{
        .counters = .{ .use_after_free = 1 },
        .issues = .{
            .count = 1,
            .items = [_]report_mod.Issue{.{
                .kind = .use_after_free,
                .allocation_return_address = alloc_site,
                .free_return_address = free_site,
            }} ++ @as([(report_mod.max_issues - 1)]report_mod.Issue, @splat(.{})),
        },
    };
    var table = exterminator.RepairTable.fromReport(report, .{});
    table = exterminator.RepairTable.fromReport(report, table);
    table = exterminator.RepairTable.fromReport(report, table);

    const repaired = Config.repaired(.{
        .mode = .exterminator,
        .diagnostics = .{ .enabled = true, .quarantine_epochs = 1 },
        .repairs = table,
    }, report);
    try std.testing.expectEqual(@as(u64, 8), repaired.repairs.lifeExtension(alloc_site, free_site));
    try std.testing.expectEqual(@as(u64, 2), repaired.diagnostics.quarantine_epochs);

    var heap = DeadAllocator.init(std.testing.allocator, repaired);
    defer heap.deinit();
    const ptr = heap.rawAlloc(8, .@"1", alloc_site) orelse return error.OutOfMemory;
    heap.rawFree(ptr[0..8], .@"1", free_site);
    const known = heap.known.get(@intFromPtr(ptr)).?;
    try std.testing.expectEqual(@as(u64, 8), known.free_quarantine_epochs);
}

test "exterminator mode reports invalid free double free overflow and leaks" {
    var heap = DeadAllocator.init(std.testing.allocator, Config.diagnostic(.exterminator));
    defer heap.deinit();
    const allocator = heap.allocator();

    var stack_byte: u8 = 0;
    allocator.rawFree((&stack_byte)[0..1], .@"1", @returnAddress());

    const ptr = allocator.rawAlloc(8, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    ptr[8] = 1;
    allocator.rawFree(ptr[0..8], .@"1", @returnAddress());
    allocator.rawFree(ptr[0..8], .@"1", @returnAddress());

    _ = try allocator.alloc(u8, 24);

    const got = heap.report();
    try std.testing.expectEqual(@as(usize, 1), got.counters.invalid_free);
    try std.testing.expectEqual(@as(usize, 1), got.counters.double_free);
    try std.testing.expectEqual(@as(usize, 1), got.counters.buffer_overflow);
    try std.testing.expectEqual(@as(usize, 1), got.leak_count);
    try std.testing.expectEqual(.leak, got.leak_issue.?.kind);
    try std.testing.expectEqual(@as(usize, 24), got.leak_issue.?.requested_len);
}

test "diagnostic invalid free reports interior allocation context" {
    var heap = DeadAllocator.init(std.testing.allocator, Config.diagnostic(.exterminator));
    defer heap.deinit();
    const allocator = heap.allocator();

    const ptr = allocator.rawAlloc(32, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    allocator.rawFree(ptr[1..2], .@"1", @returnAddress());

    const got = heap.report();
    const issue = got.last_issue.?;
    try std.testing.expectEqual(@as(usize, 1), got.counters.invalid_free);
    try std.testing.expectEqual(@as(usize, 1), got.live_allocations);
    try std.testing.expectEqual(.invalid_free, issue.kind);
    try std.testing.expectEqual(@intFromPtr(ptr) + 1, issue.address);
    try std.testing.expectEqual(@as(usize, 1), issue.offset);
    try std.testing.expectEqual(@as(usize, 1), issue.requested_len);
    try std.testing.expect(issue.block_size >= 32);
    try std.testing.expect(issue.allocation_id != 0);
    try std.testing.expect(issue.allocation_return_address != 0);

    allocator.rawFree(ptr[0..32], .@"1", @returnAddress());
}

test "diagnostic raw remap rejects unknown allocation" {
    var heap = DeadAllocator.init(std.testing.allocator, Config.diagnostic(.exterminator));
    defer heap.deinit();
    const allocator = heap.allocator();

    var stack_byte: u8 = 0x5a;
    const remapped = allocator.rawRemap((&stack_byte)[0..1], .@"1", 16, @returnAddress());

    const got = heap.report();
    try std.testing.expect(remapped == null);
    try std.testing.expectEqual(@as(usize, 1), got.counters.invalid_free);
    try std.testing.expectEqual(@as(usize, 0), got.live_allocations);
}

test "diagnostic raw remap rejects freed allocation" {
    var heap = DeadAllocator.init(std.testing.allocator, Config.diagnostic(.exterminator));
    defer heap.deinit();
    const allocator = heap.allocator();

    const ptr = allocator.rawAlloc(16, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    allocator.rawFree(ptr[0..16], .@"1", @returnAddress());
    const remapped = allocator.rawRemap(ptr[0..16], .@"1", 32, @returnAddress());

    const got = heap.report();
    try std.testing.expect(remapped == null);
    try std.testing.expectEqual(@as(usize, 1), got.counters.double_free);
    try std.testing.expectEqual(@as(usize, 0), got.live_allocations);
}

test "diagnostic report retains structured issue history" {
    var heap = DeadAllocator.init(std.testing.allocator, Config.diagnostic(.exterminator));
    defer heap.deinit();
    const allocator = heap.allocator();

    var stack_byte: u8 = 0;
    allocator.rawFree((&stack_byte)[0..1], .@"1", @returnAddress());

    const overflow = allocator.rawAlloc(8, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    overflow[10] = 0xee;
    allocator.rawFree(overflow[0..8], .@"1", @returnAddress());

    const doubled = allocator.rawAlloc(16, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    allocator.rawFree(doubled[0..16], .@"1", @returnAddress());
    allocator.rawFree(doubled[0..16], .@"1", @returnAddress());

    const got = heap.report();
    const issues = got.issueSlice();
    try std.testing.expectEqual(@as(usize, 3), issues.len);
    try std.testing.expectEqual(.invalid_free, issues[0].kind);
    try std.testing.expectEqual(.buffer_overflow, issues[1].kind);
    try std.testing.expectEqual(.double_free, issues[2].kind);
    try std.testing.expectEqual(@as(usize, 10), issues[1].offset);
    try std.testing.expect(issues[1].allocation_id != 0);
    try std.testing.expect(issues[2].free_return_address != 0);
    try std.testing.expect(issues[2].free_epoch != 0);
}

test "diagnostic report includes bounded leak issues" {
    var heap = DeadAllocator.init(std.testing.allocator, Config.diagnostic(.exterminator));
    defer heap.deinit();
    const allocator = heap.allocator();

    const first = try allocator.alloc(u8, 8);
    defer allocator.free(first);
    const second = try allocator.alloc(u8, 16);
    defer allocator.free(second);
    const third = try allocator.alloc(u8, 24);
    defer allocator.free(third);

    const got = heap.report();
    const issues = got.issueSlice();
    try std.testing.expectEqual(@as(usize, 3), got.leak_count);
    try std.testing.expectEqual(@as(usize, 3), issues.len);
    for (issues) |issue| {
        try std.testing.expectEqual(.leak, issue.kind);
        try std.testing.expect(issue.allocation_id != 0);
        try std.testing.expect(issue.allocation_return_address != 0);
    }
}

test "diagnostic report detects stale small writes before reuse" {
    var heap = DeadAllocator.init(std.testing.allocator, Config.diagnostic(.exterminator));
    defer heap.deinit();
    const allocator = heap.allocator();

    const allocation = try allocator.alloc(u8, 16);
    const address = @intFromPtr(allocation.ptr);
    allocator.free(allocation);

    const stale: [*]u8 = @ptrFromInt(address);
    stale[0] = freed_byte;

    const first = heap.report();
    const second = heap.report();
    try std.testing.expectEqual(@as(usize, 1), first.counters.use_after_free);
    try std.testing.expectEqual(@as(usize, 1), second.counters.use_after_free);
}

test "diagnostic report scans entire freed small block" {
    var heap = DeadAllocator.init(std.testing.allocator, Config.diagnostic(.exterminator));
    defer heap.deinit();
    const allocator = heap.allocator();

    const allocation = try allocator.alloc(u8, 17);
    const address = @intFromPtr(allocation.ptr);
    allocator.free(allocation);

    const stale: [*]u8 = @ptrFromInt(address);
    stale[40] = freed_byte;

    const got = heap.report();
    try std.testing.expectEqual(@as(usize, 1), got.counters.use_after_free);
    const issue = got.last_issue.?;
    try std.testing.expectEqual(.use_after_free, issue.kind);
    try std.testing.expectEqual(@as(usize, 40), issue.offset);
    try std.testing.expect(issue.allocation_id != 0);
    try std.testing.expect(issue.free_return_address != 0);
    try std.testing.expect(issue.free_epoch != 0);
}

test "diagnostic freed patterns detect fixed fill byte writes" {
    var heap = DeadAllocator.init(std.testing.allocator, Config.diagnostic(.exterminator));
    defer heap.deinit();
    const allocator = heap.allocator();

    const allocation = try allocator.alloc(u8, 16);
    const address = @intFromPtr(allocation.ptr);
    allocator.free(allocation);

    const stale: [*]u8 = @ptrFromInt(address);
    stale[0] = freed_byte;

    const got = heap.report();
    try std.testing.expectEqual(@as(usize, 1), got.counters.use_after_free);
}

test "diagnostic resize checks existing red zone before updating size" {
    var heap = DeadAllocator.init(std.testing.allocator, Config.diagnostic(.exterminator));
    defer heap.deinit();
    const allocator = heap.allocator();

    const ptr = allocator.rawAlloc(8, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    ptr[8] = 0xee;

    try std.testing.expect(allocator.rawResize(ptr[0..8], .@"1", 12, @returnAddress()));
    const got = heap.report();
    try std.testing.expectEqual(@as(usize, 1), got.counters.buffer_overflow);
}

test "diagnostic report detects live red zone overflow once" {
    var heap = DeadAllocator.init(std.testing.allocator, Config.diagnostic(.exterminator));
    defer heap.deinit();
    const allocator = heap.allocator();

    const ptr = allocator.rawAlloc(8, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    ptr[8] = 0xee;

    const first = heap.report();
    const second = heap.report();
    try std.testing.expectEqual(@as(usize, 1), first.counters.buffer_overflow);
    try std.testing.expectEqual(@as(usize, 1), second.counters.buffer_overflow);

    allocator.rawFree(ptr[0..8], .@"1", @returnAddress());
    const after_free = heap.report();
    try std.testing.expectEqual(@as(usize, 1), after_free.counters.buffer_overflow);
}

test "diagnostic report detects stale large writes while quarantined" {
    var heap = DeadAllocator.init(std.testing.allocator, Config.diagnostic(.exterminator));
    defer heap.deinit();
    const allocator = heap.allocator();

    const len = max_small_size + 64;
    const ptr = allocator.rawAlloc(len, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    const address = @intFromPtr(ptr);
    allocator.rawFree(ptr[0..len], .@"1", @returnAddress());

    const stale: [*]u8 = @ptrFromInt(address);
    stale[0] = freed_byte;

    const first = heap.report();
    const second = heap.report();
    try std.testing.expectEqual(@as(usize, 1), first.counters.use_after_free);
    try std.testing.expectEqual(@as(usize, 1), second.counters.use_after_free);
}

test "diehard mode preserves freed small contents until reuse" {
    var heap = DeadAllocator.init(std.testing.allocator, .{
        .mode = .diehard,
        .seed = 4,
        .min_chunk_blocks = 8,
        .thread_safe = false,
    });
    defer heap.deinit();

    const ptr = heap.rawAlloc(64, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    @memset(ptr[0..64], 0xab);
    const address = @intFromPtr(ptr);
    heap.rawFree(ptr[0..64], .@"1", @returnAddress());

    const stale: [*]u8 = @ptrFromInt(address);
    for (stale[0..64]) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
    try std.testing.expect(heap.report().isClean());
}

test "dieharder mode zeroes freed small contents" {
    var heap = DeadAllocator.init(std.testing.allocator, .{
        .mode = .dieharder,
        .seed = 5,
        .min_chunk_blocks = 8,
        .thread_safe = false,
    });
    defer heap.deinit();

    const ptr = heap.rawAlloc(64, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    @memset(ptr[0..64], 0xab);
    const address = @intFromPtr(ptr);
    heap.rawFree(ptr[0..64], .@"1", @returnAddress());

    const stale: [*]u8 = @ptrFromInt(address);
    for (stale[0..64]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect(heap.report().isClean());
}

test "deinit releases reported large leaks" {
    var heap = DeadAllocator.init(std.testing.allocator, Config.diagnostic(.exterminator));
    const allocator = heap.allocator();

    _ = try allocator.alloc(u8, max_small_size + 4096);

    const got = heap.report();
    try std.testing.expectEqual(@as(usize, 1), got.leak_count);
    try std.testing.expectEqual(.leak, got.leak_issue.?.kind);
    try std.testing.expectEqual(@as(usize, max_small_size + 4096), got.leak_issue.?.requested_len);
    heap.deinit();
}

test "dieharder mode delays reuse and detects stale writes when diagnostics are enabled" {
    var heap = DeadAllocator.init(std.testing.allocator, .{
        .mode = .dieharder,
        .seed = 2,
        .min_chunk_blocks = 2,
        .diagnostics = .{ .enabled = true, .quarantine_epochs = 2 },
    });
    defer heap.deinit();
    const allocator = heap.allocator();

    const first = try allocator.alloc(u8, 16);
    const first_addr = @intFromPtr(first.ptr);
    allocator.free(first);
    const stale: [*]u8 = @ptrFromInt(first_addr);
    stale[0] = 0x44;

    var scratch: ?[]u8 = null;
    var index: usize = 0;
    while (index < 32 and heap.report().counters.use_after_free == 0) : (index += 1) {
        scratch = try allocator.alloc(u8, 16);
        allocator.free(scratch.?);
        scratch = null;
    }

    const got = heap.report();
    try std.testing.expect(got.counters.use_after_free >= 1);
}

const ConcurrentWork = struct {
    allocator: Allocator,
    handoff: []?[]u8,
    failed: *std.atomic.Value(bool),
};

fn concurrentAllocatorWorker(work: *ConcurrentWork, worker_index: usize) void {
    const handoff_per_thread = 16;
    const start = worker_index * handoff_per_thread;
    const end = start + handoff_per_thread;
    var handoff_index = start;
    while (handoff_index < end) : (handoff_index += 1) {
        const allocation = work.handoff[handoff_index] orelse {
            work.failed.store(true, .release);
            return;
        };
        const expected: u8 = @truncate(handoff_index *% 17 +% 3);
        for (allocation) |byte| {
            if (byte != expected) {
                work.failed.store(true, .release);
                return;
            }
        }
        work.allocator.free(allocation);
        work.handoff[handoff_index] = null;
    }

    var iteration: usize = 0;
    while (iteration < 128) : (iteration += 1) {
        const len = 1 + ((worker_index * 257 + iteration * 37) % 2048);
        const fill: u8 = @truncate(worker_index *% 31 +% iteration);
        const allocation = work.allocator.alloc(u8, len) catch {
            work.failed.store(true, .release);
            return;
        };
        @memset(allocation, fill);

        const new_len = 1 + ((worker_index * 131 + iteration * 53) % 4096);
        const resized = work.allocator.realloc(allocation, new_len) catch {
            work.allocator.free(allocation);
            work.failed.store(true, .release);
            return;
        };
        const prefix_len = @min(len, new_len);
        for (resized[0..prefix_len]) |byte| {
            if (byte != fill) {
                work.allocator.free(resized);
                work.failed.store(true, .release);
                return;
            }
        }
        @memset(resized, fill);
        work.allocator.free(resized);
    }
}

test "thread-safe allocator supports concurrent allocation and cross-thread free" {
    const thread_count = 4;
    const handoff_per_thread = 16;

    var heap = DeadAllocator.init(std.testing.allocator, .{
        .mode = .dieharder,
        .seed = 0x7c0c_5afe,
        .diagnostics = .{ .enabled = true, .quarantine_epochs = 8 },
    });
    defer heap.deinit();
    const allocator = heap.allocator();

    var handoff: [thread_count * handoff_per_thread]?[]u8 = @as([(thread_count * handoff_per_thread)]?[]u8, @splat(null));
    defer {
        for (handoff) |allocation| {
            if (allocation) |live| allocator.free(live);
        }
    }

    for (&handoff, 0..) |*slot, index| {
        const len = 1 + (index * 23) % 1024;
        const fill: u8 = @truncate(index *% 17 +% 3);
        const allocation = try allocator.alloc(u8, len);
        @memset(allocation, fill);
        slot.* = allocation;
    }

    var failed = std.atomic.Value(bool).init(false);
    var work = ConcurrentWork{
        .allocator = allocator,
        .handoff = &handoff,
        .failed = &failed,
    };
    var threads: [thread_count]sys_thread.JoinHandle = undefined;
    var spawned: usize = 0;
    while (spawned < thread_count) : (spawned += 1) {
        threads[spawned] = try sys_thread.spawn(concurrentAllocatorWorker, .{ &work, spawned });
    }
    for (threads) |thread| thread.join();

    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expect(heap.report().isClean());
}
