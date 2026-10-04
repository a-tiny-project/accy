const std = @import("std");
const alloc_phase = @import("alloc_phase");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");

pub const Severity = enum {
    note,
    warning,
    remark,
    err,
};

pub const Metadata = struct {
    name: []const u8,
    value: []const u8,
};

pub const Note = struct {
    location: ir.Location,
    message: []const u8,
};

pub const Diagnostic = struct {
    severity: Severity,
    location: ir.Location,
    message: []const u8,
    operation: ?*ir.Operation = null,
    error_name: ?[]const u8 = null,
    notes: []const Note = &.{},
    metadata: []const Metadata = &.{},

    pub fn operationName(self: Diagnostic) ?[]const u8 {
        const op = self.operation orelse return null;
        return op.name.name;
    }
};

pub fn operationDiagnostic(
    op: *ir.Operation,
    severity: Severity,
    message: []const u8,
) Diagnostic {
    return .{
        .severity = severity,
        .location = op.getLoc(),
        .message = message,
        .operation = op,
    };
}

pub const InFlightDiagnostic = struct {
    engine: *Engine,
    diagnostic: Diagnostic,
    notes: std.ArrayListUnmanaged(Note) = .empty,
    metadata: std.ArrayListUnmanaged(Metadata) = .empty,
    notes_copied: bool = false,
    metadata_copied: bool = false,
    emitted: bool = false,
    owned_message: ?[]u8 = null,

    pub const Error = error{DiagnosticAlreadyEmitted} || std.mem.Allocator.Error;

    pub fn deinit(self: *InFlightDiagnostic, payload_allocator: std.mem.Allocator) void {
        if (self.owned_message) |message| {
            payload_allocator.free(message);
        }
        self.notes.deinit(payload_allocator);
        self.metadata.deinit(payload_allocator);
        self.* = undefined;
    }

    pub fn ownMessage(self: *InFlightDiagnostic, message: []u8) void {
        self.owned_message = message;
        self.diagnostic.message = message;
    }

    pub fn attachNote(
        self: *InFlightDiagnostic,
        payload_allocator: std.mem.Allocator,
        message: []const u8,
    ) Error!void {
        return self.attachNoteAt(payload_allocator, self.diagnostic.location, message);
    }

    pub fn attachNoteAt(
        self: *InFlightDiagnostic,
        payload_allocator: std.mem.Allocator,
        location: ir.Location,
        message: []const u8,
    ) Error!void {
        try self.requireMutable();
        try self.ensureNotesMutable(payload_allocator);
        try self.notes.append(payload_allocator, .{
            .location = location,
            .message = message,
        });
    }

    pub fn addMetadata(
        self: *InFlightDiagnostic,
        payload_allocator: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
    ) Error!void {
        try self.requireMutable();
        try self.ensureMetadataMutable(payload_allocator);
        try self.metadata.append(payload_allocator, .{
            .name = name,
            .value = value,
        });
    }

    pub fn emit(self: *InFlightDiagnostic) !HandlerResult {
        self.emitted = true;
        var diagnostic = self.diagnostic;
        if (self.notes_copied) {
            diagnostic.notes = self.notes.items;
        }
        if (self.metadata_copied) {
            diagnostic.metadata = self.metadata.items;
        }
        return self.engine.report(diagnostic);
    }

    fn requireMutable(self: *const InFlightDiagnostic) Error!void {
        if (self.emitted) return error.DiagnosticAlreadyEmitted;
    }

    fn ensureNotesMutable(
        self: *InFlightDiagnostic,
        payload_allocator: std.mem.Allocator,
    ) Error!void {
        if (self.notes_copied) return;
        try self.notes.appendSlice(payload_allocator, self.diagnostic.notes);
        self.notes_copied = true;
    }

    fn ensureMetadataMutable(
        self: *InFlightDiagnostic,
        payload_allocator: std.mem.Allocator,
    ) Error!void {
        if (self.metadata_copied) return;
        try self.metadata.appendSlice(payload_allocator, self.diagnostic.metadata);
        self.metadata_copied = true;
    }
};

