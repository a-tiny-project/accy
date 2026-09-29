const std = @import("std");
const root = @import("../../../root.zig");

const Allocator = std.mem.Allocator;
const model = root.model;

const no_candidate = std.math.maxInt(usize);

pub const Entry = struct {
    first: usize = no_candidate,
    overflow: std.ArrayListUnmanaged(usize) = .empty,
    defined: bool = false,
    unresolved: bool = false,

    fn deinit(self: *Entry, allocator: Allocator) void {
        self.overflow.deinit(allocator);
        self.* = undefined;
    }
};

pub const Index = std.StringHashMapUnmanaged(Entry);
pub const Queue = std.PriorityQueue(usize, void, compareCandidateIndex);

pub fn add(
    allocator: Allocator,
    definitions: *Index,
    symbol_name: []const u8,
    candidate_index: usize,
    active_candidate_counts: []usize,
    pending: *Queue,
) model.Error!void {
    const gop = try definitions.getOrPut(allocator, symbol_name);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .first = candidate_index };
    } else if (gop.value_ptr.first == no_candidate) {
        gop.value_ptr.first = candidate_index;
    } else {
        try gop.value_ptr.overflow.append(allocator, candidate_index);
    }
    if (gop.value_ptr.unresolved) {
        try activateCandidateIndex(allocator, active_candidate_counts, pending, candidate_index);
    }
}

pub fn define(
    allocator: Allocator,
    definitions: *Index,
    unresolved_names: *usize,
    active_candidate_counts: []usize,
    symbol_name: []const u8,
) model.Error!void {
    const gop = try definitions.getOrPut(allocator, symbol_name);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const entry = gop.value_ptr;
    if (entry.unresolved) {
        entry.unresolved = false;
        unresolved_names.* -= 1;
        try deactivateEntry(entry.*, active_candidate_counts);
    }
    entry.defined = true;
}

pub fn require(
    allocator: Allocator,
    definitions: *Index,
    unresolved_names: *usize,
    active_candidate_counts: []usize,
    pending: *Queue,
    symbol_name: []const u8,
) model.Error!void {
    const gop = try definitions.getOrPut(allocator, symbol_name);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const entry = gop.value_ptr;
    if (entry.defined or entry.unresolved) return;
    entry.unresolved = true;
    unresolved_names.* += 1;
    try activateEntry(allocator, entry.*, active_candidate_counts, pending);
}

pub fn deinit(allocator: Allocator, definitions: *Index) void {
    var values = definitions.valueIterator();
    while (values.next()) |entry| entry.deinit(allocator);
    definitions.deinit(allocator);
}

fn activateEntry(
    allocator: Allocator,
    entry: Entry,
    active_candidate_counts: []usize,
    pending: *Queue,
) model.Error!void {
    if (entry.first == no_candidate) return;
    try activateCandidateIndex(allocator, active_candidate_counts, pending, entry.first);
    for (entry.overflow.items) |index| try activateCandidateIndex(allocator, active_candidate_counts, pending, index);
}

fn deactivateEntry(entry: Entry, active_candidate_counts: []usize) model.Error!void {
    if (entry.first == no_candidate) return;
    try deactivateCandidateIndex(active_candidate_counts, entry.first);
    for (entry.overflow.items) |index| try deactivateCandidateIndex(active_candidate_counts, index);
}

fn activateCandidateIndex(
    allocator: Allocator,
    active_candidate_counts: []usize,
    pending: *Queue,
    index: usize,
) model.Error!void {
    if (index >= active_candidate_counts.len) return error.InvalidArchive;
    if (active_candidate_counts[index] == std.math.maxInt(usize)) return error.InvalidArchive;
    active_candidate_counts[index] += 1;
    try pending.push(allocator, index);
}

fn deactivateCandidateIndex(active_candidate_counts: []usize, index: usize) model.Error!void {
    if (index >= active_candidate_counts.len) return error.InvalidArchive;
    if (active_candidate_counts[index] == 0) return error.InvalidArchive;
    active_candidate_counts[index] -= 1;
}

fn compareCandidateIndex(_: void, a: usize, b: usize) std.math.Order {
    return std.math.order(a, b);
}

test "definition add activates candidates for names already required" {
    const allocator = std.testing.allocator;
    var definitions: Index = .{};
    defer deinit(allocator, &definitions);
    var counts = [_]usize{ 0, 0 };
    var pending = Queue.initContext({});
    defer pending.deinit(allocator);
    var unresolved_names: usize = 0;

    try require(allocator, &definitions, &unresolved_names, &counts, &pending, "puts");
    try std.testing.expectEqual(@as(usize, 1), unresolved_names);
    try std.testing.expectEqual(@as(?usize, null), pending.peek());

    try add(allocator, &definitions, "puts", 0, &counts, &pending);
    try std.testing.expectEqual(@as(usize, 1), counts[0]);
    try std.testing.expectEqual(@as(?usize, 0), pending.peek());

    try add(allocator, &definitions, "puts", 1, &counts, &pending);
    try std.testing.expectEqual(@as(usize, 1), counts[1]);
}

test "definition define clears required names and deactivates candidates" {
    const allocator = std.testing.allocator;
    var definitions: Index = .{};
    defer deinit(allocator, &definitions);
    var counts = [_]usize{ 0, 0 };
    var pending = Queue.initContext({});
    defer pending.deinit(allocator);
    var unresolved_names: usize = 0;

    try add(allocator, &definitions, "puts", 0, &counts, &pending);
    try add(allocator, &definitions, "puts", 1, &counts, &pending);
    try require(allocator, &definitions, &unresolved_names, &counts, &pending, "puts");
    try std.testing.expectEqual(@as(usize, 1), counts[0]);
    try std.testing.expectEqual(@as(usize, 1), counts[1]);

    try define(allocator, &definitions, &unresolved_names, &counts, "puts");
    try std.testing.expectEqual(@as(usize, 0), unresolved_names);
    try std.testing.expectEqual(@as(usize, 0), counts[0]);
    try std.testing.expectEqual(@as(usize, 0), counts[1]);

    try require(allocator, &definitions, &unresolved_names, &counts, &pending, "puts");
    try std.testing.expectEqual(@as(usize, 0), unresolved_names);
    try std.testing.expectEqual(@as(usize, 0), counts[0]);
}

test "definition require activates first and overflow candidates once" {
    const allocator = std.testing.allocator;
    var definitions: Index = .{};
    defer deinit(allocator, &definitions);
    var counts = [_]usize{ 0, 0, 0 };
    var pending = Queue.initContext({});
    defer pending.deinit(allocator);
    var unresolved_names: usize = 0;

    try add(allocator, &definitions, "malloc", 0, &counts, &pending);
    try add(allocator, &definitions, "malloc", 1, &counts, &pending);
    try add(allocator, &definitions, "malloc", 2, &counts, &pending);
    try std.testing.expectEqual(@as(?usize, null), pending.peek());

    try require(allocator, &definitions, &unresolved_names, &counts, &pending, "malloc");
    try require(allocator, &definitions, &unresolved_names, &counts, &pending, "malloc");
    try std.testing.expectEqual(@as(usize, 1), unresolved_names);
    for (counts) |count| try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(?usize, 0), pending.pop());
    try std.testing.expectEqual(@as(?usize, 1), pending.pop());
    try std.testing.expectEqual(@as(?usize, 2), pending.pop());
    try std.testing.expectEqual(@as(?usize, null), pending.pop());
}
