const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys");
const native = @import("wayland");
const windowing = @import("../root.zig");
const present = @import("present/root.zig");

const buffer = present.buffer;
const desktop = native.protocol.desktop;
const runtime = native.runtime;

const Timestamp = windowing.presentation.Timestamp;
const Submission = windowing.presentation.Submission;
const Outcome = windowing.presentation.Outcome;

pub const CapacityError = error{
    PendingFeedbackEmpty,
    RetainedOutcomesEmpty,
    RetainedOutcomesTooSmall,
    ActiveBuffersEmpty,
    RetiredBuffersEmpty,
    BufferSlotsTooMany,
    FrameStorageEmpty,
    CapacityOverflow,
};

pub const Capacity = struct {
    frames: windowing.presentation.Capacity,
    pending_feedback_count: usize,
    retained_outcome_count: usize,
    feedback_deadline_ns: u64,
    state_bytes: usize,
    pending_feedback_bytes: usize,
    retained_outcome_bytes: usize,
    swapchain: buffer.Capacity,
    swapchain_metadata_bytes: usize,
    pending_frame_bytes: usize,
    maximum_foreign_mapped_frame_bytes: usize,
    total_heap_bytes: usize,

    pub fn derive(limits: windowing.presentation.Limits) CapacityError!Capacity {
        if (limits.pending_feedback_count == 0) return error.PendingFeedbackEmpty;
        if (limits.retained_outcome_count == 0) return error.RetainedOutcomesEmpty;
        const minimum_outcomes = std.math.mul(usize, limits.pending_feedback_count, 2) catch return error.CapacityOverflow;
        const frames = try windowing.presentation.Capacity.derive(limits);
        const swapchain = try buffer.Capacity.derive(
            limits.active_buffer_count,
            limits.retired_buffer_count,
        );

        const pending_feedback_bytes = std.math.mul(
            usize,
            limits.pending_feedback_count,
            @sizeOf(PendingFeedback),
        ) catch return error.CapacityOverflow;
        if (limits.retained_outcome_count < minimum_outcomes) return error.RetainedOutcomesTooSmall;
        const retained_outcome_bytes = std.math.mul(
            usize,
            limits.retained_outcome_count,
            @sizeOf(Outcome),
        ) catch return error.CapacityOverflow;
        const storage_bytes = std.math.add(
            usize,
            pending_feedback_bytes,
            retained_outcome_bytes,
        ) catch return error.CapacityOverflow;
        const metadata_and_frame_bytes = std.math.add(
            usize,
            swapchain.metadata_storage_bytes,
            frames.wayland_pending_frame_bytes,
        ) catch return error.CapacityOverflow;
        const owner_storage_bytes = std.math.add(
            usize,
            storage_bytes,
            metadata_and_frame_bytes,
        ) catch return error.CapacityOverflow;
        const total_heap_bytes = std.math.add(
            usize,
            @sizeOf(State),
            owner_storage_bytes,
        ) catch return error.CapacityOverflow;
        const maximum_foreign_mapped_frame_bytes = std.math.mul(
            usize,
            swapchain.buffer_slot_count,
            frames.retained_frame_byte_count,
        ) catch return error.CapacityOverflow;
        return .{
            .frames = frames,
            .pending_feedback_count = limits.pending_feedback_count,
            .retained_outcome_count = limits.retained_outcome_count,
            .feedback_deadline_ns = limits.feedback_deadline_ns,
            .state_bytes = @sizeOf(State),
            .pending_feedback_bytes = pending_feedback_bytes,
            .retained_outcome_bytes = retained_outcome_bytes,
            .swapchain = swapchain,
            .swapchain_metadata_bytes = swapchain.metadata_storage_bytes,
            .pending_frame_bytes = frames.wayland_pending_frame_bytes,
            .maximum_foreign_mapped_frame_bytes = maximum_foreign_mapped_frame_bytes,
            .total_heap_bytes = total_heap_bytes,
        };
    }
};

pub const CallbackError = error{
    DuplicateClockId,
    InvalidEvent,
    InvalidTimestamp,
};

pub const InitError = error{OutOfMemory};

