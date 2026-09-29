const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");
const diagnostics = @import("../root.zig").diagnostics;
const interface = @import("interface.zig");

const BackendError = interface.BackendError;

pub fn verifyModule(stage: []const u8, module: *ir.Operation) BackendError!void {
    return verifyModuleWithOptions(stage, module, ir.verify.default_options);
}

pub const VerificationDiagnostic = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,
    failure: ?diagnostics.VerifierFailure = null,

    pub fn set(self: *VerificationDiagnostic, message: []const u8) void {
        self.len = @min(message.len, self.buffer.len);
        @memcpy(self.buffer[0..self.len], message[0..self.len]);
        self.failure = null;
    }

    pub fn capture(
        self: *VerificationDiagnostic,
        stage: []const u8,
        module: *ir.Operation,
        options: ir.VerifyOptions,
        err: anyerror,
    ) void {
        self.setFailure(diagnostics.captureVerifierFailure(stage, module, options, err));
    }

    pub fn setFailure(self: *VerificationDiagnostic, failure: diagnostics.VerifierFailure) void {
        self.failure = failure;
        const message = self.failure.?.format(&self.buffer);
        if (message.ptr == self.buffer[0..].ptr) {
            self.len = message.len;
        } else {
            self.set(message);
        }
    }

    pub fn text(self: *const VerificationDiagnostic) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn hasText(self: *const VerificationDiagnostic) bool {
        return self.len != 0;
    }

    pub fn diagnostic(self: *const VerificationDiagnostic) ?diagnostics.Diagnostic {
        const failure = self.failure orelse return null;
        return failure.diagnostic();
    }
};

pub fn verifyModuleWithOptions(
    stage: []const u8,
    module: *ir.Operation,
    options: ir.VerifyOptions,
) BackendError!void {
    return verifyModuleWithOptionsAndDiagnostic(stage, module, options, null);
}

pub fn verifyModuleWithDiagnostic(
    stage: []const u8,
    module: *ir.Operation,
    diagnostic: ?*VerificationDiagnostic,
) BackendError!void {
    return verifyModuleWithOptionsAndDiagnostic(stage, module, ir.verify.default_options, diagnostic);
}

pub fn verifyModuleWithOptionsAndDiagnostic(
    stage: []const u8,
    module: *ir.Operation,
    options: ir.VerifyOptions,
    diagnostic: ?*VerificationDiagnostic,
) BackendError!void {
    ir.verifyOperation(module, options) catch |err| {
        const failure = diagnostics.captureVerifierFailure(stage, module, options, err);
        if (diagnostic) |captured| captured.setFailure(failure);
        var in_flight = module.getContext().emitDiagnostic(failure.diagnostic());
        defer in_flight.deinit();
        in_flight.attachNoteAt(failure.root.getLoc(), "verifier root operation") catch {};
        in_flight.addMetadata("choir.stage", failure.stage) catch {};
        in_flight.addMetadata("choir.error", @errorName(failure.err)) catch {};
        _ = in_flight.emit() catch {};
        return BackendError.VerificationFailed;
    };
}

/// Loads the arith dialect that backend lowering builds operations from.
/// An activated context that lacks it stays usable, and lowering fails later if it needs arith.
/// Fails with `error.OutOfMemory` when the load cannot allocate.
pub fn loadArithDialect(ctx: *ir.Context) std.mem.Allocator.Error!void {
    const dialects = @import("../dialects/root.zig");
    ir.dialects.loadDialectSpec(ctx, dialects.arith.spec) catch |err| switch (err) {
        error.ContextFrozen => {},
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("loading the arith dialect failed: {s}", .{@errorName(err)}),
    };
}

test "verifyModuleWithOptionsAndDiagnostic captures verifier detail" {
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
    try @import("../dialects/root.zig").registerAllDialects(&ctx);
    try ir.dialects.loadDialectSpec(&ctx, dialects.arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    const bool_type = try ArithDialect.getScalarType(&ctx, .bool);

    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ctx, loc, "bad_cmp", &.{}, &.{bool_type});
    try module_block.addOperation(func.op);

    const entry_block = func.getEntryBlock();
    var left = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    try entry_block.addOperation(left.op);
    var right = try ArithDialect.ConstantOp.createInt(&ctx, loc, i64_type, 2);
    try entry_block.addOperation(right.op);
    const bad_cmp = try ArithDialect.CmpOp.create(&ctx, loc, .eq, left.getResult(), right.getResult());
    try entry_block.addOperation(bad_cmp.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{bad_cmp.getResult()});
    try entry_block.addOperation(ret.op);

    const Recorder = struct {
        seen: usize = 0,
        op_name: []const u8 = "",
        error_name: []const u8 = "",
        stage: []const u8 = "",
        note_count: usize = 0,

        fn handle(context: ?*anyopaque, diagnostic: *const diagnostics.Diagnostic) !diagnostics.HandlerResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.seen += 1;
            self.op_name = diagnostic.operationName().?;
            self.error_name = diagnostic.error_name.?;
            self.note_count = diagnostic.notes.len;
            for (diagnostic.metadata) |metadata| {
                if (std.mem.eql(u8, metadata.name, "choir.stage")) {
                    self.stage = metadata.value;
                }
            }
            return .consumed;
        }
    };

    var recorder = Recorder{};
    _ = try ctx.registerDiagnosticHandler(.{
        .context = &recorder,
        .handle = Recorder.handle,
    });

    var captured: VerificationDiagnostic = .{};
    try testing.expectError(
        BackendError.VerificationFailed,
        verifyModuleWithOptionsAndDiagnostic(
            "backend/test/verify",
            module.op,
            ir.verify.default_options,
            &captured,
        ),
    );
    try testing.expect(captured.hasText());
    try testing.expect(std.mem.indexOf(u8, captured.text(), "backend/test/verify") != null);
    try testing.expect(std.mem.indexOf(u8, captured.text(), "arith.cmp") != null);
    const diagnostic = captured.diagnostic() orelse return error.TestExpectedResult;
    try testing.expectEqual(diagnostics.Severity.err, diagnostic.severity);
    try testing.expectEqual(bad_cmp.op, diagnostic.operation.?);
    try testing.expectEqualStrings("SameTypeOperandsMismatch", diagnostic.error_name.?);
    try testing.expectEqual(@as(usize, 1), recorder.seen);
    try testing.expectEqualStrings("arith.cmp", recorder.op_name);
    try testing.expectEqualStrings("SameTypeOperandsMismatch", recorder.error_name);
    try testing.expectEqualStrings("backend/test/verify", recorder.stage);
    try testing.expectEqual(@as(usize, 1), recorder.note_count);
}
