//! The x86_64 execution target: System V code on Linux and macOS, run through
//! `execution.Runtime`.

const std = @import("std");
const profile = @import("sys").capabilities.current;
const executes = (profile.os == .linux or profile.os == .macos) and
    profile.arch == .x86_64 and profile.pointerWidthBits() == 64;
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const backends = @import("../root.zig");
const artifact = backends.artifact;
const contract = backends.contract;
const debug_info = backends.debug_info;
const execution = @import("../execution/root.zig");
const fixture = @import("../execution/fixture/root.zig");
const machine = backends.machine_code;
const sys = @import("sys");
const diagnostics = @import("../../root.zig").diagnostics;
const sysv = @import("abi.zig");
const backend = @import("backend.zig");
const emission = @import("emit.zig");
const target_bounds = @import("bounds.zig");
const failures = @import("failures.zig");
const invoke = @import("invoke.zig");
const legality = @import("legality.zig");

const Allocator = std.mem.Allocator;
const Signature = artifact.Signature;

/// The hooks `execution.assertTarget` names, for x86_64 System V.
pub const Target = struct {
    pub const unavailable: ?[]const u8 = null;
    pub const architecture: artifact.Architecture = .x86_64;
    pub const abi: artifact.Abi = .{
        .name = "sysv",
        .calling_convention = "c",
        .pointer_width_bits = 64,
        .endianness = .little,
    };
    /// Calls and data addresses are 8-byte absolute windows in `movabs` immediates.
    pub const relocation_bytes: usize = 8;
    pub const allowsSerializedArtifact: bool = true;
    /// Linux's established publication. On macOS the product declares the non-hardened policy,
    /// so ordinary `init` there refuses until the caller does, as on Apple silicon.
    pub const executable_policy: sys.memory.ExecutablePolicy = if (profile.os == .macos)
        .macos_non_hardened
    else
        .linux;
    /// `malloc` and `free`, which memref allocation calls, then the math library.
    pub const builtin_count: usize = 2 + sys.math.symbols.len;
    pub const bounds: execution.Bounds = target_bounds.bounds;
    pub const Compiler: type = emission.Emitter;
    pub const EmitError: type = @typeInfo(emit_result).error_union.error_set;
    const emit_result = @typeInfo(@TypeOf(emission.Emitter.emitFunction)).@"fn".return_type.?;

    pub fn builtin(index: usize) execution.Builtin {
        std.debug.assert(index < builtin_count);
        return switch (index) {
            0 => .{ .name = "malloc", .address = @intFromPtr(&sys.heap.malloc) },
            1 => .{ .name = "free", .address = @intFromPtr(&sys.heap.free) },
            else => .{
                .name = sys.math.symbols[index - 2].name(),
                .address = sys.math.symbols[index - 2].address(),
            },
        };
    }

    /// The x86_64 emitter works in what it allocates itself, so a host has nothing to lend it.
    pub const Scratch = struct {};

    pub fn initCompiler(allocator: Allocator, _: ?*Scratch) Allocator.Error!Compiler {
        return .init(allocator);
    }

    pub fn deinitCompiler(compiler: *Compiler) void {
        compiler.deinit();
    }

    pub fn prepare(ctx: *ir.Context) Allocator.Error!void {
        return contract.loadArithDialect(ctx);
    }

    /// Runs the lowering `backend.Backend.lower` runs: view legalization, promotion,
    /// verification and x86_64 legality.
    pub fn lower(
        allocator: Allocator,
        module: *ir.Operation,
        refused: *execution.Refused,
    ) execution.LowerError!void {
        _ = backend.lowerModule(allocator, module, null, refused) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.VerificationFailed => error.VerificationFailed,
            error.UnsupportedOperation => error.UnsupportedOperation,
            error.CodeGenFailed,
            error.UnsupportedArchitecture,
            error.FunctionNotFound,
            => error.CodeGenFailed,
        };
    }

    pub fn emit(compiler: *Compiler, func: *ir.Operation) EmitError!execution.Emitted {
        try compiler.emitFunction(func);
        return .{
            .code = compiler.getCode(),
            .calls = compiler.call_relocations.items,
            .data = compiler.data_symbols.items(),
            .data_relocations = compiler.data_relocations.items,
            .outgrew_reservation = compiler.code.items.len > compiler.code_reservation,
            .placement = placement(compiler),
        };
    }

    fn placement(compiler: *const Compiler) execution.Placement {
        if (!compiler.place_values) return .forced;
        if (compiler.framed_by) |op| return .{ .framed = op.name.name };
        return .{ .placed = .{
            .general = @intCast(compiler.value_location_index.rangedValues()),
            .floating = @intCast(compiler.xmm_location_index.rangedValues()),
        } };
    }

    pub fn takeLineTable(compiler: *Compiler) Allocator.Error!debug_info.LineTable {
        return compiler.takeLineTable();
    }

    /// The emitted function's code buffer, handed over whole. The next function reserves
    /// its own.
    pub fn takeCode(compiler: *Compiler) Allocator.Error![]u8 {
        return compiler.code.toOwnedSlice(compiler.allocator);
    }

    pub fn shareImage(compiler: *Compiler, functions: ?*const machine.ImageFunctions) void {
        compiler.image_functions = functions;
    }

    pub fn recordLines(compiler: *Compiler, on: bool) void {
        compiler.record_lines = on;
    }

    pub fn placeValues(compiler: *Compiler, on: bool) error{FrameOnlyUnsupported}!void {
        compiler.place_values = on;
    }

    pub fn failedOperation(compiler: *const Compiler) ?*ir.Operation {
        return compiler.failed_operation;
    }

    pub fn failedExcess(compiler: *const Compiler) ?execution.Excess {
        return compiler.excess;
    }

    pub fn discard(compiler: *Compiler) void {
        compiler.discardFunctionState();
    }

    pub fn report(failure: execution.Failure) void {
        failures.Failure.report(.{
            .stage = switch (failure.stage) {
                // Lowering reports its own refusals, so the runtime never hands one here.
                .lower => unreachable,
                .emit => .emit,
                .link => .link,
            },
            .operation = failure.operation,
            .err = failure.err,
            .symbol = failure.symbol,
            .excess = failure.excess,
        });
    }

    pub fn admitsSignature(signature: *const Signature) bool {
        return sysv.admitsSignature(signature);
    }

    /// Writes a little-endian `address` into the 8-byte window in `code` at `offset`.
    pub fn patch(code: []u8, offset: usize, address: u64) void {
        std.debug.assert(offset <= code.len);
        std.debug.assert(code.len - offset >= relocation_bytes);
        std.mem.writeInt(u64, code[offset..][0..relocation_bytes], address, .little);
    }

    pub fn enter(
        address: usize,
        signature: *const Signature,
        args: []const execution.Value,
        results: []execution.Value,
    ) void {
        invoke.call(address, signature, args, results);
    }
};

comptime {
    execution.assertTarget(Target);
}

const Runtime = execution.Runtime(Target);

const Handle = execution.Handle;

const artifact_target = artifact.Target{ .architecture = Target.architecture };
const artifact_abi = Target.abi;

const MalformedDataArtifact = struct {
    data: []const artifact.DataBuffer = &.{table},
    relocations: []const artifact.Relocation = &.{reference},
    orphan_buffer: bool = false,

    const table = artifact.DataBuffer{ .name = "table", .bytes = "\x01\x02" };
    const reference = artifact.Relocation{ .offset = 0, .symbol = "table", .kind = .absolute };
};

/// Fails unless the emitter holds no state from the last function it emitted.
fn expectEmitterFunctionStateDiscarded(runtime: *const Runtime) !void {
    const emitter = &runtime.compiler;
    try std.testing.expectEqual(@as(usize, 0), emitter.code.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.call_relocations.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.data_symbols.items().len);
    try std.testing.expectEqual(@as(usize, 0), emitter.data_relocations.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.slot_map.count());
    try std.testing.expectEqual(@as(usize, 0), emitter.vector_slot_map.count());
    try std.testing.expectEqual(@as(usize, 0), emitter.alloca_payload_slots.count());
    try std.testing.expectEqual(@as(usize, 0), emitter.allocation_kinds.count());
    try std.testing.expectEqual(@as(usize, 0), emitter.value_locations.count());
    try std.testing.expectEqual(@as(usize, 0), emitter.value_location_ranges.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.value_location_index.value_keys.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.value_location_index.value_heads.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.value_location_index.value_links.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.xmm_locations.count());
    try std.testing.expectEqual(@as(usize, 0), emitter.xmm_location_ranges.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.xmm_location_index.value_keys.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.xmm_location_index.value_heads.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.xmm_location_index.value_links.items.len);
    try std.testing.expectEqual(@as(usize, 0), emitter.operation_positions.count());
    try std.testing.expectEqual(@as(?*ir.Operation, null), emitter.failed_operation);
}

