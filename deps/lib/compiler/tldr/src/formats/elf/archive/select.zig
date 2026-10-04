const std = @import("std");
const allocators = @import("alloc");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const definition = @import("definition.zig");
const member_selection = @import("member.zig");
const object_selection = @import("object.zig");
const prefetch = @import("prefetch.zig");

const Allocator = std.mem.Allocator;
const archive_format = root.archive;
const model = root.model;
const parallel = root.parallel;
const trace = root.trace;
const ObjectFile = elf.parser.ObjectFile;
const ObjectParseOptions = elf.parser.ObjectParseOptions;
const ObjectSelectionSummary = elf.parser.ObjectSelectionSummary;
const parseObjectSelectionSummary = elf.parser.parseObjectSelectionSummary;
const parseObjectWithSelectionSummary = elf.parser.parseObjectWithSelectionSummary;
const parseObjectWithOptions = elf.parser.parseObjectWithOptions;

const selected_objects_per_worker = 4;

const Candidate = struct {
    archive_name: []const u8,
    archive_input_index: usize,
    member: archive_format.Member,
    object: ?ObjectFile = null,
    summary: ?ObjectSelectionSummary = null,
    summary_failure: ?model.Error = null,
    extracted: bool = false,

    fn deinitIfUnextracted(self: *Candidate, allocator: Allocator) void {
        if (!self.extracted) {
            if (self.object) |*object| object.deinit(allocator);
        }
    }

    fn load(
        self: *Candidate,
        allocator: Allocator,
        options: model.LinkOptions,
    ) model.Error!*ObjectFile {
        if (self.object) |*object| return object;
        if (self.summary) |summary| {
            self.object = parseObjectWithSelectionSummary(allocator, summary, .{
                .strip_debug = options.strip_debug,
                .worker_budget = options.max_link_jobs,
            }) catch |err| switch (err) {
                error.InvalidElfHeader => return archiveMemberHeaderFailure(self.*, err, options),
                else => return err,
            };
            self.summary = null;
        } else {
            self.object = parseObjectWithOptions(allocator, .{
                .name = self.member.name,
                .bytes = self.member.bytes,
            }, .{
                .strip_debug = options.strip_debug,
                .worker_budget = options.max_link_jobs,
            }) catch |err| switch (err) {
                error.InvalidElfHeader => return archiveMemberHeaderFailure(self.*, err, options),
                else => return err,
            };
        }
        if (self.object) |*object| object.input_index = self.archive_input_index;
        if (self.object) |*object| return object;
        unreachable;
    }

    fn loadSelectionSummary(
        self: *Candidate,
        selection: Allocator,
        options: model.LinkOptions,
    ) model.Error!*ObjectSelectionSummary {
        if (self.summary) |*summary| return summary;
        if (self.summary_failure) |failure| return mapSummaryFailure(self.*, failure, options);
        self.summary = parseObjectSelectionSummary(selection, .{
            .name = self.member.name,
            .bytes = self.member.bytes,
        }) catch |err| return mapSummaryFailure(self.*, err, options);
        if (self.summary) |*summary| return summary;
        unreachable;
    }
};

fn mapSummaryFailure(
    candidate: Candidate,
    parse_err: model.Error,
    options: model.LinkOptions,
) model.Error {
    return switch (parse_err) {
        error.InvalidElfHeader => archiveMemberHeaderFailure(candidate, parse_err, options),
        else => parse_err,
    };
}

const ArchiveIdentity = struct {
    address: usize,
    len: usize,
};

fn archiveMemberHeaderFailure(
    candidate: Candidate,
    parse_err: model.Error,
    options: model.LinkOptions,
) model.Error {
    const input_format = root.detectObjectFormat(candidate.member.bytes) catch |err| switch (err) {
        error.UnsupportedFormat => return parse_err,
        else => return err,
    };
    if (input_format == .elf) return parse_err;
    if (options.diagnostics) |diagnostics| {
        diagnostics.recordUnsupportedArchiveMemberFormat(
            candidate.archive_name,
            candidate.member.name,
            input_format,
            .elf,
        );
    }
    return error.UnsupportedFormat;
}

