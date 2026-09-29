const std = @import("std");
const sys = @import("sys");
const observe = @import("alloc_observe");
const pretty_json = @import("pretty").json;
const memtrace = @import("../root.zig");
const analyze_mod = @import("analyze.zig");
const capture_mod = @import("capture.zig");
const identity_mod = @import("identity.zig");
const symbolize_mod = @import("symbolize.zig");

const coverage_mod = memtrace.coverage;
const event_mod = memtrace.event;

const Allocator = std.mem.Allocator;

pub const Format = enum {
    text,
    jsonl,
};

pub const Sort = enum {
    roots,
    requested_bytes,
    backing_bytes,
    high_water,
};

pub const Detail = enum {
    summary,
    sources,
    full,
};

pub const Options = struct {
    top: usize = std.math.maxInt(usize),
    frame_limit: usize = capture_mod.max_frames_limit,
    format: Format = .text,
    binary_path: ?[]const u8 = null,
    selection: analyze_mod.Selection = .allocations,
    sort: Sort = .high_water,
    detail: Detail = .full,
    window: analyze_mod.Window = .{},
};

const Metrics = struct {
    operations: u64 = 0,
    logical_operations: u64 = 0,
    backing_operations: u64 = 0,
    physical_operations: u64 = 0,
    backing_requested_bytes: u128 = 0,
    physical_requested_bytes: u128 = 0,
    max_depth: u32 = 0,

    fn record(self: *Metrics, event: event_mod.ReplayEvent) !void {
        self.operations = try std.math.add(u64, self.operations, 1);
        const bytes = requestBytes(event);
        switch (event.layer) {
            .logical_allocator => {
                self.logical_operations = try std.math.add(
                    u64,
                    self.logical_operations,
                    1,
                );
            },
            .backing_boundary => {
                self.backing_operations = try std.math.add(
                    u64,
                    self.backing_operations,
                    1,
                );
                self.backing_requested_bytes = try std.math.add(
                    u128,
                    self.backing_requested_bytes,
                    bytes,
                );
            },
            .physical_page => {
                self.physical_operations = try std.math.add(
                    u64,
                    self.physical_operations,
                    1,
                );
                self.physical_requested_bytes = try std.math.add(
                    u128,
                    self.physical_requested_bytes,
                    bytes,
                );
            },
        }
    }

    fn merge(self: *Metrics, other: Metrics) !void {
        self.operations = try std.math.add(
            u64,
            self.operations,
            other.operations,
        );
        self.logical_operations = try std.math.add(
            u64,
            self.logical_operations,
            other.logical_operations,
        );
        self.backing_operations = try std.math.add(
            u64,
            self.backing_operations,
            other.backing_operations,
        );
        self.physical_operations = try std.math.add(
            u64,
            self.physical_operations,
            other.physical_operations,
        );
        self.backing_requested_bytes = try std.math.add(
            u128,
            self.backing_requested_bytes,
            other.backing_requested_bytes,
        );
        self.physical_requested_bytes = try std.math.add(
            u128,
            self.physical_requested_bytes,
            other.physical_requested_bytes,
        );
        self.max_depth = @max(self.max_depth, other.max_depth);
    }

    fn mergeChild(self: *Metrics, child: Metrics) !void {
        try self.merge(child);
        self.max_depth = @max(
            self.max_depth,
            try std.math.add(u32, child.max_depth, 1),
        );
    }
};

const RootKey = struct {
    stack_id: u32,
    kind: event_mod.Kind,
    succeeded: bool,
    layer: event_mod.Layer,
    producer: observe.Producer,
};

const Lifetime = struct {
    live_allocations: u64 = 0,
    live_bytes: u128 = 0,
    high_water_live_bytes: u128 = 0,

    fn allocate(self: *Lifetime, len: usize) !void {
        self.live_allocations = try std.math.add(
            u64,
            self.live_allocations,
            1,
        );
        self.live_bytes = try std.math.add(u128, self.live_bytes, len);
        self.high_water_live_bytes = @max(
            self.high_water_live_bytes,
            self.live_bytes,
        );
    }

    fn free(self: *Lifetime, len: usize) !void {
        if (self.live_allocations == 0 or self.live_bytes < len) {
            return error.InvalidCausalRootLifetime;
        }
        self.live_allocations -= 1;
        self.live_bytes -= len;
    }

    fn resize(self: *Lifetime, old_len: usize, new_len: usize) !void {
        if (self.live_bytes < old_len) {
            return error.InvalidCausalRootLifetime;
        }
        self.live_bytes -= old_len;
        self.live_bytes = try std.math.add(u128, self.live_bytes, new_len);
        self.high_water_live_bytes = @max(
            self.high_water_live_bytes,
            self.live_bytes,
        );
    }
};

const Counters = struct {
    roots: u64 = 0,
    root_requested_bytes: u128 = 0,
    metrics: Metrics = .{},
    lifetime: Lifetime = .{},

    fn record(
        self: *Counters,
        event: event_mod.ReplayEvent,
        metrics: Metrics,
    ) !void {
        self.roots = try std.math.add(u64, self.roots, 1);
        self.root_requested_bytes = try std.math.add(
            u128,
            self.root_requested_bytes,
            requestBytes(event),
        );
        try self.metrics.merge(metrics);
    }

    fn merge(self: *Counters, other: Counters) !void {
        self.roots = try std.math.add(u64, self.roots, other.roots);
        self.root_requested_bytes = try std.math.add(
            u128,
            self.root_requested_bytes,
            other.root_requested_bytes,
        );
        try self.metrics.merge(other.metrics);
    }
};

const Summary = struct {
    key: RootKey,
    counters: Counters,
    definition: analyze_mod.Definition,
};

const Totals = struct {
    roots: u64 = 0,
    successful: u64 = 0,
    failed: u64 = 0,
    root_requested_bytes: u128 = 0,
    metrics: Metrics = .{},
    lifetime: Lifetime = .{},
};

const SourceKey = struct {
    kind: event_mod.Kind,
    succeeded: bool,
    layer: event_mod.Layer,
    producer: observe.Producer,
    site: u64,
    caller: u64,
};

const Source = struct {
    key: SourceKey,
    counters: Counters,
    unique_stacks: u32,
};

const LiveAllocation = struct {
    root: RootKey,
    source: SourceKey,
    len: usize,
};

const Display = struct {
    source_groups: usize,
    displayed_sources: usize,
    root_stacks: usize,
    displayed_stacks: usize,
};

const ChildEvidence = struct {
    operation_id: u64,
    sequence: u64,
    stack_id: u32,
    scope_id: u32,
    kind: event_mod.Kind,
    layer: event_mod.Layer,
    producer: observe.Producer,
    succeeded: bool,
    requested_bytes: usize,
    return_address: u64,

    fn fromEvent(event: event_mod.ReplayEvent) ChildEvidence {
        return .{
            .operation_id = event.operation_id,
            .sequence = event.seq orelse 0,
            .stack_id = event.stack_id,
            .scope_id = event.scope_id,
            .kind = event.kind,
            .layer = event.layer,
            .producer = event.producer,
            .succeeded = event.succeeded,
            .requested_bytes = if (event.kind.isMemoryOperation())
                requestBytes(event)
            else
                0,
            .return_address = event.return_address,
        };
    }
};

const Pending = struct {
    metrics: Metrics = .{},
    child: ChildEvidence,
};

const DanglingParent = struct {
    operation_id: u64,
    child: ChildEvidence,
    site_address: u64,
};

const OperationLedger = struct {
    seen: std.DynamicBitSetUnmanaged = .{},
    unique: u64 = 0,
    minimum: u64 = std.math.maxInt(u64),
    maximum: u64 = 0,
    last_id: u64 = 0,
    last_parent: u64 = 0,

    fn deinit(self: *OperationLedger, allocator: Allocator) void {
        self.seen.deinit(allocator);
        self.* = undefined;
    }

    fn record(
        self: *OperationLedger,
        allocator: Allocator,
        operation_id: u64,
        parent_operation_id: u64,
    ) !void {
        const index = std.math.cast(usize, operation_id) orelse
            return error.CausalOperationIdOverflow;
        try self.ensureCapacity(allocator, index);
        if (self.seen.isSet(index)) {
            if (operation_id != self.last_id) {
                return error.NonContiguousCausalOperationGroup;
            }
            if (parent_operation_id != self.last_parent) {
                return error.CausalOperationParentConflict;
            }
            return;
        }
        self.seen.set(index);
        self.unique = try std.math.add(u64, self.unique, 1);
        self.minimum = @min(self.minimum, operation_id);
        self.maximum = @max(self.maximum, operation_id);
        self.last_id = operation_id;
        self.last_parent = parent_operation_id;
    }

    fn ensureCapacity(
        self: *OperationLedger,
        allocator: Allocator,
        index: usize,
    ) !void {
        if (index < self.seen.bit_length) return;
        const required = try std.math.add(usize, index, 1);
        const doubled = std.math.mul(
            usize,
            @max(self.seen.bit_length, 1024),
            2,
        ) catch std.math.maxInt(usize);
        try self.seen.resize(allocator, @max(required, doubled), false);
    }

    fn validate(self: OperationLedger) !void {
        if (self.unique == 0) return;
        const span = try std.math.add(
            u64,
            self.maximum - self.minimum,
            1,
        );
        if (span != self.unique) return error.NonContiguousCausalOperations;
    }
};

