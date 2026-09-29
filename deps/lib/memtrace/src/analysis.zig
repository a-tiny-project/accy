const std = @import("std");
const observe = @import("alloc_observe");
const pretty_json = @import("pretty").json;
const sys = @import("sys");
const allocations = @import("allocations.zig");
const coverage_mod = @import("coverage.zig");
const event_mod = @import("event.zig");
const mappings = @import("mappings.zig");
const stack_mod = @import("stack/root.zig");
const tracer_mod = @import("tracer.zig");

const Allocator = std.mem.Allocator;

pub const Sort = enum {
    retained,
    traffic,
    lifetime,

    pub fn parse(value: []const u8) ?Sort {
        if (std.mem.eql(u8, value, "retained")) return .retained;
        if (std.mem.eql(u8, value, "traffic")) return .traffic;
        if (std.mem.eql(u8, value, "lifetime")) return .lifetime;
        return null;
    }

    pub fn name(self: Sort) []const u8 {
        return @tagName(self);
    }
};

pub const SummaryOptions = struct {
    top: usize = 24,
    min_bytes: usize = 0,
    include_zero_live: bool = false,
    include_sites: bool = false,
    site_detail_return_address: ?u64 = null,
    site_symbol_binary: ?[]const u8 = null,
    layer: event_mod.LayerFilter = .backing,
    sort: Sort = .retained,
};

pub const SnapshotOptions = struct {
    top: usize = 24,
    min_bytes: usize = 0,
    include_zero_live: bool = false,
    site_symbol_binary: ?[]const u8 = null,
    layer: event_mod.LayerFilter = .backing,
};

pub const Summary = struct {
    events: u64 = 0,
    allocations: u64 = 0,
    frees: u64 = 0,
    resizes: u64 = 0,
    remaps: u64 = 0,
    live_allocations: u64 = 0,
    allocated_bytes: u64 = 0,
    freed_bytes: u64 = 0,
    live_bytes: u64 = 0,
    high_water_live_bytes: u64 = 0,
    retained_bytes: u64 = 0,
    high_water_retained_bytes: u64 = 0,
    completed_lifetimes: u64 = 0,
    lifetime_total_events: u64 = 0,
    lifetime_mean_events: u64 = 0,
    lifetime_max_events: u64 = 0,
    lifetime_total_byte_events: u64 = 0,
    lifetime_mean_byte_events: u64 = 0,
    lifetime_max_byte_events: u64 = 0,
    failed_allocations: u64 = 0,
    failed_resizes: u64 = 0,
    failed_remaps: u64 = 0,
    unmatched_frees: u64 = 0,
    unmatched_resizes: u64 = 0,
};

pub const Scope = struct {
    scope: []const u8,
    retained_bytes: u64,
    high_water_retained_bytes: u64,
    live_bytes: u64,
    high_water_live_bytes: u64,
    allocated_bytes: u64,
    freed_bytes: u64,
    allocations: u64,
    frees: u64,
    live_allocations: u64,
    completed_lifetimes: u64,
    lifetime_total_events: u64,
    lifetime_mean_events: u64,
    lifetime_max_events: u64,
    lifetime_total_byte_events: u64 = 0,
    lifetime_mean_byte_events: u64 = 0,
    lifetime_max_byte_events: u64 = 0,
};

pub const Source = struct {
    return_address: u64,
    function: ?[]const u8,
    location: ?[]const u8,
    retained_bytes: u64,
    high_water_retained_bytes: u64,
    live_bytes: u64,
    high_water_live_bytes: u64,
    allocated_bytes: u64,
    freed_bytes: u64,
    allocations: u64,
    frees: u64,
    live_allocations: u64,
    completed_lifetimes: u64,
    lifetime_total_events: u64,
    lifetime_mean_events: u64,
    lifetime_max_events: u64,
    lifetime_total_byte_events: u64 = 0,
    lifetime_mean_byte_events: u64 = 0,
    lifetime_max_byte_events: u64 = 0,
};

pub const Ranking = struct {
    scopes: []Scope = &.{},
    sources: []Source = &.{},
};

pub const Rankings = struct {
    retained: Ranking = .{},
    traffic: Ranking = .{},
    lifetime: Ranking = .{},

    pub fn get(self: Rankings, sort: Sort) Ranking {
        return switch (sort) {
            .retained => self.retained,
            .traffic => self.traffic,
            .lifetime => self.lifetime,
        };
    }

    fn getPtr(self: *Rankings, sort: Sort) *Ranking {
        return switch (sort) {
            .retained => &self.retained,
            .traffic => &self.traffic,
            .lifetime => &self.lifetime,
        };
    }
};

pub const Snapshot = struct {
    allocator: Allocator,
    integrity: CaptureIntegrity,
    summary: Summary,
    rankings: Rankings = .{},
    symbol_storage: ?[]u8 = null,

    pub fn deinit(self: *Snapshot) void {
        inline for (std.meta.tags(Sort)) |sort| {
            const ranking = self.rankings.getPtr(sort);
            for (ranking.scopes) |scope| self.allocator.free(scope.scope);
            if (ranking.scopes.len != 0) self.allocator.free(ranking.scopes);
            if (ranking.sources.len != 0) self.allocator.free(ranking.sources);
        }
        if (self.symbol_storage) |storage| self.allocator.free(storage);
        self.* = undefined;
    }
};

const Retention = enum {
    releases_freed_memory,
    retains_freed_memory,
};

const Counters = struct {
    allocations: u64 = 0,
    frees: u64 = 0,
    resizes: u64 = 0,
    remaps: u64 = 0,
    failed_allocations: u64 = 0,
    failed_resizes: u64 = 0,
    failed_remaps: u64 = 0,
    unmatched_frees: u64 = 0,
    unmatched_resizes: u64 = 0,
    unmatched_remaps: u64 = 0,
    bulk_invalidated_requests: u64 = 0,
    bulk_invalidated_bytes: usize = 0,
    untracked_requests: u64 = 0,
    untracked_request_bytes: usize = 0,
    lifecycle_events: u64 = 0,
    live_allocations: usize = 0,
    allocated_bytes: usize = 0,
    freed_bytes: usize = 0,
    live_bytes: usize = 0,
    high_water_live_bytes: usize = 0,
    retained_bytes: usize = 0,
    high_water_retained_bytes: usize = 0,
    completed_lifetimes: u64 = 0,
    lifetime_total_events: u64 = 0,
    lifetime_max_events: u64 = 0,
    lifetime_total_byte_events: u64 = 0,
    lifetime_max_byte_events: u64 = 0,
};

const PhysicalCounters = struct {
    maps: u64 = 0,
    unmaps: u64 = 0,
    protects: u64 = 0,
    discards: u64 = 0,
    decommits: u64 = 0,
    advises: u64 = 0,
    failed_maps: u64 = 0,
    failed_unmaps: u64 = 0,
    failed_protects: u64 = 0,
    failed_discards: u64 = 0,
    failed_decommits: u64 = 0,
    failed_advises: u64 = 0,
    mapped_bytes: usize = 0,
    unmapped_bytes: usize = 0,
    displaced_bytes: usize = 0,
    untracked_unmap_bytes: usize = 0,
    live_mapped_bytes: usize = 0,
    high_water_mapped_bytes: usize = 0,
};

const IntegrityCounters = struct {
    sequenced_events: u64 = 0,
    unsequenced_events: u64 = 0,
    sequence_gaps: u64 = 0,
    missing_sequence_events: u64 = 0,
    sequence_regressions: u64 = 0,
    start_events: u64 = 0,
    stop_events: u64 = 0,
    unmatched_scope_exits: u64 = 0,
    active_scope_events: u64 = 0,
};

pub const capture_integrity_method = "memtrace_event_sequence_and_lifecycle_v1";

pub const CaptureIntegrity = struct {
    status: []const u8,
    action: []const u8,
    message: ?[]const u8,
    event_count: u64,
    sequenced_event_count: u64,
    unsequenced_event_count: u64,
    first_sequence: ?u64,
    last_sequence: ?u64,
    sequence_gap_count: u64,
    missing_sequence_event_count: u64,
    sequence_regression_count: u64,
    start_event_count: u64,
    stop_event_count: u64,
    start_sequence: ?u64,
    stop_sequence: ?u64,
    unbalanced_event_count: u64,
};

const ScopeCounters = struct {
    allocations: u64 = 0,
    frees: u64 = 0,
    allocated_bytes: usize = 0,
    freed_bytes: usize = 0,
    bulk_invalidated_requests: u64 = 0,
    bulk_invalidated_bytes: usize = 0,
    untracked_requests: u64 = 0,
    untracked_request_bytes: usize = 0,
    live_allocations: usize = 0,
    live_bytes: usize = 0,
    high_water_live_bytes: usize = 0,
    retained_bytes: usize = 0,
    high_water_retained_bytes: usize = 0,
    completed_lifetimes: u64 = 0,
    lifetime_total_events: u64 = 0,
    lifetime_max_events: u64 = 0,
    lifetime_total_byte_events: u64 = 0,
    lifetime_max_byte_events: u64 = 0,
};

const AllocatorState = struct {
    retention: Retention = .releases_freed_memory,
    layer: event_mod.Layer = .backing_boundary,
    lifecycle_instrumented: bool = false,
    prefix_complete: bool = true,
};

const LifecycleCoverage = struct {
    instrumented: u64 = 0,
    uninstrumented: u64 = 0,
    not_required: u64 = 0,
    prefix_complete: u64 = 0,
    prefix_partial: u64 = 0,

    fn status(self: LifecycleCoverage) []const u8 {
        if (self.instrumented == 0 and
            self.uninstrumented == 0 and
            self.not_required == 0)
        {
            return "none";
        }
        if (self.uninstrumented == 0 and self.prefix_partial == 0) {
            return "complete";
        }
        return "partial";
    }
};

const AllocationRecord = struct {
    allocator_id: u32,
    len: usize,
    scope: []const u8,
    return_address: u64,
    allocation_event: u64,
    segment_event: u64,
    byte_events: u64,
};

const ScopeSummary = struct {
    path: []const u8,
    counters: ScopeCounters,
};

const ParsedEvent = event_mod.ReplayEvent;

const SiteCounters = struct {
    allocations: u64 = 0,
    frees: u64 = 0,
    allocated_bytes: usize = 0,
    freed_bytes: usize = 0,
    bulk_invalidated_requests: u64 = 0,
    bulk_invalidated_bytes: usize = 0,
    untracked_requests: u64 = 0,
    untracked_request_bytes: usize = 0,
    live_allocations: usize = 0,
    live_bytes: usize = 0,
    high_water_live_bytes: usize = 0,
    retained_bytes: usize = 0,
    high_water_retained_bytes: usize = 0,
    completed_lifetimes: u64 = 0,
    lifetime_total_events: u64 = 0,
    lifetime_max_events: u64 = 0,
    lifetime_total_byte_events: u64 = 0,
    lifetime_max_byte_events: u64 = 0,
};

const SiteSummary = struct {
    return_address: u64,
    counters: SiteCounters,
};

const SiteSizeSummary = struct {
    len: usize,
    counters: SiteCounters,
};

const SiteScopeSummary = struct {
    scope: []const u8,
    counters: SiteCounters,
};

