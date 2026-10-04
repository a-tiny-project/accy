//! The scalar and borrowed-word Apple arm64 Target for canonical Choir execution.

const std = @import("std");
const ir = @import("../../core/root.zig");
const backends = @import("../root.zig");
const artifact = backends.artifact;
const contract = backends.contract;
const debug_info = backends.debug_info;
const execution = @import("../execution/root.zig");
const backend = @import("backend.zig");
const invoke = @import("invoke.zig");
const placement = @import("placement.zig");
const sys = @import("sys");

const Allocator = std.mem.Allocator;
const Signature = artifact.Signature;

pub const Target = struct {
    pub const unavailable: ?[]const u8 = null;
    pub const architecture: artifact.Architecture = .aarch64;
    pub const abi: artifact.Abi = .{
        .name = "apple-arm64",
        .calling_convention = "c",
        .pointer_width_bits = 64,
        .endianness = .little,
    };
    pub const relocation_bytes: usize = 8;
    pub const allowsSerializedArtifact: bool = false;
    /// Only the inspected startup-linked, non-hardened arm64 product with a macOS 11.4+
    /// deployment target uses this policy. The fixed producer proves those properties before
    /// its hash-gated execution; it does not admit an arbitrary hardened or late-loaded host.
    pub const executable_policy: sys.memory.ExecutablePolicy = .macos_non_hardened;
    pub const builtin_count: usize = 0;
    pub const Compiler = backend.Emitter;
    pub const EmitError = @typeInfo(@typeInfo(@TypeOf(Compiler.emitFunction)).@"fn".return_type.?).error_union.error_set;

    pub fn builtin(_: usize) execution.Builtin {
        unreachable;
    }

    pub fn initCompiler(allocator: Allocator) Compiler {
        var compiler = Compiler.init(allocator);
        compiler.diagnose = false;
        return compiler;
    }

    pub fn deinitCompiler(compiler: *Compiler) void {
        compiler.deinit();
    }

    pub fn prepare(ctx: *ir.Context) Allocator.Error!void {
        return contract.loadArithDialect(ctx);
    }

    pub fn lower(_: Allocator, module: *ir.Operation) execution.LowerError!void {
        backend.lowerModule(module) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.VerificationFailed => error.VerificationFailed,
            error.UnsupportedOperation => error.UnsupportedOperation,
            else => error.CodeGenFailed,
        };
    }

    pub fn emit(compiler: *Compiler, func: *ir.Operation) EmitError!execution.Emitted {
        try compiler.emitFunction(func);
        try compiler.padCodeToImageAlignment();
        return .{
            .code = compiler.code.items,
            .calls = compiler.calls.items,
            .data = compiler.data_symbols.items(),
            .data_relocations = compiler.data_relocations.items,
            .outgrew_reservation = compiler.code.items.len > compiler.reservation_before_emit,
        };
    }

    /// The scalar emitter has no source-line mapping. An enabled line table is empty.
    pub fn takeLineTable(compiler: *Compiler) Allocator.Error!debug_info.LineTable {
        var builder = debug_info.LineTableBuilder.init(compiler.allocator);
        return builder.finish();
    }

    pub fn recordLines(_: *Compiler, _: bool) void {}

    pub fn takeCode(compiler: *Compiler) Allocator.Error![]u8 {
        return compiler.code.toOwnedSlice(compiler.allocator);
    }

    pub fn failedOperation(compiler: *const Compiler) ?*ir.Operation {
        return compiler.failed_operation;
    }

    pub fn discard(compiler: *Compiler) void {
        compiler.discard();
    }

    pub fn report(failure: execution.Failure) void {
        if (failure.err == error.OutOfMemory) return;
        var diagnostic = failure.operation.emitError(switch (failure.stage) {
            .emit => "Apple arm64 native emission failed",
            .link => "Apple arm64 native link failed",
        });
        defer diagnostic.deinit();
        _ = diagnostic.emit() catch {};
    }

    pub fn admitsSignature(signature: *const Signature) bool {
        if (!signature.isValid()) return false;
        if (signature.parameter_count > backend.max_arguments) return false;
        if (signature.result_count > backend.max_results) return false;
        var floating_width: ?artifact.ScalarType = null;
        for (signature.parameters()) |parameter| {
            switch (parameter) {
                .memref => {},
                else => if (!scalarArgument(parameter)) return false,
            }
            if (parameter == .scalar and (parameter.scalar == .f32 or parameter.scalar == .f64)) {
                if (floating_width) |width| {
                    if (width != parameter.scalar) return false;
                } else floating_width = parameter.scalar;
            }
        }
        for (signature.results()) |result| {
            if (!scalarArgument(result)) return false;
            if (result == .scalar and (result.scalar == .f32 or result.scalar == .f64)) {
                if (floating_width) |width| {
                    if (width != result.scalar) return false;
                } else floating_width = result.scalar;
            }
        }
        return true;
    }

    pub fn patch(code: []u8, offset: usize, address: u64) void {
        std.debug.assert(offset <= code.len);
        std.debug.assert(code.len - offset >= relocation_bytes);
        std.mem.writeInt(u64, code[offset..][0..relocation_bytes], address, .little);
    }

    pub fn enter(address: usize, signature: *const Signature, args: []const execution.Value, results: []execution.Value) void {
        std.debug.assert(admitsSignature(signature));
        invoke.call(address, signature, args, results);
    }
};

fn scalarArgument(value_type: artifact.ValueType) bool {
    return switch (value_type) {
        .scalar => |scalar| switch (scalar) {
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .bool, .index, .f32, .f64 => true,
        },
        else => false,
    };
}

fn scalarModule(
    ctx: *ir.Context,
    name: []const u8,
    kind: @import("../../dialects/root.zig").arith.ScalarKind,
    arity: usize,
    has_result: bool,
) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const scalar = try dialects.ArithDialect.getScalarType(ctx, kind);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const parameters: [backend.max_arguments]ir.Type = @splat(scalar);
    const results: [1]ir.Type = .{scalar};
    const function = try dialects.FuncDialect.FuncOp.create(
        ctx,
        loc,
        name,
        parameters[0..arity],
        if (has_result) &results else &.{},
    );
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    if (has_result) {
        const value = if (arity != 0)
            function.getArgument(arity - 1)
        else blk: {
            const constant = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, scalar, 42);
            try entry.addOperation(constant.op);
            break :blk constant.getResult();
        };
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{value});
        try entry.addOperation(ret.op);
    } else {
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{});
        try entry.addOperation(ret.op);
    }
    return module.op;
}

const global_words = [_]u8{
    0x11, 0,    0,    0,    0,    0,    0,    0x80,
    0x19, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
};

const global_first: u64 = 0x8000_0000_0000_0011;
const global_last: u64 = 0xffff_ffff_ffff_ff19;

const GlobalCase = enum { read_only, writable, zeroed, wrong_type, wrong_element, dead_wrong_type, zero_extent, nonhost, weak_alignment, missing, stored, called };

fn globalWordModule(ctx: *ir.Context, case: GlobalCase) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const signed = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const index = try dialects.ArithDialect.getIndexType(ctx);
    const table_type = try dialects.MemrefDialect.getMemrefType1D(ctx, if (case == .zero_extent) 0 else 2, word, if (case == .nonhost) .device else .host);
    const wrong_type = try dialects.MemrefDialect.getMemrefType1D(ctx, 1, word, .host);
    const wrong_element = try dialects.MemrefDialect.getMemrefType1D(ctx, 2, signed, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    if (case != .missing) {
        const table = try dialects.MemrefDialect.GlobalOp.create(ctx, loc, .{
            .sym_name = "words",
            .memref_type = table_type,
            .alignment = if (case == .weak_alignment) 4 else 8,
            .constant = case != .writable and case != .zeroed,
            .initial = if (case == .zeroed) null else if (case == .zero_extent) &.{} else &global_words,
        });
        try module.getBodyBlock().addOperation(table.op);
    }
    if (case == .called) {
        const sink = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "global_sink", &.{table_type}, &.{});
        try module.getBodyBlock().addOperation(sink.op);
    }
    for ([_][]const u8{ "global_word", "global_word_again" }) |name| {
        const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, name, &.{word}, &.{word});
        try module.getBodyBlock().addOperation(function.op);
        const entry = function.getEntryBlock();
        const word_index = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), index);
        try entry.addOperation(word_index.op);
        const second = std.mem.eql(u8, name, "global_word_again");
        const zero = if (second) try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 0) else null;
        if (zero) |constant| try entry.addOperation(constant.op);
        if (case == .dead_wrong_type) {
            const dead = try dialects.MemrefDialect.GetGlobalOp.create(ctx, loc, "words", wrong_type);
            try entry.addOperation(dead.op);
        }
        const reference = try dialects.MemrefDialect.GetGlobalOp.create(ctx, loc, "words", switch (case) {
            .wrong_type => wrong_type,
            .wrong_element => wrong_element,
            else => table_type,
        });
        try entry.addOperation(reference.op);
        if (case == .called) {
            const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "global_sink", &.{reference.getResult()}, &.{});
            try entry.addOperation(call.op);
        }
        if (case == .stored) {
            const value = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 7);
            try entry.addOperation(value.op);
            const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, value.getResult(), reference.getResult(), word_index.getResult());
            try entry.addOperation(store.op);
        }
        const load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, reference.getResult(), word_index.getResult(), if (case == .wrong_element) signed else word);
        try entry.addOperation(load.op);
        const loaded = if (case == .wrong_element) blk: {
            const cast = try dialects.ArithDialect.CastOp.create(ctx, loc, load.getResult(), word);
            try entry.addOperation(cast.op);
            break :blk cast.getResult();
        } else load.getResult();
        const value = if (zero) |constant| blk: {
            const add = try dialects.ArithDialect.AddOp.create(ctx, loc, loaded, constant.getResult());
            try entry.addOperation(add.op);
            break :blk add.getResult();
        } else loaded;
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{value});
        try entry.addOperation(ret.op);
    }
    return module.op;
}

fn expectGlobalRefusal(module: *ir.Operation) !void {
    if (backend.lowerModule(module)) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expect(err == error.UnsupportedOperation or err == error.VerificationFailed);
    }
}

test "aarch64 native execution carries one initialized read-only global through repeated references" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(failing.allocator(), .testing, .macos_non_hardened);
    defer runtime.deinit();
    var expected_charge: u64 = 0;
    const handle = blk: {
        var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
        defer ctx.deinit(testing.allocator);
        try dialects.registerAllDialects(&ctx);
        const module = try globalWordModule(&ctx, .read_only);
        defer module.erase();
        try backend.lowerModule(module);
        var compiler = Target.initCompiler(testing.allocator);
        defer Target.deinitCompiler(&compiler);
        var staged: @import("../execution/image.zig").ImageBuilder = .{};
        defer staged.deinit(testing.allocator);
        for ([_][]const u8{ "global_word", "global_word_again" }) |name| {
            const function = ir.inspection.functionDefinitionByName(module, name).?;
            const emitted = try Target.emit(&compiler, function);
            const code = try Target.takeCode(&compiler);
            _ = try staged.append(testing.allocator, emitted, code);
            Target.discard(&compiler);
            try testing.expectEqual(@as(usize, 0), compiler.data_symbols.items().len);
            try testing.expectEqual(@as(usize, 0), compiler.data_relocations.items.len);
        }
        try testing.expectEqual(@as(usize, 1), staged.data.items().len);
        try testing.expectEqual(@as(usize, 2), staged.data_relocations.items.len);
        try testing.expectEqualSlices(u8, &global_words, staged.data.items()[0].bytes);
        var literal_parities: [2]bool = @splat(false);
        for (staged.data_relocations.items) |relocation| {
            try testing.expectEqualStrings("words", relocation.target);
            try testing.expectEqual(@as(u16, 64), relocation.width_bits);
            try testing.expectEqual(@as(i64, 0), relocation.addend);
            try testing.expectEqual(@as(usize, 0), relocation.offset % 8);
            try testing.expect(relocation.offset + 8 <= staged.code.items.len);
            var found_literal = false;
            for ([_]usize{ 8, 12 }) |distance| {
                if (relocation.offset < distance) continue;
                const start = relocation.offset - distance;
                const load = std.mem.readInt(u32, staged.code.items[start..][0..4], .little);
                const branch = std.mem.readInt(u32, staged.code.items[start + 4 ..][0..4], .little);
                if ((load & 0xff00_0000) != 0x5800_0000 or (branch & 0xfc00_0000) != 0x1400_0000) continue;
                try testing.expectEqual(relocation.offset, start + @as(usize, (load >> 5) & 0x7ffff) * 4);
                try testing.expectEqual(relocation.offset + 8, start + 4 + @as(usize, branch & 0x3ffffff) * 4);
                literal_parities[start % 8 / 4] = true;
                found_literal = true;
                break;
            }
            try testing.expect(found_literal);
        }
        try testing.expect(literal_parities[0] and literal_parities[1]);
        const image = @import("../execution/image.zig");
        expected_charge = image.mappedSize(staged.code.items.len) + image.mappedSize(global_words.len);
        break :blk try runtime.compile(module);
    };
    try testing.expectEqual(expected_charge, runtime.mapped_bytes);
    const first = try runtime.getFunction(handle, "global_word", *const fn (u64) callconv(.c) u64);
    const second = try runtime.getFunction(handle, "global_word_again", *const fn (u64) callconv(.c) u64);
    try testing.expectEqual(global_first, first(0));
    try testing.expectEqual(global_last, first(1));
    try testing.expectEqual(global_last, second(1));
    var result = [_]execution.Value{.{ .u64 = 0 }};
    try runtime.call(handle, "global_word_again", &.{.{ .u64 = 0 }}, &result);
    try testing.expectEqual(global_first, result[0].u64);
    try testing.expectEqual(@as(u32, 1), runtime.live_modules);
    try testing.expectEqual(expected_charge, runtime.mapped_bytes);
    {
        var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
        defer ctx.deinit(testing.allocator);
        try dialects.registerAllDialects(&ctx);
        const retry = try globalWordModule(&ctx, .read_only);
        defer retry.erase();
        failing.fail_index = failing.alloc_index;
        try testing.expectError(error.OutOfMemory, runtime.compile(retry));
        failing.fail_index = std.math.maxInt(usize);
        try testing.expectEqual(@as(u32, 1), runtime.live_modules);
        try testing.expectEqual(expected_charge, runtime.mapped_bytes);
        try testing.expectEqual(global_last, first(1));
    }
    try runtime.release(handle);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}

test "aarch64 native execution refuses writable unresolved or escaping globals before publication" {
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    for ([_]GlobalCase{ .writable, .zeroed, .wrong_type, .wrong_element, .dead_wrong_type, .zero_extent, .nonhost, .weak_alignment, .missing, .stored, .called }) |case| {
        const module = try globalWordModule(&ctx, case);
        defer module.erase();
        try expectGlobalRefusal(module);
    }
    const unused = try globalWordModule(&ctx, .read_only);
    defer unused.erase();
    const word = try dialects.ArithDialect.getScalarType(&ctx, .u64);
    const table_type = try dialects.MemrefDialect.getMemrefType1D(&ctx, 1, word, .host);
    const extra = try dialects.MemrefDialect.GlobalOp.create(&ctx, ir.Location.getUnknown(), .{
        .sym_name = "unused_writable",
        .memref_type = table_type,
        .alignment = 8,
        .initial = global_words[0..8],
    });
    try (dialects.BuiltinDialect.ModuleOp{ .op = unused }).getBodyBlock().addOperation(extra.op);
    try expectGlobalRefusal(unused);
    const duplicate = try globalWordModule(&ctx, .read_only);
    defer duplicate.erase();
    const identical = try dialects.MemrefDialect.GlobalOp.create(&ctx, ir.Location.getUnknown(), .{
        .sym_name = "words",
        .memref_type = try dialects.MemrefDialect.getMemrefType1D(&ctx, 2, word, .host),
        .alignment = 8,
        .constant = true,
        .initial = &global_words,
    });
    try (dialects.BuiltinDialect.ModuleOp{ .op = duplicate }).getBodyBlock().addOperation(identical.op);
    try expectGlobalRefusal(duplicate);
    const outer = try dialects.BuiltinDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    defer outer.op.erase();
    const outer_table = try dialects.MemrefDialect.GlobalOp.create(&ctx, ir.Location.getUnknown(), .{
        .sym_name = "words",
        .memref_type = try dialects.MemrefDialect.getMemrefType1D(&ctx, 2, word, .host),
        .alignment = 8,
        .constant = true,
        .initial = &global_words,
    });
    try outer.getBodyBlock().addOperation(outer_table.op);
    const inner = try globalWordModule(&ctx, .missing);
    try outer.getBodyBlock().addOperation(inner);
    try expectGlobalRefusal(inner);
    const nested_with_own_global = try globalWordModule(&ctx, .read_only);
    try outer.getBodyBlock().addOperation(nested_with_own_global);
    try expectGlobalRefusal(nested_with_own_global);
    const module = try globalWordModule(&ctx, .read_only);
    defer module.erase();
    var producer = try backend.Backend.init(testing.allocator, &ctx);
    defer producer.deinit();
    try testing.expectError(error.UnsupportedOperation, producer.compileFunctionToMachineCode(module, "global_word"));
    try testing.expectError(error.UnsupportedOperation, producer.compileFunctionToArtifact(module, "global_word"));
    const function = ir.inspection.functionDefinitionByName(module, "global_word").?;
    try backend.lowerModule(module);
    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(function);
    try testing.expectEqual(@as(usize, 1), emitter.data_symbols.items().len);
    try testing.expectEqual(@as(usize, 1), emitter.data_relocations.items.len);
    try testing.expectEqual(@as(u16, 64), emitter.data_relocations.items[0].width_bits);
    const relocation = emitter.data_relocations.items[0];
    try testing.expectEqualStrings("words", relocation.target);
    try testing.expect(relocation.offset + 8 <= emitter.code.items.len);
    const zeros: [8]u8 = @splat(0);
    try testing.expectEqualSlices(u8, &zeros, emitter.code.items[relocation.offset..][0..8]);
}

test "aarch64 native execution frees partial global symbol and relocation emission" {
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try globalWordModule(&ctx, .read_only);
    defer module.erase();
    try backend.lowerModule(module);
    const function = ir.inspection.functionDefinitionByName(module, "global_word").?;
    var refused_symbol = false;
    var refused_relocation = false;
    var completed = false;
    for (0..64) |failure_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = failure_index });
        var emitter = backend.Emitter.init(failing.allocator());
        defer emitter.deinit();
        if (emitter.emitFunction(function)) |_| {
            completed = true;
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            if (emitter.first_data_operation == null) continue;
            if (emitter.data_symbols.items().len == 0) refused_symbol = true;
            if (emitter.data_symbols.items().len == 1 and emitter.data_relocations.items.len == 0 and emitter.code.items.len >= 8) {
                const tail = emitter.code.items[emitter.code.items.len - 8 ..];
                const zeros: [8]u8 = @splat(0);
                if (std.mem.eql(u8, tail, &zeros)) refused_relocation = true;
            }
        }
    }
    try testing.expect(refused_symbol);
    try testing.expect(refused_relocation);
    try testing.expect(completed);
}

/// Eight live constants cross a conditional region, exceeding the seven placement registers.
/// The result exercises the same framed spill and branch path through canonical publication.
fn structuredPressureModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const bool_type = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(
        ctx,
        loc,
        "pressure_branch",
        &.{bool_type},
        &.{i64_type},
    );
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var values: [placement.max_registers + 1]*ir.Value = undefined;
    for (&values, 0..) |*value, index| {
        const constant = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, @intCast(index + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const branch = try dialects.ScfDialect.IfOp.create(ctx, loc, function.getArgument(0), &.{i64_type});
    try entry.addOperation(branch.op);
    const then_block = branch.getThenBlock();
    var sum = values[0];
    for (values[1..]) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, value);
        try then_block.addOperation(add.op);
        sum = add.getResult();
    }
    const then_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{sum});
    try then_block.addOperation(then_yield.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 0);
    try branch.getElseBlock().?.addOperation(zero.op);
    const else_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{zero.getResult()});
    try branch.getElseBlock().?.addOperation(else_yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{branch.getResult(0).?});
    try entry.addOperation(ret.op);
    return module.op;
}

