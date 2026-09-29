const std = @import("std");
const memtrace = @import("../root.zig");
const capture_mod = @import("capture.zig");
const identity_mod = @import("identity.zig");

const coverage_mod = memtrace.coverage;
const event_mod = memtrace.event;

const Allocator = std.mem.Allocator;

pub const Counters = struct {
    calls: u64 = 0,
    requested_bytes: u128 = 0,
};

pub const Totals = struct {
    calls: u64 = 0,
    successful: u64 = 0,
    failed: u64 = 0,
    requested_bytes: u128 = 0,
};

pub const Window = struct {
    scope: ?[]const u8 = null,
    first_sequence: ?u64 = null,
    last_sequence: ?u64 = null,

    pub fn validate(self: Window) !void {
        if (self.scope) |scope| {
            if (scope.len == 0 or
                (!std.mem.eql(u8, scope, "root") and
                    !std.mem.startsWith(u8, scope, "root/")) or
                scope[scope.len - 1] == '/')
            {
                return error.InvalidScopeWindow;
            }
        }
        if (self.first_sequence) |first| {
            if (first == 0) return error.InvalidSequenceWindow;
        }
        if (self.last_sequence) |last| {
            if (last == 0) return error.InvalidSequenceWindow;
        }
        if (self.first_sequence != null and
            self.last_sequence != null and
            self.first_sequence.? > self.last_sequence.?)
        {
            return error.InvalidSequenceWindow;
        }
    }

    fn includesSequence(self: Window, sequence: ?u64) bool {
        const actual = sequence orelse return false;
        if (self.first_sequence) |first| {
            if (actual < first) return false;
        }
        if (self.last_sequence) |last| {
            if (actual > last) return false;
        }
        return true;
    }
};

pub const Selection = enum {
    allocations,
    all,

    pub fn includes(self: Selection, kind: event_mod.Kind) bool {
        return switch (self) {
            .allocations => kind == .alloc or kind == .map,
            .all => kind.isMemoryOperation(),
        };
    }
};

pub const OperationKey = struct {
    stack_id: u32,
    kind: event_mod.Kind,
    succeeded: bool,
    layer: event_mod.Layer,
    producer: @import("alloc_observe").Producer,
};

pub const Definition = struct {
    call_addresses: []u64,
    truncated: bool,
    unwind_failed: bool,
    missing_return_address: bool,

    pub fn complete(self: Definition) bool {
        return !self.truncated and
            !self.unwind_failed and
            !self.missing_return_address and
            self.call_addresses.len > 1;
    }
};

pub const Summary = struct {
    key: OperationKey,
    counters: Counters,
    definition: Definition,
};

const Sequence = struct {
    events: u64 = 0,
    unsequenced: u64 = 0,
    gaps: u64 = 0,
    regressions: u64 = 0,
    starts: u64 = 0,
    stops: u64 = 0,
    recording_failures: u64 = 0,
    first: ?u64 = null,
    last: ?u64 = null,
    stop: ?u64 = null,

    fn record(self: *Sequence, event: event_mod.ReplayEvent) void {
        self.events +|= 1;
        const current = event.seq orelse {
            self.unsequenced +|= 1;
            return;
        };
        if (current == 0) {
            self.unsequenced +|= 1;
            return;
        }
        if (self.last) |previous| {
            if (current <= previous) {
                self.regressions +|= 1;
            } else if (current != previous + 1) {
                self.gaps +|= current - previous - 1;
            }
        } else {
            self.first = current;
            if (current != 1) self.gaps +|= current - 1;
        }
        self.last = current;
        switch (event.kind) {
            .trace_start => self.starts +|= 1,
            .trace_stop => {
                self.stops +|= 1;
                self.stop = current;
                self.recording_failures +|= event.recording_failures;
            },
            else => {},
        }
    }

    fn validate(self: Sequence) !void {
        if (self.events == 0 or self.starts != 1 or self.stops != 1) {
            return error.IncompleteEventSequence;
        }
        if (self.unsequenced != 0 or self.gaps != 0 or self.regressions != 0) {
            return error.IncompleteEventSequence;
        }
        if (self.first != 1 or self.stop != self.last) {
            return error.IncompleteEventSequence;
        }
        if (self.recording_failures != 0) return error.IncompleteEventSequence;
    }
};