pub const Analyzer = struct {
    allocator: Allocator,
    allocators: std.AutoHashMapUnmanaged(u32, AllocatorState) = .{},
    allocations: allocations.Map(AllocationRecord) = .{},
    scopes: std.StringHashMapUnmanaged(ScopeCounters) = .{},
    sites: std.AutoHashMapUnmanaged(u64, SiteCounters) = .{},
    site_detail_sizes: std.AutoHashMapUnmanaged(usize, SiteCounters) = .{},
    site_detail_scopes: std.StringHashMapUnmanaged(SiteCounters) = .{},
    site_detail_return_address: ?u64 = null,
    active_scopes: std.AutoHashMapUnmanaged(u32, u64) = .{},
    scope_paths: std.AutoHashMapUnmanaged(u32, []const u8) = .{},
    track_sites: bool = true,
    layer_filter: event_mod.LayerFilter = .backing,
    counters: Counters = .{},
    physical: PhysicalCounters = .{},
    mappings: mappings.Ledger = .{},
    integrity_counters: IntegrityCounters = .{},
    events: u64 = 0,
    first_sequence: ?u64 = null,
    last_sequence: ?u64 = null,
    start_sequence: ?u64 = null,
    stop_sequence: ?u64 = null,

    pub fn init(allocator: Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn initForLayer(
        allocator: Allocator,
        layer_filter: event_mod.LayerFilter,
    ) Analyzer {
        return .{
            .allocator = allocator,
            .layer_filter = layer_filter,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        var iterator = self.scopes.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.scopes.deinit(self.allocator);
        self.sites.deinit(self.allocator);
        self.site_detail_sizes.deinit(self.allocator);
        self.site_detail_scopes.deinit(self.allocator);
        self.active_scopes.deinit(self.allocator);
        self.scope_paths.deinit(self.allocator);
        self.allocators.deinit(self.allocator);
        self.allocations.deinit(self.allocator);
        self.mappings.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ingestJsonlBytes(self: *Analyzer, bytes: []const u8) !void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| try self.ingestJsonLine(line);
    }

    pub fn ingestJsonLine(self: *Analyzer, line: []const u8) !void {
        const text = std.mem.trim(u8, line, " \t\r\n");
        if (text.len == 0) return;
        if (stack_mod.isMetadataLine(text) or coverage_mod.isMetadataLine(text)) return;

        var line_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer line_arena.deinit();
        try self.ingestParsedEvent(
            try event_mod.parseReplay(line_arena.allocator(), text),
        );
    }

    fn ingestParsedEvent(self: *Analyzer, parsed: ParsedEvent) !void {
        const scope = try self.resolveScope(parsed);
        const key = switch (parsed.kind) {
            .remap => allocationKey(parsed.allocation_id, parsed.old_address),
            else => allocationKey(parsed.allocation_id, parsed.address),
        };

        self.events +|= 1;
        self.recordSequence(parsed.seq);
        switch (parsed.kind) {
            .trace_start => {
                self.integrity_counters.start_events +|= 1;
                if (self.start_sequence == null) self.start_sequence = parsed.seq;
            },
            .trace_stop => {
                self.integrity_counters.stop_events +|= 1;
                self.stop_sequence = parsed.seq;
            },
            .allocator => if (self.layer_filter.includes(parsed.layer)) {
                try self.recordAllocator(
                    parsed.allocator_id,
                    parsed.retains_freed_memory,
                    parsed.layer,
                    parsed.lifecycle_instrumented,
                    parsed.observation_prefix_complete,
                );
            },
            .scope_enter => try self.recordScopeEnter(parsed.scope_id, scope),
            .scope_exit => self.recordScopeExit(parsed.scope_id),
            .alloc => if (self.layer_filter.includes(parsed.layer)) {
                if (parsed.succeeded) {
                    if (parsed.tracked) {
                        try self.recordAllocation(
                            parsed.allocator_id,
                            key,
                            scope,
                            parsed.return_address,
                            parsed.len,
                        );
                    } else {
                        try self.recordUntrackedAllocation(
                            scope,
                            parsed.return_address,
                            parsed.len,
                        );
                    }
                } else {
                    self.counters.failed_allocations +|= 1;
                }
            },
            .free => if (self.layer_filter.includes(parsed.layer)) {
                if (parsed.tracked) {
                    try self.recordFree(
                        key,
                        parsed.allocator_id,
                        scope,
                        parsed.len,
                    );
                } else {
                    self.counters.unmatched_frees +|= 1;
                }
            },
            .release => if (self.layer_filter.includes(parsed.layer)) {
                try self.recordRelease(key);
            },
            .resize => if (self.layer_filter.includes(parsed.layer)) {
                if (parsed.succeeded) {
                    if (parsed.tracked) {
                        try self.recordResize(
                            key,
                            parsed.allocator_id,
                            scope,
                            parsed.old_len,
                            parsed.len,
                        );
                    } else {
                        self.counters.unmatched_resizes +|= 1;
                    }
                } else {
                    self.counters.failed_resizes +|= 1;
                    if (!parsed.tracked) {
                        self.counters.unmatched_resizes +|= 1;
                    }
                }
            },
            .remap => if (self.layer_filter.includes(parsed.layer)) {
                if (parsed.succeeded) {
                    if (parsed.tracked) {
                        try self.recordRemap(
                            key,
                            allocationKey(
                                parsed.allocation_id,
                                parsed.address,
                            ),
                            parsed.allocator_id,
                            scope,
                            parsed.old_len,
                            parsed.len,
                        );
                    } else if (parsed.allocation_id != 0) {
                        try self.recordLostTrackingRemap(
                            key,
                            parsed.len,
                        );
                    } else {
                        self.counters.unmatched_remaps +|= 1;
                    }
                } else {
                    self.counters.failed_remaps +|= 1;
                    if (!parsed.tracked) {
                        self.counters.unmatched_remaps +|= 1;
                    }
                }
            },
            .lifecycle => if (self.layer_filter.includes(parsed.layer)) {
                self.counters.lifecycle_events +|= 1;
                if (self.allocators.getPtr(parsed.allocator_id)) |allocator| {
                    allocator.prefix_complete = true;
                }
            },
            .map => if (self.layer_filter.includes(parsed.layer)) {
                try self.recordPhysicalMap(parsed);
            },
            .unmap => if (self.layer_filter.includes(parsed.layer)) {
                try self.recordPhysicalUnmap(parsed);
            },
            .protect => if (self.layer_filter.includes(parsed.layer)) {
                self.recordPhysicalEffect(parsed.succeeded, .protect);
            },
            .discard => if (self.layer_filter.includes(parsed.layer)) {
                self.recordPhysicalEffect(parsed.succeeded, .discard);
            },
            .decommit => if (self.layer_filter.includes(parsed.layer)) {
                self.recordPhysicalEffect(parsed.succeeded, .decommit);
            },
            .advise => if (self.layer_filter.includes(parsed.layer)) {
                self.recordPhysicalEffect(parsed.succeeded, .advise);
            },
            .snapshot, .census => {},
        }
    }

    fn recordPhysicalMap(self: *Analyzer, parsed: ParsedEvent) !void {
        if (!parsed.succeeded) {
            self.physical.failed_maps +|= 1;
            return;
        }
        const address = std.math.cast(usize, parsed.address) orelse
            return error.InvalidMappingRange;
        const displaced = try self.mappings.map(
            self.allocator,
            address,
            parsed.len,
        );
        self.physical.maps +|= 1;
        self.physical.mapped_bytes +|= parsed.len;
        self.physical.displaced_bytes +|= displaced;
        self.updatePhysicalLiveBytes();
    }

    fn recordPhysicalUnmap(self: *Analyzer, parsed: ParsedEvent) !void {
        if (!parsed.succeeded) {
            self.physical.failed_unmaps +|= 1;
            return;
        }
        const address = std.math.cast(usize, parsed.address) orelse
            return error.InvalidMappingRange;
        const removal = try self.mappings.unmap(
            self.allocator,
            address,
            parsed.len,
        );
        self.physical.unmaps +|= 1;
        self.physical.unmapped_bytes +|= parsed.len;
        self.physical.untracked_unmap_bytes +|= removal.untrackedBytes();
        self.updatePhysicalLiveBytes();
    }

    const PhysicalEffect = enum {
        protect,
        discard,
        decommit,
        advise,
    };

    fn recordPhysicalEffect(
        self: *Analyzer,
        succeeded: bool,
        effect: PhysicalEffect,
    ) void {
        const counter = switch (effect) {
            .protect => if (succeeded)
                &self.physical.protects
            else
                &self.physical.failed_protects,
            .discard => if (succeeded)
                &self.physical.discards
            else
                &self.physical.failed_discards,
            .decommit => if (succeeded)
                &self.physical.decommits
            else
                &self.physical.failed_decommits,
            .advise => if (succeeded)
                &self.physical.advises
            else
                &self.physical.failed_advises,
        };
        counter.* +|= 1;
    }

    fn updatePhysicalLiveBytes(self: *Analyzer) void {
        self.physical.live_mapped_bytes = self.mappings.mapped_bytes;
        self.physical.high_water_mapped_bytes = @max(
            self.physical.high_water_mapped_bytes,
            self.physical.live_mapped_bytes,
        );
    }

    pub fn captureIntegrity(self: *const Analyzer) CaptureIntegrity {
        var result: CaptureIntegrity = .{
            .status = "complete",
            .action = "none",
            .message = null,
            .event_count = self.events,
            .sequenced_event_count = self.integrity_counters.sequenced_events,
            .unsequenced_event_count = self.integrity_counters.unsequenced_events,
            .first_sequence = self.first_sequence,
            .last_sequence = self.last_sequence,
            .sequence_gap_count = self.integrity_counters.sequence_gaps,
            .missing_sequence_event_count = self.integrity_counters.missing_sequence_events,
            .sequence_regression_count = self.integrity_counters.sequence_regressions,
            .start_event_count = self.integrity_counters.start_events,
            .stop_event_count = self.integrity_counters.stop_events,
            .start_sequence = self.start_sequence,
            .stop_sequence = self.stop_sequence,
            .unbalanced_event_count = self.unbalancedEventCount(),
        };
        classifyCaptureIntegrity(&result);
        return result;
    }

    fn recordSequence(self: *Analyzer, maybe_sequence: ?u64) void {
        const sequence = maybe_sequence orelse {
            self.integrity_counters.unsequenced_events +|= 1;
            return;
        };
        if (sequence == 0) {
            self.integrity_counters.unsequenced_events +|= 1;
            return;
        }
        self.integrity_counters.sequenced_events +|= 1;
        const previous = self.last_sequence orelse {
            self.first_sequence = sequence;
            self.last_sequence = sequence;
            if (sequence > 1) {
                self.integrity_counters.sequence_gaps +|= 1;
                self.integrity_counters.missing_sequence_events +|= sequence - 1;
            }
            return;
        };
        if (sequence <= previous) {
            self.integrity_counters.sequence_regressions +|= 1;
        } else if (sequence - previous > 1) {
            self.integrity_counters.sequence_gaps +|= 1;
            self.integrity_counters.missing_sequence_events +|= sequence - previous - 1;
        }
        self.last_sequence = sequence;
    }

    fn recordScopeEnter(
        self: *Analyzer,
        scope_id: u32,
        scope: []const u8,
    ) !void {
        const owned_scope = try self.internScope(scope);
        const path = try self.scope_paths.getOrPut(self.allocator, scope_id);
        if (!path.found_existing) {
            path.value_ptr.* = owned_scope;
        } else if (!std.mem.eql(u8, path.value_ptr.*, owned_scope)) {
            return error.ScopeIdentityConflict;
        }
        const result = try self.active_scopes.getOrPut(self.allocator, scope_id);
        if (!result.found_existing) result.value_ptr.* = 0;
        result.value_ptr.* +|= 1;
        self.integrity_counters.active_scope_events +|= 1;
    }

    fn recordScopeExit(self: *Analyzer, scope_id: u32) void {
        const count = self.active_scopes.getPtr(scope_id) orelse {
            self.integrity_counters.unmatched_scope_exits +|= 1;
            return;
        };
        if (count.* == 0) {
            self.integrity_counters.unmatched_scope_exits +|= 1;
            return;
        }
        count.* -= 1;
        self.integrity_counters.active_scope_events -= 1;
        if (count.* == 0) _ = self.active_scopes.remove(scope_id);
    }

    fn unbalancedEventCount(self: *const Analyzer) u64 {
        var count = self.counters.unmatched_frees +|
            self.counters.unmatched_resizes +|
            self.counters.unmatched_remaps +|
            self.integrity_counters.unmatched_scope_exits;
        count +|= self.integrity_counters.active_scope_events;
        return count;
    }

    pub fn snapshot(
        self: *Analyzer,
        allocator: Allocator,
        options: SnapshotOptions,
    ) !Snapshot {
        if (options.layer != self.layer_filter) {
            return error.LayerSelectionMismatch;
        }
        var scope_summaries: [3]std.ArrayListUnmanaged(ScopeSummary) = .{
            .empty,
            .empty,
            .empty,
        };
        defer for (&scope_summaries) |*summaries| {
            summaries.deinit(self.allocator);
        };
        var site_summaries: [3]std.ArrayListUnmanaged(SiteSummary) = .{
            .empty,
            .empty,
            .empty,
        };
        defer for (&site_summaries) |*summaries| {
            summaries.deinit(self.allocator);
        };

        inline for (std.meta.tags(Sort)) |sort| {
            const summary_options = SummaryOptions{
                .top = options.top,
                .min_bytes = options.min_bytes,
                .include_zero_live = options.include_zero_live,
                .include_sites = true,
                .site_symbol_binary = options.site_symbol_binary,
                .layer = options.layer,
                .sort = sort,
            };
            scope_summaries[@backingInt(sort)] =
                try self.collectScopeSummaries(summary_options);
            site_summaries[@backingInt(sort)] =
                try self.collectSiteSummaries(summary_options);
        }

        var addresses = std.ArrayListUnmanaged(u64).empty;
        defer addresses.deinit(allocator);
        inline for (std.meta.tags(Sort)) |sort| {
            const sites = site_summaries[@backingInt(sort)].items;
            const limit = @min(options.top, sites.len);
            for (sites[0..limit]) |site| {
                if (std.mem.indexOfScalar(
                    u64,
                    addresses.items,
                    site.return_address,
                ) == null) {
                    try addresses.append(allocator, site.return_address);
                }
            }
        }

        var maybe_symbols = if (options.site_symbol_binary) |binary|
            try resolveSiteAddressesAlloc(allocator, binary, addresses.items)
        else
            null;
        defer if (maybe_symbols) |*symbols| symbols.deinit(allocator);

        var result = Snapshot{
            .allocator = allocator,
            .integrity = self.captureIntegrity(),
            .summary = summarySnapshot(self),
        };
        errdefer result.deinit();
        inline for (std.meta.tags(Sort)) |sort| {
            const scopes = scope_summaries[@backingInt(sort)].items;
            const sites = site_summaries[@backingInt(sort)].items;
            const ranking = result.rankings.getPtr(sort);
            ranking.scopes = try snapshotScopes(
                allocator,
                scopes[0..@min(options.top, scopes.len)],
            );
            ranking.sources = try snapshotSources(
                allocator,
                sites[0..@min(options.top, sites.len)],
                if (maybe_symbols) |*symbols| symbols else null,
            );
        }
        if (maybe_symbols) |*symbols| {
            result.symbol_storage = symbols.stdout;
            symbols.ranges.deinit(allocator);
            symbols.frames.deinit(allocator);
            symbols.* = undefined;
            maybe_symbols = null;
        }
        return result;
    }

    pub fn writeSummary(self: *Analyzer, writer: *std.Io.Writer, options: SummaryOptions) !void {
        if (options.layer != self.layer_filter) {
            return error.LayerSelectionMismatch;
        }
        var summaries = try self.collectScopeSummaries(options);
        defer summaries.deinit(self.allocator);

        try writeCaptureIntegrityText(writer, self.captureIntegrity());
        if (options.layer == .logical) {
            try writer.print(
                "memtrace layer={s} sort={s} events={d} allocations={d} " ++
                    "frees={d} " ++
                    "open_requests={d} requested_bytes={d} " ++
                    "explicitly_closed_bytes={d} open_request_bytes={d} " ++
                    "high_water_open_request_bytes={d} " ++
                    "bulk_invalidated_requests={d} bulk_invalidated_bytes={d} " ++
                    "untracked_requests={d} untracked_request_bytes={d}\n",
                .{
                    options.layer.tag(),
                    options.sort.name(),
                    self.events,
                    self.counters.allocations,
                    self.counters.frees,
                    self.counters.live_allocations,
                    self.counters.allocated_bytes,
                    self.counters.freed_bytes,
                    self.counters.live_bytes,
                    self.counters.high_water_live_bytes,
                    self.counters.bulk_invalidated_requests,
                    self.counters.bulk_invalidated_bytes,
                    self.counters.untracked_requests,
                    self.counters.untracked_request_bytes,
                },
            );
            const coverage = self.lifecycleCoverage();
            try writer.print(
                "memtrace lifecycle_coverage={s} instrumented_producers={d} " ++
                    "uninstrumented_producers={d} " ++
                    "lifecycle_not_required_producers={d} " ++
                    "prefix_complete_producers={d} prefix_partial_producers={d} " ++
                    "lifecycle_events={d}\n",
                .{
                    coverage.status(),
                    coverage.instrumented,
                    coverage.uninstrumented,
                    coverage.not_required,
                    coverage.prefix_complete,
                    coverage.prefix_partial,
                    self.counters.lifecycle_events,
                },
            );
        } else {
            try writer.print(
                "memtrace layer={s} sort={s} events={d} allocations={d} " ++
                    "frees={d} live_allocations={d} allocated_bytes={d} " ++
                    "freed_bytes={d} live_bytes={d} " ++
                    "high_water_live_bytes={d}\n",
                .{
                    options.layer.tag(),
                    options.sort.name(),
                    self.events,
                    self.counters.allocations,
                    self.counters.frees,
                    self.counters.live_allocations,
                    self.counters.allocated_bytes,
                    self.counters.freed_bytes,
                    self.counters.live_bytes,
                    self.counters.high_water_live_bytes,
                },
            );
            try writer.print(
                "memtrace retained_bytes={d} high_water_retained_bytes={d}\n",
                .{
                    self.counters.retained_bytes,
                    self.counters.high_water_retained_bytes,
                },
            );
        }
        try writer.print(
            "memtrace lifetimes completed={d} total_events={d} mean_events={d} " ++
                "max_events={d} total_byte_events={d} " ++
                "mean_byte_events={d} max_byte_events={d}\n",
            .{
                self.counters.completed_lifetimes,
                self.counters.lifetime_total_events,
                meanLifetimeEvents(self.counters),
                self.counters.lifetime_max_events,
                self.counters.lifetime_total_byte_events,
                meanLifetimeByteEvents(self.counters),
                self.counters.lifetime_max_byte_events,
            },
        );
        if (self.counters.failed_allocations != 0 or
            self.counters.failed_resizes != 0 or
            self.counters.failed_remaps != 0 or
            self.counters.unmatched_frees != 0 or
            self.counters.unmatched_resizes != 0 or
            self.counters.unmatched_remaps != 0)
        {
            try writer.print(
                "memtrace anomalies failed_allocations={d} failed_resizes={d} " ++
                    "failed_remaps={d} unmatched_frees={d} unmatched_resizes={d} " ++
                    "unmatched_remaps={d}\n",
                .{
                    self.counters.failed_allocations,
                    self.counters.failed_resizes,
                    self.counters.failed_remaps,
                    self.counters.unmatched_frees,
                    self.counters.unmatched_resizes,
                    self.counters.unmatched_remaps,
                },
            );
        }
        if (options.layer.includes(.physical_page)) {
            try self.writePhysicalSummary(writer);
        }
        const limit = @min(options.top, summaries.items.len);
        for (summaries.items[0..limit]) |summary| {
            if (options.layer == .logical) {
                try writer.print(
                    "{s} open_request_bytes={d} " ++
                        "high_water_open_request_bytes={d} requested_bytes={d} " ++
                        "explicitly_closed_bytes={d} allocations={d} frees={d} " ++
                        "open_requests={d} bulk_invalidated_requests={d} " ++
                        "bulk_invalidated_bytes={d} untracked_requests={d} " ++
                        "untracked_request_bytes={d}\n",
                    .{
                        summary.path,
                        summary.counters.live_bytes,
                        summary.counters.high_water_live_bytes,
                        summary.counters.allocated_bytes,
                        summary.counters.freed_bytes,
                        summary.counters.allocations,
                        summary.counters.frees,
                        summary.counters.live_allocations,
                        summary.counters.bulk_invalidated_requests,
                        summary.counters.bulk_invalidated_bytes,
                        summary.counters.untracked_requests,
                        summary.counters.untracked_request_bytes,
                    },
                );
            } else {
                try writer.print(
                    "{s} retained_bytes={d} high_water_retained_bytes={d} " ++
                        "live_bytes={d} high_water_live_bytes={d} " ++
                        "allocated_bytes={d} freed_bytes={d} allocations={d} " ++
                        "frees={d} live_allocations={d} completed_lifetimes={d} " ++
                        "lifetime_total_events={d} lifetime_mean_events={d} " ++
                        "lifetime_max_events={d} " ++
                        "lifetime_total_byte_events={d} " ++
                        "lifetime_mean_byte_events={d} " ++
                        "lifetime_max_byte_events={d}\n",
                    .{
                        summary.path,
                        summary.counters.retained_bytes,
                        summary.counters.high_water_retained_bytes,
                        summary.counters.live_bytes,
                        summary.counters.high_water_live_bytes,
                        summary.counters.allocated_bytes,
                        summary.counters.freed_bytes,
                        summary.counters.allocations,
                        summary.counters.frees,
                        summary.counters.live_allocations,
                        summary.counters.completed_lifetimes,
                        summary.counters.lifetime_total_events,
                        meanLifetimeEvents(summary.counters),
                        summary.counters.lifetime_max_events,
                        summary.counters.lifetime_total_byte_events,
                        meanLifetimeByteEvents(summary.counters),
                        summary.counters.lifetime_max_byte_events,
                    },
                );
            }
        }
        if (options.include_sites) try self.writeSiteSummary(writer, options);
        if (options.site_detail_return_address) |return_address| try self.writeSiteDetailSummary(writer, options, return_address);
    }

    pub fn writeSummaryJsonl(self: *Analyzer, writer: *std.Io.Writer, options: SummaryOptions) !void {
        if (options.layer != self.layer_filter) {
            return error.LayerSelectionMismatch;
        }
        var summaries = try self.collectScopeSummaries(options);
        defer summaries.deinit(self.allocator);

        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("kind", "summary");
        try object.field("layer", options.layer.tag());
        try object.field("sort", options.sort.name());
        try object.field("events", self.events);
        try object.field("allocations", self.counters.allocations);
        try object.field("frees", self.counters.frees);
        try object.field("resizes", self.counters.resizes);
        try object.field("remaps", self.counters.remaps);
        try object.field("allocated_bytes", self.counters.allocated_bytes);
        if (options.layer == .logical) {
            try object.field("open_requests", self.counters.live_allocations);
            try object.field("requested_bytes", self.counters.allocated_bytes);
            try object.field(
                "explicitly_closed_bytes",
                self.counters.freed_bytes,
            );
            try object.field("open_request_bytes", self.counters.live_bytes);
            try object.field(
                "high_water_open_request_bytes",
                self.counters.high_water_live_bytes,
            );
            try object.field(
                "bulk_invalidated_requests",
                self.counters.bulk_invalidated_requests,
            );
            try object.field(
                "bulk_invalidated_bytes",
                self.counters.bulk_invalidated_bytes,
            );
            try object.field(
                "untracked_requests",
                self.counters.untracked_requests,
            );
            try object.field(
                "untracked_request_bytes",
                self.counters.untracked_request_bytes,
            );
            try object.field(
                "lifecycle_events",
                self.counters.lifecycle_events,
            );
            const coverage = self.lifecycleCoverage();
            try object.field("lifecycle_coverage", coverage.status());
            try object.field(
                "lifecycle_instrumented_producers",
                coverage.instrumented,
            );
            try object.field(
                "lifecycle_uninstrumented_producers",
                coverage.uninstrumented,
            );
            try object.field(
                "lifecycle_not_required_producers",
                coverage.not_required,
            );
            try object.field(
                "prefix_complete_producers",
                coverage.prefix_complete,
            );
            try object.field(
                "prefix_partial_producers",
                coverage.prefix_partial,
            );
        } else {
            try object.field("live_allocations", self.counters.live_allocations);
            try object.field("freed_bytes", self.counters.freed_bytes);
            try object.field("live_bytes", self.counters.live_bytes);
            try object.field(
                "high_water_live_bytes",
                self.counters.high_water_live_bytes,
            );
            try object.field("retained_bytes", self.counters.retained_bytes);
            try object.field(
                "high_water_retained_bytes",
                self.counters.high_water_retained_bytes,
            );
        }
        try object.field("completed_lifetimes", self.counters.completed_lifetimes);
        try object.field("lifetime_total_events", self.counters.lifetime_total_events);
        try object.field("lifetime_mean_events", meanLifetimeEvents(self.counters));
        try object.field("lifetime_max_events", self.counters.lifetime_max_events);
        try object.field(
            "lifetime_total_byte_events",
            self.counters.lifetime_total_byte_events,
        );
        try object.field(
            "lifetime_mean_byte_events",
            meanLifetimeByteEvents(self.counters),
        );
        try object.field(
            "lifetime_max_byte_events",
            self.counters.lifetime_max_byte_events,
        );
        try object.field("failed_allocations", self.counters.failed_allocations);
        try object.field("failed_resizes", self.counters.failed_resizes);
        try object.field("failed_remaps", self.counters.failed_remaps);
        try object.field("unmatched_frees", self.counters.unmatched_frees);
        try object.field("unmatched_resizes", self.counters.unmatched_resizes);
        try object.field("unmatched_remaps", self.counters.unmatched_remaps);
        if (options.layer.includes(.physical_page)) {
            try self.writePhysicalSummaryJson(object);
        }
        try writeCaptureIntegrityJson(object, self.captureIntegrity());
        try object.endLine();
        const limit = @min(options.top, summaries.items.len);
        for (summaries.items[0..limit]) |summary| {
            var row_stream = pretty_json.Writer.init(writer, .minified);
            const row = try row_stream.object();
            try row.field("kind", "scope");
            try row.field("sort", options.sort.name());
            try row.field("scope", summary.path);
            try writeCounterFields(
                row,
                summary.counters,
                options.layer == .logical,
            );
            try row.endLine();
        }
        if (options.include_sites) try self.writeSiteSummaryJsonl(writer, options);
        if (options.site_detail_return_address) |return_address| try self.writeSiteDetailSummaryJsonl(writer, options, return_address);
    }

    fn writePhysicalSummary(
        self: *const Analyzer,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print(
            "memtrace physical maps={d} unmaps={d} protects={d} discards={d} " ++
                "decommits={d} advises={d} mapped_bytes={d} unmapped_bytes={d} " ++
                "displaced_bytes={d} untracked_unmap_bytes={d} " ++
                "live_mapped_bytes={d} high_water_mapped_bytes={d} " ++
                "live_ranges={d}\n",
            .{
                self.physical.maps,
                self.physical.unmaps,
                self.physical.protects,
                self.physical.discards,
                self.physical.decommits,
                self.physical.advises,
                self.physical.mapped_bytes,
                self.physical.unmapped_bytes,
                self.physical.displaced_bytes,
                self.physical.untracked_unmap_bytes,
                self.physical.live_mapped_bytes,
                self.physical.high_water_mapped_bytes,
                self.mappings.count(),
            },
        );
        if (self.physical.failed_maps != 0 or
            self.physical.failed_unmaps != 0 or
            self.physical.failed_protects != 0 or
            self.physical.failed_discards != 0 or
            self.physical.failed_decommits != 0 or
            self.physical.failed_advises != 0)
        {
            try writer.print(
                "memtrace physical_failures maps={d} unmaps={d} protects={d} " ++
                    "discards={d} decommits={d} advises={d}\n",
                .{
                    self.physical.failed_maps,
                    self.physical.failed_unmaps,
                    self.physical.failed_protects,
                    self.physical.failed_discards,
                    self.physical.failed_decommits,
                    self.physical.failed_advises,
                },
            );
        }
    }

    fn writePhysicalSummaryJson(
        self: *const Analyzer,
        object: pretty_json.Object,
    ) !void {
        const physical = try object.object("physical");
        try physical.field("maps", self.physical.maps);
        try physical.field("unmaps", self.physical.unmaps);
        try physical.field("protects", self.physical.protects);
        try physical.field("discards", self.physical.discards);
        try physical.field("decommits", self.physical.decommits);
        try physical.field("advises", self.physical.advises);
        try physical.field("failed_maps", self.physical.failed_maps);
        try physical.field("failed_unmaps", self.physical.failed_unmaps);
        try physical.field("failed_protects", self.physical.failed_protects);
        try physical.field("failed_discards", self.physical.failed_discards);
        try physical.field("failed_decommits", self.physical.failed_decommits);
        try physical.field("failed_advises", self.physical.failed_advises);
        try physical.field("mapped_bytes", self.physical.mapped_bytes);
        try physical.field("unmapped_bytes", self.physical.unmapped_bytes);
        try physical.field("displaced_bytes", self.physical.displaced_bytes);
        try physical.field("untracked_unmap_bytes", self.physical.untracked_unmap_bytes);
        try physical.field("live_mapped_bytes", self.physical.live_mapped_bytes);
        try physical.field("high_water_mapped_bytes", self.physical.high_water_mapped_bytes);
        try physical.field("live_ranges", self.mappings.count());
        try physical.end();
    }

    fn collectScopeSummaries(
        self: *Analyzer,
        options: SummaryOptions,
    ) !std.ArrayListUnmanaged(ScopeSummary) {
        var summaries = std.ArrayListUnmanaged(ScopeSummary).empty;
        errdefer summaries.deinit(self.allocator);
        var iterator = self.scopes.iterator();
        while (iterator.next()) |entry| {
            const counters = entry.value_ptr.*;
            const invisible = !options.include_zero_live and counters.live_bytes == 0 and
                counters.high_water_live_bytes == 0 and counters.retained_bytes == 0;
            if (invisible) continue;
            const below_floor = counters.live_bytes < options.min_bytes and
                counters.high_water_live_bytes < options.min_bytes and
                counters.retained_bytes < options.min_bytes;
            if (below_floor) continue;
            try summaries.append(self.allocator, .{
                .path = entry.key_ptr.*,
                .counters = counters,
            });
        }
        std.mem.sort(
            ScopeSummary,
            summaries.items,
            options.sort,
            scopeSummaryGreaterThan,
        );
        return summaries;
    }

    fn recordAllocator(
        self: *Analyzer,
        allocator_id: u32,
        retains_freed_memory: bool,
        layer: event_mod.Layer,
        lifecycle_instrumented: bool,
        prefix_complete: bool,
    ) !void {
        try self.allocators.put(self.allocator, allocator_id, .{
            .retention = if (retains_freed_memory) .retains_freed_memory else .releases_freed_memory,
            .layer = layer,
            .lifecycle_instrumented = lifecycle_instrumented,
            .prefix_complete = prefix_complete,
        });
    }

    fn recordAllocation(self: *Analyzer, allocator_id: u32, key: u64, scope: []const u8, return_address: u64, len: usize) !void {
        const owned_scope = try self.internScope(scope);
        try self.allocations.put(self.allocator, key, .{
            .allocator_id = allocator_id,
            .len = len,
            .scope = owned_scope,
            .return_address = return_address,
            .allocation_event = self.events,
            .segment_event = self.events,
            .byte_events = 0,
        });
        self.applyAllocation(allocator_id, owned_scope, len);
        if (self.track_sites) {
            try self.applySiteAllocation(
                allocator_id,
                return_address,
                len,
            );
        }
        if (self.site_detail_return_address == return_address) {
            try self.applySiteDetailAllocation(
                allocator_id,
                owned_scope,
                len,
            );
        }
    }

    fn recordUntrackedAllocation(
        self: *Analyzer,
        scope: []const u8,
        return_address: u64,
        len: usize,
    ) !void {
        const owned_scope = try self.internScope(scope);
        self.counters.allocations +|= 1;
        self.counters.allocated_bytes +|= len;
        self.counters.untracked_requests +|= 1;
        self.counters.untracked_request_bytes +|= len;
        const scope_counters = self.scopes.getPtr(owned_scope).?;
        scope_counters.allocations +|= 1;
        scope_counters.allocated_bytes +|= len;
        scope_counters.untracked_requests +|= 1;
        scope_counters.untracked_request_bytes +|= len;
        if (self.track_sites) {
            const site = try self.siteCounters(return_address);
            site.allocations +|= 1;
            site.allocated_bytes +|= len;
            site.untracked_requests +|= 1;
            site.untracked_request_bytes +|= len;
        }
    }

    fn recordFree(self: *Analyzer, key: u64, allocator_id: u32, scope: []const u8, len: usize) !void {
        if (self.allocations.fetchRemove(key)) |removed| {
            self.clearDrainedAllocations();
            self.applyLifetime(
                removed.value.scope,
                removed.value.return_address,
                removed.value.len,
                completedLifetimeEvents(removed.value.allocation_event, self.events),
                removed.value.byte_events +|
                    completedLifetimeByteEvents(
                        removed.value.len,
                        removed.value.segment_event,
                        self.events,
                    ),
            );
            self.applyFree(removed.value.allocator_id, removed.value.scope, removed.value.len);
            if (self.track_sites) self.applySiteFree(removed.value.allocator_id, removed.value.return_address, removed.value.len);
            if (self.site_detail_return_address == removed.value.return_address) self.applySiteDetailFree(removed.value.allocator_id, removed.value.scope, removed.value.len);
            return;
        }
        self.counters.unmatched_frees += 1;
        const owned_scope = try self.internScope(scope);
        self.applyFree(allocator_id, owned_scope, len);
    }

    fn recordRelease(self: *Analyzer, key: u64) !void {
        const removed = self.allocations.fetchRemove(key) orelse {
            self.counters.unmatched_frees +|= 1;
            return;
        };
        self.clearDrainedAllocations();
        self.applyLifetime(
            removed.value.scope,
            removed.value.return_address,
            removed.value.len,
            completedLifetimeEvents(
                removed.value.allocation_event,
                self.events,
            ),
            removed.value.byte_events +|
                completedLifetimeByteEvents(
                    removed.value.len,
                    removed.value.segment_event,
                    self.events,
                ),
        );
        self.applyBulkInvalidation(
            removed.value.allocator_id,
            removed.value.scope,
            removed.value.len,
        );
        if (self.track_sites) {
            self.applySiteBulkInvalidation(
                removed.value.return_address,
                removed.value.len,
            );
        }
        if (self.site_detail_return_address == removed.value.return_address) {
            self.applySiteDetailBulkInvalidation(
                removed.value.scope,
                removed.value.len,
            );
        }
    }

    fn recordResize(self: *Analyzer, key: u64, allocator_id: u32, scope: []const u8, old_len: usize, new_len: usize) !void {
        self.counters.resizes += 1;
        try self.resizeAllocation(
            key,
            allocator_id,
            scope,
            old_len,
            new_len,
            false,
        );
    }

    fn resizeAllocation(
        self: *Analyzer,
        key: u64,
        allocator_id: u32,
        scope: []const u8,
        old_len: usize,
        new_len: usize,
        is_remap: bool,
    ) !void {
        if (self.allocations.getPtr(key)) |record| {
            accrueLifetimeByteEvents(record, self.events);
            self.applyResize(record.allocator_id, record.scope, record.len, new_len);
            if (self.track_sites) self.applySiteResize(record.allocator_id, record.return_address, record.len, new_len);
            if (self.site_detail_return_address == record.return_address) try self.applySiteDetailResize(record.allocator_id, record.scope, record.len, new_len);
            record.len = new_len;
            return;
        }
        _ = allocator_id;
        _ = scope;
        _ = old_len;
        if (is_remap) {
            self.counters.unmatched_remaps += 1;
        } else {
            self.counters.unmatched_resizes += 1;
        }
    }

    fn recordRemap(self: *Analyzer, old_key: u64, new_key: u64, allocator_id: u32, scope: []const u8, old_len: usize, new_len: usize) !void {
        self.counters.remaps += 1;
        if (old_key == new_key) {
            try self.resizeAllocation(
                old_key,
                allocator_id,
                scope,
                old_len,
                new_len,
                true,
            );
            return;
        }
        if (self.allocations.fetchRemove(old_key)) |removed| {
            var record = removed.value;
            self.clearDrainedAllocations();
            accrueLifetimeByteEvents(&record, self.events);
            self.applyResize(record.allocator_id, record.scope, record.len, new_len);
            if (self.track_sites) self.applySiteResize(record.allocator_id, record.return_address, record.len, new_len);
            if (self.site_detail_return_address == record.return_address) try self.applySiteDetailResize(record.allocator_id, record.scope, record.len, new_len);
            record.len = new_len;
            try self.allocations.put(self.allocator, new_key, record);
            return;
        }
        self.counters.unmatched_remaps += 1;
    }

    fn recordLostTrackingRemap(
        self: *Analyzer,
        key: u64,
        new_len: usize,
    ) !void {
        const removed = self.allocations.fetchRemove(key) orelse {
            self.counters.unmatched_remaps +|= 1;
            return;
        };
        self.clearDrainedAllocations();
        const record = removed.value;
        self.counters.resizes +|= 1;
        self.applyResize(
            record.allocator_id,
            record.scope,
            record.len,
            new_len,
        );
        self.applyLostTracking(record.scope, new_len);
        if (self.track_sites) {
            self.applySiteResize(
                record.allocator_id,
                record.return_address,
                record.len,
                new_len,
            );
            self.applySiteLostTracking(record.return_address, new_len);
        }
        if (self.site_detail_return_address == record.return_address) {
            try self.applySiteDetailResize(
                record.allocator_id,
                record.scope,
                record.len,
                new_len,
            );
            self.applySiteDetailLostTracking(record.scope, new_len);
        }
    }

    fn applyAllocation(self: *Analyzer, allocator_id: u32, scope: []const u8, len: usize) void {
        self.counters.allocations += 1;
        self.counters.live_allocations += 1;
        self.counters.allocated_bytes += len;
        self.counters.live_bytes += len;
        self.counters.high_water_live_bytes = @max(self.counters.high_water_live_bytes, self.counters.live_bytes);
        const tracks_retained = self.allocatorLayer(allocator_id) !=
            .logical_allocator;
        if (tracks_retained) {
            self.counters.retained_bytes += len;
            self.counters.high_water_retained_bytes = @max(
                self.counters.high_water_retained_bytes,
                self.counters.retained_bytes,
            );
        }

        const counters = self.scopes.getPtr(scope) orelse return;
        counters.allocations += 1;
        counters.live_allocations += 1;
        counters.allocated_bytes += len;
        counters.live_bytes += len;
        counters.high_water_live_bytes = @max(counters.high_water_live_bytes, counters.live_bytes);
        if (tracks_retained) {
            counters.retained_bytes += len;
            counters.high_water_retained_bytes = @max(
                counters.high_water_retained_bytes,
                counters.retained_bytes,
            );
        }
    }

    fn applyFree(self: *Analyzer, allocator_id: u32, scope: []const u8, len: usize) void {
        self.counters.frees += 1;
        if (self.counters.live_allocations > 0) self.counters.live_allocations -= 1;
        self.counters.freed_bytes += len;
        if (self.counters.live_bytes >= len) self.counters.live_bytes -= len else self.counters.live_bytes = 0;
        const releases = self.allocatorReleases(allocator_id);
        if (releases and self.counters.retained_bytes >= len) self.counters.retained_bytes -= len;

        const counters = self.scopes.getPtr(scope) orelse return;
        counters.frees += 1;
        if (counters.live_allocations > 0) counters.live_allocations -= 1;
        counters.freed_bytes += len;
        if (counters.live_bytes >= len) counters.live_bytes -= len else counters.live_bytes = 0;
        if (releases and counters.retained_bytes >= len) counters.retained_bytes -= len;
    }

    fn applyBulkInvalidation(
        self: *Analyzer,
        allocator_id: u32,
        scope: []const u8,
        len: usize,
    ) void {
        _ = allocator_id;
        self.counters.bulk_invalidated_requests +|= 1;
        self.counters.bulk_invalidated_bytes +|= len;
        if (self.counters.live_allocations > 0) {
            self.counters.live_allocations -= 1;
        }
        if (self.counters.live_bytes >= len) {
            self.counters.live_bytes -= len;
        } else {
            self.counters.live_bytes = 0;
        }
        const counters = self.scopes.getPtr(scope) orelse return;
        counters.bulk_invalidated_requests +|= 1;
        counters.bulk_invalidated_bytes +|= len;
        if (counters.live_allocations > 0) counters.live_allocations -= 1;
        if (counters.live_bytes >= len) {
            counters.live_bytes -= len;
        } else {
            counters.live_bytes = 0;
        }
    }

    fn applyLostTracking(
        self: *Analyzer,
        scope: []const u8,
        len: usize,
    ) void {
        applyCountersLostTracking(&self.counters, len);
        if (self.scopes.getPtr(scope)) |counters| {
            applyCountersLostTracking(counters, len);
        }
    }

    fn applyLifetime(
        self: *Analyzer,
        scope: []const u8,
        return_address: u64,
        len: usize,
        lifetime_events: u64,
        lifetime_byte_events: u64,
    ) void {
        applyCompletedLifetime(
            &self.counters,
            lifetime_events,
            lifetime_byte_events,
        );
        if (self.scopes.getPtr(scope)) |counters| {
            applyCompletedLifetime(
                counters,
                lifetime_events,
                lifetime_byte_events,
            );
        }
        if (self.track_sites) {
            if (self.sites.getPtr(return_address)) |counters| {
                applyCompletedLifetime(
                    counters,
                    lifetime_events,
                    lifetime_byte_events,
                );
            }
        }
        if (self.site_detail_return_address == return_address) {
            if (self.site_detail_sizes.getPtr(len)) |counters| {
                applyCompletedLifetime(
                    counters,
                    lifetime_events,
                    lifetime_byte_events,
                );
            }
            if (self.site_detail_scopes.getPtr(scope)) |counters| {
                applyCompletedLifetime(
                    counters,
                    lifetime_events,
                    lifetime_byte_events,
                );
            }
        }
    }

    fn applyResize(self: *Analyzer, allocator_id: u32, scope: []const u8, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            const delta = new_len - old_len;
            self.counters.allocated_bytes += delta;
            self.counters.live_bytes += delta;
            self.counters.high_water_live_bytes = @max(self.counters.high_water_live_bytes, self.counters.live_bytes);
            const tracks_retained = self.allocatorLayer(allocator_id) !=
                .logical_allocator;
            if (tracks_retained) {
                self.counters.retained_bytes += delta;
                self.counters.high_water_retained_bytes = @max(
                    self.counters.high_water_retained_bytes,
                    self.counters.retained_bytes,
                );
            }
            if (self.scopes.getPtr(scope)) |counters| {
                counters.allocated_bytes += delta;
                counters.live_bytes += delta;
                counters.high_water_live_bytes = @max(counters.high_water_live_bytes, counters.live_bytes);
                if (tracks_retained) {
                    counters.retained_bytes += delta;
                    counters.high_water_retained_bytes = @max(
                        counters.high_water_retained_bytes,
                        counters.retained_bytes,
                    );
                }
            }
        } else {
            const delta = old_len - new_len;
            self.counters.freed_bytes += delta;
            if (self.counters.live_bytes >= delta) self.counters.live_bytes -= delta else self.counters.live_bytes = 0;
            const releases = self.allocatorReleases(allocator_id);
            if (releases and self.counters.retained_bytes >= delta) self.counters.retained_bytes -= delta;
            if (self.scopes.getPtr(scope)) |counters| {
                counters.freed_bytes += delta;
                if (counters.live_bytes >= delta) counters.live_bytes -= delta else counters.live_bytes = 0;
                if (releases and counters.retained_bytes >= delta) counters.retained_bytes -= delta;
            }
        }
    }

    fn applySiteAllocation(
        self: *Analyzer,
        allocator_id: u32,
        return_address: u64,
        len: usize,
    ) !void {
        const counters = try self.siteCounters(return_address);
        counters.allocations += 1;
        counters.live_allocations += 1;
        counters.allocated_bytes += len;
        counters.live_bytes += len;
        counters.high_water_live_bytes = @max(counters.high_water_live_bytes, counters.live_bytes);
        if (self.allocatorLayer(allocator_id) != .logical_allocator) {
            counters.retained_bytes += len;
            counters.high_water_retained_bytes = @max(
                counters.high_water_retained_bytes,
                counters.retained_bytes,
            );
        }
    }

    fn applySiteFree(self: *Analyzer, allocator_id: u32, return_address: u64, len: usize) void {
        const counters = self.sites.getPtr(return_address) orelse return;
        counters.frees += 1;
        if (counters.live_allocations > 0) counters.live_allocations -= 1;
        counters.freed_bytes += len;
        if (counters.live_bytes >= len) counters.live_bytes -= len else counters.live_bytes = 0;
        if (self.allocatorReleases(allocator_id) and counters.retained_bytes >= len) counters.retained_bytes -= len;
    }

    fn applySiteBulkInvalidation(
        self: *Analyzer,
        return_address: u64,
        len: usize,
    ) void {
        const counters = self.sites.getPtr(return_address) orelse return;
        counters.bulk_invalidated_requests +|= 1;
        counters.bulk_invalidated_bytes +|= len;
        if (counters.live_allocations > 0) counters.live_allocations -= 1;
        if (counters.live_bytes >= len) {
            counters.live_bytes -= len;
        } else {
            counters.live_bytes = 0;
        }
    }

    fn applySiteLostTracking(
        self: *Analyzer,
        return_address: u64,
        len: usize,
    ) void {
        const counters = self.sites.getPtr(return_address) orelse return;
        applyCountersLostTracking(counters, len);
    }

    fn applySiteResize(self: *Analyzer, allocator_id: u32, return_address: u64, old_len: usize, new_len: usize) void {
        const counters = self.sites.getPtr(return_address) orelse return;
        if (new_len >= old_len) {
            const delta = new_len - old_len;
            counters.allocated_bytes += delta;
            counters.live_bytes += delta;
            counters.high_water_live_bytes = @max(counters.high_water_live_bytes, counters.live_bytes);
            counters.retained_bytes += delta;
            counters.high_water_retained_bytes = @max(counters.high_water_retained_bytes, counters.retained_bytes);
        } else {
            const delta = old_len - new_len;
            counters.freed_bytes += delta;
            if (counters.live_bytes >= delta) counters.live_bytes -= delta else counters.live_bytes = 0;
            if (self.allocatorReleases(allocator_id) and counters.retained_bytes >= delta) counters.retained_bytes -= delta;
        }
    }

    fn siteCounters(self: *Analyzer, return_address: u64) !*SiteCounters {
        const entry = try self.sites.getOrPut(self.allocator, return_address);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        return entry.value_ptr;
    }

    fn applySiteDetailAllocation(
        self: *Analyzer,
        allocator_id: u32,
        scope: []const u8,
        len: usize,
    ) !void {
        const tracks_retained = self.allocatorLayer(allocator_id) !=
            .logical_allocator;
        applyDetailAllocation(
            try self.siteDetailSizeCounters(len),
            len,
            tracks_retained,
        );
        applyDetailAllocation(
            try self.siteDetailScopeCounters(scope),
            len,
            tracks_retained,
        );
    }

    fn applySiteDetailFree(self: *Analyzer, allocator_id: u32, scope: []const u8, len: usize) void {
        const releases = self.allocatorReleases(allocator_id);
        if (self.site_detail_sizes.getPtr(len)) |counters| applyDetailFree(counters, len, releases);
        if (self.site_detail_scopes.getPtr(scope)) |counters| applyDetailFree(counters, len, releases);
    }

    fn applySiteDetailResize(self: *Analyzer, allocator_id: u32, scope: []const u8, old_len: usize, new_len: usize) !void {
        if (old_len == new_len) return;
        self.applySiteDetailFree(allocator_id, scope, old_len);
        try self.applySiteDetailAllocation(allocator_id, scope, new_len);
    }

    fn applySiteDetailBulkInvalidation(
        self: *Analyzer,
        scope: []const u8,
        len: usize,
    ) void {
        if (self.site_detail_sizes.getPtr(len)) |counters| {
            applyDetailBulkInvalidation(counters, len);
        }
        if (self.site_detail_scopes.getPtr(scope)) |counters| {
            applyDetailBulkInvalidation(counters, len);
        }
    }

    fn applySiteDetailLostTracking(
        self: *Analyzer,
        scope: []const u8,
        len: usize,
    ) void {
        if (self.site_detail_sizes.getPtr(len)) |counters| {
            applyCountersLostTracking(counters, len);
        }
        if (self.site_detail_scopes.getPtr(scope)) |counters| {
            applyCountersLostTracking(counters, len);
        }
    }

    fn siteDetailSizeCounters(self: *Analyzer, len: usize) !*SiteCounters {
        const entry = try self.site_detail_sizes.getOrPut(self.allocator, len);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        return entry.value_ptr;
    }

    fn siteDetailScopeCounters(self: *Analyzer, scope: []const u8) !*SiteCounters {
        const entry = try self.site_detail_scopes.getOrPut(self.allocator, scope);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        return entry.value_ptr;
    }

    fn applyDetailAllocation(
        counters: *SiteCounters,
        len: usize,
        tracks_retained: bool,
    ) void {
        counters.allocations += 1;
        counters.live_allocations += 1;
        counters.allocated_bytes += len;
        counters.live_bytes += len;
        counters.high_water_live_bytes = @max(counters.high_water_live_bytes, counters.live_bytes);
        if (tracks_retained) {
            counters.retained_bytes += len;
            counters.high_water_retained_bytes = @max(
                counters.high_water_retained_bytes,
                counters.retained_bytes,
            );
        }
    }

    fn applyDetailFree(counters: *SiteCounters, len: usize, releases: bool) void {
        counters.frees += 1;
        if (counters.live_allocations > 0) counters.live_allocations -= 1;
        counters.freed_bytes += len;
        if (counters.live_bytes >= len) counters.live_bytes -= len else counters.live_bytes = 0;
        if (releases and counters.retained_bytes >= len) counters.retained_bytes -= len;
    }

    fn applyDetailBulkInvalidation(
        counters: *SiteCounters,
        len: usize,
    ) void {
        counters.bulk_invalidated_requests +|= 1;
        counters.bulk_invalidated_bytes +|= len;
        if (counters.live_allocations > 0) counters.live_allocations -= 1;
        if (counters.live_bytes >= len) {
            counters.live_bytes -= len;
        } else {
            counters.live_bytes = 0;
        }
    }

    fn writeSiteSummary(self: *Analyzer, writer: *std.Io.Writer, options: SummaryOptions) !void {
        var summaries = try self.collectSiteSummaries(options);
        defer summaries.deinit(self.allocator);
        const limit = @min(options.top, summaries.items.len);
        var maybe_symbols = if (options.site_symbol_binary) |binary|
            try resolveSiteSummarySymbolsAlloc(
                self.allocator,
                binary,
                summaries.items[0..limit],
            )
        else
            null;
        defer if (maybe_symbols) |*symbols| symbols.deinit(self.allocator);
        for (summaries.items[0..limit]) |summary| {
            const symbol = symbol: {
                const symbols = if (maybe_symbols) |*value|
                    value
                else
                    break :symbol null;
                const frames = symbols.find(summary.return_address);
                break :symbol if (frames.len == 0) null else frames[0];
            };
            try writer.print(
                "site return_address=0x{x}",
                .{summary.return_address},
            );
            if (symbol) |resolved| {
                try writer.writeAll(" symbol=");
                var symbol_stream = pretty_json.Writer.init(writer, .minified);
                try symbol_stream.write(resolved.function);
                try writer.writeAll(" location=");
                var location_stream = pretty_json.Writer.init(writer, .minified);
                try location_stream.write(resolved.location);
            }
            try writer.print(
                " retained_bytes={d} high_water_retained_bytes={d} live_bytes={d} high_water_live_bytes={d} allocated_bytes={d} freed_bytes={d} allocations={d} frees={d} live_allocations={d} completed_lifetimes={d} lifetime_total_events={d} lifetime_mean_events={d} lifetime_max_events={d} lifetime_total_byte_events={d} lifetime_mean_byte_events={d} lifetime_max_byte_events={d}\n",
                .{
                    summary.counters.retained_bytes,
                    summary.counters.high_water_retained_bytes,
                    summary.counters.live_bytes,
                    summary.counters.high_water_live_bytes,
                    summary.counters.allocated_bytes,
                    summary.counters.freed_bytes,
                    summary.counters.allocations,
                    summary.counters.frees,
                    summary.counters.live_allocations,
                    summary.counters.completed_lifetimes,
                    summary.counters.lifetime_total_events,
                    meanLifetimeEvents(summary.counters),
                    summary.counters.lifetime_max_events,
                    summary.counters.lifetime_total_byte_events,
                    meanLifetimeByteEvents(summary.counters),
                    summary.counters.lifetime_max_byte_events,
                },
            );
        }
    }

    fn writeSiteDetailSummary(self: *Analyzer, writer: *std.Io.Writer, options: SummaryOptions, return_address: u64) !void {
        try writer.print("site_detail return_address=0x{x}\n", .{return_address});

        var sizes = try self.collectSiteSizeSummaries(options.sort);
        defer sizes.deinit(self.allocator);
        const size_limit = @min(options.top, sizes.items.len);
        for (sizes.items[0..size_limit]) |summary| {
            try writer.print(
                "site_size len={d} retained_bytes={d} high_water_retained_bytes={d} live_bytes={d} high_water_live_bytes={d} allocated_bytes={d} freed_bytes={d} allocations={d} frees={d} live_allocations={d} completed_lifetimes={d} lifetime_total_events={d} lifetime_mean_events={d} lifetime_max_events={d} lifetime_total_byte_events={d} lifetime_mean_byte_events={d} lifetime_max_byte_events={d}\n",
                .{
                    summary.len,
                    summary.counters.retained_bytes,
                    summary.counters.high_water_retained_bytes,
                    summary.counters.live_bytes,
                    summary.counters.high_water_live_bytes,
                    summary.counters.allocated_bytes,
                    summary.counters.freed_bytes,
                    summary.counters.allocations,
                    summary.counters.frees,
                    summary.counters.live_allocations,
                    summary.counters.completed_lifetimes,
                    summary.counters.lifetime_total_events,
                    meanLifetimeEvents(summary.counters),
                    summary.counters.lifetime_max_events,
                    summary.counters.lifetime_total_byte_events,
                    meanLifetimeByteEvents(summary.counters),
                    summary.counters.lifetime_max_byte_events,
                },
            );
        }

        var scopes = try self.collectSiteScopeSummaries(options.sort);
        defer scopes.deinit(self.allocator);
        const scope_limit = @min(options.top, scopes.items.len);
        for (scopes.items[0..scope_limit]) |summary| {
            try writer.writeAll("site_scope scope=");
            var stream = pretty_json.Writer.init(writer, .minified);
            try stream.write(summary.scope);
            try writer.print(
                " retained_bytes={d} high_water_retained_bytes={d} live_bytes={d} high_water_live_bytes={d} allocated_bytes={d} freed_bytes={d} allocations={d} frees={d} live_allocations={d} completed_lifetimes={d} lifetime_total_events={d} lifetime_mean_events={d} lifetime_max_events={d} lifetime_total_byte_events={d} lifetime_mean_byte_events={d} lifetime_max_byte_events={d}\n",
                .{
                    summary.counters.retained_bytes,
                    summary.counters.high_water_retained_bytes,
                    summary.counters.live_bytes,
                    summary.counters.high_water_live_bytes,
                    summary.counters.allocated_bytes,
                    summary.counters.freed_bytes,
                    summary.counters.allocations,
                    summary.counters.frees,
                    summary.counters.live_allocations,
                    summary.counters.completed_lifetimes,
                    summary.counters.lifetime_total_events,
                    meanLifetimeEvents(summary.counters),
                    summary.counters.lifetime_max_events,
                    summary.counters.lifetime_total_byte_events,
                    meanLifetimeByteEvents(summary.counters),
                    summary.counters.lifetime_max_byte_events,
                },
            );
        }
    }

    fn writeSiteSummaryJsonl(self: *Analyzer, writer: *std.Io.Writer, options: SummaryOptions) !void {
        var summaries = try self.collectSiteSummaries(options);
        defer summaries.deinit(self.allocator);
        const limit = @min(options.top, summaries.items.len);
        var maybe_symbols = if (options.site_symbol_binary) |binary|
            try resolveSiteSummarySymbolsAlloc(
                self.allocator,
                binary,
                summaries.items[0..limit],
            )
        else
            null;
        defer if (maybe_symbols) |*symbols| symbols.deinit(self.allocator);
        for (summaries.items[0..limit]) |summary| {
            const symbol = symbol: {
                const symbols = if (maybe_symbols) |*value|
                    value
                else
                    break :symbol null;
                const frames = symbols.find(summary.return_address);
                break :symbol if (frames.len == 0) null else frames[0];
            };
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("kind", "site");
            try object.field("sort", options.sort.name());
            try object.field("return_address", summary.return_address);
            if (symbol) |resolved| {
                try object.field("symbol", resolved.function);
                try object.field("location", resolved.location);
            }
            try writeCounterFields(
                object,
                summary.counters,
                options.layer == .logical,
            );
            try object.endLine();
        }
    }

    fn writeSiteDetailSummaryJsonl(self: *Analyzer, writer: *std.Io.Writer, options: SummaryOptions, return_address: u64) !void {
        var detail_stream = pretty_json.Writer.init(writer, .minified);
        const detail = try detail_stream.object();
        try detail.field("kind", "site_detail");
        try detail.field("sort", options.sort.name());
        try detail.field("return_address", return_address);
        try detail.endLine();

        var sizes = try self.collectSiteSizeSummaries(options.sort);
        defer sizes.deinit(self.allocator);
        const size_limit = @min(options.top, sizes.items.len);
        for (sizes.items[0..size_limit]) |summary| {
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("kind", "site_size");
            try object.field("sort", options.sort.name());
            try object.field("return_address", return_address);
            try object.field("len", summary.len);
            try writeCounterFields(
                object,
                summary.counters,
                options.layer == .logical,
            );
            try object.endLine();
        }

        var scopes = try self.collectSiteScopeSummaries(options.sort);
        defer scopes.deinit(self.allocator);
        const scope_limit = @min(options.top, scopes.items.len);
        for (scopes.items[0..scope_limit]) |summary| {
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("kind", "site_scope");
            try object.field("sort", options.sort.name());
            try object.field("return_address", return_address);
            try object.field("scope", summary.scope);
            try writeCounterFields(
                object,
                summary.counters,
                options.layer == .logical,
            );
            try object.endLine();
        }
    }

    fn collectSiteSummaries(self: *Analyzer, options: SummaryOptions) !std.ArrayListUnmanaged(SiteSummary) {
        var summaries = std.ArrayListUnmanaged(SiteSummary).empty;
        var iterator = self.sites.iterator();
        while (iterator.next()) |entry| {
            const counters = entry.value_ptr.*;
            if (!options.include_zero_live and counters.live_bytes == 0 and counters.high_water_live_bytes == 0 and counters.retained_bytes == 0) continue;
            if (counters.live_bytes < options.min_bytes and counters.high_water_live_bytes < options.min_bytes and counters.retained_bytes < options.min_bytes) continue;
            try summaries.append(self.allocator, .{
                .return_address = entry.key_ptr.*,
                .counters = counters,
            });
        }
        std.mem.sort(
            SiteSummary,
            summaries.items,
            options.sort,
            siteSummaryGreaterThan,
        );
        return summaries;
    }

    fn collectSiteSizeSummaries(
        self: *Analyzer,
        sort: Sort,
    ) !std.ArrayListUnmanaged(SiteSizeSummary) {
        var summaries = std.ArrayListUnmanaged(SiteSizeSummary).empty;
        var iterator = self.site_detail_sizes.iterator();
        while (iterator.next()) |entry| {
            try summaries.append(self.allocator, .{
                .len = entry.key_ptr.*,
                .counters = entry.value_ptr.*,
            });
        }
        std.mem.sort(
            SiteSizeSummary,
            summaries.items,
            sort,
            siteSizeSummaryGreaterThan,
        );
        return summaries;
    }

    fn collectSiteScopeSummaries(
        self: *Analyzer,
        sort: Sort,
    ) !std.ArrayListUnmanaged(SiteScopeSummary) {
        var summaries = std.ArrayListUnmanaged(SiteScopeSummary).empty;
        var iterator = self.site_detail_scopes.iterator();
        while (iterator.next()) |entry| {
            try summaries.append(self.allocator, .{
                .scope = entry.key_ptr.*,
                .counters = entry.value_ptr.*,
            });
        }
        std.mem.sort(
            SiteScopeSummary,
            summaries.items,
            sort,
            siteScopeSummaryGreaterThan,
        );
        return summaries;
    }

    fn allocatorReleases(self: *Analyzer, allocator_id: u32) bool {
        const state = self.allocators.get(allocator_id) orelse return true;
        return state.retention == .releases_freed_memory;
    }

    fn allocatorLayer(
        self: *Analyzer,
        allocator_id: u32,
    ) event_mod.Layer {
        const state = self.allocators.get(allocator_id) orelse
            return .backing_boundary;
        return state.layer;
    }

    fn lifecycleCoverage(self: *Analyzer) LifecycleCoverage {
        var coverage: LifecycleCoverage = .{};
        var allocators = self.allocators.valueIterator();
        while (allocators.next()) |allocator| {
            if (allocator.layer != .logical_allocator) continue;
            if (allocator.retention == .releases_freed_memory) {
                coverage.not_required +|= 1;
            } else if (allocator.lifecycle_instrumented) {
                coverage.instrumented +|= 1;
            } else {
                coverage.uninstrumented +|= 1;
            }
            if (allocator.prefix_complete) {
                coverage.prefix_complete +|= 1;
            } else {
                coverage.prefix_partial +|= 1;
            }
        }
        return coverage;
    }

    fn clearDrainedAllocations(self: *Analyzer) void {
        if (self.allocations.count() == 0) self.allocations.clearRetainingCapacity();
    }

    fn internScope(self: *Analyzer, scope: []const u8) ![]const u8 {
        const entry = try self.scopes.getOrPut(self.allocator, scope);
        if (!entry.found_existing) {
            const owned = try self.allocator.dupe(u8, scope);
            entry.key_ptr.* = owned;
            entry.value_ptr.* = .{};
        }
        return entry.key_ptr.*;
    }

    fn resolveScope(
        self: *const Analyzer,
        parsed: ParsedEvent,
    ) ![]const u8 {
        if (parsed.scope.len != 0) return parsed.scope;
        if (parsed.scope_id == 0) return "root";
        return self.scope_paths.get(parsed.scope_id) orelse
            error.MissingScopeDefinition;
    }
};

fn summarySnapshot(analyzer: *const Analyzer) Summary {
    const counters = analyzer.counters;
    return .{
        .events = analyzer.events,
        .allocations = counters.allocations,
        .frees = counters.frees,
        .resizes = counters.resizes,
        .remaps = counters.remaps,
        .live_allocations = @intCast(counters.live_allocations),
        .allocated_bytes = @intCast(counters.allocated_bytes),
        .freed_bytes = @intCast(counters.freed_bytes),
        .live_bytes = @intCast(counters.live_bytes),
        .high_water_live_bytes = @intCast(counters.high_water_live_bytes),
        .retained_bytes = @intCast(counters.retained_bytes),
        .high_water_retained_bytes = @intCast(
            counters.high_water_retained_bytes,
        ),
        .completed_lifetimes = counters.completed_lifetimes,
        .lifetime_total_events = counters.lifetime_total_events,
        .lifetime_mean_events = meanLifetimeEvents(counters),
        .lifetime_max_events = counters.lifetime_max_events,
        .lifetime_total_byte_events = counters.lifetime_total_byte_events,
        .lifetime_mean_byte_events = meanLifetimeByteEvents(counters),
        .lifetime_max_byte_events = counters.lifetime_max_byte_events,
        .failed_allocations = counters.failed_allocations,
        .failed_resizes = counters.failed_resizes,
        .failed_remaps = counters.failed_remaps,
        .unmatched_frees = counters.unmatched_frees,
        .unmatched_resizes = counters.unmatched_resizes,
    };
}

fn snapshotScopes(
    allocator: Allocator,
    summaries: []const ScopeSummary,
) ![]Scope {
    if (summaries.len == 0) return &.{};
    const result = try allocator.alloc(Scope, summaries.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |scope| allocator.free(scope.scope);
        allocator.free(result);
    }
    for (summaries, result) |summary, *scope| {
        scope.* = scopeSnapshot(
            try allocator.dupe(u8, summary.path),
            summary.counters,
        );
        initialized += 1;
    }
    return result;
}

fn snapshotSources(
    allocator: Allocator,
    summaries: []const SiteSummary,
    maybe_symbols: ?*const stack_mod.symbolize.Symbols,
) ![]Source {
    if (summaries.len == 0) return &.{};
    const result = try allocator.alloc(Source, summaries.len);
    errdefer allocator.free(result);
    for (summaries, result) |summary, *source| {
        const symbol = symbol: {
            const symbols = maybe_symbols orelse break :symbol null;
            const frames = symbols.find(summary.return_address);
            break :symbol if (frames.len == 0) null else frames[0];
        };
        source.* = sourceSnapshot(
            summary.return_address,
            if (symbol) |resolved| resolved.function else null,
            if (symbol) |resolved| resolved.location else null,
            summary.counters,
        );
    }
    return result;
}

fn scopeSnapshot(scope: []const u8, counters: anytype) Scope {
    return .{
        .scope = scope,
        .retained_bytes = @intCast(counters.retained_bytes),
        .high_water_retained_bytes = @intCast(
            counters.high_water_retained_bytes,
        ),
        .live_bytes = @intCast(counters.live_bytes),
        .high_water_live_bytes = @intCast(counters.high_water_live_bytes),
        .allocated_bytes = @intCast(counters.allocated_bytes),
        .freed_bytes = @intCast(counters.freed_bytes),
        .allocations = counters.allocations,
        .frees = counters.frees,
        .live_allocations = @intCast(counters.live_allocations),
        .completed_lifetimes = counters.completed_lifetimes,
        .lifetime_total_events = counters.lifetime_total_events,
        .lifetime_mean_events = meanLifetimeEvents(counters),
        .lifetime_max_events = counters.lifetime_max_events,
        .lifetime_total_byte_events = counters.lifetime_total_byte_events,
        .lifetime_mean_byte_events = meanLifetimeByteEvents(counters),
        .lifetime_max_byte_events = counters.lifetime_max_byte_events,
    };
}

fn sourceSnapshot(
    return_address: u64,
    function: ?[]const u8,
    location: ?[]const u8,
    counters: anytype,
) Source {
    const scope = scopeSnapshot("", counters);
    return .{
        .return_address = return_address,
        .function = function,
        .location = location,
        .retained_bytes = scope.retained_bytes,
        .high_water_retained_bytes = scope.high_water_retained_bytes,
        .live_bytes = scope.live_bytes,
        .high_water_live_bytes = scope.high_water_live_bytes,
        .allocated_bytes = scope.allocated_bytes,
        .freed_bytes = scope.freed_bytes,
        .allocations = scope.allocations,
        .frees = scope.frees,
        .live_allocations = scope.live_allocations,
        .completed_lifetimes = scope.completed_lifetimes,
        .lifetime_total_events = scope.lifetime_total_events,
        .lifetime_mean_events = scope.lifetime_mean_events,
        .lifetime_max_events = scope.lifetime_max_events,
        .lifetime_total_byte_events = scope.lifetime_total_byte_events,
        .lifetime_mean_byte_events = scope.lifetime_mean_byte_events,
        .lifetime_max_byte_events = scope.lifetime_max_byte_events,
    };
}

fn classifyCaptureIntegrity(result: *CaptureIntegrity) void {
    if (result.event_count == 0) return setIntegrity(
        result,
        "no_events",
        "capture_trace_events",
        "memtrace contains no events",
    );
    if (result.sequence_regression_count != 0) return setIntegrity(
        result,
        "non_monotonic_sequence",
        "inspect_trace_writer",
        "memtrace sequence is non-monotonic; treat the summary as corrupt evidence",
    );
    if (result.missing_sequence_event_count != 0) return setIntegrity(
        result,
        "sequence_gaps",
        "inspect_recorder_capacity_or_writer_failures",
        "memtrace sequence has gaps; treat the summary as partial evidence",
    );
    if (result.unsequenced_event_count != 0) return setIntegrity(
        result,
        "missing_sequence_metadata",
        "recapture_with_sequence_metadata",
        "one or more memtrace events lack sequence metadata; completeness is unknown",
    );
    classifyCaptureLifecycle(result);
}

fn classifyCaptureLifecycle(result: *CaptureIntegrity) void {
    if (result.start_event_count > 1 or result.stop_event_count > 1) {
        return setIntegrity(
            result,
            "multiple_trace_sessions",
            "capture_one_trace_session",
            "memtrace mixes multiple trace lifecycles; completeness is ambiguous",
        );
    }
    if (result.start_event_count == 0) return setIntegrity(
        result,
        "missing_start_event",
        "capture_complete_trace_lifecycle",
        "memtrace does not contain its start event; treat it as partial evidence",
    );
    if (result.stop_event_count == 0) return setIntegrity(
        result,
        "missing_stop_event",
        "capture_complete_trace_lifecycle",
        "memtrace does not contain its stop event; terminal state is partial evidence",
    );
    if (result.start_sequence != result.first_sequence or
        result.stop_sequence != result.last_sequence)
    {
        return setIntegrity(
            result,
            "lifecycle_not_bounded",
            "capture_complete_trace_lifecycle",
            "memtrace start and stop events do not bound the event sequence",
        );
    }
    if (result.unbalanced_event_count != 0) setIntegrity(
        result,
        "unbalanced_events",
        "inspect_allocation_and_scope_lifecycles",
        "memtrace contains unmatched allocation or scope lifecycle events",
    );
}

fn setIntegrity(
    result: *CaptureIntegrity,
    status: []const u8,
    action: []const u8,
    message: []const u8,
) void {
    result.status = status;
    result.action = action;
    result.message = message;
}

fn writeCounterFields(
    object: pretty_json.Object,
    counters: anytype,
    logical: bool,
) !void {
    if (logical) {
        try object.field("open_request_bytes", counters.live_bytes);
        try object.field(
            "high_water_open_request_bytes",
            counters.high_water_live_bytes,
        );
        try object.field(
            "bulk_invalidated_requests",
            counters.bulk_invalidated_requests,
        );
        try object.field(
            "bulk_invalidated_bytes",
            counters.bulk_invalidated_bytes,
        );
        try object.field("untracked_requests", counters.untracked_requests);
        try object.field(
            "untracked_request_bytes",
            counters.untracked_request_bytes,
        );
    } else {
        try object.field("retained_bytes", counters.retained_bytes);
        try object.field(
            "high_water_retained_bytes",
            counters.high_water_retained_bytes,
        );
        try object.field("live_bytes", counters.live_bytes);
        try object.field(
            "high_water_live_bytes",
            counters.high_water_live_bytes,
        );
    }
    try object.field("allocated_bytes", counters.allocated_bytes);
    if (logical) {
        try object.field("requested_bytes", counters.allocated_bytes);
        try object.field(
            "explicitly_closed_bytes",
            counters.freed_bytes,
        );
    } else {
        try object.field("freed_bytes", counters.freed_bytes);
    }
    try object.field("allocations", counters.allocations);
    try object.field("frees", counters.frees);
    if (logical) {
        try object.field("open_requests", counters.live_allocations);
    } else {
        try object.field("live_allocations", counters.live_allocations);
    }
    try object.field("completed_lifetimes", counters.completed_lifetimes);
    try object.field("lifetime_total_events", counters.lifetime_total_events);
    try object.field("lifetime_mean_events", meanLifetimeEvents(counters));
    try object.field("lifetime_max_events", counters.lifetime_max_events);
    try object.field(
        "lifetime_total_byte_events",
        counters.lifetime_total_byte_events,
    );
    try object.field(
        "lifetime_mean_byte_events",
        meanLifetimeByteEvents(counters),
    );
    try object.field(
        "lifetime_max_byte_events",
        counters.lifetime_max_byte_events,
    );
}

fn writeCaptureIntegrityText(
    writer: *std.Io.Writer,
    integrity: CaptureIntegrity,
) !void {
    try writer.print(
        "memtrace capture_integrity={s} events={d} sequenced_events={d} " ++
            "unsequenced_events={d} sequence_gaps={d} missing_sequence_events={d} " ++
            "sequence_regressions={d} start_events={d} stop_events={d} " ++
            "unbalanced_events={d}",
        .{
            integrity.status,
            integrity.event_count,
            integrity.sequenced_event_count,
            integrity.unsequenced_event_count,
            integrity.sequence_gap_count,
            integrity.missing_sequence_event_count,
            integrity.sequence_regression_count,
            integrity.start_event_count,
            integrity.stop_event_count,
            integrity.unbalanced_event_count,
        },
    );
    try writer.writeAll(" first_sequence=");
    try writeOptionalU64Text(writer, integrity.first_sequence);
    try writer.writeAll(" last_sequence=");
    try writeOptionalU64Text(writer, integrity.last_sequence);
    try writer.writeAll(" start_sequence=");
    try writeOptionalU64Text(writer, integrity.start_sequence);
    try writer.writeAll(" stop_sequence=");
    try writeOptionalU64Text(writer, integrity.stop_sequence);
    try writer.writeByte('\n');
    const message = integrity.message orelse return;
    try writer.print(
        "memtrace capture caveat={s} action={s} message=",
        .{ integrity.status, integrity.action },
    );
    var stream = pretty_json.Writer.init(writer, .minified);
    try stream.write(message);
    try writer.writeByte('\n');
}

fn writeCaptureIntegrityJson(
    object: pretty_json.Object,
    integrity: CaptureIntegrity,
) !void {
    const capture = try object.object("capture_integrity");
    try capture.field("method", capture_integrity_method);
    try capture.field("status", integrity.status);
    try capture.field("action", integrity.action);
    try capture.field("message", integrity.message);
    try capture.field("event_count", integrity.event_count);
    try capture.field("sequenced_event_count", integrity.sequenced_event_count);
    try capture.field("unsequenced_event_count", integrity.unsequenced_event_count);
    try capture.field("first_sequence", integrity.first_sequence);
    try capture.field("last_sequence", integrity.last_sequence);
    try capture.field("sequence_gap_count", integrity.sequence_gap_count);
    try capture.field("missing_sequence_event_count", integrity.missing_sequence_event_count);
    try capture.field("sequence_regression_count", integrity.sequence_regression_count);
    try capture.field("start_event_count", integrity.start_event_count);
    try capture.field("stop_event_count", integrity.stop_event_count);
    try capture.field("unbalanced_event_count", integrity.unbalanced_event_count);
    try capture.field("start_sequence", integrity.start_sequence);
    try capture.field("stop_sequence", integrity.stop_sequence);
    const limits = try capture.array("limits");
    try limits.element(
        "sequence gaps are lower-bound missing-row evidence",
    );
    try limits.element(
        "complete bounds do not prove whole-process coverage, low perturbation, or " ++
            "representative workload coverage",
    );
    try limits.end();
    try capture.end();
}

fn writeOptionalU64Text(writer: *std.Io.Writer, value: ?u64) !void {
    if (value) |actual| try writer.print("{d}", .{actual}) else try writer.writeAll("none");
}

pub fn writeSummaryFromJsonlPath(allocator: Allocator, path: []const u8, writer: *std.Io.Writer, options: SummaryOptions) !void {
    var analyzer = Analyzer.initForLayer(allocator, options.layer);
    defer analyzer.deinit();
    analyzer.track_sites = options.include_sites;
    analyzer.site_detail_return_address = options.site_detail_return_address;
    try ingestPath(&analyzer, path);
    try analyzer.writeSummary(writer, options);
}

pub fn writeSummaryJsonlFromJsonlPath(
    allocator: Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    options: SummaryOptions,
) !CaptureIntegrity {
    var analyzer = Analyzer.initForLayer(allocator, options.layer);
    defer analyzer.deinit();
    analyzer.track_sites = options.include_sites;
    analyzer.site_detail_return_address = options.site_detail_return_address;
    try ingestPath(&analyzer, path);
    try analyzer.writeSummaryJsonl(writer, options);
    return analyzer.captureIntegrity();
}

fn ingestPath(analyzer: *Analyzer, path: []const u8) !void {
    var file = try sys.fs.cwd().openFile(sys.fs.debugIo(), path, .{});
    defer file.close(sys.fs.debugIo());

    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(sys.fs.debugIo(), &buffer);
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        const actual = line orelse break;
        try analyzer.ingestJsonLine(actual);
    }
}

