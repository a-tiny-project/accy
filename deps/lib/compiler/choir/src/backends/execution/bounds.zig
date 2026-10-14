//! The program bounds an execution target declares, and the record a refusal against one carries.
//!
//! A bound is a property of the program and not memory a caller buys: no runtime limit raises it,
//! and a function past one is refused when it is lowered or emitted. A consumer that refuses a
//! larger program in its own words reads the figure here rather than copying the backend's
//! constant, so the two cannot drift. A refusal names its bound and carries the limit, what the
//! program already held on that axis, and what the refused step asked for, so a reader can state
//! how far over the program went without parsing a message.

const std = @import("std");
const ir = @import("../../core/root.zig");

/// Every axis a target may bound. Each tag names exactly one field of `Bounds`.
pub const Bound = enum {
    /// Values one `scf.while` carries: its operands, each region's block arguments, and its
    /// results.
    while_values,
    /// Results one `scf.if` or `scf.for` yields.
    yielded_values,
    /// Parameters one function the target defines takes.
    parameters,
    /// Arguments one call passes. A call to an external symbol follows the platform convention,
    /// which can pass more than the target records for a function it defines.
    call_arguments,
    /// Results one function, call, or return carries.
    results,
    /// Operations in one function's body, nested operations included and regions not counted.
    operations,
    /// Values one function's body defines: operation results, and the block arguments of its
    /// structured control.
    values,
    /// Structured control constructs open inside one another.
    control_depth,
    /// Bytes one function's frame holds below its frame pointer: spilled values, static
    /// allocations, and call reservations. How many a function needs depends on the target's
    /// register allocation, so a consumer reads this as the capacity a refusal names, not as a
    /// count it can make itself.
    frame_bytes,
    /// Arguments one `func.syscall` passes beside its number.
    syscall_arguments,
    /// Functions one module defines whose direct calls the target resolves.
    module_functions,

    /// What the figure counts, so a message reads as a sentence.
    pub fn counts(self: Bound) []const u8 {
        return switch (self) {
            .while_values => "values one scf.while carries",
            .yielded_values => "results one scf.if or scf.for yields",
            .parameters => "parameters one function takes",
            .call_arguments => "arguments one call passes",
            .results => "results one function, call, or return carries",
            .operations => "operations in one function's body",
            .values => "values one function's body defines",
            .control_depth => "structured control constructs open inside one another",
            .frame_bytes => "bytes one function's frame holds",
            .syscall_arguments => "arguments one func.syscall passes beside its number",
            .module_functions => "functions one module defines with direct calls",
        };
    }
};

/// What one function, or for `module_functions` one module, may hold for a target to lower and
/// emit it. A null field is an axis the target does not count, which only the runtime's memory
/// limits bound.
pub const Bounds = struct {
    while_values: ?u64,
    yielded_values: ?u64,
    parameters: ?u64,
    call_arguments: ?u64,
    results: ?u64,
    operations: ?u64,
    values: ?u64,
    control_depth: ?u64,
    frame_bytes: ?u64,
    syscall_arguments: ?u64,
    module_functions: ?u64,

    comptime {
        const fields = @typeInfo(Bounds).@"struct".field_names;
        const tags = @typeInfo(Bound).@"enum".field_names;
        if (fields.len != tags.len) @compileError("Bounds holds a field per Bound and no more");
        for (tags, fields) |tag, field| {
            if (!std.mem.eql(u8, tag, field))
                @compileError("Bounds." ++ field ++ " is not Bound." ++ tag);
        }
    }

    /// The bounds of a target that emits nothing.
    pub const none: Bounds = .{
        .while_values = 0,
        .yielded_values = 0,
        .parameters = 0,
        .call_arguments = 0,
        .results = 0,
        .operations = 0,
        .values = 0,
        .control_depth = 0,
        .frame_bytes = 0,
        .syscall_arguments = 0,
        .module_functions = 0,
    };

    /// The figure for `bound`, or null when the target does not count it.
    pub fn limit(self: Bounds, bound: Bound) ?u64 {
        return switch (bound) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }

    /// The excess when a program holding `held` on `bound` asks for `requested` more, or null
    /// when the grown figure fits or the target does not count the axis.
    pub fn excess(self: Bounds, bound: Bound, held: u64, requested: u64) ?Excess {
        const figure = self.limit(bound) orelse return null;
        return Excess.of(bound, figure, held, requested);
    }
};

/// A refusal against one bound: which bound, its figure, what the program held on that axis when
/// the refused step came, and what that step asked for.
///
/// A count the target takes whole, such as the values one while carries, is held 0 and
/// requested the count. A count the target accumulates, such as the values a body defines, is
/// held what it had and requested what the refused step adds.
pub const Excess = struct {
    bound: Bound,
    limit: u64,
    held: u64,
    requested: u64,

    /// The figure the refused step would have made, saturating rather than wrapping. A target
    /// that counts in units wider than one, such as frame slots, may also saturate `requested`
    /// when it converts, so a requested or asked figure at `maxInt(u64)` is a lower bound.
    pub fn asked(self: Excess) u64 {
        return self.held +| self.requested;
    }

    /// The excess when `held` grows by `requested` past `limit`, or null when it fits.
    pub fn of(bound: Bound, limit: u64, held: u64, requested: u64) ?Excess {
        const excess: Excess = .{ .bound = bound, .limit = limit, .held = held, .requested = requested };
        const grown = std.math.add(u64, held, requested) catch return excess;
        return if (grown > limit) excess else null;
    }

    /// Writes "<asked> <counts>, past the <limit> <target> holds; it held <held> and asked for
    /// <requested> more", the sentence every target's diagnostic carries.
    pub fn format(self: Excess, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d} {s}, past the {d} the target holds; it held {d} and asked for {d} more", .{
            self.asked(),
            self.bound.counts(),
            self.limit,
            self.held,
            self.requested,
        });
    }
};

/// Where a target's lowering refused a module, and the bound it refused past when it refused past
/// one. A target fills it before failing `lower`. A null operation locates the refusal at the
/// module, and an excess is set exactly when the refusal names a bound.
pub const Refused = struct {
    operation: ?*ir.Operation = null,
    excess: ?Excess = null,
};
