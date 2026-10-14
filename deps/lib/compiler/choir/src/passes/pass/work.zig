const std = @import("std");
const ir = @import("../../core/root.zig");
const revision = @import("../../product/revision/root.zig");

/// Structural and byte counts read without allocation before producer admission.
pub const Census = struct {
    operations: u64 = 0,
    values: u64 = 0,
    operands: u64 = 0,
    atoms: u64 = 0,
    input_bytes: u64 = 0,

    pub fn inspect(op: *ir.Operation) !Census {
        var counts: Census = .{};
        _ = try op.walk(.{ .order = .pre_order }, &counts, visit);
        return counts;
    }

    fn visit(self: *Census, op: *ir.Operation) !ir.Operation.WalkResult {
        self.operations = try add(self.operations, 1);
        self.operands = try add(self.operands, op.getOperandValues().len);
        self.atoms = try add(self.atoms, try add(1, op.getOperandValues().len));
        self.input_bytes = try add(self.input_bytes, op.name.name.len);
        for (op.results.items) |*result| try self.value(result);
        for (op.getOperandValues()) |operand| try self.typeBytes(operand.type);
        var attrs = op.getAttrs();
        while (attrs.next()) |attr| {
            self.atoms = try add(self.atoms, 1);
            self.input_bytes = try add(self.input_bytes, attr.name.len);
            if (attr.value.cast(ir.Attribute.DialectAttr)) |dialect| {
                self.input_bytes = try add(self.input_bytes, dialect.payload.len);
            } else if (attr.value.cast(ir.Attribute.StringAttr)) |string| {
                self.input_bytes = try add(self.input_bytes, string.getValue().len);
            }
        }
        for (op.regions.items) |*region| {
            self.atoms = try add(self.atoms, 1);
            var blocks = region.getBlocks();
            while (blocks.next()) |block| {
                self.atoms = try add(self.atoms, 1);
                for (block.arguments.items) |arg| try self.value(arg);
            }
        }
        return .advance;
    }

    fn value(self: *Census, item: *ir.Value) !void {
        self.values = try add(self.values, 1);
        self.atoms = try add(self.atoms, 1);
        try self.typeBytes(item.type);
        var use = item.first_use;
        while (use) |edge| : (use = edge.next_use) self.atoms = try add(self.atoms, 1);
    }

    fn typeBytes(self: *Census, typ: ir.Type) !void {
        if (typ.getDialectTypeName()) |name| {
            self.input_bytes = try add(self.input_bytes, name.len);
        }
        if (typ.getDialectParamKey()) |key| {
            self.input_bytes = try add(self.input_bytes, key.len);
        }
    }
};

pub const Phase = enum { pass, analysis };

/// Borrowed failure observations for independently bounded producer storage owners.
pub const AllocationFailure = struct {
    workspace: ?*const bool = null,
    context: ?*const ir.Context = null,

    pub fn exhausted(self: AllocationFailure) bool {
        if (self.workspace) |failed| {
            if (failed.*) return true;
        }
        if (self.context) |context| return context.exhaustedSegment() != null;
        return false;
    }

    pub fn classify(self: AllocationFailure, err: anyerror) anyerror {
        return if (self.exhausted()) error.WorkExhausted else err;
    }
};

pub const Input = struct {
    operation: *ir.Operation,
    state: ?*const anyopaque = null,
    options: ir.ThreadingOptions = .{},
};

pub const Bounds = struct {
    work: revision.WorkVector,
    workspace: u64 = 0,
    retained_storage: u64 = 0,
};

/// Estimation reads declared inputs without mutation or allocation. It includes
/// the producer's deterministic traversal, options and scheduling bounds.
pub const Contract = struct {
    identity: revision.record.Version,
    estimate: *const fn (Input) anyerror!Bounds,
};