const ScopeIndex = struct {
    paths: std.AutoHashMapUnmanaged(u32, []const u8) = .{},

    fn deinit(self: *ScopeIndex, allocator: Allocator) void {
        var paths = self.paths.valueIterator();
        while (paths.next()) |scope_path| allocator.free(scope_path.*);
        self.paths.deinit(allocator);
        self.* = undefined;
    }

    fn record(
        self: *ScopeIndex,
        allocator: Allocator,
        event: event_mod.ReplayEvent,
    ) !void {
        if (event.kind != .scope_enter) return;
        if (event.scope_id == 0 or event.scope.len == 0) {
            return error.InvalidScopeDefinition;
        }
        if (self.paths.get(event.scope_id)) |scope_path| {
            if (!std.mem.eql(u8, scope_path, event.scope)) {
                return error.ScopeIdentityConflict;
            }
            return;
        }
        const owned = try allocator.dupe(u8, event.scope);
        errdefer allocator.free(owned);
        try self.paths.putNoClobber(allocator, event.scope_id, owned);
    }

    fn includes(
        self: *const ScopeIndex,
        window: Window,
        event: event_mod.ReplayEvent,
    ) !bool {
        if (!window.includesSequence(event.seq)) return false;
        const requested = window.scope orelse return true;
        const actual = self.path(event.scope_id) orelse
            return error.MissingScopeDefinition;
        return scopeContains(requested, actual);
    }

    fn validateWindow(self: *const ScopeIndex, window: Window) !void {
        try window.validate();
        const requested = window.scope orelse return;
        if (std.mem.eql(u8, requested, "root")) return;
        var paths = self.paths.valueIterator();
        while (paths.next()) |scope_path| {
            if (scopeContains(requested, scope_path.*)) return;
        }
        return error.UnknownScopeWindow;
    }

    fn path(self: *const ScopeIndex, scope_id: u32) ?[]const u8 {
        if (scope_id == 0) return "root";
        return self.paths.get(scope_id);
    }
};