pub fn BoundInFlightDiagnostic(
    comptime Context: type,
    comptime payloadAllocator: anytype,
) type {
    return struct {
        context: *Context,
        diagnostic: InFlightDiagnostic,

        const Self = @This();
        pub const Error = InFlightDiagnostic.Error;

        pub fn deinit(self: *Self) void {
            self.diagnostic.deinit(payloadAllocator(self.context));
            self.* = undefined;
        }

        pub fn ownMessage(self: *Self, message: []u8) void {
            self.diagnostic.ownMessage(message);
        }

        pub fn attachNote(self: *Self, message: []const u8) Error!void {
            return self.diagnostic.attachNote(payloadAllocator(self.context), message);
        }

        pub fn attachNoteAt(
            self: *Self,
            location: ir.Location,
            message: []const u8,
        ) Error!void {
            return self.diagnostic.attachNoteAt(
                payloadAllocator(self.context),
                location,
                message,
            );
        }

        pub fn addMetadata(
            self: *Self,
            name: []const u8,
            value: []const u8,
        ) Error!void {
            return self.diagnostic.addMetadata(
                payloadAllocator(self.context),
                name,
                value,
            );
        }

        pub fn emit(self: *Self) !HandlerResult {
            return self.diagnostic.emit();
        }
    };
}

pub const HandlerResult = enum {
    consumed,
    propagate,
};

pub const Handler = struct {
    context: ?*anyopaque = null,
    handle: *const fn (context: ?*anyopaque, diagnostic: *const Diagnostic) anyerror!HandlerResult,
};

pub const Engine = struct {
    handlers: std.ArrayListUnmanaged(HandlerEntry) = .empty,
    next_id: HandlerId = 0,

    pub const HandlerId = usize;

    const HandlerEntry = struct {
        id: HandlerId,
        handler: Handler,
    };

    pub fn init() Engine {
        return .{};
    }

    pub fn deinit(self: *Engine, handler_allocator: std.mem.Allocator) void {
        self.handlers.deinit(handler_allocator);
        self.* = undefined;
    }

    pub fn registerHandler(
        self: *Engine,
        handler_allocator: std.mem.Allocator,
        handler: Handler,
    ) !HandlerId {
        const id = self.next_id;
        const next_id = std.math.add(HandlerId, id, 1) catch return error.HandlerIdExhausted;
        try self.handlers.append(handler_allocator, .{ .id = id, .handler = handler });
        self.next_id = next_id;
        return id;
    }

    pub fn eraseHandler(self: *Engine, id: HandlerId) void {
        for (self.handlers.items, 0..) |entry, index| {
            if (entry.id == id) {
                _ = self.handlers.orderedRemove(index);
                return;
            }
        }
    }

    pub fn emit(
        self: *Engine,
        diagnostic: Diagnostic,
    ) InFlightDiagnostic {
        return .{
            .engine = self,
            .diagnostic = diagnostic,
        };
    }

    pub fn report(self: *Engine, diagnostic: Diagnostic) !HandlerResult {
        if (active_capture) |scope| {
            if (scope.engine == self) {
                try scope.buffer.append(diagnostic);
                return .consumed;
            }
        }
        return self.reportHandlers(diagnostic);
    }

    pub fn capture(self: *Engine, buffer: *CaptureBuffer) CaptureScope {
        return .{
            .engine = self,
            .buffer = buffer,
        };
    }

    pub fn replay(self: *Engine, buffer: *const CaptureBuffer) !HandlerResult {
        var result: HandlerResult = .propagate;
        for (buffer.diagnostics.items) |diagnostic| {
            if (try self.reportHandlers(diagnostic) == .consumed) {
                result = .consumed;
            }
        }
        return result;
    }

    fn reportHandlers(self: *Engine, diagnostic: Diagnostic) !HandlerResult {
        var index = self.handlers.items.len;
        while (index > 0) {
            index -= 1;
            const handler = self.handlers.items[index].handler;
            if (try handler.handle(handler.context, &diagnostic) == .consumed) {
                return .consumed;
            }
        }
        return .propagate;
    }
};

threadlocal var active_capture: ?*CaptureScope = null;