fn allocationKey(allocation_id: u64, address: u64) u64 {
    if (allocation_id != 0) return allocation_id;
    return address;
}

fn completedLifetimeEvents(allocation_event: u64, free_event: u64) u64 {
    if (free_event <= allocation_event) return 0;
    return free_event - allocation_event;
}

fn completedLifetimeByteEvents(
    len: usize,
    allocation_event: u64,
    free_event: u64,
) u64 {
    const events = completedLifetimeEvents(allocation_event, free_event);
    return @as(u64, @intCast(len)) *| events;
}

fn accrueLifetimeByteEvents(record: *AllocationRecord, event: u64) void {
    record.byte_events +|= completedLifetimeByteEvents(
        record.len,
        record.segment_event,
        event,
    );
    record.segment_event = event;
}

fn applyCompletedLifetime(
    counters: anytype,
    lifetime_events: u64,
    lifetime_byte_events: u64,
) void {
    counters.completed_lifetimes +|= 1;
    counters.lifetime_total_events +|= lifetime_events;
    counters.lifetime_max_events = @max(counters.lifetime_max_events, lifetime_events);
    counters.lifetime_total_byte_events +|= lifetime_byte_events;
    counters.lifetime_max_byte_events = @max(
        counters.lifetime_max_byte_events,
        lifetime_byte_events,
    );
}