pub const Analyzer = struct {
    allocator: Allocator,
    window: Window,
    scopes: ScopeIndex = .{},
    definitions: std.AutoHashMapUnmanaged(u32, Definition) = .{},
    referenced_stacks: std.AutoHashMapUnmanaged(u32, void) = .{},
    counters: std.AutoHashMapUnmanaged(OperationKey, Counters) = .{},
    executable_digest: ?identity_mod.Digest = null,
    executable_records: u32 = 0,
    coverage: ?coverage_mod.Manifest = null,
    coverage_records: u32 = 0,
    unattributed_operations: u64 = 0,
    sequence: Sequence = .{},

    pub fn init(allocator: Allocator, window: Window) Analyzer {
        return .{ .allocator = allocator, .window = window };
    }

    pub fn deinit(self: *Analyzer) void {
        var definitions = self.definitions.valueIterator();
        while (definitions.next()) |definition| {
            self.allocator.free(definition.call_addresses);
        }
        self.scopes.deinit(self.allocator);
        self.definitions.deinit(self.allocator);
        self.referenced_stacks.deinit(self.allocator);
        self.counters.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ingestJsonLine(self: *Analyzer, line: []const u8) !void {
        const text = std.mem.trim(u8, line, " \t\r\n");
        if (text.len == 0) return;
        if (identity_mod.isMetadataLine(text)) {
            return try self.ingestExecutable(text);
        }
        if (coverage_mod.isMetadataLine(text)) {
            return try self.ingestCoverage(text);
        }
        if (capture_mod.isMetadataLine(text)) {
            return try self.ingestStack(text);
        }
        var line_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer line_arena.deinit();
        const event = try event_mod.parseReplay(line_arena.allocator(), text);
        self.sequence.record(event);
        try self.scopes.record(self.allocator, event);
        if (!event.kind.isMemoryOperation()) return;
        if (event.stack_id == 0) {
            self.unattributed_operations = try std.math.add(
                u64,
                self.unattributed_operations,
                1,
            );
            return;
        }
        try self.referenced_stacks.put(self.allocator, event.stack_id, {});
        if (!try self.includes(event)) return;
        const entry = try self.counters.getOrPut(
            self.allocator,
            .{
                .stack_id = event.stack_id,
                .kind = event.kind,
                .succeeded = event.succeeded,
                .layer = event.layer,
                .producer = event.producer,
            },
        );
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.calls = try std.math.add(
            u64,
            entry.value_ptr.calls,
            1,
        );
        entry.value_ptr.requested_bytes = try std.math.add(
            u128,
            entry.value_ptr.requested_bytes,
            requestBytes(event),
        );
    }

    pub fn validate(self: *const Analyzer) !void {
        try self.sequence.validate();
        try self.scopes.validateWindow(self.window);
        if (self.executable_records != 1 or self.executable_digest == null) {
            return error.MissingExecutableIdentity;
        }
        if (self.coverage_records != 1 or self.coverage == null) {
            return error.MissingCoverageManifest;
        }
        if (self.unattributed_operations != 0) {
            return error.MissingStackAttribution;
        }
        var definitions = self.definitions.valueIterator();
        while (definitions.next()) |definition| {
            if (!definition.complete()) return error.IncompleteStackCapture;
        }
        var referenced = self.referenced_stacks.keyIterator();
        while (referenced.next()) |stack_id| {
            _ = self.definitions.get(stack_id.*) orelse
                return error.MissingStackDefinition;
        }
    }

    pub fn collect(
        self: *const Analyzer,
        selection: Selection,
        layer: event_mod.LayerFilter,
    ) !std.ArrayListUnmanaged(Summary) {
        var summaries = std.ArrayListUnmanaged(Summary).empty;
        errdefer summaries.deinit(self.allocator);
        try summaries.ensureTotalCapacity(self.allocator, self.counters.count());
        var counters = self.counters.iterator();
        while (counters.next()) |entry| {
            if (!selection.includes(entry.key_ptr.kind)) continue;
            if (!layer.includes(entry.key_ptr.layer)) continue;
            summaries.appendAssumeCapacity(.{
                .key = entry.key_ptr.*,
                .counters = entry.value_ptr.*,
                .definition = self.definitions.get(entry.key_ptr.stack_id).?,
            });
        }
        std.mem.sort(Summary, summaries.items, {}, summaryGreaterThan);
        return summaries;
    }

    pub fn totals(
        self: *const Analyzer,
        selection: Selection,
        layer: event_mod.LayerFilter,
    ) Totals {
        var result: Totals = .{};
        var counters = self.counters.iterator();
        while (counters.next()) |entry| {
            if (!selection.includes(entry.key_ptr.kind)) continue;
            if (!layer.includes(entry.key_ptr.layer)) continue;
            result.calls +|= entry.value_ptr.calls;
            result.requested_bytes +|= entry.value_ptr.requested_bytes;
            if (entry.key_ptr.succeeded) {
                result.successful +|= entry.value_ptr.calls;
            } else {
                result.failed +|= entry.value_ptr.calls;
            }
        }
        return result;
    }

    pub fn stackDefinition(
        self: *const Analyzer,
        stack_id: u32,
    ) ?Definition {
        return self.definitions.get(stack_id);
    }

    pub fn includes(
        self: *const Analyzer,
        event: event_mod.ReplayEvent,
    ) !bool {
        return try self.scopes.includes(self.window, event);
    }

    pub fn scopePath(self: *const Analyzer, scope_id: u32) ?[]const u8 {
        return self.scopes.path(scope_id);
    }

    fn ingestExecutable(self: *Analyzer, text: []const u8) !void {
        const parsed = try parseMetadataRecord(
            identity_mod.Record,
            self.allocator,
            text,
            error.InvalidExecutableIdentity,
        );
        defer parsed.deinit();
        const digest = try identity_mod.parseDigest(parsed.value.sha256);
        if (self.executable_digest) |prior| {
            if (!std.mem.eql(u8, &prior, &digest)) {
                return error.InvalidExecutableIdentity;
            }
        }
        self.executable_digest = digest;
        self.executable_records = try std.math.add(
            u32,
            self.executable_records,
            1,
        );
    }

    fn ingestCoverage(self: *Analyzer, text: []const u8) !void {
        if (self.coverage != null) return error.InvalidCoverageMetadata;
        self.coverage = try coverage_mod.parseMetadata(self.allocator, text);
        self.coverage_records = try std.math.add(
            u32,
            self.coverage_records,
            1,
        );
    }

    fn ingestStack(self: *Analyzer, text: []const u8) !void {
        const parsed = try parseMetadataRecord(
            capture_mod.Record,
            self.allocator,
            text,
            error.InvalidStackDefinition,
        );
        defer parsed.deinit();
        const record = parsed.value;
        if (record.stack_id == 0 or self.definitions.contains(record.stack_id)) {
            return error.InvalidStackDefinition;
        }
        if (record.call_addresses.len == 0 or
            record.call_addresses.len > capture_mod.max_frames_limit)
        {
            return error.InvalidStackDefinition;
        }
        for (record.call_addresses) |address| {
            if (address == 0) return error.InvalidStackDefinition;
        }
        const addresses = try self.allocator.dupe(u64, record.call_addresses);
        errdefer self.allocator.free(addresses);
        try self.definitions.putNoClobber(self.allocator, record.stack_id, .{
            .call_addresses = addresses,
            .truncated = record.truncated,
            .unwind_failed = record.unwind_failed,
            .missing_return_address = record.missing_return_address,
        });
    }
};

fn scopeContains(requested: []const u8, actual: []const u8) bool {
    if (std.mem.eql(u8, requested, actual)) return true;
    return actual.len > requested.len and
        std.mem.startsWith(u8, actual, requested) and
        actual[requested.len] == '/';
}

fn summaryGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.counters.calls != right.counters.calls) {
        return left.counters.calls > right.counters.calls;
    }
    if (left.counters.requested_bytes != right.counters.requested_bytes) {
        return left.counters.requested_bytes > right.counters.requested_bytes;
    }
    if (left.key.kind != right.key.kind) {
        return @backingInt(left.key.kind) < @backingInt(right.key.kind);
    }
    if (left.key.layer != right.key.layer) {
        return @backingInt(left.key.layer) < @backingInt(right.key.layer);
    }
    if (left.key.producer != right.key.producer) {
        return @backingInt(left.key.producer) < @backingInt(right.key.producer);
    }
    if (left.key.succeeded != right.key.succeeded) return left.key.succeeded;
    return left.key.stack_id < right.key.stack_id;
}

