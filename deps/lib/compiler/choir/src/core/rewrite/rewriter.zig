const std = @import("std");
const ir = @import("../root.zig");
const alloc_arena = @import("alloc_arena");
const RewritePattern = ir.rewrite.RewritePattern;
const PatternResult = ir.rewrite.PatternResult;
const TypeConverter = ir.rewrite.TypeConverter;

pub const PatternRewriteAttempt = struct {
    rewriter: *PatternRewriter,
    created_before: usize,
    guard: PatternRewriter.InsertionGuard,

    pub inline fn init(op: *ir.Operation, rewriter: *PatternRewriter) PatternRewriteAttempt {
        const attempt = PatternRewriteAttempt{
            .rewriter = rewriter,
            .created_before = rewriter.created_ops.items.len,
            .guard = rewriter.insertionGuard(),
        };
        rewriter.setInsertionPointBefore(op);
        return attempt;
    }

    pub inline fn finish(self: *PatternRewriteAttempt, result: PatternResult) bool {
        if (result == .failure and self.rewriter.created_ops.items.len != self.created_before) {
            self.rewriter.created_ops.items.len = self.created_before;
        }
        self.guard.deinit();
        self.* = undefined;
        return result == .success;
    }
};

pub inline fn tryApplyRewritePattern(
    pattern: *const RewritePattern,
    op: *ir.Operation,
    rewriter: *PatternRewriter,
) bool {
    if (!pattern.matchesAfterRoot(op)) return false;
    var attempt = PatternRewriteAttempt.init(op, rewriter);
    return attempt.finish(pattern.apply(op, rewriter));
}

fn rewrite_listener_target(comptime TargetPtr: type) type {
    return struct {
        fn notify_event(context: ?*anyopaque, event: PatternRewriter.RewriteEvent) void {
            const typed: TargetPtr = @ptrCast(@alignCast(context.?));
            typed.notifyRewriteEvent(event);
        }
    };
}

