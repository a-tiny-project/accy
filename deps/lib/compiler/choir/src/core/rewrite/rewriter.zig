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

test "PatternRewriter delegates insertion guard to operation builder" {
    const testing = std.testing;

    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var block = ir.Block.init(testing.allocator);
    defer block.deinit();

    const anchor = try ctx.createOperation(ir.Operation.State.init("test.rewriter.anchor", .unknown));
    try block.addOperation(anchor);

    var rewriter = PatternRewriter.init(testing.allocator, &ctx);
    defer rewriter.deinit();

    rewriter.setInsertionPointBefore(anchor);
    {
        var guard = rewriter.insertionGuard();
        defer guard.deinit();
        rewriter.setInsertionPoint(&block);
        _ = try rewriter.create(ir.Operation.State.init("test.rewriter.tail", .unknown));
    }

    _ = try rewriter.create(ir.Operation.State.init("test.rewriter.before_anchor", .unknown));

    try expectRewriterBlockNames(&block, &.{
        "test.rewriter.before_anchor",
        "test.rewriter.anchor",
        "test.rewriter.tail",
    });
}

test "PatternRewriter tracks inserted ops through builder listener" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    var rewriter = PatternRewriter.init(allocator, &ctx);
    defer rewriter.deinit();

    const detached = try rewriter.create(ir.Operation.State.init("test.detached", ir.Location.getUnknown()));
    try testing.expect(detached.parent_block == null);
    try testing.expectEqual(@as(usize, 0), rewriter.created_ops.items.len);

    var block = ir.Block.init(allocator);
    defer block.deinit();

    rewriter.setInsertionPoint(&block);
    const created = try rewriter.create(ir.Operation.State.init("test.created", ir.Location.getUnknown()));
    try testing.expectEqual(@as(usize, 1), rewriter.created_ops.items.len);
    try testing.expect(rewriter.created_ops.items[0] == created);

    const inserted = try ctx.createOperation(ir.Operation.State.init("test.inserted", ir.Location.getUnknown()));
    _ = try rewriter.insert(inserted);
    try testing.expectEqual(@as(usize, 2), rewriter.created_ops.items.len);
    try testing.expect(rewriter.created_ops.items[1] == inserted);
    try expectRewriterBlockNames(&block, &.{ "test.created", "test.inserted" });
}

test "PatternRewriter listener binds typed rewrite events" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const op = try ctx.createOperation(ir.Operation.State.init("test.attr_target", .unknown));
    const attr = try ctx.getStringAttr("tracked");

    var recorder = PatternRewriterEventRecorder.init(allocator);
    defer recorder.deinit();

    var rewriter = PatternRewriter.init(allocator, &ctx);
    defer rewriter.deinit();
    rewriter.setListener(PatternRewriter.Listener.bind(&recorder));

    try rewriter.setAttr(op, "debug.note", attr);

    try testing.expect(op.getAttr("debug.note") != null);
    try testing.expectEqual(@as(usize, 1), recorder.events.items.len);
    try testing.expectEqual(PatternRewriterEventRecorder.EventKind.modified, recorder.events.items[0].kind);
    try testing.expect(recorder.events.items[0].op == op);
}

test "PatternRewriter replaceOp rejects result count mismatches" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const value_type = try ctx.getDialectTypeFromName("test.value");
    var old_state = ir.Operation.State.init("test.old", .unknown);
    old_state.addTypes(&.{value_type});
    const old_op = try ctx.createOperation(old_state);

    var rewriter = PatternRewriter.init(allocator, &ctx);
    defer rewriter.deinit();

    try testing.expectError(error.ReplacementResultCountMismatch, rewriter.replaceOp(old_op, &.{}));
    try testing.expectEqual(@as(usize, 0), rewriter.replacements.count());
    try testing.expect(!rewriter.isScheduledForErase(old_op));
}

