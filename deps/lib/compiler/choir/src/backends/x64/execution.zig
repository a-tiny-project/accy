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

test "x86_64 Runtime machine-code artifact failures leave no loaded state" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const code = @as([16]u8, @splat(0));

    var malformed = try artifact.machineCodeArtifact(
        testing.allocator,
        artifact_target,
        artifact_abi,
        "malformed_entry",
        fixture.nullary_integer,
        &code,
        &.{},
        &.{.{ .offset = 12, .symbol = "choir_decl_add1", .kind = .call }},
    );
    defer malformed.deinit();
    var runtime = try Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("choir_decl_add1", @intFromPtr(&fixture.declAdd1));
    try testing.expectError(error.InvalidArtifact, runtime.loadArtifact(&malformed));
    try testing.expectEqual(@as(usize, 0), runtime.modules.items.len);

    var unresolved = try artifact.machineCodeArtifact(
        testing.allocator,
        artifact_target,
        artifact_abi,
        "unresolved_entry",
        fixture.nullary_integer,
        &code,
        &.{},
        &.{.{ .offset = 0, .symbol = "missing_external", .kind = .call }},
    );
    defer unresolved.deinit();
    var unresolved_runtime = try Runtime.init(testing.allocator, .testing);
    defer unresolved_runtime.deinit();
    try testing.expectError(error.SymbolNotFound, unresolved_runtime.loadArtifact(&unresolved));
    try testing.expectEqual(@as(usize, 0), unresolved_runtime.modules.items.len);

    var valid = try artifact.machineCodeArtifact(
        testing.allocator,
        artifact_target,
        artifact_abi,
        "allocation_entry",
        fixture.nullary_integer,
        &code,
        &.{.{ .name = "allocation_table", .bytes = "\x01\x02", .alignment = 8 }},
        &.{
            .{ .offset = 0, .symbol = "choir_decl_add1", .kind = .call },
            .{ .offset = 8, .symbol = "allocation_table", .kind = .absolute },
        },
    );
    defer valid.deinit();
    var reached_success = false;
    var fail_offset: usize = 0;
    while (fail_offset < 32) : (fail_offset += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var allocation_runtime = try Runtime.init(failing.allocator(), .testing);
        defer allocation_runtime.deinit();
        try allocation_runtime.registerExternalSymbol("choir_decl_add1", @intFromPtr(&fixture.declAdd1));
        failing.fail_index = failing.alloc_index + fail_offset;
        if (allocation_runtime.loadArtifact(&valid)) |_| {
            reached_success = true;
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), allocation_runtime.modules.items.len);
        }
    }
    try testing.expect(reached_success);
}

test "x86_64 Runtime patches data addresses into loaded machine code" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const movabs_rax = [2]u8{ 0x48, 0xb8 };
    const movabs_rdx = [2]u8{ 0x48, 0xba };
    const ret_opcode = 0xc3;
    const unreached_movabs_rcx = [2]u8{ 0x48, 0xb9 };
    var code = @as([31]u8, @splat(0));
    code[0..2].* = movabs_rax;
    code[10..12].* = movabs_rdx;
    code[20] = ret_opcode;
    code[21..23].* = unreached_movabs_rcx;
    const table = "\x10\x20\x30\x40\x50";
    const page = "page bytes";
    const addresses_signature = try artifact.Signature.init(
        &.{},
        &.{ .{ .scalar = .index }, .{ .scalar = .index } },
    );
    var loadable = try artifact.machineCodeArtifact(
        testing.allocator,
        artifact_target,
        artifact_abi,
        "data_entry",
        addresses_signature,
        &code,
        &.{
            .{ .name = "table", .bytes = table, .alignment = 4 },
            .{ .name = "page", .bytes = page, .alignment = machine.max_data_alignment },
        },
        &.{
            .{ .offset = 2, .symbol = "table", .kind = .absolute, .addend = 3 },
            .{ .offset = 12, .symbol = "page", .kind = .absolute },
            .{ .offset = 23, .symbol = "data_entry", .kind = .call },
        },
    );
    defer loadable.deinit();

    var runtime = try Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.loadArtifact(&loadable);
    const Addresses = extern struct { table: usize, page: usize };
    const Entry = *const fn () callconv(.c) Addresses;
    const entry = try runtime.getFunction(handle, "data_entry", Entry);
    const addresses = entry();
    const table_address = addresses.table - 3;
    try testing.expect(std.mem.isAligned(table_address, 4));
    try testing.expectEqualSlices(u8, table, fixture.bytesAt(table_address, table.len));
    try testing.expect(std.mem.isAligned(addresses.page, machine.max_data_alignment));
    try testing.expectEqualSlices(u8, page, fixture.bytesAt(addresses.page, page.len));

    const entry_address = try runtime.functionAddress(handle, "data_entry");
    const self_call = fixture.bytesAt(entry_address + 23, 8)[0..8];
    try testing.expectEqual(@as(u64, entry_address), std.mem.readInt(u64, self_call, .little));
}