const Analyzer = struct {
    allocator: Allocator,
    stack: analyze_mod.Analyzer,
    pending: std.AutoHashMapUnmanaged(u64, Pending) = .{},
    groups: std.AutoHashMapUnmanaged(RootKey, Counters) = .{},
    source_lifetimes: std.AutoHashMapUnmanaged(SourceKey, Lifetime) = .{},
    live_allocations: std.AutoHashMapUnmanaged(u64, LiveAllocation) = .{},
    operation_ledger: OperationLedger = .{},
    lifetime: Lifetime = .{},
    finished: bool = false,

    fn init(allocator: Allocator, window: analyze_mod.Window) Analyzer {
        return .{
            .allocator = allocator,
            .stack = analyze_mod.Analyzer.init(allocator, window),
        };
    }

    fn deinit(self: *Analyzer) void {
        self.stack.deinit();
        self.pending.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.source_lifetimes.deinit(self.allocator);
        self.live_allocations.deinit(self.allocator);
        self.operation_ledger.deinit(self.allocator);
        self.* = undefined;
    }

    fn ingestJsonLine(self: *Analyzer, line: []const u8) !void {
        if (self.finished) return error.CausalRootAnalyzerFinished;
        const text = std.mem.trim(u8, line, " \t\r\n");
        if (text.len == 0) return;
        try self.stack.ingestJsonLine(text);
        if (identity_mod.isMetadataLine(text) or
            coverage_mod.isMetadataLine(text) or
            capture_mod.isMetadataLine(text))
        {
            return;
        }
        var line_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer line_arena.deinit();
        const event = try event_mod.parseReplay(line_arena.allocator(), text);
        const memory_operation = event.kind.isMemoryOperation();
        if (!memory_operation and event.kind != .lifecycle) return;
        if (event.operation_id == 0) return error.MissingCausalOperation;
        if (event.parent_operation_id >= event.operation_id and
            event.parent_operation_id != 0)
        {
            return error.CausalOperationCycle;
        }
        if (memory_operation) try self.recordExistingLifetime(event);
        try self.operation_ledger.record(
            self.allocator,
            event.operation_id,
            event.parent_operation_id,
        );

        var metrics = if (self.pending.fetchRemove(event.operation_id)) |entry|
            entry.value.metrics
        else
            Metrics{};
        if (memory_operation) try metrics.record(event);
        if (event.parent_operation_id == 0) {
            if (!memory_operation) return;
            if (!try self.stack.includes(event)) return;
            return self.recordRoot(event, metrics);
        }
        const parent = try self.pending.getOrPut(
            self.allocator,
            event.parent_operation_id,
        );
        if (!parent.found_existing) {
            parent.value_ptr.* = .{
                .child = ChildEvidence.fromEvent(event),
            };
        }
        if (memory_operation) {
            try parent.value_ptr.metrics.mergeChild(metrics);
        } else {
            try parent.value_ptr.metrics.merge(metrics);
        }
    }

    fn finish(self: *Analyzer) !void {
        if (self.finished) return error.CausalRootAnalyzerFinished;
        try self.stack.validate();
        try self.finishCausal();
    }

    fn finishCausal(self: *Analyzer) !void {
        if (self.finished) return error.CausalRootAnalyzerFinished;
        if (self.pending.count() != 0) return error.DanglingParentOperation;
        try self.operation_ledger.validate();
        try self.validateLifetimes();
        self.finished = true;
    }

    fn validateLifetimes(self: *const Analyzer) !void {
        var group_allocations: u64 = 0;
        var group_bytes: u128 = 0;
        var groups = self.groups.valueIterator();
        while (groups.next()) |counters| {
            group_allocations = try std.math.add(
                u64,
                group_allocations,
                counters.lifetime.live_allocations,
            );
            group_bytes = try std.math.add(
                u128,
                group_bytes,
                counters.lifetime.live_bytes,
            );
        }
        var source_allocations: u64 = 0;
        var source_bytes: u128 = 0;
        var sources = self.source_lifetimes.valueIterator();
        while (sources.next()) |lifetime| {
            source_allocations = try std.math.add(
                u64,
                source_allocations,
                lifetime.live_allocations,
            );
            source_bytes = try std.math.add(
                u128,
                source_bytes,
                lifetime.live_bytes,
            );
        }
        if (group_allocations != self.lifetime.live_allocations or
            source_allocations != self.lifetime.live_allocations or
            self.live_allocations.count() != self.lifetime.live_allocations or
            group_bytes != self.lifetime.live_bytes or
            source_bytes != self.lifetime.live_bytes)
        {
            return error.InvalidCausalRootLifetime;
        }
    }

    fn collectDangling(
        self: *const Analyzer,
    ) !std.ArrayListUnmanaged(DanglingParent) {
        var result = std.ArrayListUnmanaged(DanglingParent).empty;
        errdefer result.deinit(self.allocator);
        try result.ensureTotalCapacity(self.allocator, self.pending.count());
        var pending = self.pending.iterator();
        while (pending.next()) |entry| {
            const child = entry.value_ptr.child;
            const site_address = if (child.stack_id != 0)
                (self.stack.stackDefinition(child.stack_id) orelse
                    return error.MissingStackDefinition).call_addresses[0]
            else source: {
                const return_address = std.math.cast(
                    usize,
                    child.return_address,
                ) orelse return error.InvalidDanglingParentSite;
                if (return_address == 0) return error.MissingDanglingParentSite;
                break :source capture_mod.callAddress(return_address);
            };
            result.appendAssumeCapacity(.{
                .operation_id = entry.key_ptr.*,
                .child = child,
                .site_address = site_address,
            });
        }
        std.mem.sort(
            DanglingParent,
            result.items,
            {},
            danglingParentLessThan,
        );
        return result;
    }

    fn recordRoot(
        self: *Analyzer,
        event: event_mod.ReplayEvent,
        metrics: Metrics,
    ) !void {
        const key = RootKey{
            .stack_id = event.stack_id,
            .kind = event.kind,
            .succeeded = event.succeeded,
            .layer = event.layer,
            .producer = event.producer,
        };
        const entry = try self.groups.getOrPut(self.allocator, key);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        try entry.value_ptr.record(event, metrics);
        try self.recordLifetime(event, key);
    }

    fn recordLifetime(
        self: *Analyzer,
        event: event_mod.ReplayEvent,
        root: RootKey,
    ) !void {
        switch (event.kind) {
            .alloc => if (event.succeeded and event.tracked and event.len != 0) {
                try self.recordAllocation(event, root);
            },
            else => {},
        }
    }

    fn recordExistingLifetime(
        self: *Analyzer,
        event: event_mod.ReplayEvent,
    ) !void {
        switch (event.kind) {
            .free, .release => if (event.tracked and event.len != 0) {
                try self.recordFree(event);
            },
            .resize => if (event.succeeded and event.tracked) {
                try self.recordResize(event);
            },
            .remap => if (event.succeeded and event.tracked) {
                try self.recordRemap(event);
            },
            else => {},
        }
    }

    fn recordAllocation(
        self: *Analyzer,
        event: event_mod.ReplayEvent,
        root: RootKey,
    ) !void {
        const source = self.sourceKey(root);
        const allocation_key = allocationKey(
            event.allocation_id,
            event.address,
        );
        if (allocation_key == 0) return error.MissingCausalAllocationIdentity;
        const live = try self.live_allocations.getOrPut(
            self.allocator,
            allocation_key,
        );
        if (live.found_existing) return error.DuplicateCausalAllocation;
        live.value_ptr.* = .{
            .root = root,
            .source = source,
            .len = event.len,
        };
        try self.lifetime.allocate(event.len);
        try self.groups.getPtr(root).?.lifetime.allocate(event.len);
        const source_entry = try self.source_lifetimes.getOrPut(
            self.allocator,
            source,
        );
        if (!source_entry.found_existing) source_entry.value_ptr.* = .{};
        try source_entry.value_ptr.allocate(event.len);
    }

    fn recordFree(
        self: *Analyzer,
        event: event_mod.ReplayEvent,
    ) !void {
        const allocation_key = allocationKey(
            event.allocation_id,
            event.address,
        );
        const removed = self.live_allocations.fetchRemove(allocation_key) orelse {
            return;
        };
        try self.release(removed.value, removed.value.len);
    }

    fn recordResize(
        self: *Analyzer,
        event: event_mod.ReplayEvent,
    ) !void {
        const allocation_key = allocationKey(
            event.allocation_id,
            event.address,
        );
        const live = self.live_allocations.getPtr(allocation_key) orelse {
            return;
        };
        try self.resize(live.*, event.len);
        live.len = event.len;
    }

    fn recordRemap(
        self: *Analyzer,
        event: event_mod.ReplayEvent,
    ) !void {
        const old_key = allocationKey(
            event.allocation_id,
            event.old_address,
        );
        const new_key = allocationKey(
            event.allocation_id,
            event.address,
        );
        if (old_key == new_key) return self.recordResize(event);
        const removed = self.live_allocations.fetchRemove(old_key) orelse {
            return;
        };
        const entry = try self.live_allocations.getOrPut(
            self.allocator,
            new_key,
        );
        if (entry.found_existing) return error.DuplicateCausalAllocation;
        entry.value_ptr.* = removed.value;
        try self.resize(entry.value_ptr.*, event.len);
        entry.value_ptr.len = event.len;
    }

    fn release(
        self: *Analyzer,
        live: LiveAllocation,
        len: usize,
    ) !void {
        try self.lifetime.free(len);
        try self.groups.getPtr(live.root).?.lifetime.free(len);
        try self.source_lifetimes.getPtr(live.source).?.free(len);
    }

    fn resize(
        self: *Analyzer,
        live: LiveAllocation,
        new_len: usize,
    ) !void {
        try self.lifetime.resize(live.len, new_len);
        try self.groups.getPtr(live.root).?.lifetime.resize(
            live.len,
            new_len,
        );
        try self.source_lifetimes.getPtr(live.source).?.resize(
            live.len,
            new_len,
        );
    }

    fn sourceKey(self: *const Analyzer, root: RootKey) SourceKey {
        const definition = self.stack.stackDefinition(root.stack_id).?;
        return .{
            .kind = root.kind,
            .succeeded = root.succeeded,
            .layer = root.layer,
            .producer = root.producer,
            .site = definition.call_addresses[0],
            .caller = callerAddress(definition),
        };
    }

    fn collect(
        self: *const Analyzer,
        selection: analyze_mod.Selection,
    ) !std.ArrayListUnmanaged(Summary) {
        if (!self.finished) return error.CausalRootAnalyzerNotFinished;
        var result = std.ArrayListUnmanaged(Summary).empty;
        errdefer result.deinit(self.allocator);
        try result.ensureTotalCapacity(self.allocator, self.groups.count());
        var groups = self.groups.iterator();
        while (groups.next()) |entry| {
            if (!selection.includes(entry.key_ptr.kind)) continue;
            result.appendAssumeCapacity(.{
                .key = entry.key_ptr.*,
                .counters = entry.value_ptr.*,
                .definition = self.stack.stackDefinition(
                    entry.key_ptr.stack_id,
                ).?,
            });
        }
        return result;
    }

    fn totals(
        self: *const Analyzer,
        selection: analyze_mod.Selection,
    ) !Totals {
        if (!self.finished) return error.CausalRootAnalyzerNotFinished;
        var result: Totals = .{};
        var groups = self.groups.iterator();
        while (groups.next()) |entry| {
            if (!selection.includes(entry.key_ptr.kind)) continue;
            result.roots = try std.math.add(
                u64,
                result.roots,
                entry.value_ptr.roots,
            );
            result.root_requested_bytes = try std.math.add(
                u128,
                result.root_requested_bytes,
                entry.value_ptr.root_requested_bytes,
            );
            if (entry.key_ptr.succeeded) {
                result.successful = try std.math.add(
                    u64,
                    result.successful,
                    entry.value_ptr.roots,
                );
            } else {
                result.failed = try std.math.add(
                    u64,
                    result.failed,
                    entry.value_ptr.roots,
                );
            }
            try result.metrics.merge(entry.value_ptr.metrics);
        }
        result.lifetime = self.lifetime;
        return result;
    }
};