test "PatternRewriter immediate replacement uses no allocator or finalize walk" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const old_type = try ctx.getDialectTypeFromName("test.old_type");
    const new_type = try ctx.getDialectTypeFromName("test.new_type");

    var replacement_state = ir.Operation.State.init("test.replacement", .unknown);
    replacement_state.addTypes(&.{new_type});
    const replacement_op = try ctx.createOperation(replacement_state);
    const replacement_value = replacement_op.getResult(0).?;

    var old_state = ir.Operation.State.init("test.old_value", .unknown);
    old_state.addTypes(&.{old_type});
    const old_op = try ctx.createOperation(old_state);
    const old_value = old_op.getResult(0).?;

    var user_state = ir.Operation.State.init("test.user", .unknown);
    user_state.addOperands(&.{old_value});
    const user = try ctx.createOperation(user_state);

    var body = ir.context.initRegion(&ctx);
    defer body.deinit();
    const block = try body.addBlock();
    try block.addOperation(replacement_op);
    try block.addOperation(old_op);
    try block.addOperation(user);

    var root_state = ir.Operation.State.init("test.root", .unknown);
    root_state.addRegionBodies(&.{&body});
    const root = try ctx.createOperation(root_state);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var rewriter = PatternRewriter.init(failing.allocator(), &ctx);
    defer rewriter.deinit();

    try rewriter.replaceAllOpUsesWithOperation(old_op, replacement_op);
    try testing.expect(!rewriter.isScheduledForErase(old_op));
    try testing.expect(user.operands.items[0].value == replacement_value);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);

    rewriter.finalize(root);

    try testing.expect(user.operands.items[0].value == replacement_value);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    const root_block = root.getRegion(0).?.getEntryBlock().?;
    try expectRewriterBlockNames(root_block, &.{ "test.replacement", "test.old_value", "test.user" });
}

test "PatternRewriter listener records replacement modification and erase" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const old_type = try ctx.getDialectTypeFromName("test.old_type");
    const new_type = try ctx.getDialectTypeFromName("test.new_type");

    var replacement_state = ir.Operation.State.init("test.replacement", .unknown);
    replacement_state.addTypes(&.{new_type});
    const replacement_op = try ctx.createOperation(replacement_state);
    const replacement_value = replacement_op.getResult(0).?;

    var old_state = ir.Operation.State.init("test.old_value", .unknown);
    old_state.addTypes(&.{old_type});
    const old_op = try ctx.createOperation(old_state);
    const old_value = old_op.getResult(0).?;

    var user_state = ir.Operation.State.init("test.user", .unknown);
    user_state.addOperands(&.{old_value});
    const user = try ctx.createOperation(user_state);

    var body = ir.context.initRegion(&ctx);
    defer body.deinit();
    const block = try body.addBlock();
    try block.addOperation(replacement_op);
    try block.addOperation(old_op);
    try block.addOperation(user);

    var root_state = ir.Operation.State.init("test.root", .unknown);
    root_state.addRegionBodies(&.{&body});
    const root = try ctx.createOperation(root_state);

    var recorder = PatternRewriterEventRecorder.init(allocator);
    defer recorder.deinit();

    var rewriter = PatternRewriter.init(allocator, &ctx);
    defer rewriter.deinit();
    rewriter.setListener(PatternRewriter.Listener.bind(&recorder));

    try rewriter.replaceOpWithOperation(old_op, replacement_op);
    try testing.expectEqual(@as(usize, 2), recorder.events.items.len);
    try testing.expectEqual(PatternRewriterEventRecorder.EventKind.replaced, recorder.events.items[0].kind);
    try testing.expect(recorder.events.items[0].op == old_op);
    try testing.expectEqual(@as(usize, 1), recorder.events.items[0].value_count);

    rewriter.finalize(root);

    try testing.expect(user.operands.items[0].value == replacement_value);
    try testing.expectEqual(@as(usize, 3), recorder.events.items.len);
    try testing.expectEqual(PatternRewriterEventRecorder.EventKind.modified, recorder.events.items[1].kind);
    try testing.expect(recorder.events.items[1].op == user);
    try testing.expectEqual(PatternRewriterEventRecorder.EventKind.erased, recorder.events.items[2].kind);
    try testing.expect(recorder.events.items[2].op == old_op);
    const root_block = root.getRegion(0).?.getEntryBlock().?;
    try expectRewriterBlockNames(root_block, &.{ "test.replacement", "test.user" });
}