pub const Presentation = struct {
    state: *State,

    pub fn init(
        allocator: std.mem.Allocator,
        client: *runtime.Client,
        object_id: u32,
        capacity: Capacity,
    ) InitError!Presentation {
        const state = allocator.create(State) catch return error.OutOfMemory;
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .client = client,
            .object_id = object_id,
            .deadline_ns = capacity.feedback_deadline_ns,
            .storage = Storage.init(allocator, capacity) catch return error.OutOfMemory,
        };
        return .{ .state = state };
    }

    pub fn deinit(self: *Presentation) void {
        const state = self.state;
        state.client.request(
            state.object_id,
            desktop.wp_presentation.requests.destroy.opcode,
            &.{},
            &.{},
        ) catch {};
        state.storage.deinit(state.allocator);
        state.allocator.destroy(state);
        self.* = undefined;
    }

    pub fn dispatch(self: *Presentation, event: *runtime.RoutedView) !bool {
        if (event.object_id == self.state.object_id) {
            try self.dispatchPresentation(event);
            return true;
        }
        const feedback_index = self.state.findFeedback(event.object_id) orelse return false;
        try self.dispatchFeedback(feedback_index, event);
        return true;
    }

    pub fn prepare(self: *Presentation, id: u64) void {
        const state = self.state;
        std.debug.assert(state.transaction == null);
        state.transaction = .{ .id = id, .cause = .capacity };
        const index = state.storage.reserveFeedback() catch return;
        const clock_id = state.clock_id orelse {
            state.storage.cancelFeedbackReservation(index);
            state.transaction.?.cause = .clock;
            return;
        };
        const stamp = sampleClock(clock_id) catch {
            state.storage.cancelFeedbackReservation(index);
            state.transaction.?.cause = .clock;
            return;
        };
        const now = sys.time.awakeNow() catch {
            state.storage.cancelFeedbackReservation(index);
            state.transaction.?.cause = .clock;
            return;
        };
        state.storage.commitFeedback(index, .{
            .object_id = 0,
            .submission = .{ .id = id, .clock_id = clock_id.toNative(), .timestamp = stamp },
            .deadline = now.asNanoseconds() +| state.deadline_ns,
            .accepted = false,
        });
    }

    pub fn accept(self: *Presentation, id: u64) void {
        const state = self.state;
        std.debug.assert(state.transaction.?.id == id);
        if (state.storage.findSubmission(id)) |index| {
            state.storage.pending[index].accepted = true;
            if (state.storage.pending[index].failure) |cause| {
                state.storage.unknown(index, cause);
            }
        } else {
            state.storage.pushUnknown(id, state.transaction.?.cause);
        }
        state.transaction = null;
    }

    pub fn cancel(self: *Presentation, id: u64) void {
        const state = self.state;
        std.debug.assert(state.transaction.?.id == id);
        if (state.storage.findSubmission(id)) |index| {
            if (state.storage.pending[index].object_id == 0) {
                _ = state.storage.removeFeedback(index);
            } else {
                state.storage.pending[index].resolved = true;
                state.storage.pending[index].submission.id = 0;
            }
        }
        state.transaction = null;
    }

    pub fn submit(self: *Presentation, surface: u32, id: u64) void {
        const state = self.state;
        const index = state.storage.findSubmission(id) orelse return;
        const feedback = &state.storage.pending[index];
        if (feedback.resolved) return;
        std.debug.assert(feedback.object_id == 0);
        var created: [1]u32 = undefined;
        state.client.request(
            state.object_id,
            desktop.wp_presentation.requests.feedback.opcode,
            &.{ .{ .object = surface }, .{ .new_id = .fixed } },
            &created,
        ) catch {
            feedback.failure = .protocol;
            if (feedback.accepted) state.storage.unknown(index, .protocol);
            return;
        };
        feedback.object_id = created[0];
    }

    pub fn fail(self: *Presentation, id: u64) void {
        const index = self.state.storage.findSubmission(id) orelse return;
        self.state.storage.unknown(index, .protocol);
    }

    pub fn discard(self: *Presentation, id: u64) void {
        const index = self.state.storage.findSubmission(id) orelse return;
        const feedback = self.state.storage.pending[index];
        std.debug.assert(feedback.object_id == 0);
        self.state.storage.resolve(index, .{ .discarded = .{ .submission = feedback.submission } });
    }

    pub fn storageStatus(self: *const Presentation) windowing.presentation.StorageStatus {
        var status = self.state.storage.status;
        status.feedback_dropped_outcome_count = self.state.storage.outcomes.dropped;
        return status;
    }

    pub fn clockId(self: *const Presentation) ?sys.time.ExternalClockId {
        return self.state.clock_id;
    }

    pub fn pendingCount(self: *const Presentation) usize {
        return self.state.storage.pending_count;
    }

    pub fn outcomeCount(self: *const Presentation) usize {
        return self.state.storage.outcomes.len;
    }

    pub fn nextOutcome(self: *Presentation) ?Outcome {
        const now = sys.time.awakeNow() catch {
            self.state.storage.expire(std.math.maxInt(u64), .clock);
            return self.state.storage.outcomes.pop();
        };
        self.state.storage.expire(now.asNanoseconds(), .deadline);
        return self.state.storage.outcomes.pop();
    }

    pub fn droppedOutcomeCount(self: *const Presentation) u64 {
        return self.state.storage.outcomes.dropped;
    }

    pub fn takeCallbackError(self: *Presentation) ?CallbackError {
        const result = self.state.callback_error;
        self.state.callback_error = null;
        return result;
    }

    fn dispatchPresentation(self: *Presentation, event: *runtime.RoutedView) !void {
        if (event.metadata.opcode != desktop.wp_presentation.events.clock_id.opcode) {
            self.state.recordError(error.InvalidEvent);
            return;
        }
        var decoder = try event.borrowedDecoder();
        const clock_id = sys.time.ExternalClockId.fromNative(try decoder.unsigned());
        try decoder.finish();
        self.state.setClockId(clock_id);
    }

    fn dispatchFeedback(self: *Presentation, feedback_index: usize, event: *runtime.RoutedView) !void {
        const state = self.state;
        var decoder = try event.borrowedDecoder();
        switch (event.metadata.opcode) {
            desktop.wp_presentation_feedback.events.sync_output.opcode => {
                _ = try decoder.object();
                try decoder.finish();
                state.storage.pending[feedback_index].synchronized_outputs +|= 1;
            },
            desktop.wp_presentation_feedback.events.presented.opcode => {
                const seconds_high = try decoder.unsigned();
                const seconds_low = try decoder.unsigned();
                const nanoseconds = try decoder.unsigned();
                const refresh = try decoder.unsigned();
                const sequence_high = try decoder.unsigned();
                const sequence_low = try decoder.unsigned();
                const flags = try decoder.unsigned();
                try decoder.finish();
                const timestamp = timestampFromWire(seconds_high, seconds_low, nanoseconds) catch {
                    state.reject(feedback_index, error.InvalidTimestamp);
                    return;
                };
                const feedback = state.storage.pending[feedback_index];
                state.resolve(feedback_index, .{ .presented = .{
                    .submission = feedback.submission,
                    .timestamp = timestamp,
                    .refresh_nanoseconds = refresh,
                    .sequence = (@as(u64, sequence_high) << 32) | sequence_low,
                    .kind = @bitCast(flags),
                    .synchronized_outputs = feedback.synchronized_outputs,
                } });
            },
            desktop.wp_presentation_feedback.events.discarded.opcode => {
                try decoder.finish();
                const submission = state.storage.pending[feedback_index].submission;
                state.resolve(feedback_index, .{ .discarded = .{ .submission = submission } });
            },
            else => {
                self.state.recordError(error.InvalidEvent);
                return error.InvalidEvent;
            },
        }
    }
};