test "x86_64 Runtime rejects malformed data artifacts" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const code = @as([16]u8, @splat(0));
    const table = MalformedDataArtifact.table;
    const reference = MalformedDataArtifact.reference;
    const narrow_window = artifact.Relocation{
        .offset = 0,
        .symbol = "table",
        .kind = .absolute,
        .width_bits = 32,
    };
    const call_with_addend = artifact.Relocation{
        .offset = 0,
        .symbol = "choir_decl_add1",
        .kind = .call,
        .addend = 1,
    };
    const cases = [_]MalformedDataArtifact{
        .{ .relocations = &.{.{ .offset = 0, .symbol = "missing", .kind = .absolute }} },
        .{ .relocations = &.{.{ .offset = 0, .symbol = "malformed_entry", .kind = .absolute }} },
        .{ .data = &.{ table, .{ .name = "malformed_entry", .bytes = "\x03" } } },
        .{ .data = &.{.{ .name = "table", .bytes = "\x01\x02", .alignment = 3 }} },
        .{ .data = &.{.{ .name = "table", .bytes = "" }} },
        .{ .data = &.{.{ .name = "table", .bytes = "\x01\x02", .binding = .weak }} },
        .{ .data = &.{ table, table } },
        .{ .relocations = &.{ reference, .{ .offset = 4, .symbol = "table", .kind = .absolute } } },
        .{ .relocations = &.{.{ .offset = 9, .symbol = "table", .kind = .absolute }} },
        .{ .relocations = &.{narrow_window} },
        .{ .relocations = &.{call_with_addend} },
        .{ .relocations = &.{.{ .offset = 0, .symbol = "table", .kind = .unknown }} },
        .{ .orphan_buffer = true },
    };

    var runtime = try Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("choir_decl_add1", @intFromPtr(&fixture.declAdd1));
    for (cases) |case| {
        var malformed = try artifact.machineCodeArtifact(
            testing.allocator,
            artifact_target,
            artifact_abi,
            "malformed_entry",
            fixture.nullary_integer,
            &code,
            case.data,
            case.relocations,
        );
        defer malformed.deinit();
        if (case.orphan_buffer) {
            try malformed.payload.addBuffer(.{ .name = "orphan", .format = .raw, .bytes = "\x03" });
        }
        try testing.expectError(error.InvalidArtifact, runtime.loadArtifact(&malformed));
        try testing.expectEqual(@as(usize, 0), runtime.modules.items.len);
    }
}

test "x86_64 Runtime refuses artifacts without a signature it can call" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const code = @as([16]u8, @splat(0xc3));
    const lanes = artifact.ValueType{ .vector = .{ .element = .f32, .lanes = 4 } };
    var no_lanes = try artifact.Signature.init(&.{}, &.{lanes});
    no_lanes.result_types[0].vector.lanes = 0;
    const refused = [_]?artifact.Signature{
        null,
        try artifact.Signature.init(&.{lanes}, &.{}),
        try artifact.Signature.init(&.{}, &.{ lanes, .{ .scalar = .f32 } }),
        no_lanes,
    };
    var runtime = try Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();
    for (refused) |signature| {
        var unsigned = try artifact.machineCodeArtifact(
            testing.allocator,
            artifact_target,
            artifact_abi,
            "entry",
            fixture.nullary_integer,
            &code,
            &.{},
            &.{},
        );
        defer unsigned.deinit();
        unsigned.linkage.provided_symbols.items[0].signature = signature;
        try testing.expectError(error.InvalidArtifact, runtime.loadArtifact(&unsigned));
        try testing.expectEqual(@as(usize, 0), runtime.modules.items.len);
    }
}

