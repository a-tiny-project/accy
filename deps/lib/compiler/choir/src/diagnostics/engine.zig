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