fn sampleClock(clock_id: sys.time.ExternalClockId) error{ClockUnavailable}!Timestamp {
    const nanoseconds = sys.time.externalClockNanoseconds(clock_id) catch
        return error.ClockUnavailable;
    const value = std.math.cast(u64, nanoseconds) orelse
        return error.ClockUnavailable;
    return Timestamp.fromNanoseconds(value);
}

const State = struct {
    allocator: std.mem.Allocator,
    client: *runtime.Client,
    object_id: u32,
    storage: Storage,
    clock_id: ?sys.time.ExternalClockId = null,
    callback_error: ?CallbackError = null,
    deadline_ns: u64 = std.time.ns_per_s,
    transaction: ?struct { id: u64, cause: windowing.presentation.UnknownCause } = null,

    fn setClockId(self: *State, clock_id: sys.time.ExternalClockId) void {
        if (self.clock_id != null) {
            self.recordError(error.DuplicateClockId);
            return;
        }
        self.clock_id = clock_id;
    }

    fn recordError(self: *State, failure: CallbackError) void {
        if (self.callback_error == null) self.callback_error = failure;
    }

    fn findFeedback(self: *const State, object_id: u32) ?usize {
        return self.storage.findFeedback(object_id);
    }

    fn reject(self: *State, feedback_index: usize, failure: CallbackError) void {
        self.recordError(failure);
        const feedback = self.storage.removeFeedback(feedback_index);
        if (!feedback.resolved and feedback.accepted) self.storage.pushUnknown(feedback.submission.id, .invalid);
    }

    fn resolve(self: *State, feedback_index: usize, outcome: Outcome) void {
        self.storage.resolve(feedback_index, outcome);
    }
};