pub const ExtractionState = struct {
    candidates: std.ArrayListUnmanaged(Candidate) = .empty,
    first_archive: ?ArchiveIdentity = null,
    seen_archives: std.AutoHashMapUnmanaged(ArchiveIdentity, void) = .empty,
    definitions: definition.Index = .{},
    unresolved_names: usize = 0,
    active_candidate_counts: std.ArrayListUnmanaged(usize) = .empty,
    pending: definition.Queue = definition.Queue.initContext({}),
    observed_objects: usize = 0,

    pub fn deinit(self: *ExtractionState, allocator: Allocator) void {
        for (self.candidates.items) |*candidate| candidate.deinitIfUnextracted(allocator);
        self.candidates.deinit(allocator);
        self.seen_archives.deinit(allocator);
        definition.deinit(allocator, &self.definitions);
        self.active_candidate_counts.deinit(allocator);
        self.pending.deinit(allocator);
        self.* = undefined;
    }

    pub fn observeArchive(
        self: *ExtractionState,
        allocator: Allocator,
        input: model.Input,
    ) Allocator.Error!bool {
        const identity: ArchiveIdentity = .{
            .address = @intFromPtr(input.bytes.ptr),
            .len = input.bytes.len,
        };
        if (self.first_archive) |first_archive| {
            if (sameArchiveIdentity(first_archive, identity)) return false;
        } else {
            self.first_archive = identity;
            return true;
        }
        if (self.seen_archives.count() == 0) {
            try self.seen_archives.ensureTotalCapacity(allocator, 4);
            self.seen_archives.putAssumeCapacityNoClobber(self.first_archive.?, {});
        }
        const gop = try self.seen_archives.getOrPut(allocator, identity);
        return !gop.found_existing;
    }

    pub fn hasCandidates(self: ExtractionState) bool {
        return self.candidates.items.len != 0;
    }

    pub fn appendCandidate(
        self: *ExtractionState,
        allocator: Allocator,
        candidate: Candidate,
    ) Allocator.Error!usize {
        const index = self.candidates.items.len;
        try self.active_candidate_counts.append(allocator, 0);
        errdefer _ = self.active_candidate_counts.pop();
        try self.candidates.append(allocator, candidate);
        return index;
    }

    pub fn addDefinition(
        self: *ExtractionState,
        allocator: Allocator,
        symbol_name: []const u8,
        candidate_index: usize,
    ) model.Error!void {
        try definition.add(
            allocator,
            &self.definitions,
            symbol_name,
            candidate_index,
            self.active_candidate_counts.items,
            &self.pending,
        );
    }

    pub fn observeNewObjects(
        self: *ExtractionState,
        allocator: Allocator,
        objects: []const ObjectFile,
    ) model.Error!void {
        if (self.observed_objects >= objects.len) return;
        const recording_phase = trace.product(.archive_symbol_recording);
        defer recording_phase.end();
        while (self.observed_objects < objects.len) {
            try object_selection.record(
                allocator,
                objects,
                self.observed_objects,
                &self.definitions,
                &self.unresolved_names,
                self.active_candidate_counts.items,
                &self.pending,
            );
            self.observed_objects += 1;
        }
    }
};

fn sameArchiveIdentity(a: ArchiveIdentity, b: ArchiveIdentity) bool {
    return a.address == b.address and a.len == b.len;
}

test "archive extraction state skips repeated archive byte identities" {
    const allocator = std.testing.allocator;
    const first = [_]u8{ 1, 2, 3 };
    const second = [_]u8{ 1, 2, 4 };

    var state: ExtractionState = .{};
    defer state.deinit(allocator);

    try std.testing.expect(try state.observeArchive(allocator, .{ .name = "lib.a", .bytes = &first }));
    try std.testing.expect(!try state.observeArchive(allocator, .{ .name = "lib.a", .bytes = &first }));
    try std.testing.expect(try state.observeArchive(allocator, .{ .name = "lib.a", .bytes = &second }));
    try std.testing.expect(!try state.observeArchive(allocator, .{ .name = "lib.a", .bytes = &second }));
}

pub fn addCandidates(
    allocator: Allocator,
    selection: Allocator,
    input: model.Input,
    input_index: usize,
    state: *ExtractionState,
    options: model.LinkOptions,
    prefetcher: *prefetch.Prefetcher,
) model.Error!void {
    if (!try state.observeArchive(allocator, input)) return;
    const prefetched = take_prefetch: {
        const table_phase = trace.product(.archive_table_parse);
        defer table_phase.end();
        break :take_prefetch try prefetcher.take(input_index);
    };
    const first_new_candidate = state.candidates.items.len;
    try member_selection.addCandidates(allocator, selection, input, input_index, state, ObjectParseOptions{
        .strip_debug = options.strip_debug,
        .worker_budget = options.max_link_jobs,
    }, prefetched);
    prefetch.prepareSummaries(selection, state.candidates.items[first_new_candidate..], options);
}

pub fn extractCandidates(
    allocator: Allocator,
    selection: Allocator,
    objects: *std.ArrayListUnmanaged(ObjectFile),
    state: *ExtractionState,
    options: model.LinkOptions,
) model.Error!void {
    if (state.pending.peek() == null) return;
    if (options.max_link_jobs == 1) {
        return extractCandidatesSerial(allocator, objects, state, options);
    }

    return extractCandidatesBatched(allocator, selection, objects, state, options);
}

fn extractCandidatesSerial(
    allocator: Allocator,
    objects: *std.ArrayListUnmanaged(ObjectFile),
    state: *ExtractionState,
    options: model.LinkOptions,
) model.Error!void {
    if (state.pending.peek() == null) return;

    try objects.ensureUnusedCapacity(allocator, @min(state.candidates.items.len, state.unresolved_names));

    while (state.pending.pop()) |index| {
        if (index >= state.candidates.items.len) continue;
        var candidate = &state.candidates.items[index];
        if (candidate.extracted) continue;
        if (state.active_candidate_counts.items[index] == 0) continue;
        const object = load_member: {
            const parse_phase = trace.product(.selected_member_parse);
            defer parse_phase.end();
            break :load_member try candidate.load(allocator, options);
        };

        const object_index = objects.items.len;
        try objects.append(allocator, object.*);
        candidate.object = null;
        candidate.extracted = true;
        {
            const recording_phase = trace.product(.archive_symbol_recording);
            defer recording_phase.end();
            try object_selection.record(
                allocator,
                objects.items,
                object_index,
                &state.definitions,
                &state.unresolved_names,
                state.active_candidate_counts.items,
                &state.pending,
            );
        }
        state.observed_objects = object_index + 1;
    }
}

