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

/// Splits a parallel assignment by register file: every move that touches an XMM register goes to
/// `vector`, with every move that shares a place with one there, and the rest to `general`, so
/// the emitter can resolve each side with a scratch place of its own file.
///
/// A CYCLE OF REALS CAN RUN THROUGH FRAME SLOTS. A copy between two slots touches no XMM register,
/// and splitting by each move's own places once put it on the general side, which runs first, so
/// it overwrote a slot that an XMM move on the other side had yet to read. Moves that share no
/// place commute, so the sides may run one after the other exactly when none is shared across.
pub fn split(
    allocator: std.mem.Allocator,
    parallel: []const Move,
    general: *std.ArrayListUnmanaged(Move),
    vector: *std.ArrayListUnmanaged(Move),
) !void {
    std.debug.assert(general.items.len == 0);
    std.debug.assert(vector.items.len == 0);
    for (parallel) |move| {
        const side = if (placeIsXmm(move.src) or placeIsXmm(move.dst)) vector else general;
        try side.append(allocator, move);
    }
    // Every pass but the last carries a move across, so there are at most `parallel.len` + 1.
    for (0..parallel.len + 1) |_| {
        var carried = false;
        var index: usize = 0;
        while (index < general.items.len) {
            if (sharesPlace(general.items[index], vector.items)) {
                try vector.append(allocator, general.orderedRemove(index));
                carried = true;
            } else {
                index += 1;
            }
        }
        if (!carried) return;
    }
    unreachable;
}

fn sharesPlace(move: Move, others: []const Move) bool {
    for (others) |other| {
        if (samePlace(move.src, other.src) or samePlace(move.src, other.dst)) return true;
        if (samePlace(move.dst, other.src) or samePlace(move.dst, other.dst)) return true;
    }
    return false;
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

fn placeXmm(place: XMM) Place {
    return .{ .xmm = place };
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