test "x86_64 Runtime failed compiles keep previously compiled modules" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const kept_module = try fixture.constantModule(&ctx, "kept", 7);
    defer kept_module.erase();
    const staged_module = try fixture.constantModule(&ctx, "staged", 8);
    defer staged_module.erase();
    const staged_table = machine.DataSymbol{
        .name = "staged_table",
        .bytes = "staged bytes",
        .alignment = 8,
    };
    const table_function = try fixture.dataFunction(&ctx, "staged_table", staged_table);
    try fixture.addFunction(staged_module, table_function);

    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();

    const Constant = *const fn () callconv(.c) i64;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var runtime = try Runtime.init(failing.allocator(), .testing);
    defer runtime.deinit();
    const kept = try runtime.compile(kept_module);
    const kept_value = try runtime.getFunction(kept, "kept", Constant);

    var reached_success = false;
    var fail_offset: usize = 0;
    while (fail_offset < 128) : (fail_offset += 1) {
        failing.fail_index = failing.alloc_index + fail_offset;
        if (runtime.compile(staged_module)) |staged| {
            failing.fail_index = std.math.maxInt(usize);
            const staged_value = try runtime.getFunction(staged, "staged", Constant);
            try testing.expectEqual(@as(i64, 8), staged_value());
            const table_address = try fixture.addressFrom(&runtime, staged, "staged_table");
            const table_bytes = fixture.bytesAt(table_address, staged_table.bytes.len);
            try testing.expectEqualStrings(staged_table.bytes, table_bytes);
            reached_success = true;
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try expectEmitterFunctionStateDiscarded(&runtime);
            try testing.expectEqual(@as(usize, 1), runtime.modules.items.len);
            try testing.expectEqual(@as(i64, 7), kept_value());
        }
    }
    try testing.expect(reached_success);
    try testing.expectEqual(@as(i64, 7), kept_value());
    try testing.expectEqual(@as(usize, 0), reports.diagnostics.items.len);
}

test "x86_64 Runtime modules share equal data symbols and refuse conflicting ones" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const table = machine.DataSymbol{ .name = "table", .bytes = "shared" };
    const shared = try fixture.dataModule(&ctx, "first", table);
    defer shared.erase();
    try fixture.addFunction(shared, try fixture.dataFunction(&ctx, "second", table));
    try fixture.addFunction(shared, try fixture.dataDeltaFunction(&ctx, "delta", table, 5));

    const Value = *const fn () callconv(.c) i64;
    var runtime = try Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(shared);
    const first = (try runtime.getFunction(handle, "first", Value))();
    try testing.expectEqual(first, (try runtime.getFunction(handle, "second", Value))());
    try testing.expectEqual(@as(i64, 5), (try runtime.getFunction(handle, "delta", Value))());

    const conflicting = try fixture.dataModule(&ctx, "first", table);
    defer conflicting.erase();
    const different = machine.DataSymbol{ .name = "table", .bytes = "different" };
    const second = try fixture.dataFunction(&ctx, "second", different);
    try fixture.addFunction(conflicting, second);

    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();
    try testing.expectError(error.JitCompileFailed, runtime.compile(conflicting));
    try testing.expectEqual(@as(usize, 1), runtime.modules.items.len);
    try expectEmitterFunctionStateDiscarded(&runtime);
    try testing.expectEqual(@as(usize, 1), reports.diagnostics.items.len);
    const conflict = reports.diagnostics.items[0];
    try testing.expectEqual(second, conflict.operation.?);
    try testing.expectEqualStrings("ConflictingDataSymbol", conflict.metadata[1].value);
}

