const std = @import("std");
const allocators = @import("alloc");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");

const Allocator = std.mem.Allocator;
const archive_format = root.archive;
const elf_object = elf.object;
const model = root.model;
const parallel = root.parallel;
const trace = root.trace;
const ObjectSelectionSummary = elf.parser.ObjectSelectionSummary;
const parseObjectSelectionSummary = elf.parser.parseObjectSelectionSummary;

pub const speculative_summary_min_bytes = 2 * 1024 * 1024;
pub const summary_bytes_per_worker = 1024 * 1024;

pub const Prefetched = struct {
    parsed: archive_format.ParsedArchive,
    summaries: []const ?ObjectSelectionSummary = &.{},
    failures: []const ?model.Error = &.{},
};

pub const Prefetcher = struct {
    enabled: bool = false,
    selection: Allocator = undefined,
    inputs: []const model.Input = &.{},
    worker_budget: usize = 1,
    next_scan: usize = 0,
    target: ?usize = null,
    parsed: ?archive_format.ParsedArchive = null,
    failure: ?model.Error = null,
    references: []usize = &.{},
    summaries: []?ObjectSelectionSummary = &.{},
    failures: []?model.Error = &.{},
    table_job: TableJob = .{},
    summary_job: SummaryJob = .{},

    const TableJob: type = parallel.Background(*Prefetcher, parseTable);
    const SummaryJob: type = parallel.Background(*Prefetcher, parseSummary);

    pub fn init(
        selection: Allocator,
        inputs: []const model.Input,
        options: model.LinkOptions,
    ) Prefetcher {
        return .{
            .enabled = parallel.overlapAvailable(options.max_link_jobs),
            .selection = selection,
            .inputs = inputs,
            .worker_budget = options.max_link_jobs,
        };
    }

    pub fn deinit(self: *Prefetcher) void {
        self.table_job.wait();
        self.summary_job.wait();
    }

    pub fn advance(self: *Prefetcher, from_index: usize) void {
        if (!self.enabled) return;
        if (self.target) |current| {
            if (current >= from_index) return;
            self.table_job.wait();
            self.summary_job.wait();
            self.target = null;
        }
        var index = @max(self.next_scan, from_index);
        while (index < self.inputs.len and !archive_format.isArchive(self.inputs[index].bytes)) {
            index += 1;
        }
        if (index >= self.inputs.len) {
            self.next_scan = self.inputs.len;
            return;
        }
        self.next_scan = index + 1;
        self.target = index;
        self.parsed = null;
        self.failure = null;
        self.references = &.{};
        self.summaries = &.{};
        self.failures = &.{};
        self.table_job.submit(1, 1, self);
    }

    pub fn take(self: *Prefetcher, input_index: usize) model.Error!?Prefetched {
        const current = self.target orelse return null;
        if (current != input_index) return null;
        self.table_job.wait();
        self.summary_job.wait();
        self.target = null;
        if (self.failure) |err| {
            self.failure = null;
            return err;
        }
        const parsed = self.parsed.?;
        self.parsed = null;
        return .{
            .parsed = parsed,
            .summaries = self.summaries,
            .failures = self.failures,
        };
    }

    fn parseTable(self: *Prefetcher, item: usize) void {
        _ = item;
        const input = self.inputs[self.target.?];
        self.parsed = archive_format.parseDetailed(self.selection, input) catch |err| {
            self.failure = err;
            return;
        };
        const parsed = &self.parsed.?;
        if (!parsed.has_symbol_index) return;
        self.chainSummaries(parsed) catch {};
    }

    fn chainSummaries(self: *Prefetcher, parsed: *const archive_format.ParsedArchive) Allocator.Error!void {
        const members = parsed.members;
        const referenced = try self.selection.alloc(bool, members.len);
        @memset(referenced, false);
        var references = std.ArrayListUnmanaged(usize).empty;
        var total_bytes: usize = 0;

        var offsets_ordered = true;
        var previous_member_offset: u64 = 0;
        var member_cursor: usize = 0;
        for (parsed.symbol_index) |entry| {
            if (entry.member_offset < previous_member_offset) offsets_ordered = false;
            previous_member_offset = entry.member_offset;
            const member_index = if (offsets_ordered)
                archive_format.memberIndexByOffsetWithCursor(members, entry.member_offset, &member_cursor) orelse return
            else
                archive_format.memberIndexByOffset(members, entry.member_offset) orelse return;
            if (referenced[member_index]) continue;
            referenced[member_index] = true;
            try references.append(self.selection, member_index);
            total_bytes +|= members[member_index].bytes.len;
        }
        if (total_bytes < speculative_summary_min_bytes) return;

        const summaries = try self.selection.alloc(?ObjectSelectionSummary, members.len);
        @memset(summaries, null);
        const failures = try self.selection.alloc(?model.Error, members.len);
        @memset(failures, null);
        self.summaries = summaries;
        self.failures = failures;
        self.references = references.items;

        // The calling thread goes on linking beside the summary job, so the
        // job takes the rest of the budget.
        std.debug.assert(self.worker_budget > 1);
        const workers = parallel.grainWorkers(
            self.worker_budget - 1,
            total_bytes,
            summary_bytes_per_worker,
        );
        self.summary_job.submit(self.references.len, workers, self);
    }

    fn parseSummary(self: *Prefetcher, item: usize) void {
        const member_index = self.references[item];
        const member = self.parsed.?.members[member_index];
        self.summaries[member_index] = parseObjectSelectionSummary(self.selection, .{
            .name = member.name,
            .bytes = member.bytes,
        }) catch |err| {
            self.failures[member_index] = err;
            return;
        };
    }
};

