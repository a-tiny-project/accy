const std = @import("std");
const observe = @import("alloc_observe");
const pretty_json = @import("pretty").json;
const sys = @import("sys");
const coverage_mod = @import("coverage.zig");
const event_mod = @import("event.zig");
const stack_mod = @import("stack/root.zig");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Event = event_mod.Event;
const layer_count = std.meta.fieldNames(event_mod.Layer).len;
const record_index_none = std.math.maxInt(u32);
const anomaly_site_capacity_max = 4096;
pub const request_site_capacity_max: u16 = 16 * 1024;
const observation_producer_floor_pending = std.math.maxInt(u64);

const OperationContext = struct {
    layer: event_mod.Layer = .backing_boundary,
    operation_id: u64 = 0,
    parent_operation_id: u64 = 0,
    producer_id: u64 = 0,
    producer: observe.Producer = .boundary,
    generation: u64 = 0,
    owner_cookie: usize = 0,
};

const ObservedAllocatorKey = struct {
    producer_id: u64,
    producer: observe.Producer,
};

const root_scope_id: u32 = 0;
const root_label_id: u32 = 0;

pub const Config = struct {
    record_events: bool = false,
    event_writer: ?*std.Io.Writer = null,
    allocation_attribution: stack_mod.Attribution = .return_address,
    stack_frame_limit: u16 = 256,
    anomaly_site_capacity: u16 = 256,
    request_site_capacity: u16 = 4096,
    capture_executable_identity: bool = false,
    static_coverage: coverage_mod.StaticEvidence = .{},
};

pub const SummaryOptions = struct {
    top: usize = 24,
    min_live_bytes: usize = 0,
    include_zero_live: bool = false,
    layer: event_mod.Layer = .backing_boundary,
};

pub const Retention = enum {
    releases_freed_memory,
    retains_freed_memory,
};

pub const Snapshot = struct {
    seq: u64,
    allocations: u64,
    frees: u64,
    live_allocations: usize,
    allocated_bytes: usize,
    freed_bytes: usize,
    live_bytes: usize,
    high_water_live_bytes: usize,
    retained_bytes: usize,
    high_water_retained_bytes: usize,
    completed_lifetimes: u64,
    lifetime_total_events: u64,
    lifetime_max_events: u64,
};

pub const Difference = struct {
    allocations: u64,
    frees: u64,
    live_allocations: isize,
    allocated_bytes: usize,
    freed_bytes: usize,
    live_bytes: isize,
    high_water_live_bytes: usize,
    retained_bytes: isize,
    high_water_retained_bytes: usize,
    completed_lifetimes: u64,
    lifetime_total_events: u64,
    lifetime_max_events: u64,
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

    fn snapshot(self: Counters, seq: u64) Snapshot {
        return .{
            .seq = seq,
            .allocations = self.allocations,
            .frees = self.frees,
            .live_allocations = self.live_allocations,
            .allocated_bytes = self.allocated_bytes,
            .freed_bytes = self.freed_bytes,
            .live_bytes = self.live_bytes,
            .high_water_live_bytes = self.high_water_live_bytes,
            .retained_bytes = self.retained_bytes,
            .high_water_retained_bytes = self.high_water_retained_bytes,
            .completed_lifetimes = self.completed_lifetimes,
            .lifetime_total_events = self.lifetime_total_events,
            .lifetime_max_events = self.lifetime_max_events,
        };
    }
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
};

const ScopeNode = struct {
    parent: u32,
    label_id: u32,
    path: ?[]u8 = null,
    counters: [layer_count]ScopeCounters = @splat(.{}),
};

const Label = struct {
    text: []const u8,
};

const AllocatorState = struct {
    label_id: u32,
    retention: Retention,
    layer: event_mod.Layer,
    counters: Counters = .{},
    producer_id: u64 = 0,
    producer: observe.Producer = .boundary,
    owner_cookie: usize = 0,
    generation: u64 = 0,
    active_head: u32 = record_index_none,
    prefix_complete: bool = true,
    lifecycle_instrumented: bool = false,
    terminal: bool = false,
    observation_floor_pending: bool = false,
};

const ChildKey = struct {
    parent: u32,
    label_id: u32,
};

const AllocationRecord = struct {
    allocation_id: u64,
    allocator_id: u32,
    address: usize,
    len: usize,
    alignment: Alignment,
    scope_id: u32,
    return_address: usize,
    stack_id: u32,
    allocation_seq: u64,
    layer: event_mod.Layer,
    generation: u64,
    previous_active: u32 = record_index_none,
    next_active: u32 = record_index_none,
    next_free: u32 = record_index_none,
    active: bool = true,
};

const AllocationKey = struct {
    allocator_id: u32,
    address: usize,
};

const ScopeSummary = struct {
    scope_id: u32,
    path: []u8,
    counters: ScopeCounters,
};

const LiveSiteKey = struct {
    allocator_id: u32,
    scope_id: u32,
    return_address: usize,
};

const LiveSiteSummary = struct {
    key: LiveSiteKey,
    live_allocations: usize,
    live_bytes: usize,
};

const AnomalyReason = enum {
    duplicate_current_address,
    unknown_pre_observation,
    unknown_current_generation,
    stale_generation,
    generation_gap,
    owner_cookie_mismatch,
    length_mismatch,
    alignment_mismatch,
    operation_after_terminal,
};

const AnomalyKey = struct {
    reason: AnomalyReason,
    operation: observe.Operation,
    layer: event_mod.Layer,
    producer_id: u64,
    producer: observe.Producer,
    generation: u64,
    scope_id: u32,
    return_address: usize,
    old_len: usize,
    new_len: usize,
    succeeded: bool,
};

const AnomalySite = struct {
    key: AnomalyKey,
    first_address: usize,
    occurrences: u64,
};

const RequestSiteKey = struct {
    producer_id: u64,
    producer: observe.Producer,
    operation: observe.Operation,
    scope_id: u32,
    return_address: usize,
    succeeded: bool,
};

const RequestSiteCounters = struct {
    calls: u64 = 0,
    requested_bytes: u64 = 0,
};

const RequestSiteSummary = struct {
    key: RequestSiteKey,
    counters: RequestSiteCounters,
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

const ControlAllocatorContext = struct {
    backing: Allocator,
    epoch_active: std.atomic.Value(bool) = .init(false),
    operations: std.atomic.Value(u64) = .init(0),

    fn allocator(self: *@This()) Allocator {
        return .{
            .ptr = self,
            .vtable = &ControlAllocatorContext.vtable,
        };
    }

    fn setEpochActive(self: *@This(), active: bool) void {
        self.epoch_active.store(active, .release);
    }

    fn note(self: *@This()) void {
        if (!self.epoch_active.load(.acquire)) return;
        _ = self.operations.fetchAdd(1, .monotonic);
    }

    fn operationCount(self: *const @This()) u64 {
        return self.operations.load(.acquire);
    }

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.note();
        var allocation_suppression = observe.suppress();
        defer allocation_suppression.deinit();
        var memory_suppression = sys.memory.observe.suppress();
        defer memory_suppression.deinit();
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn rawResize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.note();
        var allocation_suppression = observe.suppress();
        defer allocation_suppression.deinit();
        var memory_suppression = sys.memory.observe.suppress();
        defer memory_suppression.deinit();
        return self.backing.rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.note();
        var allocation_suppression = observe.suppress();
        defer allocation_suppression.deinit();
        var memory_suppression = sys.memory.observe.suppress();
        defer memory_suppression.deinit();
        return self.backing.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        return_address: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.note();
        var allocation_suppression = observe.suppress();
        defer allocation_suppression.deinit();
        var memory_suppression = sys.memory.observe.suppress();
        defer memory_suppression.deinit();
        self.backing.rawFree(memory, alignment, return_address);
    }

    const vtable: Allocator.VTable = .{
        .alloc = ControlAllocatorContext.rawAlloc,
        .resize = ControlAllocatorContext.rawResize,
        .remap = ControlAllocatorContext.rawRemap,
        .free = ControlAllocatorContext.rawFree,
    };
};

pub const Scope = struct {
    tracer: *Tracer,
    previous: u32,
    scope_id: u32,
    active: bool = true,

    pub fn exit(self: *Scope) void {
        if (!self.active) return;
        self.tracer.exitScope(self.scope_id, self.previous);
        self.active = false;
    }
};

pub const OwnedObservation = struct {
    tracer: *Tracer,
    session: observe.Session,
    memory_session: sys.memory.observe.Session,
    active: bool = true,

    pub fn stop(self: *OwnedObservation) void {
        if (!self.active) return;
        self.memory_session.deinit();
        self.session.deinit();
        std.debug.assert(self.tracer.observer_active);
        self.tracer.control_context.setEpochActive(false);
        self.tracer.observer_active = false;
        self.active = false;
    }
};

pub const TracingAllocatorOptions = struct {
    name: []const u8 = "allocator",
    retention: Retention = .releases_freed_memory,
};

