const std = @import("std");
const ir = @import("../../core/root.zig");
const shared = @import("../root.zig").regalloc;
const control = @import("root.zig").control;
const GPR = @import("root.zig").GPR;
const Excess = @import("../execution/bounds.zig").Excess;
const dialects = @import("../../dialects/root.zig");

pub const max_registers: usize = 7;
/// The 8-byte slots of one frame. RePPL's church programs use at most 124, so 510 leaves room
/// fourfold. The frame stays under one 4 KiB page, so entry moves sp past no guard page
/// unprobed, and its size fits the 12-bit immediate that adjusts sp.
pub const max_frame_slots: usize = 510;
pub const max_live_values: usize = max_registers + max_frame_slots;
/// The results and region arguments one function defines, as many as its operations. A function
/// of single-result operations meets the operation bound first; multi-result constructs and
/// region arguments can meet this one. Each value costs the plan `@sizeOf(Entry)` bytes.
pub const max_values: usize = max_operations;
/// The operations of one function. The largest of RePPL's church programs has 3,571, and the
/// next largest 534; 4,096 holds the largest with 15 percent to spare.
pub const max_operations: usize = 4096;
pub const max_events: usize = 3 * max_operations;
pub const Event = struct {
    pub const Kind = enum { operation, next_region, end };
    kind: Kind,
    op: *ir.Operation,
    depth: usize,
};
pub const slot_bytes: usize = 8;
/// The bytes the frame's slots hold: spills, alloca payloads, and the call frame share them.
pub const max_frame_bytes: usize = max_frame_slots * slot_bytes;
comptime {
    std.debug.assert(max_frame_bytes % 16 == 0);
    std.debug.assert(max_frame_bytes < 4096);
}
pub const registers = [max_registers]GPR{ .x9, .x10, .x11, .x12, .x13, .x14, .x15 };
/// Incoming x0-x7 and the seven placement registers are caller-saved. The
/// final two slots hold the Apple frame record (old x29, return address).
pub const call_save_slots: usize = 8 + max_registers;
pub const call_frame_slots: usize = call_save_slots + 2;

pub const Location = union(enum) { register: GPR, stack: u16, dead };

/// A vector value lives whole in the frame: two slots starting at an even slot, so its 16
/// bytes are 16-byte aligned. It never takes a register home.
pub const vector_slots: usize = 2;

pub fn isVector(value: *ir.Value) bool {
    const name = value.type.getDialectTypeName() orelse return false;
    return dialects.arith.parseVectorTypeName(name) != null;
}
pub const Error = control.Error || error{ ValueCapacity, FrameCapacity, OperationCapacity, MissingValue };

const Entry = struct {
    value: *ir.Value,
    owner: *ir.Operation,
    retained: bool,
    range: shared.IntervalRange,
    location: Location = .dead,
    alloca_payload: ?u16 = null,
};

/// Slots of the plan's value index: a power of two at least twice `max_values`, so the index is
/// at most half full and a probe always meets an empty slot.
pub const index_slots: usize = std.math.ceilPowerOfTwoAssert(usize, 2 * max_values);
const index_shift: u6 = @intCast(64 - @as(usize, std.math.log2_int(usize, index_slots)));

/// One slot of the value index. It names an entry only while its generation is the plan's, so
/// a new plan empties the index by moving its generation on rather than by clearing it.
const IndexSlot = struct {
    generation: u32 = 0,
    entry: u32 = 0,
};

/// Where `value` starts its probe: the high bits of its address times the golden ratio.
fn indexHome(value: *const ir.Value) usize {
    const address: u64 = @intFromPtr(value);
    return @intCast((address *% 0x9e37_79b9_7f4a_7c15) >> index_shift);
}

/// The frame bytes a plan holding `held` slots asks for when it takes `requested` more.
fn frameExcess(held: usize, requested: usize) Excess {
    return Excess.of(.frame_bytes, max_frame_bytes, held *| slot_bytes, requested *| slot_bytes).?;
}