/// The sizes the observed malloc granted, in call order. A size past `heap_grant_limit` is never
/// granted: the process exits with `heap_reached` when it is `heap_expected` and with
/// `heap_unexpected` otherwise, so a child shows which oversized request reached malloc.
var heap_sizes: [8]u64 = undefined;
var heap_size_count: usize = 0;
var heap_expected: u64 = 0;
const heap_grant_limit: u64 = 1 << 20;
const heap_reached: u8 = 103;
const heap_unexpected: u8 = 106;

fn observedMalloc(size: u64) callconv(.c) ?*anyopaque {
    if (size > heap_grant_limit) {
        sys.process.exit(if (size == heap_expected) heap_reached else heap_unexpected);
    }
    if (heap_size_count == heap_sizes.len) sys.process.exit(104);
    heap_sizes[heap_size_count] = size;
    heap_size_count += 1;
    return sys.heap.malloc(size);
}

fn observedFree(address: ?*anyopaque) callconv(.c) void {
    sys.heap.free(address);
}

fn failingMalloc(_: u64) callconv(.c) ?*anyopaque {
    return null;
}

const Sized = *const fn (usize) callconv(.c) i64;

/// How `native(count)` ends in a child that inherits `heap_expected = expected`.
fn childEnding(native: Sized, count: usize, expected: u64) !sys.process.Termination {
    heap_expected = expected;
    const child = switch (try sys.process.fork()) {
        .child => {
            // The test runner's crash handler would catch `ud2` and end the child another way.
            sys.signal.restoreDefault(.ILL);
            _ = native(count);
            sys.process.exit(102);
        },
        .parent => |pid| pid,
    };
    return sys.process.waitDirect(child);
}

/// Expects `native(count)` to die on `ud2`'s invalid opcode before or after malloc.
fn expectAllocationTrap(native: Sized, count: usize) !void {
    switch (try childEnding(native, count, 0)) {
        .signal => |signal| try std.testing.expect(signal == .ILL),
        else => return error.ExpectedSigill,
    }
}

/// Expects `native(count)` to pass the size guard and ask malloc for exactly `bytes`.
fn expectMallocReached(native: Sized, count: usize, bytes: u64) !void {
    switch (try childEnding(native, count, bytes)) {
        .exited => |code| try std.testing.expectEqual(heap_reached, code),
        else => return error.ExpectedMallocReached,
    }
}

fn sizedModule(ctx: *ir.Context, widths: []const AllocationWidth) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;
    const loc = ir.Location.getUnknown();
    const index_type = try ArithDialect.getIndexType(ctx);
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    for (widths) |width| {
        const element = try ArithDialect.getScalarType(ctx, width.scalar);
        const memref_type = try MemrefDialect.getMemrefTypeDynamic(ctx, element, .host);
        const func = try FuncDialect.FuncOp.create(ctx, loc, width.name, &.{index_type}, &.{i64_type});
        try module.getBodyBlock().addOperation(func.op);
        const entry = func.getEntryBlock();
        const alloc = try MemrefDialect.AllocOp.createDynamic(ctx, loc, func.getArgument(0), memref_type);
        try entry.addOperation(alloc.op);
        try entry.addOperation((try MemrefDialect.DeallocOp.create(ctx, loc, alloc.getResult())).op);
        const seven = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 7);
        try entry.addOperation(seven.op);
        try entry.addOperation((try FuncDialect.ReturnOp.create(ctx, loc, &.{seven.getResult()})).op);
    }
    return module.op;
}

const AllocationWidth = struct { name: []const u8, scalar: dialects.ArithDialect.ScalarTypeKind, bytes: u64 };

/// Every element width `elementByteSize` admits. A byte element needs no size guard.
const allocation_widths = [_]AllocationWidth{
    .{ .name = "sized_u8", .scalar = .u8, .bytes = 1 },
    .{ .name = "sized_i16", .scalar = .i16, .bytes = 2 },
    .{ .name = "sized_i32", .scalar = .i32, .bytes = 4 },
    .{ .name = "sized_i64", .scalar = .i64, .bytes = 8 },
};

/// Linux x86-64 kernel entry numbers and arguments the two tests below enter the kernel with.
/// They are named here rather than read from a host namespace because Choir owns no host
/// surface, and because a wrong number fails the test that uses it: `getpid` answers a pid this
/// process can check, and `rt_sigprocmask` answers zero only when it read a whole signal set.
const linux_getpid: i64 = 39;
const linux_rt_sigprocmask: i64 = 14;
const linux_sig_setmask: i64 = 2;
const linux_signal_set_bytes: i64 = 8;
const linux_efault: i64 = -14;
const linux_einval: i64 = -22;

/// A constant global's bytes, as two words whose bytes a wrong offset would not reproduce.
const pin_table_words = [_]u64{ 0x0102030405060708, 0x1122334455667788 };
const pin_table_bytes: []const u8 = std.mem.asBytes(&pin_table_words);

/// Builds a module with one zeroed global the code writes and one constant global it reads.
fn buildGlobalModule(ir_ctx: *ir.Context) !dialects.BuiltinDialect.ModuleOp {
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ir_ctx, .i64);
    const index_type = try ArithDialect.getIndexType(ir_ctx);
    const word_type = try MemrefDialect.getMemrefType1D(ir_ctx, 1, i64_type, .host);
    const table_type = try MemrefDialect.getMemrefType1D(ir_ctx, 2, i64_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const count = try MemrefDialect.GlobalOp.create(ir_ctx, loc, .{
        .sym_name = "count",
        .memref_type = word_type,
        .alignment = 8,
    });
    try module_block.addOperation(count.op);
    const table = try MemrefDialect.GlobalOp.create(ir_ctx, loc, .{
        .sym_name = "table",
        .memref_type = table_type,
        .alignment = 8,
        .constant = true,
        .initial = pin_table_bytes,
    });
    try module_block.addOperation(table.op);

    var next = try FuncDialect.FuncOp.create(ir_ctx, loc, "next", &.{}, &.{i64_type});
    try module_block.addOperation(next.op);
    {
        const entry = next.getEntryBlock();
        var zero = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, index_type, 0);
        try entry.addOperation(zero.op);
        const count_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "count", word_type);
        try entry.addOperation(count_ref.op);
        var used = try MemrefDialect.LoadOp.create(
            ir_ctx,
            loc,
            count_ref.getResult(),
            zero.getResult(),
            i64_type,
        );
        try entry.addOperation(used.op);
        var one = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, i64_type, 1);
        try entry.addOperation(one.op);
        const raised = try ArithDialect.AddOp.create(ir_ctx, loc, used.getResult(), one.getResult());
        try entry.addOperation(raised.op);
        const stored = try MemrefDialect.StoreOp.create(
            ir_ctx,
            loc,
            raised.getResult(),
            count_ref.getResult(),
            zero.getResult(),
        );
        try entry.addOperation(stored.op);
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{used.getResult()});
        try entry.addOperation(ret.op);
    }

    var entry_of = try FuncDialect.FuncOp.create(ir_ctx, loc, "entry_of", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(entry_of.op);
    {
        const entry = entry_of.getEntryBlock();
        const table_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "table", table_type);
        try entry.addOperation(table_ref.op);
        var word = try MemrefDialect.LoadOp.create(
            ir_ctx,
            loc,
            table_ref.getResult(),
            entry_of.getArgument(0),
            i64_type,
        );
        try entry.addOperation(word.op);
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{word.getResult()});
        try entry.addOperation(ret.op);
    }

    return module;
}

