//! The x86_64 execution target: System V code on Linux, run through `execution.Runtime`.

const std = @import("std");
const profile = @import("sys").capabilities.current;
const executes = profile.os == .linux and profile.arch == .x86_64 and profile.pointerWidthBits() == 64;
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
    pub const executable_policy: sys.memory.ExecutablePolicy = .linux;
    /// `malloc` and `free`, which memref allocation calls, then the math library.
    pub const builtin_count: usize = 2 + sys.math.symbols.len;
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

    pub fn initCompiler(allocator: Allocator) Compiler {
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
    pub fn lower(allocator: Allocator, module: *ir.Operation) execution.LowerError!void {
        _ = backend.lowerModule(allocator, module, null) catch |err| return switch (err) {
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
        };
    }

    pub fn takeLineTable(compiler: *Compiler) Allocator.Error!debug_info.LineTable {
        return compiler.takeLineTable();
    }

    /// The emitted function's code buffer, handed over whole. The next function reserves
    /// its own.
    pub fn takeCode(compiler: *Compiler) Allocator.Error![]u8 {
        return compiler.code.toOwnedSlice(compiler.allocator);
    }

    pub fn recordLines(compiler: *Compiler, on: bool) void {
        compiler.record_lines = on;
    }

    pub fn failedOperation(compiler: *const Compiler) ?*ir.Operation {
        return compiler.failed_operation;
    }

    pub fn discard(compiler: *Compiler) void {
        compiler.discardFunctionState();
    }

    pub fn report(failure: execution.Failure) void {
        failures.Failure.report(.{
            .stage = switch (failure.stage) {
                .emit => .emit,
                .link => .link,
            },
            .operation = failure.operation,
            .err = failure.err,
            .symbol = failure.symbol,
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