pub const CaptureBuffer = struct {
    arena: alloc_arena.Arena,
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) CaptureBuffer {
        return .{ .arena = alloc_arena.Arena.init(allocator) };
    }

    pub fn deinit(self: *CaptureBuffer) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn append(self: *CaptureBuffer, diagnostic: Diagnostic) !void {
        const allocator = self.arena.allocator();
        var copied = diagnostic;
        copied.message = try allocator.dupe(u8, diagnostic.message);
        if (diagnostic.error_name) |name| {
            copied.error_name = try allocator.dupe(u8, name);
        }
        copied.notes = try cloneNotes(allocator, diagnostic.notes);
        copied.metadata = try cloneMetadata(allocator, diagnostic.metadata);
        try self.diagnostics.append(allocator, copied);
    }
};

pub const CaptureScope = struct {
    engine: *Engine,
    buffer: *CaptureBuffer,
    previous: ?*CaptureScope = null,

    pub fn enter(self: *CaptureScope) CaptureGuard {
        self.previous = active_capture;
        active_capture = self;
        return .{ .scope = self };
    }

    fn exit(self: *CaptureScope) void {
        std.debug.assert(active_capture == self);
        active_capture = self.previous;
        self.previous = null;
    }
};

pub const CaptureGuard = struct {
    scope: ?*CaptureScope,

    pub fn deinit(self: *CaptureGuard) void {
        if (self.scope) |scope| {
            scope.exit();
            self.scope = null;
        }
    }
};

fn cloneNotes(allocator: std.mem.Allocator, notes: []const Note) ![]const Note {
    if (notes.len == 0) return &.{};
    const copied = try allocator.alloc(Note, notes.len);
    for (notes, copied) |note, *out| {
        out.* = .{
            .location = note.location,
            .message = try allocator.dupe(u8, note.message),
        };
    }
    return copied;
}

fn cloneMetadata(allocator: std.mem.Allocator, metadata: []const Metadata) ![]const Metadata {
    if (metadata.len == 0) return &.{};
    const copied = try allocator.alloc(Metadata, metadata.len);
    for (metadata, copied) |entry, *out| {
        out.* = .{
            .name = try allocator.dupe(u8, entry.name),
            .value = try allocator.dupe(u8, entry.value),
        };
    }
    return copied;
}

pub const VerifierFailure = struct {
    stage: []const u8,
    root: *ir.Operation,
    operation: *ir.Operation,
    location: ir.Location,
    err: anyerror,

    pub fn init(
        stage: []const u8,
        root: *ir.Operation,
        options: ir.VerifyOptions,
        err: anyerror,
    ) VerifierFailure {
        const operation = findFailureOp(root, options) orelse root;
        return .{
            .stage = stage,
            .root = root,
            .operation = operation,
            .location = operation.getLoc(),
            .err = err,
        };
    }

    pub fn diagnostic(self: *const VerifierFailure) Diagnostic {
        return .{
            .severity = .err,
            .location = self.location,
            .message = "Choir verifier failed",
            .operation = self.operation,
            .error_name = @errorName(self.err),
        };
    }

    pub fn format(self: *const VerifierFailure, buf: []u8) []const u8 {
        return formatVerifierFailure(buf, self.*);
    }
};

pub fn captureVerifierFailure(
    stage: []const u8,
    root: *ir.Operation,
    options: ir.VerifyOptions,
    err: anyerror,
) VerifierFailure {
    return VerifierFailure.init(stage, root, options, err);
}

pub fn formatVerifierFailure(buf: []u8, failure: VerifierFailure) []const u8 {
    var loc_buf: [128]u8 = undefined;
    const loc_str = formatLocation(&loc_buf, failure.location);

    return std.fmt.bufPrint(
        buf,
        "Choir verifier failed ({s}): op={s} {s} error={s}",
        .{ failure.stage, failure.operation.name.name, loc_str, @errorName(failure.err) },
    ) catch "Choir verifier failed";
}