pub fn prepareSummaries(
    selection: Allocator,
    candidates: anytype,
    options: model.LinkOptions,
) void {
    if (options.max_link_jobs == 1) return;
    var total_bytes: usize = 0;
    for (candidates) |candidate| {
        if (candidate.summary != null or candidate.object != null) continue;
        total_bytes +|= candidate.member.bytes.len;
    }
    if (total_bytes < speculative_summary_min_bytes) return;

    const workers = parallel.chooseWorkers(
        candidates.len,
        parallel.grainWorkers(options.max_link_jobs, total_bytes, summary_bytes_per_worker),
    );
    if (workers <= 1) return;

    const summary_phase = trace.product(.archive_summary_parse);
    defer summary_phase.end();
    const Context = SummaryContext(@TypeOf(candidates));
    var context = Context{
        .selection = selection,
        .candidates = candidates,
    };
    parallel.forItems(candidates.len, workers, &context, Context.task);
}

fn SummaryContext(comptime Candidates: type) type {
    return struct {
        selection: Allocator,
        candidates: Candidates,

        fn task(context: *@This(), worker: usize, index: usize) void {
            _ = worker;
            const candidate = &context.candidates[index];
            if (candidate.summary != null or candidate.object != null) return;
            candidate.summary = parseObjectSelectionSummary(context.selection, .{
                .name = candidate.member.name,
                .bytes = candidate.member.bytes,
            }) catch |err| {
                candidate.summary_failure = err;
                return;
            };
        }
    };
}

/// Leaves the prefetcher a worker beside the calling thread.
const test_worker_budget = 4;