fn applyCountersLostTracking(counters: anytype, len: usize) void {
    if (counters.live_allocations > 0) counters.live_allocations -= 1;
    if (counters.live_bytes >= len) {
        counters.live_bytes -= len;
    } else {
        counters.live_bytes = 0;
    }
    counters.untracked_requests +|= 1;
    counters.untracked_request_bytes +|= len;
}

fn meanLifetimeEvents(counters: anytype) u64 {
    if (counters.completed_lifetimes == 0) return 0;
    return counters.lifetime_total_events / counters.completed_lifetimes;
}

fn meanLifetimeByteEvents(counters: anytype) u64 {
    if (counters.completed_lifetimes == 0) return 0;
    return counters.lifetime_total_byte_events / counters.completed_lifetimes;
}

test "escaped canonical scope uses generic replay" {
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try (event_mod.Event{
        .seq = 1,
        .kind = .alloc,
        .allocation_id = 1,
        .address = 4096,
        .len = 32,
    }).writeJsonLine(&bytes.writer, null, "root/quoted\"scope");

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(bytes.written());

    var summary = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer summary.deinit();
    try analyzer.writeSummary(&summary.writer, .{});
    try std.testing.expect(std.mem.indexOf(u8, summary.written(), "root/quoted\"scope retained_bytes=32") != null);
}