pub fn findFailureOp(root: *ir.Operation, options: ir.VerifyOptions) ?*ir.Operation {
    const shallow = ir.VerifyOptions{
        .check_terminators = options.check_terminators,
        .require_terminators = options.require_terminators,
        .recursive = false,
        .check_use_def = options.check_use_def,
        .check_local_dominance = options.check_local_dominance,
        .check_cfg = options.check_cfg,
        .max_depth = options.max_depth,
    };
    return findFailureOpRecursive(root, shallow);
}

fn findFailureOpRecursive(op: *ir.Operation, options: ir.VerifyOptions) ?*ir.Operation {
    ir.verifyOperationStructure(op, options) catch return op;

    ir.verify.runTraitVerifiers(op) catch return op;

    if (op.getInterface(ir.VerifyOpInterface)) |vtable| {
        vtable.verify(@ptrCast(op)) catch return op;
    }

    for (op.regions.items) |*region| {
        ir.verifyRegionStructure(region, options) catch return op;

        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            ir.verifyBlockStructure(block, options) catch return op;

            var op_node: ?*anyopaque = block.operations.head;
            while (op_node) |node| {
                const child: *ir.Operation = @ptrCast(@alignCast(node));
                if (findFailureOpRecursive(child, options)) |found| return found;
                op_node = child.next_op;
            }
        }
    }

    ir.verify.runRegionTraitVerifiers(op) catch return op;

    if (op.getInterface(ir.VerifyRegionOpInterface)) |vtable| {
        vtable.verify(@ptrCast(op)) catch return op;
    }

    return null;
}

fn formatLocation(buf: []u8, loc: ir.Location) []const u8 {
    return switch (loc) {
        .unknown => "loc(unknown)",
        .file => |f| std.fmt.bufPrint(buf, "loc(\"{s}\":{d}:{d})", .{ f.filename, f.line, f.column }) catch "loc(?)",
        .file_range => |range| std.fmt.bufPrint(
            buf,
            "loc(\"{s}\":{d}:{d})",
            .{ range.filename, range.start.line, range.start.column },
        ) catch "loc(?)",
        .name => |n| std.fmt.bufPrint(buf, "loc(\"{s}\")", .{n.name}) catch "loc(?)",
        .fused => "loc(fused)",
        .call_site => "loc(callsite)",
    };
}