pub const TracingAllocator = struct {
    tracer: *Tracer,
    backing: Allocator,
    allocator_id: u32,

    pub fn init(
        tracer: *Tracer,
        backing: Allocator,
        options: TracingAllocatorOptions,
    ) !TracingAllocator {
        return .{
            .tracer = tracer,
            .backing = backing,
            .allocator_id = try tracer.registerAllocator(options.name, options.retention),
        };
    }

    pub fn allocator(self: *TracingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

pub const Tracer = struct {
    control_allocator: Allocator,
    control_context: *ControlAllocatorContext,
    config: Config,
    labels: std.ArrayListUnmanaged(Label) = .empty,
    label_ids: std.StringHashMapUnmanaged(u32) = .{},
    scopes: std.ArrayListUnmanaged(ScopeNode) = .empty,
    scope_children: std.AutoHashMapUnmanaged(ChildKey, u32) = .{},
    allocators: std.ArrayListUnmanaged(AllocatorState) = .empty,
    observed_allocators: std.AutoHashMapUnmanaged(
        ObservedAllocatorKey,
        u32,
    ) = .{},
    allocations: std.AutoHashMapUnmanaged(AllocationKey, u32) = .{},
    allocation_records: std.ArrayListUnmanaged(AllocationRecord) = .empty,
    free_record_head: u32 = record_index_none,
    anomaly_sites: []AnomalySite = &.{},
    anomaly_site_count: usize = 0,
    anomaly_sites_dropped: u64 = 0,
    request_sites: std.AutoHashMapUnmanaged(
        RequestSiteKey,
        RequestSiteCounters,
    ) = .{},
    request_site_unaggregated_calls: u64 = 0,
    request_site_unaggregated_bytes: u64 = 0,
    events: std.ArrayListUnmanaged(Event) = .empty,
    stacks: stack_mod.Interner = .{},
    executable_digest: ?stack_mod.Digest = null,
    coverage: coverage_mod.Manifest = coverage_mod.boundaryManifest(),
    counters: [layer_count]Counters = @splat(.{}),
    current_scope: u32 = root_scope_id,
    next_allocation_id: u64 = 1,
    next_seq: u64 = 1,
    recording_failures: u64 = 0,
    stream_finished: bool = false,
    observer_sink: observe.Sink = undefined,
    memory_observer_sink: sys.memory.observe.Sink = undefined,
    observer_active: bool = false,
    observation_producer_floor: u64 = 0,
    physical_allocator_id: ?u32 = null,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(control_allocator: Allocator, config: Config) !Tracer {
        if (config.anomaly_site_capacity > anomaly_site_capacity_max) {
            return error.AnomalySiteCapacityTooLarge;
        }
        if (config.request_site_capacity > request_site_capacity_max) {
            return error.RequestSiteCapacityTooLarge;
        }
        if (config.allocation_attribution == .stack) {
            if (!config.record_events) {
                return error.StackAttributionRequiresEventRecording;
            }
            try stack_mod.capture.validateFrameLimit(config.stack_frame_limit);
            if (!stack_mod.capture.supportsCapture()) {
                return error.StackCaptureUnsupported;
            }
        }
        const control_context = try control_allocator.create(
            ControlAllocatorContext,
        );
        var control_context_owned = true;
        errdefer {
            if (control_context_owned) {
                control_allocator.destroy(control_context);
            }
        }
        control_context.* = .{ .backing = control_allocator };
        var tracer: Tracer = .{
            .control_allocator = control_context.allocator(),
            .control_context = control_context,
            .config = config,
        };
        control_context_owned = false;
        errdefer {
            tracer.stream_finished = true;
            tracer.deinit();
        }
        tracer.anomaly_sites = try tracer.control_allocator.alloc(
            AnomalySite,
            config.anomaly_site_capacity,
        );
        try tracer.request_sites.ensureTotalCapacity(
            tracer.control_allocator,
            config.request_site_capacity,
        );
        if (config.allocation_attribution == .stack or
            config.capture_executable_identity)
        {
            tracer.executable_digest = try stack_mod.identity.runningDigest();
        }
        try tracer.bootstrapRoot();
        if (config.event_writer) |writer| {
            if (tracer.executable_digest) |digest| {
                try stack_mod.identity.writeMetadata(writer, digest);
            }
        }
        if (config.record_events) try tracer.appendEventLocked(.{ .kind = .trace_start });
        return tracer;
    }

    pub fn deinit(self: *Tracer) void {
        std.debug.assert(!self.observer_active);
        if (self.config.event_writer != null) {
            std.debug.assert(self.stream_finished);
        }
        for (self.labels.items) |label| self.control_allocator.free(label.text);
        for (self.scopes.items) |scope| if (scope.path) |path| self.control_allocator.free(path);
        self.labels.deinit(self.control_allocator);
        self.label_ids.deinit(self.control_allocator);
        self.scopes.deinit(self.control_allocator);
        self.scope_children.deinit(self.control_allocator);
        self.allocators.deinit(self.control_allocator);
        self.observed_allocators.deinit(self.control_allocator);
        self.allocations.deinit(self.control_allocator);
        self.allocation_records.deinit(self.control_allocator);
        self.control_allocator.free(self.anomaly_sites);
        self.request_sites.deinit(self.control_allocator);
        self.events.deinit(self.control_allocator);
        self.stacks.deinit(self.control_allocator);
        const control_context = self.control_context;
        const control_backing = control_context.backing;
        self.* = undefined;
        control_backing.destroy(control_context);
    }

    pub fn tracedAllocator(self: *Tracer, backing: Allocator, name: []const u8) !TracingAllocator {
        return try TracingAllocator.init(self, backing, .{ .name = name });
    }

    pub fn tracedAllocatorWithOptions(self: *Tracer, backing: Allocator, options: TracingAllocatorOptions) !TracingAllocator {
        return try TracingAllocator.init(self, backing, options);
    }

    pub fn observeOwnedAllocatorsIfAvailable(
        self: *Tracer,
    ) !?OwnedObservation {
        if (comptime !observe.enabled) return null;
        return try self.observeOwnedAllocators();
    }

    pub fn observeOwnedAllocators(self: *Tracer) !OwnedObservation {
        if (comptime !observe.enabled) {
            return error.AllocatorObservationNotCompiled;
        }
        if (self.observer_active) return error.AllocatorObservationAlreadyActive;
        _ = sys.memory.pageSize();
        self.observer_sink = .{
            .context = self,
            .record = recordOwnedOperation,
        };
        const previous_producer_floor =
            self.markObservationProducerFloorPending();
        var session = observe.install(&self.observer_sink) catch |err| {
            self.restoreObservationProducerFloor(previous_producer_floor);
            return err;
        };
        errdefer session.deinit();
        self.reconcileObservationProducerFloor(
            session.producerIdFloor(),
        );
        self.memory_observer_sink = .{
            .context = self,
            .record = recordPhysicalOperation,
        };
        const memory_session = try sys.memory.observe.install(
            &self.memory_observer_sink,
        );
        self.observer_active = true;
        self.control_context.setEpochActive(true);
        self.coverage = coverage_mod.processManifest(
            self.config.static_coverage,
        );
        return .{
            .tracer = self,
            .session = session,
            .memory_session = memory_session,
        };
    }

    pub fn enter(self: *Tracer, label: []const u8) !Scope {
        self.lock();
        defer self.unlock();

        const label_id = try self.internLabelLocked(label);
        const previous = self.current_scope;
        const scope_id = try self.scopeChildLocked(previous, label_id);
        self.current_scope = scope_id;
        try self.appendEventLocked(.{
            .kind = .scope_enter,
            .scope_id = scope_id,
            .label_id = label_id,
            .live_bytes = self.countersForLayer(.backing_boundary).live_bytes,
        });
        return .{
            .tracer = self,
            .previous = previous,
            .scope_id = scope_id,
        };
    }

    pub fn snapshot(self: *Tracer) Snapshot {
        return self.snapshotLayer(.backing_boundary);
    }

    pub fn snapshotLayer(
        self: *Tracer,
        layer: event_mod.Layer,
    ) Snapshot {
        self.lock();
        defer self.unlock();
        return self.countersForLayer(layer).snapshot(self.next_seq - 1);
    }

    pub fn diff(self: *Tracer, before: Snapshot) Difference {
        return self.diffLayer(.backing_boundary, before);
    }

    pub fn diffLayer(
        self: *Tracer,
        layer: event_mod.Layer,
        before: Snapshot,
    ) Difference {
        const after = self.snapshotLayer(layer);
        return snapshotDifference(before, after);
    }

    fn snapshotDifference(before: Snapshot, after: Snapshot) Difference {
        return .{
            .allocations = after.allocations - before.allocations,
            .frees = after.frees - before.frees,
            .live_allocations = signedDiff(after.live_allocations, before.live_allocations),
            .allocated_bytes = after.allocated_bytes - before.allocated_bytes,
            .freed_bytes = after.freed_bytes - before.freed_bytes,
            .live_bytes = signedDiff(after.live_bytes, before.live_bytes),
            .high_water_live_bytes = after.high_water_live_bytes,
            .retained_bytes = signedDiff(after.retained_bytes, before.retained_bytes),
            .high_water_retained_bytes = after.high_water_retained_bytes,
            .completed_lifetimes = after.completed_lifetimes - before.completed_lifetimes,
            .lifetime_total_events = after.lifetime_total_events - before.lifetime_total_events,
            .lifetime_max_events = after.lifetime_max_events,
        };
    }

    pub fn observerControlOperations(self: *const Tracer) u64 {
        return self.control_context.operationCount();
    }

    pub fn writeSummary(self: *Tracer, writer: *std.Io.Writer, options: SummaryOptions) !void {
        self.lock();
        defer self.unlock();
        const counters = self.countersForLayer(options.layer);

        var summaries = std.ArrayListUnmanaged(ScopeSummary).empty;
        defer {
            for (summaries.items) |summary| self.control_allocator.free(summary.path);
            summaries.deinit(self.control_allocator);
        }

        for (self.scopes.items, 0..) |scope, index| {
            const scope_counters = scope.counters[@backingInt(options.layer)];
            if (index == root_scope_id and scope_counters.allocations == 0) continue;
            if (!options.include_zero_live and scope_counters.live_bytes == 0 and scope_counters.high_water_live_bytes == 0) continue;
            if (scope_counters.live_bytes < options.min_live_bytes and scope_counters.high_water_live_bytes < options.min_live_bytes) continue;
            try summaries.append(self.control_allocator, .{
                .scope_id = @intCast(index),
                .path = try self.scopePathAllocLocked(@intCast(index)),
                .counters = scope_counters,
            });
        }
        std.mem.sort(ScopeSummary, summaries.items, {}, scopeSummaryGreaterThan);

        var request_site_summaries =
            std.ArrayListUnmanaged(RequestSiteSummary).empty;
        defer request_site_summaries.deinit(self.control_allocator);
        if (options.layer == .logical_allocator) {
            try request_site_summaries.ensureTotalCapacity(
                self.control_allocator,
                self.request_sites.count(),
            );
            var request_sites = self.request_sites.iterator();
            while (request_sites.next()) |entry| {
                request_site_summaries.appendAssumeCapacity(.{
                    .key = entry.key_ptr.*,
                    .counters = entry.value_ptr.*,
                });
            }
            std.mem.sort(
                RequestSiteSummary,
                request_site_summaries.items,
                {},
                requestSiteSummaryGreaterThan,
            );
        }
        const request_site_limit = @min(
            options.top,
            request_site_summaries.items.len,
        );
        var request_site_omitted_calls =
            self.request_site_unaggregated_calls;
        var request_site_omitted_bytes =
            self.request_site_unaggregated_bytes;
        for (request_site_summaries.items[request_site_limit..]) |site| {
            request_site_omitted_calls +|= site.counters.calls;
            request_site_omitted_bytes +|= site.counters.requested_bytes;
        }

        if (options.layer == .logical_allocator) {
            try writer.print(
                "memtrace layer={s} allocations={d} frees={d} " ++
                    "open_requests={d} requested_bytes={d} " ++
                    "explicitly_closed_bytes={d} open_request_bytes={d} " ++
                    "high_water_open_request_bytes={d} " ++
                    "bulk_invalidated_requests={d} bulk_invalidated_bytes={d} " ++
                    "untracked_requests={d} untracked_request_bytes={d}\n",
                .{
                    options.layer.tag(),
                    counters.allocations,
                    counters.frees,
                    counters.live_allocations,
                    counters.allocated_bytes,
                    counters.freed_bytes,
                    counters.live_bytes,
                    counters.high_water_live_bytes,
                    counters.bulk_invalidated_requests,
                    counters.bulk_invalidated_bytes,
                    counters.untracked_requests,
                    counters.untracked_request_bytes,
                },
            );
            const coverage = self.lifecycleCoverageLocked();
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
                    counters.lifecycle_events,
                },
            );
            try writer.print(
                "memtrace request_sites capacity={d} groups={d} displayed={d} " ++
                    "unaggregated_calls={d} unaggregated_bytes={d} " ++
                    "omitted_calls={d} omitted_bytes={d} exact={s}\n",
                .{
                    self.config.request_site_capacity,
                    self.request_sites.count(),
                    request_site_limit,
                    self.request_site_unaggregated_calls,
                    self.request_site_unaggregated_bytes,
                    request_site_omitted_calls,
                    request_site_omitted_bytes,
                    if (request_site_omitted_calls == 0) "true" else "false",
                },
            );
        } else {
            try writer.print(
                "memtrace layer={s} allocations={d} frees={d} " ++
                    "live_allocations={d} allocated_bytes={d} " ++
                    "freed_bytes={d} live_bytes={d} " ++
                    "high_water_live_bytes={d}\n",
                .{
                    options.layer.tag(),
                    counters.allocations,
                    counters.frees,
                    counters.live_allocations,
                    counters.allocated_bytes,
                    counters.freed_bytes,
                    counters.live_bytes,
                    counters.high_water_live_bytes,
                },
            );
            try writer.print(
                "memtrace retained_bytes={d} high_water_retained_bytes={d}\n",
                .{
                    counters.retained_bytes,
                    counters.high_water_retained_bytes,
                },
            );
        }
        try writer.print(
            "memtrace lifetimes completed={d} total_events={d} mean_events={d} max_events={d}\n",
            .{
                counters.completed_lifetimes,
                counters.lifetime_total_events,
                meanLifetimeEvents(counters.*),
                counters.lifetime_max_events,
            },
        );
        if (counters.failed_allocations != 0 or
            counters.failed_resizes != 0 or
            counters.failed_remaps != 0 or
            counters.unmatched_frees != 0 or
            counters.unmatched_resizes != 0 or
            counters.unmatched_remaps != 0 or
            self.recording_failures != 0)
        {
            try writer.print(
                "memtrace anomalies failed_allocations={d} failed_resizes={d} " ++
                    "failed_remaps={d} unmatched_frees={d} unmatched_resizes={d} " ++
                    "unmatched_remaps={d} " ++
                    "recording_failures={d}\n",
                .{
                    counters.failed_allocations,
                    counters.failed_resizes,
                    counters.failed_remaps,
                    counters.unmatched_frees,
                    counters.unmatched_resizes,
                    counters.unmatched_remaps,
                    self.recording_failures,
                },
            );
        }
        const limit = @min(options.top, summaries.items.len);
        for (summaries.items[0..limit]) |summary| {
            if (options.layer == .logical_allocator) {
                try writer.print(
                    "{s} open_request_bytes={d} " ++
                        "high_water_open_request_bytes={d} requested_bytes={d} " ++
                        "explicitly_closed_bytes={d} allocations={d} frees={d} " ++
                        "open_requests={d} bulk_invalidated_requests={d} " ++
                        "bulk_invalidated_bytes={d} untracked_requests={d} " ++
                        "untracked_request_bytes={d} completed_lifetimes={d} " ++
                        "lifetime_total_events={d} lifetime_mean_events={d} " ++
                        "lifetime_max_events={d}\n",
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
                        summary.counters.completed_lifetimes,
                        summary.counters.lifetime_total_events,
                        meanLifetimeEvents(summary.counters),
                        summary.counters.lifetime_max_events,
                    },
                );
            } else {
                try writer.print(
                    "{s} retained_bytes={d} high_water_retained_bytes={d} " ++
                        "live_bytes={d} high_water_live_bytes={d} " ++
                        "allocated_bytes={d} freed_bytes={d} allocations={d} " ++
                        "frees={d} live_allocations={d} completed_lifetimes={d} " ++
                        "lifetime_total_events={d} lifetime_mean_events={d} " ++
                        "lifetime_max_events={d}\n",
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
                    },
                );
            }
        }
        for (request_site_summaries.items[0..request_site_limit]) |site| {
            const path = try self.scopePathAllocLocked(site.key.scope_id);
            defer self.control_allocator.free(path);
            try writer.print(
                "request_site producer_id={d} producer={s} operation={s} " ++
                    "scope={s} return_address=0x{x} succeeded={s} calls={d} " ++
                    "requested_bytes={d}\n",
                .{
                    site.key.producer_id,
                    @tagName(site.key.producer),
                    @tagName(site.key.operation),
                    path,
                    site.key.return_address,
                    if (site.key.succeeded) "true" else "false",
                    site.counters.calls,
                    site.counters.requested_bytes,
                },
            );
        }
    }

    pub fn writeSummaryJsonl(
        self: *Tracer,
        writer: *std.Io.Writer,
        options: SummaryOptions,
    ) !void {
        self.lock();
        defer self.unlock();
        const counters = self.countersForLayer(options.layer);

        var summaries = std.ArrayListUnmanaged(ScopeSummary).empty;
        defer {
            for (summaries.items) |summary| self.control_allocator.free(summary.path);
            summaries.deinit(self.control_allocator);
        }

        for (self.scopes.items, 0..) |scope, index| {
            const scope_counters = scope.counters[@backingInt(options.layer)];
            if (index == root_scope_id and scope_counters.allocations == 0) continue;
            if (!options.include_zero_live and
                scope_counters.live_bytes == 0 and
                scope_counters.high_water_live_bytes == 0)
            {
                continue;
            }
            if (scope_counters.live_bytes < options.min_live_bytes and
                scope_counters.high_water_live_bytes < options.min_live_bytes)
            {
                continue;
            }
            try summaries.append(self.control_allocator, .{
                .scope_id = @intCast(index),
                .path = try self.scopePathAllocLocked(@intCast(index)),
                .counters = scope_counters,
            });
        }
        std.mem.sort(ScopeSummary, summaries.items, {}, scopeSummaryGreaterThan);

        var request_site_summaries =
            std.ArrayListUnmanaged(RequestSiteSummary).empty;
        defer request_site_summaries.deinit(self.control_allocator);
        if (options.layer == .logical_allocator) {
            try request_site_summaries.ensureTotalCapacity(
                self.control_allocator,
                self.request_sites.count(),
            );
            var request_sites = self.request_sites.iterator();
            while (request_sites.next()) |entry| {
                request_site_summaries.appendAssumeCapacity(.{
                    .key = entry.key_ptr.*,
                    .counters = entry.value_ptr.*,
                });
            }
            std.mem.sort(
                RequestSiteSummary,
                request_site_summaries.items,
                {},
                requestSiteSummaryGreaterThan,
            );
        }
        const request_site_limit = @min(
            options.top,
            request_site_summaries.items.len,
        );
        var request_site_omitted_calls =
            self.request_site_unaggregated_calls;
        var request_site_omitted_bytes =
            self.request_site_unaggregated_bytes;
        for (request_site_summaries.items[request_site_limit..]) |site| {
            request_site_omitted_calls +|= site.counters.calls;
            request_site_omitted_bytes +|= site.counters.requested_bytes;
        }

        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("kind", "summary");
        try object.field("layer", options.layer.tag());
        try object.field("allocations", counters.allocations);
        try object.field("frees", counters.frees);
        try object.field("resizes", counters.resizes);
        try object.field("remaps", counters.remaps);
        try object.field("allocated_bytes", counters.allocated_bytes);
        if (options.layer == .logical_allocator) {
            try object.field("open_requests", counters.live_allocations);
            try object.field("requested_bytes", counters.allocated_bytes);
            try object.field(
                "explicitly_closed_bytes",
                counters.freed_bytes,
            );
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
            try object.field("lifecycle_events", counters.lifecycle_events);
            const coverage = self.lifecycleCoverageLocked();
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
            try object.field(
                "request_site_capacity",
                self.config.request_site_capacity,
            );
            try object.field("request_site_groups", self.request_sites.count());
            try object.field(
                "request_site_groups_displayed",
                request_site_limit,
            );
            try object.field(
                "request_site_unaggregated_calls",
                self.request_site_unaggregated_calls,
            );
            try object.field(
                "request_site_unaggregated_bytes",
                self.request_site_unaggregated_bytes,
            );
            try object.field(
                "request_site_omitted_calls",
                request_site_omitted_calls,
            );
            try object.field(
                "request_site_omitted_bytes",
                request_site_omitted_bytes,
            );
            try object.field(
                "request_site_attribution_exact",
                request_site_omitted_calls == 0,
            );
        } else {
            try object.field("live_allocations", counters.live_allocations);
            try object.field("freed_bytes", counters.freed_bytes);
            try object.field("live_bytes", counters.live_bytes);
            try object.field(
                "high_water_live_bytes",
                counters.high_water_live_bytes,
            );
            try object.field("retained_bytes", counters.retained_bytes);
            try object.field(
                "high_water_retained_bytes",
                counters.high_water_retained_bytes,
            );
        }
        try object.field("completed_lifetimes", counters.completed_lifetimes);
        try object.field("lifetime_total_events", counters.lifetime_total_events);
        try object.field("lifetime_mean_events", meanLifetimeEvents(counters.*));
        try object.field("lifetime_max_events", counters.lifetime_max_events);
        try object.field("failed_allocations", counters.failed_allocations);
        try object.field("failed_resizes", counters.failed_resizes);
        try object.field("failed_remaps", counters.failed_remaps);
        try object.field("unmatched_frees", counters.unmatched_frees);
        try object.field("unmatched_resizes", counters.unmatched_resizes);
        try object.field("unmatched_remaps", counters.unmatched_remaps);
        try object.field("anomaly_sites", self.anomaly_site_count);
        try object.field(
            "anomaly_sites_dropped",
            self.anomaly_sites_dropped,
        );
        try object.field(
            "anomaly_attribution_exact",
            self.anomaly_sites_dropped == 0,
        );
        try object.field("recording_failures", self.recording_failures);
        try object.endLine();
        const limit = @min(options.top, summaries.items.len);
        for (summaries.items[0..limit]) |summary| {
            var row_stream = pretty_json.Writer.init(writer, .minified);
            const row = try row_stream.object();
            try row.field("kind", "scope");
            try row.field("layer", options.layer.tag());
            try row.field("scope", summary.path);
            try writeCounterFields(row, summary.counters, options.layer);
            try row.endLine();
        }
        for (request_site_summaries.items[0..request_site_limit]) |site| {
            const path = try self.scopePathAllocLocked(site.key.scope_id);
            defer self.control_allocator.free(path);
            var row_stream = pretty_json.Writer.init(writer, .minified);
            const row = try row_stream.object();
            try row.field("kind", "request_site");
            try row.field("layer", event_mod.Layer.logical_allocator.tag());
            try row.field("producer_id", site.key.producer_id);
            try row.field("producer", @tagName(site.key.producer));
            try row.field("operation", @tagName(site.key.operation));
            try row.field("scope", path);
            try row.field("return_address", site.key.return_address);
            try row.field("succeeded", site.key.succeeded);
            try row.field("calls", site.counters.calls);
            try row.field("requested_bytes", site.counters.requested_bytes);
            try row.endLine();
        }

        var site_counts = std.AutoHashMapUnmanaged(
            LiveSiteKey,
            LiveSiteSummary,
        ).empty;
        defer site_counts.deinit(self.control_allocator);
        var live_allocations = self.allocations.valueIterator();
        while (live_allocations.next()) |record_index| {
            const allocation =
                &self.allocation_records.items[record_index.*];
            std.debug.assert(allocation.active);
            if (allocation.layer != options.layer) continue;
            const key = LiveSiteKey{
                .allocator_id = allocation.allocator_id,
                .scope_id = allocation.scope_id,
                .return_address = allocation.return_address,
            };
            const entry = try site_counts.getOrPut(self.control_allocator, key);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{
                    .key = key,
                    .live_allocations = 0,
                    .live_bytes = 0,
                };
            }
            entry.value_ptr.live_allocations += 1;
            entry.value_ptr.live_bytes += allocation.len;
        }
        var live_sites = std.ArrayListUnmanaged(LiveSiteSummary).empty;
        defer live_sites.deinit(self.control_allocator);
        try live_sites.ensureTotalCapacity(
            self.control_allocator,
            site_counts.count(),
        );
        var sites = site_counts.valueIterator();
        while (sites.next()) |site| live_sites.appendAssumeCapacity(site.*);
        std.mem.sort(
            LiveSiteSummary,
            live_sites.items,
            {},
            liveSiteSummaryGreaterThan,
        );
        const live_site_limit = @min(options.top, live_sites.items.len);
        for (live_sites.items[0..live_site_limit]) |site| {
            const path = try self.scopePathAllocLocked(site.key.scope_id);
            defer self.control_allocator.free(path);
            const allocator_label_id =
                self.allocators.items[site.key.allocator_id].label_id;
            var row_stream = pretty_json.Writer.init(writer, .minified);
            const row = try row_stream.object();
            try row.field(
                "kind",
                if (options.layer == .logical_allocator)
                    "open_request_site"
                else
                    "live_site",
            );
            try row.field("layer", options.layer.tag());
            try row.field("allocator", self.labels.items[allocator_label_id].text);
            try row.field("scope", path);
            try row.field("return_address", site.key.return_address);
            if (options.layer == .logical_allocator) {
                try row.field("open_requests", site.live_allocations);
                try row.field("open_request_bytes", site.live_bytes);
            } else {
                try row.field("live_allocations", site.live_allocations);
                try row.field("live_bytes", site.live_bytes);
            }
            try row.endLine();
        }
        for (self.anomaly_sites[0..self.anomaly_site_count]) |site| {
            if (site.key.layer != options.layer) continue;
            const path = try self.scopePathAllocLocked(site.key.scope_id);
            defer self.control_allocator.free(path);
            var row_stream = pretty_json.Writer.init(writer, .minified);
            const row = try row_stream.object();
            try row.field("kind", "anomaly_site");
            try row.field("layer", site.key.layer.tag());
            try row.field("reason", @tagName(site.key.reason));
            try row.field("operation", @tagName(site.key.operation));
            try row.field("producer_id", site.key.producer_id);
            try row.field("producer", @tagName(site.key.producer));
            try row.field("generation", site.key.generation);
            try row.field("scope", path);
            try row.field("return_address", site.key.return_address);
            try row.field("old_len", site.key.old_len);
            try row.field("new_len", site.key.new_len);
            try row.field("succeeded", site.key.succeeded);
            try row.field("first_address", site.first_address);
            try row.field("occurrences", site.occurrences);
            try row.endLine();
        }
    }

    pub fn writeEventsJsonl(self: *Tracer, writer: *std.Io.Writer) !void {
        self.lock();
        defer self.unlock();
        if (!self.config.record_events or self.config.event_writer != null) {
            return error.EventsNotRetained;
        }
        if (self.executable_digest) |digest| {
            try stack_mod.identity.writeMetadata(writer, digest);
        }
        try coverage_mod.writeMetadata(writer, self.coverageManifest());
        for (self.stacks.definitions.items, 0..) |definition, index| {
            try stack_mod.capture.writeDefinition(
                writer,
                @intCast(index + 1),
                definition,
            );
        }
        for (self.events.items) |recorded| {
            const label_text = if ((recorded.kind == .allocator or
                recorded.kind == .scope_enter) and
                recorded.label_id < self.labels.items.len)
                self.labels.items[recorded.label_id].text
            else
                null;
            const scope_text = if (recorded.kind == .scope_enter and
                recorded.scope_id < self.scopes.items.len)
                try self.scopePathCachedLocked(recorded.scope_id)
            else
                null;
            try recorded.writeJsonLine(writer, label_text, scope_text);
        }
        try (Event{
            .seq = self.next_seq,
            .kind = .trace_stop,
            .live_bytes = self.countersForLayer(.backing_boundary).live_bytes,
            .recording_failures = self.recording_failures,
        }).writeJsonLine(writer, null, null);
    }

    pub fn finishEvents(self: *Tracer) !void {
        self.lock();
        defer self.unlock();
        if (self.config.event_writer == null) return error.EventsNotStreamed;
        if (self.stream_finished) return error.EventStreamAlreadyFinished;
        try coverage_mod.writeMetadata(
            self.config.event_writer.?,
            self.coverageManifest(),
        );
        try self.appendEventLocked(.{
            .kind = .trace_stop,
            .live_bytes = self.countersForLayer(.backing_boundary).live_bytes,
            .recording_failures = self.recording_failures,
        });
        self.stream_finished = true;
    }

    pub fn writeEventsBundlePath(self: *Tracer, path: []const u8) !void {
        try self.writeExecutableArtifactPath(path);
        var file = try sys.fs.createFile(path, .{ .truncate = true });
        defer sys.fs.closeHandle(file);
        var buffer: [64 * 1024]u8 = undefined;
        var output = file.writer(sys.fs.debugIo(), &buffer);
        try self.writeEventsJsonl(&output.interface);
        try output.interface.flush();
    }

    pub fn writeExecutableArtifactPath(
        self: *Tracer,
        events_path: []const u8,
    ) !void {
        if (std.fs.path.dirname(events_path)) |parent| {
            if (parent.len != 0) try sys.fs.createDirPath(parent);
        }
        if (self.executable_digest) |digest| {
            const artifact_path = try stack_mod.identity.artifactPathAlloc(
                self.control_allocator,
                events_path,
            );
            defer self.control_allocator.free(artifact_path);
            try stack_mod.identity.copyRunningExecutable(artifact_path, digest);
        }
    }

    pub fn writeExecutableMetadata(
        self: *Tracer,
        writer: *std.Io.Writer,
    ) !void {
        self.lock();
        defer self.unlock();
        const digest = self.executable_digest orelse
            return error.ExecutableIdentityNotCaptured;
        try stack_mod.identity.writeMetadata(writer, digest);
    }

    fn registerAllocator(self: *Tracer, name: []const u8, retention: Retention) !u32 {
        self.lock();
        defer self.unlock();
        const label_id = try self.internLabelLocked(name);
        const allocator_id: u32 = @intCast(self.allocators.items.len);
        try self.allocators.append(self.control_allocator, .{
            .label_id = label_id,
            .retention = retention,
            .layer = .backing_boundary,
        });
        try self.appendEventLocked(.{
            .kind = .allocator,
            .allocator_id = allocator_id,
            .label_id = label_id,
            .retains_freed_memory = retention == .retains_freed_memory,
            .live_bytes = self.countersForLayer(.backing_boundary).live_bytes,
        });
        return allocator_id;
    }

    fn rawAlloc(
        self: *Tracer,
        backing: Allocator,
        allocator_id: u32,
        len: usize,
        alignment: Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        if (observe.suppressed()) {
            self.noteObserverControlOperation();
            return backing.rawAlloc(len, alignment, ret_addr);
        }
        var stack_storage: [stack_mod.max_frames_limit]usize = undefined;
        const captured = self.captureOperation(&stack_storage, ret_addr);
        var causal_context = observe.beginContext();
        const operation_context = boundaryOperationContext(causal_context);
        const ptr = backing.rawAlloc(len, alignment, ret_addr) orelse {
            causal_context.finish();
            self.recordAllocationFailure(
                allocator_id,
                len,
                alignment,
                ret_addr,
                captured,
                operation_context,
            ) catch self.markRecordingFailure();
            return null;
        };
        causal_context.finish();
        self.recordAllocation(
            allocator_id,
            ptr,
            len,
            alignment,
            ret_addr,
            captured,
            operation_context,
        ) catch {
            backing.rawFree(ptr[0..len], alignment, ret_addr);
            self.markRecordingFailure();
            return null;
        };
        return ptr;
    }

    fn rawResize(
        self: *Tracer,
        backing: Allocator,
        allocator_id: u32,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        if (observe.suppressed()) {
            self.noteObserverControlOperation();
            return backing.rawResize(memory, alignment, new_len, ret_addr);
        }
        var stack_storage: [stack_mod.max_frames_limit]usize = undefined;
        const captured = self.captureOperation(&stack_storage, ret_addr);
        var causal_context = observe.beginContext();
        const operation_context = boundaryOperationContext(causal_context);
        const succeeded = backing.rawResize(memory, alignment, new_len, ret_addr);
        causal_context.finish();
        self.recordResize(
            allocator_id,
            memory.ptr,
            memory.len,
            new_len,
            alignment,
            ret_addr,
            succeeded,
            captured,
            operation_context,
        ) catch self.markRecordingFailure();
        return succeeded;
    }

    fn rawRemap(
        self: *Tracer,
        backing: Allocator,
        allocator_id: u32,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        if (observe.suppressed()) {
            self.noteObserverControlOperation();
            return backing.rawRemap(memory, alignment, new_len, ret_addr);
        }
        var stack_storage: [stack_mod.max_frames_limit]usize = undefined;
        const captured = self.captureOperation(&stack_storage, ret_addr);
        var causal_context = observe.beginContext();
        const operation_context = boundaryOperationContext(causal_context);
        const ptr = backing.rawRemap(memory, alignment, new_len, ret_addr);
        causal_context.finish();
        self.recordRemap(
            allocator_id,
            memory.ptr,
            ptr,
            memory.len,
            new_len,
            alignment,
            ret_addr,
            captured,
            operation_context,
        ) catch self.markRecordingFailure();
        return ptr;
    }

    fn rawFree(
        self: *Tracer,
        backing: Allocator,
        allocator_id: u32,
        memory: []u8,
        alignment: Alignment,
        ret_addr: usize,
    ) void {
        if (observe.suppressed()) {
            self.noteObserverControlOperation();
            backing.rawFree(memory, alignment, ret_addr);
            return;
        }
        var stack_storage: [stack_mod.max_frames_limit]usize = undefined;
        const captured = self.captureOperation(&stack_storage, ret_addr);
        var causal_context = observe.beginContext();
        const operation_context = boundaryOperationContext(causal_context);
        backing.rawFree(memory, alignment, ret_addr);
        causal_context.finish();
        self.recordFree(
            allocator_id,
            memory.ptr,
            memory.len,
            alignment,
            ret_addr,
            captured,
            operation_context,
        ) catch self.markRecordingFailure();
    }

    fn recordOwnedEvent(
        self: *Tracer,
        observed: observe.Event,
    ) !void {
        std.debug.assert(observed.producer_id != 0);
        std.debug.assert(observed.operation_id != 0);
        const allocator_id = try self.observedAllocatorId(observed);
        const alignment = Alignment.fromByteUnits(observed.alignment);
        const operation_context = OperationContext{
            .layer = .logical_allocator,
            .operation_id = observed.operation_id,
            .parent_operation_id = observed.parent_operation_id,
            .producer_id = observed.producer_id,
            .producer = observed.producer,
            .generation = observed.generation,
            .owner_cookie = observed.owner_cookie,
        };
        if (!self.validateObservedIdentity(
            allocator_id,
            observed,
            operation_context,
        )) return;
        if (observed.operation == .lifecycle) {
            return self.recordLifecycle(
                allocator_id,
                observed,
                operation_context,
            );
        }
        var stack_storage: [stack_mod.max_frames_limit]usize = undefined;
        const captured = self.captureOperation(
            &stack_storage,
            observed.return_address,
        );
        switch (observed.operation) {
            .alloc => {
                if (!observed.succeeded) {
                    return self.recordAllocationFailure(
                        allocator_id,
                        observed.len,
                        alignment,
                        observed.return_address,
                        captured,
                        operation_context,
                    );
                }
                std.debug.assert(observed.address != 0);
                return self.recordAllocation(
                    allocator_id,
                    @ptrFromInt(observed.address),
                    observed.len,
                    alignment,
                    observed.return_address,
                    captured,
                    operation_context,
                );
            },
            .resize => {
                std.debug.assert(observed.old_address != 0);
                return self.recordResize(
                    allocator_id,
                    @ptrFromInt(observed.old_address),
                    observed.old_len,
                    observed.len,
                    alignment,
                    observed.return_address,
                    observed.succeeded,
                    captured,
                    operation_context,
                );
            },
            .remap => {
                std.debug.assert(observed.old_address != 0);
                const new_ptr: ?[*]u8 = if (observed.succeeded)
                    @ptrFromInt(observed.address)
                else
                    null;
                return self.recordRemap(
                    allocator_id,
                    @ptrFromInt(observed.old_address),
                    new_ptr,
                    observed.old_len,
                    observed.len,
                    alignment,
                    observed.return_address,
                    captured,
                    operation_context,
                );
            },
            .free => {
                std.debug.assert(observed.old_address != 0);
                return self.recordFree(
                    allocator_id,
                    @ptrFromInt(observed.old_address),
                    observed.old_len,
                    alignment,
                    observed.return_address,
                    captured,
                    operation_context,
                );
            },
            .lifecycle => unreachable,
        }
    }

    fn recordPhysicalEvent(
        self: *Tracer,
        observed: sys.memory.observe.Event,
        operation_context: OperationContext,
    ) !void {
        const allocator_id = try self.physicalAllocatorId();
        var stack_storage: [stack_mod.max_frames_limit]usize = undefined;
        const captured = self.captureOperation(
            &stack_storage,
            observed.return_address,
        );
        self.lock();
        defer self.unlock();
        const stack_id = try self.internStackLocked(captured);
        try self.appendEventLocked(.{
            .kind = physicalEventKind(observed.operation),
            .allocator_id = allocator_id,
            .scope_id = self.current_scope,
            .label_id = self.scopes.items[self.current_scope].label_id,
            .address = observed.address,
            .old_address = observed.address,
            .len = observed.len,
            .old_len = observed.len,
            .alignment = @intCast(sys.memory.pageSize()),
            .return_address = observed.return_address,
            .stack_id = stack_id,
            .succeeded = observed.succeeded,
            .layer = .physical_page,
            .operation_id = operation_context.operation_id,
            .parent_operation_id = operation_context.parent_operation_id,
            .producer_id = @backingInt(observed.source) + 1,
            .producer = .sys_memory,
        });
    }

    fn observedAllocatorId(
        self: *Tracer,
        observed: observe.Event,
    ) !u32 {
        self.lock();
        defer self.unlock();
        const key = ObservedAllocatorKey{
            .producer_id = observed.producer_id,
            .producer = observed.producer,
        };
        const entry = try self.observed_allocators.getOrPut(
            self.control_allocator,
            key,
        );
        if (entry.found_existing) return entry.value_ptr.*;
        var committed = false;
        errdefer {
            if (!committed) {
                _ = self.observed_allocators.fetchRemove(key);
            }
        }
        const label_id = try self.internLabelLocked(
            @tagName(observed.producer),
        );
        const allocator_id = std.math.cast(
            u32,
            self.allocators.items.len,
        ) orelse return error.OutOfMemory;
        const retention = observedProducerRetention(observed.producer);
        const floor_pending = self.observation_producer_floor ==
            observation_producer_floor_pending;
        const prefix_complete = !floor_pending and
            observed.producer_id >= self.observation_producer_floor;
        try self.allocators.append(self.control_allocator, .{
            .label_id = label_id,
            .retention = retention,
            .layer = .logical_allocator,
            .producer_id = observed.producer_id,
            .producer = observed.producer,
            .owner_cookie = observed.owner_cookie,
            .generation = observed.generation,
            .prefix_complete = prefix_complete,
            .lifecycle_instrumented = observedProducerLifecycleInstrumented(observed.producer),
            .observation_floor_pending = floor_pending,
        });
        entry.value_ptr.* = allocator_id;
        committed = true;
        try self.appendObservedAllocatorEventLocked(allocator_id);
        return allocator_id;
    }

    fn appendObservedAllocatorEventLocked(
        self: *Tracer,
        allocator_id: u32,
    ) !void {
        var suppression = observe.suppress();
        defer suppression.deinit();
        const allocator = self.allocators.items[allocator_id];
        try self.appendEventLocked(.{
            .kind = .allocator,
            .allocator_id = allocator_id,
            .label_id = allocator.label_id,
            .retains_freed_memory = allocator.retention ==
                .retains_freed_memory,
            .live_bytes = self.countersForLayer(.logical_allocator).live_bytes,
            .layer = .logical_allocator,
            .producer_id = allocator.producer_id,
            .producer = allocator.producer,
            .generation = allocator.generation,
            .owner_cookie = allocator.owner_cookie,
            .lifecycle_instrumented = allocator.lifecycle_instrumented,
            .observation_prefix_complete = allocator.prefix_complete,
        });
    }

    fn markObservationProducerFloorPending(self: *Tracer) u64 {
        self.lock();
        defer self.unlock();
        std.debug.assert(
            self.observation_producer_floor !=
                observation_producer_floor_pending,
        );
        const previous = self.observation_producer_floor;
        self.observation_producer_floor =
            observation_producer_floor_pending;
        return previous;
    }

    fn restoreObservationProducerFloor(
        self: *Tracer,
        previous: u64,
    ) void {
        self.lock();
        defer self.unlock();
        std.debug.assert(
            self.observation_producer_floor ==
                observation_producer_floor_pending,
        );
        self.observation_producer_floor = previous;
    }

    fn reconcileObservationProducerFloor(
        self: *Tracer,
        producer_floor: u64,
    ) void {
        self.lock();
        defer self.unlock();
        std.debug.assert(
            self.observation_producer_floor ==
                observation_producer_floor_pending,
        );
        self.observation_producer_floor = producer_floor;
        for (self.allocators.items, 0..) |*allocator, allocator_index| {
            if (!allocator.observation_floor_pending) continue;
            const prefix_was_complete = allocator.prefix_complete;
            allocator.prefix_complete = allocator.prefix_complete or
                allocator.producer_id >= producer_floor;
            allocator.observation_floor_pending = false;
            if (!prefix_was_complete and
                allocator.prefix_complete and
                self.config.record_events)
            {
                self.appendObservedAllocatorEventLocked(
                    @intCast(allocator_index),
                ) catch {
                    self.recording_failures +|= 1;
                };
            }
        }
    }

    fn physicalAllocatorId(self: *Tracer) !u32 {
        self.lock();
        defer self.unlock();
        if (self.physical_allocator_id) |allocator_id| return allocator_id;
        const label_id = try self.internLabelLocked("sys.memory");
        const allocator_id = std.math.cast(
            u32,
            self.allocators.items.len,
        ) orelse return error.OutOfMemory;
        try self.allocators.append(self.control_allocator, .{
            .label_id = label_id,
            .retention = .releases_freed_memory,
            .layer = .physical_page,
        });
        self.physical_allocator_id = allocator_id;
        try self.appendEventLocked(.{
            .kind = .allocator,
            .allocator_id = allocator_id,
            .label_id = label_id,
            .layer = .physical_page,
            .producer = .sys_memory,
        });
        return allocator_id;
    }

    fn captureOperation(
        self: *Tracer,
        storage: *[stack_mod.max_frames_limit]usize,
        ret_addr: usize,
    ) ?stack_mod.Capture {
        if (self.config.allocation_attribution != .stack) return null;
        return stack_mod.capture.capture(
            storage,
            ret_addr,
            self.config.stack_frame_limit,
        );
    }

    fn recordAllocation(
        self: *Tracer,
        allocator_id: u32,
        ptr: [*]u8,
        len: usize,
        alignment: Alignment,
        ret_addr: usize,
        captured: ?stack_mod.Capture,
        operation_context: OperationContext,
    ) !void {
        self.lock();
        defer self.unlock();

        const stack_id = try self.internStackLocked(captured);
        const address = @intFromPtr(ptr);
        const allocation_id = self.next_allocation_id;
        self.next_allocation_id += 1;
        const key = AllocationKey{
            .allocator_id = allocator_id,
            .address = address,
        };
        const entry = try self.allocations.getOrPut(
            self.control_allocator,
            key,
        );
        if (entry.found_existing) {
            self.noteAnomalyLocked(
                .duplicate_current_address,
                .alloc,
                operation_context,
                address,
                0,
                len,
                true,
                ret_addr,
            );
            self.applyUntrackedAllocationLocked(
                allocator_id,
                self.current_scope,
                len,
                operation_context.layer,
            );
            return self.appendEventLocked(.{
                .kind = .alloc,
                .allocator_id = allocator_id,
                .scope_id = self.current_scope,
                .label_id = self.scopes.items[self.current_scope].label_id,
                .address = address,
                .len = len,
                .alignment = @intCast(alignment.toByteUnits()),
                .return_address = ret_addr,
                .stack_id = stack_id,
                .succeeded = true,
                .tracked = false,
                .live_bytes = self.countersForLayer(operation_context.layer).live_bytes,
                .layer = operation_context.layer,
                .operation_id = operation_context.operation_id,
                .parent_operation_id = operation_context.parent_operation_id,
                .producer_id = operation_context.producer_id,
                .producer = operation_context.producer,
                .generation = operation_context.generation,
                .owner_cookie = operation_context.owner_cookie,
            });
        }
        var map_committed = false;
        errdefer {
            if (!map_committed) {
                _ = self.allocations.fetchRemove(key);
            }
        }
        const record_index = try self.acquireAllocationRecordLocked(.{
            .allocation_id = allocation_id,
            .allocator_id = allocator_id,
            .address = address,
            .len = len,
            .alignment = alignment,
            .scope_id = self.current_scope,
            .return_address = ret_addr,
            .stack_id = stack_id,
            .allocation_seq = self.next_seq,
            .layer = operation_context.layer,
            .generation = operation_context.generation,
        });
        entry.value_ptr.* = record_index;
        self.linkAllocationRecordLocked(record_index);
        map_committed = true;
        self.applyAllocationLocked(
            allocator_id,
            self.current_scope,
            len,
            operation_context.layer,
        );
        try self.appendEventLocked(.{
            .kind = .alloc,
            .allocator_id = allocator_id,
            .allocation_id = allocation_id,
            .scope_id = self.current_scope,
            .label_id = self.scopes.items[self.current_scope].label_id,
            .address = address,
            .len = len,
            .alignment = @intCast(alignment.toByteUnits()),
            .return_address = ret_addr,
            .stack_id = stack_id,
            .succeeded = true,
            .live_bytes = self.countersForLayer(operation_context.layer).live_bytes,
            .layer = operation_context.layer,
            .operation_id = operation_context.operation_id,
            .parent_operation_id = operation_context.parent_operation_id,
            .producer_id = operation_context.producer_id,
            .producer = operation_context.producer,
            .generation = operation_context.generation,
            .owner_cookie = operation_context.owner_cookie,
        });
    }

    fn recordAllocationFailure(
        self: *Tracer,
        allocator_id: u32,
        len: usize,
        alignment: Alignment,
        ret_addr: usize,
        captured: ?stack_mod.Capture,
        operation_context: OperationContext,
    ) !void {
        self.lock();
        defer self.unlock();

        const stack_id = try self.internStackLocked(captured);
        self.applyFailedOperationLocked(
            allocator_id,
            .alloc,
            operation_context.layer,
        );
        try self.appendEventLocked(.{
            .kind = .alloc,
            .allocator_id = allocator_id,
            .scope_id = self.current_scope,
            .label_id = self.scopes.items[self.current_scope].label_id,
            .len = len,
            .alignment = @intCast(alignment.toByteUnits()),
            .return_address = ret_addr,
            .stack_id = stack_id,
            .succeeded = false,
            .live_bytes = self.countersForLayer(operation_context.layer).live_bytes,
            .layer = operation_context.layer,
            .operation_id = operation_context.operation_id,
            .parent_operation_id = operation_context.parent_operation_id,
            .producer_id = operation_context.producer_id,
            .producer = operation_context.producer,
            .generation = operation_context.generation,
            .owner_cookie = operation_context.owner_cookie,
        });
    }

    fn recordResize(
        self: *Tracer,
        allocator_id: u32,
        ptr: [*]u8,
        old_len: usize,
        new_len: usize,
        alignment: Alignment,
        ret_addr: usize,
        succeeded: bool,
        captured: ?stack_mod.Capture,
        operation_context: OperationContext,
    ) !void {
        self.lock();
        defer self.unlock();

        const address = @intFromPtr(ptr);
        const stack_id = try self.internStackLocked(captured);
        const record_index = self.allocations.get(.{
            .allocator_id = allocator_id,
            .address = address,
        }) orelse {
            self.countersForLayer(operation_context.layer).unmatched_resizes += 1;
            self.noteAnomalyLocked(
                self.unknownReasonLocked(allocator_id),
                .resize,
                operation_context,
                address,
                old_len,
                new_len,
                succeeded,
                ret_addr,
            );
            if (!succeeded) self.applyFailedOperationLocked(
                allocator_id,
                .resize,
                operation_context.layer,
            );
            return self.appendUnknownResizeLocked(
                allocator_id,
                address,
                old_len,
                new_len,
                alignment,
                ret_addr,
                stack_id,
                succeeded,
                operation_context,
            );
        };
        const record = &self.allocation_records.items[record_index];
        const scope_id = record.scope_id;
        std.debug.assert(record.layer == operation_context.layer);
        if (record.len != old_len) {
            self.noteAnomalyLocked(
                .length_mismatch,
                .resize,
                operation_context,
                address,
                old_len,
                new_len,
                succeeded,
                ret_addr,
            );
        }
        if (record.alignment != alignment) {
            self.noteAnomalyLocked(
                .alignment_mismatch,
                .resize,
                operation_context,
                address,
                old_len,
                new_len,
                succeeded,
                ret_addr,
            );
        }
        if (succeeded) {
            const recorded_old_len = record.len;
            record.len = new_len;
            record.alignment = alignment;
            self.applyResizeLocked(
                record.allocator_id,
                scope_id,
                recorded_old_len,
                new_len,
                operation_context.layer,
            );
        } else {
            self.applyFailedOperationLocked(
                allocator_id,
                .resize,
                operation_context.layer,
            );
        }
        try self.appendEventLocked(.{
            .kind = .resize,
            .allocator_id = allocator_id,
            .allocation_id = record.allocation_id,
            .scope_id = scope_id,
            .label_id = self.scopes.items[scope_id].label_id,
            .address = address,
            .old_len = old_len,
            .len = new_len,
            .alignment = @intCast(alignment.toByteUnits()),
            .return_address = ret_addr,
            .stack_id = stack_id,
            .succeeded = succeeded,
            .live_bytes = self.countersForLayer(operation_context.layer).live_bytes,
            .layer = operation_context.layer,
            .operation_id = operation_context.operation_id,
            .parent_operation_id = operation_context.parent_operation_id,
            .producer_id = operation_context.producer_id,
            .producer = operation_context.producer,
            .generation = operation_context.generation,
            .owner_cookie = operation_context.owner_cookie,
        });
    }

    fn appendUnknownResizeLocked(
        self: *Tracer,
        allocator_id: u32,
        address: usize,
        old_len: usize,
        new_len: usize,
        alignment: Alignment,
        ret_addr: usize,
        stack_id: u32,
        succeeded: bool,
        operation_context: OperationContext,
    ) !void {
        try self.appendEventLocked(.{
            .kind = .resize,
            .allocator_id = allocator_id,
            .scope_id = self.current_scope,
            .label_id = self.scopes.items[self.current_scope].label_id,
            .address = address,
            .old_len = old_len,
            .len = new_len,
            .alignment = @intCast(alignment.toByteUnits()),
            .return_address = ret_addr,
            .stack_id = stack_id,
            .succeeded = succeeded,
            .tracked = false,
            .live_bytes = self.countersForLayer(operation_context.layer).live_bytes,
            .layer = operation_context.layer,
            .operation_id = operation_context.operation_id,
            .parent_operation_id = operation_context.parent_operation_id,
            .producer_id = operation_context.producer_id,
            .producer = operation_context.producer,
            .generation = operation_context.generation,
            .owner_cookie = operation_context.owner_cookie,
        });
    }

    fn recordRemap(
        self: *Tracer,
        allocator_id: u32,
        old_ptr: [*]u8,
        new_ptr: ?[*]u8,
        old_len: usize,
        new_len: usize,
        alignment: Alignment,
        ret_addr: usize,
        captured: ?stack_mod.Capture,
        operation_context: OperationContext,
    ) !void {
        self.lock();
        defer self.unlock();

        const old_address = @intFromPtr(old_ptr);
        const stack_id = try self.internStackLocked(captured);
        const key = AllocationKey{
            .allocator_id = allocator_id,
            .address = old_address,
        };
        const existing_index = self.allocations.get(key) orelse {
            self.countersForLayer(operation_context.layer).unmatched_remaps += 1;
            self.noteAnomalyLocked(
                self.unknownReasonLocked(allocator_id),
                .remap,
                operation_context,
                old_address,
                old_len,
                new_len,
                new_ptr != null,
                ret_addr,
            );
            if (new_ptr == null) self.applyFailedOperationLocked(
                allocator_id,
                .remap,
                operation_context.layer,
            );
            return self.appendUnknownRemapLocked(
                allocator_id,
                old_address,
                new_ptr,
                old_len,
                new_len,
                alignment,
                ret_addr,
                stack_id,
                operation_context,
            );
        };
        const record = &self.allocation_records.items[existing_index];
        std.debug.assert(record.layer == operation_context.layer);
        if (record.len != old_len) {
            self.noteAnomalyLocked(
                .length_mismatch,
                .remap,
                operation_context,
                old_address,
                old_len,
                new_len,
                new_ptr != null,
                ret_addr,
            );
        }
        if (record.alignment != alignment) {
            self.noteAnomalyLocked(
                .alignment_mismatch,
                .remap,
                operation_context,
                old_address,
                old_len,
                new_len,
                new_ptr != null,
                ret_addr,
            );
        }
        if (new_ptr == null) {
            self.applyFailedOperationLocked(
                allocator_id,
                .remap,
                operation_context.layer,
            );
            return self.appendKnownRemapLocked(
                record.*,
                old_address,
                null,
                old_len,
                new_len,
                alignment,
                ret_addr,
                stack_id,
                operation_context,
                true,
            );
        }
        const new_address = @intFromPtr(new_ptr.?);
        if (new_address != old_address and self.allocations.contains(.{
            .allocator_id = allocator_id,
            .address = new_address,
        })) {
            self.noteAnomalyLocked(
                .duplicate_current_address,
                .remap,
                operation_context,
                new_address,
                old_len,
                new_len,
                true,
                ret_addr,
            );
            _ = self.allocations.fetchRemove(key);
            self.clearDrainedAllocationsLocked();
            const abandoned = record.*;
            self.unlinkAllocationRecordLocked(existing_index);
            self.applyLostTrackingLocked(
                abandoned.allocator_id,
                abandoned.scope_id,
                abandoned.len,
                new_len,
                operation_context.layer,
            );
            self.recycleAllocationRecordLocked(existing_index);
            return self.appendKnownRemapLocked(
                abandoned,
                old_address,
                new_ptr,
                old_len,
                new_len,
                alignment,
                ret_addr,
                stack_id,
                operation_context,
                false,
            );
        }
        _ = self.allocations.fetchRemove(key).?;
        self.clearDrainedAllocationsLocked();
        const scope_id = record.scope_id;
        const recorded_old_len = record.len;
        record.address = new_address;
        record.len = new_len;
        record.alignment = alignment;
        const new_entry = try self.allocations.getOrPut(
            self.control_allocator,
            .{
                .allocator_id = allocator_id,
                .address = new_address,
            },
        );
        std.debug.assert(!new_entry.found_existing);
        new_entry.value_ptr.* = existing_index;
        self.applyResizeLocked(
            record.allocator_id,
            scope_id,
            recorded_old_len,
            new_len,
            operation_context.layer,
        );
        self.countersForLayer(operation_context.layer).remaps += 1;
        if (record.allocator_id < self.allocators.items.len) self.allocators.items[record.allocator_id].counters.remaps += 1;
        try self.appendKnownRemapLocked(
            record.*,
            old_address,
            new_ptr,
            old_len,
            new_len,
            alignment,
            ret_addr,
            stack_id,
            operation_context,
            true,
        );
    }

    fn appendKnownRemapLocked(
        self: *Tracer,
        record: AllocationRecord,
        old_address: usize,
        new_ptr: ?[*]u8,
        old_len: usize,
        new_len: usize,
        alignment: Alignment,
        ret_addr: usize,
        stack_id: u32,
        operation_context: OperationContext,
        tracked: bool,
    ) !void {
        try self.appendEventLocked(.{
            .kind = .remap,
            .allocator_id = record.allocator_id,
            .allocation_id = record.allocation_id,
            .scope_id = record.scope_id,
            .label_id = self.scopes.items[record.scope_id].label_id,
            .address = if (new_ptr) |ptr| @intFromPtr(ptr) else old_address,
            .old_address = old_address,
            .old_len = old_len,
            .len = new_len,
            .alignment = @intCast(alignment.toByteUnits()),
            .return_address = ret_addr,
            .stack_id = stack_id,
            .succeeded = new_ptr != null,
            .tracked = tracked,
            .live_bytes = self.countersForLayer(operation_context.layer).live_bytes,
            .layer = operation_context.layer,
            .operation_id = operation_context.operation_id,
            .parent_operation_id = operation_context.parent_operation_id,
            .producer_id = operation_context.producer_id,
            .producer = operation_context.producer,
            .generation = operation_context.generation,
            .owner_cookie = operation_context.owner_cookie,
        });
    }

    fn appendUnknownRemapLocked(
        self: *Tracer,
        allocator_id: u32,
        old_address: usize,
        new_ptr: ?[*]u8,
        old_len: usize,
        new_len: usize,
        alignment: Alignment,
        ret_addr: usize,
        stack_id: u32,
        operation_context: OperationContext,
    ) !void {
        const record = AllocationRecord{
            .allocation_id = 0,
            .allocator_id = allocator_id,
            .address = old_address,
            .len = old_len,
            .alignment = alignment,
            .scope_id = self.current_scope,
            .return_address = ret_addr,
            .stack_id = stack_id,
            .allocation_seq = 0,
            .layer = operation_context.layer,
            .generation = operation_context.generation,
        };
        try self.appendKnownRemapLocked(
            record,
            old_address,
            new_ptr,
            old_len,
            new_len,
            alignment,
            ret_addr,
            stack_id,
            operation_context,
            false,
        );
    }

    fn recordFree(
        self: *Tracer,
        allocator_id: u32,
        ptr: [*]u8,
        len: usize,
        alignment: Alignment,
        ret_addr: usize,
        captured: ?stack_mod.Capture,
        operation_context: OperationContext,
    ) !void {
        self.lock();
        defer self.unlock();

        const address = @intFromPtr(ptr);
        const stack_id = try self.internStackLocked(captured);
        const removed = self.allocations.fetchRemove(.{
            .allocator_id = allocator_id,
            .address = address,
        }) orelse {
            self.countersForLayer(operation_context.layer).unmatched_frees += 1;
            self.noteAnomalyLocked(
                self.unknownReasonLocked(allocator_id),
                .free,
                operation_context,
                address,
                len,
                0,
                true,
                ret_addr,
            );
            return self.appendUnknownFreeLocked(
                allocator_id,
                address,
                len,
                alignment,
                ret_addr,
                stack_id,
                operation_context,
            );
        };
        self.clearDrainedAllocationsLocked();
        const record_index = removed.value;
        const record = self.allocation_records.items[record_index];
        std.debug.assert(record.layer == operation_context.layer);
        if (record.len != len) {
            self.noteAnomalyLocked(
                .length_mismatch,
                .free,
                operation_context,
                address,
                len,
                0,
                true,
                ret_addr,
            );
        }
        if (record.alignment != alignment) {
            self.noteAnomalyLocked(
                .alignment_mismatch,
                .free,
                operation_context,
                address,
                len,
                0,
                true,
                ret_addr,
            );
        }
        self.unlinkAllocationRecordLocked(record_index);
        self.applyLifetimeLocked(
            record.scope_id,
            completedLifetimeEvents(record.allocation_seq, self.next_seq),
            operation_context.layer,
        );
        self.applyFreeLocked(
            record.allocator_id,
            record.scope_id,
            record.len,
            operation_context.layer,
        );
        self.recycleAllocationRecordLocked(record_index);
        try self.appendEventLocked(.{
            .kind = .free,
            .allocator_id = allocator_id,
            .allocation_id = record.allocation_id,
            .scope_id = record.scope_id,
            .label_id = self.scopes.items[record.scope_id].label_id,
            .address = address,
            .old_len = len,
            .len = record.len,
            .alignment = @intCast(alignment.toByteUnits()),
            .return_address = ret_addr,
            .stack_id = stack_id,
            .succeeded = true,
            .live_bytes = self.countersForLayer(operation_context.layer).live_bytes,
            .layer = operation_context.layer,
            .operation_id = operation_context.operation_id,
            .parent_operation_id = operation_context.parent_operation_id,
            .producer_id = operation_context.producer_id,
            .producer = operation_context.producer,
            .generation = operation_context.generation,
            .owner_cookie = operation_context.owner_cookie,
        });
    }

    fn appendUnknownFreeLocked(
        self: *Tracer,
        allocator_id: u32,
        address: usize,
        len: usize,
        alignment: Alignment,
        ret_addr: usize,
        stack_id: u32,
        operation_context: OperationContext,
    ) !void {
        try self.appendEventLocked(.{
            .kind = .free,
            .allocator_id = allocator_id,
            .scope_id = self.current_scope,
            .label_id = self.scopes.items[self.current_scope].label_id,
            .address = address,
            .old_len = len,
            .len = len,
            .alignment = @intCast(alignment.toByteUnits()),
            .return_address = ret_addr,
            .stack_id = stack_id,
            .succeeded = true,
            .tracked = false,
            .live_bytes = self.countersForLayer(operation_context.layer).live_bytes,
            .layer = operation_context.layer,
            .operation_id = operation_context.operation_id,
            .parent_operation_id = operation_context.parent_operation_id,
            .producer_id = operation_context.producer_id,
            .producer = operation_context.producer,
            .generation = operation_context.generation,
            .owner_cookie = operation_context.owner_cookie,
        });
    }

    fn acquireAllocationRecordLocked(
        self: *Tracer,
        record: AllocationRecord,
    ) !u32 {
        if (self.free_record_head != record_index_none) {
            const record_index = self.free_record_head;
            self.free_record_head =
                self.allocation_records.items[record_index].next_free;
            self.allocation_records.items[record_index] = record;
            return record_index;
        }
        const record_index = std.math.cast(
            u32,
            self.allocation_records.items.len,
        ) orelse return error.OutOfMemory;
        try self.allocation_records.append(
            self.control_allocator,
            record,
        );
        return record_index;
    }

    fn linkAllocationRecordLocked(
        self: *Tracer,
        record_index: u32,
    ) void {
        const record = &self.allocation_records.items[record_index];
        std.debug.assert(record.active);
        const allocator = &self.allocators.items[record.allocator_id];
        record.previous_active = record_index_none;
        record.next_active = allocator.active_head;
        if (allocator.active_head != record_index_none) {
            self.allocation_records.items[allocator.active_head]
                .previous_active = record_index;
        }
        allocator.active_head = record_index;
    }

    fn unlinkAllocationRecordLocked(
        self: *Tracer,
        record_index: u32,
    ) void {
        const record = &self.allocation_records.items[record_index];
        std.debug.assert(record.active);
        const allocator = &self.allocators.items[record.allocator_id];
        if (record.previous_active == record_index_none) {
            std.debug.assert(allocator.active_head == record_index);
            allocator.active_head = record.next_active;
        } else {
            self.allocation_records.items[record.previous_active]
                .next_active = record.next_active;
        }
        if (record.next_active != record_index_none) {
            self.allocation_records.items[record.next_active]
                .previous_active = record.previous_active;
        }
        record.previous_active = record_index_none;
        record.next_active = record_index_none;
    }

    fn recycleAllocationRecordLocked(
        self: *Tracer,
        record_index: u32,
    ) void {
        const record = &self.allocation_records.items[record_index];
        std.debug.assert(record.active);
        record.active = false;
        record.next_free = self.free_record_head;
        self.free_record_head = record_index;
    }

    fn unknownReasonLocked(
        self: *Tracer,
        allocator_id: u32,
    ) AnomalyReason {
        if (allocator_id >= self.allocators.items.len) {
            return .unknown_current_generation;
        }
        return if (self.allocators.items[allocator_id].prefix_complete)
            .unknown_current_generation
        else
            .unknown_pre_observation;
    }

    fn noteAnomalyLocked(
        self: *Tracer,
        reason: AnomalyReason,
        operation: observe.Operation,
        operation_context: OperationContext,
        address: usize,
        old_len: usize,
        new_len: usize,
        succeeded: bool,
        return_address: usize,
    ) void {
        const key = AnomalyKey{
            .reason = reason,
            .operation = operation,
            .layer = operation_context.layer,
            .producer_id = operation_context.producer_id,
            .producer = operation_context.producer,
            .generation = operation_context.generation,
            .scope_id = self.current_scope,
            .return_address = return_address,
            .old_len = old_len,
            .new_len = new_len,
            .succeeded = succeeded,
        };
        for (self.anomaly_sites[0..self.anomaly_site_count]) |*site| {
            if (!std.meta.eql(site.key, key)) continue;
            site.occurrences +|= 1;
            return;
        }
        if (self.anomaly_site_count == self.anomaly_sites.len) {
            self.anomaly_sites_dropped +|= 1;
            return;
        }
        self.anomaly_sites[self.anomaly_site_count] = .{
            .key = key,
            .first_address = address,
            .occurrences = 1,
        };
        self.anomaly_site_count += 1;
    }

    fn applyUntrackedAllocationLocked(
        self: *Tracer,
        allocator_id: u32,
        scope_id: u32,
        len: usize,
        layer: event_mod.Layer,
    ) void {
        const counters = self.countersForLayer(layer);
        counters.allocations += 1;
        counters.allocated_bytes += len;
        counters.untracked_requests += 1;
        counters.untracked_request_bytes += len;
        const allocator = &self.allocators.items[allocator_id].counters;
        allocator.allocations += 1;
        allocator.allocated_bytes += len;
        allocator.untracked_requests += 1;
        allocator.untracked_request_bytes += len;
        const scope = self.scopeCountersForLayer(scope_id, layer);
        scope.allocations += 1;
        scope.allocated_bytes += len;
        scope.untracked_requests += 1;
        scope.untracked_request_bytes += len;
    }

    fn applyLostTrackingLocked(
        self: *Tracer,
        allocator_id: u32,
        scope_id: u32,
        old_len: usize,
        new_len: usize,
        layer: event_mod.Layer,
    ) void {
        self.applyResizeLocked(
            allocator_id,
            scope_id,
            old_len,
            new_len,
            layer,
        );
        const counters = self.countersForLayer(layer);
        counters.live_allocations -= 1;
        counters.live_bytes -= new_len;
        counters.untracked_requests += 1;
        counters.untracked_request_bytes += new_len;
        const allocator = &self.allocators.items[allocator_id].counters;
        allocator.live_allocations -= 1;
        allocator.live_bytes -= new_len;
        allocator.untracked_requests += 1;
        allocator.untracked_request_bytes += new_len;
        const scope = self.scopeCountersForLayer(scope_id, layer);
        scope.live_allocations -= 1;
        scope.live_bytes -= new_len;
        scope.untracked_requests += 1;
        scope.untracked_request_bytes += new_len;
    }

    fn validateObservedIdentity(
        self: *Tracer,
        allocator_id: u32,
        observed: observe.Event,
        operation_context: OperationContext,
    ) bool {
        self.lock();
        defer self.unlock();
        self.noteRequestSiteLocked(observed);
        const allocator = &self.allocators.items[allocator_id];
        if (allocator.terminal) {
            self.noteAnomalyLocked(
                .operation_after_terminal,
                observed.operation,
                operation_context,
                observed.old_address,
                observed.old_len,
                observed.len,
                observed.succeeded,
                observed.return_address,
            );
            return false;
        }
        if (allocator.owner_cookie != observed.owner_cookie) {
            self.noteAnomalyLocked(
                .owner_cookie_mismatch,
                observed.operation,
                operation_context,
                observed.old_address,
                observed.old_len,
                observed.len,
                observed.succeeded,
                observed.return_address,
            );
            return false;
        }
        if (observed.generation < allocator.generation) {
            self.noteAnomalyLocked(
                .stale_generation,
                observed.operation,
                operation_context,
                observed.old_address,
                observed.old_len,
                observed.len,
                observed.succeeded,
                observed.return_address,
            );
            return false;
        }
        if (observed.generation > allocator.generation) {
            self.noteAnomalyLocked(
                .generation_gap,
                observed.operation,
                operation_context,
                observed.old_address,
                observed.old_len,
                observed.len,
                observed.succeeded,
                observed.return_address,
            );
            return false;
        }
        return true;
    }

    fn noteRequestSiteLocked(
        self: *Tracer,
        observed: observe.Event,
    ) void {
        if (observed.operation == .lifecycle) return;
        const requested_bytes: u64 = std.math.cast(
            u64,
            switch (observed.operation) {
                .alloc, .resize, .remap => observed.len,
                .free => observed.old_len,
                .lifecycle => unreachable,
            },
        ) orelse std.math.maxInt(u64);
        const key = RequestSiteKey{
            .producer_id = observed.producer_id,
            .producer = observed.producer,
            .operation = observed.operation,
            .scope_id = self.current_scope,
            .return_address = observed.return_address,
            .succeeded = observed.succeeded,
        };
        if (self.request_sites.getPtr(key)) |site| {
            site.calls +|= 1;
            site.requested_bytes +|= requested_bytes;
            return;
        }
        if (self.request_sites.count() ==
            @as(usize, self.config.request_site_capacity))
        {
            self.request_site_unaggregated_calls +|= 1;
            self.request_site_unaggregated_bytes +|= requested_bytes;
            return;
        }
        self.request_sites.putAssumeCapacity(key, .{
            .calls = 1,
            .requested_bytes = requested_bytes,
        });
    }

    fn recordLifecycle(
        self: *Tracer,
        allocator_id: u32,
        observed: observe.Event,
        operation_context: OperationContext,
    ) !void {
        self.lock();
        defer self.unlock();
        const allocator = &self.allocators.items[allocator_id];
        self.countersForLayer(.logical_allocator).lifecycle_events += 1;
        allocator.counters.lifecycle_events += 1;
        var append_error: ?anyerror = null;
        var record_index = allocator.active_head;
        while (record_index != record_index_none) {
            const record = self.allocation_records.items[record_index];
            const next = record.next_active;
            std.debug.assert(record.generation == observed.generation);
            const removed = self.allocations.fetchRemove(.{
                .allocator_id = record.allocator_id,
                .address = record.address,
            }) orelse unreachable;
            std.debug.assert(removed.value == record_index);
            self.unlinkAllocationRecordLocked(record_index);
            self.applyLifetimeLocked(
                record.scope_id,
                completedLifetimeEvents(
                    record.allocation_seq,
                    self.next_seq,
                ),
                .logical_allocator,
            );
            self.applyBulkInvalidationLocked(
                record.allocator_id,
                record.scope_id,
                record.len,
                .logical_allocator,
            );
            self.recycleAllocationRecordLocked(record_index);
            if (append_error == null) {
                self.appendEventLocked(.{
                    .kind = .release,
                    .allocator_id = record.allocator_id,
                    .allocation_id = record.allocation_id,
                    .scope_id = record.scope_id,
                    .label_id = self.scopes.items[record.scope_id].label_id,
                    .address = record.address,
                    .old_len = record.len,
                    .len = record.len,
                    .alignment = @intCast(record.alignment.toByteUnits()),
                    .return_address = observed.return_address,
                    .stack_id = record.stack_id,
                    .succeeded = observed.succeeded,
                    .live_bytes = self.countersForLayer(.logical_allocator).live_bytes,
                    .layer = .logical_allocator,
                    .operation_id = operation_context.operation_id,
                    .parent_operation_id = operation_context.parent_operation_id,
                    .producer_id = operation_context.producer_id,
                    .producer = operation_context.producer,
                    .generation = operation_context.generation,
                    .owner_cookie = operation_context.owner_cookie,
                    .lifecycle_disposition = observed.lifecycle_disposition,
                    .lifecycle_reason = observed.lifecycle_reason,
                }) catch |err| {
                    append_error = err;
                };
            }
            record_index = next;
        }
        self.clearDrainedAllocationsLocked();
        if (append_error == null) {
            self.appendEventLocked(.{
                .kind = .lifecycle,
                .allocator_id = allocator_id,
                .scope_id = self.current_scope,
                .label_id = self.scopes.items[self.current_scope].label_id,
                .return_address = observed.return_address,
                .succeeded = observed.succeeded,
                .live_bytes = self.countersForLayer(.logical_allocator).live_bytes,
                .layer = .logical_allocator,
                .operation_id = operation_context.operation_id,
                .parent_operation_id = operation_context.parent_operation_id,
                .producer_id = operation_context.producer_id,
                .producer = operation_context.producer,
                .generation = operation_context.generation,
                .owner_cookie = operation_context.owner_cookie,
                .lifecycle_disposition = observed.lifecycle_disposition,
                .lifecycle_reason = observed.lifecycle_reason,
            }) catch |err| {
                append_error = err;
            };
        }
        if (observed.lifecycle_disposition == .end) {
            allocator.terminal = true;
            allocator.prefix_complete = true;
        } else {
            allocator.generation = std.math.add(
                u64,
                allocator.generation,
                1,
            ) catch @panic("allocator observation generation exhausted");
            allocator.prefix_complete = true;
        }
        if (append_error) |err| return err;
    }

    fn internStackLocked(
        self: *Tracer,
        captured: ?stack_mod.Capture,
    ) !u32 {
        const stack_capture = captured orelse return 0;
        const interned = try self.stacks.intern(
            self.control_allocator,
            stack_capture,
        );
        if (interned.is_new) {
            if (self.config.event_writer) |writer| {
                try stack_mod.capture.writeDefinition(
                    writer,
                    interned.id,
                    self.stacks.recordForId(interned.id).*,
                );
            }
        }
        return interned.id;
    }

    fn applyFailedOperationLocked(
        self: *Tracer,
        allocator_id: u32,
        kind: event_mod.Kind,
        layer: event_mod.Layer,
    ) void {
        const allocator_counters = if (allocator_id < self.allocators.items.len)
            &self.allocators.items[allocator_id].counters
        else
            null;
        if (allocator_id < self.allocators.items.len) {
            std.debug.assert(self.allocators.items[allocator_id].layer == layer);
        }
        const counters = self.countersForLayer(layer);
        switch (kind) {
            .alloc => {
                counters.failed_allocations +|= 1;
                if (allocator_counters) |item| item.failed_allocations +|= 1;
            },
            .resize => {
                counters.failed_resizes +|= 1;
                if (allocator_counters) |item| item.failed_resizes +|= 1;
            },
            .remap => {
                counters.failed_remaps +|= 1;
                if (allocator_counters) |item| item.failed_remaps +|= 1;
            },
            else => unreachable,
        }
    }

    fn markRecordingFailure(self: *Tracer) void {
        self.lock();
        defer self.unlock();
        self.recording_failures +|= 1;
    }

    fn applyAllocationLocked(
        self: *Tracer,
        allocator_id: u32,
        scope_id: u32,
        len: usize,
        layer: event_mod.Layer,
    ) void {
        const counters = self.countersForLayer(layer);
        counters.allocations += 1;
        counters.live_allocations += 1;
        counters.allocated_bytes += len;
        counters.live_bytes += len;
        counters.high_water_live_bytes = @max(
            counters.high_water_live_bytes,
            counters.live_bytes,
        );
        if (layer != .logical_allocator) {
            counters.retained_bytes += len;
            counters.high_water_retained_bytes = @max(
                counters.high_water_retained_bytes,
                counters.retained_bytes,
            );
        }
        if (allocator_id < self.allocators.items.len) {
            const allocator_state = &self.allocators.items[allocator_id];
            std.debug.assert(allocator_state.layer == layer);
            allocator_state.counters.allocations += 1;
            allocator_state.counters.live_allocations += 1;
            allocator_state.counters.allocated_bytes += len;
            allocator_state.counters.live_bytes += len;
            allocator_state.counters.high_water_live_bytes = @max(
                allocator_state.counters.high_water_live_bytes,
                allocator_state.counters.live_bytes,
            );
            if (layer != .logical_allocator) {
                allocator_state.counters.retained_bytes += len;
                allocator_state.counters.high_water_retained_bytes = @max(
                    allocator_state.counters.high_water_retained_bytes,
                    allocator_state.counters.retained_bytes,
                );
            }
        }
        const scope_counters = self.scopeCountersForLayer(scope_id, layer);
        scope_counters.allocations += 1;
        scope_counters.live_allocations += 1;
        scope_counters.allocated_bytes += len;
        scope_counters.live_bytes += len;
        scope_counters.high_water_live_bytes = @max(scope_counters.high_water_live_bytes, scope_counters.live_bytes);
        if (layer != .logical_allocator) {
            scope_counters.retained_bytes += len;
            scope_counters.high_water_retained_bytes = @max(scope_counters.high_water_retained_bytes, scope_counters.retained_bytes);
        }
    }

    fn applyResizeLocked(
        self: *Tracer,
        allocator_id: u32,
        scope_id: u32,
        old_len: usize,
        new_len: usize,
        layer: event_mod.Layer,
    ) void {
        const counters = self.countersForLayer(layer);
        const scope_counters = self.scopeCountersForLayer(scope_id, layer);
        const allocator_state = if (allocator_id < self.allocators.items.len)
            &self.allocators.items[allocator_id]
        else
            null;
        if (allocator_state) |state| std.debug.assert(state.layer == layer);
        counters.resizes += 1;
        if (new_len >= old_len) {
            const delta = new_len - old_len;
            counters.allocated_bytes += delta;
            counters.live_bytes += delta;
            counters.high_water_live_bytes = @max(
                counters.high_water_live_bytes,
                counters.live_bytes,
            );
            if (layer != .logical_allocator) {
                counters.retained_bytes += delta;
                counters.high_water_retained_bytes = @max(
                    counters.high_water_retained_bytes,
                    counters.retained_bytes,
                );
            }
            scope_counters.allocated_bytes += delta;
            scope_counters.live_bytes += delta;
            scope_counters.high_water_live_bytes = @max(
                scope_counters.high_water_live_bytes,
                scope_counters.live_bytes,
            );
            if (layer != .logical_allocator) {
                scope_counters.retained_bytes += delta;
                scope_counters.high_water_retained_bytes = @max(
                    scope_counters.high_water_retained_bytes,
                    scope_counters.retained_bytes,
                );
            }
            if (allocator_state) |state| {
                state.counters.allocated_bytes += delta;
                state.counters.live_bytes += delta;
                state.counters.high_water_live_bytes = @max(
                    state.counters.high_water_live_bytes,
                    state.counters.live_bytes,
                );
                if (layer != .logical_allocator) {
                    state.counters.retained_bytes += delta;
                    state.counters.high_water_retained_bytes = @max(
                        state.counters.high_water_retained_bytes,
                        state.counters.retained_bytes,
                    );
                }
            }
        } else {
            const delta = old_len - new_len;
            counters.freed_bytes += delta;
            counters.live_bytes -= delta;
            scope_counters.freed_bytes += delta;
            scope_counters.live_bytes -= delta;
            const releases = layer != .logical_allocator and
                (allocator_state == null or
                    allocator_state.?.retention == .releases_freed_memory);
            if (releases) {
                counters.retained_bytes -= delta;
                scope_counters.retained_bytes -= delta;
            }
            if (allocator_state) |state| {
                state.counters.freed_bytes += delta;
                state.counters.live_bytes -= delta;
                if (releases) state.counters.retained_bytes -= delta;
            }
        }
        if (allocator_state) |state| state.counters.resizes += 1;
    }

    fn applyFreeLocked(
        self: *Tracer,
        allocator_id: u32,
        scope_id: u32,
        len: usize,
        layer: event_mod.Layer,
    ) void {
        const counters = self.countersForLayer(layer);
        const scope_counters = self.scopeCountersForLayer(scope_id, layer);
        const allocator_state = if (allocator_id < self.allocators.items.len)
            &self.allocators.items[allocator_id]
        else
            null;
        if (allocator_state) |state| std.debug.assert(state.layer == layer);
        counters.frees += 1;
        counters.live_allocations -= 1;
        counters.freed_bytes += len;
        counters.live_bytes -= len;
        const releases = layer != .logical_allocator and
            (allocator_state == null or
                allocator_state.?.retention == .releases_freed_memory);
        if (releases) counters.retained_bytes -= len;
        if (allocator_state) |state| {
            state.counters.frees += 1;
            state.counters.live_allocations -= 1;
            state.counters.freed_bytes += len;
            state.counters.live_bytes -= len;
            if (releases) state.counters.retained_bytes -= len;
        }
        scope_counters.frees += 1;
        scope_counters.live_allocations -= 1;
        scope_counters.freed_bytes += len;
        scope_counters.live_bytes -= len;
        if (releases) scope_counters.retained_bytes -= len;
    }

    fn applyBulkInvalidationLocked(
        self: *Tracer,
        allocator_id: u32,
        scope_id: u32,
        len: usize,
        layer: event_mod.Layer,
    ) void {
        const counters = self.countersForLayer(layer);
        counters.bulk_invalidated_requests += 1;
        counters.bulk_invalidated_bytes += len;
        counters.live_allocations -= 1;
        counters.live_bytes -= len;
        const allocator = &self.allocators.items[allocator_id].counters;
        allocator.bulk_invalidated_requests += 1;
        allocator.bulk_invalidated_bytes += len;
        allocator.live_allocations -= 1;
        allocator.live_bytes -= len;
        const scope = self.scopeCountersForLayer(scope_id, layer);
        scope.bulk_invalidated_requests += 1;
        scope.bulk_invalidated_bytes += len;
        scope.live_allocations -= 1;
        scope.live_bytes -= len;
    }

    fn applyLifetimeLocked(
        self: *Tracer,
        scope_id: u32,
        lifetime_events: u64,
        layer: event_mod.Layer,
    ) void {
        applyCompletedLifetime(self.countersForLayer(layer), lifetime_events);
        applyCompletedLifetime(
            self.scopeCountersForLayer(scope_id, layer),
            lifetime_events,
        );
    }

    fn exitScope(self: *Tracer, scope_id: u32, previous: u32) void {
        self.lock();
        defer self.unlock();
        if (self.current_scope == scope_id) self.current_scope = previous;
        self.appendEventLocked(.{
            .kind = .scope_exit,
            .scope_id = scope_id,
            .label_id = self.scopes.items[scope_id].label_id,
            .live_bytes = self.countersForLayer(.backing_boundary).live_bytes,
        }) catch {};
    }

    fn bootstrapRoot(self: *Tracer) !void {
        const owned = try self.control_allocator.dupe(u8, "root");
        errdefer self.control_allocator.free(owned);
        try self.labels.append(self.control_allocator, .{ .text = owned });
        try self.label_ids.putNoClobber(self.control_allocator, owned, root_label_id);
        try self.scopes.append(self.control_allocator, .{ .parent = root_scope_id, .label_id = root_label_id });
    }

    fn internLabelLocked(self: *Tracer, text: []const u8) !u32 {
        if (self.label_ids.get(text)) |id| return id;
        const id = std.math.cast(u32, self.labels.items.len) orelse return error.OutOfMemory;
        const owned = try self.control_allocator.dupe(u8, text);
        errdefer self.control_allocator.free(owned);
        try self.labels.append(self.control_allocator, .{ .text = owned });
        try self.label_ids.putNoClobber(self.control_allocator, owned, id);
        return id;
    }

    fn scopeChildLocked(self: *Tracer, parent: u32, label_id: u32) !u32 {
        const key = ChildKey{ .parent = parent, .label_id = label_id };
        if (self.scope_children.get(key)) |scope_id| return scope_id;
        const scope_id = std.math.cast(u32, self.scopes.items.len) orelse return error.OutOfMemory;
        try self.scopes.append(self.control_allocator, .{ .parent = parent, .label_id = label_id });
        try self.scope_children.putNoClobber(self.control_allocator, key, scope_id);
        return scope_id;
    }

    fn clearDrainedAllocationsLocked(self: *Tracer) void {
        if (self.allocations.count() == 0) self.allocations.clearRetainingCapacity();
    }

    fn noteObserverControlOperation(self: *Tracer) void {
        self.control_context.note();
    }

    fn coverageManifest(self: *const Tracer) coverage_mod.Manifest {
        var manifest = self.coverage;
        manifest.observer_control_operations =
            self.observerControlOperations();
        return manifest;
    }

    fn countersForLayer(
        self: *Tracer,
        layer: event_mod.Layer,
    ) *Counters {
        return &self.counters[@backingInt(layer)];
    }

    fn scopeCountersForLayer(
        self: *Tracer,
        scope_id: u32,
        layer: event_mod.Layer,
    ) *ScopeCounters {
        return &self.scopes.items[scope_id].counters[@backingInt(layer)];
    }

    fn lifecycleCoverageLocked(self: *const Tracer) LifecycleCoverage {
        var coverage: LifecycleCoverage = .{};
        for (self.allocators.items) |allocator| {
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

    fn appendEventLocked(self: *Tracer, event: Event) !void {
        var stored = event;
        stored.seq = self.next_seq;
        self.next_seq += 1;
        if (!self.config.record_events) return;
        if (self.config.event_writer) |writer| {
            const label_text = if ((stored.kind == .allocator or
                stored.kind == .scope_enter) and
                stored.label_id < self.labels.items.len)
                self.labels.items[stored.label_id].text
            else
                null;
            const scope_text = if (stored.kind == .scope_enter and
                stored.scope_id < self.scopes.items.len)
                try self.scopePathCachedLocked(stored.scope_id)
            else
                null;
            try stored.writeJsonLine(writer, label_text, scope_text);
            return;
        }
        try self.events.append(self.control_allocator, stored);
    }

    fn scopePathCachedLocked(self: *Tracer, scope_id: u32) ![]const u8 {
        if (self.scopes.items[scope_id].path) |path| return path;
        const path = try self.scopePathAllocLocked(scope_id);
        self.scopes.items[scope_id].path = path;
        return path;
    }

    fn scopePathAllocLocked(self: *Tracer, scope_id: u32) ![]u8 {
        var stack = std.ArrayListUnmanaged(u32).empty;
        defer stack.deinit(self.control_allocator);

        var current = scope_id;
        while (true) {
            try stack.append(self.control_allocator, current);
            if (current == root_scope_id) break;
            current = self.scopes.items[current].parent;
        }

        var total: usize = 0;
        var index = stack.items.len;
        while (index > 0) {
            index -= 1;
            const label_id = self.scopes.items[stack.items[index]].label_id;
            total += self.labels.items[label_id].text.len;
            if (index != 0) total += 1;
        }

        const out = try self.control_allocator.alloc(u8, total);
        var offset: usize = 0;
        index = stack.items.len;
        while (index > 0) {
            index -= 1;
            const label_id = self.scopes.items[stack.items[index]].label_id;
            const text = self.labels.items[label_id].text;
            @memcpy(out[offset .. offset + text.len], text);
            offset += text.len;
            if (index != 0) {
                out[offset] = '/';
                offset += 1;
            }
        }
        return out;
    }

    fn lock(self: *Tracer) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Tracer) void {
        self.mutex.unlock();
    }
};