/// The region the module-region pin declares, in bytes.
const pin_arena_capacity: u64 = 4096;
/// The width of the cursor word and of each value the pin promotes.
const pin_word_bytes: i64 = 8;
/// Values whose every byte differs, so reading the region back one byte at a time says which
/// bytes the store reached and where they landed.
const pin_values = [_]i64{
    @bitCast(@as(u64, 0x1122334455667788)),
    @bitCast(@as(u64, 0x99aabbccddeeff01)),
    @bitCast(@as(u64, 0x0123456789abcdef)),
};

/// Builds the module the module-region pin runs: two zero filled globals and three functions
/// over them.
///
/// `bump` is the promotion. `peek` and `cursor` read the result back without going through
/// `memref.view`, so a view that computed the wrong address cannot agree with itself and pass.
/// `peek` loads from the byte base, which the backend emits as a zero extending one byte load,
/// so the caller reassembles a word from eight of them rather than trusting one load to be wide.
fn buildRegionModule(ir_ctx: *ir.Context) !dialects.BuiltinDialect.ModuleOp {
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ir_ctx, .i64);
    const u8_type = try ArithDialect.getScalarType(ir_ctx, .u8);
    const index_type = try ArithDialect.getIndexType(ir_ctx);
    const arena_type = try MemrefDialect.getMemrefType1D(ir_ctx, pin_arena_capacity, u8_type, .host);
    const word_type = try MemrefDialect.getMemrefType1D(ir_ctx, 1, i64_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const backing = try MemrefDialect.GlobalOp.create(ir_ctx, loc, .{
        .sym_name = "arena",
        .memref_type = arena_type,
        .alignment = 16,
    });
    try module_block.addOperation(backing.op);
    const cursor_global = try MemrefDialect.GlobalOp.create(ir_ctx, loc, .{
        .sym_name = "arena.cursor",
        .memref_type = word_type,
        .alignment = 8,
    });
    try module_block.addOperation(cursor_global.op);

    var bump = try FuncDialect.FuncOp.create(ir_ctx, loc, "bump", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(bump.op);
    {
        const entry = bump.getEntryBlock();
        var zero = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, index_type, 0);
        try entry.addOperation(zero.op);
        const cursor_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "arena.cursor", word_type);
        try entry.addOperation(cursor_ref.op);
        var used = try MemrefDialect.LoadOp.create(
            ir_ctx,
            loc,
            cursor_ref.getResult(),
            zero.getResult(),
            i64_type,
        );
        try entry.addOperation(used.op);
        const arena_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "arena", arena_type);
        try entry.addOperation(arena_ref.op);
        const slot = try MemrefDialect.ViewOp.create(
            ir_ctx,
            loc,
            arena_ref.getResult(),
            used.getResult(),
            word_type,
        );
        try entry.addOperation(slot.op);
        const written = try MemrefDialect.StoreOp.create(
            ir_ctx,
            loc,
            bump.getArgument(0),
            slot.getResult(),
            zero.getResult(),
        );
        try entry.addOperation(written.op);
        var width = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, i64_type, pin_word_bytes);
        try entry.addOperation(width.op);
        const next = try ArithDialect.AddOp.create(ir_ctx, loc, used.getResult(), width.getResult());
        try entry.addOperation(next.op);
        const advanced = try MemrefDialect.StoreOp.create(
            ir_ctx,
            loc,
            next.getResult(),
            cursor_ref.getResult(),
            zero.getResult(),
        );
        try entry.addOperation(advanced.op);
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{used.getResult()});
        try entry.addOperation(ret.op);
    }

    var peek = try FuncDialect.FuncOp.create(ir_ctx, loc, "peek", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(peek.op);
    {
        const entry = peek.getEntryBlock();
        const arena_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "arena", arena_type);
        try entry.addOperation(arena_ref.op);
        var byte = try MemrefDialect.LoadOp.create(
            ir_ctx,
            loc,
            arena_ref.getResult(),
            peek.getArgument(0),
            i64_type,
        );
        try entry.addOperation(byte.op);
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{byte.getResult()});
        try entry.addOperation(ret.op);
    }

    var cursor = try FuncDialect.FuncOp.create(ir_ctx, loc, "cursor", &.{}, &.{i64_type});
    try module_block.addOperation(cursor.op);
    {
        const entry = cursor.getEntryBlock();
        var zero = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, index_type, 0);
        try entry.addOperation(zero.op);
        const cursor_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "arena.cursor", word_type);
        try entry.addOperation(cursor_ref.op);
        var used = try MemrefDialect.LoadOp.create(
            ir_ctx,
            loc,
            cursor_ref.getResult(),
            zero.getResult(),
            i64_type,
        );
        try entry.addOperation(used.op);
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{used.getResult()});
        try entry.addOperation(ret.op);
    }

    return module;
}

/// Reassembles the little endian word at `offset` from eight one byte reads of the region.
fn readRegionWord(peek: *const fn (i64) callconv(.c) i64, offset: i64) u64 {
    var word: u64 = 0;
    for (0..8) |index| {
        const byte: u64 = @intCast(peek(offset + @as(i64, @intCast(index))));
        std.debug.assert(byte <= 0xff);
        word |= byte << @intCast(index * 8);
    }
    return word;
}

/// The values the live-across-a-call fixture carries past its call, and the argument it passes.
///
/// Four rather than one, because one could survive by luck in whichever register the callee
/// happened not to touch. Four is more than the callee's own working set, so a call site that
/// left them in volatile registers would lose at least one of them.
const across_addends = [_]i64{ 7, 9, 11, 13 };
const across_argument: i64 = 5;

/// Builds a function whose values are live across a call without being arguments to it.
///
/// `callee` writes every volatile register it can reach by doing arithmetic, so if the call site
/// were responsible for preserving a live value and stopped doing it, the sum below would come
/// back wrong rather than merely slower.
fn buildAcrossModule(ir_ctx: *ir.Context) !dialects.BuiltinDialect.ModuleOp {
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var callee = try FuncDialect.FuncOp.create(ir_ctx, loc, "callee", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(callee.op);
    {
        const entry = callee.getEntryBlock();
        var running = callee.getArgument(0);
        for (across_addends) |addend| {
            var step = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, i64_type, addend);
            try entry.addOperation(step.op);
            const sum = try ArithDialect.AddOp.create(ir_ctx, loc, running, step.getResult());
            try entry.addOperation(sum.op);
            running = sum.getResult();
        }
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{running});
        try entry.addOperation(ret.op);
    }

    var across = try FuncDialect.FuncOp.create(ir_ctx, loc, "across", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(across.op);
    {
        const entry = across.getEntryBlock();
        var live: [across_addends.len]*ir.Value = undefined;
        for (across_addends, 0..) |addend, index| {
            var step = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, i64_type, addend);
            try entry.addOperation(step.op);
            const sum = try ArithDialect.AddOp.create(
                ir_ctx,
                loc,
                across.getArgument(0),
                step.getResult(),
            );
            try entry.addOperation(sum.op);
            live[index] = sum.getResult();
        }

        const call = try FuncDialect.CallOp.create(
            ir_ctx,
            loc,
            "callee",
            &.{across.getArgument(0)},
            &.{i64_type},
        );
        try entry.addOperation(call.op);

        var total = call.getResult(0).?;
        for (live) |value| {
            const sum = try ArithDialect.AddOp.create(ir_ctx, loc, total, value);
            try entry.addOperation(sum.op);
            total = sum.getResult();
        }
        const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{total});
        try entry.addOperation(ret.op);
    }

    return module;
}

const ArithKind = enum { div, rem, shl, shr, ushr };

/// Every arith operation the declaration lets fail, at every integer width: signed division and
/// remainder, unsigned ones, and each shift a type admits.
const arith_witnesses = witnesses: {
    const ScalarKind = dialects.ArithDialect.ScalarTypeKind;
    const signed = [_]ScalarKind{ .i8, .i16, .i32, .i64 };
    const unsigned = [_]ScalarKind{ .u8, .u16, .u32, .u64 };
    var list: []const ArithWitness = &.{};
    for (signed ++ unsigned) |scalar| {
        const is_signed = std.mem.indexOfScalar(ScalarKind, &signed, scalar) != null;
        for (std.enums.values(ArithKind)) |kind| {
            if (kind == .shr and !is_signed) continue;
            const name = @tagName(kind) ++ "_" ++ @tagName(scalar);
            list = list ++ &[_]ArithWitness{.{ .name = name, .scalar = scalar, .kind = kind }};
        }
    }
    break :witnesses list[0..list.len].*;
};