test "findFailureOp localizes a SameTypeOperandsMismatch trait failure to the nested cmp op" {
    const testing = std.testing;
    const dialects = @import("../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, dialects.arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    const bool_type = try ArithDialect.getScalarType(&ctx, .bool);

    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ctx, loc, "bad_cmp", &.{}, &.{bool_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c1 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    try entry.addOperation(c1.op);
    var c2 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i64_type, 2);
    try entry.addOperation(c2.op);
    const bad_cmp = try ArithDialect.CmpOp.create(&ctx, loc, .eq, c1.getResult(), c2.getResult());
    try entry.addOperation(bad_cmp.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{bad_cmp.getResult()});
    try entry.addOperation(ret.op);

    const failure_op = findFailureOp(module.op, ir.verify.default_options);
    try testing.expect(failure_op != null);
    try testing.expectEqual(bad_cmp.op, failure_op.?);
}

test "captureVerifierFailure carries structured verifier fields and stable text" {
    const testing = std.testing;
    const dialects = @import("../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, dialects.arith.spec);

    const loc = ir.Location.getFile("bad.tiny", 7, 13);
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    const bool_type = try ArithDialect.getScalarType(&ctx, .bool);

    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ctx, loc, "bad_cmp", &.{}, &.{bool_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c1 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    try entry.addOperation(c1.op);
    var c2 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i64_type, 2);
    try entry.addOperation(c2.op);
    const bad_cmp = try ArithDialect.CmpOp.create(&ctx, loc, .eq, c1.getResult(), c2.getResult());
    try entry.addOperation(bad_cmp.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{bad_cmp.getResult()});
    try entry.addOperation(ret.op);

    const failure = captureVerifierFailure(
        "backend/test/verify",
        module.op,
        ir.verify.default_options,
        error.SameTypeOperandsMismatch,
    );
    const diagnostic = failure.diagnostic();

    try testing.expectEqual(Severity.err, diagnostic.severity);
    try testing.expectEqual(bad_cmp.op, diagnostic.operation.?);
    try testing.expectEqualStrings("arith.cmp", diagnostic.operationName().?);
    try testing.expectEqualStrings("SameTypeOperandsMismatch", diagnostic.error_name.?);
    try testing.expect(diagnostic.location.eql(loc));

    var buffer: [256]u8 = undefined;
    const text = failure.format(&buffer);
    try testing.expect(std.mem.indexOf(u8, text, "backend/test/verify") != null);
    try testing.expect(std.mem.indexOf(u8, text, "op=arith.cmp") != null);
    try testing.expect(std.mem.indexOf(u8, text, "loc(\"bad.tiny\":7:13)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "SameTypeOperandsMismatch") != null);
}

test "Engine invokes newest handler first and respects propagation" {
    const testing = std.testing;

    const Counter = struct {
        seen: usize = 0,
        consumed: usize = 0,

        fn propagate(context: ?*anyopaque, diagnostic: *const Diagnostic) !HandlerResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.seen += 1;
            try testing.expectEqual(Severity.warning, diagnostic.severity);
            return .propagate;
        }

        fn consume(context: ?*anyopaque, diagnostic: *const Diagnostic) !HandlerResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.seen += 1;
            self.consumed += 1;
            try testing.expectEqualStrings("choir.test", diagnostic.metadata[0].value);
            return .consumed;
        }
    };

    var engine = Engine.init();
    defer engine.deinit(testing.allocator);

    var counter = Counter{};
    _ = try engine.registerHandler(testing.allocator, .{ .context = &counter, .handle = Counter.propagate });
    const consuming_handler = try engine.registerHandler(testing.allocator, .{ .context = &counter, .handle = Counter.consume });

    const metadata = [_]Metadata{.{ .name = "dialect", .value = "choir.test" }};
    const diagnostic = Diagnostic{
        .severity = .warning,
        .location = ir.Location.getUnknown(),
        .message = "example diagnostic",
        .metadata = &metadata,
    };
    const result = try engine.report(diagnostic);

    try testing.expectEqual(HandlerResult.consumed, result);
    try testing.expectEqual(@as(usize, 1), counter.seen);
    try testing.expectEqual(@as(usize, 1), counter.consumed);

    engine.eraseHandler(consuming_handler);
    const propagated = try engine.report(diagnostic);
    try testing.expectEqual(HandlerResult.propagate, propagated);
    try testing.expectEqual(@as(usize, 2), counter.seen);
    try testing.expectEqual(@as(usize, 1), counter.consumed);
}

test "Context diagnostics reject named segment exhaustion before mutation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("../core/context/root.zig").Context, "choir_context_diagnostic_exhaustion"),
        );
    }

    const testing = std.testing;
    const HandlerFn = struct {
        fn handle(_: ?*anyopaque, _: *const Diagnostic) !HandlerResult {
            return .propagate;
        }
    };

    var handler_limits = ir.Context.Limits.testing;
    handler_limits.diagnostics.handler_bytes = 1;
    var handler_context = try ir.Context.init(testing.allocator, handler_limits);
    defer handler_context.deinit(testing.allocator);
    handler_context.activate();

    const engine = handler_context.getDiagnosticEngine();
    const next_id = engine.next_id;
    try testing.expectError(error.OutOfMemory, handler_context.registerDiagnosticHandler(.{
        .handle = HandlerFn.handle,
    }));
    try testing.expectEqual(next_id, engine.next_id);
    try testing.expectEqual(@as(usize, 0), engine.handlers.items.len);
    try testing.expectEqual(
        ir.Context.Segment.diagnostic_handlers,
        handler_context.exhaustedSegment().?,
    );

    var payload_limits = ir.Context.Limits.testing;
    payload_limits.diagnostics.payload_bytes = 1;
    var payload_context = try ir.Context.init(testing.allocator, payload_limits);
    defer payload_context.deinit(testing.allocator);
    payload_context.activate();

    var diagnostic = payload_context.emitDiagnostic(.{
        .severity = .warning,
        .location = ir.Location.getUnknown(),
        .message = "bounded",
    });
    defer diagnostic.deinit();
    try testing.expectError(error.OutOfMemory, diagnostic.attachNote("note"));
    try testing.expectEqual(@as(usize, 0), diagnostic.diagnostic.notes.items.len);
    try testing.expectEqual(
        ir.Context.Segment.diagnostic_payloads,
        payload_context.exhaustedSegment().?,
    );

    payload_context.clearExhaustion();
    try testing.expectError(error.OutOfMemory, diagnostic.addMetadata("name", "value"));
    try testing.expectEqual(@as(usize, 0), diagnostic.diagnostic.metadata.items.len);
    try testing.expectEqual(
        ir.Context.Segment.diagnostic_payloads,
        payload_context.exhaustedSegment().?,
    );
}