pub const PatternRewriter = struct {
    pub const ReplacementMode = enum {
        immediate,
        deferred,
    };

    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    type_converter: ?*const TypeConverter,
    replacement_mode: ReplacementMode,

    created_ops: std.ArrayListUnmanaged(*ir.Operation),

    ops_to_erase: std.ArrayListUnmanaged(*ir.Operation),

    replacements: std.AutoHashMap(*ir.Value, *ir.Value),

    builder: ir.OperationBuilder,

    listener: ?Listener,

    pub const InsertPoint: type = ir.OperationBuilder.InsertPoint;
    pub const InsertionGuard: type = ir.OperationBuilder.InsertionGuard;

    pub const OperationReplacement = struct {
        op: *ir.Operation,
        new_values: []const *ir.Value,
    };

    pub const DetachedOperation = struct {
        op: *ir.Operation,
        block: *ir.Block,
        next: ?*ir.Operation,
    };

    pub const RewriteEvent = union(enum) {
        modified: *ir.Operation,
        replaced: OperationReplacement,
        erased: *ir.Operation,
    };

    pub const Listener = struct {
        context: ?*anyopaque = null,
        notify_event: ?*const fn (?*anyopaque, RewriteEvent) void = null,

        pub fn bind(target: anytype) Listener {
            const TargetPtr = @TypeOf(target);
            comptime {
                const pointer_info = switch (@typeInfo(TargetPtr)) {
                    .pointer => |info| info,
                    else => @compileError("PatternRewriter.Listener.bind expects a mutable pointer"),
                };
                if (pointer_info.size != .one) {
                    @compileError("PatternRewriter.Listener.bind expects a single-item pointer");
                }
                if (pointer_info.attrs.@"const") {
                    @compileError("PatternRewriter.Listener.bind expects a mutable pointer");
                }
                if (!@hasDecl(pointer_info.child, "notifyRewriteEvent")) {
                    @compileError("PatternRewriter listener target must define notifyRewriteEvent");
                }
            }

            return .{
                .context = target,
                .notify_event = rewrite_listener_target(TargetPtr).notify_event,
            };
        }

        pub fn notify(self: Listener, event: RewriteEvent) void {
            if (self.notify_event) |notify_event| notify_event(self.context, event);
        }
    };

    pub fn init(allocator: std.mem.Allocator, ir_ctx: *ir.Context) PatternRewriter {
        return initWithMode(allocator, ir_ctx, .immediate);
    }

    pub fn initDeferred(allocator: std.mem.Allocator, ir_ctx: *ir.Context) PatternRewriter {
        return initWithMode(allocator, ir_ctx, .deferred);
    }

    fn initWithMode(
        allocator: std.mem.Allocator,
        ir_ctx: *ir.Context,
        replacement_mode: ReplacementMode,
    ) PatternRewriter {
        return .{
            .allocator = allocator,
            .ir_ctx = ir_ctx,
            .type_converter = null,
            .replacement_mode = replacement_mode,
            .created_ops = .empty,
            .ops_to_erase = .empty,
            .replacements = std.AutoHashMap(*ir.Value, *ir.Value).init(allocator),
            .builder = ir.OperationBuilder.init(ir_ctx),
            .listener = null,
        };
    }

    pub fn initWithTypeConverter(
        allocator: std.mem.Allocator,
        ir_ctx: *ir.Context,
        type_converter: ?*const TypeConverter,
    ) PatternRewriter {
        var rewriter = PatternRewriter.init(allocator, ir_ctx);
        rewriter.type_converter = type_converter;
        return rewriter;
    }

    pub fn deinit(self: *PatternRewriter) void {
        self.created_ops.deinit(self.allocator);
        self.ops_to_erase.deinit(self.allocator);
        self.replacements.deinit();
    }

    pub fn setTypeConverter(self: *PatternRewriter, type_converter: ?*const TypeConverter) void {
        self.type_converter = type_converter;
    }

    pub fn getTypeConverter(self: *const PatternRewriter) ?*const TypeConverter {
        return self.type_converter;
    }

    pub fn setListener(self: *PatternRewriter, listener: ?Listener) void {
        self.listener = listener;
    }

    pub fn getListener(self: *const PatternRewriter) ?Listener {
        return self.listener;
    }

    pub fn materializeConversion(self: *PatternRewriter, value: *ir.Value, target_type: ir.Type) ?*ir.Value {
        const converter = self.type_converter orelse return null;
        return converter.materialize(self, value, target_type);
    }

    pub fn clearInsertionPoint(self: *PatternRewriter) void {
        self.builder.clearInsertionPoint();
    }

    pub fn hasInsertionPoint(self: *const PatternRewriter) bool {
        return self.builder.hasInsertionPoint();
    }

    pub fn saveInsertionPoint(self: *const PatternRewriter) InsertPoint {
        return self.builder.saveInsertionPoint();
    }

    pub fn restoreInsertionPoint(self: *PatternRewriter, insert_point: InsertPoint) void {
        self.builder.restoreInsertionPoint(insert_point);
    }

    pub fn insertionGuard(self: *PatternRewriter) InsertionGuard {
        return self.builder.insertionGuard();
    }

    pub fn setInsertionPoint(self: *PatternRewriter, block: *ir.Block) void {
        self.builder.setInsertionPoint(block);
    }

    pub fn setInsertionPointBefore(self: *PatternRewriter, op: *ir.Operation) void {
        self.builder.setInsertionPointBefore(op);
    }

    pub fn setInsertionPointAfter(self: *PatternRewriter, op: *ir.Operation) void {
        self.builder.setInsertionPointAfter(op);
    }

    fn ensureBuilderListener(self: *PatternRewriter) void {
        self.builder.setListener(.{
            .context = self,
            .notify_operation_inserted = recordInsertedOperation,
        });
    }

    fn recordInsertedOperation(context: ?*anyopaque, op: *ir.Operation, previous: ir.OperationBuilder.InsertPoint) !void {
        _ = previous;
        const self: *PatternRewriter = @ptrCast(@alignCast(context.?));
        try self.created_ops.append(self.allocator, op);
    }

    pub fn insert(self: *PatternRewriter, op: *ir.Operation) !*ir.Operation {
        self.ensureBuilderListener();
        return try self.builder.insert(op);
    }

    pub fn create(self: *PatternRewriter, state: ir.Operation.State) !*ir.Operation {
        self.ensureBuilderListener();
        return try self.builder.create(state);
    }

    fn notifyRewriteEvent(self: *const PatternRewriter, event: RewriteEvent) void {
        if (self.listener) |listener| listener.notify(event);
    }

    fn replaceUsesImmediately(self: *PatternRewriter, old_value: *ir.Value, new_value: *ir.Value) void {
        if (old_value == new_value) return;
        var uses = old_value.useIterator();
        while (uses.next()) |operand| {
            operand.setValue(new_value);
            const owner: *ir.Operation = @ptrCast(@alignCast(operand.owner));
            self.notifyRewriteEvent(.{ .modified = owner });
        }
    }

    fn ensureReplacementCapacity(self: *PatternRewriter, count: usize) !void {
        if (self.replacement_mode == .deferred) {
            try self.replacements.ensureUnusedCapacity(@intCast(count));
        }
    }

    fn ensureEraseCapacity(self: *PatternRewriter) !void {
        try self.ops_to_erase.ensureUnusedCapacity(self.allocator, 1);
    }

    pub fn setOperandValue(self: *PatternRewriter, op: *ir.Operation, index: usize, new_value: *ir.Value) void {
        op.setOperandValue(index, new_value);
        self.notifyRewriteEvent(.{ .modified = op });
    }

    pub fn setAttr(self: *PatternRewriter, op: *ir.Operation, attr_name: []const u8, value: ir.Attribute) !void {
        try op.setAttr(attr_name, value);
        self.notifyRewriteEvent(.{ .modified = op });
    }

    pub fn replaceAllUsesWith(self: *PatternRewriter, old_value: *ir.Value, new_value: *ir.Value) !void {
        switch (self.replacement_mode) {
            .immediate => self.replaceUsesImmediately(old_value, new_value),
            .deferred => try self.replacements.put(old_value, new_value),
        }
    }

    pub fn replaceAllOpUsesWith(self: *PatternRewriter, op: *ir.Operation, new_values: []const *ir.Value) !void {
        if (new_values.len != op.getNumResults()) return error.ReplacementResultCountMismatch;
        try self.ensureReplacementCapacity(new_values.len);
        self.notifyRewriteEvent(.{ .replaced = .{ .op = op, .new_values = new_values } });
        switch (self.replacement_mode) {
            .immediate => for (op.results.items, new_values) |*result, new_value| {
                self.replaceUsesImmediately(result, new_value);
            },
            .deferred => for (op.results.items, new_values) |*result, new_value| {
                self.replacements.putAssumeCapacity(result, new_value);
            },
        }
    }

    pub fn replaceAllOpUsesWithOperation(self: *PatternRewriter, op: *ir.Operation, replacement: *ir.Operation) !void {
        const result_count = op.getNumResults();
        if (replacement.getNumResults() != result_count) return error.ReplacementResultCountMismatch;
        if (result_count == 0) {
            try self.replaceAllOpUsesWith(op, &.{});
            return;
        }
        if (result_count == 1) {
            const value = replacement.getResult(0) orelse return error.ReplacementResultCountMismatch;
            try self.replaceAllOpUsesWith(op, &.{value});
            return;
        }

        const values = try self.allocator.alloc(*ir.Value, result_count);
        defer self.allocator.free(values);
        for (values, 0..) |*value, index| {
            value.* = replacement.getResult(index) orelse return error.ReplacementResultCountMismatch;
        }

        try self.replaceAllOpUsesWith(op, values);
    }

    pub fn replaceOp(self: *PatternRewriter, op: *ir.Operation, new_values: []const *ir.Value) !void {
        if (new_values.len != op.getNumResults()) return error.ReplacementResultCountMismatch;
        try self.ensureEraseCapacity();
        try self.replaceAllOpUsesWith(op, new_values);
        self.ops_to_erase.appendAssumeCapacity(op);
    }

    pub fn replaceOpWithOperation(self: *PatternRewriter, op: *ir.Operation, replacement: *ir.Operation) !void {
        if (replacement.getNumResults() != op.getNumResults()) return error.ReplacementResultCountMismatch;
        try self.ensureEraseCapacity();
        try self.replaceAllOpUsesWithOperation(op, replacement);
        self.ops_to_erase.appendAssumeCapacity(op);
    }

    pub fn replaceOpWithNewOp(self: *PatternRewriter, op: *ir.Operation, state: ir.Operation.State) !*ir.Operation {
        const result_count = op.getNumResults();
        if (state.result_types.len != result_count) return error.ReplacementResultCountMismatch;
        try self.ensureEraseCapacity();
        try self.ensureReplacementCapacity(result_count);

        const new_op = try self.create(state);
        try self.replaceOpWithOperation(op, new_op);
        return new_op;
    }

    pub fn replaceOpWithValue(self: *PatternRewriter, op: *ir.Operation, new_value: *ir.Value) !void {
        try self.replaceOp(op, &.{new_value});
    }

    pub fn eraseOp(self: *PatternRewriter, op: *ir.Operation) !void {
        try self.ops_to_erase.append(self.allocator, op);
    }

    pub fn isScheduledForErase(self: *const PatternRewriter, op: *const ir.Operation) bool {
        for (self.ops_to_erase.items) |erased_op| {
            if (erased_op == op) return true;
        }
        return false;
    }

    pub fn getRemappedValue(self: *const PatternRewriter, value: *ir.Value) *ir.Value {
        if (self.replacement_mode == .immediate) return value;
        var current = value;
        while (self.replacements.get(current)) |replacement| {
            current = replacement;
        }
        return current;
    }

    pub fn finalize(self: *PatternRewriter, root_op: *ir.Operation) void {
        self.applyPendingReplacements(root_op);

        for (self.ops_to_erase.items) |op| {
            self.notifyRewriteEvent(.{ .erased = op });
            op.erase();
        }
    }

    pub fn applyPendingReplacements(self: *PatternRewriter, root_op: *ir.Operation) void {
        if (self.replacement_mode == .immediate) return;
        if (self.replacements.count() != 0) self.applyReplacementsToOp(root_op);
    }

    pub fn detachScheduledOperations(
        self: *PatternRewriter,
        storage: []DetachedOperation,
    ) []DetachedOperation {
        std.debug.assert(storage.len >= self.ops_to_erase.items.len);
        for (self.ops_to_erase.items, 0..) |op, index| {
            const block = op.getBlock() orelse @panic("scheduled erased operation is detached");
            storage[index] = .{
                .op = op,
                .block = block,
                .next = op.next_op,
            };
            self.notifyRewriteEvent(.{ .erased = op });
            block.detachOperation(op);
        }
        return storage[0..self.ops_to_erase.items.len];
    }

    pub fn restoreDetachedOperations(detached: []const DetachedOperation) void {
        var index = detached.len;
        while (index > 0) {
            index -= 1;
            const entry = detached[index];
            if (entry.next) |next| {
                entry.block.insertBefore(entry.op, next) catch unreachable;
            } else {
                entry.block.addOperation(entry.op) catch unreachable;
            }
        }
    }

    pub fn destroyDetachedOperations(detached: []const DetachedOperation) void {
        for (detached) |entry| entry.op.dropAllReferences();
        var index = detached.len;
        while (index > 0) {
            index -= 1;
            detached[index].op.erase();
        }
    }

    pub fn rollbackCreatedOperations(self: *PatternRewriter) void {
        var index = self.created_ops.items.len;
        while (index > 0) {
            index -= 1;
            self.created_ops.items[index].erase();
        }
        self.created_ops.clearRetainingCapacity();
    }

    fn applyReplacementsToOp(self: *PatternRewriter, op: *ir.Operation) void {
        var context = ReplacementWalk{ .rewriter = self };
        _ = op.walk(.{ .order = .pre_order }, &context, ReplacementWalk.visit) catch unreachable;
    }
};

