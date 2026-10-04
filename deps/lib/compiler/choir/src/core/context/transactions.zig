const std = @import("std");
const Operation = @import("../root.zig").Operation;
const interfaces = @import("../root.zig").interfaces;
const memory_ctx = @import("memory.zig");

const NameList = interfaces.InlineList([]const u8, 0);

pub const DialectLoadTransaction = struct {
    dialect_name: []const u8,
    created_dialect_object: bool,
    attr_next_id_snapshot: u32,
    created_ops: NameList,
    created_types: NameList,
    created_attrs: NameList,
    record_storage: [][]const u8,

    pub fn init(dialect_name: []const u8, attr_next_id_snapshot: u32) DialectLoadTransaction {
        return .{
            .dialect_name = dialect_name,
            .created_dialect_object = false,
            .attr_next_id_snapshot = attr_next_id_snapshot,
            .created_ops = .{},
            .created_types = .{},
            .created_attrs = .{},
            .record_storage = &.{},
        };
    }

    pub fn deinit(self: *DialectLoadTransaction, allocator: std.mem.Allocator) void {
        self.created_ops.deinit(allocator);
        self.created_types.deinit(allocator);
        self.created_attrs.deinit(allocator);
        if (self.record_storage.len != 0) allocator.free(self.record_storage);
        self.* = undefined;
    }

    fn prepareRecordStorage(
        self: *DialectLoadTransaction,
        allocator: std.mem.Allocator,
        additional_operations: usize,
        additional_types: usize,
    ) std.mem.Allocator.Error!void {
        const operation_values = self.created_ops.values();
        const type_values = self.created_types.values();
        const operation_capacity = std.math.add(
            usize,
            operation_values.len,
            additional_operations,
        ) catch return error.OutOfMemory;
        const type_capacity = std.math.add(
            usize,
            type_values.len,
            additional_types,
        ) catch return error.OutOfMemory;
        const total_capacity = std.math.add(
            usize,
            operation_capacity,
            type_capacity,
        ) catch return error.OutOfMemory;
        if (total_capacity == 0) return;

        const replacement_storage = try allocator.alloc([]const u8, total_capacity);
        const replacement_operations = NameList.initBorrowedValues(
            replacement_storage[0..operation_capacity],
            operation_values,
        );
        const replacement_types = NameList.initBorrowedValues(
            replacement_storage[operation_capacity..],
            type_values,
        );

        self.created_ops.deinit(allocator);
        self.created_types.deinit(allocator);
        if (self.record_storage.len != 0) allocator.free(self.record_storage);
        self.created_ops = replacement_operations;
        self.created_types = replacement_types;
        self.record_storage = replacement_storage;
    }
};

pub fn deinitAll(ctx: anytype) void {
    for (ctx.dialect_load_transactions.items) |*txn| {
        txn.deinit(memory_ctx.segmentAllocator(ctx, .configuration_transactions));
    }
    ctx.dialect_load_transactions.deinit(memory_ctx.segmentAllocator(ctx, .configuration_transactions));
}

pub fn begin(ctx: anytype, dialect_name: []const u8) !usize {
    const snapshot = ctx.attr_interner.registry.nextAttributeId();
    try ctx.dialect_load_transactions.append(
        memory_ctx.segmentAllocator(ctx, .configuration_transactions),
        DialectLoadTransaction.init(dialect_name, snapshot),
    );
    return ctx.dialect_load_transactions.items.len - 1;
}

pub fn prepareRecordStorage(
    ctx: anytype,
    dialect_name: []const u8,
    operation_count: usize,
    type_count: usize,
) std.mem.Allocator.Error!void {
    if (find(ctx, dialect_name)) |txn| {
        try txn.prepareRecordStorage(memory_ctx.segmentAllocator(ctx, .configuration_transactions), operation_count, type_count);
    }
}

pub fn commit(ctx: anytype, txn_index: usize) void {
    std.debug.assert(txn_index + 1 == ctx.dialect_load_transactions.items.len);
    var txn = ctx.dialect_load_transactions.pop().?;
    txn.deinit(memory_ctx.segmentAllocator(ctx, .configuration_transactions));
}

pub fn rollback(ctx: anytype, txn_index: usize) void {
    std.debug.assert(txn_index + 1 == ctx.dialect_load_transactions.items.len);
    var txn = ctx.dialect_load_transactions.pop().?;

    const created_ops = txn.created_ops.values();
    var i_ops = created_ops.len;
    while (i_ops > 0) {
        i_ops -= 1;
        _ = ctx.dialect_registry.operation_registry.removeOperation(created_ops[i_ops]);
    }

    const created_types = txn.created_types.values();
    var i_types = created_types.len;
    while (i_types > 0) {
        i_types -= 1;
        _ = ctx.type_interner.registry.removeType(created_types[i_types]);
    }

    const created_attrs = txn.created_attrs.values();
    var i_attrs = created_attrs.len;
    while (i_attrs > 0) {
        i_attrs -= 1;
        _ = ctx.attr_interner.registry.removeAttribute(created_attrs[i_attrs]);
    }

    ctx.attr_interner.registry.restoreNextAttributeId(txn.attr_next_id_snapshot);

    if (txn.created_dialect_object) {
        if (ctx.dialect_registry.loaded.fetchRemove(txn.dialect_name)) |removed| {
            memory_ctx.segmentAllocator(ctx, .configuration_tables).destroy(removed.value);
        }
    }

    _ = ctx.dialect_registry.load_state.remove(txn.dialect_name);

    txn.deinit(memory_ctx.segmentAllocator(ctx, .configuration_transactions));
}