test "Engine capture replays diagnostics after in-flight storage is destroyed" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("../core/context/root.zig").Context, "choir_context_foreign_ownership"),
        );
    }

    const testing = std.testing;

    const Recorder = struct {
        seen: usize = 0,
        severity: Severity = .note,
        message: []const u8 = "",
        note: []const u8 = "",
        metadata_name: []const u8 = "",
        metadata_value: []const u8 = "",

        fn handle(context: ?*anyopaque, diagnostic: *const Diagnostic) !HandlerResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.seen += 1;
            self.severity = diagnostic.severity;
            self.message = diagnostic.message;
            self.note = diagnostic.notes[0].message;
            self.metadata_name = diagnostic.metadata[0].name;
            self.metadata_value = diagnostic.metadata[0].value;
            return .consumed;
        }
    };

    var engine = Engine.init();
    defer engine.deinit(testing.allocator);

    var recorder = Recorder{};
    _ = try engine.registerHandler(testing.allocator, .{
        .context = &recorder,
        .handle = Recorder.handle,
    });

    var buffer = CaptureBuffer.init(testing.allocator);
    defer buffer.deinit();

    {
        var scope = engine.capture(&buffer);
        var guard = scope.enter();
        defer guard.deinit();

        var diagnostic = engine.emit(.{
            .severity = .warning,
            .location = ir.Location.getUnknown(),
            .message = "borrowed",
        });
        defer diagnostic.deinit(testing.allocator);

        const owned = try testing.allocator.dupe(u8, "owned diagnostic");
        diagnostic.ownMessage(owned);
        try diagnostic.attachNote(testing.allocator, "captured note");
        try diagnostic.addMetadata(testing.allocator, "owner", "capture");

        try testing.expectEqual(HandlerResult.consumed, try diagnostic.emit());
    }

    try testing.expectEqual(@as(usize, 0), recorder.seen);
    try testing.expectEqual(HandlerResult.consumed, try engine.replay(&buffer));
    try testing.expectEqual(@as(usize, 1), recorder.seen);
    try testing.expectEqual(Severity.warning, recorder.severity);
    try testing.expectEqualStrings("owned diagnostic", recorder.message);
    try testing.expectEqualStrings("captured note", recorder.note);
    try testing.expectEqualStrings("owner", recorder.metadata_name);
    try testing.expectEqualStrings("capture", recorder.metadata_value);
}

test "operationDiagnostic anchors message to operation and location" {
    const testing = std.testing;
    const loc = ir.Location.getName("anchor", null);

    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const op = try ctx.createOperation(ir.Operation.State.init("test.anchor", loc));
    const diagnostic = operationDiagnostic(op, .note, "attached to operation");

    try testing.expectEqual(Severity.note, diagnostic.severity);
    try testing.expect(diagnostic.location.eql(loc));
    try testing.expectEqual(op, diagnostic.operation.?);
    try testing.expectEqualStrings("test.anchor", diagnostic.operationName().?);
}

