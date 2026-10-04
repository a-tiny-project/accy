const std = @import("std");
const alloc_phase = @import("alloc_phase");

const Allocator = std.mem.Allocator;

/// Every page the reserve hands out takes this size, and so fixes the unit its
/// whole memory bound is counted in: the number of bytes in one 128 KiB page of
/// the kind the debug allocator asks for, a *bucket page*. It is the standard
/// library's default on a target where no system page is larger.
pub const page_bytes = 128 * 1024;
pub const page_alignment: std.mem.Alignment = .fromByteUnits(page_bytes);

const word_bits = 64;
/// To record which pages are handed out, the reserve keeps an inline bitmap of
/// 64-bit words with one bit per page, its *occupancy words*. This constant
/// sets how many of those words the reserve keeps inline, so eight words of 64
/// bits put the ceiling at 512 pages.
const words_max = 8;
pub const pages_max = words_max * word_bits;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(page_bytes));
}

pub const ReserveLimits = struct {
    pages: u16,
};

pub const ReserveCapacity = struct {
    pages: u16,
    words: u8,
    storage_bytes: usize,

    pub const DeriveError = error{InvalidLimit};

    pub fn derive(limits: ReserveLimits) DeriveError!ReserveCapacity {
        if (limits.pages == 0) return error.InvalidLimit;
        if (limits.pages > pages_max) return error.InvalidLimit;
        const words = (limits.pages + word_bits - 1) / word_bits;
        std.debug.assert(words <= words_max);
        return .{
            .pages = limits.pages,
            .words = @intCast(words),
            .storage_bytes = @as(usize, limits.pages) * page_bytes,
        };
    }
};

pub const Reserve = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: Capacity,
    region: []align(page_bytes) u8,
    occupied: [words_max]u64,
    held: u16,

    pub const Limits: type = ReserveLimits;
    pub const Capacity: type = ReserveCapacity;
    pub const Exhaustion = error{PageReserveFull};
    pub const InitError = Allocator.Error || Capacity.DeriveError;

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "alloc.page_reserve",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{.{
                    .id = "retained_pages",
                    .lifetime = .steady,
                    .detail = "one page-aligned region whose released pages stay mapped for reuse",
                }},
                .excluded = &.{
                    "bucket slots and headers that the page holder writes inside held pages",
                    "requests other than one page at page alignment",
                    "page requests past a full reserve",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "pages", "pages"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{
                        .node = 0,
                        .coefficient = .{ .literal = 131072 },
                    } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 1,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "a full reserve rejects acquire before any occupancy change",
            },
            .risks = .{
                .transitive = .{
                    .status = .excluded,
                    .detail = "acquire and release take no allocator and touch no other owner",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "page contents belong to the holder of the page",
                },
            },
            .obligations = &.{
                .{ .key = "page_reserve_capacity", .role = .capacity_model },
                .{ .key = "page_reserve_exhaustion", .role = .overload },
                .{ .key = "page_reserve_reuse", .role = .acquisition },
                .{ .key = "page_reserve_oom", .role = .initialization_failure },
                .{ .key = "page_reserve_teardown", .role = .teardown },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    pub fn init(allocator: Allocator, limits: Limits) InitError!Reserve {
        const capacity = try Capacity.derive(limits);
        const region = try allocator.alignedAlloc(
            u8,
            page_alignment,
            capacity.storage_bytes,
        );
        var occupied: [words_max]u64 = @splat(0);
        const tail: u6 = @intCast(capacity.pages % word_bits);
        if (tail != 0) occupied[capacity.words - 1] = ~@as(u64, 0) << tail;
        return .{
            .phase = .initialization,
            .capacity = capacity,
            .region = region,
            .occupied = occupied,
            .held = 0,
        };
    }

    pub fn activate(self: *Reserve) void {
        std.debug.assert(self.phase == .initialization);
        std.debug.assert(self.region.len == self.capacity.storage_bytes);
        std.debug.assert(self.held == 0);
        self.phase = .steady;
    }

    pub fn acquire(self: *Reserve) Exhaustion![]align(page_bytes) u8 {
        std.debug.assert(self.phase == .steady);
        std.debug.assert(self.held <= self.capacity.pages);
        for (self.occupied[0..self.capacity.words], 0..) |*word, index| {
            if (word.* == ~@as(u64, 0)) continue;
            const bit: u6 = @intCast(@ctz(~word.*));
            const page = index * word_bits + bit;
            std.debug.assert(page < self.capacity.pages);
            word.* |= @as(u64, 1) << bit;
            self.held += 1;
            const bytes: []u8 = self.region[page * page_bytes ..][0..page_bytes];
            return @alignCast(bytes);
        }
        std.debug.assert(self.held == self.capacity.pages);
        return error.PageReserveFull;
    }

    pub fn owns(self: *const Reserve, memory: []const u8) bool {
        std.debug.assert(self.phase == .steady);
        const base = @intFromPtr(self.region.ptr);
        const address = @intFromPtr(memory.ptr);
        return address >= base and address - base < self.region.len;
    }

    pub fn release(self: *Reserve, page: []u8) void {
        std.debug.assert(self.owns(page));
        std.debug.assert(page.len == page_bytes);
        const offset = @intFromPtr(page.ptr) - @intFromPtr(self.region.ptr);
        std.debug.assert(offset % page_bytes == 0);
        const index = offset / page_bytes;
        const mask = @as(u64, 1) << @as(u6, @intCast(index % word_bits));
        const word = &self.occupied[index / word_bits];
        std.debug.assert(word.* & mask != 0);
        std.debug.assert(self.held > 0);
        word.* &= ~mask;
        self.held -= 1;
    }

    pub fn deinit(self: *Reserve, allocator: Allocator) void {
        std.debug.assert(self.phase != .teardown);
        std.debug.assert(self.held == 0);
        std.debug.assert(self.region.len == self.capacity.storage_bytes);
        self.phase = .teardown;
        allocator.free(self.region);
        self.region = &.{};
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorRejectingOwnerShape(Reserve);
}

fn expectPage(reserve: *const Reserve, page: []const u8, index: usize) !void {
    try std.testing.expectEqual(page_bytes, page.len);
    const base = @intFromPtr(reserve.region.ptr);
    try std.testing.expectEqual(base + index * page_bytes, @intFromPtr(page.ptr));
    try std.testing.expect(page_alignment.check(@intFromPtr(page.ptr)));
}

test "page reserve maps one aligned region of its pages" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(Reserve, "page_reserve_capacity"));
    }
    const scale = Reserve.claim.source.capacity.nodes[1].scale;
    try std.testing.expectEqual(page_bytes, scale.coefficient.literal);
    const derive = Reserve.Capacity.derive;
    try std.testing.expectError(error.InvalidLimit, derive(.{ .pages = 0 }));
    try std.testing.expectError(error.InvalidLimit, derive(.{ .pages = pages_max + 1 }));
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reserve = try Reserve.init(counting.allocator(), .{ .pages = 65 });
    defer reserve.deinit(counting.allocator());
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);
    try std.testing.expectEqual(65 * page_bytes, counting.allocated_bytes);
    reserve.activate();
    var pages: [65][]align(page_bytes) u8 = undefined;
    for (&pages, 0..) |*page, index| {
        page.* = try reserve.acquire();
        try expectPage(&reserve, page.*, index);
    }
    for (pages) |page| reserve.release(page);
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);
}