fn callPressureModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const bool_type = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "pressure_oracle", &.{i64_type}, &.{i64_type});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "call_pressure", &.{bool_type}, &.{i64_type});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var values: [placement.max_registers + 1]*ir.Value = undefined;
    for (&values, 0..) |*value, index| {
        const constant = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, @intCast(index + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const branch = try dialects.ScfDialect.IfOp.create(ctx, loc, function.getArgument(0), &.{i64_type});
    try entry.addOperation(branch.op);
    const then_block = branch.getThenBlock();
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "pressure_oracle", &.{values[0]}, &.{i64_type});
    try then_block.addOperation(call.op);
    var sum = call.getResult(0).?;
    for (values) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, value);
        try then_block.addOperation(add.op);
        sum = add.getResult();
    }
    const then_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{sum});
    try then_block.addOperation(then_yield.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 0);
    try branch.getElseBlock().?.addOperation(zero.op);
    const else_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{zero.getResult()});
    try branch.getElseBlock().?.addOperation(else_yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{branch.getResult(0).?});
    try entry.addOperation(ret.op);
    return module.op;
}

fn loopCallModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const index_type = try dialects.ArithDialect.getScalarType(ctx, .index);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "loop_oracle", &.{index_type}, &.{index_type});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "loop_calls", &.{index_type}, &.{index_type});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index_type, 0);
    try entry.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index_type, 1);
    try entry.addOperation(one.op);
    const loop = try dialects.ScfDialect.ForOp.create(ctx, loc, zero.getResult(), function.getArgument(0), one.getResult(), &.{zero.getResult()}, &.{index_type});
    try entry.addOperation(loop.op);
    const body = loop.getBodyBlock();
    const called = try dialects.FuncDialect.CallOp.create(ctx, loc, "loop_oracle", &.{body.arguments.items[0]}, &.{index_type});
    try body.addOperation(called.op);
    const next = try dialects.ArithDialect.AddOp.create(ctx, loc, body.arguments.items[1], called.getResult(0).?);
    try body.addOperation(next.op);
    const yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{next.getResult()});
    try body.addOperation(yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{loop.op.getResult(0).?});
    try entry.addOperation(ret.op);
    return module.op;
}

fn directCallModule(ctx: *ir.Context, external_name: []const u8) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();

    const sum = try dialects.FuncDialect.FuncOp.create(ctx, loc, "sum", &.{ i64_type, i64_type }, &.{i64_type});
    try module.getBodyBlock().addOperation(sum.op);
    const addition = try dialects.ArithDialect.AddOp.create(ctx, loc, sum.getArgument(0), sum.getArgument(1));
    try sum.getEntryBlock().addOperation(addition.op);
    const sum_return = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{addition.getResult()});
    try sum.getEntryBlock().addOperation(sum_return.op);

    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, external_name, &.{i64_type}, &.{i64_type});
    try module.getBodyBlock().addOperation(external.op);

    const middle = try dialects.FuncDialect.FuncOp.create(ctx, loc, "middle", &.{i64_type}, &.{i64_type});
    try module.getBodyBlock().addOperation(middle.op);
    const forwarded = try dialects.FuncDialect.CallOp.create(ctx, loc, external_name, &.{middle.getArgument(0)}, &.{i64_type});
    try middle.getEntryBlock().addOperation(forwarded.op);
    const middle_return = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{forwarded.getResult(0).?});
    try middle.getEntryBlock().addOperation(middle_return.op);

    const entry = try dialects.FuncDialect.FuncOp.create(ctx, loc, "call_entry", &.{ i64_type, i64_type }, &.{i64_type});
    try module.getBodyBlock().addOperation(entry.op);
    const internal = try dialects.FuncDialect.CallOp.create(
        ctx,
        loc,
        "sum",
        &.{ entry.getArgument(1), entry.getArgument(0) },
        &.{i64_type},
    );
    try entry.getEntryBlock().addOperation(internal.op);
    const outgoing = try dialects.FuncDialect.CallOp.create(
        ctx,
        loc,
        "middle",
        &.{internal.getResult(0).?},
        &.{i64_type},
    );
    try entry.getEntryBlock().addOperation(outgoing.op);
    const retained = try dialects.ArithDialect.AddOp.create(ctx, loc, outgoing.getResult(0).?, entry.getArgument(0));
    try entry.getEntryBlock().addOperation(retained.op);
    const entry_return = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{retained.getResult()});
    try entry.getEntryBlock().addOperation(entry_return.op);
    return module.op;
}

fn scalarExternalOracle(value: i64) callconv(.c) i64 {
    return value * 3 + 1;
}

var stack_word_observed: u64 = 0;

fn staticWordOracle(value: u64) callconv(.c) void {
    stack_word_observed = value;
}

fn conflictingExternalSum(left: i64, right: i64) callconv(.c) i64 {
    return 1000 + left + right;
}

fn narrowCallModule(ctx: *ir.Context, kind: @import("../../dialects/root.zig").arith.ScalarKind, name: []const u8) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const scalar = try dialects.ArithDialect.getScalarType(ctx, kind);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, name, &.{scalar}, &.{scalar});
    try module.getBodyBlock().addOperation(external.op);
    const entry = try dialects.FuncDialect.FuncOp.create(ctx, loc, "narrow_entry", &.{scalar}, &.{scalar});
    try module.getBodyBlock().addOperation(entry.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, name, &.{entry.getArgument(0)}, &.{scalar});
    try entry.getEntryBlock().addOperation(call.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{call.getResult(0).?});
    try entry.getEntryBlock().addOperation(ret.op);
    return module.op;
}

fn narrowWidenCallModule(
    ctx: *ir.Context,
    parameter_kind: @import("../../dialects/root.zig").arith.ScalarKind,
    result_kind: @import("../../dialects/root.zig").arith.ScalarKind,
    name: []const u8,
) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const parameter = try dialects.ArithDialect.getScalarType(ctx, parameter_kind);
    const result = try dialects.ArithDialect.getScalarType(ctx, result_kind);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, name, &.{parameter}, &.{result});
    try module.getBodyBlock().addOperation(external.op);
    const entry = try dialects.FuncDialect.FuncOp.create(ctx, loc, "widen_entry", &.{parameter}, &.{result});
    try module.getBodyBlock().addOperation(entry.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, name, &.{entry.getArgument(0)}, &.{result});
    try entry.getEntryBlock().addOperation(call.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{call.getResult(0).?});
    try entry.getEntryBlock().addOperation(ret.op);
    return module.op;
}

fn signedNarrowOracle(value: i8) callconv(.c) i8 {
    return value;
}

fn unsignedNarrowOracle(value: u8) callconv(.c) u8 {
    return value;
}

fn signedWidenOracle(value: i8) callconv(.c) i64 {
    return value;
}

fn unsignedWidenOracle(value: u8) callconv(.c) u64 {
    return value;
}

fn booleanOracle(value: bool) callconv(.c) bool {
    return !value;
}

fn indexOracle(value: usize) callconv(.c) usize {
    return value + 1;
}

fn arityCallModule(ctx: *ir.Context, arity: usize, name: []const u8) !*ir.Operation {
    std.debug.assert(arity == 0 or arity == backend.max_arguments);
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const types: [backend.max_arguments]ir.Type = @splat(i64_type);
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, name, types[0..arity], &.{i64_type});
    try module.getBodyBlock().addOperation(external.op);
    const entry = try dialects.FuncDialect.FuncOp.create(ctx, loc, "arity_entry", types[0..arity], &.{i64_type});
    try module.getBodyBlock().addOperation(entry.op);
    var operands: [backend.max_arguments]*ir.Value = undefined;
    for (operands[0..arity], 0..) |*operand, index| operand.* = entry.getArgument(arity - index - 1);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, name, operands[0..arity], &.{i64_type});
    try entry.getEntryBlock().addOperation(call.op);
    const result = if (arity == 0) call.getResult(0).? else blk: {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, call.getResult(0).?, entry.getArgument(0));
        try entry.getEntryBlock().addOperation(add.op);
        break :blk add.getResult();
    };
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{result});
    try entry.getEntryBlock().addOperation(ret.op);
    return module.op;
}

fn scalarExternalZero() callconv(.c) i64 {
    return 42;
}

fn scalarExternalEight(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64) callconv(.c) i64 {
    return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h;
}

var void_observed: i64 = 0;

fn scalarVoidOracle(value: i64) callconv(.c) void {
    void_observed = value;
}

fn voidCallModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "void_oracle", &.{i64_type}, &.{});
    try module.getBodyBlock().addOperation(external.op);
    const entry = try dialects.FuncDialect.FuncOp.create(ctx, loc, "void_entry", &.{i64_type}, &.{});
    try module.getBodyBlock().addOperation(entry.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "void_oracle", &.{entry.getArgument(0)}, &.{});
    try entry.getEntryBlock().addOperation(call.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{});
    try entry.getEntryBlock().addOperation(ret.op);
    return module.op;
}

fn borrowedCopyModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "borrowed_copy", &.{ buffer, buffer, index }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, function.getArgument(0), function.getArgument(2), word);
    try entry.addOperation(load.op);
    const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, load.getResult(), function.getArgument(1), function.getArgument(2));
    try entry.addOperation(store.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{load.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

/// Every value read from this entry-local payload is stored first. No result
/// depends on a newly reserved stack slot's unspecified initial contents.
fn staticAllocaModule(ctx: *ir.Context, words: u64, with_call: bool) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefType1D(ctx, words, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    if (with_call) {
        const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "stack_void_oracle", &.{word}, &.{});
        try module.getBodyBlock().addOperation(external.op);
    }
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "stack_words", &.{ word, word }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const alloca = try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    try entry.addOperation(alloca.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero.op);
    const last = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, @intCast(words - 1));
    try entry.addOperation(last.op);
    const first_store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, function.getArgument(0), alloca.getResult(), zero.getResult());
    try entry.addOperation(first_store.op);
    const last_store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, function.getArgument(1), alloca.getResult(), last.getResult());
    try entry.addOperation(last_store.op);
    if (with_call) {
        const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "stack_void_oracle", &.{function.getArgument(0)}, &.{});
        try entry.addOperation(call.op);
    }
    const first_load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), zero.getResult(), word);
    try entry.addOperation(first_load.op);
    const last_load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), last.getResult(), word);
    try entry.addOperation(last_load.op);
    const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, first_load.getResult(), last_load.getResult());
    try entry.addOperation(sum.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

fn twoStaticAllocasModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefType1D(ctx, 2, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "two_stack_words", &.{ word, word }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const first = try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    try entry.addOperation(first.op);
    const second = try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    try entry.addOperation(second.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 1);
    try entry.addOperation(one.op);
    const marker_a = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 101);
    try entry.addOperation(marker_a.op);
    const marker_b = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 202);
    try entry.addOperation(marker_b.op);
    for ([_]struct { value: *ir.Value, memref: *ir.Value, offset: *ir.Value }{
        .{ .value = marker_a.getResult(), .memref = first.getResult(), .offset = zero.getResult() },
        .{ .value = function.getArgument(0), .memref = first.getResult(), .offset = one.getResult() },
        .{ .value = function.getArgument(1), .memref = second.getResult(), .offset = zero.getResult() },
        .{ .value = marker_b.getResult(), .memref = second.getResult(), .offset = one.getResult() },
    }) |write| {
        const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, write.value, write.memref, write.offset);
        try entry.addOperation(store.op);
    }
    const left = try dialects.MemrefDialect.LoadOp.create(ctx, loc, first.getResult(), one.getResult(), word);
    try entry.addOperation(left.op);
    const right = try dialects.MemrefDialect.LoadOp.create(ctx, loc, second.getResult(), zero.getResult(), word);
    try entry.addOperation(right.op);
    const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, left.getResult(), right.getResult());
    try entry.addOperation(sum.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

fn spilledStaticAllocaModule(ctx: *ir.Context) !BorrowedSpill {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefType1D(ctx, 2, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const oracle = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "stack_word_oracle", &.{word}, &.{});
    try module.getBodyBlock().addOperation(oracle.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "spilled_stack_words", &.{ index, word }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var live: [placement.max_registers + 1]*ir.Value = undefined;
    for (&live, 0..) |*value, position| {
        const constant = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, @intCast(position + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const alloca = try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    try entry.addOperation(alloca.op);
    const zero_index = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero_index.op);
    const computed_index = try dialects.ArithDialect.AddOp.create(ctx, loc, function.getArgument(0), zero_index.getResult());
    try entry.addOperation(computed_index.op);
    const zero_word = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 0);
    try entry.addOperation(zero_word.op);
    const computed_value = try dialects.ArithDialect.AddOp.create(ctx, loc, function.getArgument(1), zero_word.getResult());
    try entry.addOperation(computed_value.op);
    const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, computed_value.getResult(), alloca.getResult(), computed_index.getResult());
    try entry.addOperation(store.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "stack_word_oracle", &.{computed_value.getResult()}, &.{});
    try entry.addOperation(call.op);
    const load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), computed_index.getResult(), word);
    try entry.addOperation(load.op);
    var total = load.getResult();
    for (live) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, total, value);
        try entry.addOperation(add.op);
        total = add.getResult();
    }
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{total});
    try entry.addOperation(ret.op);
    return .{ .module = module.op, .pointer = alloca.getResult(), .index = computed_index.getResult(), .value = computed_value.getResult() };
}

fn staticAllocaLoopModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefType1D(ctx, 2, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const oracle = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "stack_scalar_oracle", &.{word}, &.{word});
    try module.getBodyBlock().addOperation(oracle.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "stack_loop", &.{ index, word }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const alloca = try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    try entry.addOperation(alloca.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 1);
    try entry.addOperation(one.op);
    const nine = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 9);
    try entry.addOperation(nine.op);
    const initial_store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, function.getArgument(1), alloca.getResult(), zero.getResult());
    try entry.addOperation(initial_store.op);
    const second_store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, nine.getResult(), alloca.getResult(), one.getResult());
    try entry.addOperation(second_store.op);
    const loop = try dialects.ScfDialect.ForOp.create(ctx, loc, zero.getResult(), function.getArgument(0), one.getResult(), &.{}, &.{});
    try entry.addOperation(loop.op);
    const body = loop.getBodyBlock();
    const before = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), zero.getResult(), word);
    try body.addOperation(before.op);
    const called = try dialects.FuncDialect.CallOp.create(ctx, loc, "stack_scalar_oracle", &.{before.getResult()}, &.{word});
    try body.addOperation(called.op);
    const updated = try dialects.MemrefDialect.StoreOp.create(ctx, loc, called.getResult(0).?, alloca.getResult(), zero.getResult());
    try body.addOperation(updated.op);
    const reread = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), zero.getResult(), word);
    try body.addOperation(reread.op);
    const accumulated = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), one.getResult(), word);
    try body.addOperation(accumulated.op);
    const next = try dialects.ArithDialect.AddOp.create(ctx, loc, reread.getResult(), accumulated.getResult());
    try body.addOperation(next.op);
    const store_sum = try dialects.MemrefDialect.StoreOp.create(ctx, loc, next.getResult(), alloca.getResult(), one.getResult());
    try body.addOperation(store_sum.op);
    const yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{});
    try body.addOperation(yield.op);
    const first = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), zero.getResult(), word);
    try entry.addOperation(first.op);
    const second = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), one.getResult(), word);
    try entry.addOperation(second.op);
    const total = try dialects.ArithDialect.AddOp.create(ctx, loc, first.getResult(), second.getResult());
    try entry.addOperation(total.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{total.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

const StaticAllocaCase = enum { unused, dynamic, zero, nonhost, annotated, nested, escaped };

fn staticAllocaCaseModule(ctx: *ir.Context, case: StaticAllocaCase) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = if (case == .dynamic)
        try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, word, .host)
    else
        try dialects.MemrefDialect.getMemrefType1D(ctx, if (case == .zero) 0 else 2, word, if (case == .nonhost) .device else .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    if (case == .escaped) {
        const sink = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "stack_sink", &.{buffer}, &.{});
        try module.getBodyBlock().addOperation(sink.op);
    }
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "stack_case", &.{index}, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const container = if (case == .nested) nested: {
        const condition = try dialects.ArithDialect.ConstantOp.createBool(ctx, loc, true);
        try entry.addOperation(condition.op);
        const branch = try dialects.ScfDialect.IfOp.createWithoutElse(ctx, loc, condition.getResult());
        try entry.addOperation(branch.op);
        break :nested branch.getThenBlock();
    } else entry;
    const alloca = if (case == .dynamic)
        try dialects.MemrefDialect.AllocaOp.createDynamic(ctx, loc, function.getArgument(0), buffer)
    else
        try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    if (case == .annotated)
        try alloca.op.setAttr("future", try ctx.getBoolAttr(true));
    try container.addOperation(alloca.op);
    if (case == .nested) {
        const yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{});
        try container.addOperation(yield.op);
    }
    if (case == .escaped) {
        const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "stack_sink", &.{alloca.getResult()}, &.{});
        try entry.addOperation(call.op);
    }
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 0);
    try entry.addOperation(zero.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{zero.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

fn borrowedViewModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const byte = try dialects.ArithDialect.getScalarType(ctx, .u8);
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const bytes = try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, byte, .host);
    const words = try dialects.MemrefDialect.getMemrefType1D(ctx, 2, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "borrowed_view", &.{ bytes, index, index, word }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const view = try dialects.MemrefDialect.ViewOp.create(ctx, loc, function.getArgument(0), function.getArgument(1), words);
    try entry.addOperation(view.op);
    const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, function.getArgument(3), view.getResult(), function.getArgument(2));
    try entry.addOperation(store.op);
    const load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, view.getResult(), function.getArgument(2), word);
    try entry.addOperation(load.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{load.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

fn borrowedLoopModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "borrowed_step_oracle", &.{ buffer, index, word }, &.{word});
    try module.getBodyBlock().addOperation(external.op);
    const step = try dialects.FuncDialect.FuncOp.create(ctx, loc, "borrowed_step", &.{ buffer, index, word }, &.{word});
    try module.getBodyBlock().addOperation(step.op);
    const step_call = try dialects.FuncDialect.CallOp.create(ctx, loc, "borrowed_step_oracle", &.{ step.getArgument(0), step.getArgument(1), step.getArgument(2) }, &.{word});
    try step.getEntryBlock().addOperation(step_call.op);
    const step_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{step_call.getResult(0).?});
    try step.getEntryBlock().addOperation(step_ret.op);

    const entry = try dialects.FuncDialect.FuncOp.create(ctx, loc, "borrowed_loop", &.{ index, buffer, word }, &.{word});
    try module.getBodyBlock().addOperation(entry.op);
    const body = entry.getEntryBlock();
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try body.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 1);
    try body.addOperation(one.op);
    const one_word = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 1);
    try body.addOperation(one_word.op);
    const initial = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 0);
    try body.addOperation(initial.op);
    const loop = try dialects.ScfDialect.ForOp.create(ctx, loc, zero.getResult(), entry.getArgument(0), one.getResult(), &.{initial.getResult()}, &.{word});
    try body.addOperation(loop.op);
    const loop_body = loop.getBodyBlock();
    const before = try dialects.MemrefDialect.LoadOp.create(ctx, loc, entry.getArgument(1), loop_body.arguments.items[0], word);
    try loop_body.addOperation(before.op);
    const called = try dialects.FuncDialect.CallOp.create(ctx, loc, "borrowed_step", &.{ entry.getArgument(1), loop_body.arguments.items[0], entry.getArgument(2) }, &.{word});
    try loop_body.addOperation(called.op);
    const incremented = try dialects.ArithDialect.AddOp.create(ctx, loc, called.getResult(0).?, one_word.getResult());
    try loop_body.addOperation(incremented.op);
    const stored = try dialects.MemrefDialect.StoreOp.create(ctx, loc, incremented.getResult(), entry.getArgument(1), loop_body.arguments.items[0]);
    try loop_body.addOperation(stored.op);
    const seen = try dialects.MemrefDialect.LoadOp.create(ctx, loc, entry.getArgument(1), loop_body.arguments.items[0], word);
    try loop_body.addOperation(seen.op);
    const prior_sum = try dialects.ArithDialect.AddOp.create(ctx, loc, loop_body.arguments.items[1], before.getResult());
    try loop_body.addOperation(prior_sum.op);
    const next = try dialects.ArithDialect.AddOp.create(ctx, loc, prior_sum.getResult(), seen.getResult());
    try loop_body.addOperation(next.op);
    const yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{next.getResult()});
    try loop_body.addOperation(yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{loop.op.getResult(0).?});
    try body.addOperation(ret.op);
    return module.op;
}

fn borrowedStepOracle(buffer: [*]u64, index: usize, delta: u64) callconv(.c) u64 {
    buffer[index] +%= delta;
    return buffer[index];
}