test "event analysis resolves scope ids from scope entry events" {
    const events =
        "{\"v\":3,\"seq\":1,\"kind\":\"trace.start\"}\n" ++
        "{\"v\":3,\"seq\":2,\"kind\":\"scope.enter\",\"scope_id\":1," ++
        "\"scope\":\"root/phase\"}\n" ++
        "{\"v\":3,\"seq\":3,\"kind\":\"alloc\",\"allocation_id\":1," ++
        "\"scope_id\":1,\"address\":4096,\"len\":32}\n" ++
        "{\"v\":3,\"seq\":4,\"kind\":\"free\",\"allocation_id\":1," ++
        "\"scope_id\":1,\"address\":4096,\"old_len\":32}\n" ++
        "{\"v\":3,\"seq\":5,\"kind\":\"scope.exit\",\"scope_id\":1}\n" ++
        "{\"v\":3,\"seq\":6,\"kind\":\"trace.stop\"}\n";
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(events);

    var summary = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer summary.deinit();
    try analyzer.writeSummary(
        &summary.writer,
        .{ .include_zero_live = true },
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            summary.written(),
            "root/phase retained_bytes=0 high_water_retained_bytes=32",
        ) != null,
    );
}

fn scopeSummaryGreaterThan(
    sort: Sort,
    left: ScopeSummary,
    right: ScopeSummary,
) bool {
    if (counterOrder(sort, left.counters, right.counters)) |order| return order;
    return std.mem.lessThan(u8, left.path, right.path);
}