test "x86_64 Runtime modules outlive their IR until released" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();

    var constants: Handle = undefined;
    var identity: Handle = undefined;
    const identity_name = "temporary_memref_identity";
    {
        var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
        defer ctx.deinit(testing.allocator);
        try dialects.registerAllDialects(&ctx);
        const resource_baseline = fixture.IrResourceCounts.capture(&ctx);

        const module = try fixture.constantModule(&ctx, "temporary_first", 41);
        var module_owned = true;
        errdefer if (module_owned) module.erase();
        const caller = try fixture.callingFunction(&ctx, "temporary_caller", "temporary_first");
        try module.getRegion(0).?.getEntryBlock().?.addOperation(caller);
        constants = try runtime.compile(module);
        try expectEmitterFunctionStateDiscarded(&runtime);
        module.erase();
        module_owned = false;
        try resource_baseline.expectEqual(&ctx);

        const identity_module = try fixture.memrefIdentityModule(&ctx, identity_name);
        var identity_owned = true;
        errdefer if (identity_owned) identity_module.erase();
        identity = try runtime.compile(identity_module);
        try expectEmitterFunctionStateDiscarded(&runtime);
        identity_module.erase();
        identity_owned = false;
        try resource_baseline.expectEqual(&ctx);
    }

    const Constant = *const fn () callconv(.c) i64;
    const first_entry = try runtime.getFunction(constants, "temporary_first", Constant);
    try testing.expectEqual(@as(i64, 41), first_entry());
    const caller_entry = try runtime.getFunction(constants, "temporary_caller", Constant);
    try testing.expectEqual(@as(i64, 41), caller_entry());
    const first_signature = try runtime.functionSignature(constants, "temporary_first");
    try testing.expect(first_signature.eql(&fixture.nullary_integer));

    const memref_identity = try artifact.Signature.init(&.{.memref}, &.{.memref});
    const identity_signature = try runtime.functionSignature(identity, identity_name);
    try testing.expect(identity_signature.eql(&memref_identity));
    const Identity = *const fn (*anyopaque) callconv(.c) *anyopaque;
    const identity_entry = try runtime.getFunction(identity, identity_name, Identity);
    const address: *anyopaque = @ptrFromInt(0x1234_5678);
    try testing.expectEqual(address, identity_entry(address));

    try runtime.release(constants);
    const released = runtime.getFunction(constants, "temporary_first", Constant);
    try testing.expectError(error.InvalidModuleHandle, released);
    try testing.expectError(error.InvalidModuleHandle, runtime.release(constants));
    const low: *anyopaque = @ptrFromInt(0x42);
    try testing.expectEqual(low, identity_entry(low));
    try runtime.release(identity);
    for (runtime.modules.items) |module| try testing.expect(!module.live);
}

test "x86_64 Runtime patches extern call targets for memref alloc/free" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, i64_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "memref_roundtrip", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var size = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 1);
    try entry.addOperation(size.op);

    var alloc = try MemrefDialect.AllocOp.createDynamic(&ir_ctx, loc, size.getResult(), memref_type);
    try entry.addOperation(alloc.op);

    const dealloc = try MemrefDialect.DeallocOp.create(&ir_ctx, loc, alloc.getResult());
    try entry.addOperation(dealloc.op);

    var zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try entry.addOperation(zero.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{zero.getResult()});
    try entry.addOperation(ret.op);

    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ir_ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("malloc", 0);
    try runtime.registerExternalSymbol("free", 0);
    try testing.expectError(error.SymbolNotFound, runtime.compile(module.op));
    try testing.expectEqual(@as(usize, 1), reports.diagnostics.items.len);
    try testing.expectEqual(func.op, reports.diagnostics.items[0].operation.?);
    try runtime.registerExternalSymbol("malloc", @intFromPtr(&sys.heap.malloc));
    try runtime.registerExternalSymbol("free", @intFromPtr(&sys.heap.free));
    const handle = try runtime.compile(module.op);

    const compiled = runtime.modules.items[handle.index];
    const function = compiled.functions.get("memref_roundtrip") orelse return error.FunctionNotFound;
    const address = compiled.functionAddress(&function);
    const code: []const u8 = @as([*]const u8, @ptrFromInt(address))[0..function.size];

    var malloc_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, malloc_bytes[0..], @intCast(@intFromPtr(&sys.heap.malloc)), .little);
    var free_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, free_bytes[0..], @intCast(@intFromPtr(&sys.heap.free)), .little);

    try testing.expect(std.mem.indexOf(u8, code, malloc_bytes[0..]) != null);
    try testing.expect(std.mem.indexOf(u8, code, free_bytes[0..]) != null);
}

test "x86_64 Runtime treats bodyless func declarations as extern symbols" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const decl_name = "choir_decl_add1";
    const declaration = try FuncDialect.FuncOp.createDeclaration(
        &ir_ctx,
        loc,
        decl_name,
        &.{i64_type},
        &.{i64_type},
    );
    try module_block.addOperation(declaration.op);

    var caller = try FuncDialect.FuncOp.create(&ir_ctx, loc, "call_decl", &.{}, &.{i64_type});
    try module_block.addOperation(caller.op);

    const entry = caller.getEntryBlock();
    var forty_one = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 41);
    try entry.addOperation(forty_one.op);

    var call = try FuncDialect.CallOp.create(&ir_ctx, loc, decl_name, &.{forty_one.getResult()}, &.{i64_type});
    try entry.addOperation(call.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{call.getResult(0).?});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol(decl_name, @intFromPtr(&fixture.declAdd1));
    const handle = try runtime.compile(module.op);

    try testing.expectError(error.FunctionNotFound, runtime.functionAddress(handle, decl_name));
    const entry_fn = try runtime.getFunction(handle, "call_decl", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 42), entry_fn());
}

