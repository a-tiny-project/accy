//! What a target supplies to `Runtime`, checked exactly at compile time.
//!
//! A target owns what differs by instruction set and calling convention: preparing a context,
//! lowering and legality, emitting one function, reporting a located failure, which signatures
//! it passes and returns, patching one absolute address, the artifact identity it loads, and
//! entering code. `Runtime` owns everything else: staging, linking, publication and rollback,
//! handles and generations, limits, external symbols, lookup, the call check, and artifact
//! validation.

const std = @import("std");
const ir = @import("../../core/root.zig");
const backends = @import("../root.zig");
const artifact = backends.artifact;
const debug_info = backends.debug_info;
const image = @import("image.zig");
const machine = backends.machine_code;
const value = @import("value.zig");
const bound_set = @import("bounds.zig");
const sys = @import("sys");

const Allocator = std.mem.Allocator;
const Signature = artifact.Signature;

/// The errors lowering may give. Each keeps the meaning `backends.interface.BackendError` gives
/// it.
pub const LowerError = error{
    OutOfMemory,
    VerificationFailed,
    UnsupportedOperation,
    CodeGenFailed,
};

/// A name the runtime binds for every module before the host registers its own.
pub const Builtin = struct {
    name: []const u8,
    address: usize,
};

/// The stage a located failure belongs to.
pub const Stage = enum {
    /// Rewriting and checking the whole module, before any function is emitted. The target's
    /// `lower` reports its own diagnostic, so `report` is never given this stage.
    lower,
    /// Lowering one function to machine code.
    emit,
    /// Resolving a module's calls before its code is mapped.
    link,
};

/// An error, the stage that raised it, and the operation it is located at.
pub const Failure = struct {
    stage: Stage,
    operation: *ir.Operation,
    err: anyerror,
    /// The symbol that no definition provides. Set exactly when `stage` is `.link`.
    symbol: ?[]const u8 = null,
    /// The bound the failure refused past, with its figures. Set exactly when the refused
    /// operation is past one of the target's `bounds`, whatever error names the stage.
    excess: ?Excess = null,
};

pub const Bound = bound_set.Bound;
pub const Bounds = bound_set.Bounds;
pub const Excess = bound_set.Excess;
pub const Refused = bound_set.Refused;

/// Fails compilation unless `T` declares every member below with exactly this type. Checking
/// types rather than names makes a changed hook a compile error here, naming the target, instead
/// of one inside a generic runtime body.
///
/// - `unavailable: ?[]const u8`: null for a target that executes, or why this host cannot.
/// - `architecture: artifact.Architecture` and `abi: artifact.Abi`: the identity a loaded
///   machine-code artifact must carry.
/// - `relocation_bytes: usize`: the width of the absolute address `patch` writes.
/// - `allowsSerializedArtifact: bool`: whether `loadArtifact` accepts serialized code.
/// - `executable_policy: sys.memory.ExecutablePolicy`: the qualified product's publication
///   contract, not a policy inferred from the host instruction set.
/// - `builtin_count: usize` and `builtin(index) Builtin`: names bound at `Runtime.init`.
/// - `Compiler`, `EmitError`, `initCompiler`, `deinitCompiler`: one function's emission state,
///   retained across compiles.
/// - `Scratch`: what one emit works in and nothing reads after it. `initCompiler(allocator,
///   scratch)` borrows `scratch` when the host lends one, which no two compilers emitting at
///   once may share, and allocates its own when the host passes null.
/// - `prepare(ctx)`: loads what `lower` needs into the module's context.
/// - `lower(allocator, module, refused)`: rewrites and checks the whole module before any
///   emission. On failure other than `error.OutOfMemory`, `refused` locates the refusal and
///   carries the bound it refused past, so the runtime reports it as `emit` reports its own.
/// - `emit(compiler, func)`: emits one function, borrowed until `discard`.
/// - `takeLineTable(compiler)`, `failedOperation(compiler)`, `discard(compiler)`.
/// - `failedExcess(compiler)`: the bound the last failed `emit` refused past, or null when it
///   refused none.
/// - `shareImage(compiler, functions)`: the functions whose code lands in the same mapping as
///   what `emit` emits next, which a call may reach by a 32-bit displacement, or null for none.
///   The set is borrowed until the next `shareImage`.
/// - `recordLines(compiler, on)`: whether `emit` records a line table, from here on.
/// - `placeValues(compiler, on)`: whether `emit` places values, from here on, or
///   `error.FrameOnlyUnsupported` for a target that emits no frame-only code.
/// - `takeCode(compiler)`: the last emitted function's code, which the caller owns from here
///   on, allocated by the allocator `initCompiler` took.
/// - `report(failure)`: one located error diagnostic.
/// - `admitsSignature(signature)`: whether the target passes and returns every type in it.
/// - `bounds: Bounds`: what one function may hold for `emit` to accept it.
/// - `patch(code, offset, address)`: writes one absolute address.
/// - `enter(address, signature, args, results)`: calls code whose arguments `value.check`
///   accepted.
pub fn assertTarget(comptime T: type) void {
    comptime {
        expect(T, "unavailable", ?[]const u8);
        expect(T, "architecture", artifact.Architecture);
        expect(T, "abi", artifact.Abi);
        expect(T, "relocation_bytes", usize);
        expect(T, "allowsSerializedArtifact", bool);
        expect(T, "executable_policy", sys.memory.ExecutablePolicy);
        expect(T, "builtin_count", usize);
        expect(T, "builtin", fn (usize) Builtin);
        expect(T, "Compiler", type);
        expect(T, "EmitError", type);
        if (@typeInfo(T.EmitError) != .error_set)
            @compileError(@typeName(T) ++ ".EmitError is no error set");
        expect(T, "Scratch", type);
        expect(T, "initCompiler", fn (Allocator, ?*T.Scratch) Allocator.Error!T.Compiler);
        expect(T, "deinitCompiler", fn (*T.Compiler) void);
        expect(T, "prepare", fn (*ir.Context) Allocator.Error!void);
        expect(T, "lower", fn (Allocator, *ir.Operation, *Refused) LowerError!void);
        expect(T, "emit", fn (*T.Compiler, *ir.Operation) T.EmitError!image.Emitted);
        expect(T, "takeLineTable", fn (*T.Compiler) Allocator.Error!debug_info.LineTable);
        expect(T, "shareImage", fn (*T.Compiler, ?*const machine.ImageFunctions) void);
        expect(T, "recordLines", fn (*T.Compiler, bool) void);
        expect(T, "placeValues", fn (*T.Compiler, bool) error{FrameOnlyUnsupported}!void);
        expect(T, "takeCode", fn (*T.Compiler) Allocator.Error![]u8);
        expect(T, "failedOperation", fn (*const T.Compiler) ?*ir.Operation);
        expect(T, "failedExcess", fn (*const T.Compiler) ?Excess);
        expect(T, "discard", fn (*T.Compiler) void);
        expect(T, "report", fn (Failure) void);
        expect(T, "admitsSignature", fn (*const Signature) bool);
        expect(T, "bounds", Bounds);
        expect(T, "patch", fn ([]u8, usize, u64) void);
        expect(T, "enter", fn (usize, *const Signature, []const value.Value, []value.Value) void);
        if (T.relocation_bytes == 0 or T.relocation_bytes > @sizeOf(u64))
            @compileError(@typeName(T) ++ ".relocation_bytes must be 1 to 8");
    }
}