const PendingFeedback = struct {
    object_id: u32,
    submission: Submission,
    synchronized_outputs: u32 = 0,
    deadline: u64 = std.math.maxInt(u64),
    accepted: bool = true,
    resolved: bool = false,
    failure: ?windowing.presentation.UnknownCause = null,
};

const Storage = struct {
    pending: []PendingFeedback,
    pending_count: usize = 0,
    feedback_reserved: bool = false,
    outcomes: OutcomeQueue,
    status: windowing.presentation.StorageStatus = .{},

    fn init(allocator: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Storage {
        const pending = try allocator.alloc(PendingFeedback, capacity.pending_feedback_count);
        errdefer allocator.free(pending);
        const outcomes = try allocator.alloc(Outcome, capacity.retained_outcome_count);
        return .{
            .pending = pending,
            .outcomes = OutcomeQueue.init(outcomes),
        };
    }

    fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        allocator.free(self.outcomes.items);
        allocator.free(self.pending);
        self.* = undefined;
    }

    fn reserveFeedback(self: *Storage) error{TooManyPending}!usize {
        if (self.feedback_reserved or self.pending_count == self.pending.len) return error.TooManyPending;
        self.feedback_reserved = true;
        return self.pending_count;
    }

    fn cancelFeedbackReservation(self: *Storage, index: usize) void {
        std.debug.assert(self.feedback_reserved);
        std.debug.assert(index == self.pending_count);
        self.feedback_reserved = false;
    }

    fn commitFeedback(self: *Storage, index: usize, feedback: PendingFeedback) void {
        std.debug.assert(self.feedback_reserved);
        std.debug.assert(index == self.pending_count);
        self.pending[index] = feedback;
        self.pending_count += 1;
        self.feedback_reserved = false;
    }

    fn findFeedback(self: *const Storage, object_id: u32) ?usize {
        for (self.pending[0..self.pending_count], 0..) |feedback, index| {
            if (object_id != 0 and feedback.object_id == object_id) return index;
        }
        return null;
    }

    fn removeFeedback(self: *Storage, index: usize) PendingFeedback {
        std.debug.assert(!self.feedback_reserved);
        std.debug.assert(index < self.pending_count);
        const removed = self.pending[index];
        self.pending_count -= 1;
        if (index != self.pending_count) self.pending[index] = self.pending[self.pending_count];
        return removed;
    }

    fn resolve(self: *Storage, index: usize, outcome: Outcome) void {
        const feedback = self.removeFeedback(index);
        if (!feedback.resolved and feedback.accepted) self.outcomes.push(outcome);
    }

    fn findSubmission(self: *const Storage, id: u64) ?usize {
        for (self.pending[0..self.pending_count], 0..) |feedback, index| {
            if (feedback.submission.id == id) return index;
        }
        return null;
    }

    fn pushUnknown(self: *Storage, id: u64, cause: windowing.presentation.UnknownCause) void {
        const counter = switch (cause) {
            .capacity => &self.status.feedback_capacity_unknown_count,
            .deadline => &self.status.feedback_deadline_unknown_count,
            .clock => &self.status.feedback_clock_unknown_count,
            .protocol => &self.status.feedback_protocol_unknown_count,
            .invalid => &self.status.feedback_invalid_unknown_count,
        };
        counter.* +|= 1;
        self.outcomes.push(.{ .unknown = .{
            .submission = .{ .id = id, .clock_id = 0, .timestamp = Timestamp.fromNanoseconds(0) },
            .cause = cause,
        } });
    }

    fn unknown(self: *Storage, index: usize, cause: windowing.presentation.UnknownCause) void {
        const feedback = &self.pending[index];
        if (feedback.resolved) return;
        std.debug.assert(feedback.accepted);
        self.pushUnknown(feedback.submission.id, cause);
        feedback.resolved = true;
        if (feedback.object_id == 0) _ = self.removeFeedback(index);
    }

    fn expire(self: *Storage, now: u64, cause: windowing.presentation.UnknownCause) void {
        var index = self.pending_count;
        while (index > 0) {
            index -= 1;
            const feedback = self.pending[index];
            if (!feedback.accepted or feedback.resolved) continue;
            if (now >= feedback.deadline) self.unknown(index, cause);
        }
    }
};