fn refusedBorrowedModule(ctx: *ir.Context, annotated: bool) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, word, if (annotated) .host else .device);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "refused_borrow", &.{ buffer, index }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const unused_load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, function.getArgument(0), function.getArgument(1), word);
    if (annotated) try unused_load.op.setAttr("cache", try ctx.getDialectAttr("memref.cache", "future"));
    try entry.addOperation(unused_load.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 0);
    try entry.addOperation(zero.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{zero.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

const BorrowedSpill = struct {
    module: *ir.Operation,
    pointer: *ir.Value,
    index: *ir.Value,
    value: *ir.Value,
};

fn borrowedSpillModule(ctx: *ir.Context) !BorrowedSpill {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const byte = try dialects.ArithDialect.getScalarType(ctx, .u8);
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const bytes = try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, byte, .host);
    const words = try dialects.MemrefDialect.getMemrefType1D(ctx, 2, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "borrowed_spill", &.{ bytes, index, index, word }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var live: [placement.max_registers + 1]*ir.Value = undefined;
    for (&live, 0..) |*value, position| {
        const constant = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, @intCast(position + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const view = try dialects.MemrefDialect.ViewOp.create(ctx, loc, function.getArgument(0), function.getArgument(1), words);
    try entry.addOperation(view.op);
    const zero_index = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero_index.op);
    const computed_index = try dialects.ArithDialect.AddOp.create(ctx, loc, function.getArgument(2), zero_index.getResult());
    try entry.addOperation(computed_index.op);
    const zero_word = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 0);
    try entry.addOperation(zero_word.op);
    const computed_value = try dialects.ArithDialect.AddOp.create(ctx, loc, function.getArgument(3), zero_word.getResult());
    try entry.addOperation(computed_value.op);
    const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, computed_value.getResult(), view.getResult(), computed_index.getResult());
    try entry.addOperation(store.op);
    const load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, view.getResult(), computed_index.getResult(), word);
    try entry.addOperation(load.op);
    var total = load.getResult();
    for (live) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, total, value);
        try entry.addOperation(add.op);
        total = add.getResult();
    }
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{total});
    try entry.addOperation(ret.op);
    return .{ .module = module.op, .pointer = view.getResult(), .index = computed_index.getResult(), .value = computed_value.getResult() };
}

comptime {
    execution.assertTarget(Target);
}

test "aarch64 native execution admits Apple scalar and borrowed address parameters" {
    const one = try Signature.init(&.{ .{ .scalar = .i8 }, .{ .scalar = .u64 }, .{ .scalar = .bool } }, &.{.{ .scalar = .index }});
    try std.testing.expect(Target.admitsSignature(&one));
    try std.testing.expectEqualStrings("apple-arm64", Target.abi.name.?);
    try std.testing.expectEqualStrings("c", Target.abi.calling_convention.?);
    try std.testing.expectEqual(@as(?u16, 64), Target.abi.pointer_width_bits);
    try std.testing.expect(!Target.allowsSerializedArtifact);
    const memref = try Signature.init(&.{.memref}, &.{});
    try std.testing.expect(Target.admitsSignature(&memref));
    const pointer_result = try Signature.init(&.{}, &.{.memref});
    try std.testing.expect(!Target.admitsSignature(&pointer_result));
    const float = try Signature.init(&.{.{ .scalar = .f64 }}, &.{});
    try std.testing.expect(Target.admitsSignature(&float));
    const small_float = try Signature.init(&.{.{ .scalar = .f32 }}, &.{});
    try std.testing.expect(Target.admitsSignature(&small_float));
    const mixed_float_width = try Signature.init(&.{ .{ .scalar = .f32 }, .{ .scalar = .f64 } }, &.{});
    try std.testing.expect(!Target.admitsSignature(&mixed_float_width));
    const mixed_float_result = try Signature.init(&.{.{ .scalar = .f32 }}, &.{.{ .scalar = .f64 }});
    try std.testing.expect(!Target.admitsSignature(&mixed_float_result));
    const vector = try Signature.init(&.{.{ .vector = .{ .element = .i32, .lanes = 4 } }}, &.{});
    try std.testing.expect(!Target.admitsSignature(&vector));
    const two_results = try Signature.init(&.{}, &.{ .{ .scalar = .i64 }, .{ .scalar = .i64 } });
    try std.testing.expect(!Target.admitsSignature(&two_results));
    var too_many = try Signature.init(&.{}, &.{});
    too_many.parameter_count = 9;
    try std.testing.expect(!Target.admitsSignature(&too_many));
    var invalid = too_many;
    invalid.parameter_count = 255;
    try std.testing.expect(!Target.admitsSignature(&invalid));
}

test "aarch64 native execution reserves static word payload within the shared frame" {
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    for ([_]struct { words: u64, call: bool, accepted: bool }{
        .{ .words = 64, .call = false, .accepted = true },
        .{ .words = 65, .call = false, .accepted = false },
        .{ .words = 47, .call = true, .accepted = true },
        .{ .words = 48, .call = true, .accepted = false },
    }) |case| {
        const module = try staticAllocaModule(&ctx, case.words, case.call);
        defer module.erase();
        if (case.words > placement.max_frame_slots) {
            try testing.expectError(error.UnsupportedOperation, backend.lowerModule(module));
            continue;
        }
        try backend.lowerModule(module);
        const function = ir.inspection.functionDefinitionByName(module, "stack_words").?;
        var plan: placement.Plan = .{};
        try plan.build(function.getRegion(0).?.getEntryBlock().?);
        try testing.expectEqual(@as(usize, 0), plan.frame_slots);
        var emitter = backend.Emitter.init(testing.allocator);
        defer emitter.deinit();
        if (case.accepted) {
            try emitter.emitFunction(function);
            try testing.expectEqual(@as(usize, @intCast(case.words)) + (if (case.call) placement.call_frame_slots else @as(usize, 0)), emitter.plan.frame_slots);
            try testing.expect(emitter.plan.frameBytes() <= placement.max_frame_slots * placement.slot_bytes);
        } else {
            try testing.expectError(error.UnsupportedOperation, emitter.emitFunction(function));
            try testing.expect(emitter.failed_operation != null);
        }
    }
}

test "aarch64 native execution stores static words before reading through a call frame" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try staticAllocaModule(&ctx, 47, true);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("stack_void_oracle", @intFromPtr(&scalarVoidOracle));
    const handle = try runtime.compile(module);
    const native = try runtime.getFunction(handle, "stack_words", *const fn (i64, i64) callconv(.c) i64);
    for ([_][2]i64{ .{ 17, 25 }, .{ -81, 123 }, .{ 0, 42 } }) |pair| {
        void_observed = 0;
        try testing.expectEqual(pair[0] + pair[1], native(pair[0], pair[1]));
        try testing.expectEqual(pair[0], void_observed);
        var result = [_]execution.Value{.{ .i64 = 0 }};
        try runtime.call(handle, "stack_words", &.{ .{ .i64 = pair[0] }, .{ .i64 = pair[1] } }, &result);
        try testing.expectEqual(pair[0] + pair[1], result[0].i64);
    }
    try runtime.release(handle);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}

test "aarch64 native execution keeps two static payloads separate across invocations" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try twoStaticAllocasModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    const native = try runtime.getFunction(handle, "two_stack_words", *const fn (u64, u64) callconv(.c) u64);
    for ([_][2]u64{
        .{ 0x8000_0000_0000_0001, 0x1234_5678_9abc_def0 },
        .{ 77, 88 },
        .{ 0xffff_ffff_ffff_ff00, 0xff },
    }) |pair| {
        try testing.expectEqual(pair[0] +% pair[1], native(pair[0], pair[1]));
        var result = [_]execution.Value{.{ .u64 = 0 }};
        try runtime.call(handle, "two_stack_words", &.{ .{ .u64 = pair[0] }, .{ .u64 = pair[1] } }, &result);
        try testing.expectEqual(pair[0] +% pair[1], result[0].u64);
    }
    try runtime.release(handle);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}

test "aarch64 native execution reloads a spilled static address index and word" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const witness = try spilledStaticAllocaModule(&ctx);
    defer witness.module.erase();
    const function = ir.inspection.functionDefinitionByName(witness.module, "spilled_stack_words").?;
    var plan: placement.Plan = .{};
    try plan.build(function.getRegion(0).?.getEntryBlock().?);
    try testing.expect(plan.get(witness.pointer).? == .stack);
    try testing.expect(plan.get(witness.index).? == .stack);
    try testing.expect(plan.get(witness.value).? == .stack);
    const spills = plan.frame_slots;
    try testing.expect(spills > 0);
    try plan.reserveCallFrame(function);
    try testing.expectEqual(spills + placement.call_frame_slots, plan.frame_slots);
    const alloca_op: *ir.Operation = @ptrCast(@alignCast(witness.pointer.getDefiningOp().?));
    try plan.reserveAlloca(alloca_op, witness.pointer, 2);
    try testing.expectEqual(spills + placement.call_frame_slots + 2, plan.frame_slots);
    try testing.expectEqual(@as(u16, @intCast(spills + placement.call_frame_slots)), plan.allocaPayload(witness.pointer).?);

    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("stack_word_oracle", @intFromPtr(&staticWordOracle));
    const handle = try runtime.compile(witness.module);
    const native = try runtime.getFunction(handle, "spilled_stack_words", *const fn (usize, u64) callconv(.c) u64);
    stack_word_observed = 0;
    try testing.expectEqual(@as(u64, 0x8000_0000_0000_005a + 36), native(1, 0x8000_0000_0000_005a));
    try testing.expectEqual(@as(u64, 0x8000_0000_0000_005a), stack_word_observed);
    try runtime.release(handle);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}

test "aarch64 native execution retains static payload across calls and loop back edges" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try staticAllocaLoopModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("stack_scalar_oracle", @intFromPtr(&scalarExternalOracle));
    const handle = try runtime.compile(module);
    const native = try runtime.getFunction(handle, "stack_loop", *const fn (usize, i64) callconv(.c) i64);
    for ([_]usize{ 0, 1, 4 }) |trips| {
        var first: i64 = 7;
        var second: i64 = 9;
        for (0..trips) |_| {
            first = scalarExternalOracle(first);
            second += first;
        }
        try testing.expectEqual(first + second, native(trips, 7));
        var result = [_]execution.Value{.{ .i64 = 0 }};
        try runtime.call(handle, "stack_loop", &.{ .{ .index = trips }, .{ .i64 = 7 } }, &result);
        try testing.expectEqual(first + second, result[0].i64);
    }
    try runtime.release(handle);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}

test "aarch64 native execution refuses unsupported static allocation shapes and escapes" {
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const unused = try staticAllocaCaseModule(&ctx, .unused);
    defer unused.erase();
    try backend.lowerModule(unused);
    const unused_function = ir.inspection.functionDefinitionByName(unused, "stack_case").?;
    var unused_emitter = backend.Emitter.init(testing.allocator);
    defer unused_emitter.deinit();
    try unused_emitter.emitFunction(unused_function);
    try testing.expectEqual(@as(usize, 2), unused_emitter.plan.frame_slots);
    for ([_]StaticAllocaCase{ .dynamic, .zero, .nonhost, .annotated, .nested, .escaped }) |case| {
        const module = try staticAllocaCaseModule(&ctx, case);
        defer module.erase();
        try testing.expectError(error.UnsupportedOperation, backend.lowerModule(module));
    }

    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return;
    const stable = try scalarModule(&ctx, "stable_stack_refusal", .i64, 0, true);
    defer stable.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(stable);
    const charged = runtime.mapped_bytes;
    const escaped = try staticAllocaCaseModule(&ctx, .escaped);
    defer escaped.erase();
    try testing.expectError(error.UnsupportedOperation, runtime.compile(escaped));
    try testing.expectEqual(charged, runtime.mapped_bytes);
    try testing.expectEqual(@as(u32, 1), runtime.live_modules);
    const native = try runtime.getFunction(handle, "stable_stack_refusal", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 42), native());
    try runtime.release(handle);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}

test "aarch64 native execution copies borrowed host words with dynamic indices" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try borrowedCopyModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    var source: [4100]u64 = @splat(0);
    var target: [4100]u64 = @splat(0xa5a5_a5a5_a5a5_a5a5);
    const native = try runtime.getFunction(handle, "borrowed_copy", *const fn ([*]const u64, [*]u64, usize) callconv(.c) u64);
    for ([_]usize{ 0, 1, 4096, 4099 }) |index| {
        const expected: u64 = 0x8000_0000_0000_0017 + @as(u64, @intCast(index));
        source[index] = expected;
        try testing.expectEqual(expected, native(&source, &target, index));
        try testing.expectEqual(expected, target[index]);
        var checked = [_]execution.Value{.{ .u64 = 0 }};
        target[index] = 0;
        try runtime.call(handle, "borrowed_copy", &.{ .{ .memref = @intFromPtr(&source) }, .{ .memref = @intFromPtr(&target) }, .{ .index = index } }, &checked);
        try testing.expectEqual(expected, checked[0].u64);
        try testing.expectEqual(expected, target[index]);
    }
    var wrong = [_]execution.Value{.{ .u64 = 0 }};
    try testing.expectError(error.SignatureMismatch, runtime.call(handle, "borrowed_copy", &.{ .{ .u64 = @intFromPtr(&source) }, .{ .memref = @intFromPtr(&target) }, .{ .index = 1 } }, &wrong));
    try testing.expectEqual(@as(u64, 0), wrong[0].u64);
    source[1] = 0xdead_beef_dead_beef;
    try testing.expectEqual(source[1], native(&source, &source, 1));
    try testing.expectEqual(@as(u64, 0xa5a5_a5a5_a5a5_a5a5), target[2]);
    try runtime.release(handle);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
    try testing.expectEqual(@as(u64, 0xdead_beef_dead_beef), source[1]);
}

test "aarch64 native execution uses byte View offsets before word indexing" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try borrowedViewModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    const native = try runtime.getFunction(handle, "borrowed_view", *const fn ([*]u8, usize, usize, u64) callconv(.c) u64);
    var arena: [24]u64 = @splat(0x1111_1111_1111_1111);
    const bytes: [*]u8 = @ptrCast(&arena);
    try testing.expectEqual(@as(u64, 0x8000_0000_0000_0023), native(bytes, 8, 1, 0x8000_0000_0000_0023));
    try testing.expectEqual(@as(u64, 0x1111_1111_1111_1111), arena[1]);
    try testing.expectEqual(@as(u64, 0x8000_0000_0000_0023), arena[2]);
    try testing.expectEqual(@as(u64, 0x1111_1111_1111_1111), arena[3]);
    try testing.expectEqual(@as(u64, 0x1111_1111_1111_1111), arena[9]);
    var checked = [_]execution.Value{.{ .u64 = 0 }};
    try runtime.call(handle, "borrowed_view", &.{ .{ .memref = @intFromPtr(&arena) }, .{ .index = 16 }, .{ .index = 0 }, .{ .u64 = 0xfedc_ba98_7654_3210 } }, &checked);
    try testing.expectEqual(@as(u64, 0xfedc_ba98_7654_3210), checked[0].u64);
    try testing.expectEqual(checked[0].u64, arena[2]);
    try runtime.release(handle);
    try testing.expectEqual(@as(u64, 0xfedc_ba98_7654_3210), arena[2]);
}

test "aarch64 native execution keeps borrowed buffers across loop and mixed direct calls" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try borrowedLoopModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("borrowed_step_oracle", @intFromPtr(&borrowedStepOracle));
    const handle = try runtime.compile(module);
    const native = try runtime.getFunction(handle, "borrowed_loop", *const fn (usize, [*]u64, u64) callconv(.c) u64);
    var buffer = [_]u64{ 0x8000_0000_0000_0001, 2, 3, 4 };
    var reference = buffer;
    try testing.expectEqual(@as(u64, 0), native(0, &buffer, 7));
    try testing.expectEqualSlices(u64, &reference, &buffer);
    for ([_]usize{ 1, 4 }) |trip_count| {
        var expected: u64 = 0;
        for (reference[0..trip_count]) |*word| {
            const prior = word.*;
            word.* +%= 7;
            word.* +%= 1;
            expected +%= prior +% word.*;
        }
        var checked = [_]execution.Value{.{ .u64 = 0 }};
        try runtime.call(handle, "borrowed_loop", &.{ .{ .index = trip_count }, .{ .memref = @intFromPtr(&buffer) }, .{ .u64 = 7 } }, &checked);
        try testing.expectEqual(expected, checked[0].u64);
        try testing.expectEqualSlices(u64, &reference, &buffer);
    }
    try runtime.release(handle);
    try testing.expectEqualSlices(u64, &reference, &buffer);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}

test "aarch64 native execution refuses unused nonhost memory before publication" {
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try refusedBorrowedModule(&ctx, false);
    defer module.erase();
    try testing.expectError(error.UnsupportedOperation, backend.lowerModule(module));
    const annotated = try refusedBorrowedModule(&ctx, true);
    defer annotated.erase();
    try testing.expectError(error.UnsupportedOperation, backend.lowerModule(annotated));

    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return;
    const stable = try scalarModule(&ctx, "kept_borrow", .i64, 0, true);
    defer stable.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(stable);
    const before = runtime.mapped_bytes;
    try testing.expectError(error.UnsupportedOperation, runtime.compile(module));
    try testing.expectError(error.UnsupportedOperation, runtime.compile(annotated));
    try testing.expectEqual(before, runtime.mapped_bytes);
    try testing.expectEqual(@as(u32, 1), runtime.live_modules);
    const native = try runtime.getFunction(handle, "kept_borrow", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 42), native());
    try runtime.release(handle);
}

test "aarch64 native execution reloads spilled borrowed address index and stored word" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const witness = try borrowedSpillModule(&ctx);
    defer witness.module.erase();
    const function = ir.inspection.functionDefinitionByName(witness.module, "borrowed_spill").?;
    var plan: placement.Plan = .{};
    try plan.build(function.getRegion(0).?.getEntryBlock().?);
    try testing.expect(plan.get(witness.pointer).? == .stack);
    try testing.expect(plan.get(witness.index).? == .stack);
    try testing.expect(plan.get(witness.value).? == .stack);
    try testing.expect(plan.frame_slots <= placement.max_frame_slots);

    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(witness.module);
    const native = try runtime.getFunction(handle, "borrowed_spill", *const fn ([*]u8, usize, usize, u64) callconv(.c) u64);
    var arena: [24]u64 = @splat(0x2222_2222_2222_2222);
    const bytes: [*]u8 = @ptrCast(&arena);
    try testing.expectEqual(@as(u64, 0x8000_0000_0000_005a + 36), native(bytes, 8, 1, 0x8000_0000_0000_005a));
    try testing.expectEqual(@as(u64, 0x8000_0000_0000_005a), arena[2]);
    try testing.expectEqual(@as(u64, 0x2222_2222_2222_2222), arena[1]);
    try testing.expectEqual(@as(u64, 0x2222_2222_2222_2222), arena[3]);
    try runtime.release(handle);
}

test "aarch64 native execution resolves direct internal and external scalar calls" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try directCallModule(&ctx, "scalar_oracle");
    defer module.erase();

    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("scalar_oracle", @intFromPtr(&scalarExternalOracle));
    try runtime.registerExternalSymbol("sum", @intFromPtr(&conflictingExternalSum));
    const handle = try runtime.compile(module);
    const second = try runtime.compile(module);
    const direct = try runtime.getFunction(handle, "call_entry", *const fn (i64, i64) callconv(.c) i64);
    for ([_][2]i64{ .{ 2, 7 }, .{ -11, 4 }, .{ 0, 0 } }) |arguments| {
        const expected = scalarExternalOracle(arguments[0] + arguments[1]) + arguments[0];
        try testing.expectEqual(expected, direct(arguments[0], arguments[1]));
        var result = [_]execution.Value{.{ .i64 = 0 }};
        try runtime.call(handle, "call_entry", &.{ .{ .i64 = arguments[0] }, .{ .i64 = arguments[1] } }, &result);
        try testing.expectEqual(expected, result[0].i64);
    }
    try runtime.release(handle);
    var retained = [_]execution.Value{.{ .i64 = 0 }};
    try runtime.call(second, "call_entry", &.{ .{ .i64 = 3 }, .{ .i64 = 4 } }, &retained);
    try testing.expectEqual(scalarExternalOracle(7) + 3, retained[0].i64);
    try runtime.release(second);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}

test "aarch64 native execution keeps prior code callable after an unresolved direct external" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const stable = try scalarModule(&ctx, "stable", .i64, 0, true);
    defer stable.erase();
    const unresolved = try directCallModule(&ctx, "not_registered");
    defer unresolved.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(stable);
    try testing.expectError(error.SymbolNotFound, runtime.compile(unresolved));
    var result = [_]execution.Value{.{ .i64 = 0 }};
    try runtime.call(handle, "stable", &.{}, &result);
    try testing.expectEqual(@as(i64, 42), result[0].i64);
    try testing.expectEqual(@as(u32, 1), runtime.live_modules);
    try runtime.release(handle);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
}