const ArithWitness = struct {
    name: []const u8,
    scalar: dialects.ArithDialect.ScalarTypeKind,
    kind: ArithKind,
};

/// One function `name(lhs, rhs) -> lhs op rhs` per witness, each on its own type.
fn arithModule(ctx: *ir.Context) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    inline for (arith_witnesses) |witness| {
        const typ = try ArithDialect.getScalarType(ctx, witness.scalar);
        const func = try FuncDialect.FuncOp.create(ctx, loc, witness.name, &.{ typ, typ }, &.{typ});
        try module.getBodyBlock().addOperation(func.op);
        const entry = func.getEntryBlock();
        const Op = switch (witness.kind) {
            .div => ArithDialect.DivOp,
            .rem => ArithDialect.RemOp,
            .shl => ArithDialect.ShlOp,
            .shr => ArithDialect.ShrOp,
            .ushr => ArithDialect.UshrOp,
        };
        const op = try Op.create(ctx, loc, func.getArgument(0), func.getArgument(1));
        try entry.addOperation(op.op);
        try entry.addOperation((try FuncDialect.ReturnOp.create(ctx, loc, &.{op.getResult()})).op);
    }
    return module.op;
}

/// The Zig type that carries `scalar` across the C boundary.
fn Carrier(comptime scalar: dialects.ArithDialect.ScalarTypeKind) type {
    return @Int(
        if (std.mem.startsWith(u8, @tagName(scalar), "u")) .unsigned else .signed,
        dialects.arith.scalarBitWidth(scalar),
    );
}

/// How `native(lhs, rhs)` ends in a child with the default action for the signals a failed
/// arith operation raises.
fn arithEnding(
    comptime T: type,
    native: *const fn (T, T) callconv(.c) T,
    lhs: T,
    rhs: T,
) !sys.process.Termination {
    const child = switch (try sys.process.fork()) {
        .child => {
            // The test runner's crash handler would catch both and end the child another way.
            sys.signal.restoreDefault(.ILL);
            sys.signal.restoreDefault(.FPE);
            _ = native(lhs, rhs);
            sys.process.exit(102);
        },
        .parent => |pid| pid,
    };
    return sys.process.waitDirect(child);
}

fn expectArithSignal(
    comptime T: type,
    native: *const fn (T, T) callconv(.c) T,
    lhs: T,
    rhs: T,
    expected: @FieldType(sys.process.Termination, "signal"),
) !void {
    switch (try arithEnding(T, native, lhs, rhs)) {
        .signal => |signal| if (signal != expected) return error.UnexpectedSignal,
        else => return error.ExpectedSignal,
    }
}

/// The `T` whose bits spell the signed `value`.
fn bitsOf(comptime T: type, comptime value: comptime_int) T {
    return @bitCast(@as(@Int(.signed, @bitSizeOf(T)), value));
}

/// Zig's answer for `lhs op rhs` on operands the declaration admits.
fn arithAnswer(comptime T: type, kind: ArithKind, lhs: T, rhs: T) T {
    const U = @Int(.unsigned, @bitSizeOf(T));
    return switch (kind) {
        .div => @divTrunc(lhs, rhs),
        .rem => @rem(lhs, rhs),
        .shl => lhs << @intCast(rhs),
        .shr => lhs >> @intCast(rhs),
        .ushr => @bitCast(@as(U, @bitCast(lhs)) >> @intCast(rhs)),
    };
}

/// The lane loop's failures: division and every shift, over 128 bit vectors of each signed
/// width and of unsigned 32 bit lanes.
const lane_witnesses = witnesses: {
    const ScalarKind = dialects.ArithDialect.ScalarTypeKind;
    var list: []const ArithWitness = &.{};
    for ([_]ScalarKind{ .i8, .i16, .i32, .i64, .u32 }) |scalar| {
        for ([_]ArithKind{ .div, .shl, .shr, .ushr }) |kind| {
            if (kind == .shr and scalar == .u32) continue;
            const name = "lane_" ++ @tagName(kind) ++ "_" ++ @tagName(scalar);
            list = list ++ &[_]ArithWitness{.{ .name = name, .scalar = scalar, .kind = kind }};
        }
    }
    break :witnesses list[0..list.len].*;
};

/// One function `name(lhs, rhs)` per lane witness, answering lane 0 of `splat(lhs) op splat(rhs)`.
/// A splat of a parameter is no literal, so every lane takes the loop and its guards.
fn laneModule(ctx: *ir.Context) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    inline for (lane_witnesses) |witness| {
        const typ = try ArithDialect.getScalarType(ctx, witness.scalar);
        const lanes: u32 = 128 / dialects.arith.scalarBitWidth(witness.scalar);
        const element = dialects.arith.scalarTypeName(witness.scalar);
        const vec_type = (try ArithDialect.getVecType(ctx, lanes, element)).?;
        const func = try FuncDialect.FuncOp.create(ctx, loc, witness.name, &.{ typ, typ }, &.{typ});
        try module.getBodyBlock().addOperation(func.op);
        const entry = func.getEntryBlock();
        const lhs = try ArithDialect.SplatOp.create(ctx, loc, func.getArgument(0), vec_type);
        try entry.addOperation(lhs.op);
        const rhs = try ArithDialect.SplatOp.create(ctx, loc, func.getArgument(1), vec_type);
        try entry.addOperation(rhs.op);
        const Op = switch (witness.kind) {
            .div => ArithDialect.DivOp,
            .shl => ArithDialect.ShlOp,
            .shr => ArithDialect.ShrOp,
            .ushr => ArithDialect.UshrOp,
            .rem => unreachable,
        };
        const op = try Op.create(ctx, loc, lhs.getResult(), rhs.getResult());
        try entry.addOperation(op.op);
        const lane = try ArithDialect.ExtractOp.create(ctx, loc, op.getResult(), 0, typ);
        try entry.addOperation(lane.op);
        try entry.addOperation((try FuncDialect.ReturnOp.create(ctx, loc, &.{lane.getResult()})).op);
    }
    return module.op;
}

const NegShape = struct { lanes: u32, scalar: dialects.ArithDialect.ScalarTypeKind };

/// Every float vector shape the lane loop negates, and the two packed shapes beside them.
const neg_shapes = [_]NegShape{
    .{ .lanes = 2, .scalar = .f32 },
    .{ .lanes = 8, .scalar = .f32 },
    .{ .lanes = 16, .scalar = .f32 },
    .{ .lanes = 4, .scalar = .f64 },
    .{ .lanes = 8, .scalar = .f64 },
    .{ .lanes = 4, .scalar = .f32 },
    .{ .lanes = 2, .scalar = .f64 },
};

fn negName(comptime shape: NegShape, comptime lane: u32) []const u8 {
    return std.fmt.comptimePrint("neg_{d}x{s}_{d}", .{ shape.lanes, @tagName(shape.scalar), lane });
}

/// One function per shape and lane, answering that lane of `neg(splat(x))`.
fn negModule(ctx: *ir.Context) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    inline for (neg_shapes) |shape| {
        const typ = try ArithDialect.getScalarType(ctx, shape.scalar);
        const element = dialects.arith.scalarTypeName(shape.scalar);
        const vec_type = (try ArithDialect.getVecType(ctx, shape.lanes, element)).?;
        inline for (0..shape.lanes) |lane| {
            const func = try FuncDialect.FuncOp.create(ctx, loc, negName(shape, lane), &.{typ}, &.{typ});
            try module.getBodyBlock().addOperation(func.op);
            const entry = func.getEntryBlock();
            const splat = try ArithDialect.SplatOp.create(ctx, loc, func.getArgument(0), vec_type);
            try entry.addOperation(splat.op);
            const neg = try ArithDialect.NegOp.create(ctx, loc, splat.getResult());
            try entry.addOperation(neg.op);
            const answer = try ArithDialect.ExtractOp.create(ctx, loc, neg.getResult(), lane, typ);
            try entry.addOperation(answer.op);
            try entry.addOperation((try FuncDialect.ReturnOp.create(ctx, loc, &.{answer.getResult()})).op);
        }
    }
    return module.op;
}