fn siteSummaryGreaterThan(
    sort: Sort,
    left: SiteSummary,
    right: SiteSummary,
) bool {
    if (counterOrder(sort, left.counters, right.counters)) |order| return order;
    return left.return_address < right.return_address;
}

fn siteSizeSummaryGreaterThan(
    sort: Sort,
    left: SiteSizeSummary,
    right: SiteSizeSummary,
) bool {
    if (counterOrder(sort, left.counters, right.counters)) |order| return order;
    return left.len < right.len;
}

fn siteScopeSummaryGreaterThan(
    sort: Sort,
    left: SiteScopeSummary,
    right: SiteScopeSummary,
) bool {
    if (counterOrder(sort, left.counters, right.counters)) |order| return order;
    return std.mem.lessThan(u8, left.scope, right.scope);
}

fn counterOrder(sort: Sort, left: anytype, right: @TypeOf(left)) ?bool {
    switch (sort) {
        .retained => {
            if (left.retained_bytes != right.retained_bytes) {
                return left.retained_bytes > right.retained_bytes;
            }
            if (left.high_water_retained_bytes !=
                right.high_water_retained_bytes)
            {
                return left.high_water_retained_bytes >
                    right.high_water_retained_bytes;
            }
        },
        .traffic => {
            if (left.allocated_bytes != right.allocated_bytes) {
                return left.allocated_bytes > right.allocated_bytes;
            }
            if (left.allocations != right.allocations) {
                return left.allocations > right.allocations;
            }
        },
        .lifetime => {
            if (left.lifetime_total_byte_events !=
                right.lifetime_total_byte_events)
            {
                return left.lifetime_total_byte_events >
                    right.lifetime_total_byte_events;
            }
            if (left.lifetime_total_events != right.lifetime_total_events) {
                return left.lifetime_total_events >
                    right.lifetime_total_events;
            }
            if (left.lifetime_max_events != right.lifetime_max_events) {
                return left.lifetime_max_events > right.lifetime_max_events;
            }
            if (left.completed_lifetimes != right.completed_lifetimes) {
                return left.completed_lifetimes > right.completed_lifetimes;
            }
        },
    }
    if (left.retained_bytes != right.retained_bytes) {
        return left.retained_bytes > right.retained_bytes;
    }
    if (left.high_water_retained_bytes != right.high_water_retained_bytes) {
        return left.high_water_retained_bytes >
            right.high_water_retained_bytes;
    }
    if (left.allocated_bytes != right.allocated_bytes) {
        return left.allocated_bytes > right.allocated_bytes;
    }
    if (left.allocations != right.allocations) {
        return left.allocations > right.allocations;
    }
    if (left.lifetime_total_byte_events !=
        right.lifetime_total_byte_events)
    {
        return left.lifetime_total_byte_events >
            right.lifetime_total_byte_events;
    }
    if (left.lifetime_total_events != right.lifetime_total_events) {
        return left.lifetime_total_events > right.lifetime_total_events;
    }
    if (left.lifetime_max_events != right.lifetime_max_events) {
        return left.lifetime_max_events > right.lifetime_max_events;
    }
    if (left.completed_lifetimes != right.completed_lifetimes) {
        return left.completed_lifetimes > right.completed_lifetimes;
    }
    if (left.live_bytes != right.live_bytes) {
        return left.live_bytes > right.live_bytes;
    }
    if (left.high_water_live_bytes != right.high_water_live_bytes) {
        return left.high_water_live_bytes > right.high_water_live_bytes;
    }
    return null;
}