test "aarch64 native execution extends narrow arguments and normalizes direct call results" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("signed_narrow", @intFromPtr(&signedNarrowOracle));
    try runtime.registerExternalSymbol("unsigned_narrow", @intFromPtr(&unsignedNarrowOracle));
    try runtime.registerExternalSymbol("boolean_oracle", @intFromPtr(&booleanOracle));
    try runtime.registerExternalSymbol("index_oracle", @intFromPtr(&indexOracle));
    try runtime.registerExternalSymbol("signed_widen", @intFromPtr(&signedWidenOracle));
    try runtime.registerExternalSymbol("unsigned_widen", @intFromPtr(&unsignedWidenOracle));

    const signed = try narrowCallModule(&ctx, .i8, "signed_narrow");
    defer signed.erase();
    const signed_handle = try runtime.compile(signed);
    const signed_entry = try runtime.getFunction(signed_handle, "narrow_entry", *const fn (i8) callconv(.c) i8);
    try testing.expectEqual(@as(i8, -128), signed_entry(-128));
    try runtime.release(signed_handle);

    const unsigned = try narrowCallModule(&ctx, .u8, "unsigned_narrow");
    defer unsigned.erase();
    const unsigned_handle = try runtime.compile(unsigned);
    const unsigned_entry = try runtime.getFunction(unsigned_handle, "narrow_entry", *const fn (u8) callconv(.c) u8);
    try testing.expectEqual(@as(u8, 255), unsigned_entry(255));
    try runtime.release(unsigned_handle);

    const boolean = try narrowCallModule(&ctx, .bool, "boolean_oracle");
    defer boolean.erase();
    const boolean_handle = try runtime.compile(boolean);
    const boolean_entry = try runtime.getFunction(boolean_handle, "narrow_entry", *const fn (bool) callconv(.c) bool);
    try testing.expectEqual(false, boolean_entry(true));
    try testing.expectEqual(true, boolean_entry(false));
    try runtime.release(boolean_handle);

    const index = try narrowCallModule(&ctx, .index, "index_oracle");
    defer index.erase();
    const index_handle = try runtime.compile(index);
    const index_entry = try runtime.getFunction(index_handle, "narrow_entry", *const fn (usize) callconv(.c) usize);
    try testing.expectEqual(@as(usize, 8), index_entry(7));
    try runtime.release(index_handle);

    const signed_widen = try narrowWidenCallModule(&ctx, .i8, .i64, "signed_widen");
    defer signed_widen.erase();
    const signed_widen_handle = try runtime.compile(signed_widen);
    const signed_widen_entry = try runtime.getFunction(signed_widen_handle, "widen_entry", *const fn (i8) callconv(.c) i64);
    try testing.expectEqual(@as(i64, -128), signed_widen_entry(-128));
    try runtime.release(signed_widen_handle);

    const unsigned_widen = try narrowWidenCallModule(&ctx, .u8, .u64, "unsigned_widen");
    defer unsigned_widen.erase();
    const unsigned_widen_handle = try runtime.compile(unsigned_widen);
    const unsigned_widen_entry = try runtime.getFunction(unsigned_widen_handle, "widen_entry", *const fn (u8) callconv(.c) u64);
    try testing.expectEqual(@as(u64, 255), unsigned_widen_entry(255));
    try runtime.release(unsigned_widen_handle);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
}

test "aarch64 native execution calls compiled externals at zero and eight arguments" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("zero_oracle", @intFromPtr(&scalarExternalZero));
    try runtime.registerExternalSymbol("eight_oracle", @intFromPtr(&scalarExternalEight));
    const zero = try arityCallModule(&ctx, 0, "zero_oracle");
    defer zero.erase();
    const zero_handle = try runtime.compile(zero);
    const zero_entry = try runtime.getFunction(zero_handle, "arity_entry", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 42), zero_entry());
    try runtime.release(zero_handle);
    const eight = try arityCallModule(&ctx, 8, "eight_oracle");
    defer eight.erase();
    const eight_handle = try runtime.compile(eight);
    const eight_entry = try runtime.getFunction(eight_handle, "arity_entry", *const fn (i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) i64);
    try testing.expectEqual(scalarExternalEight(8, 7, 6, 5, 4, 3, 2, 1) + 1, eight_entry(1, 2, 3, 4, 5, 6, 7, 8));
    try runtime.release(eight_handle);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
}

test "aarch64 native execution preserves state around a zero-result external call" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try voidCallModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("void_oracle", @intFromPtr(&scalarVoidOracle));
    const handle = try runtime.compile(module);
    const entry = try runtime.getFunction(handle, "void_entry", *const fn (i64) callconv(.c) void);
    void_observed = 0;
    entry(73);
    try testing.expectEqual(@as(i64, 73), void_observed);
    try runtime.release(handle);
}

test "aarch64 native execution bounds call saves and frame record to 64 slots" {
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    defer module.op.erase();
    var within: placement.Plan = .{ .frame_slots = placement.max_frame_slots - placement.call_frame_slots };
    try within.reserveCallFrame(module.op);
    try testing.expectEqual(placement.max_frame_slots, within.frame_slots);
    try testing.expectEqual(@as(usize, 0), within.frameBytes() % 16);
    var over: placement.Plan = .{ .frame_slots = placement.max_frame_slots - placement.call_frame_slots + 1 };
    try testing.expectError(error.FrameCapacity, over.reserveCallFrame(module.op));
}

test "aarch64 native execution preserves register and spill values through a branch call" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try callPressureModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("pressure_oracle", @intFromPtr(&scalarExternalOracle));
    const handle = try runtime.compile(module);
    const entry = try runtime.getFunction(handle, "call_pressure", *const fn (bool) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 0), entry(false));
    try testing.expectEqual(@as(i64, 40), entry(true));
    try runtime.release(handle);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
}

test "aarch64 native execution preserves carried state through call back edges" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try loopCallModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("loop_oracle", @intFromPtr(&indexOracle));
    const handle = try runtime.compile(module);
    const entry = try runtime.getFunction(handle, "loop_calls", *const fn (usize) callconv(.c) usize);
    try testing.expectEqual(@as(usize, 0), entry(0));
    try testing.expectEqual(@as(usize, 15), entry(5));
    try runtime.release(handle);
}

test "aarch64 native execution calls Apple scalar functions at arities zero through eight" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();

    var arguments: [backend.max_arguments]execution.Value = undefined;
    for (&arguments, 0..) |*argument, index| argument.* = .{ .i64 = @intCast(index + 1) };
    for (0..backend.max_arguments + 1) |arity| {
        const module = try scalarModule(&ctx, "entry", .i64, arity, true);
        defer module.erase();
        const handle = try runtime.compile(module);
        var result = [_]execution.Value{.{ .i64 = 0 }};
        try runtime.call(handle, "entry", arguments[0..arity], &result);
        try testing.expectEqual(@as(i64, @intCast(if (arity == 0) 42 else arity)), result[0].i64);
        try runtime.release(handle);
    }

    const void_module = try scalarModule(&ctx, "void_entry", .i64, 8, false);
    defer void_module.erase();
    const void_handle = try runtime.compile(void_module);
    var no_results: [0]execution.Value = .{};
    try runtime.call(void_handle, "void_entry", &arguments, &no_results);
    try runtime.release(void_handle);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}

test "aarch64 native execution preserves structured spill results and the caller frame" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try structuredPressureModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    defer runtime.release(handle) catch {};
    const entry = try runtime.getFunction(handle, "pressure_branch", *const fn (bool) callconv(.c) i64);
    var evaluator = @import("../../root.zig").eval.Evaluator.init(testing.allocator, &ctx);
    defer evaluator.deinit();
    try evaluator.setRootOperation(module);
    const function = ir.inspection.functionDefinitionByName(module, "pressure_branch").?;
    for ([_]bool{ false, true }) |condition| {
        const argument = try ctx.getBoolAttr(condition);
        const result = try evaluator.evaluateFunctionOp(function, &.{argument});
        const expected = dialects.ArithDialect.getIntValue(result).?;
        try testing.expectEqual(expected, entry(condition));
        var checked = [_]execution.Value{.{ .i64 = 0 }};
        try runtime.call(handle, "pressure_branch", &.{.{ .bool = condition }}, &checked);
        try testing.expectEqual(expected, checked[0].i64);
    }
}

test "aarch64 native execution keeps Apple integer boundary widths and signedness" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const Case = struct { kind: dialects.arith.ScalarKind, argument: execution.Value };
    const cases = [_]Case{
        .{ .kind = .i8, .argument = .{ .i8 = std.math.minInt(i8) } },
        .{ .kind = .i8, .argument = .{ .i8 = std.math.maxInt(i8) } },
        .{ .kind = .i16, .argument = .{ .i16 = std.math.minInt(i16) } },
        .{ .kind = .i16, .argument = .{ .i16 = std.math.maxInt(i16) } },
        .{ .kind = .i32, .argument = .{ .i32 = std.math.minInt(i32) } },
        .{ .kind = .i32, .argument = .{ .i32 = std.math.maxInt(i32) } },
        .{ .kind = .i64, .argument = .{ .i64 = std.math.minInt(i64) } },
        .{ .kind = .i64, .argument = .{ .i64 = std.math.maxInt(i64) } },
        .{ .kind = .u8, .argument = .{ .u8 = 0 } },
        .{ .kind = .u8, .argument = .{ .u8 = std.math.maxInt(u8) } },
        .{ .kind = .u16, .argument = .{ .u16 = 0 } },
        .{ .kind = .u16, .argument = .{ .u16 = 0x8001 } },
        .{ .kind = .u16, .argument = .{ .u16 = std.math.maxInt(u16) } },
        .{ .kind = .u32, .argument = .{ .u32 = 0 } },
        .{ .kind = .u32, .argument = .{ .u32 = 0x8000_0001 } },
        .{ .kind = .u32, .argument = .{ .u32 = std.math.maxInt(u32) } },
        .{ .kind = .u64, .argument = .{ .u64 = 0 } },
        .{ .kind = .u64, .argument = .{ .u64 = 0x8000_0000_0000_0001 } },
        .{ .kind = .u64, .argument = .{ .u64 = std.math.maxInt(u64) } },
        .{ .kind = .bool, .argument = .{ .bool = false } },
        .{ .kind = .bool, .argument = .{ .bool = true } },
        .{ .kind = .index, .argument = .{ .index = 0 } },
        .{ .kind = .index, .argument = .{ .index = std.math.maxInt(u64) } },
        .{ .kind = .f64, .argument = .{ .f64 = -13.25 } },
    };
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();

    for (cases) |case| {
        const module = try scalarModule(&ctx, "identity", case.kind, 1, true);
        defer module.erase();
        const handle = try runtime.compile(module);
        var result = [_]execution.Value{case.argument};
        try runtime.call(handle, "identity", &.{case.argument}, &result);
        try testing.expectEqual(case.argument, result[0]);
        switch (case.kind) {
            .i8 => {
                const native = try runtime.getFunction(handle, "identity", *const fn (i8) callconv(.c) i8);
                try testing.expectEqual(case.argument.i8, native(case.argument.i8));
            },
            .u8 => {
                const native = try runtime.getFunction(handle, "identity", *const fn (u8) callconv(.c) u8);
                try testing.expectEqual(case.argument.u8, native(case.argument.u8));
            },
            .f64 => {
                const native = try runtime.getFunction(handle, "identity", *const fn (f64) callconv(.c) f64);
                try testing.expectEqual(case.argument.f64, native(case.argument.f64));
            },
            else => {},
        }
        try runtime.release(handle);
    }
}

test "aarch64 native execution rejects wrong Apple scalar calls before entry" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try scalarModule(&ctx, "identity", .i64, 1, true);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);

    var result = [_]execution.Value{.{ .i64 = 0 }};
    var no_results: [0]execution.Value = .{};
    try testing.expectError(error.SignatureMismatch, runtime.call(handle, "identity", &.{}, &result));
    try testing.expectError(error.SignatureMismatch, runtime.call(handle, "identity", &.{.{ .u64 = 9 }}, &result));
    try testing.expectError(error.SignatureMismatch, runtime.call(handle, "identity", &.{.{ .i64 = 9 }}, &no_results));
    try testing.expectEqual(@as(i64, 0), result[0].i64);
    try runtime.call(handle, "identity", &.{.{ .i64 = 41 }}, &result);
    try testing.expectEqual(@as(i64, 41), result[0].i64);
    try runtime.release(handle);
}

fn mixedFloatModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const args = [_]ir.Type{ floating, integer, floating };
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "mixed_float_oracle", &args, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "mixed_float_entry", &args, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const seven = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 7);
    try entry.addOperation(seven.op);
    const condition = try dialects.ArithDialect.CmpOp.create(ctx, loc, .eq, function.getArgument(1), seven.getResult());
    try entry.addOperation(condition.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "mixed_float_oracle", &.{ function.getArgument(0), function.getArgument(1), function.getArgument(2) }, &.{floating});
    try entry.addOperation(call.op);
    const added = try dialects.ArithDialect.AddOp.create(ctx, loc, call.getResult(0).?, function.getArgument(0));
    try entry.addOperation(added.op);
    const selected = try dialects.ArithDialect.SelectOp.create(ctx, loc, condition.getResult(), added.getResult(), function.getArgument(2));
    try entry.addOperation(selected.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{selected.getResult()});
    try entry.addOperation(ret.op);
    const wrapper = try dialects.FuncDialect.FuncOp.create(ctx, loc, "mixed_float_wrapper", &args, &.{floating});
    try module.getBodyBlock().addOperation(wrapper.op);
    const internal = try dialects.FuncDialect.CallOp.create(ctx, loc, "mixed_float_entry", wrapper.getArguments(), &.{floating});
    try wrapper.getEntryBlock().addOperation(internal.op);
    const wrapper_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{internal.getResult(0).?});
    try wrapper.getEntryBlock().addOperation(wrapper_ret.op);
    return module.op;
}

fn mixedFloatOracle(first: f64, middle: i64, last: f64) callconv(.c) f64 {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(middle == 7 or middle == 8);
    return first * 2 + last;
}

fn bitRoundtripModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const bits = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "float_bits", &.{bits}, &.{bits});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const to_float = try dialects.ArithDialect.BitcastOp.create(ctx, loc, function.getArgument(0), floating);
    try entry.addOperation(to_float.op);
    const to_bits = try dialects.ArithDialect.BitcastOp.create(ctx, loc, to_float.getResult(), bits);
    try entry.addOperation(to_bits.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{to_bits.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

test "aarch64 native execution keeps mixed f64 and integer banks across external calls" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try mixedFloatModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("mixed_float_oracle", @intFromPtr(&mixedFloatOracle));
    const handle = try runtime.compile(module);
    try testing.expect(invoke.defaultFpcr());
    var result = [_]execution.Value{.{ .f64 = 0 }};
    try runtime.call(handle, "mixed_float_entry", &.{ .{ .f64 = 1.5 }, .{ .i64 = 7 }, .{ .f64 = 2.25 } }, &result);
    try testing.expectEqual(@as(f64, 6.75), result[0].f64);
    try runtime.call(handle, "mixed_float_wrapper", &.{ .{ .f64 = 1.5 }, .{ .i64 = 7 }, .{ .f64 = 2.25 } }, &result);
    try testing.expectEqual(@as(f64, 6.75), result[0].f64);
    const native = try runtime.getFunction(handle, "mixed_float_entry", *const fn (f64, i64, f64) callconv(.c) f64);
    try testing.expectEqual(@as(f64, 2.25), native(1.5, 8, 2.25));
    var wrong = [_]execution.Value{.{ .f64 = 0 }};
    try testing.expectError(error.SignatureMismatch, runtime.call(handle, "mixed_float_entry", &.{ .{ .u64 = 1 }, .{ .i64 = 7 }, .{ .f64 = 2.25 } }, &wrong));
    try testing.expectEqual(@as(f64, 0), wrong[0].f64);
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

fn eightMixedModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const narrow = try dialects.ArithDialect.getScalarType(ctx, .u8);
    const signed = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const boolean = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const types = [_]ir.Type{ floating, narrow, floating, signed, floating, boolean, floating, index };
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "eight_mixed_oracle", &types, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "eight_mixed_entry", &types, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "eight_mixed_oracle", function.getArguments(), &.{floating});
    try function.getEntryBlock().addOperation(call.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{call.getResult(0).?});
    try function.getEntryBlock().addOperation(ret.op);
    return module.op;
}

fn eightMixedOracle(a: f64, b: u8, c: f64, d: i64, e: f64, f: bool, g: f64, h: usize) callconv(.c) f64 {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(a == 1.5 and b == 0xff and c == 2.5 and d == -7);
    std.debug.assert(e == 3.5 and f and g == 4.5 and h == std.math.maxInt(usize));
    return a + c + e + g;
}

test "aarch64 native execution preserves eight interleaved integer and f64 formals" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try eightMixedModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("eight_mixed_oracle", @intFromPtr(&eightMixedOracle));
    const handle = try runtime.compile(module);
    const arguments = [_]execution.Value{ .{ .f64 = 1.5 }, .{ .u8 = 0xff }, .{ .f64 = 2.5 }, .{ .i64 = -7 }, .{ .f64 = 3.5 }, .{ .bool = true }, .{ .f64 = 4.5 }, .{ .index = std.math.maxInt(u64) } };
    var result = [_]execution.Value{.{ .f64 = 0 }};
    try runtime.call(handle, "eight_mixed_entry", &arguments, &result);
    try testing.expectEqual(@as(f64, 12), result[0].f64);
    const native = try runtime.getFunction(handle, "eight_mixed_entry", *const fn (f64, u8, f64, i64, f64, bool, f64, usize) callconv(.c) f64);
    try testing.expectEqual(@as(f64, 12), native(1.5, 0xff, 2.5, -7, 3.5, true, 4.5, std.math.maxInt(usize)));
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

fn eightFloatOracle(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64) callconv(.c) f64 {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(a == 1 and b == 2 and c == 3 and d == 4);
    std.debug.assert(e == 5 and f == 6 and g == 7 and h == 8);
    return a + b + c + d + e + f + g + h;
}