test "x86_64 Runtime requires explicit extern symbol registration" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const decl_name = "choir_unregistered_external";
    const declaration = try FuncDialect.FuncOp.createDeclaration(
        &ir_ctx,
        loc,
        decl_name,
        &.{i64_type},
        &.{i64_type},
    );
    try module_block.addOperation(declaration.op);

    var caller = try FuncDialect.FuncOp.create(&ir_ctx, loc, "call_unregistered_decl", &.{}, &.{i64_type});
    try module_block.addOperation(caller.op);

    const entry = caller.getEntryBlock();
    var forty_one = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 41);
    try entry.addOperation(forty_one.op);

    var call = try FuncDialect.CallOp.create(&ir_ctx, loc, decl_name, &.{forty_one.getResult()}, &.{i64_type});
    try entry.addOperation(call.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{call.getResult(0).?});
    try entry.addOperation(ret.op);

    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ir_ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("malloc", 0);
    try runtime.registerExternalSymbol("free", 0);
    try testing.expectError(error.SymbolNotFound, runtime.compile(module.op));
    try testing.expectEqual(@as(usize, 0), runtime.modules.items.len);
    try testing.expectEqual(@as(usize, 1), reports.diagnostics.items.len);
    const unresolved = reports.diagnostics.items[0];
    try testing.expectEqual(call.op, unresolved.operation.?);
    try testing.expectEqualStrings(failures.Stage.link.name(), unresolved.metadata[0].value);

    try runtime.registerExternalSymbol(decl_name, @intFromPtr(&fixture.declAdd1));
    const handle = try runtime.compile(module.op);
    const entry_fn = try runtime.getFunction(handle, "call_unregistered_decl", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 42), entry_fn());
}

test "x86_64 Runtime rejects functions beyond the result record bound" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    var results: [sysv.max_result_count + 1]ir.Type = undefined;
    @memset(&results, i64_type);
    const wide = try FuncDialect.FuncOp.create(&ctx, loc, "wide", &.{i64_type}, &results);
    try module.getBodyBlock().addOperation(wide.op);
    var operands: [results.len]*ir.Value = undefined;
    @memset(&operands, wide.getArgument(0));
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &operands);
    try wide.getEntryBlock().addOperation(ret.op);

    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();

    var runtime = try Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.UnsupportedOperation, runtime.compile(module.op));
    try testing.expectEqual(@as(usize, 0), runtime.modules.items.len);
    try testing.expectEqual(@as(usize, 1), reports.diagnostics.items.len);
    const rejected = reports.diagnostics.items[0];
    try testing.expectEqual(wide.op, rejected.operation.?);
    try testing.expectEqualStrings(legality.stage, rejected.metadata[0].value);

    // Legality refuses first, so the emitter's own bound is driven through the emission hook.
    try testing.expectError(error.TooManyResults, Target.emit(&runtime.compiler, wide.op));
    try testing.expectEqual(@as(?*ir.Operation, null), Target.failedOperation(&runtime.compiler));
    Target.discard(&runtime.compiler);
    try expectEmitterFunctionStateDiscarded(&runtime);
}