test "PatternRewriter replaceOpWithOperation remaps existing operation results" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const old_type = try ctx.getDialectTypeFromName("test.old_type");
    const new_type = try ctx.getDialectTypeFromName("test.new_type");

    var replacement_state = ir.Operation.State.init("test.replacement", .unknown);
    replacement_state.addTypes(&.{new_type});
    const replacement_op = try ctx.createOperation(replacement_state);
    const replacement_value = replacement_op.getResult(0).?;

    var old_state = ir.Operation.State.init("test.old_value", .unknown);
    old_state.addTypes(&.{old_type});
    const old_op = try ctx.createOperation(old_state);
    const old_value = old_op.getResult(0).?;

    var user_state = ir.Operation.State.init("test.user", .unknown);
    user_state.addOperands(&.{old_value});
    const user = try ctx.createOperation(user_state);

    var body = ir.context.initRegion(&ctx);
    defer body.deinit();
    const block = try body.addBlock();
    try block.addOperation(replacement_op);
    try block.addOperation(old_op);
    try block.addOperation(user);

    var root_state = ir.Operation.State.init("test.root", .unknown);
    root_state.addRegionBodies(&.{&body});
    const root = try ctx.createOperation(root_state);

    var rewriter = PatternRewriter.init(allocator, &ctx);
    defer rewriter.deinit();

    try rewriter.replaceOpWithOperation(old_op, replacement_op);
    try testing.expectEqual(@as(usize, 0), rewriter.created_ops.items.len);
    try testing.expect(rewriter.isScheduledForErase(old_op));

    rewriter.finalize(root);

    try testing.expect(user.operands.items[0].value == replacement_value);
    const root_block = root.getRegion(0).?.getEntryBlock().?;
    try expectRewriterBlockNames(root_block, &.{ "test.replacement", "test.user" });
}

test "PatternRewriter detached erasures can be restored or committed" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const value_type = try ctx.getDialectTypeFromName("test.value");
    var replacement_state = ir.Operation.State.init("test.replacement", .unknown);
    replacement_state.addTypes(&.{value_type});
    const replacement = try ctx.createOperation(replacement_state);
    var old_state = ir.Operation.State.init("test.old", .unknown);
    old_state.addTypes(&.{value_type});
    const old = try ctx.createOperation(old_state);
    var user_state = ir.Operation.State.init("test.user", .unknown);
    user_state.addOperands(&.{old.getResult(0).?});
    const user = try ctx.createOperation(user_state);

    var body = ir.context.initRegion(&ctx);
    defer body.deinit();
    const block = try body.addBlock();
    try block.addOperation(replacement);
    try block.addOperation(old);
    try block.addOperation(user);
    var root_state = ir.Operation.State.init("test.root", .unknown);
    root_state.addRegionBodies(&.{&body});
    const root = try ctx.createOperation(root_state);

    var rewriter = PatternRewriter.initDeferred(allocator, &ctx);
    defer rewriter.deinit();
    try rewriter.replaceOpWithOperation(old, replacement);
    try testing.expectEqual(old.getResult(0).?, user.getOperand(0).?);

    var detached_storage: [1]PatternRewriter.DetachedOperation = undefined;
    rewriter.applyPendingReplacements(root);
    const detached = rewriter.detachScheduledOperations(&detached_storage);
    try testing.expectEqual(replacement.getResult(0).?, user.getOperand(0).?);
    try expectRewriterBlockNames(block, &.{ "test.replacement", "test.user" });

    user.setOperandValue(0, old.getResult(0).?);
    PatternRewriter.restoreDetachedOperations(detached);
    try expectRewriterBlockNames(block, &.{ "test.replacement", "test.old", "test.user" });

    rewriter.applyPendingReplacements(root);
    _ = rewriter.detachScheduledOperations(&detached_storage);
    PatternRewriter.destroyDetachedOperations(&detached_storage);
    try testing.expectEqual(replacement.getResult(0).?, user.getOperand(0).?);
    try expectRewriterBlockNames(block, &.{ "test.replacement", "test.user" });
}