pub fn writeFromPath(
    allocator: Allocator,
    events_path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    if (options.top == 0 or
        options.frame_limit == 0 or
        options.frame_limit > capture_mod.max_frames_limit)
    {
        return error.InvalidCausalRootReportLimit;
    }
    try options.window.validate();
    var analyzer = Analyzer.init(allocator, options.window);
    defer analyzer.deinit();
    try ingestPath(&analyzer, events_path);
    try analyzer.stack.validate();

    var inferred_binary: ?[]u8 = null;
    defer if (inferred_binary) |path| allocator.free(path);
    const binary_path = options.binary_path orelse inferred: {
        inferred_binary = try identity_mod.artifactPathAlloc(
            allocator,
            events_path,
        );
        break :inferred inferred_binary.?;
    };
    const actual_digest = identity_mod.fileDigest(
        allocator,
        binary_path,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingExecutableArtifact,
        else => return err,
    };
    const expected_digest = analyzer.stack.executable_digest.?;
    if (!std.mem.eql(u8, &actual_digest, &expected_digest)) {
        return error.ExecutableIdentityMismatch;
    }
    analyzer.finishCausal() catch |err| switch (err) {
        error.DanglingParentOperation => {
            try writeDanglingReport(
                allocator,
                writer,
                &analyzer,
                options,
                binary_path,
                expected_digest,
            );
            return err;
        },
        else => return err,
    };

    var summaries = try analyzer.collect(options.selection);
    defer summaries.deinit(allocator);
    const totals = try analyzer.totals(options.selection);
    std.mem.sort(Summary, summaries.items, options.sort, summaryGreaterThan);
    const stack_limit = if (options.detail == .full)
        @min(options.top, summaries.items.len)
    else
        0;
    var sources = try collectSources(allocator, &analyzer, summaries.items);
    defer sources.deinit(allocator);
    std.mem.sort(Source, sources.items, options.sort, sourceGreaterThan);
    const source_limit = if (options.detail == .summary)
        0
    else
        @min(options.top, sources.items.len);
    const display = Display{
        .source_groups = sources.items.len,
        .displayed_sources = source_limit,
        .root_stacks = summaries.items.len,
        .displayed_stacks = stack_limit,
    };
    var addresses = try collectAddresses(
        allocator,
        summaries.items[0..stack_limit],
        sources.items[0..source_limit],
        options.frame_limit,
    );
    defer addresses.deinit(allocator);
    var symbols = if (addresses.items.len == 0)
        null
    else
        try symbolize_mod.resolveAlloc(
            allocator,
            binary_path,
            addresses.items,
        );
    defer if (symbols) |*resolved| resolved.deinit(allocator);
    switch (options.format) {
        .text => try writeText(
            writer,
            &analyzer,
            totals,
            options.selection,
            options.sort,
            options.window,
            display,
            sources.items[0..source_limit],
            summaries.items[0..stack_limit],
            symbols,
            options.frame_limit,
            expected_digest,
        ),
        .jsonl => try writeJsonl(
            writer,
            &analyzer,
            totals,
            options.selection,
            options.sort,
            options.window,
            display,
            sources.items[0..source_limit],
            summaries.items[0..stack_limit],
            symbols,
            options.frame_limit,
            expected_digest,
        ),
    }
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

fn writeDanglingReport(
    allocator: Allocator,
    writer: *std.Io.Writer,
    analyzer: *const Analyzer,
    options: Options,
    binary_path: []const u8,
    digest: identity_mod.Digest,
) !void {
    var dangling = try analyzer.collectDangling();
    defer dangling.deinit(allocator);
    const limit = @min(options.top, dangling.items.len);
    var addresses = try collectDanglingAddresses(
        allocator,
        dangling.items[0..limit],
    );
    defer addresses.deinit(allocator);
    var symbols = if (addresses.items.len == 0)
        null
    else
        try symbolize_mod.resolveAlloc(
            allocator,
            binary_path,
            addresses.items,
        );
    defer if (symbols) |*resolved| resolved.deinit(allocator);
    switch (options.format) {
        .text => try writeDanglingText(
            writer,
            analyzer,
            dangling.items[0..limit],
            dangling.items.len,
            symbols,
            digest,
        ),
        .jsonl => try writeDanglingJsonl(
            writer,
            analyzer,
            dangling.items[0..limit],
            dangling.items.len,
            symbols,
            digest,
        ),
    }
}

fn collectDanglingAddresses(
    allocator: Allocator,
    dangling: []const DanglingParent,
) !std.ArrayListUnmanaged(u64) {
    var seen = std.AutoHashMapUnmanaged(u64, void){};
    defer seen.deinit(allocator);
    var addresses = std.ArrayListUnmanaged(u64).empty;
    errdefer addresses.deinit(allocator);
    try addresses.ensureTotalCapacity(allocator, dangling.len);
    for (dangling) |entry| {
        const address = entry.site_address;
        const result = try seen.getOrPut(allocator, address);
        if (result.found_existing) continue;
        addresses.appendAssumeCapacity(address);
    }
    std.mem.sort(u64, addresses.items, {}, lessThan);
    return addresses;
}

fn writeDanglingText(
    writer: *std.Io.Writer,
    analyzer: *const Analyzer,
    dangling: []const DanglingParent,
    total: usize,
    symbols: ?symbolize_mod.Symbols,
    digest: identity_mod.Digest,
) !void {
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    try writer.print(
        "causal_roots_error code=dangling_parent_operation " ++
            "diagnostic_universe=all_memory_operations missing_parents={d} " ++
            "displayed_missing_parents={d} binary_sha256={s}\n",
        .{ total, dangling.len, digest_hex },
    );
    for (dangling) |entry| {
        const child = entry.child;
        try writer.print(
            "dangling_parent missing_parent_operation_id={d} " ++
                "observed_child_operation_id={d} observed_child_sequence={d} " ++
                "observed_child_scope_id={d} observed_child_operation={s} " ++
                "observed_child_layer={s} observed_child_producer={s} " ++
                "observed_child_outcome={s} observed_child_requested_bytes={d} " ++
                "observed_child_stack_id={d} observed_child_scope=",
            .{
                entry.operation_id,
                child.operation_id,
                child.sequence,
                child.scope_id,
                child.kind.tag(),
                child.layer.tag(),
                @tagName(child.producer),
                outcomeTag(child.succeeded),
                child.requested_bytes,
                child.stack_id,
            },
        );
        const scope = analyzer.stack.scopePath(child.scope_id) orelse "unknown";
        try pretty_json.writeString(writer, scope);
        try writeTextAddress(
            writer,
            " observed_child_site",
            entry.site_address,
            symbols,
        );
        try writer.writeByte('\n');
    }
}

fn writeDanglingJsonl(
    writer: *std.Io.Writer,
    analyzer: *const Analyzer,
    dangling: []const DanglingParent,
    total: usize,
    symbols: ?symbolize_mod.Symbols,
    digest: identity_mod.Digest,
) !void {
    var header_stream = pretty_json.Writer.init(writer, .minified);
    const header = try header_stream.object();
    try header.field("kind", "causal_root_error");
    try header.field("code", "dangling_parent_operation");
    try header.field("diagnostic_universe", "all_memory_operations");
    try header.field("missing_parents", total);
    try header.field("displayed_missing_parents", dangling.len);
    try header.hexString("binary_sha256", &digest);
    try header.endLine();
    for (dangling) |entry| {
        try writeDanglingJsonEntry(writer, analyzer, entry, symbols);
    }
}

fn writeDanglingJsonEntry(
    writer: *std.Io.Writer,
    analyzer: *const Analyzer,
    entry: DanglingParent,
    symbols: ?symbolize_mod.Symbols,
) !void {
    const child = entry.child;
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("kind", "causal_root_dangling_parent");
    try object.field("missing_parent_operation_id", entry.operation_id);
    try object.field("observed_child_operation_id", child.operation_id);
    try object.field("observed_child_sequence", child.sequence);
    try object.field("observed_child_scope_id", child.scope_id);
    try object.field("observed_child_scope", analyzer.stack.scopePath(
        child.scope_id,
    ));
    try object.field("observed_child_operation", child.kind.tag());
    try object.field("observed_child_layer", child.layer.tag());
    try object.field("observed_child_producer", @tagName(child.producer));
    try object.field("observed_child_succeeded", child.succeeded);
    try object.field("observed_child_requested_bytes", child.requested_bytes);
    try object.field("observed_child_stack_id", child.stack_id);
    const address = entry.site_address;
    try object.field("observed_child_site_address", address);
    try writeJsonSymbol(object, "observed_child_site", address, symbols);
    try object.endLine();
}

fn collectSources(
    allocator: Allocator,
    analyzer: *const Analyzer,
    summaries: []const Summary,
) !std.ArrayListUnmanaged(Source) {
    var counts = std.AutoHashMapUnmanaged(SourceKey, Source){};
    defer counts.deinit(allocator);
    for (summaries) |summary| {
        const key = SourceKey{
            .kind = summary.key.kind,
            .succeeded = summary.key.succeeded,
            .layer = summary.key.layer,
            .producer = summary.key.producer,
            .site = summary.definition.call_addresses[0],
            .caller = callerAddress(summary.definition),
        };
        const entry = try counts.getOrPut(allocator, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .key = key,
                .counters = .{},
                .unique_stacks = 0,
            };
        }
        try entry.value_ptr.counters.merge(summary.counters);
        entry.value_ptr.unique_stacks = try std.math.add(
            u32,
            entry.value_ptr.unique_stacks,
            1,
        );
    }
    var sources = std.ArrayListUnmanaged(Source).empty;
    errdefer sources.deinit(allocator);
    try sources.ensureTotalCapacity(allocator, counts.count());
    var values = counts.valueIterator();
    while (values.next()) |source| sources.appendAssumeCapacity(source.*);
    for (sources.items) |*source| {
        source.counters.lifetime = analyzer.source_lifetimes.get(
            source.key,
        ) orelse .{};
    }
    return sources;
}