test "InFlightDiagnostic attaches notes and metadata before reporting" {
    const testing = std.testing;
    const loc = ir.Location.getFile("emit.tiny", 3, 5);
    const note_loc = ir.Location.getFile("emit.tiny", 8, 2);

    const Recorder = struct {
        seen: usize = 0,
        severity: Severity = .note,
        message: []const u8 = "",
        note_count: usize = 0,
        first_note_location: ir.Location = ir.Location.getUnknown(),
        first_note_message: []const u8 = "",
        second_note_location: ir.Location = ir.Location.getUnknown(),
        metadata_name: []const u8 = "",
        metadata_value: []const u8 = "",

        fn handle(context: ?*anyopaque, diagnostic: *const Diagnostic) !HandlerResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.seen += 1;
            self.severity = diagnostic.severity;
            self.message = diagnostic.message;
            self.note_count = diagnostic.notes.len;
            self.first_note_location = diagnostic.notes[0].location;
            self.first_note_message = diagnostic.notes[0].message;
            self.second_note_location = diagnostic.notes[1].location;
            self.metadata_name = diagnostic.metadata[0].name;
            self.metadata_value = diagnostic.metadata[0].value;
            return .consumed;
        }
    };

    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const op = try ctx.createOperation(ir.Operation.State.init("test.emit", loc));

    var recorder = Recorder{};
    _ = try ctx.registerDiagnosticHandler(.{
        .context = &recorder,
        .handle = Recorder.handle,
    });

    var diagnostic = op.emitError("bad operation");
    defer diagnostic.deinit();
    try diagnostic.attachNote("inherits primary location");
    try diagnostic.attachNoteAt(note_loc, "uses explicit location");
    try diagnostic.addMetadata("dialect", "choir.test");

    const result = try diagnostic.emit();
    try testing.expectEqual(HandlerResult.consumed, result);
    try testing.expectEqual(@as(usize, 1), recorder.seen);
    try testing.expectEqual(Severity.err, recorder.severity);
    try testing.expectEqualStrings("bad operation", recorder.message);
    try testing.expectEqual(@as(usize, 2), recorder.note_count);
    try testing.expect(recorder.first_note_location.eql(loc));
    try testing.expectEqualStrings("inherits primary location", recorder.first_note_message);
    try testing.expect(recorder.second_note_location.eql(note_loc));
    try testing.expectEqualStrings("dialect", recorder.metadata_name);
    try testing.expectEqualStrings("choir.test", recorder.metadata_value);
    try testing.expectError(error.DiagnosticAlreadyEmitted, diagnostic.attachNote("too late"));
}

test "Context diagnostic engine receives Operation emit helpers" {
    const testing = std.testing;
    const loc = ir.Location.getFile("emit.tiny", 3, 5);

    const Recorder = struct {
        seen: usize = 0,
        severity: Severity = .note,
        message: []const u8 = "",
        op_name: []const u8 = "",
        location: ir.Location = ir.Location.getUnknown(),

        fn handle(context: ?*anyopaque, diagnostic: *const Diagnostic) !HandlerResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.seen += 1;
            self.severity = diagnostic.severity;
            self.message = diagnostic.message;
            self.op_name = diagnostic.operationName().?;
            self.location = diagnostic.location;
            return .consumed;
        }
    };

    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const op = try ctx.createOperation(ir.Operation.State.init("test.emit", loc));

    var recorder = Recorder{};
    const handler_id = try ctx.registerDiagnosticHandler(.{
        .context = &recorder,
        .handle = Recorder.handle,
    });

    var diagnostic = op.emitError("bad operation");
    defer diagnostic.deinit();
    const result = try diagnostic.emit();
    try testing.expectEqual(HandlerResult.consumed, result);
    try testing.expectEqual(@as(usize, 1), recorder.seen);
    try testing.expectEqual(Severity.err, recorder.severity);
    try testing.expectEqualStrings("bad operation", recorder.message);
    try testing.expectEqualStrings("test.emit", recorder.op_name);
    try testing.expect(recorder.location.eql(loc));

    var remark_diagnostic = op.emitRemark("reviewed operation");
    defer remark_diagnostic.deinit();
    const remark = try remark_diagnostic.emit();
    try testing.expectEqual(HandlerResult.consumed, remark);
    try testing.expectEqual(Severity.remark, recorder.severity);

    ctx.eraseDiagnosticHandler(handler_id);
    var warning_diagnostic = op.emitWarning("unhandled warning");
    defer warning_diagnostic.deinit();
    const propagated = try warning_diagnostic.emit();
    try testing.expectEqual(HandlerResult.propagate, propagated);
    try testing.expectEqual(@as(usize, 2), recorder.seen);
}