test "page reserve rejects a full acquire without changing occupancy" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Reserve, "page_reserve_exhaustion"),
        );
    }
    var reserve = try Reserve.init(std.testing.allocator, .{ .pages = 3 });
    defer reserve.deinit(std.testing.allocator);
    reserve.activate();
    const first = try reserve.acquire();
    const second = try reserve.acquire();
    const third = try reserve.acquire();
    const occupied = reserve.occupied;
    try std.testing.expectError(error.PageReserveFull, reserve.acquire());
    try std.testing.expectEqual(occupied, reserve.occupied);
    try std.testing.expectEqual(@as(u16, 3), reserve.held);
    reserve.release(second);
    try std.testing.expectEqual(second.ptr, (try reserve.acquire()).ptr);
    for ([_][]u8{ first, second, third }) |page| reserve.release(page);
}

test "page reserve reuses the lowest released page first" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(Reserve, "page_reserve_reuse"));
    }
    var reserve = try Reserve.init(std.testing.allocator, .{ .pages = 130 });
    defer reserve.deinit(std.testing.allocator);
    reserve.activate();
    var held: [2][]align(page_bytes) u8 = undefined;
    for (0..1000) |round| {
        for (&held) |*page| page.* = try reserve.acquire();
        try expectPage(&reserve, held[0], 0);
        try expectPage(&reserve, held[1], 1);
        reserve.release(held[round % 2]);
        reserve.release(held[1 - round % 2]);
    }
    try std.testing.expectEqual(@as(u16, 0), reserve.held);
    try std.testing.expectEqual(@as(u64, 0), reserve.occupied[0]);
    try std.testing.expectEqual(~@as(u64, 0) << 2, reserve.occupied[2]);
}

fn initAndTeardown(allocator: Allocator) !void {
    var reserve = try Reserve.init(allocator, .{ .pages = 2 });
    reserve.activate();
    reserve.deinit(allocator);
}

test "page reserve initialization fails without partial state" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(Reserve, "page_reserve_oom"));
    }
    const allocator = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(allocator, initAndTeardown, .{});
}

test "page reserve teardown frees its whole region" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(Reserve, "page_reserve_teardown"));
    }
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reserve = try Reserve.init(counting.allocator(), .{ .pages = 4 });
    reserve.activate();
    const page = try reserve.acquire();
    reserve.release(page);
    reserve.deinit(counting.allocator());
    try std.testing.expectEqual(alloc_phase.capacity.Phase.teardown, reserve.phase);
    try std.testing.expectEqual(@as(usize, 1), counting.deallocations);
    try std.testing.expectEqual(4 * page_bytes, counting.freed_bytes);
}