fn collectAddresses(
    allocator: Allocator,
    summaries: []const Summary,
    sources: []const Source,
    frame_limit: usize,
) !std.ArrayListUnmanaged(u64) {
    var seen = std.AutoHashMapUnmanaged(u64, void){};
    defer seen.deinit(allocator);
    var addresses = std.ArrayListUnmanaged(u64).empty;
    errdefer addresses.deinit(allocator);
    for (sources) |source| {
        try appendAddress(allocator, &seen, &addresses, source.key.site);
        if (source.key.caller != 0) {
            try appendAddress(
                allocator,
                &seen,
                &addresses,
                source.key.caller,
            );
        }
    }
    for (summaries) |summary| {
        const limit = @min(
            frame_limit,
            summary.definition.call_addresses.len,
        );
        for (summary.definition.call_addresses[0..limit]) |address| {
            try appendAddress(allocator, &seen, &addresses, address);
        }
    }
    std.mem.sort(u64, addresses.items, {}, lessThan);
    return addresses;
}

fn appendAddress(
    allocator: Allocator,
    seen: *std.AutoHashMapUnmanaged(u64, void),
    addresses: *std.ArrayListUnmanaged(u64),
    address: u64,
) !void {
    const entry = try seen.getOrPut(allocator, address);
    if (entry.found_existing) return;
    try addresses.append(allocator, address);
}

fn callerAddress(definition: analyze_mod.Definition) u64 {
    const site = definition.call_addresses[0];
    for (definition.call_addresses[1..], 1..) |address, index| {
        if (address != site) continue;
        const caller_index = index + 1;
        if (caller_index < definition.call_addresses.len) {
            return definition.call_addresses[caller_index];
        }
        return 0;
    }
    return 0;
}

fn summaryGreaterThan(sort: Sort, left: Summary, right: Summary) bool {
    if (counterOrder(sort, left.counters, right.counters)) |order| {
        return order;
    }
    if (left.counters.roots != right.counters.roots) {
        return left.counters.roots > right.counters.roots;
    }
    if (left.counters.root_requested_bytes !=
        right.counters.root_requested_bytes)
    {
        return left.counters.root_requested_bytes >
            right.counters.root_requested_bytes;
    }
    if (left.counters.metrics.operations != right.counters.metrics.operations) {
        return left.counters.metrics.operations >
            right.counters.metrics.operations;
    }
    return keyLessThan(left.key, right.key);
}

fn sourceGreaterThan(sort: Sort, left: Source, right: Source) bool {
    if (counterOrder(sort, left.counters, right.counters)) |order| {
        return order;
    }
    if (left.counters.roots != right.counters.roots) {
        return left.counters.roots > right.counters.roots;
    }
    if (left.counters.root_requested_bytes !=
        right.counters.root_requested_bytes)
    {
        return left.counters.root_requested_bytes >
            right.counters.root_requested_bytes;
    }
    if (left.key.site != right.key.site) return left.key.site < right.key.site;
    if (left.key.caller != right.key.caller) {
        return left.key.caller < right.key.caller;
    }
    return sourceKeyLessThan(left.key, right.key);
}

fn counterOrder(
    sort: Sort,
    left: Counters,
    right: Counters,
) ?bool {
    const left_value: u128 = switch (sort) {
        .roots => left.roots,
        .requested_bytes => left.root_requested_bytes,
        .backing_bytes => left.metrics.backing_requested_bytes,
        .high_water => left.lifetime.high_water_live_bytes,
    };
    const right_value: u128 = switch (sort) {
        .roots => right.roots,
        .requested_bytes => right.root_requested_bytes,
        .backing_bytes => right.metrics.backing_requested_bytes,
        .high_water => right.lifetime.high_water_live_bytes,
    };
    if (left_value == right_value) return null;
    return left_value > right_value;
}

fn keyLessThan(left: RootKey, right: RootKey) bool {
    if (left.kind != right.kind) {
        return @backingInt(left.kind) < @backingInt(right.kind);
    }
    if (left.layer != right.layer) {
        return @backingInt(left.layer) < @backingInt(right.layer);
    }
    if (left.producer != right.producer) {
        return @backingInt(left.producer) < @backingInt(right.producer);
    }
    if (left.succeeded != right.succeeded) return left.succeeded;
    return left.stack_id < right.stack_id;
}