fn requestBytes(event: event_mod.ReplayEvent) usize {
    return switch (event.kind) {
        .free, .release, .unmap => event.old_len,
        .alloc, .resize, .remap, .map, .protect, .discard, .decommit, .advise => event.len,
        else => unreachable,
    };
}

/// Parses one metadata line into its writer's record. A missing field makes
/// the record incomplete, which the reader names `incomplete`. Any other
/// fault, an out-of-range number included, is malformed metadata.
fn parseMetadataRecord(
    comptime Record: type,
    allocator: Allocator,
    text: []const u8,
    comptime incomplete: error{ InvalidExecutableIdentity, InvalidStackDefinition },
) error{
    OutOfMemory,
    InvalidStackMetadata,
    InvalidExecutableIdentity,
    InvalidStackDefinition,
}!std.json.Parsed(Record) {
    return std.json.parseFromSlice(Record, allocator, text, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MissingField => return incomplete,
        else => return error.InvalidStackMetadata,
    };
}

test "exact analyzer rejects an allocation without a stack" {
    var analyzer = Analyzer.init(std.testing.allocator, .{});
    defer analyzer.deinit();
    const digest: identity_mod.Digest = @splat(0xaa);
    var metadata = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer metadata.deinit();
    try identity_mod.writeMetadata(&metadata.writer, digest);
    try coverage_mod.writeMetadata(
        &metadata.writer,
        coverage_mod.boundaryManifest(),
    );
    var lines = std.mem.splitScalar(u8, metadata.written(), '\n');
    while (lines.next()) |line| try analyzer.ingestJsonLine(line);
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"seq\":1,\"kind\":\"trace.start\"}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"seq\":2,\"kind\":\"alloc\",\"len\":8,\"stack_id\":0}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"seq\":3,\"kind\":\"trace.stop\"}",
    );
    try std.testing.expectError(
        error.MissingStackAttribution,
        analyzer.validate(),
    );
}

test "exact analyzer rejects a truncated physical stack" {
    var analyzer = Analyzer.init(std.testing.allocator, .{});
    defer analyzer.deinit();
    const digest: identity_mod.Digest = @splat(0xaa);
    var metadata = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer metadata.deinit();
    try identity_mod.writeMetadata(&metadata.writer, digest);
    try coverage_mod.writeMetadata(
        &metadata.writer,
        coverage_mod.boundaryManifest(),
    );
    var addresses = [_]usize{ 1, 2 };
    try capture_mod.writeDefinition(&metadata.writer, 1, .{
        .addresses = &addresses,
        .truncated = true,
        .unwind_failed = false,
        .missing_return_address = false,
        .collision_next = 0,
    });
    var lines = std.mem.splitScalar(u8, metadata.written(), '\n');
    while (lines.next()) |line| try analyzer.ingestJsonLine(line);
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"seq\":1,\"kind\":\"trace.start\"}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"seq\":2,\"kind\":\"alloc\",\"len\":8,\"stack_id\":1}",
    );
    try analyzer.ingestJsonLine(
        "{\"v\":3,\"seq\":3,\"kind\":\"trace.stop\"}",
    );
    try std.testing.expectError(
        error.IncompleteStackCapture,
        analyzer.validate(),
    );
}

