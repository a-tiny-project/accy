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
        // A verifier that could not buy memory has not checked the module, so the module is not
        // the thing to blame: the shortfall answers as one, with no diagnostic against the IR.
        if (err == error.OutOfMemory) return BackendError.OutOfMemory;
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