/// One immutable home per SSA result. Arguments retain their incoming homes.
pub const Plan = struct {
    entries: [max_values]Entry = undefined,
    count: usize = 0,
    /// Each entry by its value, probed linearly from `indexHome`.
    index: [index_slots]IndexSlot = @splat(.{}),
    /// The generation of this plan's index slots, which each `reset` advances. Zero marks a slot
    /// no plan has filled, and a plan that has built nothing yet, so a fresh plan is all zeros.
    generation: u32 = 0,
    events: [max_events]Event = undefined,
    event_count: usize = 0,
    loops: [max_operations]shared.LoopInterval = undefined,
    loop_count: usize = 0,
    frame_slots: usize = 0,
    call_save_base: ?u16 = null,
    entry_block: ?*ir.Block = null,
    refused_operation: ?*ir.Operation = null,
    /// Whether values may take register homes, as the last `build` was asked. Off, every value
    /// lives in a frame slot, as a host that checks the placed code against frame-only code asks.
    place_values: bool = false,
    /// The bound the plan refused past, with its figures, set exactly when `build` or a frame
    /// reservation fails with a capacity error.
    excess: ?Excess = null,

    pub fn storageBytes() usize {
        return @sizeOf(Plan);
    }

    pub fn frameBytes(self: *const Plan) usize {
        std.debug.assert(self.frame_slots <= max_frame_slots);
        return std.mem.alignForward(usize, self.frame_slots * slot_bytes, 16);
    }

    /// Reserve the fixed call frame inside the same frame-slot budget as spills.
    pub fn reserveCallFrame(self: *Plan, op: *ir.Operation) Error!void {
        if (self.call_save_base != null) return;
        self.refused_operation = op;
        if (self.frame_slots > max_frame_slots - call_frame_slots) {
            self.excess = frameExcess(self.frame_slots, call_frame_slots);
            return error.FrameCapacity;
        }
        self.call_save_base = @intCast(self.frame_slots);
        self.frame_slots += call_frame_slots;
        self.refused_operation = null;
    }

    /// An alloca owns these slots for the whole invocation, even when its
    /// address dies. Spill homes may be reused, but payload storage may not.
    pub fn reserveAlloca(self: *Plan, op: *ir.Operation, result: *ir.Value, words: usize) Error!void {
        std.debug.assert(words > 0);
        self.refused_operation = op;
        if (words > max_frame_slots - self.frame_slots) {
            self.excess = frameExcess(self.frame_slots, words);
            return error.FrameCapacity;
        }
        const entry = self.find(result) orelse return error.MissingValue;
        std.debug.assert(entry.owner == op and entry.alloca_payload == null);
        entry.alloca_payload = @intCast(self.frame_slots);
        self.frame_slots += words;
        self.refused_operation = null;
    }

    pub fn allocaPayload(self: *const Plan, result: *ir.Value) ?u16 {
        const entry = self.lookup(result) orelse return null;
        return self.entries[entry].alloca_payload;
    }

    /// The values the plan homes in a register, each for its whole life.
    pub fn registerHomes(self: *const Plan) u32 {
        var homes: u32 = 0;
        for (self.entries[0..self.count]) |entry| {
            if (entry.location == .register) homes += 1;
        }
        return homes;
    }

    pub fn get(self: *const Plan, value: *ir.Value) ?Location {
        const entry = self.lookup(value) orelse return null;
        return self.entries[entry].location;
    }

    /// Empty the plan for `block`, keeping whether it places values. The index is emptied by
    /// moving its generation on, and cleared only when the generation wraps.
    pub fn reset(self: *Plan, block: ?*ir.Block) void {
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(&self.index, .{});
            self.generation = 1;
        }
        self.count = 0;
        self.event_count = 0;
        self.loop_count = 0;
        self.frame_slots = 0;
        self.call_save_base = null;
        self.entry_block = block;
        self.refused_operation = null;
        self.excess = null;
    }

    /// The entry of `value`, or null when the plan defines none.
    fn lookup(self: *const Plan, value: *const ir.Value) ?usize {
        std.debug.assert(self.generation != 0);
        std.debug.assert(2 * self.count <= index_slots);
        var slot = indexHome(value);
        for (0..index_slots) |_| {
            const found = self.index[slot];
            if (found.generation != self.generation) return null;
            if (self.entries[found.entry].value == value) return found.entry;
            slot = (slot + 1) & (index_slots - 1);
        }
        unreachable;
    }

    /// A fixed traversal stack linearizes regions without host recursion.
    /// Once loop boundaries exist, each actual source use reaches the shared
    /// loop extension through one borrowed record, without allocation.
    pub fn build(self: *Plan, block: *ir.Block, place_values: bool) Error!void {
        self.reset(block);
        self.place_values = place_values;
        const Frame = struct { next: ?*ir.Operation, owner: ?*ir.Operation = null, region: usize = 0, entry: u32 = 0 };
        var frames: [control.max_depth + 1]Frame = undefined;
        frames[0] = .{ .next = first(block) };
        var depth: usize = 0;
        const counted = countOperations(block);
        if (counted.total > max_operations) {
            self.refused_operation = counted.past;
            self.excess = Excess.of(.operations, max_operations, max_operations, counted.total - max_operations).?;
            return error.OperationCapacity;
        }
        var operations: usize = 0;
        for (0..max_events) |_| {
            const frame = &frames[depth];
            if (frame.next) |op| {
                self.refused_operation = op;
                std.debug.assert(operations < max_operations);
                operations += 1;
                frame.next = op.next_op;
                const position = self.appendEvent(.operation, op, depth);
                if (control.kind(op)) |construct| {
                    if (depth == control.max_depth) {
                        self.excess = Excess.of(.control_depth, control.max_depth, depth, 1).?;
                        return error.DepthCapacity;
                    }
                    control.validate(op, construct) catch |err| {
                        if (err == error.CarriedCapacity) self.excess = control.carriedExcess(op, construct);
                        return err;
                    };
                    for (op.results.items) |*value| try self.define(value, op, position, true);
                    for (op.regions.items) |*region| {
                        for (region.getEntryBlock().?.arguments.items) |arg| try self.define(arg, op, position, true);
                    }
                    depth += 1;
                    frames[depth] = .{ .next = first(op.regions.items[0].getEntryBlock().?), .owner = op, .entry = position + 1 };
                } else {
                    if (op.regions.items.len != 0) return error.ControlShape;
                    for (op.results.items) |*value| try self.define(value, op, position, false);
                }
            } else if (frame.owner) |owner| {
                self.refused_operation = owner;
                frame.region += 1;
                if (frame.region < owner.regions.items.len) {
                    _ = self.appendEvent(.next_region, owner, depth - 1);
                    frame.next = first(owner.regions.items[frame.region].getEntryBlock().?);
                } else {
                    const position = self.appendEvent(.end, owner, depth - 1);
                    if (control.kind(owner).? != .conditional) {
                        std.debug.assert(self.loop_count < max_operations);
                        self.loops[self.loop_count] = .{ .entry = frame.entry, .trailing = position };
                        self.loop_count += 1;
                    }
                    for (owner.results.items) |*value| try self.use(value, position);
                    for (owner.regions.items) |*region| {
                        for (region.getEntryBlock().?.arguments.items) |arg| try self.use(arg, position);
                    }
                    if (control.kind(owner).? == .counted) {
                        try self.use(owner.operands.items[1].value, position);
                        try self.use(owner.operands.items[2].value, position);
                    }
                    depth -= 1;
                }
            } else break;
        } else unreachable;
        for (self.events[0..self.event_count], 0..) |event, position| {
            if (event.kind != .operation) continue;
            self.refused_operation = event.op;
            for (event.op.operands.items) |operand| try self.use(operand.value, @intCast(position));
        }
        try self.place();
        self.refused_operation = null;
    }

    fn first(block: *ir.Block) ?*ir.Operation {
        return if (block.operations.head) |op| @ptrCast(@alignCast(op)) else null;
    }

    /// The operations `block` holds, nested ones included, walked as `build` walks them, and
    /// the first past `max_operations`. `build` refuses a function past the bound by this
    /// figure before it walks it, so the refusal says how large the function is, and no other
    /// bound of the walk speaks first. A construct nested deeper than `control.max_depth`
    /// counts as one, since `build` refuses it by depth.
    fn countOperations(block: *ir.Block) struct { total: usize, past: ?*ir.Operation } {
        const Frame = struct { next: ?*ir.Operation, owner: ?*ir.Operation = null, region: usize = 0 };
        var frames: [control.max_depth + 1]Frame = undefined;
        frames[0] = .{ .next = first(block) };
        var depth: usize = 0;
        var total: usize = 0;
        var past: ?*ir.Operation = null;
        while (true) {
            const frame = &frames[depth];
            if (frame.next) |op| {
                total += 1;
                if (total == max_operations + 1) past = op;
                frame.next = op.next_op;
                if (op.regions.items.len != 0 and depth < control.max_depth) {
                    depth += 1;
                    frames[depth] = .{ .next = regionFirst(op, 0), .owner = op };
                }
            } else if (frame.owner) |owner| {
                frame.region += 1;
                if (frame.region < owner.regions.items.len) {
                    frame.next = regionFirst(owner, frame.region);
                } else depth -= 1;
            } else return .{ .total = total, .past = past };
        }
    }

    fn regionFirst(op: *ir.Operation, region: usize) ?*ir.Operation {
        const block = op.regions.items[region].getEntryBlock() orelse return null;
        return first(block);
    }

    fn appendEvent(self: *Plan, kind: Event.Kind, op: *ir.Operation, depth: usize) u32 {
        std.debug.assert(self.event_count < max_events);
        const position = self.event_count;
        self.events[position] = .{ .kind = kind, .op = op, .depth = depth };
        self.event_count += 1;
        return @intCast(position);
    }

    fn define(self: *Plan, value: *ir.Value, owner: *ir.Operation, position: u32, retained: bool) Error!void {
        if (self.count == max_values) {
            self.excess = Excess.of(.values, max_values, self.count, 1).?;
            return error.ValueCapacity;
        }
        std.debug.assert(2 * (self.count + 1) <= index_slots);
        var slot = indexHome(value);
        for (0..index_slots) |_| {
            const found = &self.index[slot];
            if (found.generation != self.generation) {
                found.* = .{ .generation = self.generation, .entry = @intCast(self.count) };
                break;
            }
            std.debug.assert(self.entries[found.entry].value != value);
            slot = (slot + 1) & (index_slots - 1);
        } else unreachable;
        self.entries[self.count] = .{
            .value = value,
            .owner = owner,
            .retained = retained,
            .range = .{ .start = position, .end = position, .end_phase = .definition },
        };
        self.count += 1;
    }

    fn use(self: *Plan, value: *ir.Value, position: u32) Error!void {
        const entry = self.find(value) orelse {
            if (value.getOwnerBlock() == @as(*anyopaque, self.entry_block.?)) return;
            return error.MissingValue;
        };
        if (entry.range.start > position) return error.MissingValue;
        if (position >= entry.range.end) {
            entry.range.end = position;
            entry.range.end_phase = .source;
        }
        var use_storage = [_]shared.UsePosition(GPR, u32){.{ .point = shared.PositionPoint.source(position), .requirement = .any, .source_blockers = 0 }};
        var candidate = [_]shared.Candidate(GPR, u32){.{
            .value = value,
            .range = entry.range,
            .use_positions = .fromOwnedSlice(&use_storage),
            .definition = .{ .point = shared.PositionPoint.definition(entry.range.start), .requirement = .any, .source = .any },
            .order = 0,
            .is_constant = false,
        }};
        shared.extendAcrossLoops(GPR, u32, &candidate, self.loops[0..self.loop_count]);
        entry.range = candidate[0].range;
    }

    fn find(self: *Plan, value: *ir.Value) ?*Entry {
        const entry = self.lookup(value) orelse return null;
        return &self.entries[entry];
    }

    /// Shared interval expiration and register selection borrow stack storage.
    fn place(self: *Plan) Error!void {
        var active_storage: [max_registers]shared.Active(GPR) = undefined;
        var active: shared.ActiveSet(GPR) = .{
            .items = .initBuffer(&active_storage),
        };
        var spills: SpillSlots = .init;
        for (self.entries[0..self.count], 0..) |*entry, index| {
            if (!entry.retained and entry.value.hasNoUses()) continue;
            self.refused_operation = entry.owner;
            const start = shared.PositionPoint.definition(entry.range.start);
            const end: shared.PositionPoint = .{ .position = entry.range.end, .phase = entry.range.end_phase };
            if (index > 0) std.debug.assert(self.entries[index - 1].range.start <= entry.range.start);
            spills.release(start);
            if (isVector(entry.value)) {
                const slot = spills.takePair(end) orelse {
                    self.excess = frameExcess(self.frame_slots, vector_slots);
                    return error.FrameCapacity;
                };
                entry.location = .{ .stack = @intCast(slot) };
                self.frame_slots = @max(self.frame_slots, slot + vector_slots);
                continue;
            }
            for (0..max_registers) |_| {
                if (active.takeExpiredBefore(start) == null) break;
            }
            if (self.place_values) {
                if (shared.firstAvailableRegister(GPR, active, &registers, Policy{})) |register| {
                    std.debug.assert(active.items.items.len < max_registers);
                    active.items.appendAssumeCapacity(.{
                        .start = entry.range.start,
                        .end = entry.range.end,
                        .end_phase = entry.range.end_phase,
                        .reg = register,
                        .candidate_index = index,
                    });
                    entry.location = .{ .register = register };
                    continue;
                }
            }
            const slot = spills.take(end) orelse {
                self.excess = frameExcess(self.frame_slots, 1);
                return error.FrameCapacity;
            };
            entry.location = .{ .stack = @intCast(slot) };
            self.frame_slots = @max(self.frame_slots, slot + 1);
        }
    }
};