test "aarch64 native execution fills all eight f64 argument registers in both directions" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(&ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer module.op.erase();
    const types: [8]ir.Type = @splat(floating);
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(&ctx, loc, "eight_float_oracle", &types, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(&ctx, loc, "eight_float_entry", &types, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const call = try dialects.FuncDialect.CallOp.create(&ctx, loc, "eight_float_oracle", function.getArguments(), &.{floating});
    try function.getEntryBlock().addOperation(call.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(&ctx, loc, &.{call.getResult(0).?});
    try function.getEntryBlock().addOperation(ret.op);
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("eight_float_oracle", @intFromPtr(&eightFloatOracle));
    const handle = try runtime.compile(module.op);
    const arguments = [_]execution.Value{ .{ .f64 = 1 }, .{ .f64 = 2 }, .{ .f64 = 3 }, .{ .f64 = 4 }, .{ .f64 = 5 }, .{ .f64 = 6 }, .{ .f64 = 7 }, .{ .f64 = 8 } };
    var result = [_]execution.Value{.{ .f64 = 0 }};
    try runtime.call(handle, "eight_float_entry", &arguments, &result);
    try testing.expectEqual(@as(f64, 36), result[0].f64);
    const native = try runtime.getFunction(handle, "eight_float_entry", *const fn (f64, f64, f64, f64, f64, f64, f64, f64) callconv(.c) f64);
    try testing.expectEqual(@as(f64, 36), native(1, 2, 3, 4, 5, 6, 7, 8));
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

fn mixedPointerOracle(address: [*]const u64, floating: f64, narrow: u8) callconv(.c) u64 {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(floating == 1.25 and narrow == 0xff);
    return address[0] + narrow;
}

var floating_void_bits: u64 = 0;

fn floatingVoidOracle(floating: f64, integer: i64) callconv(.c) void {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(integer == -3);
    floating_void_bits = @bitCast(floating);
}

test "aarch64 native execution sends borrowed pointers with f64 and captures integer or void calls" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(&ctx, .f64);
    const word = try dialects.ArithDialect.getScalarType(&ctx, .u64);
    const narrow = try dialects.ArithDialect.getScalarType(&ctx, .u8);
    const signed = try dialects.ArithDialect.getScalarType(&ctx, .i64);
    const buffer = try dialects.MemrefDialect.getMemrefTypeDynamic(&ctx, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer module.op.erase();
    const pointer_types = [_]ir.Type{ buffer, floating, narrow };
    const pointer_external = try dialects.FuncDialect.FuncOp.createDeclaration(&ctx, loc, "mixed_pointer_oracle", &pointer_types, &.{word});
    try module.getBodyBlock().addOperation(pointer_external.op);
    const pointer_entry = try dialects.FuncDialect.FuncOp.create(&ctx, loc, "mixed_pointer_entry", &pointer_types, &.{word});
    try module.getBodyBlock().addOperation(pointer_entry.op);
    const pointer_call = try dialects.FuncDialect.CallOp.create(&ctx, loc, "mixed_pointer_oracle", pointer_entry.getArguments(), &.{word});
    try pointer_entry.getEntryBlock().addOperation(pointer_call.op);
    const pointer_ret = try dialects.FuncDialect.ReturnOp.create(&ctx, loc, &.{pointer_call.getResult(0).?});
    try pointer_entry.getEntryBlock().addOperation(pointer_ret.op);
    const void_types = [_]ir.Type{ floating, signed };
    const void_external = try dialects.FuncDialect.FuncOp.createDeclaration(&ctx, loc, "floating_void_oracle", &void_types, &.{});
    try module.getBodyBlock().addOperation(void_external.op);
    const void_entry = try dialects.FuncDialect.FuncOp.create(&ctx, loc, "floating_void_entry", &void_types, &.{});
    try module.getBodyBlock().addOperation(void_entry.op);
    const void_call = try dialects.FuncDialect.CallOp.create(&ctx, loc, "floating_void_oracle", void_entry.getArguments(), &.{});
    try void_entry.getEntryBlock().addOperation(void_call.op);
    const void_ret = try dialects.FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try void_entry.getEntryBlock().addOperation(void_ret.op);
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("mixed_pointer_oracle", @intFromPtr(&mixedPointerOracle));
    try runtime.registerExternalSymbol("floating_void_oracle", @intFromPtr(&floatingVoidOracle));
    const handle = try runtime.compile(module.op);
    var storage = [_]u64{11};
    var result = [_]execution.Value{.{ .u64 = 0 }};
    try runtime.call(handle, "mixed_pointer_entry", &.{ .{ .memref = @intFromPtr(&storage) }, .{ .f64 = 1.25 }, .{ .u8 = 0xff } }, &result);
    try testing.expectEqual(@as(u64, 266), result[0].u64);
    floating_void_bits = 0;
    var no_results: [0]execution.Value = .{};
    try runtime.call(handle, "floating_void_entry", &.{ .{ .f64 = -0.0 }, .{ .i64 = -3 } }, &no_results);
    try testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), floating_void_bits);
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

test "aarch64 native execution bitcasts f64 zero and NaN payload words exactly" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try bitRoundtripModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    var result = [_]execution.Value{.{ .u64 = 0 }};
    for ([_]u64{ 0, 0x8000_0000_0000_0000, 0x7ff8_1234_5678_9abc, 0x7ff0_1234_5678_9abc }) |bits| {
        try runtime.call(handle, "float_bits", &.{.{ .u64 = bits }}, &result);
        try testing.expectEqual(bits, result[0].u64);
    }
    try runtime.release(handle);
}

test "aarch64 native execution f64 ABI returns NaN payload and signed-zero bits from d0" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try scalarModule(&ctx, "float_abi_identity", .f64, 1, true);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    const native = try runtime.getFunction(handle, "float_abi_identity", *const fn (f64) callconv(.c) f64);
    for ([_]u64{ 0, 0x8000_0000_0000_0000, 0x7ff8_1234_5678_9abc, 0x7ff0_1234_5678_9abc }) |bits| {
        const number: f64 = @bitCast(bits);
        var result = [_]execution.Value{.{ .f64 = 0 }};
        try runtime.call(handle, "float_abi_identity", &.{.{ .f64 = number }}, &result);
        try testing.expectEqual(bits, @as(u64, @bitCast(result[0].f64)));
        try testing.expectEqual(bits, @as(u64, @bitCast(native(number))));
    }
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

fn floatSignModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const bits = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const boolean = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    for ([_][]const u8{ "float_neg_bits", "float_abs_bits" }, 0..) |name, index| {
        const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, name, &.{bits}, &.{bits});
        try module.getBodyBlock().addOperation(function.op);
        const entry = function.getEntryBlock();
        const to_float = try dialects.ArithDialect.BitcastOp.create(ctx, loc, function.getArgument(0), floating);
        try entry.addOperation(to_float.op);
        const transformed = if (index == 0) blk: {
            const negated = try dialects.ArithDialect.NegOp.create(ctx, loc, to_float.getResult());
            try entry.addOperation(negated.op);
            break :blk negated.getResult();
        } else blk: {
            const absolute = try dialects.ArithDialect.AbsOp.create(ctx, loc, to_float.getResult());
            try entry.addOperation(absolute.op);
            break :blk absolute.getResult();
        };
        const to_bits = try dialects.ArithDialect.BitcastOp.create(ctx, loc, transformed, bits);
        try entry.addOperation(to_bits.op);
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{to_bits.getResult()});
        try entry.addOperation(ret.op);
    }
    const selected = try dialects.FuncDialect.FuncOp.create(ctx, loc, "float_select_bits", &.{ boolean, bits, bits }, &.{bits});
    try module.getBodyBlock().addOperation(selected.op);
    const entry = selected.getEntryBlock();
    const left = try dialects.ArithDialect.BitcastOp.create(ctx, loc, selected.getArgument(1), floating);
    try entry.addOperation(left.op);
    const right = try dialects.ArithDialect.BitcastOp.create(ctx, loc, selected.getArgument(2), floating);
    try entry.addOperation(right.op);
    const choice = try dialects.ArithDialect.SelectOp.create(ctx, loc, selected.getArgument(0), left.getResult(), right.getResult());
    try entry.addOperation(choice.op);
    const to_bits = try dialects.ArithDialect.BitcastOp.create(ctx, loc, choice.getResult(), bits);
    try entry.addOperation(to_bits.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{to_bits.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

test "aarch64 native execution f64 sign and select preserve NaN and signed-zero bits" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try floatSignModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    var result = [_]execution.Value{.{ .u64 = 0 }};
    for ([_]u64{ 0, 0x8000_0000_0000_0000, 0x7ff8_1234_5678_9abc, 0x7ff0_1234_5678_9abc }) |bits| {
        try runtime.call(handle, "float_neg_bits", &.{.{ .u64 = bits }}, &result);
        try testing.expectEqual(bits ^ 0x8000_0000_0000_0000, result[0].u64);
        try runtime.call(handle, "float_abs_bits", &.{.{ .u64 = bits }}, &result);
        try testing.expectEqual(bits & 0x7fff_ffff_ffff_ffff, result[0].u64);
    }
    const first: u64 = 0x8000_0000_0000_0000;
    const second: u64 = 0x7ff0_1234_5678_9abc;
    try runtime.call(handle, "float_select_bits", &.{ .{ .bool = true }, .{ .u64 = first }, .{ .u64 = second } }, &result);
    try testing.expectEqual(first, result[0].u64);
    try runtime.call(handle, "float_select_bits", &.{ .{ .bool = false }, .{ .u64 = first }, .{ .u64 = second } }, &result);
    try testing.expectEqual(second, result[0].u64);
    try runtime.release(handle);
}

const float_predicates = [_]@import("../../dialects/root.zig").arith.CmpPredicate{ .eq, .ne, .lt, .le, .gt, .ge };
const float_predicate_names = [_][]const u8{ "float_eq", "float_ne", "float_lt", "float_le", "float_gt", "float_ge" };

fn floatComparisonModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const boolean = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    for (float_predicates, float_predicate_names) |predicate, name| {
        const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, name, &.{ floating, floating }, &.{boolean});
        try module.getBodyBlock().addOperation(function.op);
        const comparison = try dialects.ArithDialect.CmpOp.create(ctx, loc, predicate, function.getArgument(0), function.getArgument(1));
        try function.getEntryBlock().addOperation(comparison.op);
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{comparison.getResult()});
        try function.getEntryBlock().addOperation(ret.op);
    }
    return module.op;
}

test "aarch64 native execution f64 FCMP handles ordered and unordered values" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try floatComparisonModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    const rows = [_]struct { lhs: f64, rhs: f64, expected: [6]bool }{
        .{ .lhs = 1, .rhs = 2, .expected = .{ false, true, true, true, false, false } },
        .{ .lhs = 0.0, .rhs = -0.0, .expected = .{ true, false, false, true, false, true } },
        .{ .lhs = 2, .rhs = 1, .expected = .{ false, true, false, false, true, true } },
        .{ .lhs = std.math.nan(f64), .rhs = 1, .expected = .{ false, true, false, false, false, false } },
        .{ .lhs = 1, .rhs = std.math.nan(f64), .expected = .{ false, true, false, false, false, false } },
    };
    for (rows) |row| {
        for (float_predicate_names, row.expected) |name, expected| {
            var result = [_]execution.Value{.{ .bool = false }};
            try runtime.call(handle, name, &.{ .{ .f64 = row.lhs }, .{ .f64 = row.rhs } }, &result);
            try testing.expectEqual(expected, result[0].bool);
        }
    }
    try runtime.release(handle);
}

fn floatArithmeticModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "float_arithmetic", &.{ floating, floating }, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, function.getArgument(0), function.getArgument(1));
    try entry.addOperation(sum.op);
    const difference = try dialects.ArithDialect.SubOp.create(ctx, loc, function.getArgument(0), function.getArgument(1));
    try entry.addOperation(difference.op);
    const product = try dialects.ArithDialect.MulOp.create(ctx, loc, sum.getResult(), difference.getResult());
    try entry.addOperation(product.op);
    const quotient = try dialects.ArithDialect.DivOp.create(ctx, loc, product.getResult(), function.getArgument(1));
    try entry.addOperation(quotient.op);
    const negated = try dialects.ArithDialect.NegOp.create(ctx, loc, quotient.getResult());
    try entry.addOperation(negated.op);
    const absolute = try dialects.ArithDialect.AbsOp.create(ctx, loc, negated.getResult());
    try entry.addOperation(absolute.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{absolute.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

test "aarch64 native execution f64 arithmetic rounds each operation and preserves FPCR" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try floatArithmeticModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    try testing.expect(invoke.defaultFpcr());
    var result = [_]execution.Value{.{ .f64 = 0 }};
    try runtime.call(handle, "float_arithmetic", &.{ .{ .f64 = 6 }, .{ .f64 = 2 } }, &result);
    try testing.expectEqual(@as(f64, 16), result[0].f64);
    const native = try runtime.getFunction(handle, "float_arithmetic", *const fn (f64, f64) callconv(.c) f64);
    try testing.expectEqual(@as(f64, 16), native(6, 2));
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

test "aarch64 native execution f64 arithmetic keeps subnormals overflow and separate rounding" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(&ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer module.op.erase();
    const sum = try dialects.FuncDialect.FuncOp.create(&ctx, loc, "float_sum", &.{ floating, floating }, &.{floating});
    try module.getBodyBlock().addOperation(sum.op);
    const add = try dialects.ArithDialect.AddOp.create(&ctx, loc, sum.getArgument(0), sum.getArgument(1));
    try sum.getEntryBlock().addOperation(add.op);
    const sum_return = try dialects.FuncDialect.ReturnOp.create(&ctx, loc, &.{add.getResult()});
    try sum.getEntryBlock().addOperation(sum_return.op);
    const separate = try dialects.FuncDialect.FuncOp.create(&ctx, loc, "float_mul_add", &.{ floating, floating, floating }, &.{floating});
    try module.getBodyBlock().addOperation(separate.op);
    const product = try dialects.ArithDialect.MulOp.create(&ctx, loc, separate.getArgument(0), separate.getArgument(1));
    try separate.getEntryBlock().addOperation(product.op);
    const added = try dialects.ArithDialect.AddOp.create(&ctx, loc, product.getResult(), separate.getArgument(2));
    try separate.getEntryBlock().addOperation(added.op);
    const separate_return = try dialects.FuncDialect.ReturnOp.create(&ctx, loc, &.{added.getResult()});
    try separate.getEntryBlock().addOperation(separate_return.op);
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);
    var result = [_]execution.Value{.{ .f64 = 0 }};
    const least: f64 = @bitCast(@as(u64, 1));
    try runtime.call(handle, "float_sum", &.{ .{ .f64 = least }, .{ .f64 = least } }, &result);
    try testing.expectEqual(@as(u64, 2), @as(u64, @bitCast(result[0].f64)));
    try runtime.call(handle, "float_sum", &.{ .{ .f64 = std.math.floatMax(f64) }, .{ .f64 = std.math.floatMax(f64) } }, &result);
    try testing.expectEqual(@as(u64, 0x7ff0_0000_0000_0000), @as(u64, @bitCast(result[0].f64)));
    try runtime.call(handle, "float_sum", &.{ .{ .f64 = 1 }, .{ .f64 = -1 } }, &result);
    try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(result[0].f64)));
    const quiet_nan: f64 = @bitCast(@as(u64, 0x7ff8_1234_5678_9abc));
    try runtime.call(handle, "float_sum", &.{ .{ .f64 = quiet_nan }, .{ .f64 = 1 } }, &result);
    try testing.expectEqual(@as(u64, 0x7ff8_1234_5678_9abc), @as(u64, @bitCast(result[0].f64)));
    const delta: f64 = 1.0 / 134217728.0;
    try runtime.call(handle, "float_mul_add", &.{ .{ .f64 = 1.0 + delta }, .{ .f64 = 1.0 - delta }, .{ .f64 = -1.0 } }, &result);
    try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(result[0].f64)));
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

fn floatStepOracle(value: f64) callconv(.c) f64 {
    std.debug.assert(invoke.defaultFpcr());
    return value + 1;
}

fn f32NewtonModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f32);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_newton_steps", &.{floating}, &.{integer});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const guess = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, 1);
    try entry.addOperation(guess.op);
    const half = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, 0.5);
    try entry.addOperation(half.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 0);
    try entry.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 1);
    try entry.addOperation(one.op);
    const limit = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 60);
    try entry.addOperation(limit.op);
    const loop = try dialects.ScfDialect.WhileOp.create(ctx, loc, &.{ guess.getResult(), zero.getResult() }, &.{ floating, integer });
    try entry.addOperation(loop.op);
    const before = loop.getBeforeBlock();
    const divided = try dialects.ArithDialect.DivOp.create(ctx, loc, function.getArgument(0), before.arguments.items[0]);
    try before.addOperation(divided.op);
    const summed = try dialects.ArithDialect.AddOp.create(ctx, loc, before.arguments.items[0], divided.getResult());
    try before.addOperation(summed.op);
    const next = try dialects.ArithDialect.MulOp.create(ctx, loc, summed.getResult(), half.getResult());
    try before.addOperation(next.op);
    const converged = try dialects.ArithDialect.CmpOp.create(ctx, loc, .eq, next.getResult(), before.arguments.items[0]);
    try before.addOperation(converged.op);
    const not_converged = try dialects.ArithDialect.NotOp.create(ctx, loc, converged.getResult());
    try before.addOperation(not_converged.op);
    const below_limit = try dialects.ArithDialect.CmpOp.create(ctx, loc, .slt, before.arguments.items[1], limit.getResult());
    try before.addOperation(below_limit.op);
    const continuing = try dialects.ArithDialect.AndOp.create(ctx, loc, not_converged.getResult(), below_limit.getResult());
    try before.addOperation(continuing.op);
    const condition = try dialects.ScfDialect.ConditionOp.create(ctx, loc, continuing.getResult(), &.{ next.getResult(), before.arguments.items[1] });
    try before.addOperation(condition.op);
    const after = loop.getAfterBlock();
    const incremented = try dialects.ArithDialect.AddOp.create(ctx, loc, after.arguments.items[1], one.getResult());
    try after.addOperation(incremented.op);
    const yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{ after.arguments.items[0], incremented.getResult() });
    try after.addOperation(yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{loop.op.getResult(1).?});
    try entry.addOperation(ret.op);
    return module.op;
}

test "aarch64 native execution counts binary32 Newton convergence with checked and typed entry" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);
    const module = try f32NewtonModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    try testing.expect(invoke.defaultFpcr());
    const native = try runtime.getFunction(handle, "f32_newton_steps", *const fn (f32) callconv(.c) i64);
    for ([_]struct { input: f32, expected_steps: i64 }{ .{ .input = 2, .expected_steps = 4 }, .{ .input = 4, .expected_steps = 4 }, .{ .input = 9, .expected_steps = 5 } }) |row| {
        var result = [_]execution.Value{.{ .i64 = -1 }};
        try runtime.call(handle, "f32_newton_steps", &.{.{ .f32 = row.input }}, &result);
        try testing.expectEqual(row.expected_steps, result[0].i64);
        try testing.expectEqual(row.expected_steps, native(row.input));
    }
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

fn f32MixedOracle(first: f32, middle: i64) callconv(.c) f32 {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(middle == 7);
    return first + @as(f32, @floatFromInt(middle));
}

fn f32StepOracle(value: f32) callconv(.c) f32 {
    std.debug.assert(invoke.defaultFpcr());
    return value + 1;
}

fn f32EightOracle(a: f32, b: u8, c: f32, d: i64, e: f32, f: bool, g: f32, h: usize) callconv(.c) f32 {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(b == 0xff and d == -7 and f and h == std.math.maxInt(usize));
    return ((a + c) + e) + g;
}

fn f32EightModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f32);
    const narrow = try dialects.ArithDialect.getScalarType(ctx, .u8);
    const signed = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const boolean = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const index = try dialects.ArithDialect.getIndexType(ctx);
    const types = [_]ir.Type{ floating, narrow, floating, signed, floating, boolean, floating, index };
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "f32_eight_oracle", &types, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_eight_mixed", &types, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "f32_eight_oracle", function.getArguments(), &.{floating});
    try function.getEntryBlock().addOperation(call.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{call.getResult(0).?});
    try function.getEntryBlock().addOperation(ret.op);
    const floats: [8]ir.Type = @splat(floating);
    const all_floats = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_eight_floats", &floats, &.{floating});
    try module.getBodyBlock().addOperation(all_floats.op);
    var sum = all_floats.getArgument(0);
    for (1..8) |ordinal| {
        const added = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, all_floats.getArgument(ordinal));
        try all_floats.getEntryBlock().addOperation(added.op);
        sum = added.getResult();
    }
    const floats_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum});
    try all_floats.getEntryBlock().addOperation(floats_ret.op);
    return module.op;
}

test "aarch64 native execution routes eight interleaved f32 and integer arguments" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);
    const module = try f32EightModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("f32_eight_oracle", @intFromPtr(&f32EightOracle));
    const handle = try runtime.compile(module);
    var result = [_]execution.Value{.{ .f32 = 0 }};
    const mixed_args = [_]execution.Value{ .{ .f32 = 1.5 }, .{ .u8 = 0xff }, .{ .f32 = 2.5 }, .{ .i64 = -7 }, .{ .f32 = 3.5 }, .{ .bool = true }, .{ .f32 = 4.5 }, .{ .index = std.math.maxInt(u64) } };
    try runtime.call(handle, "f32_eight_mixed", &mixed_args, &result);
    try testing.expectEqual(@as(f32, 12), result[0].f32);
    const typed_mixed = try runtime.getFunction(handle, "f32_eight_mixed", *const fn (f32, u8, f32, i64, f32, bool, f32, usize) callconv(.c) f32);
    try testing.expectEqual(@as(f32, 12), typed_mixed(1.5, 0xff, 2.5, -7, 3.5, true, 4.5, std.math.maxInt(usize)));
    const float_args = [_]execution.Value{ .{ .f32 = 1 }, .{ .f32 = 2 }, .{ .f32 = 3 }, .{ .f32 = 4 }, .{ .f32 = 5 }, .{ .f32 = 6 }, .{ .f32 = 7 }, .{ .f32 = 8 } };
    try runtime.call(handle, "f32_eight_floats", &float_args, &result);
    try testing.expectEqual(@as(f32, 36), result[0].f32);
    const typed_floats = try runtime.getFunction(handle, "f32_eight_floats", *const fn (f32, f32, f32, f32, f32, f32, f32, f32) callconv(.c) f32);
    try testing.expectEqual(@as(f32, 36), typed_floats(1, 2, 3, 4, 5, 6, 7, 8));
    try runtime.release(handle);
}

fn f32MixedModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f32);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "f32_mixed_oracle", &.{ floating, integer }, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_mixed_entry", &.{ floating, integer, floating }, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "f32_mixed_oracle", &.{ function.getArgument(0), function.getArgument(1) }, &.{floating});
    try entry.addOperation(call.op);
    const added = try dialects.ArithDialect.AddOp.create(ctx, loc, call.getResult(0).?, function.getArgument(2));
    try entry.addOperation(added.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{added.getResult()});
    try entry.addOperation(ret.op);
    const wrapper = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_mixed_wrapper", &.{ floating, integer, floating }, &.{floating});
    try module.getBodyBlock().addOperation(wrapper.op);
    const internal = try dialects.FuncDialect.CallOp.create(ctx, loc, "f32_mixed_entry", wrapper.getArguments(), &.{floating});
    try wrapper.getEntryBlock().addOperation(internal.op);
    const wrapper_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{internal.getResult(0).?});
    try wrapper.getEntryBlock().addOperation(wrapper_ret.op);
    return module.op;
}