const PowerWitness = struct {
    scalar: dialects.ArithDialect.ScalarTypeKind,
    kind: ArithKind,
    divisor: i64,
    name: []const u8,
};

/// Signed division and remainder at every width by every 2^k with 1 <= k <= width - 2, which
/// shift, and by every -2^k with 1 <= k <= width - 1, which stay on the divide.
const power_witnesses = witnesses: {
    @setEvalBranchQuota(1_000_000);
    var list: []const PowerWitness = &.{};
    for ([_]dialects.ArithDialect.ScalarTypeKind{ .i8, .i16, .i32, .i64 }) |scalar| {
        const bits = dialects.arith.scalarBitWidth(scalar);
        for ([_]ArithKind{ .div, .rem }) |kind| {
            for (1..bits) |k| {
                const negative: i64 = if (k == 63) std.math.minInt(i64) else -(@as(i64, 1) << @intCast(k));
                const parts = .{ @tagName(kind), @tagName(scalar), k };
                list = list ++ &[_]PowerWitness{.{
                    .scalar = scalar,
                    .kind = kind,
                    .divisor = negative,
                    .name = std.fmt.comptimePrint("pow_{s}_{s}_minus_{d}", parts),
                }};
                if (k > bits - 2) continue;
                list = list ++ &[_]PowerWitness{.{
                    .scalar = scalar,
                    .kind = kind,
                    .divisor = @as(i64, 1) << @intCast(k),
                    .name = std.fmt.comptimePrint("pow_{s}_{s}_{d}", parts),
                }};
            }
        }
    }
    break :witnesses list[0..list.len].*;
};

/// One function `name(x) -> x op divisor` per witness, the divisor a literal.
fn powerModule(ctx: *ir.Context) !*ir.Operation {
    @setEvalBranchQuota(1_000_000);
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    inline for (power_witnesses) |witness| {
        const typ = try ArithDialect.getScalarType(ctx, witness.scalar);
        const func = try FuncDialect.FuncOp.create(ctx, loc, witness.name, &.{typ}, &.{typ});
        try module.getBodyBlock().addOperation(func.op);
        const entry = func.getEntryBlock();
        const divisor = try ArithDialect.ConstantOp.createInt(ctx, loc, typ, witness.divisor);
        try entry.addOperation(divisor.op);
        const Op = if (witness.kind == .div) ArithDialect.DivOp else ArithDialect.RemOp;
        const op = try Op.create(ctx, loc, func.getArgument(0), divisor.getResult());
        try entry.addOperation(op.op);
        try entry.addOperation((try FuncDialect.ReturnOp.create(ctx, loc, &.{op.getResult()})).op);
    }
    return module.op;
}

const ImmediateKind = enum { add, sub, mul, @"and", @"or", xor };

const ImmediateWitness = struct {
    scalar: dialects.ArithDialect.ScalarTypeKind,
    kind: ImmediateKind,
    value: i128,
    name: []const u8,
};

/// Literals at each boundary an immediate form turns on: imm8, imm32 sign extension, the
/// unsigned 32-bit values a `mov r32` zero extends, and the values only `movabs` holds.
const immediate_literals = [_]i128{
    1,                    -1,            7,                    -7,
    127,                  -128,          128,                  -129,
    255,                  32767,         -32768,               65535,
    0x7FFF_FFFF,          -0x8000_0000,  0x8000_0000,          -0x8000_0001,
    0xFFFF_FFFF,          0x1_0000_0000, std.math.maxInt(i64), std.math.minInt(i64),
    std.math.maxInt(u64),
};

const immediate_scalars = [_]dialects.ArithDialect.ScalarTypeKind{ .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 };

/// Every integer operation that takes an imm32, at every width, by every literal its type holds.
const immediate_witnesses = witnesses: {
    @setEvalBranchQuota(1_000_000);
    var list: []const ImmediateWitness = &.{};
    for (immediate_scalars) |scalar| {
        for (std.enums.values(ImmediateKind)) |kind| {
            for (immediate_literals, 0..) |value, index| {
                if (std.math.cast(Carrier(scalar), value) == null) continue;
                list = list ++ &[_]ImmediateWitness{.{
                    .scalar = scalar,
                    .kind = kind,
                    .value = value,
                    .name = std.fmt.comptimePrint("imm_{s}_{s}_{d}", .{ @tagName(kind), @tagName(scalar), index }),
                }};
            }
        }
    }
    break :witnesses list[0..list.len].*;
};

/// The word `ConstantOp.createInt` takes for `value` as a `T`: its bits, read as signed.
fn literalWord(comptime T: type, comptime value: i128) i64 {
    const typed: T = value;
    if (@bitSizeOf(T) == 64) return @bitCast(@as(u64, @bitCast(typed)));
    return typed;
}

fn immediateAnswer(comptime T: type, kind: ImmediateKind, lhs: T, rhs: T) T {
    return switch (kind) {
        .add => lhs +% rhs,
        .sub => lhs -% rhs,
        .mul => lhs *% rhs,
        .@"and" => lhs & rhs,
        .@"or" => lhs | rhs,
        .xor => lhs ^ rhs,
    };
}

/// `imm_*(x) -> x op literal` per immediate witness, and `const_<scalar>_<index>() -> literal`
/// per literal each type holds, plus the two booleans.
fn immediateModule(ctx: *ir.Context) !*ir.Operation {
    @setEvalBranchQuota(1_000_000);
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    inline for (immediate_witnesses) |witness| {
        const T = Carrier(witness.scalar);
        const typ = try ArithDialect.getScalarType(ctx, witness.scalar);
        const func = try FuncDialect.FuncOp.create(ctx, loc, witness.name, &.{typ}, &.{typ});
        try module.getBodyBlock().addOperation(func.op);
        const entry = func.getEntryBlock();
        const literal = try ArithDialect.ConstantOp.createInt(ctx, loc, typ, literalWord(T, witness.value));
        try entry.addOperation(literal.op);
        const Op = switch (witness.kind) {
            .add => ArithDialect.AddOp,
            .sub => ArithDialect.SubOp,
            .mul => ArithDialect.MulOp,
            .@"and" => ArithDialect.AndOp,
            .@"or" => ArithDialect.OrOp,
            .xor => ArithDialect.XorOp,
        };
        const op = try Op.create(ctx, loc, func.getArgument(0), literal.getResult());
        try entry.addOperation(op.op);
        try entry.addOperation((try FuncDialect.ReturnOp.create(ctx, loc, &.{op.getResult()})).op);
    }
    inline for (immediate_scalars) |scalar| {
        const T = Carrier(scalar);
        const typ = try ArithDialect.getScalarType(ctx, scalar);
        inline for (immediate_literals, 0..) |value, index| {
            if (comptime std.math.cast(T, value) == null) continue;
            const name = std.fmt.comptimePrint("const_{s}_{d}", .{ @tagName(scalar), index });
            const func = try FuncDialect.FuncOp.create(ctx, loc, name, &.{}, &.{typ});
            try module.getBodyBlock().addOperation(func.op);
            const entry = func.getEntryBlock();
            const literal = try ArithDialect.ConstantOp.createInt(ctx, loc, typ, literalWord(T, value));
            try entry.addOperation(literal.op);
            try entry.addOperation((try FuncDialect.ReturnOp.create(ctx, loc, &.{literal.getResult()})).op);
        }
    }
    const bool_type = try ArithDialect.getScalarType(ctx, .bool);
    inline for (.{ false, true }) |value| {
        const name = if (value) "const_bool_true" else "const_bool_false";
        const func = try FuncDialect.FuncOp.create(ctx, loc, name, &.{}, &.{bool_type});
        try module.getBodyBlock().addOperation(func.op);
        const entry = func.getEntryBlock();
        const literal = try ArithDialect.ConstantOp.createBool(ctx, loc, value);
        try entry.addOperation(literal.op);
        try entry.addOperation((try FuncDialect.ReturnOp.create(ctx, loc, &.{literal.getResult()})).op);
    }
    return module.op;
}