fn sourceKeyLessThan(left: SourceKey, right: SourceKey) bool {
    if (left.kind != right.kind) {
        return @backingInt(left.kind) < @backingInt(right.kind);
    }
    if (left.layer != right.layer) {
        return @backingInt(left.layer) < @backingInt(right.layer);
    }
    if (left.producer != right.producer) {
        return @backingInt(left.producer) < @backingInt(right.producer);
    }
    return left.succeeded and !right.succeeded;
}

fn selectionTag(selection: analyze_mod.Selection) []const u8 {
    return switch (selection) {
        .allocations => "allocations",
        .all => "all",
    };
}

fn sortTag(sort: Sort) []const u8 {
    return switch (sort) {
        .roots => "roots",
        .requested_bytes => "requested_bytes",
        .backing_bytes => "backing_bytes",
        .high_water => "high_water",
    };
}

fn allocationKey(allocation_id: u64, address: u64) u64 {
    return if (allocation_id != 0) allocation_id else address;
}

fn outcomeTag(succeeded: bool) []const u8 {
    return if (succeeded) "success" else "failure";
}

fn requestBytes(event: event_mod.ReplayEvent) usize {
    return switch (event.kind) {
        .free, .release, .unmap => event.old_len,
        .alloc, .resize, .remap, .map, .protect, .discard, .decommit, .advise => event.len,
        else => unreachable,
    };
}

fn lessThan(_: void, left: u64, right: u64) bool {
    return left < right;
}

fn danglingParentLessThan(
    _: void,
    left: DanglingParent,
    right: DanglingParent,
) bool {
    if (left.operation_id != right.operation_id) {
        return left.operation_id < right.operation_id;
    }
    if (left.child.sequence != right.child.sequence) {
        return left.child.sequence < right.child.sequence;
    }
    return left.child.operation_id < right.child.operation_id;
}

fn writeText(
    writer: *std.Io.Writer,
    analyzer: *const Analyzer,
    totals: Totals,
    selection: analyze_mod.Selection,
    sort: Sort,
    window: analyze_mod.Window,
    display: Display,
    sources: []const Source,
    summaries: []const Summary,
    maybe_symbols: ?symbolize_mod.Symbols,
    frame_limit: usize,
    digest: identity_mod.Digest,
) !void {
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const coverage = analyzer.stack.coverage.?;
    try writer.print(
        "causal_roots status={s} universe={s} selection={s} sort={s} " ++
            "roots={d} " ++
            "successful={d} failed={d} root_requested_bytes={d} " ++
            "live_allocations={d} live_bytes={d} " ++
            "high_water_live_bytes={d} " ++
            "causal_operations={d} logical_operations={d} " ++
            "backing_operations={d} physical_operations={d} " ++
            "backing_requested_bytes={d} physical_requested_bytes={d} " ++
            "max_depth={d} source_groups={d} displayed_sources={d} " ++
            "root_stacks={d} displayed_stacks={d} binary_sha256={s}",
        .{
            coverage.statusTag(),
            coverage.universe.tag(),
            selectionTag(selection),
            sortTag(sort),
            totals.roots,
            totals.successful,
            totals.failed,
            totals.root_requested_bytes,
            totals.lifetime.live_allocations,
            totals.lifetime.live_bytes,
            totals.lifetime.high_water_live_bytes,
            totals.metrics.operations,
            totals.metrics.logical_operations,
            totals.metrics.backing_operations,
            totals.metrics.physical_operations,
            totals.metrics.backing_requested_bytes,
            totals.metrics.physical_requested_bytes,
            totals.metrics.max_depth,
            display.source_groups,
            display.displayed_sources,
            display.root_stacks,
            display.displayed_stacks,
            digest_hex,
        },
    );
    try writeTextWindow(writer, window, "root_operation");
    try writer.writeByte('\n');
    try writeCoverage(writer, coverage);
    for (sources) |source| {
        try writer.print(
            "root_source layer={s} producer={s} operation={s} outcome={s} " ++
                "roots={d} root_requested_bytes={d} live_allocations={d} " ++
                "live_bytes={d} high_water_live_bytes={d} " ++
                "causal_operations={d} " ++
                "logical_operations={d} backing_operations={d} " ++
                "physical_operations={d} backing_requested_bytes={d} " ++
                "physical_requested_bytes={d} max_depth={d} unique_stacks={d}",
            .{
                source.key.layer.tag(),
                @tagName(source.key.producer),
                source.key.kind.tag(),
                outcomeTag(source.key.succeeded),
                source.counters.roots,
                source.counters.root_requested_bytes,
                source.counters.lifetime.live_allocations,
                source.counters.lifetime.live_bytes,
                source.counters.lifetime.high_water_live_bytes,
                source.counters.metrics.operations,
                source.counters.metrics.logical_operations,
                source.counters.metrics.backing_operations,
                source.counters.metrics.physical_operations,
                source.counters.metrics.backing_requested_bytes,
                source.counters.metrics.physical_requested_bytes,
                source.counters.metrics.max_depth,
                source.unique_stacks,
            },
        );
        try writeTextAddress(
            writer,
            " site",
            source.key.site,
            maybe_symbols,
        );
        if (source.key.caller != 0) {
            try writeTextAddress(
                writer,
                " caller",
                source.key.caller,
                maybe_symbols,
            );
        } else {
            try writer.writeAll(" caller=unavailable");
        }
        try writer.writeByte('\n');
    }
    for (summaries) |summary| {
        const displayed = @min(
            frame_limit,
            summary.definition.call_addresses.len,
        );
        try writer.print(
            "root_stack id={d} layer={s} producer={s} operation={s} " ++
                "outcome={s} roots={d} root_requested_bytes={d} " ++
                "live_allocations={d} live_bytes={d} " ++
                "high_water_live_bytes={d} " ++
                "causal_operations={d} logical_operations={d} " ++
                "backing_operations={d} physical_operations={d} " ++
                "backing_requested_bytes={d} physical_requested_bytes={d} " ++
                "max_depth={d} captured_frames={d} displayed_frames={d}\n",
            .{
                summary.key.stack_id,
                summary.key.layer.tag(),
                @tagName(summary.key.producer),
                summary.key.kind.tag(),
                outcomeTag(summary.key.succeeded),
                summary.counters.roots,
                summary.counters.root_requested_bytes,
                summary.counters.lifetime.live_allocations,
                summary.counters.lifetime.live_bytes,
                summary.counters.lifetime.high_water_live_bytes,
                summary.counters.metrics.operations,
                summary.counters.metrics.logical_operations,
                summary.counters.metrics.backing_operations,
                summary.counters.metrics.physical_operations,
                summary.counters.metrics.backing_requested_bytes,
                summary.counters.metrics.physical_requested_bytes,
                summary.counters.metrics.max_depth,
                summary.definition.call_addresses.len,
                displayed,
            },
        );
        try writeTextFrames(
            writer,
            summary.definition,
            displayed,
            maybe_symbols,
        );
    }
}

fn writeCoverage(
    writer: *std.Io.Writer,
    coverage: coverage_mod.Manifest,
) !void {
    try writer.print(
        "coverage child_allocator_fast_paths={s} sys_memory_operations={s} " ++
            "direct_os_memory_operations={s} unowned_allocator_producers={s} " ++
            "foreign_allocations={s} observer_control={s} " ++
            "observer_control_operations={d} zero_length_operations={s} " ++
            "predispatch_failures={s}\n",
        .{
            coverage.child_allocator_fast_paths.tag(),
            coverage.sys_memory_operations.tag(),
            coverage.direct_os_memory_operations.tag(),
            coverage.unowned_allocator_producers.tag(),
            coverage.foreign_allocations.tag(),
            coverage.observer_control.tag(),
            coverage.observer_control_operations,
            coverage.zero_length_operations.tag(),
            coverage.predispatch_failures.tag(),
        },
    );
}

fn writeTextFrames(
    writer: *std.Io.Writer,
    definition: analyze_mod.Definition,
    displayed: usize,
    maybe_symbols: ?symbolize_mod.Symbols,
) !void {
    for (definition.call_addresses[0..displayed], 0..) |address, frame_index| {
        const resolved = if (maybe_symbols) |symbols|
            symbols.find(address)
        else
            &.{};
        try writer.print(
            "  frame={d} kind={s} call_address=0x{x}",
            .{
                frame_index,
                if (frame_index == 0) "root_site" else "physical",
                address,
            },
        );
        if (resolved.len != 0) {
            try writer.writeAll(" function=");
            try pretty_json.writeString(writer, resolved[0].function);
            try writer.writeAll(" location=");
            try pretty_json.writeString(writer, resolved[0].location);
        }
        try writer.writeByte('\n');
        for (resolved[1..], 1..) |inline_frame, inline_index| {
            try writer.print("    inline={d} function=", .{inline_index});
            try pretty_json.writeString(writer, inline_frame.function);
            try writer.writeAll(" location=");
            try pretty_json.writeString(writer, inline_frame.location);
            try writer.writeByte('\n');
        }
    }
}

