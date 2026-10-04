const std = @import("std");
const ir = @import("../../core/root.zig");
const shared = @import("../root.zig").regalloc;
const control = @import("root.zig").control;
const GPR = @import("root.zig").GPR;

pub const max_registers: usize = 7;
pub const max_frame_slots: usize = 64;
pub const max_live_values: usize = max_registers + max_frame_slots;
pub const max_values: usize = 256;
pub const max_operations: usize = 1024;
pub const max_events: usize = 3 * max_operations;
pub const Event = struct {
    pub const Kind = enum { operation, next_region, end };
    kind: Kind,
    op: *ir.Operation,
    depth: usize,
};
pub const slot_bytes: usize = 8;
pub const registers = [max_registers]GPR{ .x9, .x10, .x11, .x12, .x13, .x14, .x15 };
/// Incoming x0-x7 and the seven placement registers are caller-saved. The
/// final two slots hold the Apple frame record (old x29, return address).
pub const call_save_slots: usize = 8 + max_registers;
pub const call_frame_slots: usize = call_save_slots + 2;

pub const Location = union(enum) { register: GPR, stack: u16, dead };
pub const Error = control.Error || error{ ValueCapacity, FrameCapacity, OperationCapacity, MissingValue };

const Entry = struct {
    value: *ir.Value,
    owner: *ir.Operation,
    retained: bool,
    range: shared.IntervalRange,
    location: Location = .dead,
    alloca_payload: ?u16 = null,
};

/// One immutable home per SSA result. Arguments retain their incoming homes.
pub const Plan = struct {
    entries: [max_values]Entry = undefined,
    count: usize = 0,
    events: [max_events]Event = undefined,
    event_count: usize = 0,
    loops: [max_operations]shared.LoopInterval = undefined,
    loop_count: usize = 0,
    frame_slots: usize = 0,
    call_save_base: ?u16 = null,
    entry_block: ?*ir.Block = null,
    refused_operation: ?*ir.Operation = null,

    pub fn storageBytes() usize {
        return @sizeOf(Plan);
    }

    pub fn frameBytes(self: *const Plan) usize {
        std.debug.assert(self.frame_slots <= max_frame_slots);
        return std.mem.alignForward(usize, self.frame_slots * slot_bytes, 16);
    }

    /// Reserve the fixed call frame inside the same 64-slot budget as spills.
    pub fn reserveCallFrame(self: *Plan, op: *ir.Operation) Error!void {
        if (self.call_save_base != null) return;
        self.refused_operation = op;
        if (self.frame_slots > max_frame_slots - call_frame_slots) return error.FrameCapacity;
        self.call_save_base = @intCast(self.frame_slots);
        self.frame_slots += call_frame_slots;
        self.refused_operation = null;
    }

    /// An alloca owns these slots for the whole invocation, even when its
    /// address dies. Spill homes may be reused, but payload storage may not.
    pub fn reserveAlloca(self: *Plan, op: *ir.Operation, result: *ir.Value, words: usize) Error!void {
        std.debug.assert(words > 0);
        self.refused_operation = op;
        if (words > max_frame_slots - self.frame_slots) return error.FrameCapacity;
        const entry = self.find(result) orelse return error.MissingValue;
        std.debug.assert(entry.owner == op and entry.alloca_payload == null);
        entry.alloca_payload = @intCast(self.frame_slots);
        self.frame_slots += words;
        self.refused_operation = null;
    }

    pub fn allocaPayload(self: *const Plan, result: *ir.Value) ?u16 {
        for (self.entries[0..self.count]) |entry| {
            if (entry.value == result) return entry.alloca_payload;
        }
        return null;
    }

    pub fn get(self: *const Plan, value: *ir.Value) ?Location {
        std.debug.assert(self.count <= max_values);
        for (self.entries[0..self.count]) |entry| {
            if (entry.value == value) return entry.location;
        }
        return null;
    }

    /// A fixed traversal stack linearizes regions without host recursion.
    /// Once loop boundaries exist, each actual source use reaches the shared
    /// loop extension through one borrowed record, without allocation.
    pub fn build(self: *Plan, block: *ir.Block) Error!void {
        self.* = .{ .entry_block = block };
        const Frame = struct { next: ?*ir.Operation, owner: ?*ir.Operation = null, region: usize = 0, entry: u32 = 0 };
        var frames: [control.max_depth + 1]Frame = undefined;
        frames[0] = .{ .next = first(block) };
        var depth: usize = 0;
        var operations: usize = 0;
        for (0..max_events) |_| {
            const frame = &frames[depth];
            if (frame.next) |op| {
                self.refused_operation = op;
                if (operations == max_operations) return error.OperationCapacity;
                operations += 1;
                frame.next = op.next_op;
                const position = self.appendEvent(.operation, op, depth);
                if (control.kind(op)) |construct| {
                    if (depth == control.max_depth) return error.DepthCapacity;
                    try control.validate(op, construct);
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

    fn appendEvent(self: *Plan, kind: Event.Kind, op: *ir.Operation, depth: usize) u32 {
        std.debug.assert(self.event_count < max_events);
        const position = self.event_count;
        self.events[position] = .{ .kind = kind, .op = op, .depth = depth };
        self.event_count += 1;
        return @intCast(position);
    }

    fn define(self: *Plan, value: *ir.Value, owner: *ir.Operation, position: u32, retained: bool) Error!void {
        if (self.count == max_values) return error.ValueCapacity;
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
        for (self.entries[0..self.count]) |*entry| {
            if (entry.value == value) return entry;
        }
        return null;
    }

    /// Shared interval expiration and register selection borrow stack storage.
    fn place(self: *Plan) Error!void {
        var active_storage: [max_registers]shared.Active(GPR) = undefined;
        var active: shared.ActiveSet(GPR) = .{
            .items = .initBuffer(&active_storage),
        };
        var stack_ends: [max_frame_slots]?shared.PositionPoint = @splat(null);
        for (self.entries[0..self.count], 0..) |*entry, index| {
            if (!entry.retained and entry.value.hasNoUses()) continue;
            self.refused_operation = entry.owner;
            const start = shared.PositionPoint.definition(entry.range.start);
            const end: shared.PositionPoint = .{ .position = entry.range.end, .phase = entry.range.end_phase };
            for (0..max_registers) |_| {
                if (active.takeExpiredBefore(start) == null) break;
            }
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
            var placed = false;
            for (&stack_ends, 0..) |*last, slot| {
                if (last.*) |point| if (!point.lessThan(start)) continue;
                last.* = end;
                entry.location = .{ .stack = @intCast(slot) };
                self.frame_slots = @max(self.frame_slots, slot + 1);
                placed = true;
                break;
            }
            if (!placed) return error.FrameCapacity;
        }
    }
};

const Policy = struct {
    pub fn blocksRegister(_: Policy, _: GPR) bool {
        return false;
    }
};