const OutcomeQueue = struct {
    items: []Outcome,
    head: usize = 0,
    len: usize = 0,
    dropped: u64 = 0,

    fn init(items: []Outcome) OutcomeQueue {
        std.debug.assert(items.len > 0);
        return .{ .items = items };
    }

    fn push(self: *OutcomeQueue, outcome: Outcome) void {
        if (self.len == self.items.len) {
            self.items[self.head] = outcome;
            self.head = (self.head + 1) % self.items.len;
            self.dropped = self.dropped +| 1;
            return;
        }
        const tail = (self.head + self.len) % self.items.len;
        self.items[tail] = outcome;
        self.len += 1;
    }

    fn pop(self: *OutcomeQueue) ?Outcome {
        if (self.len == 0) return null;
        const outcome = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        return outcome;
    }
};

fn timestampFromWire(seconds_high: u32, seconds_low: u32, nanoseconds: u32) windowing.presentation.TimestampError!Timestamp {
    const seconds = (@as(u64, seconds_high) << 32) | seconds_low;
    return Timestamp.init(seconds, nanoseconds);
}

test "presentation timestamps preserve wire precision" {
    const timestamp = try timestampFromWire(0x0123_4567, 0x89ab_cdef, 987_654_321);
    try std.testing.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), timestamp.seconds);
    try std.testing.expectEqual(@as(u32, 987_654_321), timestamp.nanoseconds);
    try std.testing.expectError(error.InvalidTimestamp, timestampFromWire(0, 0, std.time.ns_per_s));
}

test "presentation capacity derives exact default storage and rejects invalid limits" {
    const capacity = try Capacity.derive(.{});
    try std.testing.expectEqual(@as(usize, 256), capacity.pending_feedback_count);
    try std.testing.expectEqual(@as(usize, 512), capacity.retained_outcome_count);
    try std.testing.expectEqual(@sizeOf(State), capacity.state_bytes);
    try std.testing.expectEqual(256 * @sizeOf(PendingFeedback), capacity.pending_feedback_bytes);
    try std.testing.expectEqual(512 * @sizeOf(Outcome), capacity.retained_outcome_bytes);
    try std.testing.expectEqual(@as(usize, 3), capacity.swapchain.active_buffer_count);
    try std.testing.expectEqual(@as(usize, 3), capacity.swapchain.retired_buffer_count);
    try std.testing.expectEqual(
        capacity.swapchain.metadata_storage_bytes,
        capacity.swapchain_metadata_bytes,
    );
    try std.testing.expectEqual(
        capacity.state_bytes +
            capacity.pending_feedback_bytes +
            capacity.retained_outcome_bytes +
            capacity.swapchain_metadata_bytes +
            capacity.pending_frame_bytes,
        capacity.total_heap_bytes,
    );
    try std.testing.expectEqual(
        capacity.swapchain.buffer_slot_count * capacity.frames.retained_frame_byte_count,
        capacity.maximum_foreign_mapped_frame_bytes,
    );
    try std.testing.expectError(error.PendingFeedbackEmpty, Capacity.derive(.{
        .pending_feedback_count = 0,
    }));
    try std.testing.expectError(error.RetainedOutcomesEmpty, Capacity.derive(.{
        .retained_outcome_count = 0,
    }));
    try std.testing.expectError(error.ActiveBuffersEmpty, Capacity.derive(.{
        .active_buffer_count = 0,
    }));
    try std.testing.expectError(error.RetiredBuffersEmpty, Capacity.derive(.{
        .retired_buffer_count = 0,
    }));
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .pending_feedback_count = std.math.maxInt(usize) / @sizeOf(PendingFeedback) + 1,
    }));
    try std.testing.expectError(error.FrameStorageEmpty, Capacity.derive(.{
        .retained_frame_byte_count = 0,
    }));
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .retained_frame_byte_count = std.math.maxInt(usize) / 9 + 1,
    }));
}