test "aarch64 native execution keeps f32 and integer banks across an external call" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);
    const module = try f32MixedModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("f32_mixed_oracle", @intFromPtr(&f32MixedOracle));
    const handle = try runtime.compile(module);
    var result = [_]execution.Value{.{ .f32 = 0 }};
    try runtime.call(handle, "f32_mixed_entry", &.{ .{ .f32 = 1.5 }, .{ .i64 = 7 }, .{ .f32 = 2.25 } }, &result);
    try testing.expectEqual(@as(f32, 10.75), result[0].f32);
    try runtime.call(handle, "f32_mixed_wrapper", &.{ .{ .f32 = 1.5 }, .{ .i64 = 7 }, .{ .f32 = 2.25 } }, &result);
    try testing.expectEqual(@as(f32, 10.75), result[0].f32);
    const native = try runtime.getFunction(handle, "f32_mixed_entry", *const fn (f32, i64, f32) callconv(.c) f32);
    try testing.expectEqual(@as(f32, 10.75), native(1.5, 7, 2.25));
    try runtime.release(handle);
}

test "aarch64 native execution transports f32 signed zero and NaN payload bits" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);
    const module = try scalarModule(&ctx, "f32_identity", .f32, 1, true);
    defer module.erase();
    const floating = try @import("../../dialects/root.zig").ArithDialect.getScalarType(&ctx, .f32);
    const constant_function = try @import("../../dialects/root.zig").FuncDialect.FuncOp.create(&ctx, .unknown, "f32_negative_zero", &.{}, &.{floating});
    try module.getRegion(0).?.getEntryBlock().?.addOperation(constant_function.op);
    const constant = try @import("../../dialects/root.zig").ArithDialect.ConstantOp.createFloat(&ctx, .unknown, floating, -0.0);
    try constant_function.getEntryBlock().addOperation(constant.op);
    const constant_return = try @import("../../dialects/root.zig").FuncDialect.ReturnOp.create(&ctx, .unknown, &.{constant.getResult()});
    try constant_function.getEntryBlock().addOperation(constant_return.op);
    const wide = try @import("../../dialects/root.zig").ArithDialect.getScalarType(&ctx, .f64);
    const wide_function = try @import("../../dialects/root.zig").FuncDialect.FuncOp.create(&ctx, .unknown, "separate_f64_identity", &.{wide}, &.{wide});
    try module.getRegion(0).?.getEntryBlock().?.addOperation(wide_function.op);
    const wide_return = try @import("../../dialects/root.zig").FuncDialect.ReturnOp.create(&ctx, .unknown, &.{wide_function.getArgument(0)});
    try wide_function.getEntryBlock().addOperation(wide_return.op);
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    const native = try runtime.getFunction(handle, "f32_identity", *const fn (f32) callconv(.c) f32);
    for ([_]u32{ 0x8000_0000, 0x7fc1_2345, 0x0000_0001 }) |bits| {
        const number: f32 = @bitCast(bits);
        var result = [_]execution.Value{.{ .f32 = 0 }};
        try runtime.call(handle, "f32_identity", &.{.{ .f32 = number }}, &result);
        try testing.expectEqual(bits, @as(u32, @bitCast(result[0].f32)));
        try testing.expectEqual(bits, @as(u32, @bitCast(native(number))));
    }
    var wrong = [_]execution.Value{.{ .f32 = 0 }};
    try testing.expectError(error.SignatureMismatch, runtime.call(handle, "f32_identity", &.{.{ .f64 = 1 }}, &wrong));
    try testing.expectEqual(@as(f32, 0), wrong[0].f32);
    var wide_result = [_]execution.Value{.{ .f64 = 0 }};
    try runtime.call(handle, "separate_f64_identity", &.{.{ .f64 = -13.25 }}, &wide_result);
    try testing.expectEqual(@as(f64, -13.25), wide_result[0].f64);
    var constant_result = [_]execution.Value{.{ .f32 = 0 }};
    try runtime.call(handle, "f32_negative_zero", &.{}, &constant_result);
    try testing.expectEqual(@as(u32, 0x8000_0000), @as(u32, @bitCast(constant_result[0].f32)));
    const constant_native = try runtime.getFunction(handle, "f32_negative_zero", *const fn () callconv(.c) f32);
    try testing.expectEqual(@as(u32, 0x8000_0000), @as(u32, @bitCast(constant_native())));
    try runtime.release(handle);
}

fn f32PressureModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f32);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "f32_step_oracle", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_pressure", &.{}, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var values: [placement.max_registers + 1]*ir.Value = undefined;
    for (&values, 0..) |*value, index| {
        const constant = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, @floatFromInt(index + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "f32_step_oracle", &.{values[0]}, &.{floating});
    try entry.addOperation(call.op);
    var sum = call.getResult(0).?;
    for (values) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, value);
        try entry.addOperation(add.op);
        sum = add.getResult();
    }
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum});
    try entry.addOperation(ret.op);
    return module.op;
}

fn f32EqualityModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f32);
    const boolean = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_equal", &.{ floating, floating }, &.{boolean});
    try module.getBodyBlock().addOperation(function.op);
    const comparison = try dialects.ArithDialect.CmpOp.create(ctx, loc, .eq, function.getArgument(0), function.getArgument(1));
    try function.getEntryBlock().addOperation(comparison.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{comparison.getResult()});
    try function.getEntryBlock().addOperation(ret.op);
    const integer_function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_equal_integer", &.{ floating, floating }, &.{integer});
    try module.getBodyBlock().addOperation(integer_function.op);
    const compared = try dialects.ArithDialect.CmpOp.create(ctx, loc, .eq, integer_function.getArgument(0), integer_function.getArgument(1));
    try integer_function.getEntryBlock().addOperation(compared.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 1);
    try integer_function.getEntryBlock().addOperation(one.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 0);
    try integer_function.getEntryBlock().addOperation(zero.op);
    const selected = try dialects.ArithDialect.SelectOp.create(ctx, loc, compared.getResult(), one.getResult(), zero.getResult());
    try integer_function.getEntryBlock().addOperation(selected.op);
    const integer_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{selected.getResult()});
    try integer_function.getEntryBlock().addOperation(integer_ret.op);
    return module.op;
}

fn f32RoundingModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f32);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const one_ulp = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_one_ulp", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(one_ulp.op);
    const delta = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, 1.0 / 8388608.0);
    try one_ulp.getEntryBlock().addOperation(delta.op);
    const added = try dialects.ArithDialect.AddOp.create(ctx, loc, one_ulp.getArgument(0), delta.getResult());
    try one_ulp.getEntryBlock().addOperation(added.op);
    const one_ulp_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{added.getResult()});
    try one_ulp.getEntryBlock().addOperation(one_ulp_ret.op);
    const unfused = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_unfused", &.{ floating, floating }, &.{floating});
    try module.getBodyBlock().addOperation(unfused.op);
    const negative_one = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, -1);
    try unfused.getEntryBlock().addOperation(negative_one.op);
    const multiplied = try dialects.ArithDialect.MulOp.create(ctx, loc, unfused.getArgument(0), unfused.getArgument(1));
    try unfused.getEntryBlock().addOperation(multiplied.op);
    const summed = try dialects.ArithDialect.AddOp.create(ctx, loc, multiplied.getResult(), negative_one.getResult());
    try unfused.getEntryBlock().addOperation(summed.op);
    const unfused_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{summed.getResult()});
    try unfused.getEntryBlock().addOperation(unfused_ret.op);
    return module.op;
}

test "aarch64 native execution rounds each f32 operation and keeps one-ULP values" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);
    const module = try f32RoundingModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    const delta: f32 = 1.0 / 8388608.0;
    var result = [_]execution.Value{.{ .f32 = 0 }};
    try runtime.call(handle, "f32_one_ulp", &.{.{ .f32 = 1 }}, &result);
    try testing.expectEqual(@as(u32, 0x3f80_0001), @as(u32, @bitCast(result[0].f32)));
    const typed_ulp = try runtime.getFunction(handle, "f32_one_ulp", *const fn (f32) callconv(.c) f32);
    try testing.expectEqual(@as(f32, 1) + delta, typed_ulp(1));
    try runtime.call(handle, "f32_unfused", &.{ .{ .f32 = 1 + delta }, .{ .f32 = 1 - delta } }, &result);
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(result[0].f32)));
    const typed_unfused = try runtime.getFunction(handle, "f32_unfused", *const fn (f32, f32) callconv(.c) f32);
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(typed_unfused(1 + delta, 1 - delta))));
    try runtime.release(handle);
}

test "aarch64 native execution compares binary32 zero and unordered NaN" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);
    const module = try f32EqualityModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    const native = try runtime.getFunction(handle, "f32_equal_integer", *const fn (f32, f32) callconv(.c) i64);
    const nan: f32 = @bitCast(@as(u32, 0x7fc1_2345));
    for ([_]struct { lhs: f32, rhs: f32, expected: bool }{
        .{ .lhs = 0, .rhs = -0.0, .expected = true },
        .{ .lhs = 1, .rhs = 2, .expected = false },
        .{ .lhs = nan, .rhs = 1, .expected = false },
    }) |row| {
        var result = [_]execution.Value{.{ .bool = false }};
        try runtime.call(handle, "f32_equal", &.{ .{ .f32 = row.lhs }, .{ .f32 = row.rhs } }, &result);
        try testing.expectEqual(row.expected, result[0].bool);
        try testing.expectEqual(@as(i64, @intFromBool(row.expected)), native(row.lhs, row.rhs));
    }
    try runtime.release(handle);
}

test "aarch64 native execution reloads spilled f32 words after a callback" {
    const builtin = @import("builtin");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);
    const module = try f32PressureModule(&ctx);
    defer module.erase();
    try backend.lowerModule(module);
    const function = ir.inspection.functionDefinitionByName(module, "f32_pressure").?;
    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(function);
    try testing.expect(emitter.plan.call_save_base != null);
    var spilled = false;
    for (emitter.plan.entries[0..emitter.plan.count]) |entry| {
        if (entry.value.getDefiningOp() == null) continue;
        const defining: *ir.Operation = @ptrCast(@alignCast(entry.value.getDefiningOp().?));
        if (std.mem.eql(u8, defining.name.name, @import("../../dialects/root.zig").ArithDialect.ConstantOp.operation_name) and entry.location == .stack) spilled = true;
    }
    try testing.expect(spilled);
    try testing.expect(emitter.plan.frame_slots <= placement.max_frame_slots);
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return;
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("f32_step_oracle", @intFromPtr(&f32StepOracle));
    const handle = try runtime.compile(module);
    var result = [_]execution.Value{.{ .f32 = 0 }};
    try runtime.call(handle, "f32_pressure", &.{}, &result);
    try testing.expectEqual(@as(f32, 38), result[0].f32);
    try runtime.release(handle);
}

fn floatControlModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const boolean = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "float_step_oracle", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "float_control", &.{ boolean, index, floating }, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 1);
    try entry.addOperation(one.op);
    const one_float = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, 1);
    try entry.addOperation(one_float.op);
    const conditional = try dialects.ScfDialect.IfOp.create(ctx, loc, function.getArgument(0), &.{floating});
    try entry.addOperation(conditional.op);
    const then_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{function.getArgument(2)});
    try conditional.getThenBlock().addOperation(then_yield.op);
    const negative_zero = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, -0.0);
    try conditional.getElseBlock().?.addOperation(negative_zero.op);
    const else_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{negative_zero.getResult()});
    try conditional.getElseBlock().?.addOperation(else_yield.op);
    const counted = try dialects.ScfDialect.ForOp.create(ctx, loc, zero.getResult(), function.getArgument(1), one.getResult(), &.{conditional.op.getResult(0).?}, &.{floating});
    try entry.addOperation(counted.op);
    const for_body = counted.getBodyBlock();
    const next_float = try dialects.ArithDialect.AddOp.create(ctx, loc, for_body.arguments.items[1], one_float.getResult());
    try for_body.addOperation(next_float.op);
    const for_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{next_float.getResult()});
    try for_body.addOperation(for_yield.op);
    const repeated = try dialects.ScfDialect.WhileOp.create(ctx, loc, &.{ zero.getResult(), counted.op.getResult(0).? }, &.{ index, floating });
    try entry.addOperation(repeated.op);
    const before = repeated.getBeforeBlock();
    const comparison = try dialects.ArithDialect.CmpOp.create(ctx, loc, .slt, before.arguments.items[0], function.getArgument(1));
    try before.addOperation(comparison.op);
    const condition = try dialects.ScfDialect.ConditionOp.create(ctx, loc, comparison.getResult(), before.arguments.items);
    try before.addOperation(condition.op);
    const after = repeated.getAfterBlock();
    const next_index = try dialects.ArithDialect.AddOp.create(ctx, loc, after.arguments.items[0], one.getResult());
    try after.addOperation(next_index.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "float_step_oracle", &.{after.arguments.items[1]}, &.{floating});
    try after.addOperation(call.op);
    const while_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{ next_index.getResult(), call.getResult(0).? });
    try after.addOperation(while_yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{repeated.op.getResult(1).?});
    try entry.addOperation(ret.op);
    return module.op;
}

test "aarch64 native execution carries f64 through If For While and an external loop call" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try floatControlModule(&ctx);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("float_step_oracle", @intFromPtr(&floatStepOracle));
    const handle = try runtime.compile(module);
    var result = [_]execution.Value{.{ .f64 = 0 }};
    for ([_]u64{ 0, 1, 3 }) |trips| {
        try runtime.call(handle, "float_control", &.{ .{ .bool = true }, .{ .index = trips }, .{ .f64 = 2.5 } }, &result);
        try testing.expectEqual(@as(f64, 2.5) + @as(f64, @floatFromInt(2 * trips)), result[0].f64);
        try runtime.call(handle, "float_control", &.{ .{ .bool = false }, .{ .index = trips }, .{ .f64 = 2.5 } }, &result);
        if (trips == 0)
            try testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), @as(u64, @bitCast(result[0].f64)))
        else
            try testing.expectEqual(@as(f64, @floatFromInt(2 * trips)), result[0].f64);
    }
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

fn floatPayloadModule(ctx: *ir.Context, words: u64) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefType1D(ctx, words, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "float_step_oracle", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "float_payload", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const alloca = try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    try entry.addOperation(alloca.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero.op);
    const bits = try dialects.ArithDialect.BitcastOp.create(ctx, loc, function.getArgument(0), word);
    try entry.addOperation(bits.op);
    const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, bits.getResult(), alloca.getResult(), zero.getResult());
    try entry.addOperation(store.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "float_step_oracle", &.{function.getArgument(0)}, &.{floating});
    try entry.addOperation(call.op);
    const load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), zero.getResult(), word);
    try entry.addOperation(load.op);
    const restored = try dialects.ArithDialect.BitcastOp.create(ctx, loc, load.getResult(), floating);
    try entry.addOperation(restored.op);
    const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, restored.getResult(), call.getResult(0).?);
    try entry.addOperation(sum.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

test "aarch64 native execution retains initialized word payload across an f64 call frame" {
    const builtin = @import("builtin");
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const accepted = try floatPayloadModule(&ctx, 47);
    defer accepted.erase();
    try backend.lowerModule(accepted);
    const function = ir.inspection.functionDefinitionByName(accepted, "float_payload").?;
    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(function);
    try testing.expectEqual(@as(u16, 0), emitter.plan.call_save_base.?);
    var operations = function.getRegion(0).?.getEntryBlock().?.getOperations();
    const alloca = operations.next().?;
    try testing.expectEqual(@as(u16, placement.call_frame_slots), emitter.plan.allocaPayload(alloca.getResult(0).?).?);
    try testing.expectEqual(placement.max_frame_slots, emitter.plan.frame_slots);
    try testing.expectEqual(@as(usize, 512), emitter.plan.frameBytes());
    const refused = try floatPayloadModule(&ctx, 48);
    defer refused.erase();
    try backend.lowerModule(refused);
    const refused_function = ir.inspection.functionDefinitionByName(refused, "float_payload").?;
    var refused_emitter = backend.Emitter.init(testing.allocator);
    defer refused_emitter.deinit();
    try testing.expectError(error.UnsupportedOperation, refused_emitter.emitFunction(refused_function));
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return;
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("float_step_oracle", @intFromPtr(&floatStepOracle));
    const handle = try runtime.compile(accepted);
    var result = [_]execution.Value{.{ .f64 = 0 }};
    try runtime.call(handle, "float_payload", &.{.{ .f64 = 2.5 }}, &result);
    try testing.expectEqual(@as(f64, 6), result[0].f64);
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

const NumericCastFunction = struct {
    name: []const u8,
    kind: @import("../../dialects/root.zig").arith.ScalarKind,
};

const numeric_cast_functions = [_]NumericCastFunction{
    .{ .name = "cast_i8", .kind = .i8 },
    .{ .name = "cast_i16", .kind = .i16 },
    .{ .name = "cast_i32", .kind = .i32 },
    .{ .name = "cast_i64", .kind = .i64 },
    .{ .name = "cast_u8", .kind = .u8 },
    .{ .name = "cast_u16", .kind = .u16 },
    .{ .name = "cast_u32", .kind = .u32 },
    .{ .name = "cast_u64", .kind = .u64 },
    .{ .name = "cast_index", .kind = .index },
};

fn numericCastModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    for (numeric_cast_functions) |definition| {
        const integer = try dialects.ArithDialect.getScalarType(ctx, definition.kind);
        const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, definition.name, &.{integer}, &.{floating});
        try module.getBodyBlock().addOperation(function.op);
        const cast = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), floating);
        try function.getEntryBlock().addOperation(cast.op);
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{cast.getResult()});
        try function.getEntryBlock().addOperation(ret.op);
    }
    return module.op;
}

fn numericCastExpected(value: execution.Value) f64 {
    return switch (value) {
        .i8 => |integer| @floatFromInt(integer),
        .i16 => |integer| @floatFromInt(integer),
        .i32 => |integer| @floatFromInt(integer),
        .i64 => |integer| @floatFromInt(integer),
        .u8 => |integer| @floatFromInt(integer),
        .u16 => |integer| @floatFromInt(integer),
        .u32 => |integer| @floatFromInt(integer),
        .u64 => |integer| @floatFromInt(integer),
        .index => |integer| @floatFromInt(integer),
        else => unreachable,
    };
}

const float_to_integer_functions = [_]NumericCastFunction{
    .{ .name = "reverse_i8", .kind = .i8 },
    .{ .name = "reverse_i16", .kind = .i16 },
    .{ .name = "reverse_i32", .kind = .i32 },
    .{ .name = "reverse_i64", .kind = .i64 },
    .{ .name = "reverse_u8", .kind = .u8 },
    .{ .name = "reverse_u16", .kind = .u16 },
    .{ .name = "reverse_u32", .kind = .u32 },
    .{ .name = "reverse_u64", .kind = .u64 },
    .{ .name = "reverse_index", .kind = .index },
};

fn floatToIntegerModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    for (float_to_integer_functions) |definition| {
        const integer = try dialects.ArithDialect.getScalarType(ctx, definition.kind);
        const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, definition.name, &.{floating}, &.{integer});
        try module.getBodyBlock().addOperation(function.op);
        const cast = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), integer);
        try function.getEntryBlock().addOperation(cast.op);
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{cast.getResult()});
        try function.getEntryBlock().addOperation(ret.op);
    }
    return module.op;
}