fn recordOwnedOperation(context: *anyopaque, event: observe.Event) void {
    const tracer: *Tracer = @ptrCast(@alignCast(context));
    var memory_suppression = sys.memory.observe.suppress();
    defer memory_suppression.deinit();
    tracer.recordOwnedEvent(event) catch tracer.markRecordingFailure();
}

fn recordPhysicalOperation(
    context: *anyopaque,
    event: sys.memory.observe.Event,
) void {
    const tracer: *Tracer = @ptrCast(@alignCast(context));
    var causal_context = observe.beginContext();
    defer causal_context.finish();
    const operation_context = OperationContext{
        .layer = .physical_page,
        .operation_id = causal_context.id(),
        .parent_operation_id = causal_context.parentId(),
        .producer_id = @as(u64, @backingInt(event.source)) + 1,
        .producer = .sys_memory,
    };
    var allocation_suppression = observe.suppress();
    defer allocation_suppression.deinit();
    tracer.recordPhysicalEvent(
        event,
        operation_context,
    ) catch tracer.markRecordingFailure();
}

fn boundaryOperationContext(context: observe.Context) OperationContext {
    return .{
        .operation_id = context.id(),
        .parent_operation_id = context.parentId(),
    };
}

fn physicalEventKind(operation: sys.memory.observe.Operation) event_mod.Kind {
    return switch (operation) {
        .map => .map,
        .unmap => .unmap,
        .protect => .protect,
        .discard => .discard,
        .decommit => .decommit,
        .advise => .advise,
    };
}

