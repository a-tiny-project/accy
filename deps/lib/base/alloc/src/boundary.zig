const std = @import("std");

const policy = @import("policy.zig");
const process = @import("process.zig");

pub const PhaseBoundaryState = struct {
    phase: Phase = .initialization,
    sealed: bool = false,

    pub const Phase = enum { initialization, steady, teardown };
};

pub const PhaseBoundary = struct {
    state: ?*PhaseBoundaryState = null,

    pub fn seal(self: PhaseBoundary) void {
        const state = self.state orelse return;
        std.debug.assert(state.phase == .initialization);
        policy.sealProcessAllocatorPhase();
        state.phase = .steady;
        state.sealed = true;
    }

    pub fn beginTeardown(self: PhaseBoundary) void {
        const state = self.state orelse return;
        if (state.phase != .steady) return;
        policy.beginProcessAllocatorTeardown();
        state.phase = .teardown;
    }

    pub fn sealed(self: PhaseBoundary) bool {
        const state = self.state orelse return false;
        return state.sealed;
    }
};

pub fn writePhaseReport(writer: *std.Io.Writer, tool: []const u8, was_sealed: bool) !bool {
    const violations = process.violations() orelse return false;
    try writer.print(
        "{s} allocator phase steady violations: sealed={} total={d} alloc={d} " ++
            "resize={d} remap={d} free={d}",
        .{
            tool,
            was_sealed,
            violations.total(),
            violations.allocations,
            violations.resizes,
            violations.remaps,
            violations.frees,
        },
    );
    if (process.violationSites()) |sites| {
        for (sites.slice()) |address| try writer.print(" site=0x{x}", .{address});
    }
    try writer.writeByte('\n');
    return true;
}