/// The frame slots spills take as `place` walks the entries in order of definition. A slot is
/// free again once the value in it has ended before the next definition starts. The lowest free
/// slot is taken, found by a count of trailing zeros, and a heap of the occupied slots ordered by
/// end frees them as the walk passes, so placing a value costs a word scan and a heap step.
const SpillSlots = struct {
    const words = (max_frame_slots + 63) / 64;
    const Occupied = struct { end: shared.PositionPoint, slot: u16 };
    const even_bits: u64 = 0x5555_5555_5555_5555;

    /// A set bit is a free slot.
    free: [words]u64,
    heap: [max_frame_slots]Occupied = undefined,
    heap_count: usize = 0,

    comptime {
        std.debug.assert(max_frame_slots % vector_slots == 0);
    }

    const init: SpillSlots = .{ .free = free: {
        var bits: [words]u64 = @splat(~@as(u64, 0));
        if (max_frame_slots % 64 != 0) bits[words - 1] = (@as(u64, 1) << (max_frame_slots % 64)) - 1;
        break :free bits;
    } };

    /// Free every slot whose value ended before `start`.
    fn release(self: *SpillSlots, start: shared.PositionPoint) void {
        while (self.heap_count > 0 and self.heap[0].end.lessThan(start)) {
            const slot = self.pop();
            std.debug.assert(self.free[slot / 64] & bit(slot) == 0);
            self.free[slot / 64] |= bit(slot);
        }
    }

    /// The lowest free slot, held until `end`, or null when every slot is held.
    fn take(self: *SpillSlots, end: shared.PositionPoint) ?usize {
        for (self.free, 0..) |word, index| {
            if (word == 0) continue;
            const slot = index * 64 + @ctz(word);
            self.occupy(slot, end);
            return slot;
        }
        return null;
    }

    /// The lowest even slot free with its successor, both held until `end`: a vector's 16
    /// aligned bytes. A pair never straddles two words, since a word holds an even count.
    fn takePair(self: *SpillSlots, end: shared.PositionPoint) ?usize {
        for (self.free, 0..) |word, index| {
            const pairs = word & (word >> 1) & even_bits;
            if (pairs == 0) continue;
            const slot = index * 64 + @ctz(pairs);
            self.occupy(slot, end);
            self.occupy(slot + 1, end);
            return slot;
        }
        return null;
    }

    fn bit(slot: usize) u64 {
        return @as(u64, 1) << @intCast(slot % 64);
    }

    fn occupy(self: *SpillSlots, slot: usize, end: shared.PositionPoint) void {
        std.debug.assert(self.free[slot / 64] & bit(slot) != 0);
        self.free[slot / 64] &= ~bit(slot);
        std.debug.assert(self.heap_count < max_frame_slots);
        var child = self.heap_count;
        self.heap[child] = .{ .end = end, .slot = @intCast(slot) };
        self.heap_count += 1;
        while (child > 0) {
            const parent = (child - 1) / 2;
            if (!self.heap[child].end.lessThan(self.heap[parent].end)) break;
            std.mem.swap(Occupied, &self.heap[child], &self.heap[parent]);
            child = parent;
        }
    }

    fn pop(self: *SpillSlots) usize {
        std.debug.assert(self.heap_count > 0);
        const top = self.heap[0].slot;
        self.heap_count -= 1;
        self.heap[0] = self.heap[self.heap_count];
        var parent: usize = 0;
        for (0..max_frame_slots) |_| {
            var least = parent;
            for ([_]usize{ 2 * parent + 1, 2 * parent + 2 }) |child| {
                if (child < self.heap_count and self.heap[child].end.lessThan(self.heap[least].end)) least = child;
            }
            if (least == parent) return top;
            std.mem.swap(Occupied, &self.heap[parent], &self.heap[least]);
            parent = least;
        }
        unreachable;
    }
};

const Policy = struct {
    pub fn blocksRegister(_: Policy, _: GPR) bool {
        return false;
    }
};