fn observedProducerRetention(producer: observe.Producer) Retention {
    return switch (producer) {
        .arena, .bump, .buffer_first, .fixed_buffer, .pool => .retains_freed_memory,
        .debug,
        .process,
        .phase,
        .limit,
        .boundary,
        .sys_memory,
        .custom,
        => .releases_freed_memory,
    };
}

fn observedProducerLifecycleInstrumented(
    producer: observe.Producer,
) bool {
    return switch (producer) {
        .arena, .bump => true,
        .buffer_first,
        .fixed_buffer,
        .pool,
        .debug,
        .process,
        .phase,
        .limit,
        .boundary,
        .sys_memory,
        .custom,
        => false,
    };
}

fn rawAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *TracingAllocator = @ptrCast(@alignCast(ctx));
    return self.tracer.rawAlloc(self.backing, self.allocator_id, len, alignment, ret_addr);
}

fn rawResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *TracingAllocator = @ptrCast(@alignCast(ctx));
    return self.tracer.rawResize(self.backing, self.allocator_id, memory, alignment, new_len, ret_addr);
}

fn rawRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *TracingAllocator = @ptrCast(@alignCast(ctx));
    return self.tracer.rawRemap(self.backing, self.allocator_id, memory, alignment, new_len, ret_addr);
}

