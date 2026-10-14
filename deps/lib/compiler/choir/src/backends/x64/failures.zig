//! Located error diagnostics for x86_64 emission and call resolution.

const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const diagnostics = @import("../../root.zig").diagnostics;
const abi = @import("abi.zig");
const Excess = @import("../execution/bounds.zig").Excess;

const message_capacity = 256;

/// The x86_64 stage a failure belongs to.
pub const Stage = enum {
    /// Lowering one function to machine code.
    emit,
    /// Resolving a module's calls before its code is mapped.
    link,

    /// Returns the value recorded as `choir.stage` metadata.
    pub fn name(self: Stage) []const u8 {
        return switch (self) {
            .emit => "backend/x86_64/emit",
            .link => "backend/x86_64/link",
        };
    }
};

/// An error, the stage that raised it, and the operation it is located at.
pub const Failure = struct {
    stage: Stage,
    operation: *ir.Operation,
    err: anyerror,
    /// The symbol that no definition provides. Set exactly when `stage` is `.link`.
    symbol: ?[]const u8 = null,
    /// The bound the emitter refused past, with its figures. Set exactly when `namesBound(err)`.
    excess: ?Excess = null,

    /// Whether `err` is a refusal against one of the target's bounds, which carries an `Excess`.
    pub fn namesBound(err: anyerror) bool {
        return err == error.FrameTooLarge or err == error.TooManyWhileValues or
            err == error.TooManyResults or err == error.TooManyArguments;
    }

    /// Reports one error diagnostic located at `operation`, with `choir.stage` and `choir.error`
    /// metadata, and `choir.bound` when it refused past a bound. Reports nothing for
    /// `error.OutOfMemory`.
    pub fn report(self: Failure) void {
        std.debug.assert((self.stage == .link) == (self.symbol != null));
        std.debug.assert(namesBound(self.err) == (self.excess != null));
        if (self.err == error.OutOfMemory) return;
        var buffer: [message_capacity]u8 = undefined;
        var in_flight = self.operation.emitError(self.message(&buffer));
        defer in_flight.deinit();
        in_flight.addMetadata("choir.stage", self.stage.name()) catch {};
        in_flight.addMetadata("choir.error", @errorName(self.err)) catch {};
        if (self.excess) |excess| in_flight.addMetadata("choir.bound", @tagName(excess.bound)) catch {};
        _ = in_flight.emit() catch {};
    }

    fn message(self: Failure, buffer: []u8) []const u8 {
        const error_name = @errorName(self.err);
        if (self.stage == .link) {
            return std.fmt.bufPrint(buffer, link_format, .{self.symbol.?}) catch link_fallback;
        }
        if (self.excess) |excess| {
            if (excess.bound == .frame_bytes) {
                const figures = .{ excess.asked(), excess.limit, excess.held, excess.requested };
                return std.fmt.bufPrint(buffer, frame_format, figures) catch frame_fallback;
            }
            return std.fmt.bufPrint(buffer, bound_format, .{ excess, error_name }) catch
                bound_fallback;
        }
        if (ir.inspection.isFunctionDefinition(self.operation)) {
            return std.fmt.bufPrint(buffer, function_format, .{error_name}) catch function_fallback;
        }
        return std.fmt.bufPrint(buffer, operation_format, .{error_name}) catch operation_fallback;
    }
};

const operation_format = "x86_64 emission failed at this operation with error.{s}";
const operation_fallback = "x86_64 emission failed at this operation";
const function_format = "x86_64 emission failed for this function with error.{s}";
const function_fallback = "x86_64 emission failed for this function";
const link_format = "x86_64 found no function in the module and no registered external symbol " ++
    "named {s}";
const link_fallback = "x86_64 found no function in the module and no registered external symbol";
const frame_format = "x86_64 refused a frame of {d} bytes below rbp, past the {d} that signed " ++
    "32-bit displacements address; it held {d} bytes and asked for {d} more " ++
    "(error.FrameTooLarge)";
const frame_fallback = "x86_64 cannot address this function's frame (error.FrameTooLarge)";
const bound_format = "x86_64 refused {f} (error.{s})";
const bound_fallback = "x86_64 refused a construct past one of its bounds";

fn metadataValue(diagnostic: *const diagnostics.Diagnostic, name: []const u8) ?[]const u8 {
    for (diagnostic.metadata) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}