/// `low(x) = x * 3`, `caller(x) = low(x) + high(x)` and `high(x) = x - 11`, laid out in that
/// order, so the caller reaches one callee backward and one forward.
fn directCallModule(ctx: *ir.Context) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    const block = module.getBodyBlock();
    inline for (.{ "low", "caller", "high" }) |name| {
        const func = try FuncDialect.FuncOp.create(ctx, loc, name, &.{i64_type}, &.{i64_type});
        try block.addOperation(func.op);
        const entry = func.getEntryBlock();
        const x = func.getArgument(0);
        const result = if (comptime std.mem.eql(u8, name, "caller")) sum: {
            const low = try FuncDialect.CallOp.create(ctx, loc, "low", &.{x}, &.{i64_type});
            try entry.addOperation(low.op);
            const high = try FuncDialect.CallOp.create(ctx, loc, "high", &.{x}, &.{i64_type});
            try entry.addOperation(high.op);
            const sum = try ArithDialect.AddOp.create(ctx, loc, low.getResult(0).?, high.getResult(0).?);
            try entry.addOperation(sum.op);
            break :sum sum.getResult();
        } else other: {
            const low = comptime std.mem.eql(u8, name, "low");
            const literal = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, if (low) 3 else 11);
            try entry.addOperation(literal.op);
            if (low) {
                const product = try ArithDialect.MulOp.create(ctx, loc, x, literal.getResult());
                try entry.addOperation(product.op);
                break :other product.getResult();
            }
            const difference = try ArithDialect.SubOp.create(ctx, loc, x, literal.getResult());
            try entry.addOperation(difference.op);
            break :other difference.getResult();
        };
        try entry.addOperation((try FuncDialect.ReturnOp.create(ctx, loc, &.{result})).op);
    }
    return module.op;
}

/// `early() -> i64` runs a `scf.while` that takes no turn and whose after block returns 1, then
/// stores 7 to the global `cell` and returns 9. `peek() -> i64` reads `cell`.
const ReturningWhile = struct {
    module: *ir.Operation,
    early: *ir.Operation,
    inner_return: *ir.Operation,
};

fn returningWhileModule(ir_ctx: *ir.Context) !ReturningWhile {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;
    const ScfDialect = dialects.ScfDialect;
    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ir_ctx, .i64);
    const index_type = try ArithDialect.getIndexType(ir_ctx);
    const word_type = try MemrefDialect.getMemrefType1D(ir_ctx, 1, i64_type, .host);

    const module = try dialects.BuiltinDialect.ModuleOp.create(ir_ctx, loc);
    const module_block = module.getBodyBlock();
    const cell = try MemrefDialect.GlobalOp.create(ir_ctx, loc, .{
        .sym_name = "cell",
        .memref_type = word_type,
        .alignment = 8,
    });
    try module_block.addOperation(cell.op);

    const early = try FuncDialect.FuncOp.create(ir_ctx, loc, "early", &.{}, &.{i64_type});
    try module_block.addOperation(early.op);
    var inner_return: *ir.Operation = undefined;
    {
        const entry = early.getEntryBlock();
        var loop = try ScfDialect.WhileOp.create(ir_ctx, loc, &.{}, &.{});
        try entry.addOperation(loop.op);
        const before = loop.getBeforeBlock();
        const never = try ArithDialect.ConstantOp.createBool(ir_ctx, loc, false);
        try before.addOperation(never.op);
        try before.addOperation((try ScfDialect.ConditionOp.create(ir_ctx, loc, never.getResult(), &.{})).op);
        const after = loop.getAfterBlock();
        const one = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, i64_type, 1);
        try after.addOperation(one.op);
        inner_return = (try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{one.getResult()})).op;
        try after.addOperation(inner_return);

        const zero = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, index_type, 0);
        try entry.addOperation(zero.op);
        const seven = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, i64_type, 7);
        try entry.addOperation(seven.op);
        const cell_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "cell", word_type);
        try entry.addOperation(cell_ref.op);
        const stored = try MemrefDialect.StoreOp.create(ir_ctx, loc, seven.getResult(), cell_ref.getResult(), zero.getResult());
        try entry.addOperation(stored.op);
        const nine = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, i64_type, 9);
        try entry.addOperation(nine.op);
        try entry.addOperation((try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{nine.getResult()})).op);
    }

    const peek = try FuncDialect.FuncOp.create(ir_ctx, loc, "peek", &.{}, &.{i64_type});
    try module_block.addOperation(peek.op);
    {
        const entry = peek.getEntryBlock();
        const zero = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, index_type, 0);
        try entry.addOperation(zero.op);
        const cell_ref = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "cell", word_type);
        try entry.addOperation(cell_ref.op);
        var word = try MemrefDialect.LoadOp.create(ir_ctx, loc, cell_ref.getResult(), zero.getResult(), i64_type);
        try entry.addOperation(word.op);
        try entry.addOperation((try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{word.getResult()})).op);
    }
    return .{ .module = module.op, .early = early.op, .inner_return = inner_return };
}

/// The kinds narrower than 64 bits a cast can hand a memory access as its index.
const narrow_index_kinds = [_]dialects.ArithDialect.ScalarTypeKind{ .i8, .u8, .i16, .i32, .u32 };

const NarrowIndexForm = enum { load, store, atomic, view };

/// Four functions per narrow kind `K`, each casting an i64 to `K` and reading it as an index:
///
///     load_K(m: memref<i64>, x: i64) -> i64     { return load m[cast x to K] }
///     store_K(m: memref<i64>, x: i64, v: i64)   { store v, m[cast x to K]; return v }
///     atomic_K(m: memref<i64>, x: i64) -> i64   { return atomic_load m[cast x to K] }
///     view_K(b: memref<u8>, x: i64) -> i64      { return load (view b, cast x to K)[0] }
///
/// These witness how an index is extended into an address, and nothing about bounds: x64 checks
/// no extent, and the dialect's bounds premise is the caller's to hold. The memref is a
/// parameter so the caller can point it into the middle of an array, where the word a negative
/// index addresses is mapped and the two extensions of it can be told apart.
fn narrowIndexModule(ctx: *ir.Context) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;
    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const u8_type = try ArithDialect.getScalarType(ctx, .u8);
    const index_type = try ArithDialect.getIndexType(ctx);
    const words_type = try MemrefDialect.getMemrefTypeDynamic(ctx, i64_type, .host);
    const bytes_type = try MemrefDialect.getMemrefTypeDynamic(ctx, u8_type, .host);
    const word_type = try MemrefDialect.getMemrefType1D(ctx, 1, i64_type, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    inline for (narrow_index_kinds) |kind| {
        const narrow_type = try ArithDialect.getScalarType(ctx, kind);
        inline for (comptime std.enums.values(NarrowIndexForm)) |form| {
            const name = @tagName(form) ++ "_" ++ @tagName(kind);
            const params: []const ir.Type = switch (form) {
                .load, .atomic => &.{ words_type, i64_type },
                .store => &.{ words_type, i64_type, i64_type },
                .view => &.{ bytes_type, i64_type },
            };
            const func = try FuncDialect.FuncOp.create(ctx, loc, name, params, &.{i64_type});
            try module.getBodyBlock().addOperation(func.op);
            const entry = func.getEntryBlock();
            const memory = func.getArgument(0);
            const source = func.getArgument(1);
            const narrowed = try ArithDialect.CastOp.create(ctx, loc, source, narrow_type);
            try entry.addOperation(narrowed.op);
            const index = narrowed.getResult();
            const answer: *ir.Value = switch (form) {
                .load => answer: {
                    var loaded = try MemrefDialect.LoadOp.create(ctx, loc, memory, index, i64_type);
                    try entry.addOperation(loaded.op);
                    break :answer loaded.getResult();
                },
                .store => answer: {
                    const value = func.getArgument(2);
                    const stored = try MemrefDialect.StoreOp.create(ctx, loc, value, memory, index);
                    try entry.addOperation(stored.op);
                    break :answer value;
                },
                .atomic => answer: {
                    const Atomic = MemrefDialect.AtomicLoadOp;
                    const loaded = try Atomic.create(ctx, loc, memory, index, i64_type, .seq_cst);
                    try entry.addOperation(loaded.op);
                    break :answer loaded.op.getResult(0).?;
                },
                .view => answer: {
                    const View = MemrefDialect.ViewOp;
                    const word = try View.create(ctx, loc, memory, index, word_type);
                    try entry.addOperation(word.op);
                    const zero = try ArithDialect.ConstantOp.createInt(ctx, loc, index_type, 0);
                    try entry.addOperation(zero.op);
                    const first = zero.getResult();
                    const Load = MemrefDialect.LoadOp;
                    var loaded = try Load.create(ctx, loc, word.getResult(), first, i64_type);
                    try entry.addOperation(loaded.op);
                    break :answer loaded.getResult();
                },
            };
            try entry.addOperation((try FuncDialect.ReturnOp.create(ctx, loc, &.{answer})).op);
        }
    }
    return module.op;
}