fn rawFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *TracingAllocator = @ptrCast(@alignCast(ctx));
    self.tracer.rawFree(self.backing, self.allocator_id, memory, alignment, ret_addr);
}

const vtable: Allocator.VTable = .{
    .alloc = rawAlloc,
    .resize = rawResize,
    .remap = rawRemap,
    .free = rawFree,
};

fn signedDiff(after: usize, before: usize) isize {
    if (after >= before) return @intCast(after - before);
    return -@as(isize, @intCast(before - after));
}

fn completedLifetimeEvents(allocation_seq: u64, free_seq: u64) u64 {
    if (free_seq <= allocation_seq) return 0;
    return free_seq - allocation_seq;
}

fn applyCompletedLifetime(counters: anytype, lifetime_events: u64) void {
    counters.completed_lifetimes += 1;
    counters.lifetime_total_events += lifetime_events;
    counters.lifetime_max_events = @max(counters.lifetime_max_events, lifetime_events);
}

fn meanLifetimeEvents(counters: anytype) u64 {
    if (counters.completed_lifetimes == 0) return 0;
    return counters.lifetime_total_events / counters.completed_lifetimes;
}

fn writeCounterFields(
    object: pretty_json.Object,
    counters: anytype,
    layer: event_mod.Layer,
) !void {
    if (layer == .logical_allocator) {
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
    if (layer == .logical_allocator) {
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
    if (layer == .logical_allocator) {
        try object.field("open_requests", counters.live_allocations);
    } else {
        try object.field("live_allocations", counters.live_allocations);
    }
    try object.field("completed_lifetimes", counters.completed_lifetimes);
    try object.field("lifetime_total_events", counters.lifetime_total_events);
    try object.field("lifetime_mean_events", meanLifetimeEvents(counters));
    try object.field("lifetime_max_events", counters.lifetime_max_events);
}

fn scopeSummaryGreaterThan(_: void, left: ScopeSummary, right: ScopeSummary) bool {
    if (left.counters.retained_bytes != right.counters.retained_bytes) return left.counters.retained_bytes > right.counters.retained_bytes;
    if (left.counters.high_water_retained_bytes != right.counters.high_water_retained_bytes) return left.counters.high_water_retained_bytes > right.counters.high_water_retained_bytes;
    if (left.counters.live_bytes != right.counters.live_bytes) return left.counters.live_bytes > right.counters.live_bytes;
    if (left.counters.high_water_live_bytes != right.counters.high_water_live_bytes) return left.counters.high_water_live_bytes > right.counters.high_water_live_bytes;
    return std.mem.lessThan(u8, left.path, right.path);
}

fn liveSiteSummaryGreaterThan(
    _: void,
    left: LiveSiteSummary,
    right: LiveSiteSummary,
) bool {
    if (left.live_bytes != right.live_bytes) {
        return left.live_bytes > right.live_bytes;
    }
    if (left.live_allocations != right.live_allocations) {
        return left.live_allocations > right.live_allocations;
    }
    if (left.key.return_address != right.key.return_address) {
        return left.key.return_address < right.key.return_address;
    }
    if (left.key.scope_id != right.key.scope_id) {
        return left.key.scope_id < right.key.scope_id;
    }
    return left.key.allocator_id < right.key.allocator_id;
}

fn requestSiteSummaryGreaterThan(
    _: void,
    left: RequestSiteSummary,
    right: RequestSiteSummary,
) bool {
    if (left.counters.requested_bytes != right.counters.requested_bytes) {
        return left.counters.requested_bytes >
            right.counters.requested_bytes;
    }
    if (left.counters.calls != right.counters.calls) {
        return left.counters.calls > right.counters.calls;
    }
    if (left.key.return_address != right.key.return_address) {
        return left.key.return_address < right.key.return_address;
    }
    if (left.key.producer_id != right.key.producer_id) {
        return left.key.producer_id < right.key.producer_id;
    }
    if (left.key.scope_id != right.key.scope_id) {
        return left.key.scope_id < right.key.scope_id;
    }
    if (left.key.operation != right.key.operation) {
        return @backingInt(left.key.operation) <
            @backingInt(right.key.operation);
    }
    return left.key.succeeded and !right.key.succeeded;
}

noinline fn sharedAllocation(allocator: Allocator) ![]u8 {
    return try allocator.alloc(u8, 8);
}

noinline fn allocationCallerA(allocator: Allocator) ![]u8 {
    const bytes = try sharedAllocation(allocator);
    std.mem.doNotOptimizeAway(bytes.ptr);
    return bytes;
}

noinline fn allocationCallerB(allocator: Allocator) ![]u8 {
    const bytes = try sharedAllocation(allocator);
    std.mem.doNotOptimizeAway(bytes.len);
    return bytes;
}

const OperationFixtureAllocator = struct {
    backing: Allocator,

    fn allocator(self: *@This()) Allocator {
        return .{ .ptr = self, .vtable = &operation_fixture_vtable };
    }
};

fn operationFixtureAlloc(
    ctx: *anyopaque,
    len: usize,
    alignment: Alignment,
    ret_addr: usize,
) ?[*]u8 {
    const self: *OperationFixtureAllocator = @ptrCast(@alignCast(ctx));
    if (len == 13) return null;
    return self.backing.rawAlloc(len, alignment, ret_addr);
}

fn operationFixtureResize(
    _: *anyopaque,
    _: []u8,
    _: Alignment,
    _: usize,
    _: usize,
) bool {
    return false;
}

fn operationFixtureRemap(
    _: *anyopaque,
    _: []u8,
    _: Alignment,
    _: usize,
    _: usize,
) ?[*]u8 {
    return null;
}

fn operationFixtureFree(
    ctx: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    ret_addr: usize,
) void {
    const self: *OperationFixtureAllocator = @ptrCast(@alignCast(ctx));
    self.backing.rawFree(memory, alignment, ret_addr);
}

const operation_fixture_vtable: Allocator.VTable = .{
    .alloc = operationFixtureAlloc,
    .resize = operationFixtureResize,
    .remap = operationFixtureRemap,
    .free = operationFixtureFree,
};

fn ownedRequestEvent(
    operation_id: u64,
    operation: observe.Operation,
    generation: u64,
    address: usize,
    old_address: usize,
    len: usize,
    old_len: usize,
    return_address: usize,
    succeeded: bool,
) observe.Event {
    return .{
        .operation_id = operation_id,
        .parent_operation_id = 0,
        .producer_id = 9001,
        .producer = .arena,
        .generation = generation,
        .owner_cookie = 0xcafe,
        .operation = operation,
        .lifecycle_disposition = .none,
        .lifecycle_reason = .none,
        .address = address,
        .old_address = old_address,
        .len = len,
        .old_len = old_len,
        .alignment = 8,
        .return_address = return_address,
        .succeeded = succeeded,
    };
}

fn ownedLifecycleEvent(
    operation_id: u64,
    generation: u64,
    disposition: observe.LifecycleDisposition,
    reason: observe.LifecycleReason,
    return_address: usize,
) observe.Event {
    return .{
        .operation_id = operation_id,
        .parent_operation_id = 0,
        .producer_id = 9001,
        .producer = .arena,
        .generation = generation,
        .owner_cookie = 0xcafe,
        .operation = .lifecycle,
        .lifecycle_disposition = disposition,
        .lifecycle_reason = reason,
        .address = 0,
        .old_address = 0,
        .len = 0,
        .old_len = 0,
        .alignment = 1,
        .return_address = return_address,
        .succeeded = true,
    };
}

noinline fn captureSummaryReturnAddress() usize {
    const return_address = @returnAddress();
    std.mem.doNotOptimizeAway(return_address);
    return return_address;
}

noinline fn summaryAttributionSource(tracer: *Tracer) !usize {
    const return_address = captureSummaryReturnAddress();
    try tracer.recordOwnedEvent(ownedRequestEvent(
        41,
        .alloc,
        0,
        0x5100,
        0,
        80,
        0,
        return_address,
        true,
    ));
    try tracer.recordOwnedEvent(ownedLifecycleEvent(
        42,
        0,
        .end,
        .deinit,
        return_address,
    ));
    std.mem.doNotOptimizeAway(tracer);
    return return_address;
}

test "summary-only request attribution retains exact symbolizable binary" {
    if (comptime @import("builtin").os.tag != .linux) {
        return error.SkipZigTest;
    }
    var tracer = try Tracer.init(std.testing.allocator, .{
        .capture_executable_identity = true,
    });
    defer tracer.deinit();
    const expected_address: u64 = @intCast(
        try summaryAttributionSource(&tracer),
    );

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root_path = try temporary.dir.realPathFileAlloc(
        std.Options.debug_io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root_path);
    const summary_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root_path, "summary.jsonl" },
    );
    defer std.testing.allocator.free(summary_path);
    try tracer.writeExecutableArtifactPath(summary_path);

    var summary = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer summary.deinit();
    try tracer.writeExecutableMetadata(&summary.writer);
    try tracer.writeSummaryJsonl(&summary.writer, .{
        .layer = .logical_allocator,
        .include_zero_live = true,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary.written(),
        "\"meta\":\"memtrace.executable\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary.written(),
        "\"kind\":\"request_site\"",
    ) != null);
    var address_buffer: [64]u8 = undefined;
    const address_text = try std.fmt.bufPrint(
        &address_buffer,
        "\"return_address\":{d}",
        .{expected_address},
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary.written(),
        address_text,
    ) != null);

    const artifact_path = try stack_mod.identity.artifactPathAlloc(
        std.testing.allocator,
        summary_path,
    );
    defer std.testing.allocator.free(artifact_path);
    var symbols = try stack_mod.symbolize.resolveAlloc(
        std.testing.allocator,
        artifact_path,
        &.{expected_address},
    );
    defer symbols.deinit(std.testing.allocator);
    const frames = symbols.find(expected_address);
    try std.testing.expect(frames.len != 0);
    var found_source = false;
    for (frames) |frame| {
        if (std.mem.indexOf(
            u8,
            frame.function,
            "summaryAttributionSource",
        ) == null) continue;
        if (std.mem.indexOf(u8, frame.location, "tracer.zig:") == null) {
            continue;
        }
        found_source = true;
        break;
    }
    try std.testing.expect(found_source);
}