test "PatternRewriter replaceOpWithNewOp remaps replacement results" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const old_type = try ctx.getDialectTypeFromName("test.old_type");
    const new_type = try ctx.getDialectTypeFromName("test.new_type");

    var old_state = ir.Operation.State.init("test.old_value", .unknown);
    old_state.addTypes(&.{old_type});
    const old_op = try ctx.createOperation(old_state);
    const old_value = old_op.getResult(0).?;

    var user_state = ir.Operation.State.init("test.user", .unknown);
    user_state.addOperands(&.{old_value});
    const user = try ctx.createOperation(user_state);

    var body = ir.context.initRegion(&ctx);
    defer body.deinit();
    const block = try body.addBlock();
    try block.addOperation(old_op);
    try block.addOperation(user);

    var root_state = ir.Operation.State.init("test.root", .unknown);
    root_state.addRegionBodies(&.{&body});
    const root = try ctx.createOperation(root_state);

    var rewriter = PatternRewriter.init(allocator, &ctx);
    defer rewriter.deinit();

    rewriter.setInsertionPointBefore(old_op);
    var new_state = ir.Operation.State.init("test.new_value", .unknown);
    new_state.addTypes(&.{new_type});
    const new_op = try rewriter.replaceOpWithNewOp(old_op, new_state);
    const new_value = new_op.getResult(0).?;

    try testing.expectEqual(@as(usize, 1), rewriter.created_ops.items.len);
    try testing.expect(rewriter.created_ops.items[0] == new_op);
    try testing.expect(rewriter.isScheduledForErase(old_op));

    rewriter.finalize(root);

    try testing.expect(user.operands.items[0].value == new_value);
    const root_block = root.getRegion(0).?.getEntryBlock().?;
    try expectRewriterBlockNames(root_block, &.{ "test.new_value", "test.user" });
}

test "PatternRewriter replaceOpWithNewOp rejects result count mismatches before insertion" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const i32_type = try ctx.getDialectTypeFromName("test.i32");
    var block = ir.Block.init(allocator);
    defer block.deinit();

    var old_state = ir.Operation.State.init("test.old", .unknown);
    old_state.addTypes(&.{i32_type});
    const old_op = try ctx.createOperation(old_state);
    try block.addOperation(old_op);

    var rewriter = PatternRewriter.init(allocator, &ctx);
    defer rewriter.deinit();
    rewriter.setInsertionPointBefore(old_op);

    const no_result_state = ir.Operation.State.init("test.no_result", .unknown);
    try testing.expectError(
        error.ReplacementResultCountMismatch,
        rewriter.replaceOpWithNewOp(old_op, no_result_state),
    );

    try testing.expectEqual(@as(usize, 0), rewriter.created_ops.items.len);
    try testing.expect(!rewriter.isScheduledForErase(old_op));
    try expectRewriterBlockNames(&block, &.{"test.old"});
}

test "PatternRewriter finalize remaps nested operands through operation walk" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const value_type = try ctx.getDialectTypeFromName("test.value");

    var old_state = ir.Operation.State.init("test.old_value", .unknown);
    old_state.addTypes(&.{value_type});
    const old_op = try ctx.createOperation(old_state);
    const old_value = old_op.getResult(0).?;

    var new_state = ir.Operation.State.init("test.new_value", .unknown);
    new_state.addTypes(&.{value_type});
    const new_op = try ctx.createOperation(new_state);
    const new_value = new_op.getResult(0).?;

    var body = ir.context.initRegion(&ctx);
    defer body.deinit();
    const block = try body.addBlock();

    var user_state = ir.Operation.State.init("test.nested_user", .unknown);
    user_state.addOperands(&.{old_value});
    const user = try ctx.createOperation(user_state);
    try block.addOperation(user);

    var root_state = ir.Operation.State.init("test.rewrite_root", .unknown);
    root_state.addRegionBodies(&.{&body});
    const root = try ctx.createOperation(root_state);

    var rewriter = PatternRewriter.init(allocator, &ctx);
    defer rewriter.deinit();

    try rewriter.replaceAllUsesWith(old_value, new_value);
    rewriter.finalize(root);

    try testing.expect(user.operands.items[0].value == new_value);
}