fn writeTextAddress(
    writer: *std.Io.Writer,
    prefix: []const u8,
    address: u64,
    maybe_symbols: ?symbolize_mod.Symbols,
) !void {
    try writer.print("{s}_address=0x{x}", .{ prefix, address });
    const resolved = if (maybe_symbols) |symbols|
        symbols.find(address)
    else
        &.{};
    if (resolved.len == 0) return;
    try writer.print("{s}_function=", .{prefix});
    try pretty_json.writeString(writer, resolved[0].function);
    try writer.print("{s}_location=", .{prefix});
    try pretty_json.writeString(writer, resolved[0].location);
    if (resolved.len == 1) return;
    const owner = resolved[resolved.len - 1];
    try writer.print("{s}_owner_function=", .{prefix});
    try pretty_json.writeString(writer, owner.function);
    try writer.print("{s}_owner_location=", .{prefix});
    try pretty_json.writeString(writer, owner.location);
}

fn writeTextWindow(
    writer: *std.Io.Writer,
    window: analyze_mod.Window,
    anchor: []const u8,
) !void {
    try writer.writeAll(" window_scope=");
    if (window.scope) |scope| {
        try pretty_json.writeString(writer, scope);
    } else {
        try writer.writeAll("all");
    }
    try writer.writeAll(" window_scope_match=subtree window_first_sequence=");
    try writeOptionalSequence(writer, window.first_sequence);
    try writer.writeAll(" window_last_sequence=");
    try writeOptionalSequence(writer, window.last_sequence);
    try writer.print(" window_sequence_bounds=inclusive window_anchor={s}", .{
        anchor,
    });
}

fn writeOptionalSequence(writer: *std.Io.Writer, sequence: ?u64) !void {
    if (sequence) |value| {
        try writer.print("{d}", .{value});
    } else {
        try writer.writeAll("all");
    }
}

fn writeJsonWindow(
    object: pretty_json.Object,
    window: analyze_mod.Window,
    anchor: []const u8,
) !void {
    try object.field("window_scope", window.scope);
    try object.field("window_scope_match", "subtree");
    try object.field("window_first_sequence", window.first_sequence);
    try object.field("window_last_sequence", window.last_sequence);
    try object.field("window_sequence_bounds", "inclusive");
    try object.field("window_anchor", anchor);
}

fn writeCounterFields(object: pretty_json.Object, counters: anytype) !void {
    try object.field("roots", counters.roots);
    try object.field("root_requested_bytes", counters.root_requested_bytes);
    try object.field("live_allocations", counters.lifetime.live_allocations);
    try object.field("live_bytes", counters.lifetime.live_bytes);
    try object.field("high_water_live_bytes", counters.lifetime.high_water_live_bytes);
    try object.field("causal_operations", counters.metrics.operations);
    try object.field("logical_operations", counters.metrics.logical_operations);
    try object.field("backing_operations", counters.metrics.backing_operations);
    try object.field("physical_operations", counters.metrics.physical_operations);
    try object.field("backing_requested_bytes", counters.metrics.backing_requested_bytes);
    try object.field("physical_requested_bytes", counters.metrics.physical_requested_bytes);
    try object.field("max_depth", counters.metrics.max_depth);
}

/// The `causal_root_summary` line, field for field as `writeJsonl` writes
/// it. The causal budget reads the status, the source counts, and four
/// totals, so those fields are required. The others are optional, so a
/// budget can be checked against a report cut down to what it reads.
pub const SummaryRecord = struct {
    kind: []const u8,
    status: []const u8,
    universe: ?coverage_mod.Universe = null,
    selection: ?analyze_mod.Selection = null,
    sort: ?Sort = null,
    roots: u64,
    successful: ?u64 = null,
    failed: ?u64 = null,
    root_requested_bytes: u128,
    live_allocations: ?u64 = null,
    live_bytes: ?u128 = null,
    high_water_live_bytes: u128,
    causal_operations: ?u64 = null,
    logical_operations: ?u64 = null,
    backing_operations: ?u64 = null,
    physical_operations: ?u64 = null,
    backing_requested_bytes: u128,
    physical_requested_bytes: ?u128 = null,
    max_depth: ?u32 = null,
    source_groups: usize,
    displayed_sources: usize,
    root_stacks: ?usize = null,
    displayed_stacks: ?usize = null,
    binary_sha256: ?[]const u8 = null,
    window_scope: ?[]const u8 = null,
    window_scope_match: ?[]const u8 = null,
    window_first_sequence: ?u64 = null,
    window_last_sequence: ?u64 = null,
    window_sequence_bounds: ?[]const u8 = null,
    window_anchor: ?[]const u8 = null,
    child_allocator_fast_paths: ?coverage_mod.Inclusion = null,
    sys_memory_operations: ?coverage_mod.Inclusion = null,
    direct_os_memory_operations: ?coverage_mod.Inclusion = null,
    unowned_allocator_producers: ?coverage_mod.Inclusion = null,
    foreign_allocations: ?coverage_mod.Inclusion = null,
    observer_control: ?coverage_mod.Inclusion = null,
    observer_control_operations: ?u64 = null,
    zero_length_operations: ?coverage_mod.Inclusion = null,
    predispatch_failures: ?coverage_mod.Inclusion = null,
};

/// A `causal_root_source` line, field for field as `writeJsonl` writes it.
/// The symbol fields appear only when the site or caller resolves. The
/// causal budget reads the site function, the callers, and four counters.
pub const SourceRecord = struct {
    kind: []const u8,
    layer: ?event_mod.Layer = null,
    producer: ?observe.Producer = null,
    operation: ?event_mod.Kind = null,
    succeeded: ?bool = null,
    roots: u64,
    root_requested_bytes: u128,
    live_allocations: ?u64 = null,
    live_bytes: ?u128 = null,
    high_water_live_bytes: u128,
    causal_operations: ?u64 = null,
    logical_operations: ?u64 = null,
    backing_operations: ?u64 = null,
    physical_operations: ?u64 = null,
    backing_requested_bytes: u128,
    physical_requested_bytes: ?u128 = null,
    max_depth: ?u32 = null,
    unique_stacks: ?u32 = null,
    site_address: ?u64 = null,
    caller_address: ?u64 = null,
    site_function: ?[]const u8 = null,
    site_location: ?[]const u8 = null,
    site_owner_function: ?[]const u8 = null,
    site_owner_location: ?[]const u8 = null,
    caller_function: ?[]const u8 = null,
    caller_location: ?[]const u8 = null,
    caller_owner_function: ?[]const u8 = null,
    caller_owner_location: ?[]const u8 = null,
};

fn writeJsonl(
    writer: *std.Io.Writer,
    analyzer: *const Analyzer,
    totals: Totals,
    selection: analyze_mod.Selection,
    sort: Sort,
    window: analyze_mod.Window,
    display: Display,
    sources: []const Source,
    summaries: []const Summary,
    maybe_symbols: ?symbolize_mod.Symbols,
    frame_limit: usize,
    digest: identity_mod.Digest,
) !void {
    const coverage = analyzer.stack.coverage.?;
    var summary_stream = pretty_json.Writer.init(writer, .minified);
    const header = try summary_stream.object();
    try header.field("kind", "causal_root_summary");
    try header.field("status", coverage.statusTag());
    try header.field("universe", coverage.universe.tag());
    try header.field("selection", selectionTag(selection));
    try header.field("sort", sortTag(sort));
    try header.field("roots", totals.roots);
    try header.field("successful", totals.successful);
    try header.field("failed", totals.failed);
    try header.field("root_requested_bytes", totals.root_requested_bytes);
    try header.field("live_allocations", totals.lifetime.live_allocations);
    try header.field("live_bytes", totals.lifetime.live_bytes);
    try header.field("high_water_live_bytes", totals.lifetime.high_water_live_bytes);
    try header.field("causal_operations", totals.metrics.operations);
    try header.field("logical_operations", totals.metrics.logical_operations);
    try header.field("backing_operations", totals.metrics.backing_operations);
    try header.field("physical_operations", totals.metrics.physical_operations);
    try header.field("backing_requested_bytes", totals.metrics.backing_requested_bytes);
    try header.field("physical_requested_bytes", totals.metrics.physical_requested_bytes);
    try header.field("max_depth", totals.metrics.max_depth);
    try header.field("source_groups", display.source_groups);
    try header.field("displayed_sources", display.displayed_sources);
    try header.field("root_stacks", display.root_stacks);
    try header.field("displayed_stacks", display.displayed_stacks);
    try header.hexString("binary_sha256", &digest);
    try writeJsonWindow(header, window, "root_operation");
    try header.field("child_allocator_fast_paths", coverage.child_allocator_fast_paths.tag());
    try header.field("sys_memory_operations", coverage.sys_memory_operations.tag());
    try header.field("direct_os_memory_operations", coverage.direct_os_memory_operations.tag());
    try header.field("unowned_allocator_producers", coverage.unowned_allocator_producers.tag());
    try header.field("foreign_allocations", coverage.foreign_allocations.tag());
    try header.field("observer_control", coverage.observer_control.tag());
    try header.field("observer_control_operations", coverage.observer_control_operations);
    try header.field("zero_length_operations", coverage.zero_length_operations.tag());
    try header.field("predispatch_failures", coverage.predispatch_failures.tag());
    try header.endLine();
    for (sources) |source| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("kind", "causal_root_source");
        try object.field("layer", source.key.layer.tag());
        try object.field("producer", @tagName(source.key.producer));
        try object.field("operation", source.key.kind.tag());
        try object.field("succeeded", source.key.succeeded);
        try writeCounterFields(object, source.counters);
        try object.field("unique_stacks", source.unique_stacks);
        try object.field("site_address", source.key.site);
        const caller_address: ?u64 = if (source.key.caller == 0) null else source.key.caller;
        try object.field("caller_address", caller_address);
        try writeJsonSymbol(
            object,
            "site",
            source.key.site,
            maybe_symbols,
        );
        if (source.key.caller != 0) {
            try writeJsonSymbol(
                object,
                "caller",
                source.key.caller,
                maybe_symbols,
            );
        }
        try object.endLine();
    }
    for (summaries) |summary| {
        const displayed = @min(
            frame_limit,
            summary.definition.call_addresses.len,
        );
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("kind", "causal_root_stack");
        try object.field("stack_id", summary.key.stack_id);
        try object.field("layer", summary.key.layer.tag());
        try object.field("producer", @tagName(summary.key.producer));
        try object.field("operation", summary.key.kind.tag());
        try object.field("succeeded", summary.key.succeeded);
        try writeCounterFields(object, summary.counters);
        try object.field("captured_frames", summary.definition.call_addresses.len);
        try object.field("displayed_frames", displayed);
        try object.endLine();
        for (
            summary.definition.call_addresses[0..displayed],
            0..,
        ) |address, frame_index| {
            const resolved = if (maybe_symbols) |symbols|
                symbols.find(address)
            else
                &.{};
            if (resolved.len == 0) {
                try writeJsonFrame(
                    writer,
                    summary.key.stack_id,
                    frame_index,
                    address,
                    0,
                    "",
                    "",
                );
                continue;
            }
            for (resolved, 0..) |inline_frame, inline_index| {
                try writeJsonFrame(
                    writer,
                    summary.key.stack_id,
                    frame_index,
                    address,
                    inline_index,
                    inline_frame.function,
                    inline_frame.location,
                );
            }
        }
    }
}