test "owned lifecycle permits deterministic same-address reuse" {
    var tracer = try Tracer.init(std.testing.allocator, .{
        .record_events = true,
    });
    defer tracer.deinit();

    try tracer.recordOwnedEvent(ownedRequestEvent(
        1,
        .alloc,
        0,
        0x1000,
        0,
        64,
        0,
        0x101,
        true,
    ));
    try tracer.recordOwnedEvent(ownedLifecycleEvent(
        2,
        0,
        .invalidate,
        .reset,
        0x102,
    ));
    try tracer.recordOwnedEvent(ownedRequestEvent(
        3,
        .alloc,
        1,
        0x1000,
        0,
        64,
        0,
        0x103,
        true,
    ));
    try tracer.recordOwnedEvent(ownedRequestEvent(
        4,
        .free,
        1,
        0x1000,
        0x1000,
        0,
        64,
        0x104,
        true,
    ));
    try tracer.recordOwnedEvent(ownedLifecycleEvent(
        5,
        1,
        .end,
        .deinit,
        0x105,
    ));

    const counters = tracer.countersForLayer(.logical_allocator);
    try std.testing.expectEqual(@as(u64, 2), counters.allocations);
    try std.testing.expectEqual(@as(u64, 1), counters.frees);
    try std.testing.expectEqual(
        @as(u64, 1),
        counters.bulk_invalidated_requests,
    );
    try std.testing.expectEqual(@as(usize, 64), counters.bulk_invalidated_bytes);
    try std.testing.expectEqual(@as(usize, 0), counters.live_allocations);
    try std.testing.expectEqual(@as(usize, 0), counters.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), tracer.allocations.count());
    try std.testing.expectEqual(@as(usize, 0), tracer.anomaly_site_count);

    var releases: u64 = 0;
    var lifecycles: u64 = 0;
    for (tracer.events.items) |event| {
        if (event.kind == .release) releases += 1;
        if (event.kind == .lifecycle) lifecycles += 1;
    }
    try std.testing.expectEqual(@as(u64, 1), releases);
    try std.testing.expectEqual(@as(u64, 2), lifecycles);

    var summary = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer summary.deinit();
    try tracer.writeSummaryJsonl(&summary.writer, .{
        .layer = .logical_allocator,
        .include_zero_live = true,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary.written(),
        "\"open_requests\":0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary.written(),
        "\"bulk_invalidated_requests\":1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary.written(),
        "\"lifecycle_coverage\":\"complete\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary.written(),
        "\"kind\":\"request_site\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary.written(),
        "\"request_site_attribution_exact\":true",
    ) != null);
    try std.testing.expect(
        std.mem.indexOf(u8, summary.written(), "\"live_bytes\"") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, summary.written(), "\"retained_bytes\"") == null,
    );
}

