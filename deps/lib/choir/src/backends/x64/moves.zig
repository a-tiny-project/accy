const std = @import("std");
const registers = @import("registers/root.zig");
const slot_layout = @import("slots.zig");

const GPR = registers.GPR;
const XMM = registers.XMM;
const Slot = slot_layout.Slot;

pub const scratch_gprs = [_]GPR{ .rax, .rcx, .rdx, .r8, .r9, .r10, .r11 };
pub const stack_scratch_gpr = scratch_gprs[scratch_gprs.len - 1];

pub const Place = union(enum) {
    reg: GPR,
    xmm: XMM,
    slot: Slot,
};

pub const Move = struct {
    src: Place,
    dst: Place,
};

pub fn samePlace(a: Place, b: Place) bool {
    return switch (a) {
        .reg => |home| switch (b) {
            .reg => |other| home == other,
            .xmm, .slot => false,
        },
        .xmm => |home| switch (b) {
            .xmm => |other| home == other,
            .reg, .slot => false,
        },
        .slot => |stack_home| switch (b) {
            .reg, .xmm => false,
            .slot => |other| stack_home.offset == other.offset and stack_home.width == other.width,
        },
    };
}

pub fn usesReg(place: Place, target: GPR) bool {
    return switch (place) {
        .reg => |home| home == target,
        .xmm, .slot => false,
    };
}

pub fn placeIsXmm(place: Place) bool {
    return place == .xmm;
}

pub fn usesXmm(place: Place, target: XMM) bool {
    return switch (place) {
        .xmm => |home| home == target,
        .reg, .slot => false,
    };
}