test "presentation outcome retention stays bounded and keeps newest evidence" {
    var items: [3]Outcome = undefined;
    var queue = OutcomeQueue.init(&items);
    for (0..items.len + 3) |index| {
        queue.push(.{ .discarded = .{ .submission = .{
            .id = @intCast(index),
            .clock_id = 1,
            .timestamp = Timestamp.fromNanoseconds(@intCast(index)),
        } } });
    }
    try std.testing.expectEqual(items.len, queue.len);
    try std.testing.expectEqual(@as(u64, 3), queue.dropped);
    try std.testing.expectEqual(@as(u64, 3), queue.pop().?.submission().id);
}

test "presentation storage admits to its limit and allocates only during initialization" {
    const capacity = try Capacity.derive(.{
        .pending_feedback_count = 2,
        .retained_outcome_count = 4,
    });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    const allocator = failing.allocator();
    var storage = try Storage.init(allocator, capacity);
    defer storage.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), failing.allocations);

    const first = try storage.reserveFeedback();
    storage.commitFeedback(first, .{
        .object_id = 11,
        .submission = .{ .id = 1, .clock_id = 7, .timestamp = Timestamp.fromNanoseconds(10) },
    });
    const second = try storage.reserveFeedback();
    storage.commitFeedback(second, .{
        .object_id = 12,
        .submission = .{ .id = 2, .clock_id = 7, .timestamp = Timestamp.fromNanoseconds(20) },
    });
    try std.testing.expectError(error.TooManyPending, storage.reserveFeedback());
    try std.testing.expectEqual(@as(?usize, 0), storage.findFeedback(11));
    try std.testing.expectEqual(@as(?usize, 1), storage.findFeedback(12));

    storage.resolve(0, .{ .discarded = .{ .submission = .{
        .id = 1,
        .clock_id = 7,
        .timestamp = Timestamp.fromNanoseconds(10),
    } } });
    try std.testing.expectEqual(@as(usize, 1), storage.pending_count);
    try std.testing.expectEqual(@as(?usize, 0), storage.findFeedback(12));
    const cancelled = try storage.reserveFeedback();
    storage.cancelFeedbackReservation(cancelled);
    try std.testing.expectEqual(@as(usize, 1), storage.pending_count);
    const reused = try storage.reserveFeedback();
    storage.commitFeedback(reused, .{
        .object_id = 13,
        .submission = .{ .id = 3, .clock_id = 7, .timestamp = Timestamp.fromNanoseconds(30) },
    });

    storage.outcomes.push(.{ .discarded = .{ .submission = .{
        .id = 4,
        .clock_id = 7,
        .timestamp = Timestamp.fromNanoseconds(40),
    } } });
    storage.outcomes.push(.{ .discarded = .{ .submission = .{
        .id = 5,
        .clock_id = 7,
        .timestamp = Timestamp.fromNanoseconds(50),
    } } });
    try std.testing.expectEqual(@as(u64, 0), storage.outcomes.dropped);
    try std.testing.expectEqual(@as(u64, 1), storage.outcomes.pop().?.submission().id);
    try std.testing.expectEqual(@as(usize, 2), failing.allocations);
}

test "presentation samples the compositor-selected POSIX clock" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const realtime = try sampleClock(sys.time.real_clock_id);
    const monotonic = try sampleClock(sys.time.awake_clock_id);
    try std.testing.expect(realtime.seconds > monotonic.seconds);
    try std.testing.expectError(
        error.ClockUnavailable,
        sampleClock(.fromNative(std.math.maxInt(u32))),
    );
}