/// A missing declaration permits transient work but revokes publication authority.
pub fn begin(
    accounting: ?*revision.AccountingV1,
    phase: Phase,
    contract: ?Contract,
    input: Input,
) !?u32 {
    const ledger = accounting orelse return null;
    if (ledger.view().outcome != .running) return error.TerminalWorkOutcome;
    const declared = contract orelse {
        ledger.missingContract();
        return null;
    };
    const bounds = declared.estimate(input) catch |err| {
        if (err == error.MissingWorkContract) ledger.missingContract();
        ledger.fail(if (err == error.WorkOverflow or err == error.WorkExhausted)
            .exhausted
        else
            .rejected);
        return err;
    };
    if (phase == .analysis and bounds.work.analysis_computations != 1) {
        ledger.missingContract();
        ledger.fail(.rejected);
        return error.MissingWorkContract;
    }
    return try ledger.begin(switch (phase) {
        .pass => .pass,
        .analysis => .analysis,
    }, .{
        .identity = declared.identity,
        .work = bounds.work,
        .workspace = bounds.workspace,
        .retained_storage = bounds.retained_storage,
    });
}

pub fn add(left: u64, right: u64) error{WorkOverflow}!u64 {
    return std.math.add(u64, left, right) catch return error.WorkOverflow;
}

pub fn multiply(left: u64, right: u64) error{WorkOverflow}!u64 {
    return std.math.mul(u64, left, right) catch return error.WorkOverflow;
}

/// Capacity for a default-load-factor std.HashMap on the pinned toolchain.
pub fn hashMapCapacity(entries: u64) !u64 {
    if (entries == 0) return 0;
    const needed = try add(try multiply(entries, 100) / 80, 1);
    if (needed > std.math.maxInt(u32)) return error.WorkOverflow;
    const capacity = std.math.ceilPowerOfTwo(u32, @intCast(needed)) catch
        return error.WorkOverflow;
    if (capacity > std.math.maxInt(u32) / 80) return error.WorkOverflow;
    return @max(8, capacity);
}

/// Conservative cumulative allocation traffic, including old tables and alignment.
pub fn hashMapGrowth(comptime Key: type, comptime Value: type, entries: u64) !u64 {
    const alignment = @max(@alignOf(usize), @alignOf(Key), @alignOf(Value));
    const slot = 1 + @sizeOf(Key) + @sizeOf(Value);
    const overhead = 4 * @sizeOf(usize) + 3 * alignment;
    return multiply(try multiply(2, try hashMapCapacity(entries)), slot + overhead);
}

/// Conservative cumulative std.ArrayList traffic, including geometric growth.
pub fn arrayListGrowth(comptime Item: type, entries: u64) !u64 {
    if (entries == 0) return 0;
    const capacity = try add(try multiply(4, entries), 64);
    return multiply(try multiply(4, capacity), @sizeOf(Item) + @alignOf(Item));
}

fn checkContainerGrowth(comptime Value: type, count: usize, comptime map_case: bool) !void {
    const fixed = @import("alloc_fixed");
    const allowance = if (map_case)
        try hashMapGrowth(u64, Value, count)
    else
        try arrayListGrowth(Value, count);
    const bytes = try std.testing.allocator.alignedAlloc(u8, .@"64", @intCast(allowance));
    defer std.testing.allocator.free(bytes);
    var backing = fixed.Tracked.init(bytes);
    var retained = fixed.Monotonic.init(backing.allocator(), @max(1, bytes.len));
    var map = std.AutoHashMap(u64, Value).init(retained.allocator());
    defer map.deinit();
    var list: std.ArrayList(Value) = .empty;
    defer list.deinit(retained.allocator());
    for (0..count) |index| {
        if (map_case) {
            try map.put(@intCast(index), std.mem.zeroes(Value));
        } else {
            try list.append(retained.allocator(), std.mem.zeroes(Value));
        }
    }
    try std.testing.expectEqual(if (map_case) count else 0, map.count());
    try std.testing.expectEqual(if (map_case) 0 else count, list.items.len);
    try std.testing.expect(map.capacity() <= try hashMapCapacity(count));
    const used = if (retained.current) |*current| fixed.used(current) else 0;
    try std.testing.expect(used <= allowance);
    try std.testing.expect(!backing.exhausted);
}