fn writeJsonSymbol(
    object: pretty_json.Object,
    prefix: []const u8,
    address: u64,
    maybe_symbols: ?symbolize_mod.Symbols,
) !void {
    const resolved = if (maybe_symbols) |symbols|
        symbols.find(address)
    else
        &.{};
    if (resolved.len == 0) return;
    try object.fieldParts(&.{ prefix, "_function" }, resolved[0].function);
    try object.fieldParts(&.{ prefix, "_location" }, resolved[0].location);
    if (resolved.len == 1) return;
    const owner = resolved[resolved.len - 1];
    try object.fieldParts(&.{ prefix, "_owner_function" }, owner.function);
    try object.fieldParts(&.{ prefix, "_owner_location" }, owner.location);
}

fn writeJsonFrame(
    writer: *std.Io.Writer,
    stack_id: u32,
    frame_index: usize,
    address: u64,
    inline_index: usize,
    function: []const u8,
    location: []const u8,
) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("kind", "causal_root_stack_frame");
    try object.field("stack_id", stack_id);
    try object.field("frame", frame_index);
    try object.field("frame_kind", if (frame_index == 0) "root_site" else "physical");
    try object.field("call_address", address);
    try object.field("inline", inline_index);
    try object.field("function", function);
    try object.field("location", location);
    try object.endLine();
}

fn fixture(analyzer: *Analyzer, dangling: bool) !void {
    const digest: identity_mod.Digest = @splat(0xaa);
    var input = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer input.deinit();
    try identity_mod.writeMetadata(&input.writer, digest);
    try coverage_mod.writeMetadata(
        &input.writer,
        coverage_mod.ownedProducerManifest(),
    );
    var addresses = [_]usize{ 1, 2 };
    try capture_mod.writeDefinition(&input.writer, 1, .{
        .addresses = &addresses,
        .truncated = false,
        .unwind_failed = false,
        .missing_return_address = false,
        .collision_next = 0,
    });
    try (event_mod.Event{
        .seq = 1,
        .kind = .trace_start,
    }).writeJsonLine(&input.writer, null, null);
    try (event_mod.Event{
        .seq = 2,
        .kind = .map,
        .len = 128,
        .stack_id = 1,
        .layer = .physical_page,
        .operation_id = 3,
        .parent_operation_id = 2,
        .producer = .sys_memory,
    }).writeJsonLine(&input.writer, null, null);
    try (event_mod.Event{
        .seq = 3,
        .kind = .alloc,
        .len = 64,
        .stack_id = 1,
        .operation_id = 2,
        .parent_operation_id = 1,
    }).writeJsonLine(&input.writer, null, null);
    if (!dangling) {
        try (event_mod.Event{
            .seq = 4,
            .kind = .alloc,
            .allocation_id = 1,
            .address = 4096,
            .len = 16,
            .stack_id = 1,
            .layer = .logical_allocator,
            .operation_id = 1,
            .producer = .arena,
        }).writeJsonLine(&input.writer, null, null);
        try (event_mod.Event{
            .seq = 5,
            .kind = .alloc,
            .allocation_id = 2,
            .address = 8192,
            .len = 32,
            .stack_id = 1,
            .layer = .logical_allocator,
            .operation_id = 4,
            .producer = .arena,
        }).writeJsonLine(&input.writer, null, null);
    }
    try (event_mod.Event{
        .seq = if (dangling) 4 else 6,
        .kind = .trace_stop,
    }).writeJsonLine(&input.writer, null, null);
    var lines = std.mem.splitScalar(u8, input.written(), '\n');
    while (lines.next()) |line| try analyzer.ingestJsonLine(line);
}

test "causal roots collapse nested allocator layers" {
    var analyzer = Analyzer.init(std.testing.allocator, .{});
    defer analyzer.deinit();
    try fixture(&analyzer, false);
    try analyzer.finish();
    const totals = try analyzer.totals(.allocations);
    try std.testing.expectEqual(@as(u64, 2), totals.roots);
    try std.testing.expectEqual(@as(u128, 48), totals.root_requested_bytes);
    try std.testing.expectEqual(@as(u64, 4), totals.metrics.operations);
    try std.testing.expectEqual(@as(u64, 2), totals.metrics.logical_operations);
    try std.testing.expectEqual(@as(u64, 1), totals.metrics.backing_operations);
    try std.testing.expectEqual(@as(u64, 1), totals.metrics.physical_operations);
    try std.testing.expectEqual(@as(u32, 2), totals.metrics.max_depth);
    try std.testing.expectEqual(@as(u64, 2), totals.lifetime.live_allocations);
    try std.testing.expectEqual(@as(u128, 48), totals.lifetime.live_bytes);
    try std.testing.expectEqual(
        @as(u128, 48),
        totals.lifetime.high_water_live_bytes,
    );
}

test "causal roots reject a missing parent operation" {
    var analyzer = Analyzer.init(std.testing.allocator, .{});
    defer analyzer.deinit();
    try fixture(&analyzer, true);
    try std.testing.expectError(
        error.DanglingParentOperation,
        analyzer.finish(),
    );
}

test "causal roots identify each missing parent through its observed child site" {
    var analyzer = Analyzer.init(std.testing.allocator, .{});
    defer analyzer.deinit();
    try fixture(&analyzer, true);
    try analyzer.stack.validate();
    var dangling = try analyzer.collectDangling();
    defer dangling.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), dangling.items.len);
    try std.testing.expectEqual(@as(u64, 1), dangling.items[0].operation_id);
    try std.testing.expectEqual(@as(u64, 2), dangling.items[0].child.operation_id);
    try std.testing.expectEqual(@as(u64, 1), dangling.items[0].site_address);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const digest: identity_mod.Digest = @splat(0xaa);
    try writeDanglingText(
        &output.writer,
        &analyzer,
        dangling.items,
        dangling.items.len,
        null,
        digest,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "missing_parent_operation_id=1 observed_child_operation_id=2",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "observed_child_site_address=0x1",
    ) != null);
}

test "causal root window anchors a complete tree at its root operation" {
    var analyzer = Analyzer.init(std.testing.allocator, .{
        .scope = "root/phase",
        .first_sequence = 4,
        .last_sequence = 4,
    });
    defer analyzer.deinit();
    try filteredRootFixture(&analyzer);
    try analyzer.finish();

    const totals = try analyzer.totals(.allocations);
    try std.testing.expectEqual(@as(u64, 1), totals.roots);
    try std.testing.expectEqual(@as(u128, 16), totals.root_requested_bytes);
    try std.testing.expectEqual(@as(u64, 2), totals.metrics.operations);
    try std.testing.expectEqual(@as(u64, 1), totals.metrics.logical_operations);
    try std.testing.expectEqual(@as(u64, 1), totals.metrics.backing_operations);
    try std.testing.expectEqual(@as(u128, 64), totals.metrics.backing_requested_bytes);
}