test "exact analyzer preserves allocator layers and producers" {
    var analyzer = Analyzer.init(std.testing.allocator, .{});
    defer analyzer.deinit();
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
        .kind = .alloc,
        .len = 128,
        .stack_id = 1,
    }).writeJsonLine(&input.writer, null, null);
    try (event_mod.Event{
        .seq = 3,
        .kind = .alloc,
        .len = 16,
        .stack_id = 1,
        .layer = .logical_allocator,
        .producer = .arena,
    }).writeJsonLine(&input.writer, null, null);
    try (event_mod.Event{
        .seq = 4,
        .kind = .trace_stop,
    }).writeJsonLine(&input.writer, null, null);
    var lines = std.mem.splitScalar(u8, input.written(), '\n');
    while (lines.next()) |line| try analyzer.ingestJsonLine(line);
    try analyzer.validate();

    const backing = analyzer.totals(.allocations, .backing);
    const logical = analyzer.totals(.allocations, .logical);
    const all = analyzer.totals(.allocations, .all);
    try std.testing.expectEqual(@as(u64, 1), backing.calls);
    try std.testing.expectEqual(@as(u128, 128), backing.requested_bytes);
    try std.testing.expectEqual(@as(u64, 1), logical.calls);
    try std.testing.expectEqual(@as(u128, 16), logical.requested_bytes);
    try std.testing.expectEqual(@as(u64, 2), all.calls);

    var logical_summaries = try analyzer.collect(.allocations, .logical);
    defer logical_summaries.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), logical_summaries.items.len);
    try std.testing.expectEqual(
        event_mod.Layer.logical_allocator,
        logical_summaries.items[0].key.layer,
    );
    try std.testing.expectEqual(
        @import("alloc_observe").Producer.arena,
        logical_summaries.items[0].key.producer,
    );
}

test "exact analyzer filters a scope subtree and inclusive sequence window" {
    var analyzer = Analyzer.init(std.testing.allocator, .{
        .scope = "root/phase",
        .first_sequence = 3,
        .last_sequence = 5,
    });
    defer analyzer.deinit();
    try ingestWindowFixture(&analyzer);
    try analyzer.validate();

    const totals = analyzer.totals(.allocations, .backing);
    try std.testing.expectEqual(@as(u64, 2), totals.calls);
    try std.testing.expectEqual(@as(u128, 24), totals.requested_bytes);
}

test "exact analyzer rejects an unknown scope window" {
    var analyzer = Analyzer.init(std.testing.allocator, .{
        .scope = "root/absent",
    });
    defer analyzer.deinit();
    try ingestWindowFixture(&analyzer);
    try std.testing.expectError(error.UnknownScopeWindow, analyzer.validate());
}

fn ingestWindowFixture(analyzer: *Analyzer) !void {
    const digest: identity_mod.Digest = @splat(0xaa);
    var input = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer input.deinit();
    try identity_mod.writeMetadata(&input.writer, digest);
    try coverage_mod.writeMetadata(
        &input.writer,
        coverage_mod.boundaryManifest(),
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
        "{\"v\":3,\"seq\":3,\"kind\":\"alloc\",\"scope_id\":1,\"len\":8," ++
            "\"stack_id\":1}",
        "{\"v\":3,\"seq\":4,\"kind\":\"scope.enter\",\"scope_id\":2," ++
            "\"scope\":\"root/phase/child\"}",
        "{\"v\":3,\"seq\":5,\"kind\":\"alloc\",\"scope_id\":2,\"len\":16," ++
            "\"stack_id\":1}",
        "{\"v\":3,\"seq\":6,\"kind\":\"scope.exit\",\"scope_id\":2}",
        "{\"v\":3,\"seq\":7,\"kind\":\"scope.exit\",\"scope_id\":1}",
        "{\"v\":3,\"seq\":8,\"kind\":\"scope.enter\",\"scope_id\":3," ++
            "\"scope\":\"root/other\"}",
        "{\"v\":3,\"seq\":9,\"kind\":\"alloc\",\"scope_id\":3,\"len\":32," ++
            "\"stack_id\":1}",
        "{\"v\":3,\"seq\":10,\"kind\":\"scope.exit\",\"scope_id\":3}",
        "{\"v\":3,\"seq\":11,\"kind\":\"trace.stop\"}",
    };
    var metadata = std.mem.splitScalar(u8, input.written(), '\n');
    while (metadata.next()) |line| try analyzer.ingestJsonLine(line);
    for (lines) |line| try analyzer.ingestJsonLine(line);
}