const ReplacementWalk = struct {
    rewriter: *PatternRewriter,

    fn visit(self: *ReplacementWalk, op: *ir.Operation) void {
        for (op.operands.items, 0..) |*operand, i| {
            const new_value = self.rewriter.getRemappedValue(operand.value);
            if (new_value != operand.value) {
                self.rewriter.setOperandValue(op, i, new_value);
            }
        }
    }
};

fn expectRewriterBlockNames(block: *ir.Block, expected: []const []const u8) !void {
    var iter = block.getOperations();
    for (expected) |name| {
        const op = iter.next() orelse return error.TestExpectedOperation;
        try std.testing.expectEqualStrings(name, op.name.name);
    }
    try std.testing.expect(iter.next() == null);
}

const PatternRewriterEventRecorder = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(Event) = .empty,

    const EventKind = enum {
        modified,
        replaced,
        erased,
    };

    const Event = struct {
        kind: EventKind,
        op: *ir.Operation,
        value_count: usize = 0,
    };

    fn init(allocator: std.mem.Allocator) PatternRewriterEventRecorder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *PatternRewriterEventRecorder) void {
        self.events.deinit(self.allocator);
    }

    pub fn notifyRewriteEvent(self: *PatternRewriterEventRecorder, event: PatternRewriter.RewriteEvent) void {
        const recorded: Event = switch (event) {
            .modified => |op| .{ .kind = .modified, .op = op },
            .replaced => |replacement| .{
                .kind = .replaced,
                .op = replacement.op,
                .value_count = replacement.new_values.len,
            },
            .erased => |op| .{ .kind = .erased, .op = op },
        };
        self.events.append(self.allocator, recorded) catch unreachable;
    }
};