/// Twenty-four exact raw f64 inputs per declared width; invalid rows are
/// compared with the dialect's optional oracle without executing a trap here.
fn floatToIntegerSamples(kind: @import("../../dialects/root.zig").arith.ScalarKind) [24]f64 {
    const arith = @import("../../dialects/root.zig").arith;
    const unsigned = arith.scalarKindIsUnsignedInteger(kind) or kind == .index;
    const bits = arith.scalarBitWidth(kind);
    const exponent: u7 = @intCast(bits - @as(u8, if (unsigned) 0 else 1));
    const upper: f64 = @floatFromInt(@as(u128, 1) << exponent);
    const lower: f64 = if (unsigned) -1 else if (bits == 64) -upper else -upper - 1;
    const lower_bits: u64 = @bitCast(lower);
    const upper_bits: u64 = @bitCast(upper);
    const subnormal: f64 = @bitCast(@as(u64, 1));
    return .{
        0,                                         -0.0,                                      subnormal,                                 -subnormal,                                0.5,                                       -0.5,                     1.75,               -1.75,
        lower,                                     @bitCast(lower_bits + 1),                  @bitCast(lower_bits - 1),                  upper,                                     @bitCast(upper_bits - 1),                  @bitCast(upper_bits + 1), -1,                 @bitCast(@as(u64, 0xfff8_1234_5678_9abc)),
        @bitCast(@as(u64, 0x7ff0_1234_5678_9abc)), @bitCast(@as(u64, 0xfff0_1234_5678_9abc)), @bitCast(@as(u64, 0x43e0_0000_0000_0000)), @bitCast(@as(u64, 0x43ef_ffff_ffff_ffff)), @bitCast(@as(u64, 0x43f0_0000_0000_0000)), std.math.inf(f64),        -std.math.inf(f64), @bitCast(@as(u64, 0x7ff8_1234_5678_9abc)),
    };
}

fn floatToIntegerValue(kind: @import("../../dialects/root.zig").arith.ScalarKind, raw: i64) execution.Value {
    const bits: u64 = @bitCast(raw);
    return switch (kind) {
        .i8 => .{ .i8 = @intCast(raw) },
        .i16 => .{ .i16 = @intCast(raw) },
        .i32 => .{ .i32 = @intCast(raw) },
        .i64 => .{ .i64 = raw },
        .u8 => .{ .u8 = @truncate(bits) },
        .u16 => .{ .u16 = @truncate(bits) },
        .u32 => .{ .u32 = @truncate(bits) },
        .u64 => .{ .u64 = bits },
        .index => .{ .index = bits },
        else => unreachable,
    };
}

test "aarch64 native execution classifies every fixed f64 to integer input before execution" {
    const arith = @import("../../dialects/root.zig").arith;
    const testing = std.testing;
    // Independently calculated from the exact IEEE bits by integer-range math.
    const validity = [_]u24{
        0x0054ff, 0x0054ff, 0x0054ff, 0x0055ff,
        0x00147f, 0x00147f, 0x00147f, 0x0c147f,
        0x0c147f,
    };
    var valid: usize = 0;
    var invalid: usize = 0;
    for (float_to_integer_functions, 0..) |definition, definition_index| {
        const kind = definition.kind;
        const signed = arith.scalarKindIsSignedInteger(kind) and kind != .index;
        for (floatToIntegerSamples(kind), 0..) |input, sample_index| {
            const raw = arith.scalar.floatToInt(input, arith.scalarBitWidth(kind), signed);
            const expected_valid = (validity[definition_index] & (@as(u24, 1) << @as(u5, @intCast(sample_index)))) != 0;
            try testing.expectEqual(expected_valid, raw != null);
            if (raw) |integer| {
                valid += 1;
                const truncated = @trunc(input);
                const independent: i64 = if (truncated < 0)
                    @intFromFloat(truncated)
                else
                    @bitCast(@as(u64, @intFromFloat(truncated)));
                try testing.expectEqual(independent, integer);
            } else {
                invalid += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 94), valid);
    try testing.expectEqual(@as(usize, 122), invalid);
}

fn expectInvalidFloatToIntegerTrap(comptime Result: type, native: *const fn (f64) callconv(.c) Result, input: f64) !void {
    const child = std.c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        _ = native(input);
        std.c._exit(102);
    }
    const termination = try sys.process.waitDirect(@intCast(child));
    switch (termination) {
        .signal => |signal| try std.testing.expect(signal == .TRAP),
        else => return error.ExpectedSigtrap,
    }
}

fn expectValidFloatToIntegerChild(comptime Result: type, native: *const fn (f64) callconv(.c) Result) !void {
    const child = std.c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        if (native(1.75) != @as(Result, 1)) std.c._exit(101);
        std.c._exit(0);
    }
    const termination = try sys.process.waitDirect(@intCast(child));
    switch (termination) {
        .exited => |status| try std.testing.expectEqual(@as(u8, 0), status),
        else => return error.ExpectedNormalChildExit,
    }
}

test "aarch64 native execution traps invalid dynamic f64 conversions before returning" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try floatToIntegerModule(&ctx);
    defer module.erase();
    const dead = try unusedNumericCastModule(&ctx, .f64, .i64);
    defer dead.module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    defer runtime.release(handle) catch unreachable;
    const dead_handle = try runtime.compile(dead.module);
    defer runtime.release(dead_handle) catch unreachable;
    const dead_native = try runtime.getFunction(dead_handle, "unused_numeric_cast", *const fn (f64) callconv(.c) f64);
    try expectInvalidFloatToIntegerTrap(f64, dead_native, floatToIntegerSamples(.i64)[23]);
    inline for (float_to_integer_functions) |definition| {
        const kind = definition.kind;
        const Result = switch (kind) {
            .i8 => i8,
            .i16 => i16,
            .i32 => i32,
            .i64 => i64,
            .u8 => u8,
            .u16 => u16,
            .u32 => u32,
            .u64 => u64,
            .index => usize,
            else => unreachable,
        };
        const native = try runtime.getFunction(handle, definition.name, *const fn (f64) callconv(.c) Result);
        try expectValidFloatToIntegerChild(Result, native);
        const samples = floatToIntegerSamples(kind);
        const lower_invalid: usize = if (kind == .i64) 9 else 8;
        for ([_]usize{ lower_invalid, 11, 15, 16, 17, 21, 22, 23 }) |index| {
            const input = samples[index];
            try expectInvalidFloatToIntegerTrap(Result, native, input);
        }
    }
    try testing.expect(invoke.defaultFpcr());
}

test "aarch64 native execution guards finite f64 conversion at every integer width" {
    const builtin = @import("builtin");
    const testing = std.testing;
    const arith = @import("../../dialects/root.zig").arith;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);
    const module = try floatToIntegerModule(&ctx);
    defer module.erase();
    try backend.lowerModule(module);
    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    for (float_to_integer_functions) |definition| {
        const function = ir.inspection.functionDefinitionByName(module, definition.name).?;
        try emitter.emitFunction(function);
        emitter.discard();
    }
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return;
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    for (float_to_integer_functions) |definition| {
        const kind = definition.kind;
        const signed = arith.scalarKindIsSignedInteger(kind) and kind != .index;
        for (floatToIntegerSamples(kind)) |input| {
            const raw = arith.scalar.floatToInt(input, arith.scalarBitWidth(kind), signed) orelse continue;
            var result = [_]execution.Value{floatToIntegerValue(kind, 0)};
            try runtime.call(handle, definition.name, &.{.{ .f64 = input }}, &result);
            try testing.expectEqual(floatToIntegerValue(kind, raw), result[0]);
        }
    }
    const typed_i8 = try runtime.getFunction(handle, "reverse_i8", *const fn (f64) callconv(.c) i8);
    const typed_i16 = try runtime.getFunction(handle, "reverse_i16", *const fn (f64) callconv(.c) i16);
    const typed_i32 = try runtime.getFunction(handle, "reverse_i32", *const fn (f64) callconv(.c) i32);
    const typed_i64 = try runtime.getFunction(handle, "reverse_i64", *const fn (f64) callconv(.c) i64);
    const typed_u8 = try runtime.getFunction(handle, "reverse_u8", *const fn (f64) callconv(.c) u8);
    const typed_u16 = try runtime.getFunction(handle, "reverse_u16", *const fn (f64) callconv(.c) u16);
    const typed_u32 = try runtime.getFunction(handle, "reverse_u32", *const fn (f64) callconv(.c) u32);
    const typed_u64 = try runtime.getFunction(handle, "reverse_u64", *const fn (f64) callconv(.c) u64);
    const typed_index = try runtime.getFunction(handle, "reverse_index", *const fn (f64) callconv(.c) usize);
    try testing.expectEqual(@as(i8, -1), typed_i8(-1.75));
    try testing.expectEqual(@as(i16, -1), typed_i16(-1.75));
    try testing.expectEqual(@as(i32, -1), typed_i32(-1.75));
    try testing.expectEqual(@as(i64, -1), typed_i64(-1.75));
    try testing.expectEqual(@as(u8, 1), typed_u8(1.75));
    try testing.expectEqual(@as(u16, 1), typed_u16(1.75));
    try testing.expectEqual(@as(u32, 1), typed_u32(1.75));
    const high_unsigned: f64 = @bitCast(@as(u64, 0x43ef_ffff_ffff_ffff));
    const high_expected: u64 = @intFromFloat(high_unsigned);
    try testing.expectEqual(high_expected, typed_u64(high_unsigned));
    try testing.expectEqual(@as(usize, @intCast(high_expected)), typed_index(high_unsigned));
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

fn reverseMixedModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const to_float = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "reverse_to_float", &.{integer}, &.{floating});
    try module.getBodyBlock().addOperation(to_float.op);
    const to_integer = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "reverse_to_integer", &.{floating}, &.{integer});
    try module.getBodyBlock().addOperation(to_integer.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "reverse_mixed", &.{floating}, &.{integer});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const cast = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), integer);
    try entry.addOperation(cast.op);
    const floating_call = try dialects.FuncDialect.CallOp.create(ctx, loc, "reverse_to_float", &.{cast.getResult()}, &.{floating});
    try entry.addOperation(floating_call.op);
    const integer_call = try dialects.FuncDialect.CallOp.create(ctx, loc, "reverse_to_integer", &.{floating_call.getResult(0).?}, &.{integer});
    try entry.addOperation(integer_call.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{integer_call.getResult(0).?});
    try entry.addOperation(ret.op);
    return module.op;
}

fn reverseToFloat(value: i64) callconv(.c) f64 {
    std.debug.assert(invoke.defaultFpcr());
    return @as(f64, @floatFromInt(value)) + 0.75;
}

fn reverseToInteger(value: f64) callconv(.c) i64 {
    std.debug.assert(invoke.defaultFpcr());
    return @as(i64, @intFromFloat(value)) + 2;
}

test "aarch64 native execution carries guarded reverse conversion through both external ABI banks" {
    const builtin = @import("builtin");
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try reverseMixedModule(&ctx);
    defer module.erase();
    try backend.lowerModule(module);
    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(ir.inspection.functionDefinitionByName(module, "reverse_mixed").?);
    try testing.expect(emitter.plan.call_save_base != null);
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return;
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("reverse_to_float", @intFromPtr(&reverseToFloat));
    try runtime.registerExternalSymbol("reverse_to_integer", @intFromPtr(&reverseToInteger));
    const handle = try runtime.compile(module);
    var result = [_]execution.Value{.{ .i64 = 0 }};
    try runtime.call(handle, "reverse_mixed", &.{.{ .f64 = 3.75 }}, &result);
    try testing.expectEqual(@as(i64, 5), result[0].i64);
    const native = try runtime.getFunction(handle, "reverse_mixed", *const fn (f64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 5), native(3.75));
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

const ReversePressure = struct { module: *ir.Operation, converted: *ir.Value };

fn reversePressureModule(ctx: *ir.Context) !ReversePressure {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "reverse_integer_step", &.{integer}, &.{integer});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "reverse_pressure", &.{floating}, &.{integer});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var values: [placement.max_registers]*ir.Value = undefined;
    for (&values, 0..) |*value, index| {
        const constant = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, @floatFromInt(index + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const converted = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), integer);
    try entry.addOperation(converted.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "reverse_integer_step", &.{converted.getResult()}, &.{integer});
    try entry.addOperation(call.op);
    var float_sum = values[0];
    for (values[1..]) |value| {
        const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, float_sum, value);
        try entry.addOperation(sum.op);
        float_sum = sum.getResult();
    }
    const constant_sum = try dialects.ArithDialect.CastOp.create(ctx, loc, float_sum, integer);
    try entry.addOperation(constant_sum.op);
    const first_sum = try dialects.ArithDialect.AddOp.create(ctx, loc, call.getResult(0).?, converted.getResult());
    try entry.addOperation(first_sum.op);
    const second_sum = try dialects.ArithDialect.AddOp.create(ctx, loc, first_sum.getResult(), constant_sum.getResult());
    try entry.addOperation(second_sum.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{second_sum.getResult()});
    try entry.addOperation(ret.op);
    return .{ .module = module.op, .converted = converted.getResult() };
}

fn reverseIntegerStep(value: i64) callconv(.c) i64 {
    std.debug.assert(invoke.defaultFpcr());
    return value + 1;
}

test "aarch64 native execution reloads a guarded reverse conversion across a call spill" {
    const builtin = @import("builtin");
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const witness = try reversePressureModule(&ctx);
    defer witness.module.erase();
    try backend.lowerModule(witness.module);
    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(ir.inspection.functionDefinitionByName(witness.module, "reverse_pressure").?);
    try testing.expect(emitter.plan.call_save_base != null);
    switch (emitter.plan.get(witness.converted).?) {
        .stack => {},
        else => return error.ExpectedConvertedIntegerSpill,
    }
    try testing.expect(emitter.plan.frame_slots <= placement.max_frame_slots);
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return;
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("reverse_integer_step", @intFromPtr(&reverseIntegerStep));
    const handle = try runtime.compile(witness.module);
    var result = [_]execution.Value{.{ .i64 = 0 }};
    try runtime.call(handle, "reverse_pressure", &.{.{ .f64 = 3.75 }}, &result);
    try testing.expectEqual(@as(i64, 35), result[0].i64);
    const native = try runtime.getFunction(handle, "reverse_pressure", *const fn (f64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 35), native(3.75));
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

fn reverseLoopModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "reverse_loop", &.{ floating, index }, &.{integer});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const zero_index = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero_index.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 1);
    try entry.addOperation(one.op);
    const zero_integer = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 0);
    try entry.addOperation(zero_integer.op);
    const loop = try dialects.ScfDialect.ForOp.create(ctx, loc, zero_index.getResult(), function.getArgument(1), one.getResult(), &.{zero_integer.getResult()}, &.{integer});
    try entry.addOperation(loop.op);
    const body = loop.getBodyBlock();
    const converted = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), integer);
    try body.addOperation(converted.op);
    const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, body.arguments.items[1], converted.getResult());
    try body.addOperation(sum.op);
    const yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{sum.getResult()});
    try body.addOperation(yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{loop.op.getResult(0).?});
    try entry.addOperation(ret.op);
    return module.op;
}

test "aarch64 native execution carries guarded reverse conversion through a bounded loop" {
    const builtin = @import("builtin");
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try reverseLoopModule(&ctx);
    defer module.erase();
    try backend.lowerModule(module);
    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(ir.inspection.functionDefinitionByName(module, "reverse_loop").?);
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return;
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    for ([_]struct { trips: u64, expected: i64 }{
        .{ .trips = 0, .expected = 0 },
        .{ .trips = 1, .expected = 2 },
        .{ .trips = 3, .expected = 6 },
    }) |case| {
        var result = [_]execution.Value{.{ .i64 = -1 }};
        try runtime.call(handle, "reverse_loop", &.{ .{ .f64 = 2.75 }, .{ .index = case.trips } }, &result);
        try testing.expectEqual(case.expected, result[0].i64);
    }
    const native = try runtime.getFunction(handle, "reverse_loop", *const fn (f64, usize) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 6), native(2.75, 3));
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

test "aarch64 native execution converts declared integer widths and unsigned index to f64" {
    const builtin = @import("builtin");
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try numericCastModule(&ctx);
    defer module.erase();
    try backend.lowerModule(module);
    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    for (numeric_cast_functions) |definition| {
        const function = ir.inspection.functionDefinitionByName(module, definition.name).?;
        try emitter.emitFunction(function);
        emitter.discard();
    }
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return;
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    const cases = [_]struct { name: []const u8, input: execution.Value }{
        .{ .name = "cast_i8", .input = .{ .i8 = 0 } },
        .{ .name = "cast_i8", .input = .{ .i8 = 1 } },
        .{ .name = "cast_i8", .input = .{ .i8 = -128 } },
        .{ .name = "cast_i8", .input = .{ .i8 = 127 } },
        .{ .name = "cast_i16", .input = .{ .i16 = 0 } },
        .{ .name = "cast_i16", .input = .{ .i16 = 1 } },
        .{ .name = "cast_i16", .input = .{ .i16 = -32768 } },
        .{ .name = "cast_i16", .input = .{ .i16 = 32767 } },
        .{ .name = "cast_i32", .input = .{ .i32 = 0 } },
        .{ .name = "cast_i32", .input = .{ .i32 = 1 } },
        .{ .name = "cast_i32", .input = .{ .i32 = std.math.minInt(i32) } },
        .{ .name = "cast_i32", .input = .{ .i32 = std.math.maxInt(i32) } },
        .{ .name = "cast_i64", .input = .{ .i64 = 0 } },
        .{ .name = "cast_i64", .input = .{ .i64 = 1 } },
        .{ .name = "cast_i64", .input = .{ .i64 = std.math.minInt(i64) } },
        .{ .name = "cast_i64", .input = .{ .i64 = -9007199254740995 } },
        .{ .name = "cast_i64", .input = .{ .i64 = -9007199254740993 } },
        .{ .name = "cast_i64", .input = .{ .i64 = 9007199254740993 } },
        .{ .name = "cast_i64", .input = .{ .i64 = 9007199254740995 } },
        .{ .name = "cast_i64", .input = .{ .i64 = std.math.maxInt(i64) } },
        .{ .name = "cast_u8", .input = .{ .u8 = 0 } },
        .{ .name = "cast_u8", .input = .{ .u8 = std.math.maxInt(u8) } },
        .{ .name = "cast_u8", .input = .{ .u8 = 1 } },
        .{ .name = "cast_u16", .input = .{ .u16 = 0 } },
        .{ .name = "cast_u16", .input = .{ .u16 = 1 } },
        .{ .name = "cast_u16", .input = .{ .u16 = std.math.maxInt(u16) } },
        .{ .name = "cast_u32", .input = .{ .u32 = 0 } },
        .{ .name = "cast_u32", .input = .{ .u32 = 1 } },
        .{ .name = "cast_u32", .input = .{ .u32 = std.math.maxInt(u32) } },
        .{ .name = "cast_u64", .input = .{ .u64 = 0 } },
        .{ .name = "cast_u64", .input = .{ .u64 = 1 } },
        .{ .name = "cast_u64", .input = .{ .u64 = 9007199254740991 } },
        .{ .name = "cast_u64", .input = .{ .u64 = 9007199254740992 } },
        .{ .name = "cast_u64", .input = .{ .u64 = 9007199254740993 } },
        .{ .name = "cast_u64", .input = .{ .u64 = 9007199254740994 } },
        .{ .name = "cast_u64", .input = .{ .u64 = 9007199254740995 } },
        .{ .name = "cast_u64", .input = .{ .u64 = 0x8000_0000_0000_0000 } },
        .{ .name = "cast_u64", .input = .{ .u64 = std.math.maxInt(u64) } },
        .{ .name = "cast_index", .input = .{ .index = 0 } },
        .{ .name = "cast_index", .input = .{ .index = 1 } },
        .{ .name = "cast_index", .input = .{ .index = 0x8000_0000_0000_0000 } },
        .{ .name = "cast_index", .input = .{ .index = std.math.maxInt(u64) } },
    };
    try testing.expect(invoke.defaultFpcr());
    for (cases) |case| {
        var result = [_]execution.Value{.{ .f64 = 0 }};
        try runtime.call(handle, case.name, &.{case.input}, &result);
        try testing.expectEqual(@as(u64, @bitCast(numericCastExpected(case.input))), @as(u64, @bitCast(result[0].f64)));
    }
    const typed_signed = try runtime.getFunction(handle, "cast_i8", *const fn (i8) callconv(.c) f64);
    try testing.expectEqual(@as(f64, -128), typed_signed(-128));
    const typed_unsigned = try runtime.getFunction(handle, "cast_u64", *const fn (u64) callconv(.c) f64);
    try testing.expectEqual(@as(f64, @floatFromInt(std.math.maxInt(u64))), typed_unsigned(std.math.maxInt(u64)));
    const typed_index = try runtime.getFunction(handle, "cast_index", *const fn (usize) callconv(.c) f64);
    try testing.expectEqual(@as(f64, @floatFromInt(std.math.maxInt(usize))), typed_index(std.math.maxInt(usize)));
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

fn unusedNumericCastModule(
    ctx: *ir.Context,
    source_kind: @import("../../dialects/root.zig").arith.ScalarKind,
    result_kind: @import("../../dialects/root.zig").arith.ScalarKind,
) !struct { module: *ir.Operation, function: *ir.Operation, cast: *ir.Operation } {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const source = try dialects.ArithDialect.getScalarType(ctx, source_kind);
    const result = try dialects.ArithDialect.getScalarType(ctx, result_kind);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "unused_numeric_cast", &.{source}, &.{source});
    try module.getBodyBlock().addOperation(function.op);
    const cast = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), result);
    try function.getEntryBlock().addOperation(cast.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{function.getArgument(0)});
    try function.getEntryBlock().addOperation(ret.op);
    return .{ .module = module.op, .function = function.op, .cast = cast.op };
}