fn extractCandidatesBatched(
    allocator: Allocator,
    selection: Allocator,
    objects: *std.ArrayListUnmanaged(ObjectFile),
    state: *ExtractionState,
    options: model.LinkOptions,
) model.Error!void {
    var selected = std.ArrayListUnmanaged(usize).empty;
    defer selected.deinit(allocator);

    try selected.ensureUnusedCapacity(allocator, @min(state.candidates.items.len, state.unresolved_names));

    while (state.pending.pop()) |index| {
        if (index >= state.candidates.items.len) continue;
        var candidate = &state.candidates.items[index];
        if (candidate.extracted) continue;
        if (state.active_candidate_counts.items[index] == 0) continue;
        const summary = load_summary: {
            const summary_phase = trace.product(.archive_summary_parse);
            defer summary_phase.end();
            break :load_summary try candidate.loadSelectionSummary(selection, options);
        };

        try selected.append(allocator, index);
        candidate.extracted = true;
        {
            const recording_phase = trace.product(.archive_symbol_recording);
            defer recording_phase.end();
            try object_selection.recordSymbols(
                allocator,
                summary.symbols,
                &state.definitions,
                &state.unresolved_names,
                state.active_candidate_counts.items,
                &state.pending,
            );
        }
    }

    if (selected.items.len == 0) return;
    {
        const parse_phase = trace.product(.selected_member_parse);
        defer parse_phase.end();
        try parseSelectedObjects(allocator, objects, state, selected.items, options);
    }
    state.observed_objects = objects.items.len;
}

const SelectedParseFailure = struct {
    selected_index: usize = std.math.maxInt(usize),
    err: ?model.Error = null,

    fn found(self: SelectedParseFailure) bool {
        return self.err != null;
    }

    fn before(self: SelectedParseFailure, other: SelectedParseFailure) bool {
        return self.selected_index < other.selected_index;
    }
};

const SelectedParseFailures = parallel.FailureSlots(SelectedParseFailure);

const SelectedParseContext = struct {
    allocator: Allocator,
    candidates: []Candidate,
    selected: []const usize,
    objects: []ObjectFile,
    parse_options: ObjectParseOptions,
    failures: *SelectedParseFailures,
};

fn parseSelectedObjects(
    allocator: Allocator,
    objects: *std.ArrayListUnmanaged(ObjectFile),
    state: *ExtractionState,
    selected: []const usize,
    options: model.LinkOptions,
) model.Error!void {
    const object_start = objects.items.len;
    try objects.resize(allocator, object_start + selected.len);

    const workers = parallel.chooseWorkers(
        selected.len,
        parallel.grainWorkers(options.max_link_jobs, selected.len, selected_objects_per_worker),
    );
    const parse_options = ObjectParseOptions{
        .strip_debug = options.strip_debug,
        .worker_budget = options.max_link_jobs,
    };

    if (workers <= 1) {
        for (selected, 0..) |candidate_index, selected_index| {
            objects.items[object_start + selected_index] = try parseSelectedObject(
                allocator,
                &state.candidates.items[candidate_index],
                parse_options,
            );
        }
        return;
    }

    var locked_allocator = allocators.LockedAllocator.init(allocator);
    var failures = try SelectedParseFailures.init(allocator, workers, .{});
    defer failures.deinit(allocator);

    var context = SelectedParseContext{
        .allocator = locked_allocator.allocator(),
        .candidates = state.candidates.items,
        .selected = selected,
        .objects = objects.items[object_start..][0..selected.len],
        .parse_options = parse_options,
        .failures = &failures,
    };
    parallel.forItems(selected.len, workers, &context, parseSelectedObjectTask);
    if (failures.earliest(SelectedParseFailure.found, SelectedParseFailure.before)) |failure| {
        return failure.err.?;
    }
}

fn parseSelectedObject(
    allocator: Allocator,
    candidate: *Candidate,
    parse_options: ObjectParseOptions,
) model.Error!ObjectFile {
    const summary = candidate.summary orelse return error.InvalidObject;
    var object = try parseObjectWithSelectionSummary(allocator, summary, parse_options);
    candidate.summary = null;
    object.input_index = candidate.archive_input_index;
    return object;
}

fn parseSelectedObjectTask(context: *SelectedParseContext, worker: usize, selected_index: usize) void {
    const candidate_index = context.selected[selected_index];
    context.objects[selected_index] = parseSelectedObject(
        context.allocator,
        &context.candidates[candidate_index],
        context.parse_options,
    ) catch |err| {
        context.failures.record(worker, .{
            .selected_index = selected_index,
            .err = err,
        });
        return;
    };
}