test "allocation summary sort separates retention traffic and lifetime" {
    const retained = ScopeSummary{
        .path = "retained",
        .counters = .{
            .retained_bytes = 128,
            .allocated_bytes = 16,
            .lifetime_total_events = 8,
        },
    };
    const traffic = ScopeSummary{
        .path = "traffic",
        .counters = .{
            .retained_bytes = 32,
            .allocated_bytes = 256,
            .lifetime_total_events = 4,
        },
    };
    const lifetime = ScopeSummary{
        .path = "lifetime",
        .counters = .{
            .retained_bytes = 16,
            .allocated_bytes = 32,
            .lifetime_total_events = 512,
        },
    };
    try std.testing.expect(scopeSummaryGreaterThan(.retained, retained, traffic));
    try std.testing.expect(scopeSummaryGreaterThan(.traffic, traffic, retained));
    try std.testing.expect(scopeSummaryGreaterThan(.lifetime, lifetime, retained));
    inline for (std.meta.tags(Sort)) |sort| {
        try std.testing.expect(!scopeSummaryGreaterThan(sort, retained, retained));
    }
    try std.testing.expectEqual(Sort.retained, Sort.parse("retained").?);
    try std.testing.expectEqual(Sort.traffic, Sort.parse("traffic").?);
    try std.testing.expectEqual(Sort.lifetime, Sort.parse("lifetime").?);
    try std.testing.expect(Sort.parse("bytes") == null);
}

fn resolveSiteSummarySymbolsAlloc(
    allocator: Allocator,
    binary_path: []const u8,
    summaries: []const SiteSummary,
) !?stack_mod.symbolize.Symbols {
    if (summaries.len == 0) return null;
    const addresses = try allocator.alloc(u64, summaries.len);
    defer allocator.free(addresses);
    for (summaries, 0..) |summary, index| {
        addresses[index] = summary.return_address;
    }
    return try stack_mod.symbolize.resolveAlloc(
        allocator,
        binary_path,
        addresses,
    );
}

fn resolveSiteAddressesAlloc(
    allocator: Allocator,
    binary_path: []const u8,
    addresses: []const u64,
) !?stack_mod.symbolize.Symbols {
    if (addresses.len == 0) return null;
    return try stack_mod.symbolize.resolveAlloc(
        allocator,
        binary_path,
        addresses,
    );
}

test "event analysis preserves retained allocator pressure" {
    var tracer = try tracer_mod.Tracer.init(std.testing.allocator, .{ .record_events = true });
    defer tracer.deinit();
    var traced = try tracer.tracedAllocatorWithOptions(std.testing.allocator, .{
        .name = "arena",
        .retention = .retains_freed_memory,
    });
    const allocator = traced.allocator();

    var scope = try tracer.enter("phase");
    const bytes = try allocator.alloc(u8, 64);
    allocator.free(bytes);
    scope.exit();

    var events = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer events.deinit();
    try tracer.writeEventsJsonl(&events.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(events.written());
    const integrity = analyzer.captureIntegrity();
    try std.testing.expectEqualStrings("complete", integrity.status);
    try std.testing.expectEqual(@as(?u64, 1), integrity.first_sequence);
    try std.testing.expectEqual(integrity.first_sequence, integrity.start_sequence);
    try std.testing.expectEqual(integrity.last_sequence, integrity.stop_sequence);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try analyzer.writeSummary(&out.writer, .{ .top = 8, .include_zero_live = true });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "retained_bytes=64") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "live_bytes=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "root/phase retained_bytes=64") != null);
}

test "event analysis separates resize and remap event counts" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    var events = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer events.deinit();
    const rows = [_]event_mod.Event{
        .{ .seq = 1, .kind = .trace_start },
        .{ .seq = 2, .kind = .allocator, .allocator_id = 0 },
        .{
            .seq = 3,
            .kind = .alloc,
            .allocation_id = 1,
            .address = 100,
            .len = 16,
        },
        .{
            .seq = 4,
            .kind = .resize,
            .allocation_id = 1,
            .address = 100,
            .old_len = 16,
            .len = 24,
        },
        .{
            .seq = 5,
            .kind = .remap,
            .allocation_id = 1,
            .old_address = 100,
            .address = 200,
            .old_len = 24,
            .len = 32,
        },
        .{ .seq = 6, .kind = .trace_stop },
    };
    for (rows) |row| try row.writeJsonLine(&events.writer, null, null);
    try analyzer.ingestJsonlBytes(events.written());
    var output: [8 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try analyzer.writeSummaryJsonl(&writer, .{ .top = 0 });
    try std.testing.expect(
        std.mem.indexOf(u8, writer.buffered(), "\"resizes\":1,\"remaps\":1") != null,
    );
}

test "event analysis classifies release-explicit lifecycle as not required" {
    var events = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer events.deinit();
    const rows = [_]event_mod.Event{
        .{ .seq = 1, .kind = .trace_start },
        .{
            .seq = 2,
            .kind = .allocator,
            .allocator_id = 1,
            .retains_freed_memory = true,
            .layer = .logical_allocator,
            .lifecycle_instrumented = true,
        },
        .{
            .seq = 3,
            .kind = .allocator,
            .allocator_id = 2,
            .retains_freed_memory = false,
            .layer = .logical_allocator,
        },
        .{ .seq = 4, .kind = .trace_stop },
    };
    for (rows) |row| try row.writeJsonLine(&events.writer, null, null);
    var analyzer = Analyzer.initForLayer(std.testing.allocator, .logical);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(events.written());

    var summary = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer summary.deinit();
    try analyzer.writeSummaryJsonl(&summary.writer, .{
        .layer = .logical,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary.written(),
        "\"lifecycle_coverage\":\"complete\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary.written(),
        "\"lifecycle_instrumented_producers\":1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary.written(),
        "\"lifecycle_uninstrumented_producers\":0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary.written(),
        "\"lifecycle_not_required_producers\":1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary.written(),
        "\"prefix_complete_producers\":2",
    ) != null);
}