fn constantFloatToIntegerModule(
    ctx: *ir.Context,
    number: f64,
    result_kind: @import("../../dialects/root.zig").arith.ScalarKind,
) !struct { module: *ir.Operation, function: *ir.Operation, cast: *ir.Operation } {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const integer = try dialects.ArithDialect.getScalarType(ctx, result_kind);
    const return_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "constant_float_cast", &.{}, &.{return_type});
    try module.getBodyBlock().addOperation(function.op);
    const constant = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, number);
    try function.getEntryBlock().addOperation(constant.op);
    const cast = try dialects.ArithDialect.CastOp.create(ctx, loc, constant.getResult(), integer);
    try function.getEntryBlock().addOperation(cast.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, return_type, 0);
    try function.getEntryBlock().addOperation(zero.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{zero.getResult()});
    try function.getEntryBlock().addOperation(ret.op);
    return .{ .module = module.op, .function = function.op, .cast = cast.op };
}

const FloatToIntegerDiagnostic = struct {
    operation: []const u8 = "",
    message: []const u8 = "",

    fn record(context: ?*anyopaque, diagnostic: *const @import("../../root.zig").diagnostics.Diagnostic) !@import("../../root.zig").diagnostics.HandlerResult {
        const self: *FloatToIntegerDiagnostic = @ptrCast(@alignCast(context.?));
        self.operation = diagnostic.operationName() orelse "";
        self.message = diagnostic.message;
        return .consumed;
    }
};

test "aarch64 native execution refuses statically invalid f64 conversion before dead-result elision" {
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);
    var captured: FloatToIntegerDiagnostic = .{};
    _ = try ctx.registerDiagnosticHandler(.{ .context = &captured, .handle = FloatToIntegerDiagnostic.record });
    for ([_]struct { number: f64, kind: @import("../../dialects/root.zig").arith.ScalarKind }{
        .{ .number = std.math.nan(f64), .kind = .i64 },
        .{ .number = std.math.inf(f64), .kind = .u8 },
        .{ .number = -129, .kind = .i8 },
        .{ .number = 256, .kind = .u8 },
        .{ .number = @bitCast(@as(u64, 0x43f0_0000_0000_0000)), .kind = .index },
    }) |case| {
        const witness = try constantFloatToIntegerModule(&ctx, case.number, case.kind);
        defer witness.module.erase();
        var emitter = backend.Emitter.init(testing.allocator);
        defer emitter.deinit();
        captured = .{};
        try testing.expectError(error.UnsupportedOperation, emitter.emitFunction(witness.function));
        try testing.expectEqual(witness.cast, emitter.failed_operation.?);
        try testing.expectEqualStrings("arith.cast", captured.operation);
        try testing.expect(std.mem.indexOf(u8, captured.message, "InvalidFloatToInteger") != null);
    }
    const dynamic = try unusedNumericCastModule(&ctx, .f64, .i64);
    defer dynamic.module.erase();
    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(dynamic.function);
    try testing.expect(std.mem.indexOf(u8, emitter.code.items, &.{ 0x00, 0x00, 0x20, 0xd4 }) != null);
}

test "aarch64 native execution refuses reverse conversion under nondefault floating policy" {
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const witness = try unusedNumericCastModule(&ctx, .f64, .i64);
    defer witness.module.erase();
    for ([_]enum { unmasked, rounding, observable }{ .unmasked, .rounding, .observable }) |case| {
        ctx.arithmetic_policy = .{};
        switch (case) {
            .unmasked => ctx.arithmetic_policy.exceptions_masked = false,
            .rounding => ctx.arithmetic_policy.default_rounding = false,
            .observable => ctx.arithmetic_policy.environment_observable = true,
        }
        var emitter = backend.Emitter.init(testing.allocator);
        defer emitter.deinit();
        try testing.expectError(error.UnsupportedOperation, emitter.emitFunction(witness.function));
        try testing.expectEqual(witness.function, emitter.failed_operation.?);
    }
    ctx.arithmetic_policy = .{};
    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(witness.function);
}

test "aarch64 native execution refuses invalid or untrusted numeric casts before dead-result elision" {
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const boolean = try unusedNumericCastModule(&ctx, .bool, .f64);
    defer boolean.module.erase();
    var bool_emitter = backend.Emitter.init(testing.allocator);
    defer bool_emitter.deinit();
    try testing.expectError(error.UnsupportedOperation, bool_emitter.emitFunction(boolean.function));
    try testing.expectEqual(boolean.cast, bool_emitter.failed_operation.?);
    const reverse = try unusedNumericCastModule(&ctx, .f32, .i64);
    defer reverse.module.erase();
    var reverse_emitter = backend.Emitter.init(testing.allocator);
    defer reverse_emitter.deinit();
    try testing.expectError(error.UnsupportedOperation, reverse_emitter.emitFunction(reverse.function));
    try testing.expectEqual(reverse.cast, reverse_emitter.failed_operation.?);
    const dead = try unusedNumericCastModule(&ctx, .i64, .f64);
    defer dead.module.erase();
    for ([_]enum { unmasked, rounding, observable }{ .unmasked, .rounding, .observable }) |case| {
        ctx.arithmetic_policy = .{};
        switch (case) {
            .unmasked => ctx.arithmetic_policy.exceptions_masked = false,
            .rounding => ctx.arithmetic_policy.default_rounding = false,
            .observable => ctx.arithmetic_policy.environment_observable = true,
        }
        var emitter = backend.Emitter.init(testing.allocator);
        defer emitter.deinit();
        try testing.expectError(error.UnsupportedOperation, emitter.emitFunction(dead.function));
        try testing.expectEqual(dead.cast, emitter.failed_operation.?);
    }
    ctx.arithmetic_policy = .{};
    var admitted = backend.Emitter.init(testing.allocator);
    defer admitted.deinit();
    try admitted.emitFunction(dead.function);
}

fn numericCastLoopModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "float_step_oracle", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "numeric_cast_loop", &.{index}, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 1);
    try entry.addOperation(one.op);
    const floating_zero = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, 0);
    try entry.addOperation(floating_zero.op);
    const loop = try dialects.ScfDialect.ForOp.create(ctx, loc, zero.getResult(), function.getArgument(0), one.getResult(), &.{floating_zero.getResult()}, &.{floating});
    try entry.addOperation(loop.op);
    const body = loop.getBodyBlock();
    const converted = try dialects.ArithDialect.CastOp.create(ctx, loc, body.arguments.items[0], floating);
    try body.addOperation(converted.op);
    const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, body.arguments.items[1], converted.getResult());
    try body.addOperation(sum.op);
    const step = try dialects.FuncDialect.CallOp.create(ctx, loc, "float_step_oracle", &.{sum.getResult()}, &.{floating});
    try body.addOperation(step.op);
    const yielded = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{step.getResult(0).?});
    try body.addOperation(yielded.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{loop.op.getResult(0).?});
    try entry.addOperation(ret.op);
    const wrapper = try dialects.FuncDialect.FuncOp.create(ctx, loc, "numeric_cast_wrapper", &.{index}, &.{floating});
    try module.getBodyBlock().addOperation(wrapper.op);
    const internal = try dialects.FuncDialect.CallOp.create(ctx, loc, "numeric_cast_loop", wrapper.getArguments(), &.{floating});
    try wrapper.getEntryBlock().addOperation(internal.op);
    const wrapper_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{internal.getResult(0).?});
    try wrapper.getEntryBlock().addOperation(wrapper_ret.op);
    return module.op;
}

test "aarch64 native execution carries converted index through a loop and external and internal calls" {
    const builtin = @import("builtin");
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try numericCastLoopModule(&ctx);
    defer module.erase();
    try backend.lowerModule(module);
    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    for ([_][]const u8{ "numeric_cast_loop", "numeric_cast_wrapper" }) |name| {
        try emitter.emitFunction(ir.inspection.functionDefinitionByName(module, name).?);
        emitter.discard();
    }
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return;
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("float_step_oracle", @intFromPtr(&floatStepOracle));
    const handle = try runtime.compile(module);
    for ([_]struct { trips: u64, expected: f64 }{
        .{ .trips = 0, .expected = 0 },
        .{ .trips = 1, .expected = 1 },
        .{ .trips = 3, .expected = 6 },
    }) |case| {
        var result = [_]execution.Value{.{ .f64 = -1 }};
        try runtime.call(handle, "numeric_cast_loop", &.{.{ .index = case.trips }}, &result);
        try testing.expectEqual(case.expected, result[0].f64);
        try runtime.call(handle, "numeric_cast_wrapper", &.{.{ .index = case.trips }}, &result);
        try testing.expectEqual(case.expected, result[0].f64);
    }
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

const NumericCastPressure = struct { module: *ir.Operation, source: *ir.Value, converted: *ir.Value };

fn numericCastPressureModule(ctx: *ir.Context) !NumericCastPressure {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "float_step_oracle", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "numeric_cast_pressure", &.{word}, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var values: [placement.max_registers]*ir.Value = undefined;
    for (&values, 0..) |*value, index| {
        const constant = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, @floatFromInt(index + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const source = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), word);
    try entry.addOperation(source.op);
    const converted = try dialects.ArithDialect.CastOp.create(ctx, loc, source.getResult(), floating);
    try entry.addOperation(converted.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "float_step_oracle", &.{values[0]}, &.{floating});
    try entry.addOperation(call.op);
    var sum = call.getResult(0).?;
    const first_sum = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, converted.getResult());
    try entry.addOperation(first_sum.op);
    sum = first_sum.getResult();
    for (values) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, value);
        try entry.addOperation(add.op);
        sum = add.getResult();
    }
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum});
    try entry.addOperation(ret.op);
    return .{ .module = module.op, .source = source.getResult(), .converted = converted.getResult() };
}

test "aarch64 native execution reloads a converted f64 spill after an external call" {
    const builtin = @import("builtin");
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const witness = try numericCastPressureModule(&ctx);
    defer witness.module.erase();
    try backend.lowerModule(witness.module);
    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    const function = ir.inspection.functionDefinitionByName(witness.module, "numeric_cast_pressure").?;
    try emitter.emitFunction(function);
    try testing.expect(emitter.plan.call_save_base != null);
    switch (emitter.plan.get(witness.source).?) {
        .stack => {},
        else => return error.ExpectedIntegerSourceSpill,
    }
    switch (emitter.plan.get(witness.converted).?) {
        .stack => {},
        else => return error.ExpectedConvertedSpill,
    }
    try testing.expect(emitter.plan.frame_slots <= placement.max_frame_slots);
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return;
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("float_step_oracle", @intFromPtr(&floatStepOracle));
    const handle = try runtime.compile(witness.module);
    var result = [_]execution.Value{.{ .f64 = 0 }};
    try runtime.call(handle, "numeric_cast_pressure", &.{.{ .u64 = 3 }}, &result);
    try testing.expectEqual(@as(f64, 33), result[0].f64);
    const native = try runtime.getFunction(handle, "numeric_cast_pressure", *const fn (u64) callconv(.c) f64);
    try testing.expectEqual(@as(f64, 33), native(3));
    try testing.expect(invoke.defaultFpcr());
    try runtime.release(handle);
}

fn floatPressureModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "float_step_oracle", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "float_pressure", &.{}, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var values: [placement.max_registers + 1]*ir.Value = undefined;
    for (&values, 0..) |*value, index| {
        const constant = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, @floatFromInt(index + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "float_step_oracle", &.{values[0]}, &.{floating});
    try entry.addOperation(call.op);
    var sum = call.getResult(0).?;
    for (values) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, value);
        try entry.addOperation(add.op);
        sum = add.getResult();
    }
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum});
    try entry.addOperation(ret.op);
    return module.op;
}

test "aarch64 native execution reloads spilled f64 values after a direct call" {
    const builtin = @import("builtin");
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try floatPressureModule(&ctx);
    defer module.erase();
    try backend.lowerModule(module);
    const function = ir.inspection.functionDefinitionByName(module, "float_pressure").?;
    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(function);
    try testing.expect(emitter.plan.call_save_base != null);
    var spilled = false;
    for (emitter.plan.entries[0..emitter.plan.count]) |entry| {
        if (entry.value.getDefiningOp() == null) continue;
        const defining: *ir.Operation = @ptrCast(@alignCast(entry.value.getDefiningOp().?));
        if (std.mem.eql(u8, defining.name.name, dialects.ArithDialect.ConstantOp.operation_name) and entry.location == .stack) spilled = true;
    }
    try testing.expect(spilled);
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return;
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("float_step_oracle", @intFromPtr(&floatStepOracle));
    const handle = try runtime.compile(module);
    var result = [_]execution.Value{.{ .f64 = 0 }};
    try runtime.call(handle, "float_pressure", &.{}, &result);
    try testing.expectEqual(@as(f64, 38), result[0].f64);
    try runtime.release(handle);
}

test "aarch64 native execution materializes a zero-argument f64 constant" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(&ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(&ctx, loc, "negative_zero", &.{}, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const constant = try dialects.ArithDialect.ConstantOp.createFloat(&ctx, loc, floating, -0.0);
    try function.getEntryBlock().addOperation(constant.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(&ctx, loc, &.{constant.getResult()});
    try function.getEntryBlock().addOperation(ret.op);
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);
    var result = [_]execution.Value{.{ .f64 = 0 }};
    try runtime.call(handle, "negative_zero", &.{}, &result);
    try testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), @as(u64, @bitCast(result[0].f64)));
    const native = try runtime.getFunction(handle, "negative_zero", *const fn () callconv(.c) f64);
    try testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), @as(u64, @bitCast(native())));
    try runtime.release(handle);
}

test "aarch64 native execution refuses nondefault floating context and float predicate aliases" {
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const arithmetic = try floatArithmeticModule(&ctx);
    defer arithmetic.erase();
    const arithmetic_function = ir.inspection.functionDefinitionByName(arithmetic, "float_arithmetic").?;
    for ([_]enum { unmasked, rounding, observable }{ .unmasked, .rounding, .observable }) |case| {
        ctx.arithmetic_policy = .{};
        switch (case) {
            .unmasked => ctx.arithmetic_policy.exceptions_masked = false,
            .rounding => ctx.arithmetic_policy.default_rounding = false,
            .observable => ctx.arithmetic_policy.environment_observable = true,
        }
        var emitter = backend.Emitter.init(testing.allocator);
        defer emitter.deinit();
        try testing.expectError(error.UnsupportedOperation, emitter.emitFunction(arithmetic_function));
        try testing.expect(emitter.failed_operation != null);
    }
    ctx.arithmetic_policy = .{};
    try backend.lowerModule(arithmetic);

    const identity = try scalarModule(&ctx, "float_identity", .f64, 1, true);
    defer identity.erase();
    ctx.arithmetic_policy.environment_observable = true;
    var identity_emitter = backend.Emitter.init(testing.allocator);
    defer identity_emitter.deinit();
    const identity_function = ir.inspection.functionDefinitionByName(identity, "float_identity").?;
    try testing.expectError(error.UnsupportedOperation, identity_emitter.emitFunction(identity_function));
    try testing.expectEqual(identity_function, identity_emitter.failed_operation.?);
    ctx.arithmetic_policy = .{};

    const call_module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    defer call_module.op.erase();
    const floating_call_type = try dialects.ArithDialect.getScalarType(&ctx, .f64);
    const integer_call_type = try dialects.ArithDialect.getScalarType(&ctx, .i64);
    const call_external = try dialects.FuncDialect.FuncOp.createDeclaration(&ctx, .unknown, "unused_float_external", &.{}, &.{floating_call_type});
    try call_module.getBodyBlock().addOperation(call_external.op);
    const call_function = try dialects.FuncDialect.FuncOp.create(&ctx, .unknown, "unused_float_call", &.{}, &.{integer_call_type});
    try call_module.getBodyBlock().addOperation(call_function.op);
    const dead_call = try dialects.FuncDialect.CallOp.create(&ctx, .unknown, "unused_float_external", &.{}, &.{floating_call_type});
    try call_function.getEntryBlock().addOperation(dead_call.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(&ctx, .unknown, integer_call_type, 0);
    try call_function.getEntryBlock().addOperation(zero.op);
    const call_ret = try dialects.FuncDialect.ReturnOp.create(&ctx, .unknown, &.{zero.getResult()});
    try call_function.getEntryBlock().addOperation(call_ret.op);
    ctx.arithmetic_policy.environment_observable = true;
    var call_emitter = backend.Emitter.init(testing.allocator);
    defer call_emitter.deinit();
    try testing.expectError(error.UnsupportedOperation, call_emitter.emitFunction(call_function.op));
    try testing.expectEqual(dead_call.op, call_emitter.failed_operation.?);
    ctx.arithmetic_policy = .{};

    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(&ctx, .f64);
    const boolean = try dialects.ArithDialect.getScalarType(&ctx, .bool);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(&ctx, loc, "wrong_float_predicate", &.{ floating, floating }, &.{boolean});
    try module.getBodyBlock().addOperation(function.op);
    const comparison = try dialects.ArithDialect.CmpOp.create(&ctx, loc, .slt, function.getArgument(0), function.getArgument(1));
    try function.getEntryBlock().addOperation(comparison.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(&ctx, loc, &.{comparison.getResult()});
    try function.getEntryBlock().addOperation(ret.op);
    var predicate_emitter = backend.Emitter.init(testing.allocator);
    defer predicate_emitter.deinit();
    try testing.expectError(error.UnsupportedOperation, predicate_emitter.emitFunction(function.op));
    try testing.expectEqual(comparison.op, predicate_emitter.failed_operation.?);
}

test "aarch64 native execution retains Apple scalar code after its context ends" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    const Entry = *const fn () callconv(.c) i64;
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = blk: {
        var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
        defer ctx.deinit(testing.allocator);
        try dialects.registerAllDialects(&ctx);
        const module = try scalarModule(&ctx, "survivor", .i64, 0, true);
        defer module.erase();
        break :blk try runtime.compile(module);
    };
    const entry = try runtime.getFunction(handle, "survivor", Entry);
    try testing.expectEqual(@as(i64, 42), entry());
    try runtime.release(handle);
    try testing.expectError(error.InvalidModuleHandle, runtime.functionAddress(handle, "survivor"));
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}

test "aarch64 native execution keeps Apple code callable as serialized loads refuse" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const fixture = @import("../execution/fixture/root.zig");
    const dialects = @import("../../dialects/root.zig");
    const testing = std.testing;
    const Runtime = execution.Runtime(Target);
    const Entry = *const fn () callconv(.c) i64;

    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try fixture.constantModule(&ctx, "kept", 42);
    defer module.erase();

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var limits: execution.Limits = .testing;
    limits.live_modules = 1;
    var runtime = try Runtime.initWithExecutablePolicy(failing.allocator(), limits, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    const kept = try runtime.getFunction(handle, "kept", Entry);
    try testing.expectEqual(@as(i64, 42), kept());
    const mapped = runtime.mapped_bytes;
    const slots = runtime.modules.items.len;
    const generations = runtime.modules.items[handle.index].generation;

    const code = [_]u8{ 0xc0, 0x03, 0x5f, 0xd6 };
    var plausible = try artifact.machineCodeArtifact(
        testing.allocator,
        .{ .architecture = .aarch64, .triple = "aarch64-apple-macos" },
        Target.abi,
        "plausible",
        fixture.nullary_integer,
        &code,
        &.{},
        &.{},
    );
    defer plausible.deinit();
    var malformed = try artifact.machineCodeArtifact(
        testing.allocator,
        .{ .architecture = .unknown },
        .{},
        "malformed",
        fixture.nullary_integer,
        &code,
        &.{},
        &.{},
    );
    defer malformed.deinit();

    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    try testing.expectError(error.InvalidArtifact, runtime.loadArtifact(&plausible));
    try testing.expectError(error.InvalidArtifact, runtime.loadArtifact(&malformed));
    try testing.expectEqual(allocations, failing.alloc_index);
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(@as(u32, 1), runtime.live_modules);
    try testing.expectEqual(mapped, runtime.mapped_bytes);
    try testing.expectEqual(slots, runtime.modules.items.len);
    try testing.expectEqual(generations, runtime.modules.items[handle.index].generation);
    try testing.expectEqual(@as(?execution.Refusal, null), runtime.refusal);
    try testing.expectEqual(@as(i64, 42), kept());
    try runtime.release(handle);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}