pub fn resolve(
    allocator: std.mem.Allocator,
    parallel: []const Move,
    scratch: Place,
    resolved: *std.ArrayListUnmanaged(Move),
) !void {
    var pending: std.ArrayListUnmanaged(Move) = .empty;
    defer pending.deinit(allocator);

    for (parallel) |move| {
        if (samePlace(move.src, move.dst)) continue;
        if (samePlace(move.src, scratch) or samePlace(move.dst, scratch)) return error.InvalidParallelMove;
        var duplicate = false;
        for (pending.items) |existing| {
            if (samePlace(existing.dst, move.dst)) {
                if (!samePlace(existing.src, move.src)) return error.InvalidParallelMove;
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try pending.append(allocator, move);
    }

    while (pending.items.len != 0) {
        if (nextReadyMove(pending.items)) |index| {
            const move = pending.orderedRemove(index);
            try resolved.append(allocator, move);
            continue;
        }

        const saved = pending.items[0].src;
        try resolved.append(allocator, .{ .src = saved, .dst = scratch });
        for (pending.items) |*move| {
            if (samePlace(move.src, saved)) {
                move.src = scratch;
            }
        }
    }
}

fn nextReadyMove(pending: []const Move) ?usize {
    for (pending, 0..) |move, index| {
        if (!hasSource(pending, move.dst)) return index;
    }
    return null;
}

fn hasSource(pending: []const Move, place: Place) bool {
    for (pending) |move| {
        if (samePlace(move.src, place)) return true;
    }
    return false;
}

const Binding = struct {
    place: Place,
    value: i64,
};

fn placeReg(place: GPR) Place {
    return .{ .reg = place };
}

/// A 64 bit scratch place for the move machinery, which reads a location and
/// never reloads a value through it, so its form is never consulted.
fn placeSlot(offset: i32) Place {
    return .{ .slot = .{ .offset = offset, .width = 64, .ext = .unsigned } };
}

fn bindingFor(bindings: []Binding, place: Place) *i64 {
    for (bindings) |*binding| {
        if (samePlace(binding.place, place)) return &binding.value;
    }
    @panic("missing test binding");
}

fn execute(bindings: []Binding, sequence: []const Move) void {
    for (sequence) |move| {
        bindingFor(bindings, move.dst).* = bindingFor(bindings, move.src).*;
    }
}

test "parallel moves resolve register cycles with one scratch" {
    var resolved: std.ArrayListUnmanaged(Move) = .empty;
    defer resolved.deinit(std.testing.allocator);

    const parallel = [_]Move{
        .{ .src = placeReg(.rbx), .dst = placeReg(.r12) },
        .{ .src = placeReg(.r12), .dst = placeReg(.r13) },
        .{ .src = placeReg(.r13), .dst = placeReg(.rbx) },
    };
    try resolve(std.testing.allocator, &parallel, placeReg(.rax), &resolved);

    var bindings = [_]Binding{
        .{ .place = placeReg(.rbx), .value = 1 },
        .{ .place = placeReg(.r12), .value = 2 },
        .{ .place = placeReg(.r13), .value = 3 },
        .{ .place = placeReg(.rax), .value = 0 },
    };
    execute(&bindings, resolved.items);

    try std.testing.expectEqual(@as(i64, 3), bindingFor(&bindings, placeReg(.rbx)).*);
    try std.testing.expectEqual(@as(i64, 1), bindingFor(&bindings, placeReg(.r12)).*);
    try std.testing.expectEqual(@as(i64, 2), bindingFor(&bindings, placeReg(.r13)).*);
}

test "parallel moves keep fanout source values" {
    var resolved: std.ArrayListUnmanaged(Move) = .empty;
    defer resolved.deinit(std.testing.allocator);

    const parallel = [_]Move{
        .{ .src = placeReg(.rbx), .dst = placeReg(.r12) },
        .{ .src = placeReg(.rbx), .dst = placeReg(.r13) },
        .{ .src = placeReg(.r12), .dst = placeReg(.r14) },
    };
    try resolve(std.testing.allocator, &parallel, placeReg(.rax), &resolved);

    var bindings = [_]Binding{
        .{ .place = placeReg(.rbx), .value = 1 },
        .{ .place = placeReg(.r12), .value = 2 },
        .{ .place = placeReg(.r13), .value = 3 },
        .{ .place = placeReg(.r14), .value = 4 },
        .{ .place = placeReg(.rax), .value = 0 },
    };
    execute(&bindings, resolved.items);

    try std.testing.expectEqual(@as(i64, 1), bindingFor(&bindings, placeReg(.r12)).*);
    try std.testing.expectEqual(@as(i64, 1), bindingFor(&bindings, placeReg(.r13)).*);
    try std.testing.expectEqual(@as(i64, 2), bindingFor(&bindings, placeReg(.r14)).*);
}

test "parallel moves resolve stack cycles" {
    var resolved: std.ArrayListUnmanaged(Move) = .empty;
    defer resolved.deinit(std.testing.allocator);

    const parallel = [_]Move{
        .{ .src = placeSlot(-8), .dst = placeSlot(-16) },
        .{ .src = placeSlot(-16), .dst = placeSlot(-24) },
        .{ .src = placeSlot(-24), .dst = placeSlot(-8) },
    };
    try resolve(std.testing.allocator, &parallel, placeReg(.rax), &resolved);

    var bindings = [_]Binding{
        .{ .place = placeSlot(-8), .value = 1 },
        .{ .place = placeSlot(-16), .value = 2 },
        .{ .place = placeSlot(-24), .value = 3 },
        .{ .place = placeReg(.rax), .value = 0 },
    };
    execute(&bindings, resolved.items);

    try std.testing.expectEqual(@as(i64, 3), bindingFor(&bindings, placeSlot(-8)).*);
    try std.testing.expectEqual(@as(i64, 1), bindingFor(&bindings, placeSlot(-16)).*);
    try std.testing.expectEqual(@as(i64, 2), bindingFor(&bindings, placeSlot(-24)).*);
}

test "parallel moves match parallel semantics across small register maps" {
    const places = [_]Place{
        placeReg(.rbx),
        placeReg(.r12),
        placeReg(.r13),
        placeReg(.r14),
    };
    const scratch = placeReg(.rax);
    const radix = places.len + 1;
    var total: usize = 1;
    for (0..places.len) |_| {
        total *= radix;
    }

    var parallel: std.ArrayListUnmanaged(Move) = .empty;
    defer parallel.deinit(std.testing.allocator);
    var resolved: std.ArrayListUnmanaged(Move) = .empty;
    defer resolved.deinit(std.testing.allocator);

    var case_index: usize = 0;
    while (case_index < total) : (case_index += 1) {
        parallel.clearRetainingCapacity();
        resolved.clearRetainingCapacity();

        var choices: [places.len]usize = undefined;
        var encoded = case_index;
        for (&choices) |*choice| {
            choice.* = encoded % radix;
            encoded /= radix;
        }

        var expected = [_]i64{ 1, 2, 3, 4 };
        for (choices, 0..) |source_index, dest_index| {
            if (source_index < places.len) {
                try parallel.append(std.testing.allocator, .{
                    .src = places[source_index],
                    .dst = places[dest_index],
                });
                expected[dest_index] = @intCast(source_index + 1);
            }
        }

        try resolve(std.testing.allocator, parallel.items, scratch, &resolved);

        var bindings = [_]Binding{
            .{ .place = places[0], .value = 1 },
            .{ .place = places[1], .value = 2 },
            .{ .place = places[2], .value = 3 },
            .{ .place = places[3], .value = 4 },
            .{ .place = scratch, .value = 0 },
        };
        execute(&bindings, resolved.items);

        for (places, 0..) |place, i| {
            try std.testing.expectEqual(expected[i], bindingFor(&bindings, place).*);
        }
    }
}

test "parallel moves reject ambiguous destinations" {
    var resolved: std.ArrayListUnmanaged(Move) = .empty;
    defer resolved.deinit(std.testing.allocator);

    const parallel = [_]Move{
        .{ .src = placeReg(.rbx), .dst = placeReg(.r12) },
        .{ .src = placeReg(.r13), .dst = placeReg(.r12) },
    };

    try std.testing.expectError(error.InvalidParallelMove, resolve(std.testing.allocator, &parallel, placeReg(.rax), &resolved));
}