test "owned anomalies retain bounded exact call-site attribution" {
    var tracer = try Tracer.init(std.testing.allocator, .{
        .anomaly_site_capacity = 4,
        .request_site_capacity = 2,
    });
    defer tracer.deinit();

    try tracer.recordOwnedEvent(ownedRequestEvent(
        1,
        .alloc,
        0,
        0x1000,
        0,
        64,
        0,
        0x201,
        true,
    ));
    try tracer.recordOwnedEvent(ownedRequestEvent(
        2,
        .alloc,
        0,
        0x1000,
        0,
        32,
        0,
        0x202,
        true,
    ));
    try tracer.recordOwnedEvent(ownedRequestEvent(
        3,
        .resize,
        0,
        0,
        0x2000,
        48,
        24,
        0x203,
        true,
    ));
    try tracer.recordOwnedEvent(ownedRequestEvent(
        4,
        .remap,
        0,
        0x3100,
        0x3000,
        96,
        48,
        0x204,
        true,
    ));
    try tracer.recordOwnedEvent(ownedRequestEvent(
        5,
        .free,
        0,
        0x4000,
        0x4000,
        0,
        16,
        0x205,
        true,
    ));
    try tracer.recordOwnedEvent(ownedRequestEvent(
        6,
        .free,
        0,
        0x1000,
        0x1000,
        0,
        63,
        0x206,
        true,
    ));

    const counters = tracer.countersForLayer(.logical_allocator);
    try std.testing.expectEqual(@as(u64, 1), counters.unmatched_frees);
    try std.testing.expectEqual(@as(u64, 1), counters.unmatched_resizes);
    try std.testing.expectEqual(@as(u64, 1), counters.unmatched_remaps);
    try std.testing.expectEqual(@as(usize, 4), tracer.anomaly_site_count);
    try std.testing.expectEqual(@as(u64, 1), tracer.anomaly_sites_dropped);

    var summary = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer summary.deinit();
    try tracer.writeSummaryJsonl(&summary.writer, .{
        .layer = .logical_allocator,
        .include_zero_live = true,
    });
    const text = summary.written();
    try std.testing.expect(
        std.mem.indexOf(u8, text, "\"anomaly_sites_dropped\":1") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            text,
            "\"anomaly_attribution_exact\":false",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            text,
            "\"request_site_unaggregated_calls\":4",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            text,
            "\"request_site_attribution_exact\":false",
        ) != null,
    );
    inline for (.{ "alloc", "resize", "remap", "free" }) |operation| {
        var needle_buffer: [48]u8 = undefined;
        const needle = try std.fmt.bufPrint(
            &needle_buffer,
            "\"operation\":\"{s}\"",
            .{operation},
        );
        try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
}

test "exact attribution separates callers behind one allocation site" {
    var tracer = try Tracer.init(std.testing.allocator, .{
        .record_events = true,
        .allocation_attribution = .stack,
    });
    defer tracer.deinit();
    var traced = try tracer.tracedAllocator(std.testing.allocator, "exact");
    const allocator = traced.allocator();
    const first = try allocationCallerA(allocator);
    const second = try allocationCallerB(allocator);
    defer allocator.free(first);
    defer allocator.free(second);

    var first_event: ?Event = null;
    var second_event: ?Event = null;
    for (tracer.events.items) |recorded| {
        if (recorded.kind != .alloc) continue;
        if (first_event == null) {
            first_event = recorded;
        } else {
            second_event = recorded;
            break;
        }
    }
    try std.testing.expect(first_event != null);
    try std.testing.expect(second_event != null);
    try std.testing.expectEqual(
        first_event.?.return_address,
        second_event.?.return_address,
    );
    try std.testing.expect(first_event.?.stack_id != 0);
    try std.testing.expect(second_event.?.stack_id != 0);
    try std.testing.expect(first_event.?.stack_id != second_event.?.stack_id);
    try std.testing.expect(
        tracer.stacks.recordForId(first_event.?.stack_id).complete(),
    );
    try std.testing.expect(
        tracer.stacks.recordForId(second_event.?.stack_id).complete(),
    );
}

test "exact attribution covers every operation and failed outcome" {
    var tracer = try Tracer.init(std.testing.allocator, .{
        .record_events = true,
        .allocation_attribution = .stack,
    });
    defer tracer.deinit();
    var fixture = OperationFixtureAllocator{ .backing = std.testing.allocator };
    var traced = try tracer.tracedAllocator(fixture.allocator(), "operations");
    const allocator = traced.allocator();

    const bytes = try allocator.alloc(u8, 8);
    try std.testing.expect(!allocator.resize(bytes, 16));
    try std.testing.expect(allocator.remap(bytes, 16) == null);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 13));
    allocator.free(bytes);

    var calls: u64 = 0;
    var successes: u64 = 0;
    var failures: u64 = 0;
    for (tracer.events.items) |event| {
        if (!event.kind.isMemoryOperation()) continue;
        calls += 1;
        if (event.succeeded) {
            successes += 1;
        } else {
            failures += 1;
        }
        try std.testing.expect(event.stack_id != 0);
        try std.testing.expect(
            tracer.stacks.recordForId(event.stack_id).complete(),
        );
    }
    try std.testing.expectEqual(@as(u64, 5), calls);
    try std.testing.expectEqual(@as(u64, 2), successes);
    try std.testing.expectEqual(@as(u64, 3), failures);
    try std.testing.expectEqual(@as(u64, 0), tracer.recording_failures);
}

test "zero-length and predispatch failures have no memory effect" {
    var tracer = try Tracer.init(std.testing.allocator, .{
        .record_events = true,
    });
    defer tracer.deinit();
    var traced = try tracer.tracedAllocator(std.testing.allocator, "requests");
    const allocator = traced.allocator();
    const before = tracer.snapshot();

    const empty = try allocator.alloc(u8, 0);
    allocator.free(empty);
    const impossible_count = std.math.maxInt(usize);
    try std.testing.expectError(
        error.OutOfMemory,
        allocator.alloc(u64, impossible_count),
    );

    const after = tracer.snapshot();
    try std.testing.expectEqual(before, after);
    for (tracer.events.items) |event| {
        try std.testing.expect(!event.kind.isMemoryOperation());
    }
}

