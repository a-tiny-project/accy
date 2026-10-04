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
const value = @import("value.zig");
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
};

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
/// - `prepare(ctx)`: loads what `lower` needs into the module's context.
/// - `lower(allocator, module)`: rewrites and checks the whole module before any emission.
/// - `emit(compiler, func)`: emits one function, borrowed until `discard`.
/// - `takeLineTable(compiler)`, `failedOperation(compiler)`, `discard(compiler)`.
/// - `recordLines(compiler, on)`: whether `emit` records a line table, from here on.
/// - `takeCode(compiler)`: the last emitted function's code, which the caller owns from here
///   on, allocated by the allocator `initCompiler` took.
/// - `report(failure)`: one located error diagnostic.
/// - `admitsSignature(signature)`: whether the target passes and returns every type in it.
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
        expect(T, "initCompiler", fn (Allocator) T.Compiler);
        expect(T, "deinitCompiler", fn (*T.Compiler) void);
        expect(T, "prepare", fn (*ir.Context) Allocator.Error!void);
        expect(T, "lower", fn (Allocator, *ir.Operation) LowerError!void);
        expect(T, "emit", fn (*T.Compiler, *ir.Operation) T.EmitError!image.Emitted);
        expect(T, "takeLineTable", fn (*T.Compiler) Allocator.Error!debug_info.LineTable);
        expect(T, "recordLines", fn (*T.Compiler, bool) void);
        expect(T, "takeCode", fn (*T.Compiler) Allocator.Error![]u8);
        expect(T, "failedOperation", fn (*const T.Compiler) ?*ir.Operation);
        expect(T, "discard", fn (*T.Compiler) void);
        expect(T, "report", fn (Failure) void);
        expect(T, "admitsSignature", fn (*const Signature) bool);
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
        pub const Compiler = struct {};
        pub const EmitError = error{};

        pub fn builtin(_: usize) Builtin {
            unreachable;
        }
        pub fn initCompiler(_: Allocator) Compiler {
            unreachable;
        }
        pub fn deinitCompiler(_: *Compiler) void {
            unreachable;
        }
        pub fn prepare(_: *ir.Context) Allocator.Error!void {
            unreachable;
        }
        pub fn lower(_: Allocator, _: *ir.Operation) LowerError!void {
            unreachable;
        }
        pub fn emit(_: *Compiler, _: *ir.Operation) EmitError!image.Emitted {
            unreachable;
        }
        pub fn takeLineTable(_: *Compiler) Allocator.Error!debug_info.LineTable {
            unreachable;
        }
        pub fn recordLines(_: *Compiler, _: bool) void {}
        pub fn takeCode(_: *Compiler) Allocator.Error![]u8 {
            unreachable;
        }
        pub fn failedOperation(_: *const Compiler) ?*ir.Operation {
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

test "an unavailable target satisfies the contract and carries its reason" {
    const why = "no execution target exists for this host";
    const Target = Unavailable(why);
    comptime assertTarget(Target);
    try std.testing.expectEqualStrings(why, Target.unavailable.?);
}