/// An i64 whose low bits spell `typed` in `Narrow` and whose bits above that width are the ones a
/// correct reader must not see: all ones for an unsigned kind, and the complement of the sign
/// extension for a signed one. So reading the 64 bits as they stand is wrong for every kind, and
/// so is extending a signed kind by zeros.
fn narrowIndexSource(comptime Narrow: type, typed: Narrow) i64 {
    const bits = @bitSizeOf(Narrow);
    const mask: u64 = (@as(u64, 1) << bits) - 1;
    const exact: u64 = @bitCast(@as(i64, typed));
    const signed = @typeInfo(Narrow).int.signedness == .signed;
    const above: u64 = if (signed) ~exact else std.math.maxInt(u64);
    return @bitCast((exact & mask) | (above & ~mask));
}

const narrow_index_words = 512;
const narrow_index_middle = narrow_index_words / 2;

/// Runs one access in a child and answers how the child ended: 0 when the access reached the
/// word the typed index names, 1 when it reached another, and a signal when it left the mapping.
fn narrowIndexEnding(
    comptime form: NarrowIndexForm,
    native: anytype,
    source: i64,
    typed: i64,
) !sys.process.Termination {
    const child = switch (try sys.process.fork()) {
        .child => {
            sys.signal.restoreDefault(.ILL);
            sys.signal.restoreDefault(.SEGV);
            var words: [narrow_index_words]i64 = undefined;
            for (&words, 0..) |*word, at| word.* = 1000 + @as(i64, @intCast(at));
            const middle: [*]i64 = words[narrow_index_middle..].ptr;
            const want: usize = @intCast(narrow_index_middle + typed);
            const reached = switch (form) {
                .load, .atomic => native(middle, source) == words[want],
                .store => stored: {
                    _ = native(middle, source, -7);
                    break :stored words[want] == -7;
                },
                .view => viewed: {
                    const bytes: [*]u8 = @ptrCast(middle);
                    // A byte offset: the typed value names the byte the word read starts at.
                    const got = native(bytes, source);
                    const distance: usize = @intCast(@abs(typed));
                    const start = if (typed < 0) bytes - distance else bytes + distance;
                    break :viewed got == std.mem.readInt(i64, start[0..8], .little);
                },
            };
            sys.process.exit(if (reached) 0 else 1);
        },
        .parent => |pid| pid,
    };
    return sys.process.waitDirect(child);
}

/// What a comparison's other side is: a second parameter, or a literal on the right or the left.
/// `written` is the spelling handed to the constructor when that differs from the value, as a
/// producer that does not write the kind's canonical word would hand it.
const CompareSide = union(enum) {
    parameter,
    literal: struct { value: i64, written: ?i64 = null, left: bool = false },
};

/// `returned(x) -> bool` answers `cmp predicate x, other`, and `branched(x) -> i64` answers 1
/// or 0 from an `scf.if` on the same comparison, which reads the flags without the stored bool.
/// With a parameter on the other side both take `(x, y)`.
fn compareModule(
    ir_ctx: *ir.Context,
    kind: dialects.arith.ScalarKind,
    predicate: dialects.arith.CmpPredicate,
    side: CompareSide,
) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;
    const loc = ir.Location.getUnknown();
    const int_type = try ArithDialect.getScalarType(ir_ctx, kind);
    const bool_type = try ArithDialect.getScalarType(ir_ctx, .bool);
    const i64_type = try ArithDialect.getScalarType(ir_ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ir_ctx, loc);

    const parameters: []const ir.Type = if (side == .parameter) &.{ int_type, int_type } else &.{int_type};
    const returned = try FuncDialect.FuncOp.create(ir_ctx, loc, "returned", parameters, &.{bool_type});
    try module.getBodyBlock().addOperation(returned.op);
    {
        const entry = returned.getEntryBlock();
        const sides = try compareOperands(ir_ctx, entry, returned, int_type, side);
        const cmp = try ArithDialect.CmpOp.create(ir_ctx, loc, predicate, sides[0], sides[1]);
        try entry.addOperation(cmp.op);
        try entry.addOperation((try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{cmp.getResult()})).op);
    }

    const branched = try FuncDialect.FuncOp.create(ir_ctx, loc, "branched", parameters, &.{i64_type});
    try module.getBodyBlock().addOperation(branched.op);
    {
        const entry = branched.getEntryBlock();
        const sides = try compareOperands(ir_ctx, entry, branched, int_type, side);
        const cmp = try ArithDialect.CmpOp.create(ir_ctx, loc, predicate, sides[0], sides[1]);
        try entry.addOperation(cmp.op);
        const pick = try ScfDialect.IfOp.create(ir_ctx, loc, cmp.getResult(), &.{i64_type});
        try entry.addOperation(pick.op);
        const one = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, i64_type, 1);
        try pick.getThenBlock().addOperation(one.op);
        try pick.getThenBlock().addOperation((try ScfDialect.YieldOp.create(ir_ctx, loc, &.{one.getResult()})).op);
        const zero = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, i64_type, 0);
        try pick.getElseBlock().?.addOperation(zero.op);
        try pick.getElseBlock().?.addOperation((try ScfDialect.YieldOp.create(ir_ctx, loc, &.{zero.getResult()})).op);
        try entry.addOperation((try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{pick.op.getResult(0).?})).op);
    }
    return module.op;
}

/// The two operands of `function`'s comparison, in order, with any literal added to `entry`.
fn compareOperands(
    ir_ctx: *ir.Context,
    entry: *ir.Block,
    function: dialects.FuncDialect.FuncOp,
    int_type: ir.Type,
    side: CompareSide,
) ![2]*ir.Value {
    const x = function.getArgument(0);
    const literal = switch (side) {
        .parameter => return .{ x, function.getArgument(1) },
        .literal => |literal| literal,
    };
    const spelled = literal.written orelse literal.value;
    const constant = try dialects.ArithDialect.ConstantOp.createInt(ir_ctx, ir.Location.getUnknown(), int_type, spelled);
    try entry.addOperation(constant.op);
    return if (literal.left) .{ constant.getResult(), x } else .{ x, constant.getResult() };
}