test "feedback drains every N accepts retain a delayed 2N burst and count one oldest drop beyond it" {
    const n = 4;
    const capacity = try Capacity.derive(.{ .pending_feedback_count = n, .retained_outcome_count = 2 * n });
    var storage = try Storage.init(std.testing.allocator, capacity);
    defer storage.deinit(std.testing.allocator);
    for (0..n) |index| {
        const slot = try storage.reserveFeedback();
        storage.commitFeedback(slot, .{
            .object_id = @intCast(index + 10),
            .submission = .{ .id = index + 1, .clock_id = 1, .timestamp = Timestamp.fromNanoseconds(1) },
        });
    }
    try std.testing.expect(storage.outcomes.pop() == null);
    for (0..n) |index| storage.pushUnknown(n + index + 1, .capacity);
    while (storage.pending_count > 0) {
        const item = storage.pending[0];
        storage.resolve(0, .{ .discarded = .{ .submission = item.submission } });
    }
    try std.testing.expectEqual(@as(usize, 2 * n), storage.outcomes.len);
    try std.testing.expectEqual(@as(u64, 0), storage.outcomes.dropped);
    var seen: [2 * n]bool = @splat(false);
    var copy = storage.outcomes;
    while (copy.pop()) |outcome| {
        const index = outcome.submission().id - 1;
        try std.testing.expect(!seen[index]);
        seen[index] = true;
    }
    for (seen) |value| try std.testing.expect(value);
    storage.pushUnknown(2 * n + 1, .capacity);
    try std.testing.expectEqual(@as(u64, 1), storage.outcomes.dropped);
    try std.testing.expectEqual(@as(u64, n + 2), storage.outcomes.pop().?.submission().id);
}

test "feedback deadlines leave bounded tombstones and late terminals never repeat an outcome" {
    const n = 4;
    const capacity = try Capacity.derive(.{ .pending_feedback_count = n, .retained_outcome_count = 2 * n });
    var storage = try Storage.init(std.testing.allocator, capacity);
    defer storage.deinit(std.testing.allocator);
    for (0..n) |index| {
        const slot = try storage.reserveFeedback();
        storage.commitFeedback(slot, .{
            .object_id = @intCast(index + 10),
            .submission = .{ .id = index + 1, .clock_id = 1, .timestamp = Timestamp.fromNanoseconds(1) },
            .deadline = 100,
        });
    }
    storage.expire(99, .deadline);
    try std.testing.expectEqual(@as(usize, 0), storage.outcomes.len);
    storage.expire(100, .deadline);
    storage.expire(101, .deadline);
    try std.testing.expectEqual(@as(usize, n), storage.pending_count);
    try std.testing.expectEqual(@as(u64, n), storage.status.feedback_deadline_unknown_count);
    var seen: [3 * n]bool = @splat(false);
    while (storage.outcomes.pop()) |outcome| {
        try std.testing.expect(outcome == .unknown);
        try std.testing.expectEqual(@as(u128, 0), outcome.submission().timestamp.totalNanoseconds());
        seen[outcome.submission().id - 1] = true;
    }
    for (n..3 * n) |index| {
        try std.testing.expectError(error.TooManyPending, storage.reserveFeedback());
        storage.pushUnknown(index + 1, .capacity);
        const outcome = storage.outcomes.pop().?;
        try std.testing.expect(!seen[outcome.submission().id - 1]);
        seen[outcome.submission().id - 1] = true;
    }
    while (storage.pending_count > 0) {
        const item = storage.pending[0];
        storage.resolve(0, .{ .discarded = .{ .submission = item.submission } });
    }
    try std.testing.expect(storage.outcomes.pop() == null);
    try std.testing.expectEqual(@as(u64, 0), storage.outcomes.dropped);
    for (seen) |value| try std.testing.expect(value);
    const recovered = try storage.reserveFeedback();
    storage.cancelFeedbackReservation(recovered);
}

test "feedback with no polling continues beyond three N and counts queue drops" {
    const capacity = try Capacity.derive(.{ .pending_feedback_count = 4, .retained_outcome_count = 8 });
    var storage = try Storage.init(std.testing.allocator, capacity);
    defer storage.deinit(std.testing.allocator);
    for (0..13) |index| storage.pushUnknown(index + 1, .capacity);
    try std.testing.expectEqual(@as(u64, 13), storage.status.feedback_capacity_unknown_count);
    try std.testing.expectEqual(@as(u64, 5), storage.outcomes.dropped);
    try std.testing.expectEqual(@as(usize, 8), storage.outcomes.len);
}