test "nested traced allocator identities may own the same address" {
    var tracer = try Tracer.init(std.testing.allocator, .{ .record_events = true });
    defer tracer.deinit();
    var backing = try tracer.tracedAllocator(std.testing.allocator, "backing");
    var logical = try tracer.tracedAllocator(backing.allocator(), "logical");
    const allocator = logical.allocator();

    const bytes = try allocator.alloc(u8, 32);
    allocator.free(bytes);

    var allocations: u64 = 0;
    var frees: u64 = 0;
    for (tracer.events.items) |event| {
        switch (event.kind) {
            .alloc => allocations += 1,
            .free => frees += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(u64, 2), allocations);
    try std.testing.expectEqual(@as(u64, 2), frees);
    try std.testing.expectEqual(
        @as(u64, 0),
        tracer.countersForLayer(.backing_boundary).unmatched_frees,
    );
    try std.testing.expectEqual(@as(usize, 0), tracer.allocations.count());
}

test "traced allocator attributes live allocations to scopes" {
    var tracer = try Tracer.init(std.testing.allocator, .{});
    defer tracer.deinit();

    var traced = try tracer.tracedAllocator(std.testing.allocator, "test.heap");
    const allocator = traced.allocator();

    var outer = try tracer.enter("outer");
    const first = try allocator.alloc(u8, 32);
    errdefer allocator.free(first);
    var inner = try tracer.enter("inner");
    const second = try allocator.alloc(u8, 16);
    inner.exit();
    allocator.free(second);
    outer.exit();

    const snap = tracer.snapshot();
    try std.testing.expectEqual(@as(usize, 32), snap.live_bytes);
    try std.testing.expectEqual(@as(usize, 2), snap.allocations);
    try std.testing.expectEqual(@as(usize, 1), snap.frees);
    try std.testing.expectEqual(@as(u64, 1), snap.completed_lifetimes);
    try std.testing.expectEqual(@as(u64, 2), snap.lifetime_total_events);
    try std.testing.expectEqual(@as(u64, 2), snap.lifetime_max_events);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try tracer.writeSummary(&out.writer, .{ .top = 8 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "memtrace lifetimes completed=1 total_events=2 mean_events=2 max_events=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "root/outer retained_bytes=32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "live_bytes=32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "root/outer/inner retained_bytes=0 high_water_retained_bytes=16 live_bytes=0 high_water_live_bytes=16 allocated_bytes=16 freed_bytes=16 allocations=1 frees=1 live_allocations=0 completed_lifetimes=1 lifetime_total_events=2 lifetime_mean_events=2 lifetime_max_events=2") != null);

    var jsonl = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer jsonl.deinit();
    try tracer.writeSummaryJsonl(&jsonl.writer, .{ .top = 8 });
    try std.testing.expect(std.mem.indexOf(
        u8,
        jsonl.written(),
        "{\"kind\":\"summary\",\"layer\":\"backing_boundary\"," ++
            "\"allocations\":2,\"frees\":1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        jsonl.written(),
        "\"unmatched_frees\":0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        jsonl.written(),
        "\"kind\":\"scope\",\"layer\":\"backing_boundary\"," ++
            "\"scope\":\"root/outer/inner\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        jsonl.written(),
        "\"kind\":\"live_site\",\"layer\":\"backing_boundary\",",
    ) != null);

    allocator.free(first);
}

test "snapshot diffs report allocator deltas" {
    var tracer = try Tracer.init(std.testing.allocator, .{});
    defer tracer.deinit();

    var traced = try tracer.tracedAllocator(std.testing.allocator, "test.heap");
    const allocator = traced.allocator();
    const before = tracer.snapshot();
    const bytes = try allocator.alloc(u8, 24);
    const during = tracer.diff(before);
    try std.testing.expectEqual(@as(isize, 24), during.live_bytes);
    try std.testing.expectEqual(@as(u64, 1), during.allocations);
    allocator.free(bytes);
    const after_free = tracer.diff(before);
    try std.testing.expectEqual(@as(u64, 1), after_free.completed_lifetimes);
    try std.testing.expectEqual(@as(u64, 1), after_free.lifetime_total_events);
    try std.testing.expectEqual(@as(u64, 1), after_free.lifetime_max_events);
}

test "retaining allocator reports capacity pressure after logical frees" {
    var tracer = try Tracer.init(std.testing.allocator, .{});
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

    const snap = tracer.snapshot();
    try std.testing.expectEqual(@as(usize, 0), snap.live_bytes);
    try std.testing.expectEqual(@as(usize, 64), snap.retained_bytes);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try tracer.writeSummary(&out.writer, .{ .top = 8, .include_zero_live = true });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "root/phase retained_bytes=64") != null);
}

test "event log records alloc and free lines" {
    var tracer = try Tracer.init(std.testing.allocator, .{ .record_events = true });
    defer tracer.deinit();

    var traced = try tracer.tracedAllocator(std.testing.allocator, "test.heap");
    const allocator = traced.allocator();
    var scope = try tracer.enter("phase");
    const bytes = try allocator.alloc(u8, 8);
    allocator.free(bytes);
    scope.exit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try tracer.writeEventsJsonl(&out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "{\"v\":3,\"seq\":1,\"kind\":\"trace.start\"",
    ) != null);
    try std.testing.expect(std.mem.startsWith(
        u8,
        text,
        "{\"v\":3,\"meta\":\"memtrace.coverage\"",
    ));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"alloc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"free\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"scope\":\"root/phase\"") != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        text,
        "\"kind\":\"trace.stop\"}\n",
    ));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"trace.stop\"") != null);
}

test "observation publication window reconciles producer prefix floor" {
    var tracer = try Tracer.init(std.testing.allocator, .{
        .record_events = true,
    });
    defer tracer.deinit();
    const previous = tracer.markObservationProducerFloorPending();
    try std.testing.expectEqual(@as(u64, 0), previous);

    var preexisting = ownedRequestEvent(
        1,
        .alloc,
        0,
        0x7100,
        0,
        64,
        0,
        0x101,
        true,
    );
    preexisting.producer_id = 7001;
    try tracer.recordOwnedEvent(preexisting);
    var created_during_publication = ownedRequestEvent(
        2,
        .alloc,
        0,
        0x7300,
        0,
        32,
        0,
        0x102,
        true,
    );
    created_during_publication.producer_id = 7003;
    try tracer.recordOwnedEvent(created_during_publication);

    const preexisting_id = tracer.observed_allocators.get(.{
        .producer_id = preexisting.producer_id,
        .producer = preexisting.producer,
    }).?;
    const created_id = tracer.observed_allocators.get(.{
        .producer_id = created_during_publication.producer_id,
        .producer = created_during_publication.producer,
    }).?;
    try std.testing.expect(
        !tracer.allocators.items[preexisting_id].prefix_complete,
    );
    try std.testing.expect(
        tracer.allocators.items[preexisting_id]
            .observation_floor_pending,
    );
    try std.testing.expect(
        !tracer.allocators.items[created_id].prefix_complete,
    );
    try std.testing.expect(
        tracer.allocators.items[created_id]
            .observation_floor_pending,
    );

    tracer.reconcileObservationProducerFloor(7002);
    try std.testing.expect(
        !tracer.allocators.items[preexisting_id].prefix_complete,
    );
    try std.testing.expect(
        !tracer.allocators.items[preexisting_id]
            .observation_floor_pending,
    );
    try std.testing.expect(
        tracer.allocators.items[created_id].prefix_complete,
    );
    try std.testing.expect(
        !tracer.allocators.items[created_id]
            .observation_floor_pending,
    );
    var emitted_correction = false;
    for (tracer.events.items) |event| {
        if (event.kind != .allocator) continue;
        if (event.allocator_id != created_id) continue;
        if (!event.observation_prefix_complete) continue;
        emitted_correction = true;
        break;
    }
    try std.testing.expect(emitted_correction);
}

test "lifecycle coverage treats release-explicit producer as not required" {
    var tracer = try Tracer.init(std.testing.allocator, .{});
    defer tracer.deinit();
    try tracer.recordOwnedEvent(ownedRequestEvent(
        1,
        .alloc,
        0,
        0x8100,
        0,
        64,
        0,
        0x201,
        true,
    ));
    var limit = ownedRequestEvent(
        2,
        .alloc,
        0,
        0x8200,
        0,
        32,
        0,
        0x202,
        true,
    );
    limit.producer_id = 9002;
    limit.producer = .limit;
    try tracer.recordOwnedEvent(limit);

    var summary = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer summary.deinit();
    try tracer.writeSummaryJsonl(&summary.writer, .{
        .layer = .logical_allocator,
        .include_zero_live = true,
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

test "owned logical operations correlate nested backing boundaries" {
    if (!observe.enabled) return error.SkipZigTest;
    var tracer = try Tracer.init(std.testing.allocator, .{
        .record_events = true,
    });
    defer tracer.deinit();
    var backing = try tracer.tracedAllocator(
        sys.memory.page_allocator,
        "backing",
    );
    var observation = try tracer.observeOwnedAllocators();
    defer observation.stop();
    var arena = std.heap.ArenaAllocator.init(backing.allocator());
    defer arena.deinit();
    const backing_before = tracer.snapshotLayer(.backing_boundary);
    const logical_before = tracer.snapshotLayer(.logical_allocator);

    const producer_id = observe.producerId();
    var span = observe.begin(
        producer_id,
        .arena,
        .alloc,
        0,
        0,
        48,
        8,
        @returnAddress(),
    );
    const address = arena.allocator().rawAlloc(
        48,
        .@"8",
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    span.finish(.{
        .address = @intFromPtr(address),
        .succeeded = true,
    });

    var logical: ?Event = null;
    var boundary: ?Event = null;
    for (tracer.events.items) |event| {
        if (event.kind != .alloc) continue;
        switch (event.layer) {
            .logical_allocator => logical = event,
            .backing_boundary => boundary = event,
            .physical_page => {},
        }
    }
    const logical_event = logical orelse
        return error.MissingLogicalAllocation;
    const boundary_event = boundary orelse
        return error.MissingBackingAllocation;
    try std.testing.expectEqual(
        logical_event.operation_id,
        boundary_event.parent_operation_id,
    );
    try std.testing.expectEqual(producer_id, logical_event.producer_id);
    try std.testing.expectEqual(
        observe.Producer.arena,
        logical_event.producer,
    );
    try std.testing.expectEqual(
        observe.Producer.boundary,
        boundary_event.producer,
    );
    const backing_difference = tracer.diffLayer(.backing_boundary, backing_before);
    const logical_difference = tracer.diffLayer(.logical_allocator, logical_before);
    try std.testing.expectEqual(@as(u64, 1), backing_difference.allocations);
    try std.testing.expectEqual(@as(u64, 1), logical_difference.allocations);
    try std.testing.expect(backing_difference.allocated_bytes > 48);
    try std.testing.expectEqual(@as(usize, 48), logical_difference.allocated_bytes);

    var logical_summary = std.Io.Writer.Allocating.init(
        std.testing.allocator,
    );
    defer logical_summary.deinit();
    try tracer.writeSummary(
        &logical_summary.writer,
        .{ .layer = .logical_allocator },
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        logical_summary.written(),
        "memtrace layer=logical_allocator allocations=1",
    ) != null);
    try std.testing.expectEqual(@as(u64, 0), tracer.recording_failures);
}

test "observer control remains isolated when backing allocators alias" {
    if (!observe.enabled) return error.SkipZigTest;
    var tracer = try Tracer.init(std.testing.allocator, .{
        .record_events = true,
    });
    defer tracer.deinit();
    var traced = try tracer.tracedAllocator(
        std.testing.allocator,
        "aliased",
    );
    var observation = try tracer.observeOwnedAllocators();
    defer observation.stop();
    const bytes = try traced.allocator().alloc(u8, 32);
    traced.allocator().free(bytes);
    try std.testing.expectEqual(
        @as(u64, 1),
        tracer.snapshot().allocations,
    );
    try std.testing.expect(tracer.observerControlOperations() > 0);
    try std.testing.expectEqual(@as(u64, 0), tracer.recording_failures);
}

test "owned observation correlates logical backing and physical operations" {
    if (!observe.enabled) return error.SkipZigTest;
    if (!sys.memory.anonymousMappingSupported()) return error.SkipZigTest;
    var tracer = try Tracer.init(std.testing.allocator, .{
        .record_events = true,
    });
    defer tracer.deinit();
    var backing = try tracer.tracedAllocator(
        sys.memory.page_allocator,
        "owned.page",
    );
    var observation = try tracer.observeOwnedAllocators();
    defer observation.stop();

    const producer_id = observe.producerId();
    var logical_span = observe.begin(
        producer_id,
        .custom,
        .alloc,
        0,
        0,
        33,
        1,
        @returnAddress(),
    );
    const bytes = try backing.allocator().alloc(u8, 33);
    logical_span.finish(.{
        .address = @intFromPtr(bytes.ptr),
        .succeeded = true,
    });

    var logical: ?Event = null;
    var boundary: ?Event = null;
    var physical: ?Event = null;
    for (tracer.events.items) |recorded| {
        if (recorded.kind != .alloc and recorded.kind != .map) continue;
        switch (recorded.layer) {
            .logical_allocator => logical = recorded,
            .backing_boundary => boundary = recorded,
            .physical_page => physical = recorded,
        }
    }
    const logical_event = logical orelse
        return error.MissingLogicalAllocation;
    const boundary_event = boundary orelse
        return error.MissingBackingAllocation;
    const physical_event = physical orelse
        return error.MissingPhysicalMapping;
    try std.testing.expectEqual(
        logical_event.operation_id,
        boundary_event.parent_operation_id,
    );
    try std.testing.expectEqual(
        boundary_event.operation_id,
        physical_event.parent_operation_id,
    );
    try std.testing.expectEqual(
        observe.Producer.sys_memory,
        physical_event.producer,
    );
    try std.testing.expect(physical_event.operation_id != 0);
    try std.testing.expectEqual(@as(u64, 0), tracer.recording_failures);

    backing.allocator().free(bytes);
}

test "owned observation fails closed when not compiled" {
    if (observe.enabled) return error.SkipZigTest;
    var tracer = try Tracer.init(std.testing.allocator, .{});
    defer tracer.deinit();
    try std.testing.expectError(
        error.AllocatorObservationNotCompiled,
        tracer.observeOwnedAllocators(),
    );
}

test "optional owned observation follows compiled capability" {
    var tracer = try Tracer.init(std.testing.allocator, .{});
    defer tracer.deinit();
    var observation = try tracer.observeOwnedAllocatorsIfAvailable();
    if (comptime observe.enabled) {
        try std.testing.expect(observation != null);
        observation.?.stop();
    } else {
        try std.testing.expect(observation == null);
    }
}

test "event log can stream without retaining records" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var tracer = try Tracer.init(std.testing.allocator, .{
        .record_events = true,
        .event_writer = &out.writer,
    });
    defer tracer.deinit();

    var traced = try tracer.tracedAllocator(std.testing.allocator, "test.heap");
    const allocator = traced.allocator();
    var scope = try tracer.enter("phase");
    const bytes = try allocator.alloc(u8, 8);
    allocator.free(bytes);
    scope.exit();
    try tracer.finishEvents();

    try std.testing.expectEqual(@as(usize, 0), tracer.events.items.len);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"trace.start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"alloc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"free\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"scope\":\"root/phase\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "\"universe\":\"registered_allocator_handles\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"trace.stop\"") != null);
}

test "streamed coverage records the final observed universe" {
    if (!observe.enabled) return error.SkipZigTest;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var tracer = try Tracer.init(std.testing.allocator, .{
        .record_events = true,
        .event_writer = &output.writer,
    });
    defer tracer.deinit();
    var observation = try tracer.observeOwnedAllocators();
    observation.stop();
    try tracer.finishEvents();

    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "\"universe\":\"process_memory_operations_during_trace_epoch\"",
    ) != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            output.written(),
            "\"meta\":\"memtrace.coverage\"",
        ),
    );
}

test "observer control allocation is counted and physically isolated" {
    if (!observe.enabled) return error.SkipZigTest;
    var tracer = try Tracer.init(sys.memory.page_allocator, .{});
    defer tracer.deinit();
    var observation = try tracer.observeOwnedAllocators();
    defer observation.stop();
    const before = tracer.snapshotLayer(.physical_page);
    inline for (.{
        "control.one",
        "control.two",
        "control.three",
        "control.four",
        "control.five",
        "control.six",
        "control.seven",
        "control.eight",
    }) |label| {
        var scope = try tracer.enter(label);
        scope.exit();
    }
    const after = tracer.snapshotLayer(.physical_page);
    try std.testing.expect(tracer.observerControlOperations() > 0);
    try std.testing.expectEqual(
        before.allocated_bytes,
        after.allocated_bytes,
    );
    try std.testing.expectEqual(
        before.freed_bytes,
        after.freed_bytes,
    );
}

test "event serialization rejects unretained streams" {
    var tracer = try Tracer.init(std.testing.allocator, .{});
    defer tracer.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.EventsNotRetained, tracer.writeEventsJsonl(&out.writer));
}
