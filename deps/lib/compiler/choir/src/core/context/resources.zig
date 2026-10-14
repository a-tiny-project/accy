const std = @import("std");
const Operation = @import("../root.zig").Operation;

pub const Tracker = struct {
    next_value_id: u32,
    next_operation_id: u31,
    operation_head: ?*Operation,
    operation_count: usize,

    pub fn init() Tracker {
        return .{
            .next_value_id = 0,
            .next_operation_id = 0,
            .operation_head = null,
            .operation_count = 0,
        };
    }

    pub fn deinit(self: *Tracker) void {
        var current = self.operation_head;
        var remaining = self.operation_count;
        while (remaining > 0) : (remaining -|= 1) {
            const op = current.?;
            op.dropAllReferences();
            current = op.tracking_next;
        }

        while (self.operation_head) |op| {
            std.debug.assert(op.hasNoUses());
            const removed = self.removeOperation(op);
            std.debug.assert(removed);
            op.destroy();
        }
        std.debug.assert(self.operation_count == 0);
    }

    /// Whether `expected` is on the list, found by walking it. The walk compares addresses and
    /// never reads `expected`, so it is exact for any address, at a cost in live operations.
    fn listsOperation(self: *const Tracker, expected: *const Operation) bool {
        var current = self.operation_head;
        for (0..self.operation_count) |_| {
            const op = current.?;
            if (op == expected) return true;
            current = op.tracking_next;
        }
        return false;
    }

    fn appendOperation(self: *Tracker, op: *Operation) void {
        std.debug.assert(op.tracking_prev == null);
        std.debug.assert(op.tracking_next == null);
        std.debug.assert(self.next_operation_id < std.math.maxInt(u31));
        std.debug.assert(self.operation_count < std.math.maxInt(usize));

        op.setCreationId(self.next_operation_id);
        self.next_operation_id = std.math.add(u31, self.next_operation_id, 1) catch unreachable;

        if (self.operation_head) |head| {
            const tail = head.tracking_prev.?;
            op.tracking_prev = tail;
            op.tracking_next = head;
            tail.tracking_next = op;
            head.tracking_prev = op;
        } else {
            op.tracking_prev = op;
            op.tracking_next = op;
            self.operation_head = op;
        }
        self.operation_count = std.math.add(usize, self.operation_count, 1) catch unreachable;
    }

    fn removeOperation(self: *Tracker, op: *Operation) bool {
        const previous = op.tracking_prev orelse {
            std.debug.assert(op.tracking_next == null);
            return false;
        };
        const next = op.tracking_next.?;
        std.debug.assert(self.operation_count > 0);

        if (previous == op) {
            std.debug.assert(next == op);
            std.debug.assert(self.operation_head == op);
            std.debug.assert(self.operation_count == 1);
            self.operation_head = null;
        } else {
            std.debug.assert(next != op);
            previous.tracking_next = next;
            next.tracking_prev = previous;
            if (self.operation_head == op) self.operation_head = next;
        }

        op.tracking_prev = null;
        op.tracking_next = null;
        self.operation_count = std.math.sub(usize, self.operation_count, 1) catch unreachable;
        return true;
    }
};

pub fn allocateValueId(ctx: anytype) u32 {
    const id = ctx.resources.next_value_id;
    std.debug.assert(id < std.math.maxInt(u32));
    ctx.resources.next_value_id = std.math.add(u32, id, 1) catch unreachable;
    return id;
}

pub fn operationCount(ctx: anytype) usize {
    return ctx.resources.operation_count;
}

pub fn operationCreationBoundary(ctx: anytype) u31 {
    return ctx.resources.next_operation_id;
}

pub fn eraseOperationsCreatedSince(ctx: anytype, boundary: u31) void {
    while (ctx.resources.operation_head) |head| {
        const operation = head.tracking_prev.?;
        if (operation.createdBefore(boundary)) return;
        operation.erase();
    }
}

comptime {
    // A released slot's first word becomes its pool's free link, which is not null once the
    // pool holds a second free slot, and an operation's header starts its slot. The link an
    // erased operation is read by must therefore sit past that word.
    std.debug.assert(@offsetOf(Operation, "tracking_prev") >= @sizeOf(?*anyopaque));
}

/// Whether `ctx` tracks `op`, read from the operation in constant time.
///
/// The tracker's list is circular, so every tracked operation, the head included, has a
/// previous one, and `removeOperation` clears the link. `trackOperation` links only an
/// operation whose context is `ctx`, so a linked operation of this context is on this list.
///
/// `op` must be storage that holds an operation's header, or held one that this context
/// erased and has been reused only as a header since. Pool slots meet that for the context's
/// lifetime: an erased slot keeps the link `removeOperation` cleared, or the bytes a safe
/// build fills it with, which are no context's address, and a reused slot answers for the
/// operation now in it. Storage outside the pools does not: the segment may hand its bytes to
/// an allocation of another shape, and this would read that allocation's contents. A caller
/// that keeps an address across erasures records `operationReleaseEpoch` with it, reads here
/// while the epoch stands, and asks `listsOperation` once it has moved. A caller that must
/// tell an operation from a later one in its storage compares creation boundaries.
pub fn containsOperation(ctx: anytype, op: *const Operation) bool {
    return op.tracking_prev != null and @intFromPtr(op.context) == @intFromPtr(ctx);
}

/// Whether `ctx` tracks an operation at `op`, found by walking the list. It reads nothing at
/// `op`, so it holds for an address whose storage has been released and reused.
pub fn listsOperation(ctx: anytype, op: *const Operation) bool {
    return ctx.resources.listsOperation(op);
}

pub fn trackOperation(ctx: anytype, op: *Operation) void {
    std.debug.assert(@intFromPtr(op.context) == @intFromPtr(ctx));
    ctx.resources.appendOperation(op);
}

pub fn untrackOperation(ctx: anytype, op: *Operation) void {
    if (@intFromPtr(op.context) != @intFromPtr(ctx)) return;
    _ = ctx.resources.removeOperation(op);
}

const FakeContext = struct {
    resources: Tracker = Tracker.init(),
};