pub fn recordCreatedOperation(
    ctx: anytype,
    op_name: []const u8,
    created: bool,
) !void {
    if (!created) return;
    const ns = dialectNamespace(op_name);
    if (ns.len == 0) return;
    if (find(ctx, ns)) |txn| {
        try appendUniqueName(&txn.created_ops, memory_ctx.segmentAllocator(ctx, .configuration_transactions), op_name);
    }
}

pub fn recordCreatedType(
    ctx: anytype,
    type_name: []const u8,
    created: bool,
) !void {
    if (!created) return;
    const dotted_ns = dialectNamespace(type_name);
    const ns = if (dotted_ns.len > 0) dotted_ns else type_name;
    if (ns.len == 0) return;
    if (find(ctx, ns)) |txn| {
        try appendUniqueName(&txn.created_types, memory_ctx.segmentAllocator(ctx, .configuration_transactions), type_name);
    }
}

pub fn recordCreatedAttribute(
    ctx: anytype,
    attr_name: []const u8,
    created: bool,
) !void {
    if (!created) return;
    const ns = dialectNamespace(attr_name);
    if (ns.len == 0) return;
    if (find(ctx, ns)) |txn| {
        try appendUniqueName(&txn.created_attrs, memory_ctx.segmentAllocator(ctx, .configuration_transactions), attr_name);
    }
}

pub fn markDialectObjectCreated(ctx: anytype, dialect_name: []const u8) void {
    if (find(ctx, dialect_name)) |txn| {
        txn.created_dialect_object = true;
    }
}

fn find(
    ctx: anytype,
    dialect_ns: []const u8,
) ?*DialectLoadTransaction {
    var i = ctx.dialect_load_transactions.items.len;
    while (i > 0) {
        i -= 1;
        const txn = &ctx.dialect_load_transactions.items[i];
        if (std.mem.eql(u8, txn.dialect_name, dialect_ns)) return txn;
    }
    return null;
}

fn dialectNamespace(name: []const u8) []const u8 {
    const name_struct = Operation.OperationName.init(name);
    return name_struct.getDialectNamespace();
}

fn appendUniqueName(
    list: *NameList,
    allocator: std.mem.Allocator,
    name: []const u8,
) !void {
    for (list.values()) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try list.append(allocator, name);
}

test "dialect transaction record storage transfers exactly and spills transactionally" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});

    {
        var txn = DialectLoadTransaction.init("test", 0);
        defer txn.deinit(failing.allocator());

        const before = failing.alloc_index;
        const before_allocated = failing.allocated_bytes;
        try txn.prepareRecordStorage(failing.allocator(), 2, 1);
        try testing.expectEqual(before + 1, failing.alloc_index);
        try testing.expectEqual(
            before_allocated + 3 * @sizeOf([]const u8),
            failing.allocated_bytes,
        );

        try appendUniqueName(&txn.created_ops, failing.allocator(), "test.first");
        try appendUniqueName(&txn.created_ops, failing.allocator(), "test.second");
        try appendUniqueName(&txn.created_types, failing.allocator(), "test.type");
        try appendUniqueName(&txn.created_ops, failing.allocator(), "test.first");
        try testing.expectEqual(before + 1, failing.alloc_index);

        const storage_address = @intFromPtr(txn.record_storage.ptr);
        const before_overflow = failing.alloc_index;
        try testing.expectError(
            error.OutOfMemory,
            txn.prepareRecordStorage(failing.allocator(), std.math.maxInt(usize), 1),
        );
        try testing.expectEqual(before_overflow, failing.alloc_index);
        try testing.expectEqual(storage_address, @intFromPtr(txn.record_storage.ptr));

        failing.fail_index = failing.alloc_index;
        try testing.expectError(
            error.OutOfMemory,
            txn.prepareRecordStorage(failing.allocator(), 1, 1),
        );
        try testing.expectEqual(storage_address, @intFromPtr(txn.record_storage.ptr));
        try testing.expectEqual(@as(usize, 2), txn.created_ops.values().len);
        try testing.expectEqual(@as(usize, 1), txn.created_types.values().len);

        failing.fail_index = std.math.maxInt(usize);
        const before_transfer_freed = failing.freed_bytes;
        try txn.prepareRecordStorage(failing.allocator(), 1, 1);
        try testing.expectEqual(@as(usize, 5), txn.record_storage.len);
        try testing.expectEqual(
            before_transfer_freed + 3 * @sizeOf([]const u8),
            failing.freed_bytes,
        );
        try testing.expectEqualStrings("test.first", txn.created_ops.values()[0]);
        try testing.expectEqualStrings("test.second", txn.created_ops.values()[1]);
        try testing.expectEqualStrings("test.type", txn.created_types.values()[0]);

        try appendUniqueName(&txn.created_ops, failing.allocator(), "test.third");
        try appendUniqueName(&txn.created_types, failing.allocator(), "test.other_type");
        const before_spill = failing.alloc_index;
        failing.fail_index = before_spill;
        try testing.expectError(
            error.OutOfMemory,
            appendUniqueName(&txn.created_ops, failing.allocator(), "test.spill"),
        );
        try testing.expectEqual(@as(usize, 3), txn.created_ops.values().len);

        failing.fail_index = std.math.maxInt(usize);
        try appendUniqueName(&txn.created_ops, failing.allocator(), "test.spill");
        try testing.expectEqual(before_spill + 1, failing.alloc_index);
        try testing.expectEqual(@as(usize, 4), txn.created_ops.values().len);

        const before_attr = failing.alloc_index;
        try appendUniqueName(&txn.created_attrs, failing.allocator(), "test.attr");
        try testing.expectEqual(before_attr + 1, failing.alloc_index);
    }

    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}