/// The readers the first narrow index witness left out, one function each:
///
///     far_u32(m: memref<i64>, x: i64) -> i64     { return load m[cast x to u32] }
///     at_u16(m: memref<u8>, i: u16) -> u8        { return load m[i] }
///     fixed_u16(m: memref<u8>) -> u8             { return load m[40000 as u16] }
///     walk_i32(m: memref<i64>, lo: i64, hi: i64) -> i64
///         { for i in i32(lo)..i32(hi): acc += m[i]; m[i] = acc }
///
/// `walk_i32` answers the last `acc`, so its index is carried by the loop and read by a load and
/// by a store in every turn.
fn indexSeamModule(ctx: *ir.Context) !*ir.Operation {
    const Arith = dialects.ArithDialect;
    const Func = dialects.FuncDialect.FuncOp;
    const Load = dialects.MemrefDialect.LoadOp;
    const loc = ir.Location.getUnknown();
    const i64_type = try Arith.getScalarType(ctx, .i64);
    const u32_type = try Arith.getScalarType(ctx, .u32);
    const u16_type = try Arith.getScalarType(ctx, .u16);
    const u8_type = try Arith.getScalarType(ctx, .u8);
    const words_type = try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, i64_type, .host);
    const bytes_type = try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, u8_type, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    const body = module.getBodyBlock();
    {
        const func = try Func.create(ctx, loc, "far_u32", &.{ words_type, i64_type }, &.{i64_type});
        try body.addOperation(func.op);
        const entry = func.getEntryBlock();
        const index = try Arith.CastOp.create(ctx, loc, func.getArgument(1), u32_type);
        try entry.addOperation(index.op);
        var loaded = try Load.create(ctx, loc, func.getArgument(0), index.getResult(), i64_type);
        try entry.addOperation(loaded.op);
        try returnValue(ctx, entry, loaded.getResult());
    }
    {
        const func = try Func.create(ctx, loc, "at_u16", &.{ bytes_type, u16_type }, &.{u8_type});
        try body.addOperation(func.op);
        const entry = func.getEntryBlock();
        var loaded = try Load.create(ctx, loc, func.getArgument(0), func.getArgument(1), u8_type);
        try entry.addOperation(loaded.op);
        try returnValue(ctx, entry, loaded.getResult());
    }
    {
        const func = try Func.create(ctx, loc, "fixed_u16", &.{bytes_type}, &.{u8_type});
        try body.addOperation(func.op);
        const entry = func.getEntryBlock();
        const index = try Arith.ConstantOp.createInt(ctx, loc, u16_type, index_seam_u16);
        try entry.addOperation(index.op);
        var loaded = try Load.create(ctx, loc, func.getArgument(0), index.getResult(), u8_type);
        try entry.addOperation(loaded.op);
        try returnValue(ctx, entry, loaded.getResult());
    }
    try addIndexWalk(ctx, body);
    return module.op;
}

/// `walk_i32`, whose index is the counter of an `scf.for` and so is carried from turn to turn.
fn addIndexWalk(ctx: *ir.Context, module_body: *ir.Block) !void {
    const Arith = dialects.ArithDialect;
    const Func = dialects.FuncDialect.FuncOp;
    const Load = dialects.MemrefDialect.LoadOp;
    const Store = dialects.MemrefDialect.StoreOp;
    const Scf = dialects.ScfDialect;
    const loc = ir.Location.getUnknown();
    const i64_type = try Arith.getScalarType(ctx, .i64);
    const i32_type = try Arith.getScalarType(ctx, .i32);
    const words_type = try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, i64_type, .host);
    const params = [_]ir.Type{ words_type, i64_type, i64_type };
    const func = try Func.create(ctx, loc, "walk_i32", &params, &.{i64_type});
    try module_body.addOperation(func.op);
    const entry = func.getEntryBlock();
    const memory = func.getArgument(0);
    const low = try Arith.CastOp.create(ctx, loc, func.getArgument(1), i32_type);
    try entry.addOperation(low.op);
    const high = try Arith.CastOp.create(ctx, loc, func.getArgument(2), i32_type);
    try entry.addOperation(high.op);
    const one = try Arith.ConstantOp.createInt(ctx, loc, i32_type, 1);
    try entry.addOperation(one.op);
    const zero = try Arith.ConstantOp.createInt(ctx, loc, i64_type, 0);
    try entry.addOperation(zero.op);
    const from = low.getResult();
    const to = high.getResult();
    const carried = [_]*ir.Value{zero.getResult()};
    const For = Scf.ForOp;
    const loop = try For.create(ctx, loc, from, to, one.getResult(), &carried, &.{i64_type});
    try entry.addOperation(loop.op);
    const turn = loop.getBodyBlock();
    const index = turn.arguments.items[0];
    var loaded = try Load.create(ctx, loc, memory, index, i64_type);
    try turn.addOperation(loaded.op);
    const next = try Arith.AddOp.create(ctx, loc, turn.arguments.items[1], loaded.getResult());
    try turn.addOperation(next.op);
    try turn.addOperation((try Store.create(ctx, loc, next.getResult(), memory, index)).op);
    try turn.addOperation((try Scf.YieldOp.create(ctx, loc, &.{next.getResult()})).op);
    try returnValue(ctx, entry, loop.op.getResult(0).?);
}

fn returnValue(ctx: *ir.Context, block: *ir.Block, value: *ir.Value) !void {
    const loc = ir.Location.getUnknown();
    try block.addOperation((try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{value})).op);
}

/// A u16 with its top bit set, so reading it by its sign addresses 25536 bytes before the base.
const index_seam_u16 = 40000;
/// A u32 with its top bit set. Extended by zeros it names a word 16 GiB past the base, and
/// extended by its sign a word 16 GiB before it.
const index_seam_u32 = 0x8000_0001;
const index_seam_far_byte = index_seam_u32 * @sizeOf(i64);

/// What the sparse child found before it could call `far_u32`.
const far_index_unreserved = 3;
const far_index_unprotected = 4;

/// Runs `far_u32` in a child over a sparse mapping: the whole extent is reserved and only the
/// page holding the word its zero-extended index names is backed. The child exits 0 when the
/// function answers that word.
fn farIndexEnding(native: *const fn ([*]i64, i64) callconv(.c) i64) !sys.process.Termination {
    const child = switch (try sys.process.fork()) {
        .child => {
            sys.signal.restoreDefault(.ILL);
            sys.signal.restoreDefault(.SEGV);
            const page = sys.memory.pageSize();
            const extent = sys.memory.reserveAddressSpace(index_seam_far_byte + page) catch
                sys.process.exit(far_index_unreserved);
            const start = std.mem.alignBackward(usize, index_seam_far_byte, page);
            const backed: []align(std.heap.page_size_min) u8 = @alignCast(extent[start..][0..page]);
            sys.memory.protect(backed, .{ .read = true, .write = true }) catch
                sys.process.exit(far_index_unprotected);
            const words: [*]i64 = @ptrCast(extent.ptr);
            words[index_seam_u32] = 0x5EA7;
            // Junk above the kind's width, as the first witness spells it.
            const source = narrowIndexSource(u32, index_seam_u32);
            sys.process.exit(if (native(words, source) == 0x5EA7) 0 else 1);
        },
        .parent => |pid| pid,
    };
    return sys.process.waitDirect(child);
}

/// The byte a u16 index of 40000 names, and the byte the same bits name read as an i16.
const index_seam_u16_byte = 0x5C;
const index_seam_i16_byte = 0xA3;
/// How far before the base the index read as an i16 lands.
const index_seam_before = 0x1_0000 - index_seam_u16;

const NearIndexFunctions = struct {
    at_u16: *const fn ([*]u8, u16) callconv(.c) u8,
    fixed_u16: *const fn ([*]u8) callconv(.c) u8,
    walk_i32: *const fn ([*]i64, i64, i64) callconv(.c) i64,
};

/// Runs the u16 readers and the loop in a child, since a wrong reader may address memory no test
/// owns. The u16 base sits inside a buffer that holds both the byte its index names and the byte
/// the index read by its sign names. The child's exit says which answer was wrong, and 0 says
/// none was.
fn nearIndexEnding(native: NearIndexFunctions) !sys.process.Termination {
    const child = switch (try sys.process.fork()) {
        .child => {
            sys.signal.restoreDefault(.ILL);
            sys.signal.restoreDefault(.SEGV);
            const before = index_seam_before;
            var bytes: [before + index_seam_u16 + 1]u8 = @splat(0);
            bytes[0] = index_seam_i16_byte;
            bytes[before + index_seam_u16] = index_seam_u16_byte;
            const base: [*]u8 = bytes[before..].ptr;
            if (native.at_u16(base, index_seam_u16) != index_seam_u16_byte) sys.process.exit(1);
            if (native.fixed_u16(base) != index_seam_u16_byte) sys.process.exit(2);

            // Turns -2, -1, 0 and 1 around the base, with junk above bit 31 of both bounds.
            var words = [_]i64{ 0, 0, 10, 20, 30, 40, 0, 0 };
            const low = narrowIndexSource(i32, -2);
            const total = native.walk_i32(words[4..].ptr, low, narrowIndexSource(i32, 2));
            if (total != 100) sys.process.exit(3);
            const stored = [_]i64{ 0, 0, 10, 30, 60, 100, 0, 0 };
            sys.process.exit(if (std.mem.eql(i64, &stored, &words)) 0 else 4);
        },
        .parent => |pid| pid,
    };
    return sys.process.waitDirect(child);
}