test "x86_64 Runtime locates emission failures at the innermost failing operation" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getFile("failing-jit.choir", 5, 3);
    const u64_type = try ArithDialect.getScalarType(&ctx, .u64);
    const module = try fixture.constantModule(&ctx, "kept", 7);
    const function = try FuncDialect.FuncOp.create(&ctx, loc, "shift", &.{}, &.{u64_type});
    try fixture.addFunction(module, function.op);
    const entry = function.getEntryBlock();
    const value = try ArithDialect.ConstantOp.createInt(&ctx, loc, u64_type, 16);
    try entry.addOperation(value.op);
    const condition = try ArithDialect.ConstantOp.createBool(&ctx, loc, true);
    try entry.addOperation(condition.op);
    const branch = try ScfDialect.IfOp.create(&ctx, loc, condition.getResult(), &.{u64_type});
    try entry.addOperation(branch.op);
    const shift = try ArithDialect.ShrOp.create(&ctx, loc, value.getResult(), value.getResult());
    try branch.getThenBlock().addOperation(shift.op);
    const shifted = try ScfDialect.YieldOp.create(&ctx, loc, &.{shift.getResult()});
    try branch.getThenBlock().addOperation(shifted.op);
    const unshifted = try ScfDialect.YieldOp.create(&ctx, loc, &.{value.getResult()});
    try branch.getElseBlock().?.addOperation(unshifted.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{branch.op.getResult(0).?});
    try entry.addOperation(ret.op);

    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();

    var runtime = try Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.JitCompileFailed, runtime.compile(module));
    try expectEmitterFunctionStateDiscarded(&runtime);
    try testing.expectEqual(@as(usize, 0), runtime.modules.items.len);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
    try testing.expectEqual(@as(usize, 1), reports.diagnostics.items.len);
    const rejected = reports.diagnostics.items[0];
    try testing.expectEqual(shift.op, rejected.operation.?);
    try testing.expectEqualStrings(failures.Stage.emit.name(), rejected.metadata[0].value);
    try testing.expectEqualStrings("UnsupportedType", rejected.metadata[1].value);
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

test "x86_64 Runtime enters the kernel through a func.syscall" {
    if (!executes) return error.SkipZigTest;
    if (!sys.capabilities.current.isLinux()) {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "syscall_getpid", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var number = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, linux_getpid);
    try entry.addOperation(number.op);
    const entered = try FuncDialect.SyscallOp.create(&ir_ctx, loc, number.getResult(), &.{}, i64_type);
    try entry.addOperation(entered.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{entered.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);
    const entry_fn = try runtime.getFunction(handle, "syscall_getpid", *const fn () callconv(.c) i64);

    const expected: i64 = try sys.process.currentProcessId();
    try testing.expectEqual(expected, entry_fn());
}

test "x86_64 Runtime passes a func.syscall argument three in r10" {
    if (!executes) return error.SkipZigTest;
    if (!sys.capabilities.current.isLinux()) {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(
        &ir_ctx,
        loc,
        "syscall_read_signal_mask",
        &.{ i64_type, i64_type },
        &.{i64_type},
    );
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var number = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, linux_rt_sigprocmask);
    try entry.addOperation(number.op);
    var how = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, linux_sig_setmask);
    try entry.addOperation(how.op);
    var no_new_mask = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try entry.addOperation(no_new_mask.op);

    const arguments = [_]*ir.Value{
        how.getResult(),
        no_new_mask.getResult(),
        func.getArgument(0),
        func.getArgument(1),
    };
    const entered = try FuncDialect.SyscallOp.create(&ir_ctx, loc, number.getResult(), &arguments, i64_type);
    try entry.addOperation(entered.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{entered.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);
    const entry_fn = try runtime.getFunction(
        handle,
        "syscall_read_signal_mask",
        *const fn (i64, i64) callconv(.c) i64,
    );

    var observed: u64 = 0;
    const address: i64 = @intCast(@intFromPtr(&observed));

    try testing.expectEqual(@as(i64, 0), entry_fn(address, linux_signal_set_bytes));
    try testing.expectEqual(linux_einval, entry_fn(address, linux_signal_set_bytes - 1));
    try testing.expectEqual(linux_efault, entry_fn(1, linux_signal_set_bytes));
}

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

test "x86_64 Runtime resolves a zeroed global and a constant one to storage" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const module = try buildGlobalModule(&ir_ctx);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);
    const next = try runtime.getFunction(handle, "next", *const fn () callconv(.c) i64);
    const entry_of = try runtime.getFunction(handle, "entry_of", *const fn (i64) callconv(.c) i64);

    try testing.expectEqual(@as(i64, 0), next());
    try testing.expectEqual(@as(i64, 1), next());
    try testing.expectEqual(@as(i64, 2), next());

    for (pin_table_words, 0..) |word, index| {
        try testing.expectEqual(word, @as(u64, @bitCast(entry_of(@intCast(index)))));
    }
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