test "Operation emitOpError prefixes the operation name" {
    const testing = std.testing;
    const loc = ir.Location.getName("op error", null);

    const Recorder = struct {
        message: []const u8 = "",

        fn handle(context: ?*anyopaque, diagnostic: *const Diagnostic) !HandlerResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.message = diagnostic.message;
            return .consumed;
        }
    };

    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const op = try ctx.createOperation(ir.Operation.State.init("test.prefixed", loc));

    var recorder = Recorder{};
    _ = try ctx.registerDiagnosticHandler(.{
        .context = &recorder,
        .handle = Recorder.handle,
    });

    var diagnostic = try op.emitOpError("requires one operand");
    defer diagnostic.deinit();
    try testing.expectEqual(HandlerResult.consumed, try diagnostic.emit());
    try testing.expectEqualStrings("'test.prefixed' op requires one operand", recorder.message);
}

test "Choir named parse localizes a verifier failure and preserves its dump" {
    const testing = std.testing;
    const dialects = @import("../dialects/root.zig");
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ir.dialects.loadDialectSpec(&ctx, dialects.BuiltinDialect.spec);
    try ir.dialects.loadDialectSpec(&ctx, dialects.arith.spec);
    try ir.dialects.loadDialectSpec(&ctx, dialects.ScfDialect.spec);
    const text =
        \\builtin.module() {
        \\  ^bb0(%0: !arith.index):
        \\    %1 = arith.constant() {value = 0.0:f64}: !arith.f64
        \\    %7 = scf.for(%0, %0, %0, %1): !arith.f64 {
        \\      ^bb1(%4: !arith.index, %5: !arith.f64):
        \\        scf.yield(%0)
        \\    }
        \\}
        \\
    ;
    const name = "/tmp/tiny-d1-location-probe/wrong.choir";
    const parsed = try ir.parse.source(&ctx, .{ .name = name, .text = text });
    defer parsed.erase();
    const expected_dump =
        \\builtin.module() {
        \\  ^bb0(%0: !arith.index):
        \\    %1 = arith.constant() {value = 0:f64} : !arith.f64
        \\    %2 = scf.for(%0, %0, %0, %1) : !arith.f64 {
        \\      ^bb0(%3: !arith.index, %4: !arith.f64):
        \\        scf.yield(%0)
        \\    }
        \\}
        \\
    ;
    const dumped = try ir.dump.operationAlloc(testing.allocator, parsed);
    defer testing.allocator.free(dumped);
    try testing.expectEqualStrings(expected_dump, dumped);
    const reparsed = try ir.parse.operation(&ctx, dumped);
    defer reparsed.erase();
    const redumped = try ir.dump.operationAlloc(testing.allocator, reparsed);
    defer testing.allocator.free(redumped);
    try testing.expectEqualStrings(dumped, redumped);

    try testing.expectError(
        error.ScfForYieldTypeMismatch,
        ir.verify.verifyOperation(parsed, ir.verify.default_options),
    );
    const failure = captureVerifierFailure(
        "ir.verify.verifyOperation",
        parsed,
        ir.verify.default_options,
        error.ScfForYieldTypeMismatch,
    );
    try testing.expectEqualStrings("scf.for", failure.operation.name.name);
    try testing.expect(failure.location == .file_range);
    const range = failure.location.file_range;
    try testing.expectEqualStrings(name, range.filename);
    try testing.expectEqual(@as(u32, 4), range.start.line);
    try testing.expectEqual(@as(u32, 5), range.start.column);
    try testing.expectEqualStrings(
        "%7 = scf.for(%0, %0, %0, %1): !arith.f64 {",
        text[range.start.byte..range.end.byte],
    );
    try testing.expectEqual(@as(u32, 4), range.end.line);
    try testing.expectEqual(@as(u32, 47), range.end.column);
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "Choir verifier failed (ir.verify.verifyOperation): op=scf.for " ++
            "loc(\"/tmp/tiny-d1-location-probe/wrong.choir\":4:5) " ++
            "error=ScfForYieldTypeMismatch",
        failure.format(&buffer),
    );
}