test "event replay matches failed known and lost-tracking remaps" {
    if (!observe.enabled) return error.SkipZigTest;
    var tracer = try tracer_mod.Tracer.init(std.testing.allocator, .{
        .record_events = true,
    });
    defer tracer.deinit();
    var observation = try tracer.observeOwnedAllocators();
    defer observation.stop();
    const identity = observe.Identity{
        .producer_id = observe.producerId(),
        .producer = .arena,
        .generation = 0,
        .owner_cookie = 0xcafe,
    };

    var first = observe.beginOwned(
        identity,
        .alloc,
        0,
        0,
        64,
        8,
        @returnAddress(),
    );
    first.finish(.{
        .address = 0x1000,
        .succeeded = true,
    });
    var second = observe.beginOwned(
        identity,
        .alloc,
        0,
        0,
        32,
        8,
        @returnAddress(),
    );
    second.finish(.{
        .address = 0x2000,
        .succeeded = true,
    });
    var failed_known = observe.beginOwned(
        identity,
        .remap,
        0x1000,
        64,
        80,
        8,
        @returnAddress(),
    );
    failed_known.finish(.{
        .address = 0,
        .succeeded = false,
    });
    var collision = observe.beginOwned(
        identity,
        .remap,
        0x1000,
        64,
        96,
        8,
        @returnAddress(),
    );
    collision.finish(.{
        .address = 0x2000,
        .succeeded = true,
    });
    observation.stop();

    const live = tracer.snapshotLayer(.logical_allocator);
    var live_summary = std.Io.Writer.Allocating.init(
        std.testing.allocator,
    );
    defer live_summary.deinit();
    try tracer.writeSummaryJsonl(&live_summary.writer, .{
        .layer = .logical_allocator,
        .include_zero_live = true,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        live_summary.written(),
        "\"resizes\":1,\"remaps\":0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        live_summary.written(),
        "\"untracked_requests\":1,\"untracked_request_bytes\":96",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        live_summary.written(),
        "\"failed_remaps\":1,\"unmatched_frees\":0," ++
            "\"unmatched_resizes\":0,\"unmatched_remaps\":0",
    ) != null);

    var emitted = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer emitted.deinit();
    try tracer.writeEventsJsonl(&emitted.writer);
    var replay = Analyzer.initForLayer(std.testing.allocator, .logical);
    defer replay.deinit();
    try replay.ingestJsonlBytes(emitted.written());

    try std.testing.expectEqual(live.allocations, replay.counters.allocations);
    try std.testing.expectEqual(live.frees, replay.counters.frees);
    try std.testing.expectEqual(
        live.live_allocations,
        replay.counters.live_allocations,
    );
    try std.testing.expectEqual(
        live.allocated_bytes,
        replay.counters.allocated_bytes,
    );
    try std.testing.expectEqual(
        live.freed_bytes,
        replay.counters.freed_bytes,
    );
    try std.testing.expectEqual(live.live_bytes, replay.counters.live_bytes);
    try std.testing.expectEqual(
        live.high_water_live_bytes,
        replay.counters.high_water_live_bytes,
    );
    try std.testing.expectEqual(@as(u64, 1), replay.counters.resizes);
    try std.testing.expectEqual(@as(u64, 0), replay.counters.remaps);
    try std.testing.expectEqual(@as(u64, 1), replay.counters.failed_remaps);
    try std.testing.expectEqual(@as(u64, 0), replay.counters.unmatched_remaps);
    try std.testing.expectEqual(
        @as(u64, 1),
        replay.counters.untracked_requests,
    );
    try std.testing.expectEqual(
        @as(usize, 96),
        replay.counters.untracked_request_bytes,
    );
    try std.testing.expectEqual(@as(usize, 1), replay.allocations.count());
}

test "event analysis classifies sequence loss and tail truncation" {
    var gapped = Analyzer.init(std.testing.allocator);
    defer gapped.deinit();
    try gapped.ingestJsonlBytes(
        "{\"v\":3,\"seq\":1,\"kind\":\"trace.start\"}\n" ++
            "{\"v\":3,\"seq\":3,\"kind\":\"allocator\",\"allocator_id\":0}\n" ++
            "{\"v\":3,\"seq\":4,\"kind\":\"trace.stop\"}\n",
    );
    const gap_integrity = gapped.captureIntegrity();
    try std.testing.expectEqualStrings("sequence_gaps", gap_integrity.status);
    try std.testing.expectEqual(@as(u64, 1), gap_integrity.sequence_gap_count);
    try std.testing.expectEqual(@as(u64, 1), gap_integrity.missing_sequence_event_count);

    var truncated = Analyzer.init(std.testing.allocator);
    defer truncated.deinit();
    try truncated.ingestJsonlBytes(
        "{\"v\":3,\"seq\":1,\"kind\":\"trace.start\"}\n" ++
            "{\"v\":3,\"seq\":2,\"kind\":\"allocator\",\"allocator_id\":0}\n",
    );
    const tail_integrity = truncated.captureIntegrity();
    try std.testing.expectEqualStrings("missing_stop_event", tail_integrity.status);
    try std.testing.expectEqual(@as(u64, 0), tail_integrity.sequence_gap_count);
}

test "event analysis reports allocation sites" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    try analyzer.ingestJsonLine(
        "{\"v\":3,\"kind\":\"allocator\",\"allocator_id\":0,\"retains_freed_memory\":true}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"kind\":\"alloc\",\"allocator_id\":0,\"allocation_id\":1,\"address\":4096,\"len\":64,\"return_address\":2748,\"scope\":\"root/phase\"}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"kind\":\"free\",\"allocator_id\":0,\"allocation_id\":1,\"address\":4096,\"len\":64,\"return_address\":8192,\"scope\":\"root/phase\"}",
    );

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try analyzer.writeSummary(&out.writer, .{ .top = 8, .include_sites = true });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "site return_address=0xabc retained_bytes=64") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "freed_bytes=64") != null);
}

test "event analysis reports site detail by size and scope" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    analyzer.site_detail_return_address = 0xabc;

    try analyzer.ingestJsonLine(
        "{\"v\":3,\"kind\":\"allocator\",\"allocator_id\":0,\"retains_freed_memory\":true}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"kind\":\"alloc\",\"allocator_id\":0,\"allocation_id\":1,\"address\":4096,\"len\":64,\"return_address\":2748,\"scope\":\"root/left\"}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"kind\":\"alloc\",\"allocator_id\":0,\"allocation_id\":2,\"address\":8192,\"len\":128,\"return_address\":2748,\"scope\":\"root/right\"}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"kind\":\"free\",\"allocator_id\":0,\"allocation_id\":1,\"address\":4096,\"len\":64,\"return_address\":8192,\"scope\":\"root/left\"}",
    );

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try analyzer.writeSummary(&out.writer, .{ .top = 8, .site_detail_return_address = 0xabc });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "site_detail return_address=0xabc") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "site_size len=128 retained_bytes=128") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "site_size len=64 retained_bytes=64") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "site_scope scope=\"root/right\" retained_bytes=128") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "site_scope scope=\"root/left\" retained_bytes=64") != null);
}

test "event analysis reports completed allocation lifetimes" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    try analyzer.ingestJsonLine(
        "{\"v\":3,\"kind\":\"allocator\",\"allocator_id\":0,\"retains_freed_memory\":false}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"kind\":\"alloc\",\"allocator_id\":0,\"allocation_id\":1,\"address\":4096,\"len\":64,\"return_address\":2748,\"scope\":\"root/phase\"}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"kind\":\"resize\",\"allocator_id\":0,\"allocation_id\":1,\"address\":4096,\"old_len\":64,\"len\":80,\"return_address\":2748,\"scope\":\"root/phase\"}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"kind\":\"alloc\",\"allocator_id\":0,\"allocation_id\":2,\"address\":8192,\"len\":32,\"return_address\":3567,\"scope\":\"root/temp\"}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"kind\":\"free\",\"allocator_id\":0,\"allocation_id\":2,\"address\":8192,\"len\":32,\"return_address\":3567,\"scope\":\"root/temp\"}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"kind\":\"free\",\"allocator_id\":0,\"allocation_id\":1,\"address\":4096,\"len\":80,\"return_address\":2748,\"scope\":\"root/phase\"}",
    );

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try analyzer.writeSummary(&out.writer, .{ .top = 8, .include_sites = true, .include_zero_live = true });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "memtrace lifetimes completed=2 total_events=5 mean_events=2 max_events=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "completed_lifetimes=1 lifetime_total_events=4 lifetime_mean_events=4 lifetime_max_events=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "completed_lifetimes=1 lifetime_total_events=1 lifetime_mean_events=1 lifetime_max_events=1") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "total_byte_events=336 mean_byte_events=168 max_byte_events=304",
    ) != null);

    var jsonl = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer jsonl.deinit();
    try analyzer.writeSummaryJsonl(&jsonl.writer, .{ .top = 8, .include_sites = true, .include_zero_live = true });
    const jsonl_text = jsonl.written();
    try std.testing.expect(std.mem.indexOf(u8, jsonl_text, "\"completed_lifetimes\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl_text, "\"lifetime_total_events\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl_text, "\"lifetime_max_events\":4") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        jsonl_text,
        "\"lifetime_total_byte_events\":336",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        jsonl_text,
        "\"kind\":\"scope\",\"sort\":\"retained\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        jsonl_text,
        "\"kind\":\"site\",\"sort\":\"retained\"",
    ) != null);

    var snapshot_value = try analyzer.snapshot(std.testing.allocator, .{
        .top = 8,
        .include_zero_live = true,
    });
    defer snapshot_value.deinit();
    try std.testing.expectEqual(
        @as(u64, 336),
        snapshot_value.summary.lifetime_total_byte_events,
    );
    try std.testing.expectEqual(
        @as(u64, 304),
        snapshot_value.summary.lifetime_max_byte_events,
    );
    inline for (std.meta.tags(Sort)) |sort| {
        const ranking = snapshot_value.rankings.get(sort);
        try std.testing.expectEqual(@as(usize, 2), ranking.scopes.len);
        try std.testing.expectEqual(@as(usize, 2), ranking.sources.len);
    }
    try std.testing.expectEqualStrings(
        "root/phase",
        snapshot_value.rankings.lifetime.scopes[0].scope,
    );
    try std.testing.expectEqual(
        @as(u64, 304),
        snapshot_value.rankings.lifetime.scopes[0]
            .lifetime_total_byte_events,
    );
}

test "event analysis separates backing logical and failed allocations" {
    const events =
        "{\"v\":3,\"kind\":\"allocator\",\"allocator_id\":0," ++
        "\"layer\":\"backing_boundary\"}\n" ++
        "{\"v\":3,\"kind\":\"allocator\",\"allocator_id\":1," ++
        "\"layer\":\"logical_allocator\",\"producer\":\"arena\"}\n" ++
        "{\"v\":3,\"kind\":\"alloc\",\"allocator_id\":0," ++
        "\"allocation_id\":1,\"address\":4096,\"len\":128," ++
        "\"scope\":\"root\",\"layer\":\"backing_boundary\"}\n" ++
        "{\"v\":3,\"kind\":\"alloc\",\"allocator_id\":1," ++
        "\"allocation_id\":2,\"address\":8192,\"len\":16," ++
        "\"scope\":\"root\",\"layer\":\"logical_allocator\"," ++
        "\"producer\":\"arena\"}\n" ++
        "{\"v\":3,\"kind\":\"alloc\",\"allocator_id\":1,\"len\":64," ++
        "\"succeeded\":false,\"scope\":\"root\"," ++
        "\"layer\":\"logical_allocator\",\"producer\":\"arena\"}\n";

    var backing = Analyzer.initForLayer(std.testing.allocator, .backing);
    defer backing.deinit();
    try backing.ingestJsonlBytes(events);
    var backing_summary = std.Io.Writer.Allocating.init(
        std.testing.allocator,
    );
    defer backing_summary.deinit();
    try backing.writeSummary(&backing_summary.writer, .{});
    try std.testing.expect(std.mem.indexOf(
        u8,
        backing_summary.written(),
        "layer=backing sort=retained events=5 allocations=1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        backing_summary.written(),
        "allocated_bytes=128",
    ) != null);

    var logical = Analyzer.initForLayer(std.testing.allocator, .logical);
    defer logical.deinit();
    try logical.ingestJsonlBytes(events);
    var logical_summary = std.Io.Writer.Allocating.init(
        std.testing.allocator,
    );
    defer logical_summary.deinit();
    try logical.writeSummary(
        &logical_summary.writer,
        .{ .layer = .logical },
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        logical_summary.written(),
        "layer=logical sort=retained events=5 allocations=1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        logical_summary.written(),
        "requested_bytes=16",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        logical_summary.written(),
        "failed_allocations=1",
    ) != null);
}

test "physical analysis preserves partial mapping lifecycles" {
    const events =
        "{\"v\":3,\"kind\":\"map\",\"allocator_id\":2," ++
        "\"address\":4096,\"len\":16384,\"scope\":\"root\"," ++
        "\"layer\":\"physical_page\",\"producer\":\"sys_memory\"}\n" ++
        "{\"v\":3,\"kind\":\"unmap\",\"allocator_id\":2," ++
        "\"address\":4096,\"len\":4096,\"scope\":\"root\"," ++
        "\"layer\":\"physical_page\",\"producer\":\"sys_memory\"}\n" ++
        "{\"v\":3,\"kind\":\"unmap\",\"allocator_id\":2," ++
        "\"address\":16384,\"len\":4096,\"scope\":\"root\"," ++
        "\"layer\":\"physical_page\",\"producer\":\"sys_memory\"}\n" ++
        "{\"v\":3,\"kind\":\"discard\",\"allocator_id\":2," ++
        "\"address\":8192,\"len\":4096,\"scope\":\"root\"," ++
        "\"layer\":\"physical_page\",\"producer\":\"sys_memory\"}\n";

    var analyzer = Analyzer.initForLayer(std.testing.allocator, .physical);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(events);
    try std.testing.expectEqual(@as(u64, 1), analyzer.physical.maps);
    try std.testing.expectEqual(@as(u64, 2), analyzer.physical.unmaps);
    try std.testing.expectEqual(@as(u64, 1), analyzer.physical.discards);
    try std.testing.expectEqual(
        @as(usize, 8192),
        analyzer.physical.live_mapped_bytes,
    );
    try std.testing.expectEqual(@as(usize, 1), analyzer.mappings.count());
    try std.testing.expectEqual(
        @as(usize, 0),
        analyzer.physical.untracked_unmap_bytes,
    );

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try analyzer.writeSummaryJsonl(
        &output.writer,
        .{ .layer = .physical },
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "\"live_mapped_bytes\":8192",
    ) != null);
}

test "physical advice records success and failure without changing mapped bytes" {
    const events =
        "{\"v\":3,\"kind\":\"map\",\"allocator_id\":2," ++
        "\"address\":4096,\"len\":4096,\"layer\":\"physical_page\"}\n" ++
        "{\"v\":3,\"kind\":\"advise\",\"allocator_id\":2," ++
        "\"address\":4096,\"len\":4096,\"layer\":\"physical_page\"}\n" ++
        "{\"v\":3,\"kind\":\"advise\",\"allocator_id\":2," ++
        "\"address\":4096,\"len\":4096,\"layer\":\"physical_page\",\"succeeded\":false}\n";
    var analyzer = Analyzer.initForLayer(std.testing.allocator, .physical);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(events);
    try std.testing.expectEqual(@as(u64, 1), analyzer.physical.advises);
    try std.testing.expectEqual(@as(u64, 1), analyzer.physical.failed_advises);
    try std.testing.expectEqual(@as(u64, 1), analyzer.physical.maps);
    try std.testing.expectEqual(@as(usize, 4096), analyzer.physical.live_mapped_bytes);
    try std.testing.expectEqual(@as(usize, 4096), analyzer.physical.high_water_mapped_bytes);
    try std.testing.expectEqual(@as(usize, 1), analyzer.mappings.count());
}