fn filteredRootFixture(analyzer: *Analyzer) !void {
    const digest: identity_mod.Digest = @splat(0xaa);
    var input = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer input.deinit();
    try identity_mod.writeMetadata(&input.writer, digest);
    try coverage_mod.writeMetadata(
        &input.writer,
        coverage_mod.ownedProducerManifest(),
    );
    var addresses = [_]usize{ 1, 2 };
    try capture_mod.writeDefinition(&input.writer, 1, .{
        .addresses = &addresses,
        .truncated = false,
        .unwind_failed = false,
        .missing_return_address = false,
        .collision_next = 0,
    });
    const lines = [_][]const u8{
        "{\"v\":3,\"seq\":1,\"kind\":\"trace.start\"}",
        "{\"v\":3,\"seq\":2,\"kind\":\"scope.enter\",\"scope_id\":1," ++
            "\"scope\":\"root/phase\"}",
        "{\"v\":3,\"seq\":3,\"kind\":\"alloc\",\"scope_id\":1,\"len\":64," ++
            "\"stack_id\":1,\"operation_id\":2,\"parent_operation_id\":1}",
        "{\"v\":3,\"seq\":4,\"kind\":\"alloc\",\"scope_id\":1," ++
            "\"allocation_id\":1,\"address\":4096,\"len\":16,\"stack_id\":1," ++
            "\"layer\":\"logical_allocator\",\"operation_id\":1," ++
            "\"producer\":\"arena\"}",
        "{\"v\":3,\"seq\":5,\"kind\":\"scope.exit\",\"scope_id\":1}",
        "{\"v\":3,\"seq\":6,\"kind\":\"scope.enter\",\"scope_id\":2," ++
            "\"scope\":\"root/other\"}",
        "{\"v\":3,\"seq\":7,\"kind\":\"alloc\",\"scope_id\":2,\"len\":128," ++
            "\"stack_id\":1,\"operation_id\":4,\"parent_operation_id\":3}",
        "{\"v\":3,\"seq\":8,\"kind\":\"alloc\",\"scope_id\":2," ++
            "\"allocation_id\":2,\"address\":8192,\"len\":32,\"stack_id\":1," ++
            "\"layer\":\"logical_allocator\",\"operation_id\":3," ++
            "\"producer\":\"arena\"}",
        "{\"v\":3,\"seq\":9,\"kind\":\"free\",\"scope_id\":2,\"address\":99," ++
            "\"len\":8,\"old_len\":8,\"stack_id\":1,\"operation_id\":6," ++
            "\"parent_operation_id\":5}",
        "{\"v\":3,\"seq\":10,\"kind\":\"release\",\"scope_id\":2," ++
            "\"address\":99,\"len\":8,\"old_len\":8,\"stack_id\":1," ++
            "\"operation_id\":5}",
        "{\"v\":3,\"seq\":11,\"kind\":\"lifecycle\",\"scope_id\":2," ++
            "\"return_address\":2,\"operation_id\":5}",
        "{\"v\":3,\"seq\":12,\"kind\":\"scope.exit\",\"scope_id\":2}",
        "{\"v\":3,\"seq\":13,\"kind\":\"trace.stop\"}",
    };
    var metadata = std.mem.splitScalar(u8, input.written(), '\n');
    while (metadata.next()) |line| try analyzer.ingestJsonLine(line);
    for (lines) |line| try analyzer.ingestJsonLine(line);
}

test "causal root records name exactly the fields the report writes" {
    const allocator = std.testing.allocator;
    const window = analyze_mod.Window{};
    var analyzer = Analyzer.init(allocator, window);
    defer analyzer.deinit();
    var input = std.Io.Writer.Allocating.init(allocator);
    defer input.deinit();
    try identity_mod.writeMetadata(&input.writer, @splat(0xaa));
    try coverage_mod.writeMetadata(&input.writer, coverage_mod.ownedProducerManifest());
    var addresses = [_]usize{ 7, 7, 9 };
    try capture_mod.writeDefinition(&input.writer, 1, .{
        .addresses = &addresses,
        .truncated = false,
        .unwind_failed = false,
        .missing_return_address = false,
        .collision_next = 0,
    });
    try input.writer.writeAll(
        \\{"v":3,"seq":1,"kind":"trace.start"}
        \\{"v":3,"seq":2,"kind":"alloc","allocation_id":1,"address":4096,"len":16,"stack_id":1,"layer":"logical_allocator","operation_id":1,"producer":"arena"}
        \\{"v":3,"seq":3,"kind":"trace.stop"}
    );
    var lines_in = std.mem.splitScalar(u8, input.written(), '\n');
    while (lines_in.next()) |line| try analyzer.ingestJsonLine(line);
    try analyzer.finish();
    var summaries = try analyzer.collect(.allocations);
    defer summaries.deinit(allocator);
    var sources = try collectSources(allocator, &analyzer, summaries.items);
    defer sources.deinit(allocator);
    try std.testing.expect(sources.items.len > 0);

    var symbols = symbolize_mod.Symbols{ .stdout = &.{}, .frames = .empty, .ranges = .empty };
    defer symbols.frames.deinit(allocator);
    defer symbols.ranges.deinit(allocator);
    try symbols.frames.appendSlice(allocator, &.{
        .{ .function = "inlined", .location = "a.zig:1" },
        .{ .function = "owner", .location = "a.zig:9" },
    });
    for (sources.items) |source| {
        inline for (.{ source.key.site, source.key.caller }) |address| {
            try symbols.ranges.put(allocator, address, .{ .start = 0, .len = 2 });
        }
    }

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try writeJsonl(
        &output.writer,
        &analyzer,
        try analyzer.totals(.allocations),
        .allocations,
        .roots,
        window,
        .{
            .source_groups = sources.items.len,
            .displayed_sources = sources.items.len,
            .root_stacks = summaries.items.len,
            .displayed_stacks = 0,
        },
        sources.items,
        &.{},
        symbols,
        capture_mod.max_frames_limit,
        @splat(0xaa),
    );

    var summary_fields: [@typeInfo(SummaryRecord).@"struct".field_names.len]bool = @splat(false);
    var source_fields: [@typeInfo(SourceRecord).@"struct".field_names.len]bool = @splat(false);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output.written(), "\n"), '\n');
    while (lines.next()) |line| {
        const written = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer written.deinit();
        const kind = written.value.object.get("kind").?.string;
        if (std.mem.eql(u8, kind, "causal_root_summary")) {
            const record = try std.json.parseFromSlice(SummaryRecord, allocator, line, .{});
            defer record.deinit();
            inline for (@typeInfo(SummaryRecord).@"struct".field_names, 0..) |name, index| {
                if (written.value.object.contains(name)) summary_fields[index] = true;
            }
        } else if (std.mem.eql(u8, kind, "causal_root_source")) {
            const record = try std.json.parseFromSlice(SourceRecord, allocator, line, .{});
            defer record.deinit();
            inline for (@typeInfo(SourceRecord).@"struct".field_names, 0..) |name, index| {
                if (written.value.object.contains(name)) source_fields[index] = true;
            }
        }
    }
    for (summary_fields) |seen| try std.testing.expect(seen);
    for (source_fields) |seen| try std.testing.expect(seen);
}

test "causal root source ordering is irreflexive" {
    const source = Source{
        .key = .{
            .kind = .alloc,
            .succeeded = true,
            .layer = .logical_allocator,
            .producer = .arena,
            .site = 1,
            .caller = 2,
        },
        .counters = .{},
        .unique_stacks = 1,
    };
    try std.testing.expect(!sourceGreaterThan(.high_water, source, source));
}

test "causal root lifetime tracks resize and release" {
    var lifetime = Lifetime{};
    try lifetime.allocate(16);
    try lifetime.resize(16, 40);
    try lifetime.resize(40, 24);
    try lifetime.free(24);
    try std.testing.expectEqual(@as(u64, 0), lifetime.live_allocations);
    try std.testing.expectEqual(@as(u128, 0), lifetime.live_bytes);
    try std.testing.expectEqual(
        @as(u128, 40),
        lifetime.high_water_live_bytes,
    );
}

test "causal operation ledger validates contiguous multi-event groups" {
    var ledger = OperationLedger{};
    defer ledger.deinit(std.testing.allocator);
    try ledger.record(std.testing.allocator, 2, 1);
    try ledger.record(std.testing.allocator, 2, 1);
    try ledger.record(std.testing.allocator, 1, 0);
    try ledger.validate();
    try std.testing.expectEqual(@as(u64, 2), ledger.unique);
    try std.testing.expectError(
        error.NonContiguousCausalOperationGroup,
        ledger.record(std.testing.allocator, 2, 1),
    );
}

test "causal operation ledger rejects a parent conflict within one group" {
    var ledger = OperationLedger{};
    defer ledger.deinit(std.testing.allocator);
    try ledger.record(std.testing.allocator, 2, 1);
    try std.testing.expectError(
        error.CausalOperationParentConflict,
        ledger.record(std.testing.allocator, 2, 0),
    );
}