test "x86_64 Runtime promotes into a module region through writable globals" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const module = try buildRegionModule(&ir_ctx);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);
    const bump = try runtime.getFunction(handle, "bump", *const fn (i64) callconv(.c) i64);
    const peek = try runtime.getFunction(handle, "peek", *const fn (i64) callconv(.c) i64);
    const cursor = try runtime.getFunction(handle, "cursor", *const fn () callconv(.c) i64);

    try testing.expectEqual(@as(i64, 0), cursor());
    for (pin_values, 0..) |value, index| {
        const expected: i64 = @intCast(index * @as(usize, @intCast(pin_word_bytes)));
        try testing.expectEqual(expected, bump(value));
    }
    try testing.expectEqual(@as(i64, 24), cursor());

    for (pin_values, 0..) |value, index| {
        const offset: i64 = @intCast(index * @as(usize, @intCast(pin_word_bytes)));
        try testing.expectEqual(@as(u64, @bitCast(value)), readRegionWord(peek, offset));
    }
    try testing.expectEqual(@as(u64, 0), readRegionWord(peek, 24));
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

test "x86_64 Runtime keeps values live across a call without the call site saving them" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const module = try buildAcrossModule(&ir_ctx);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);
    const across = try runtime.getFunction(handle, "across", *const fn (i64) callconv(.c) i64);

    var expected: i64 = across_argument;
    for (across_addends) |addend| expected += addend;
    for (across_addends) |addend| expected += across_argument + addend;

    try testing.expectEqual(expected, across(across_argument));
}

test "x86_64 Runtime legality and emission refusals leave an earlier module callable" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;
    const Constant = *const fn () callconv(.c) i64;

    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();

    var runtime = try Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();
    const kept_module = try fixture.constantModule(&ctx, "kept", 23);
    defer kept_module.erase();
    const kept = try runtime.compile(kept_module);
    const kept_value = try runtime.getFunction(kept, "kept", Constant);
    const mapped = runtime.mapped_bytes;

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    const wide_module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer wide_module.op.erase();
    var results: [sysv.max_result_count + 1]ir.Type = undefined;
    @memset(&results, i64_type);
    const wide = try FuncDialect.FuncOp.create(&ctx, loc, "wide", &.{i64_type}, &results);
    try wide_module.getBodyBlock().addOperation(wide.op);
    var operands: [results.len]*ir.Value = undefined;
    @memset(&operands, wide.getArgument(0));
    const wide_return = try FuncDialect.ReturnOp.create(&ctx, loc, &operands);
    try wide.getEntryBlock().addOperation(wide_return.op);
    try testing.expectError(error.UnsupportedOperation, runtime.compile(wide_module.op));

    const u64_type = try ArithDialect.getScalarType(&ctx, .u64);
    const shift_module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer shift_module.op.erase();
    const function = try FuncDialect.FuncOp.create(&ctx, loc, "shift", &.{}, &.{u64_type});
    try shift_module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const value = try ArithDialect.ConstantOp.createInt(&ctx, loc, u64_type, 16);
    try entry.addOperation(value.op);
    const condition = try ArithDialect.ConstantOp.createBool(&ctx, loc, true);
    try entry.addOperation(condition.op);
    const branch = try ScfDialect.IfOp.create(&ctx, loc, condition.getResult(), &.{u64_type});
    try entry.addOperation(branch.op);
    const shift = try ArithDialect.ShrOp.create(&ctx, loc, value.getResult(), value.getResult());
    try branch.getThenBlock().addOperation(shift.op);
    const shifted = try ScfDialect.YieldOp.create(&ctx, loc, &.{shift.getResult()});
    try branch.getThenBlock().addOperation(shifted.op);
    const unshifted = try ScfDialect.YieldOp.create(&ctx, loc, &.{value.getResult()});
    try branch.getElseBlock().?.addOperation(unshifted.op);
    const shift_return = try FuncDialect.ReturnOp.create(&ctx, loc, &.{branch.op.getResult(0).?});
    try entry.addOperation(shift_return.op);
    try testing.expectError(error.JitCompileFailed, runtime.compile(shift_module.op));

    try testing.expectEqual(@as(usize, 2), reports.diagnostics.items.len);
    try testing.expectEqual(@as(u32, 1), runtime.live_modules);
    try testing.expectEqual(mapped, runtime.mapped_bytes);
    try testing.expectEqual(@as(usize, 1), runtime.modules.items.len);
    try testing.expectEqual(@as(i64, 23), kept_value());
    try testing.expectEqual(@as(?execution.Refusal, null), runtime.refusal);
}
