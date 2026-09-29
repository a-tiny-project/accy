const std = @import("std");
const builtin = @import("builtin");
const deadalloc = @import("deadalloc");
const sys = @import("sys");
const diagnostics = @import("diagnostics.zig");
const page = @import("page/root.zig");
const policy = @import("policy.zig");
const process = @import("process.zig");

const Allocator = std.mem.Allocator;

pub const ProcessAllocatorFinish = union(enum) {
    clean,
    leak,
    diagnostics: deadalloc.Report,

    pub fn exitCode(self: ProcessAllocatorFinish) u8 {
        return switch (self) {
            .clean => 0,
            .leak, .diagnostics => 1,
        };
    }

    pub fn diagnosticReport(self: ProcessAllocatorFinish) ?deadalloc.Report {
        return switch (self) {
            .diagnostics => |report| report,
            .clean, .leak => null,
        };
    }
};

pub const ProcessAllocatorOwner = if (diagnostics.mode != null or process.mode != .off)
    DiagnosticProcessAllocatorOwner
else if (retainsPages(builtin.mode, builtin.is_test, std.heap.page_size_max))
    RetainingProcessAllocatorOwner
else
    DebugProcessAllocatorOwner;

fn retainsPages(mode: std.builtin.OptimizeMode, is_test: bool, page_size_max: usize) bool {
    if (is_test) return false;
    if (page_size_max > page.page_bytes) return false;
    return switch (mode) {
        .ReleaseFast, .ReleaseSmall => true,
        .Debug, .ReleaseSafe => false,
    };
}

/// The largest number of bucket pages live at one time, taken over every input
/// of the start harness, is the measurement the retained page count is derived
/// from. The measurement was traced on the baseline `chic` binary the
/// start-latency harness measures against, the *ruler*.
const measured_peak_pages = 298;
/// The count of bucket pages the process allocator keeps mapped for reuse, and
/// so the memory the process holds on to in a release build: it takes the
/// measured peak, adds a quarter of it again, and rounds up to the next
/// multiple of 8.
const retained_pages = std.mem.alignForward(u16, (measured_peak_pages * 5 + 3) / 4, 8);

const DebugProcessAllocatorOwner = struct {
    gpa: std.heap.DebugAllocator(.{}) = .{
        .backing_allocator = sys.memory.page_allocator,
    },

    pub fn init() @This() {
        return .{};
    }

    pub fn allocator(self: *@This()) Allocator {
        return self.gpa.allocator();
    }

    pub fn finish(self: *@This()) ProcessAllocatorFinish {
        return if (self.gpa.deinit() == .leak) .leak else .clean;
    }
};

const RetainingProcessAllocatorOwner = struct {
    gpa: std.heap.DebugAllocator(.{
        .backing_allocator_zeroes = false,
        .page_size = page.page_bytes,
    }) = .{},
    pages: page.Router = .init(sys.memory.page_allocator, .{ .pages = retained_pages }),

    pub fn init() @This() {
        return .{};
    }

    pub fn allocator(self: *@This()) Allocator {
        self.gpa.backing_allocator = self.pages.allocator();
        return self.gpa.allocator();
    }

    pub fn finish(self: *@This()) ProcessAllocatorFinish {
        const check = self.gpa.deinit();
        self.pages.finish();
        return if (check == .leak) .leak else .clean;
    }
};

const DiagnosticProcessAllocatorOwner = struct {
    pub fn init() @This() {
        return .{};
    }

    pub fn allocator(_: *@This()) Allocator {
        return policy.standaloneProcessAllocator();
    }

    pub fn finish(_: *@This()) ProcessAllocatorFinish {
        const report = diagnostics.report() orelse return .clean;
        return if (report.isClean()) .clean else .{ .diagnostics = report };
    }
};

test "process allocator owner retains pages only in release builds outside tests on small pages" {
    const small = 4 * 1024;
    try std.testing.expect(retainsPages(.ReleaseFast, false, small));
    try std.testing.expect(retainsPages(.ReleaseSmall, false, page.page_bytes));
    try std.testing.expect(!retainsPages(.Debug, false, small));
    try std.testing.expect(!retainsPages(.ReleaseSafe, false, small));
    try std.testing.expect(!retainsPages(.ReleaseSmall, true, small));
    try std.testing.expect(!retainsPages(.ReleaseSmall, false, 2 * page.page_bytes));
}

test "retained page count is the smallest multiple of 8 at or above 1.25 times the peak" {
    try std.testing.expectEqual(@as(u16, 0), retained_pages % 8);
    try std.testing.expect(@as(u32, retained_pages) * 4 >= measured_peak_pages * 5);
    try std.testing.expect(@as(u32, retained_pages - 8) * 4 < measured_peak_pages * 5);
}

test "retaining process allocator owner reuses bucket pages and finishes clean" {
    var owner = RetainingProcessAllocatorOwner.init();
    const allocator = owner.allocator();
    for (0..64) |_| {
        const objects = try allocator.alloc(*[4096]u8, 256);
        for (objects) |*object| object.* = try allocator.create([4096]u8);
        try std.testing.expectEqual(@as(u64, 0), owner.pages.reserve.occupied[1]);
        for (objects) |object| allocator.destroy(object);
        allocator.free(objects);
    }
    try std.testing.expectEqual(page.Router.State.active, owner.pages.state);
    try std.testing.expectEqual(@as(u16, 0), owner.pages.reserve.held);
    try std.testing.expectEqual(ProcessAllocatorFinish.clean, owner.finish());
}