fn expect(comptime T: type, comptime name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(T, name)) @compileError(@typeName(T) ++ " declares no " ++ name);
    const Actual = @TypeOf(@field(T, name));
    if (Actual != Expected)
        @compileError(@typeName(T) ++ "." ++ name ++ " is " ++ @typeName(Actual) ++ ", not " ++
            @typeName(Expected));
}

/// A target for a host that cannot execute, carrying `why`. It satisfies `assertTarget` so every
/// runtime entry type-checks on every host. `Runtime.init` refuses before any hook can run, so no
/// runtime of this target exists and each hook is unreachable.
pub fn Unavailable(comptime why: []const u8) type {
    return struct {
        pub const unavailable: ?[]const u8 = why;
        pub const architecture: artifact.Architecture = .unknown;
        pub const abi: artifact.Abi = .{};
        pub const relocation_bytes: usize = 8;
        pub const allowsSerializedArtifact: bool = false;
        pub const executable_policy: sys.memory.ExecutablePolicy = .unverified;
        pub const builtin_count: usize = 0;
        pub const bounds: Bounds = .none;
        pub const Compiler = struct {};
        pub const Scratch = struct {};
        pub const EmitError = error{};

        pub fn builtin(_: usize) Builtin {
            unreachable;
        }
        pub fn initCompiler(_: Allocator, _: ?*Scratch) Allocator.Error!Compiler {
            unreachable;
        }
        pub fn deinitCompiler(_: *Compiler) void {
            unreachable;
        }
        pub fn prepare(_: *ir.Context) Allocator.Error!void {
            unreachable;
        }
        pub fn lower(_: Allocator, _: *ir.Operation, _: *Refused) LowerError!void {
            unreachable;
        }
        pub fn emit(_: *Compiler, _: *ir.Operation) EmitError!image.Emitted {
            unreachable;
        }
        pub fn takeLineTable(_: *Compiler) Allocator.Error!debug_info.LineTable {
            unreachable;
        }
        pub fn shareImage(_: *Compiler, _: ?*const machine.ImageFunctions) void {}
        pub fn recordLines(_: *Compiler, _: bool) void {}
        pub fn placeValues(_: *Compiler, _: bool) error{FrameOnlyUnsupported}!void {
            unreachable;
        }
        pub fn takeCode(_: *Compiler) Allocator.Error![]u8 {
            unreachable;
        }
        pub fn failedOperation(_: *const Compiler) ?*ir.Operation {
            unreachable;
        }
        pub fn failedExcess(_: *const Compiler) ?Excess {
            unreachable;
        }
        pub fn discard(_: *Compiler) void {
            unreachable;
        }
        pub fn report(_: Failure) void {
            unreachable;
        }
        pub fn admitsSignature(_: *const Signature) bool {
            unreachable;
        }
        pub fn patch(_: []u8, _: usize, _: u64) void {
            unreachable;
        }
        pub fn enter(_: usize, _: *const Signature, _: []const value.Value, _: []value.Value) void {
            unreachable;
        }
    };
}