test "prefetcher stashes the next archive table and summaries" {
    const allocator = std.testing.allocator;
    var selection_state = std.heap.ArenaAllocator.init(allocator);
    defer selection_state.deinit();
    var selection_lock = allocators.LockedAllocator.init(selection_state.allocator());
    const selection = selection_lock.allocator();

    const payload = try allocator.alloc(u8, speculative_summary_min_bytes);
    defer allocator.free(payload);
    @memset(payload, 0x90);
    const member_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text.big", payload, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("big", 1, 0, payload.len),
        },
    });
    defer allocator.free(member_object);

    const archive_bytes = try archive_format.build(allocator, &.{
        .{ .name = "big.o", .bytes = member_object, .symbols = &.{"big"} },
    });
    defer allocator.free(archive_bytes);

    const inputs = [_]model.Input{
        .{ .name = "start.o", .bytes = "not an archive" },
        .{ .name = "libbig.a", .bytes = archive_bytes },
    };

    var prefetcher = Prefetcher.init(selection, &inputs, .{ .max_link_jobs = test_worker_budget });
    defer prefetcher.deinit();
    prefetcher.advance(0);

    try std.testing.expectEqual(@as(?Prefetched, null), try prefetcher.take(0));
    const ready = (try prefetcher.take(1)) orelse {
        if (!parallel.overlapAvailable(test_worker_budget)) return;
        return error.MissingPrefetch;
    };
    try std.testing.expect(ready.parsed.has_symbol_index);
    try std.testing.expectEqual(@as(usize, 1), ready.parsed.members.len);
    try std.testing.expectEqualStrings("big.o", ready.parsed.members[0].name);
    try std.testing.expectEqual(@as(usize, 1), ready.summaries.len);
    const summary = ready.summaries[0] orelse return error.MissingSummary;
    try std.testing.expect(summary.symbols.len != 0);
    try std.testing.expectEqual(@as(?model.Error, null), ready.failures[0]);
}

test "prefetcher surfaces stashed table failures at take" {
    const allocator = std.testing.allocator;
    var selection_state = std.heap.ArenaAllocator.init(allocator);
    defer selection_state.deinit();
    var selection_lock = allocators.LockedAllocator.init(selection_state.allocator());
    const selection = selection_lock.allocator();

    const corrupt = "!<arch>\ncorrupt archive body";
    const inputs = [_]model.Input{
        .{ .name = "libbad.a", .bytes = corrupt },
    };

    var prefetcher = Prefetcher.init(selection, &inputs, .{ .max_link_jobs = test_worker_budget });
    defer prefetcher.deinit();
    prefetcher.advance(0);
    if (!prefetcher.enabled) return;

    try std.testing.expectError(error.InvalidArchive, prefetcher.take(0));
    try std.testing.expectEqual(@as(?Prefetched, null), try prefetcher.take(0));
}

test "prefetcher discards stale targets when the loop passes them" {
    const allocator = std.testing.allocator;
    var selection_state = std.heap.ArenaAllocator.init(allocator);
    defer selection_state.deinit();
    var selection_lock = allocators.LockedAllocator.init(selection_state.allocator());
    const selection = selection_lock.allocator();

    const first = try archive_format.build(allocator, &.{
        .{ .name = "a.o", .bytes = "xy", .symbols = &.{"a"} },
    });
    defer allocator.free(first);
    const second = try archive_format.build(allocator, &.{
        .{ .name = "b.o", .bytes = "zw", .symbols = &.{"b"} },
    });
    defer allocator.free(second);

    const inputs = [_]model.Input{
        .{ .name = "libfirst.a", .bytes = first },
        .{ .name = "libsecond.a", .bytes = second },
    };

    var prefetcher = Prefetcher.init(selection, &inputs, .{ .max_link_jobs = test_worker_budget });
    defer prefetcher.deinit();
    prefetcher.advance(0);
    if (!prefetcher.enabled) return;

    prefetcher.advance(1);
    const ready = (try prefetcher.take(1)) orelse return error.MissingPrefetch;
    try std.testing.expectEqualStrings("b.o", ready.parsed.members[0].name);
}

test "disabled prefetcher never targets inputs" {
    const allocator = std.testing.allocator;
    var selection_state = std.heap.ArenaAllocator.init(allocator);
    defer selection_state.deinit();
    var selection_lock = allocators.LockedAllocator.init(selection_state.allocator());
    const selection = selection_lock.allocator();

    const bytes = try archive_format.build(allocator, &.{
        .{ .name = "a.o", .bytes = "xy", .symbols = &.{"a"} },
    });
    defer allocator.free(bytes);
    const inputs = [_]model.Input{
        .{ .name = "liba.a", .bytes = bytes },
    };

    var prefetcher = Prefetcher.init(selection, &inputs, .{ .max_link_jobs = 1 });
    defer prefetcher.deinit();
    prefetcher.advance(0);
    try std.testing.expectEqual(@as(?Prefetched, null), try prefetcher.take(0));
}
