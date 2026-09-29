const std = @import("std");

const closing_mask: u64 = 1 << 63;
const invocation_count_mask: u64 = closing_mask - 1;

pub const Gate = struct {
    next_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    state: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn reserve(self: *Gate) ?u64 {
        var state = self.state.load(.acquire);
        while (true) {
            if (state & closing_mask != 0 or state & invocation_count_mask == invocation_count_mask) return null;
            if (self.state.cmpxchgWeak(state, state + 1, .acq_rel, .acquire)) |observed| {
                state = observed;
                continue;
            }
            break;
        }
        return self.next_id.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Gate) void {
        const previous_state = self.state.fetchSub(1, .acq_rel);
        if (previous_state & invocation_count_mask == 0) @panic("released inactive composition invocation");
    }

    pub fn close(self: *Gate) void {
        const previous_state = self.state.fetchOr(closing_mask, .acq_rel);
        if (previous_state & invocation_count_mask != 0) @panic("composition destroyed with active invocations");
    }

    pub fn activeCount(self: *const Gate) u64 {
        return self.state.load(.acquire) & invocation_count_mask;
    }

    pub fn isClosing(self: *const Gate) bool {
        return self.state.load(.acquire) & closing_mask != 0;
    }
};
