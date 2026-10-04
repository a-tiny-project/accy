const std = @import("std");
const profile = @import("sys").capabilities.current;
const executes = profile.os == .linux and profile.arch == .x86_64 and profile.pointerWidthBits() == 64;
const x86_64 = @import("root.zig");
const choir = @import("../../root.zig");
const pretty = @import("pretty");
const execution = choir.backends.execution;
const Runtime = execution.native.Runtime;

test {
    _ = @import("registers/test.zig");
    _ = @import("stack/test.zig");
    std.testing.refAllDecls(x86_64);
}

test "loop guards preserve spilled bounds across arithmetic backedges" {
    if (!executes) return error.SkipZigTest;

    var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(std.testing.allocator);
    const module = try pressuredLoopGuard(&context);
    var runtime = try Runtime.init(std.testing.allocator, .testing);
    defer runtime.deinit();
    const loaded = try runtime.compile(module.op);
    const Execute = *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) i64;
    const execute = try runtime.getFunction(loaded, "pressured_guard", Execute);
    for ([_]i64{ -3, 0, 1, 2, 7, 31 }) |bound| {
        const terms = if (bound > 0) bound * (bound - 1) else 0;
        const actual = execute(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, bound);
        try std.testing.expectEqual(78 + bound + terms, actual);
    }
}

test "x86_64 public emission produces machine artifacts and ELF objects on every host" {
    const testing = std.testing;
    const backend = choir.backends.x86_64;
    const fixture = @import("../execution/fixture/root.zig");
    const artifacts = choir.backends.artifact;
    var context = try choir.Context.init(testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(testing.allocator);
    try choir.dialects.registerAllDialects(&context);
    const name = "cross_host_constant";
    const module = try fixture.constantModule(&context, name, 42);
    defer module.erase();
    const function = choir.ir.inspection.functionDefinitionByName(module, name).?;

    var emitter = backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(function);
    try testing.expect(emitter.getCode().len > 0);

    var machine = try backend.object.compileFunctionToArtifact(testing.allocator, function, name);
    defer machine.deinit();
    try testing.expectEqual(artifacts.ArtifactKind.machine_code, machine.metadata.kind);
    try testing.expectEqual(artifacts.Architecture.x86_64, machine.metadata.target.architecture);
    try testing.expectEqualStrings("x86_64-unknown-linux-gnu", machine.metadata.target.triple.?);
    try testing.expectEqualStrings("sysv", machine.metadata.abi.name.?);
    try testing.expect(machine.linkage.hasProvided(name));
    try testing.expectEqualSlices(u8, emitter.getCode(), machine.payload.buffers.items[0].bytes);

    var compiler = try backend.backend.Backend.init(testing.allocator, &context);
    defer compiler.deinit();
    var object = try compiler.compileModuleToObjectFile(module, name);
    defer object.deinit();
    try testing.expectEqual(artifacts.ArtifactKind.object_file, object.metadata.kind);
    try testing.expectEqual(artifacts.Architecture.x86_64, object.metadata.target.architecture);
    try testing.expectEqualStrings("sysv", object.metadata.abi.name.?);
    try testing.expectEqualStrings("elf", object.metadata.abi.object_format.?);
    try testing.expect(object.linkage.hasProvided(name));
    const bytes = object.payload.buffers.items[0].bytes;
    var reader = std.Io.Reader.fixed(bytes);
    const header = try std.elf.Header.read(&reader);
    try testing.expect(header.is_64);
    try testing.expectEqual(std.builtin.Endian.little, header.endian);
    try testing.expectEqual(std.elf.EM.X86_64, header.machine);
    try testing.expectEqual(std.elf.ET.REL, header.type);
}

test "x86_64 public execution surface follows native availability" {
    const backend = choir.backends.x86_64;
    try std.testing.expectEqual(executes, @hasDecl(backend.execution, "Target"));
    try std.testing.expectEqual(executes, @hasDecl(backend.invoke, "call"));
}

test "conditional call join preserves values on the no-call edge" {
    try std.testing.expectEqual(@as(i64, 105), try runConditionalCallJoin(1));
}

test "conditional call join preserves values across the call edge" {
    try std.testing.expectEqual(@as(i64, 104), try runConditionalCallJoin(0));
}

test "covered loop return survives nested conditional reloads" {
    if (!executes) {
        return error.SkipZigTest;
    }
    var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(std.testing.allocator);
    try choir.dialects.registerAllDialects(&context);
    const module = try choir.ir.parse.operation(&context, @embedFile("fixture/covered_return.ir"));
    try choir.ir.verifyOperation(module, .{});
    var runtime = try Runtime.init(std.testing.allocator, .testing);
    defer runtime.deinit();
    const loaded = try runtime.compile(module);
    const execute = try runtime.getFunction(loaded, "cover0", *const fn (i64, i64) callconv(.c) i64);
    try std.testing.expectEqual(@as(i64, 7), execute(1, 1));
}

fn runConditionalCallJoin(mode: i64) !i64 {
    if (!executes) {
        return error.SkipZigTest;
    }
    var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(std.testing.allocator);
    const module = try conditionalCallJoin(&context);
    var runtime = try Runtime.init(std.testing.allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("join_increment", @intFromPtr(&joinIncrement));
    const loaded = try runtime.compile(module.op);
    const Execute = *const fn (i64, i64) callconv(.c) i64;
    const execute = try runtime.getFunction(loaded, "conditional_join", Execute);
    return execute(7, mode);
}

fn joinIncrement(value: i64) callconv(.c) i64 {
    return value + 11;
}

fn conditionalCallJoin(context: *choir.Context) !choir.dialects.BuiltinDialect.ModuleOp {
    const Arith = choir.dialects.ArithDialect;
    const Func = choir.dialects.FuncDialect;
    const Scf = choir.dialects.ScfDialect;
    const loc = choir.Location.getUnknown();
    try choir.dialects.registerAllDialects(context);
    const integer = try Arith.getScalarType(context, .i64);
    const module = try choir.dialects.BuiltinDialect.ModuleOp.create(context, loc);
    const function = try Func.FuncOp.create(context, loc, "conditional_join", &.{ integer, integer }, &.{integer});
    try module.getBodyBlock().addOperation(function.op);
    const declaration = try Func.FuncOp.createDeclaration(context, loc, "join_increment", &.{integer}, &.{integer});
    try module.getBodyBlock().addOperation(declaration.op);
    const entry = function.getEntryBlock();
    const zero = try Arith.ConstantOp.createInt(context, loc, integer, 0);
    try entry.addOperation(zero.op);
    const one = try Arith.ConstantOp.createInt(context, loc, integer, 1);
    try entry.addOperation(one.op);
    const condition = try Arith.CmpOp.create(context, loc, .gt, function.getArgument(1), zero.getResult());
    try entry.addOperation(condition.op);
    var live: [12]*choir.Value = undefined;
    for (&live, 1..) |*value, number| {
        const constant = try Arith.ConstantOp.createInt(context, loc, integer, @intCast(number));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const branch = try Scf.IfOp.create(context, loc, condition.getResult(), &.{integer});
    try entry.addOperation(branch.op);
    const then_zero = try Arith.ConstantOp.createInt(context, loc, integer, 0);
    try branch.getThenBlock().addOperation(then_zero.op);
    try branch.getThenBlock().addOperation((try Scf.YieldOp.create(context, loc, &.{then_zero.getResult()})).op);
    const argument = try Arith.AddOp.create(context, loc, function.getArgument(0), one.getResult());
    try branch.getElseBlock().?.addOperation(argument.op);
    const call = try Func.CallOp.create(context, loc, "join_increment", &.{argument.getResult()}, &.{integer});
    try branch.getElseBlock().?.addOperation(call.op);
    try branch.getElseBlock().?.addOperation((try Scf.YieldOp.create(context, loc, &.{call.getResult(0).?})).op);
    const selected = try Scf.IfOp.create(context, loc, condition.getResult(), &.{integer});
    try entry.addOperation(selected.op);
    const yes = try Arith.ConstantOp.createInt(context, loc, integer, 20);
    try selected.getThenBlock().addOperation(yes.op);
    const yes_with_live = try Arith.AddOp.create(context, loc, yes.getResult(), live[11]);
    try selected.getThenBlock().addOperation(yes_with_live.op);
    try selected.getThenBlock().addOperation((try Scf.YieldOp.create(context, loc, &.{yes_with_live.getResult()})).op);
    const no_with_live = try Arith.AddOp.create(context, loc, branch.getResult(0).?, live[11]);
    try selected.getElseBlock().?.addOperation(no_with_live.op);
    try selected.getElseBlock().?.addOperation((try Scf.YieldOp.create(context, loc, &.{no_with_live.getResult()})).op);
    var result: *choir.Value = function.getArgument(0);
    const with_selected = try Arith.AddOp.create(context, loc, result, selected.getResult(0).?);
    try entry.addOperation(with_selected.op);
    result = with_selected.getResult();
    for (live[0..11]) |value| {
        const sum = try Arith.AddOp.create(context, loc, result, value);
        try entry.addOperation(sum.op);
        result = sum.getResult();
    }
    try entry.addOperation((try Func.ReturnOp.create(context, loc, &.{result})).op);
    return module;
}

fn pressuredLoopGuard(context: *choir.Context) !choir.dialects.BuiltinDialect.ModuleOp {
    const arith = choir.dialects.ArithDialect;
    const func = choir.dialects.FuncDialect;
    const scf = choir.dialects.ScfDialect;
    try choir.dialects.registerAllDialects(context);
    const location = choir.ir.Location.getUnknown();
    const integer = try arith.getScalarType(context, .i64);
    const index = try arith.getIndexType(context);
    const argument_count = 13;
    const arguments: [argument_count]choir.Type = @splat(integer);
    const module = try choir.dialects.BuiltinDialect.ModuleOp.create(context, location);
    var function = try func.FuncOp.create(context, location, "pressured_guard", &arguments, &.{integer});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var zero = try arith.ConstantOp.createInt(context, location, index, 0);
    try entry.addOperation(zero.op);
    var bound = try arith.CastOp.create(context, location, function.getArgument(argument_count - 1), index);
    try entry.addOperation(bound.op);
    var step = try arith.ConstantOp.createInt(context, location, index, 1);
    try entry.addOperation(step.op);
    var initial = try arith.ConstantOp.createInt(context, location, integer, 0);
    try entry.addOperation(initial.op);
    var loop = try scf.ForOp.create(context, location, zero.getResult(), bound.getResult(), step.getResult(), &.{initial.getResult()}, &.{integer});
    try entry.addOperation(loop.op);
    const body = loop.getBodyBlock();
    var induction = try arith.CastOp.create(context, location, body.arguments.items[0], integer);
    try body.addOperation(induction.op);
    var doubled = try arith.AddOp.create(context, location, induction.getResult(), induction.getResult());
    try body.addOperation(doubled.op);
    var next = try arith.AddOp.create(context, location, body.arguments.items[1], doubled.getResult());
    try body.addOperation(next.op);
    const yield = try scf.YieldOp.create(context, location, &.{next.getResult()});
    try body.addOperation(yield.op);
    var result = loop.op.getResult(0).?;
    for (0..argument_count) |argument| {
        var add = try arith.AddOp.create(context, location, result, function.getArgument(argument));
        try entry.addOperation(add.op);
        result = add.getResult();
    }
    const returned = try func.ReturnOp.create(context, location, &.{result});
    try entry.addOperation(returned.op);
    return module;
}

test "nested conditional calls preserve results at every merge" {
    if (!executes) {
        return error.SkipZigTest;
    }
    for (0..8) |scenario| {
        const depth = ([_]u8{ 2, 7, 31, 63 })[scenario / 2];
        const loop = scenario % 2 != 0;
        var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
        defer context.deinit(std.testing.allocator);
        const module = try nestedCalls(&context, depth, loop);
        var backend = try x86_64.backend.Backend.init(std.testing.allocator, &context);
        defer backend.deinit();
        var runtime = try Runtime.init(std.testing.allocator, .testing);
        defer runtime.deinit();
        try runtime.registerExternalSymbol("decrement", @intFromPtr(&decrement));
        var artifact = try backend.compileFunctionToArtifact(module.op, "nested");
        defer artifact.deinit();
        const loaded = try runtime.loadArtifact(&artifact);
        const Nested = *const fn (i64) callconv(.c) i64;
        const execute = try runtime.getFunction(loaded, "nested", Nested);
        for (0..@as(usize, depth) + 2) |input| {
            const value: i64 = @intCast(input);
            const expected = if (value < depth) -100 - value else 3 * value - depth - 1;
            const actual = execute(value - (if (loop) @as(i64, 2) else 0));
            if (expected == actual) continue;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var report = try pretty.diagnostic.Report.init(arena.allocator(), "Choir merge");
            defer report.deinit();
            try report.field("depth", "{d}", .{depth});
            try report.field("loop", "{}", .{loop});
            try report.field("input", "{d}", .{value});
            try report.field("expected", "{d}", .{expected});
            try report.field("actual", "{d}", .{actual});
            pretty.diagnostic.writeStderr(&report, .{});
            return error.IncorrectConditionalResult;
        }
    }
}

fn decrement(value: i64) callconv(.c) i64 {
    return value - 1;
}

test "native artifact construction preserves allocation failures" {
    if (!executes) {
        return error.SkipZigTest;
    }
    var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(std.testing.allocator);
    const module = try nestedCalls(&context, 3, false);
    const function = choir.ir.inspection.functionDefinitionByName(module.op, "nested").?;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocateArtifact,
        .{function},
    );
}

test "runtime initialization preserves allocation failures" {
    if (!executes) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initializeRuntime, .{});
}

fn initializeRuntime(allocator: std.mem.Allocator) !void {
    var runtime = try Runtime.init(allocator, .testing);
    runtime.deinit();
}

test "backend compilation reports allocation failures as out of memory" {
    if (!executes) {
        return error.SkipZigTest;
    }
    var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(std.testing.allocator);
    const module = try nestedCalls(&context, 2, false);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var backend = try x86_64.backend.Backend.init(failing.allocator(), &context);
    defer backend.deinit();
    var runtime = try Runtime.init(failing.allocator(), .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("decrement", @intFromPtr(&decrement));
    _ = try backend.lower(module.op);
    const lowered_at = failing.alloc_index;
    _ = try backend.lower(module.op);
    const lowering = failing.alloc_index - lowered_at;
    const relowered_at = failing.alloc_index;
    _ = try backend.lower(module.op);
    try std.testing.expectEqual(lowering, failing.alloc_index - relowered_at);
    for (0..256) |offset| {
        failing.fail_index = failing.alloc_index + lowering + offset;
        const handle = runtime.compile(module.op) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(offset != 0);
        return runtime.release(handle);
    }
    return error.TestExpectedCompile;
}

test "runtime reports module exhaustion apart from a compile failure" {
    if (!executes) {
        return error.SkipZigTest;
    }
    var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(std.testing.allocator);
    const module = try nestedCalls(&context, 2, false);
    const limits: execution.Limits = .{
        .live_modules = 1,
        .mapped_bytes = execution.Limits.testing.mapped_bytes,
    };
    var runtime = try Runtime.init(std.testing.allocator, limits);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("decrement", @intFromPtr(&decrement));

    const handle = try runtime.compile(module.op);
    try std.testing.expectError(error.JitRuntimeFull, runtime.compile(module.op));
    try runtime.release(handle);
    const next = try runtime.compile(module.op);
    try runtime.release(next);
}

fn allocateArtifact(allocator: std.mem.Allocator, function: *choir.Operation) !void {
    var artifact = try x86_64.object.compileFunctionToArtifact(allocator, function, "nested");
    defer artifact.deinit();
    try std.testing.expectEqual(@as(usize, 3), artifact.linkage.relocations.items.len);
}

fn nestedCalls(
    context: *choir.Context,
    depth: u8,
    loop: bool,
) !choir.dialects.BuiltinDialect.ModuleOp {
    std.debug.assert(depth > 0);
    std.debug.assert(depth <= 63);
    const Arith = choir.dialects.ArithDialect;
    const Func = choir.dialects.FuncDialect;
    const Scf = choir.dialects.ScfDialect;
    const loc = choir.Location.getUnknown();
    try choir.dialects.registerAllDialects(context);
    const integer = try Arith.getScalarType(context, .i64);
    const module = try choir.dialects.BuiltinDialect.ModuleOp.create(context, loc);
    const function = try Func.FuncOp.create(context, loc, "nested", &.{integer}, &.{integer});
    try module.getBodyBlock().addOperation(function.op);
    const declaration = try Func.FuncOp.createDeclaration(
        context,
        loc,
        "decrement",
        &.{integer},
        &.{integer},
    );
    try module.getBodyBlock().addOperation(declaration.op);
    var block = function.getEntryBlock();
    const zero = try Arith.ConstantOp.createInt(context, loc, integer, 0);
    try block.addOperation(zero.op);
    var branches: [63]Scf.IfOp = undefined;
    const initial = if (loop)
        try countedSeed(context, block, function.getArgument(0))
    else
        function.getArgument(0);
    var value = initial;
    var first: *choir.Value = undefined;
    for (0..depth) |index| {
        const call = try Func.CallOp.create(context, loc, "decrement", &.{value}, &.{integer});
        try block.addOperation(call.op);
        value = call.getResult(0).?;
        if (index == 0) first = value;
        const condition = try Arith.CmpOp.create(context, loc, .ge, value, zero.getResult());
        try block.addOperation(condition.op);
        const branch = try Scf.IfOp.create(context, loc, condition.getResult(), &.{integer});
        try block.addOperation(branch.op);
        const other = branch.getElseBlock().?;
        const failure = try Arith.ConstantOp.createInt(context, loc, integer, -100 -
            @as(i64, @intCast(index)));
        try other.addOperation(failure.op);
        try other.addOperation((try Scf.YieldOp.create(context, loc, &.{failure.getResult()})).op);
        branches[index] = branch;
        block = branch.getThenBlock();
    }
    const sum = try Arith.AddOp.create(context, loc, value, first);
    try block.addOperation(sum.op);
    const total = try Arith.AddOp.create(context, loc, sum.getResult(), initial);
    try block.addOperation(total.op);
    value = total.getResult();
    var remaining = depth;
    while (remaining > 0) {
        const branch = branches[remaining - 1];
        const yield = try Scf.YieldOp.create(context, loc, &.{value});
        try branch.getThenBlock().addOperation(yield.op);
        value = branch.getResult(0).?;
        remaining -= 1;
    }
    const ret = try Func.ReturnOp.create(context, loc, &.{value});
    try function.getEntryBlock().addOperation(ret.op);
    return module;
}

fn countedSeed(context: *choir.Context, block: *choir.Block, seed: *choir.Value) !*choir.Value {
    const Arith = choir.dialects.ArithDialect;
    const Scf = choir.dialects.ScfDialect;
    const loc = choir.Location.getUnknown();
    const integer = try Arith.getScalarType(context, .i64);
    const lower = try Arith.ConstantOp.createInt(context, loc, integer, 0);
    try block.addOperation(lower.op);
    const upper = try Arith.ConstantOp.createInt(context, loc, integer, 2);
    try block.addOperation(upper.op);
    const step = try Arith.ConstantOp.createInt(context, loc, integer, 1);
    try block.addOperation(step.op);
    const loop = try Scf.ForOp.create(
        context,
        loc,
        lower.getResult(),
        upper.getResult(),
        step.getResult(),
        &.{seed},
        &.{integer},
    );
    try block.addOperation(loop.op);
    const body = loop.getBodyBlock();
    const next = try Arith.AddOp.create(context, loc, loop.getIterArgs()[0], step.getResult());
    try body.addOperation(next.op);
    const yield = try Scf.YieldOp.create(context, loc, &.{next.getResult()});
    try body.addOperation(yield.op);
    return loop.op.getResult(0).?;
}

const Pair = extern struct { first: i64, second: i64 };
const Mixed = extern struct { scale: f64, count: i64 };
const Flagged = extern struct { value: i64, below: bool align(8) };
const Record = extern struct {
    sum: i64,
    scale: f64,
    narrow: i32 align(8),
    below: bool align(8),
};

test "x86_64 products return through the SysV struct convention" {
    if (!executes) {
        return error.SkipZigTest;
    }
    var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(std.testing.allocator);
    var products = try Products.init(&context);
    try products.generated();
    var runtime = try Runtime.init(std.testing.allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(products.module.op);

    const Binary = *const fn (i64, i64) callconv(.c) Pair;
    const Reduce = *const fn (i64, i64) callconv(.c) i64;
    const Mix = *const fn (i64, f64) callconv(.c) Mixed;
    const Flag = *const fn (i64, i64) callconv(.c) Flagged;
    const Recorded = *const fn (i64, f64, i32, i64) callconv(.c) Record;
    const pair = try runtime.getFunction(compiled, "pair", Binary);
    const swap = try runtime.getFunction(compiled, "swap", Binary);
    const fold = try runtime.getFunction(compiled, "fold", Reduce);
    const mixed = try runtime.getFunction(compiled, "mixed", Mix);
    const flagged = try runtime.getFunction(compiled, "flagged", Flag);
    const record = try runtime.getFunction(compiled, "record", Recorded);
    const relay = try runtime.getFunction(compiled, "relay", Recorded);
    const inputs = [_]i64{ std.math.minInt(i64), -7, 0, 3, std.math.maxInt(i64) };
    for (inputs) |a| {
        for (inputs) |b| {
            try std.testing.expectEqual(Pair{ .first = a -% b, .second = a +% b }, pair(a, b));
            try std.testing.expectEqual(Pair{ .first = b, .second = a }, swap(a, b));
            try std.testing.expectEqual((a +% b) *% 3 +% (a -% b) +% a, fold(a, b));
            try std.testing.expectEqual(Flagged{ .value = b, .below = a < b }, flagged(a, b));
            const narrow: i32 = @truncate(a);
            const expected = Record{
                .sum = a +% b,
                .scale = 0.5,
                .narrow = narrow,
                .below = a < b,
            };
            try std.testing.expectEqual(expected, record(a, 0.5, narrow, b));
            try std.testing.expectEqual(expected, relay(a, 0.5, narrow, b));
        }
        try std.testing.expectEqual(Mixed{ .scale = 2.25, .count = a }, mixed(a, 1.5));
    }
}

const DirtyFlagged = extern struct { narrow: u64, bits: u64 };
const DirtyRecord = extern struct { narrow: u64, bits: u64, product: i64 };

fn nativeFlagged(a: i64, b: i64) callconv(.c) DirtyFlagged {
    return .{ .narrow = dirtyNarrow(a -% b), .bits = 0xa5a5_0000 | @as(u64, @intFromBool(a < b)) };
}

fn nativeRecord(a: i64, b: i64) callconv(.c) DirtyRecord {
    const bits = 0x5a00 | @as(u64, @intFromBool(b < a));
    return .{ .narrow = dirtyNarrow(a +% b), .bits = bits, .product = a *% b };
}

fn dirtyNarrow(value: i64) u64 {
    const low: u32 = @truncate(@as(u64, @bitCast(value)));
    return 0xdead_beef_0000_0000 | @as(u64, low);
}

test "x86_64 product calls canonicalize narrow results from native callees" {
    if (!executes) {
        return error.SkipZigTest;
    }
    var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(std.testing.allocator);
    var products = try Products.init(&context);
    try products.observer();
    var runtime = try Runtime.init(std.testing.allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("native_flagged", @intFromPtr(&nativeFlagged));
    try runtime.registerExternalSymbol("native_record", @intFromPtr(&nativeRecord));
    const compiled = try runtime.compile(products.module.op);

    const Observe = *const fn (i64, i64) callconv(.c) Pair;
    const observe = try runtime.getFunction(compiled, "observe", Observe);
    const inputs = [_]i64{ std.math.minInt(i64), -7, 0, 3, 1 << 40, std.math.maxInt(i64) };
    for (inputs) |a| {
        for (inputs) |b| {
            const difference: i32 = @truncate(a -% b);
            const sum: i32 = @truncate(a +% b);
            const expected = Pair{
                .first = @as(i64, difference) +% sum +% (a *% b),
                .second = @as(i64, @intFromBool(a < b)) + 2 * @as(i64, @intFromBool(b < a)),
            };
            try std.testing.expectEqual(expected, observe(a, b));
        }
    }
}

const Products = struct {
    context: *choir.Context,
    module: choir.dialects.BuiltinDialect.ModuleOp,
    loc: choir.Location,
    int: choir.ir.Type,
    narrow: choir.ir.Type,
    real: choir.ir.Type,
    flag: choir.ir.Type,

    const Arith: type = choir.dialects.ArithDialect;
    const Func: type = choir.dialects.FuncDialect;

    fn init(context: *choir.Context) !Products {
        try choir.dialects.registerAllDialects(context);
        const loc = choir.Location.getUnknown();
        return .{
            .context = context,
            .module = try choir.dialects.BuiltinDialect.ModuleOp.create(context, loc),
            .loc = loc,
            .int = try Arith.getScalarType(context, .i64),
            .narrow = try Arith.getScalarType(context, .i32),
            .real = try Arith.getScalarType(context, .f64),
            .flag = try Arith.getScalarType(context, .bool),
        };
    }

    fn generated(self: *Products) !void {
        const int = self.int;
        const pair = try self.function("pair", &.{ int, int }, &.{ int, int });
        const pair_block = pair.getEntryBlock();
        const lhs = pair.getArgument(0);
        const rhs = pair.getArgument(1);
        const difference = try self.binary(pair_block, Arith.SubOp, lhs, rhs);
        const sum = try self.binary(pair_block, Arith.AddOp, lhs, rhs);
        try self.finish(pair_block, &.{ difference, sum });

        const swap = try self.function("swap", &.{ int, int }, &.{ int, int });
        try self.finish(swap.getEntryBlock(), &.{ swap.getArgument(1), swap.getArgument(0) });

        const mixed = try self.function("mixed", &.{ int, self.real }, &.{ self.real, int });
        const mixed_block = mixed.getEntryBlock();
        const factor = mixed.getArgument(1);
        const scale = try self.binary(mixed_block, Arith.MulOp, factor, factor);
        try self.finish(mixed_block, &.{ scale, mixed.getArgument(0) });

        const flagged = try self.function("flagged", &.{ int, int }, &.{ int, self.flag });
        const flagged_block = flagged.getEntryBlock();
        const below = try self.less(flagged_block, flagged.getArgument(0), flagged.getArgument(1));
        try self.finish(flagged_block, &.{ flagged.getArgument(1), below });

        try self.fold();
        try self.records();
    }

    fn fold(self: *Products) !void {
        const int = self.int;
        const folded = try self.function("fold", &.{ int, int }, &.{int});
        const block = folded.getEntryBlock();
        const a = folded.getArgument(0);
        const first = try self.call(block, "pair", &.{ a, folded.getArgument(1) }, &.{ int, int });
        const operands = [_]*choir.Value{ first.getResult(0).?, first.getResult(1).? };
        const second = try self.call(block, "swap", &operands, &.{ int, int });
        const three = try self.constant(block, 3);
        const scaled = try self.binary(block, Arith.MulOp, second.getResult(0).?, three);
        const partial = try self.binary(block, Arith.AddOp, scaled, second.getResult(1).?);
        const total = try self.binary(block, Arith.AddOp, partial, a);
        try self.finish(block, &.{total});
    }

    fn records(self: *Products) !void {
        const inputs = [_]choir.ir.Type{ self.int, self.real, self.narrow, self.int };
        const results = [_]choir.ir.Type{ self.int, self.real, self.narrow, self.flag };
        const record = try self.function("record", &inputs, &results);
        const block = record.getEntryBlock();
        const a = record.getArgument(0);
        const b = record.getArgument(3);
        const sum = try self.binary(block, Arith.AddOp, a, b);
        const below = try self.less(block, a, b);
        try self.finish(block, &.{ sum, record.getArgument(1), record.getArgument(2), below });

        const relay = try self.function("relay", &inputs, &results);
        const relay_block = relay.getEntryBlock();
        var arguments: [inputs.len]*choir.Value = undefined;
        for (&arguments, 0..) |*argument, index| argument.* = relay.getArgument(index);
        const forwarded = try self.call(relay_block, "record", &arguments, &results);
        var forwarded_results: [results.len]*choir.Value = undefined;
        for (&forwarded_results, 0..) |*result, index| result.* = forwarded.getResult(index).?;
        try self.finish(relay_block, &forwarded_results);
    }

    fn observer(self: *Products) !void {
        const int = self.int;
        const flagged_types = [_]choir.ir.Type{ self.narrow, self.flag };
        const record_types = [_]choir.ir.Type{ self.narrow, self.flag, int };
        try self.declaration("native_flagged", &.{ int, int }, &flagged_types);
        try self.declaration("native_record", &.{ int, int }, &record_types);
        const observe = try self.function("observe", &.{ int, int }, &.{ int, int });
        const block = observe.getEntryBlock();
        const arguments = [_]*choir.Value{ observe.getArgument(0), observe.getArgument(1) };
        const flagged = try self.call(block, "native_flagged", &arguments, &flagged_types);
        const record = try self.call(block, "native_record", &arguments, &record_types);
        const difference = try self.widen(block, flagged.getResult(0).?);
        const sum = try self.widen(block, record.getResult(0).?);
        const below = try self.widen(block, flagged.getResult(1).?);
        const above = try self.widen(block, record.getResult(1).?);
        const narrow_total = try self.binary(block, Arith.AddOp, difference, sum);
        const first = try self.binary(block, Arith.AddOp, narrow_total, record.getResult(2).?);
        const doubled = try self.binary(block, Arith.AddOp, above, above);
        const second = try self.binary(block, Arith.AddOp, below, doubled);
        try self.finish(block, &.{ first, second });
    }

    fn counterexample(self: *Products) !void {
        const int = self.int;
        const triple_types = [_]choir.ir.Type{ int, int, self.flag };
        const triple = try self.function("diff_triple", &.{ int, int }, &triple_types);
        const triple_block = triple.getEntryBlock();
        const triple_lhs = triple.getArgument(0);
        const triple_rhs = triple.getArgument(1);
        const triple_sum = try self.binary(triple_block, Arith.AddOp, triple_lhs, triple_rhs);
        const triple_below = try self.less(triple_block, triple_lhs, triple_rhs);
        try self.finish(triple_block, &.{ triple_rhs, triple_sum, triple_below });

        const helper = try self.function("diff_helper", &.{ int, int, int, int }, &.{int});
        const helper_block = helper.getEntryBlock();
        var inputs: [4]*choir.Value = undefined;
        for (&inputs, 0..) |*input, index| input.* = helper.getArgument(index);
        const helper_lhs = try self.binary(helper_block, Arith.AddOp, inputs[0], inputs[1]);
        const helper_rhs = try self.binary(helper_block, Arith.XorOp, inputs[2], inputs[3]);
        const helper_three = try self.constant(helper_block, 3);
        const helper_scaled = try self.binary(helper_block, Arith.MulOp, helper_lhs, helper_three);
        const helper_result = try self.binary(helper_block, Arith.SubOp, helper_scaled, helper_rhs);
        try self.finish(helper_block, &.{helper_result});

        const main = try self.function("diff_fn", &.{int}, &.{int});
        const block = main.getEntryBlock();
        const arg = main.getArgument(0);
        const seed = try self.constant(block, -32768);
        const true_flag = try Arith.ConstantOp.createBool(self.context, self.loc, true);
        try block.addOperation(true_flag.op);
        const false_flag = try Arith.ConstantOp.createBool(self.context, self.loc, false);
        try block.addOperation(false_flag.op);
        const triple_call = try self.call(block, "diff_triple", &.{ arg, arg }, &triple_types);
        const t0 = triple_call.getResult(0).?;
        const below = triple_call.getResult(2).?;
        const c0 = try self.constant(block, 0);
        _ = try self.binary(block, Arith.UshrOp, t0, c0);
        const k0 = try self.constant(block, 0);
        _ = try self.constant(block, -164);
        const w01 = try self.loop(block, 2, t0);
        const w23 = try self.loop(block, 2, w01[0]);
        const sel = try self.select(block, below, w23[0], arg);
        const b1 = try self.binary(block, Arith.AndOp, k0, w23[1]);
        const inverted = try self.unary(block, Arith.NotOp, w01[1]);
        const m1 = try self.binary(block, Arith.MaxOp, w23[1], t0);
        const w45 = try self.loop(block, 4, w01[0]);
        _ = try self.select(block, below, b1, w01[0]);
        _ = try self.call(block, "diff_helper", &.{ inverted, w45[1], b1, seed }, &.{int});
        _ = try self.unary(block, Arith.NegOp, m1);
        _ = try self.binary(block, Arith.MinOp, k0, sel);
        const w67 = try self.loop(block, 7, w01[0]);
        try self.finish(block, &.{w67[1]});
    }

    fn constant(self: *Products, block: *choir.Block, value: i64) !*choir.Value {
        const created = try Arith.ConstantOp.createInt(self.context, self.loc, self.int, value);
        try block.addOperation(created.op);
        return created.getResult();
    }

    fn unary(
        self: *Products,
        block: *choir.Block,
        comptime Op: type,
        operand: *choir.Value,
    ) !*choir.Value {
        const created = try Op.create(self.context, self.loc, operand);
        try block.addOperation(created.op);
        return created.getResult();
    }

    fn select(
        self: *Products,
        block: *choir.Block,
        condition: *choir.Value,
        chosen: *choir.Value,
        other: *choir.Value,
    ) !*choir.Value {
        const created = try Arith.SelectOp.create(self.context, self.loc, condition, chosen, other);
        try block.addOperation(created.op);
        return created.getResult();
    }

    fn loop(
        self: *Products,
        block: *choir.Block,
        count: i64,
        initial: *choir.Value,
    ) ![2]*choir.Value {
        const Scf = choir.dialects.ScfDialect;
        const start = try self.constant(block, count);
        const types = [_]choir.ir.Type{ self.int, self.int };
        const inits = [_]*choir.Value{ start, initial };
        const loop_op = try Scf.WhileOp.create(self.context, self.loc, &inits, &types);
        try block.addOperation(loop_op.op);
        const before = loop_op.getBeforeBlock();
        const zero = try self.constant(before, 0);
        const counter = before.arguments.items[0];
        const keep = try Arith.CmpOp.create(self.context, self.loc, .gt, counter, zero);
        try before.addOperation(keep.op);
        const carried = [_]*choir.Value{ counter, before.arguments.items[1] };
        const kept = keep.getResult();
        const condition = try Scf.ConditionOp.create(self.context, self.loc, kept, &carried);
        try before.addOperation(condition.op);
        const after = loop_op.getAfterBlock();
        const one = try self.constant(after, 1);
        const remaining = after.arguments.items[0];
        const accumulated = after.arguments.items[1];
        const next_count = try self.binary(after, Arith.SubOp, remaining, one);
        const next_acc = try self.binary(after, Arith.AddOp, accumulated, remaining);
        const yield = try Scf.YieldOp.create(self.context, self.loc, &.{ next_count, next_acc });
        try after.addOperation(yield.op);
        return .{ loop_op.op.getResult(0).?, loop_op.op.getResult(1).? };
    }

    fn function(
        self: *Products,
        name: []const u8,
        inputs: []const choir.ir.Type,
        results: []const choir.ir.Type,
    ) !Func.FuncOp {
        const created = try Func.FuncOp.create(self.context, self.loc, name, inputs, results);
        try self.module.getBodyBlock().addOperation(created.op);
        return created;
    }

    fn declaration(
        self: *Products,
        name: []const u8,
        inputs: []const choir.ir.Type,
        results: []const choir.ir.Type,
    ) !void {
        const declared =
            try Func.FuncOp.createDeclaration(self.context, self.loc, name, inputs, results);
        try self.module.getBodyBlock().addOperation(declared.op);
    }

    fn call(
        self: *Products,
        block: *choir.Block,
        callee: []const u8,
        arguments: []const *choir.Value,
        results: []const choir.ir.Type,
    ) !Func.CallOp {
        const created = try Func.CallOp.create(self.context, self.loc, callee, arguments, results);
        try block.addOperation(created.op);
        return created;
    }

    fn binary(
        self: *Products,
        block: *choir.Block,
        comptime Op: type,
        lhs: *choir.Value,
        rhs: *choir.Value,
    ) !*choir.Value {
        const created = try Op.create(self.context, self.loc, lhs, rhs);
        try block.addOperation(created.op);
        return created.getResult();
    }

    fn less(
        self: *Products,
        block: *choir.Block,
        lhs: *choir.Value,
        rhs: *choir.Value,
    ) !*choir.Value {
        const created = try Arith.CmpOp.create(self.context, self.loc, .lt, lhs, rhs);
        try block.addOperation(created.op);
        return created.getResult();
    }

    fn widen(self: *Products, block: *choir.Block, value: *choir.Value) !*choir.Value {
        const created = try Arith.CastOp.create(self.context, self.loc, value, self.int);
        try block.addOperation(created.op);
        return created.getResult();
    }

    fn finish(self: *Products, block: *choir.Block, values: []const *choir.Value) !void {
        const ret = try Func.ReturnOp.create(self.context, self.loc, values);
        try block.addOperation(ret.op);
    }
};

test "x86_64 product call counterexample keeps loop results" {
    if (!executes) {
        return error.SkipZigTest;
    }
    var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(std.testing.allocator);
    var products = try Products.init(&context);
    try products.counterexample();
    var runtime = try Runtime.init(std.testing.allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(products.module.op);
    const Unary = *const fn (i64) callconv(.c) i64;
    const function = try runtime.getFunction(compiled, "diff_fn", Unary);
    try std.testing.expectEqual(@as(i64, 28), function(-32767));
}

test "x86_64 native paths carry data symbols" {
    if (!executes) {
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;
    const BackendError = choir.backends.interface.BackendError;
    const artifact = choir.backends.artifact;
    var context = try choir.Context.init(allocator, choir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try relocatedFunctions(&context);
    const literal = choir.ir.inspection.functionDefinitionByName(module.op, "literal").?;
    const Address = *const fn () callconv(.c) i64;

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol("external", @intFromPtr(&externalSeven));
    const compiled = try runtime.compile(module.op);
    const compiled_address = (try runtime.getFunction(compiled, "literal", Address))();
    try std.testing.expectEqualStrings("literal bytes", literalBytes(compiled_address));
    const caller = try runtime.getFunction(compiled, "caller", Address);
    try std.testing.expectEqual(@as(i64, 7), caller());

    var carried = try x86_64.object.compileFunctionToArtifact(allocator, literal, "literal");
    defer carried.deinit();
    try std.testing.expectEqual(@as(usize, 2), carried.payload.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 2), carried.linkage.provided_symbols.items.len);
    const carried_relocations = carried.linkage.relocations.items;
    try std.testing.expectEqual(@as(usize, 1), carried_relocations.len);
    try std.testing.expectEqual(artifact.RelocationKind.absolute, carried_relocations[0].kind);
    const serialized = try artifact.serialization.serialize(allocator, &carried);
    defer allocator.free(serialized);
    var restored = try artifact.serialization.deserialize(allocator, serialized);
    defer restored.deinit();
    const loaded = try runtime.loadArtifact(&restored);
    const loaded_address = (try runtime.getFunction(loaded, "literal", Address))();
    try std.testing.expect(loaded_address != compiled_address);
    try std.testing.expectEqualStrings("literal bytes", literalBytes(loaded_address));

    var object = try x86_64.object.compileFunctionToObjectFile(allocator, literal, "literal");
    defer object.deinit();
    const relocations = object.linkage.relocations.items;
    try std.testing.expectEqual(@as(usize, 1), relocations.len);
    try std.testing.expectEqual(artifact.RelocationKind.absolute, relocations[0].kind);
    try std.testing.expectEqualStrings("choir_literal", relocations[0].symbol);

    var backend = try x86_64.backend.Backend.init(allocator, &context);
    defer backend.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try backend.emit(module.op, .{ .entry = "plain" }, &out.writer);
    try std.testing.expect(out.written().len != 0);
    for ([_][]const u8{ "literal", "caller" }) |entry| {
        const refused = backend.emit(module.op, .{ .entry = entry }, &out.writer);
        try std.testing.expectError(BackendError.UnsupportedOperation, refused);
    }
}

fn externalSeven() callconv(.c) i64 {
    return 7;
}

fn literalBytes(address: i64) []const u8 {
    const bytes: [*]const u8 = @ptrFromInt(@as(usize, @intCast(address)));
    return bytes[0.."literal bytes".len];
}

fn relocatedFunctions(context: *choir.Context) !choir.dialects.BuiltinDialect.ModuleOp {
    const Arith = choir.dialects.ArithDialect;
    const Func = choir.dialects.FuncDialect;
    const names = choir.backends.machine_code.data_symbol_attr_names;
    const loc = choir.Location.getUnknown();
    try choir.dialects.registerAllDialects(context);
    const int = try Arith.getScalarType(context, .i64);
    const module = try choir.dialects.BuiltinDialect.ModuleOp.create(context, loc);
    const body = module.getBodyBlock();
    const external = try Func.FuncOp.createDeclaration(context, loc, "external", &.{}, &.{int});
    try body.addOperation(external.op);
    for ([_][]const u8{ "plain", "literal", "caller" }) |name| {
        const function = try Func.FuncOp.create(context, loc, name, &.{}, &.{int});
        try body.addOperation(function.op);
        const block = function.getEntryBlock();
        const result = if (std.mem.eql(u8, name, "caller")) from_call: {
            const call = try Func.CallOp.create(context, loc, "external", &.{}, &.{int});
            try block.addOperation(call.op);
            break :from_call call.getResult(0).?;
        } else from_constant: {
            const constant = try Arith.ConstantOp.createInt(context, loc, int, 7);
            if (std.mem.eql(u8, name, "literal")) {
                try constant.op.setAttr(names.name, try context.getStringAttr("choir_literal"));
                try constant.op.setAttr(names.bytes, try context.getStringAttr("literal bytes"));
            }
            try block.addOperation(constant.op);
            break :from_constant constant.getResult();
        };
        const ret = try Func.ReturnOp.create(context, loc, &.{result});
        try block.addOperation(ret.op);
    }
    return module;
}

const CallValue = execution.Value;

const Selection = struct {
    name: []const u8,
    args: []const CallValue,
    selected: []const usize,
};

const echo_args = [_]CallValue{
    .{ .i8 = std.math.minInt(i8) },
    .{ .i16 = std.math.minInt(i16) },
    .{ .i32 = std.math.minInt(i32) },
    .{ .i64 = std.math.minInt(i64) },
    .{ .u8 = std.math.maxInt(u8) },
    .{ .u16 = std.math.maxInt(u16) },
    .{ .u32 = std.math.maxInt(u32) },
    .{ .u64 = std.math.maxInt(u64) },
    .{ .index = 1 << 63 },
    .{ .bool = true },
    .{ .f32 = -0.0 },
    .{ .f64 = std.math.nan(f64) },
    .{ .memref = 0xdead_b000 },
};

const echo_selections = blk: {
    var selections: [echo_args.len]Selection = undefined;
    for (&selections, &echo_args) |*selection, *arg| {
        const name = "echo_" ++ @tagName(arg.*);
        selection.* = .{ .name = name, .args = arg[0..1], .selected = &.{0} };
    }
    break :blk selections;
};

const reverse_args = [_]CallValue{
    .{ .i8 = -1 },
    .{ .f32 = 0.5 },
    .{ .u16 = std.math.maxInt(u16) },
    .{ .bool = true },
    .{ .f64 = 1e300 },
};

const spill_args = [_]CallValue{
    .{ .i64 = 1 },    .{ .i64 = -2 },  .{ .i64 = 3 },     .{ .i64 = -4 },  .{ .i64 = 5 },
    .{ .i64 = -6 },   .{ .i64 = 7 },   .{ .f64 = 0.5 },   .{ .f64 = 1.5 }, .{ .f64 = 2.5 },
    .{ .f64 = 3.5 },  .{ .f64 = 4.5 }, .{ .f64 = 5.5 },   .{ .f64 = 6.5 }, .{ .f64 = 7.5 },
    .{ .f64 = -8.5 }, .{ .u8 = 200 },  .{ .f32 = -3.25 },
};

const boundary_selections = echo_selections ++ [_]Selection{
    .{
        .name = "swap_ii",
        .args = &.{ .{ .i64 = -3 }, .{ .i64 = 1 << 40 } },
        .selected = &.{ 1, 0 },
    },
    .{
        .name = "swap_if",
        .args = &.{ .{ .i64 = -3 }, .{ .f64 = 0.25 } },
        .selected = &.{ 1, 0 },
    },
    .{
        .name = "swap_fi",
        .args = &.{ .{ .f32 = 1.5 }, .{ .u16 = 9 } },
        .selected = &.{ 1, 0 },
    },
    .{
        .name = "swap_ff",
        .args = &.{ .{ .f64 = -0.0 }, .{ .f32 = 2.5 } },
        .selected = &.{ 1, 0 },
    },
    .{ .name = "reverse", .args = &reverse_args, .selected = &.{ 4, 3, 2, 1, 0 } },
    .{ .name = "spill", .args = &spill_args, .selected = &.{ 6, 15, 16, 17 } },
};

test "x86_64 checked calls carry boundary values through every load path" {
    if (!executes) {
        return error.SkipZigTest;
    }
    var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(std.testing.allocator);
    var boundary = try Boundary.init(&context);
    for (boundary_selections) |selection| try boundary.select(selection);
    try boundary.sum("sum_i8", .i8);
    try boundary.sum("sum_u16", .u16);
    try boundary.splat("splat_f32", .f32, 4);
    try boundary.splat("splat_u64", .u64, 2);

    var runtime = try Runtime.init(std.testing.allocator, .testing);
    defer runtime.deinit();
    const compiled = try LoadedBoundary.compile(&runtime, &boundary);
    const carried = try LoadedBoundary.carry(&runtime, &boundary);
    for ([_]*const LoadedBoundary{ &compiled, &carried }) |loaded| {
        try expectSelections(&runtime, loaded);
        try expectComputed(&runtime, loaded);
        try expectRefusals(&runtime, loaded);
    }
    for (boundary.names[0..boundary.count]) |name| {
        const recorded = try runtime.functionSignature(compiled.of(name), name);
        const restored = try runtime.functionSignature(carried.of(name), name);
        try std.testing.expect(recorded.eql(&restored));
    }
}

fn expectSelections(runtime: *const Runtime, loaded: *const LoadedBoundary) !void {
    for (boundary_selections) |selection| {
        var results: [Boundary.max_values]CallValue = undefined;
        const count = selection.selected.len;
        const handle = loaded.of(selection.name);
        try runtime.call(handle, selection.name, selection.args, results[0..count]);
        for (selection.selected, results[0..count]) |index, result| {
            try expectSameBits(selection.args[index], result);
        }
    }
}

fn expectComputed(runtime: *const Runtime, loaded: *const LoadedBoundary) !void {
    const wrapped = try callOne(runtime, loaded, "sum_i8", &.{ .{ .i8 = 127 }, .{ .i8 = 1 } });
    try expectSameBits(.{ .i8 = std.math.minInt(i8) }, wrapped);
    const carried = try callOne(runtime, loaded, "sum_u16", &.{ .{ .u16 = 65535 }, .{ .u16 = 2 } });
    try expectSameBits(.{ .u16 = 1 }, carried);

    const lane: f32 = -1.25;
    const floats = try callOne(runtime, loaded, "splat_f32", &.{.{ .f32 = lane }});
    try expectSameBits(splatted(.f32, 4, @as(u32, @bitCast(lane))), floats);
    const word: u64 = (1 << 63) | 5;
    const words = try callOne(runtime, loaded, "splat_u64", &.{.{ .u64 = word }});
    try expectSameBits(splatted(.u64, 2, word), words);
}

fn expectRefusals(runtime: *const Runtime, loaded: *const LoadedBoundary) !void {
    const mismatch = error.SignatureMismatch;
    const handle = loaded.of("echo_i8");
    var slots: [2]CallValue = undefined;
    const one = [_]CallValue{.{ .i8 = 1 }};
    try std.testing.expectError(mismatch, callEcho(runtime, handle, &.{.{ .u8 = 1 }}, slots[0..1]));
    try std.testing.expectError(mismatch, callEcho(runtime, handle, &.{}, slots[0..1]));
    try std.testing.expectError(mismatch, callEcho(runtime, handle, &one, slots[0..0]));
    try std.testing.expectError(mismatch, callEcho(runtime, handle, &one, slots[0..2]));
    try callEcho(runtime, handle, &one, slots[0..1]);
    try expectSameBits(one[0], slots[0]);
    const absent = runtime.call(handle, "absent", &.{}, &.{});
    try std.testing.expectError(error.FunctionNotFound, absent);

    const Echo = *const fn (i8) callconv(.c) i8;
    const echo = try runtime.getFunction(handle, "echo_i8", Echo);
    try std.testing.expectEqual(@as(i8, std.math.minInt(i8)), echo(std.math.minInt(i8)));
    const Unsigned = *const fn (u8) callconv(.c) u8;
    try std.testing.expectError(mismatch, runtime.getFunction(handle, "echo_i8", Unsigned));
    const Wider = *const fn (i8) callconv(.c) i16;
    try std.testing.expectError(mismatch, runtime.getFunction(handle, "echo_i8", Wider));

    const swap_handle = loaded.of("swap_if");
    const Swapped = extern struct { first: f64, second: i64 };
    const Swap = *const fn (i64, f64) callconv(.c) Swapped;
    const swap = try runtime.getFunction(swap_handle, "swap_if", Swap);
    try std.testing.expectEqual(Swapped{ .first = 0.25, .second = -3 }, swap(-3, 0.25));
    const Paired = *const fn (i64, f64) callconv(.c) Pair;
    try std.testing.expectError(mismatch, runtime.getFunction(swap_handle, "swap_if", Paired));
}

fn callEcho(
    runtime: *const Runtime,
    handle: execution.Handle,
    args: []const CallValue,
    results: []CallValue,
) !void {
    return runtime.call(handle, "echo_i8", args, results);
}

fn callOne(
    runtime: *const Runtime,
    loaded: *const LoadedBoundary,
    name: []const u8,
    args: []const CallValue,
) !CallValue {
    var result: [1]CallValue = undefined;
    try runtime.call(loaded.of(name), name, args, &result);
    return result[0];
}

fn splatted(element: choir.backends.artifact.ScalarType, lanes: u8, word: u64) CallValue {
    var bits: [choir.backends.artifact.VectorType.max_lanes]u64 = @splat(0);
    @memset(bits[0..lanes], word);
    return .{ .vector = .{ .element = element, .lanes = lanes, .bits = bits } };
}

fn expectSameBits(expected: CallValue, actual: CallValue) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .bool => |flag| try std.testing.expectEqual(flag, actual.bool),
        .vector => |vector| {
            try std.testing.expectEqual(vector.element, actual.vector.element);
            try std.testing.expectEqual(vector.lanes, actual.vector.lanes);
            try std.testing.expectEqualSlices(u64, &vector.bits, &actual.vector.bits);
        },
        inline else => |payload, tag| {
            const Bits = @Int(.unsigned, @bitSizeOf(@TypeOf(payload)));
            const found = @field(actual, @tagName(tag));
            try std.testing.expectEqual(@as(Bits, @bitCast(payload)), @as(Bits, @bitCast(found)));
        },
    }
}

const Boundary = struct {
    context: *choir.Context,
    module: choir.dialects.BuiltinDialect.ModuleOp,
    loc: choir.Location,
    names: [max_functions][]const u8 = undefined,
    functions: [max_functions]*choir.Operation = undefined,
    count: usize = 0,

    const max_functions = 32;
    const max_values = 18;
    const Arith: type = choir.dialects.ArithDialect;
    const Func: type = choir.dialects.FuncDialect;

    fn init(context: *choir.Context) !Boundary {
        try choir.dialects.registerAllDialects(context);
        const loc = choir.Location.getUnknown();
        const module = try choir.dialects.BuiltinDialect.ModuleOp.create(context, loc);
        return .{ .context = context, .module = module, .loc = loc };
    }

    fn select(self: *Boundary, selection: Selection) !void {
        std.debug.assert(selection.args.len <= max_values);
        std.debug.assert(selection.selected.len <= max_values);
        var inputs: [max_values]choir.ir.Type = undefined;
        for (selection.args, inputs[0..selection.args.len]) |arg, *input| {
            input.* = try self.typeOf(arg);
        }
        const count = selection.selected.len;
        var outputs: [max_values]choir.ir.Type = undefined;
        for (selection.selected, outputs[0..count]) |index, *output| output.* = inputs[index];
        const parameters = inputs[0..selection.args.len];
        const func = try self.function(selection.name, parameters, outputs[0..count]);
        var values: [max_values]*choir.Value = undefined;
        for (selection.selected, values[0..count]) |index, *value| {
            value.* = func.getArgument(index);
        }
        try self.finish(func, values[0..count]);
    }

    fn sum(self: *Boundary, name: []const u8, kind: Arith.ScalarTypeKind) !void {
        const scalar = try Arith.getScalarType(self.context, kind);
        const func = try self.function(name, &.{ scalar, scalar }, &.{scalar});
        const lhs = func.getArgument(0);
        const added = try Arith.AddOp.create(self.context, self.loc, lhs, func.getArgument(1));
        try func.getEntryBlock().addOperation(added.op);
        try self.finish(func, &.{added.getResult()});
    }

    fn splat(self: *Boundary, name: []const u8, kind: Arith.ScalarTypeKind, lanes: u32) !void {
        const scalar = try Arith.getScalarType(self.context, kind);
        const element = choir.dialects.arith.scalarTypeName(kind);
        const vector = (try Arith.getVecType(self.context, lanes, element)).?;
        const func = try self.function(name, &.{scalar}, &.{vector});
        const input = func.getArgument(0);
        const repeated = try Arith.SplatOp.create(self.context, self.loc, input, vector);
        try func.getEntryBlock().addOperation(repeated.op);
        try self.finish(func, &.{repeated.getResult()});
    }

    fn typeOf(self: *const Boundary, value: CallValue) !choir.ir.Type {
        switch (value) {
            .vector => unreachable,
            .memref => {
                const Memref = choir.dialects.MemrefDialect;
                const byte = try Arith.getScalarType(self.context, .u8);
                return Memref.getMemrefTypeDynamic(self.context, byte, .host);
            },
            inline else => |_, tag| {
                const kind = @field(Arith.ScalarTypeKind, @tagName(tag));
                return Arith.getScalarType(self.context, kind);
            },
        }
    }

    fn function(
        self: *Boundary,
        name: []const u8,
        inputs: []const choir.ir.Type,
        results: []const choir.ir.Type,
    ) !Func.FuncOp {
        std.debug.assert(self.count < max_functions);
        const created = try Func.FuncOp.create(self.context, self.loc, name, inputs, results);
        try self.module.getBodyBlock().addOperation(created.op);
        self.names[self.count] = name;
        self.functions[self.count] = created.op;
        self.count += 1;
        return created;
    }

    fn finish(self: *Boundary, func: Func.FuncOp, values: []const *choir.Value) !void {
        const ret = try Func.ReturnOp.create(self.context, self.loc, values);
        try func.getEntryBlock().addOperation(ret.op);
    }
};

const LoadedBoundary = struct {
    boundary: *const Boundary,
    handles: [Boundary.max_functions]execution.Handle,

    fn compile(runtime: *Runtime, boundary: *const Boundary) !LoadedBoundary {
        const handle = try runtime.compile(boundary.module.op);
        var loaded = LoadedBoundary{ .boundary = boundary, .handles = undefined };
        @memset(loaded.handles[0..boundary.count], handle);
        return loaded;
    }

    fn carry(runtime: *Runtime, boundary: *const Boundary) !LoadedBoundary {
        const allocator = std.testing.allocator;
        const serialization = choir.backends.artifact.serialization;
        var loaded = LoadedBoundary{ .boundary = boundary, .handles = undefined };
        const names = boundary.names[0..boundary.count];
        const functions = boundary.functions[0..boundary.count];
        for (names, functions, loaded.handles[0..names.len]) |name, function, *handle| {
            var built = try x86_64.object.compileFunctionToArtifact(allocator, function, name);
            defer built.deinit();
            const bytes = try serialization.serialize(allocator, &built);
            defer allocator.free(bytes);
            var restored = try serialization.deserialize(allocator, bytes);
            defer restored.deinit();
            handle.* = try runtime.loadArtifact(&restored);
        }
        return loaded;
    }

    fn of(self: *const LoadedBoundary, name: []const u8) execution.Handle {
        const count = self.boundary.count;
        for (self.boundary.names[0..count], self.handles[0..count]) |candidate, handle| {
            if (std.mem.eql(u8, candidate, name)) return handle;
        }
        unreachable;
    }
};

const OverflowUse = enum { both, value, flag };
const OverflowMode = enum { allocated, frame };
const overflow_inputs = [_]i64{ std.math.minInt(i64), std.math.minInt(i64) + 1, -9, -2, -1, 0, 1, 2, 3, 5, 9, 1 << 7, 1 << 31, 1 << 32, 1 << 62, std.math.maxInt(i64) };

fn overflowExpected(comptime Op: type, lhs: i64, rhs: i64) Flagged {
    const Arith = choir.dialects.ArithDialect;
    const result = if (Op == Arith.AddoOp)
        @addWithOverflow(lhs, rhs)
    else if (Op == Arith.SuboOp)
        @subWithOverflow(lhs, rhs)
    else
        @mulWithOverflow(lhs, rhs);
    return .{ .value = result[0], .below = result[1] != 0 };
}

fn overflowFunction(
    comptime Op: type,
    context: *choir.Context,
    module: choir.dialects.BuiltinDialect.ModuleOp,
    mode: OverflowMode,
    use: OverflowUse,
    constant: ?i64,
    left: bool,
) !choir.dialects.FuncDialect.FuncOp {
    const Arith = choir.dialects.ArithDialect;
    const Func = choir.dialects.FuncDialect;
    const integer = try Arith.getScalarType(context, .i64);
    const boolean = try Arith.getScalarType(context, .bool);
    const results: []const choir.Type = switch (use) {
        .both => &.{ integer, boolean },
        .value => &.{integer},
        .flag => &.{boolean},
    };
    const function = try Func.FuncOp.create(context, .unknown, "overflow", &.{ integer, integer }, results);
    try module.getBodyBlock().addOperation(function.op);
    const block = function.getEntryBlock();
    var lhs = function.getArgument(0);
    var rhs = function.getArgument(1);
    if (constant) |value| {
        const literal = try Arith.ConstantOp.createInt(context, .unknown, integer, value);
        try block.addOperation(literal.op);
        if (left) lhs = literal.getResult() else rhs = literal.getResult();
    }
    if (mode == .frame) {
        const control = try Arith.UmulhiOp.create(context, .unknown, lhs, rhs);
        try block.addOperation(control.op);
    }
    const checked = try Op.create(context, .unknown, lhs, rhs);
    try block.addOperation(checked.op);
    const returns: []const *choir.Value = switch (use) {
        .both => &.{ checked.getResult(), checked.getOverflow() },
        .value => &.{checked.getResult()},
        .flag => &.{checked.getOverflow()},
    };
    const ret = try Func.ReturnOp.create(context, .unknown, returns);
    try block.addOperation(ret.op);
    return function;
}

fn checkOverflowNative(comptime Op: type, mode: OverflowMode, use: OverflowUse, constant: ?i64, left: bool) !void {
    var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(std.testing.allocator);
    try choir.dialects.registerAllDialects(&context);
    const module = try choir.dialects.BuiltinDialect.ModuleOp.create(&context, .unknown);
    const function = try overflowFunction(Op, &context, module, mode, use, constant, left);
    try choir.ir.verifyOperation(module.op, .{});
    var emitter = x86_64.Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(function.op);
    const allocated = emitter.value_locations.count() != 0 or emitter.value_location_ranges.items.len != 0;
    try std.testing.expectEqual(mode == .allocated, allocated);
    const flag_instruction = x86_64.encoding.setcc(.rcx, .o);
    try std.testing.expect(std.mem.indexOf(u8, emitter.getCode(), flag_instruction.slice()) != null);

    var artifact = try x86_64.object.compileFunctionToArtifact(std.testing.allocator, function.op, "overflow");
    defer artifact.deinit();
    var runtime = try Runtime.init(std.testing.allocator, .testing);
    defer runtime.deinit();
    const loaded = try runtime.loadArtifact(&artifact);
    const Both = *const fn (i64, i64) callconv(.c) Flagged;
    const Value = *const fn (i64, i64) callconv(.c) i64;
    const Flag = *const fn (i64, i64) callconv(.c) bool;
    for (overflow_inputs) |a| for (overflow_inputs) |b| {
        const lhs = if (left) constant orelse a else a;
        const rhs = if (!left) constant orelse b else b;
        const expected = overflowExpected(Op, lhs, rhs);
        switch (use) {
            .both => {
                const run = try runtime.getFunction(loaded, "overflow", Both);
                try std.testing.expectEqual(expected, run(a, b));
            },
            .value => {
                const run = try runtime.getFunction(loaded, "overflow", Value);
                try std.testing.expectEqual(expected.value, run(a, b));
            },
            .flag => {
                const run = try runtime.getFunction(loaded, "overflow", Flag);
                try std.testing.expectEqual(expected.below, run(a, b));
            },
        }
    };
}

test "x86_64 overflow arithmetic preserves allocation and both materialized answers" {
    if (!executes) return error.SkipZigTest;
    const Arith = choir.dialects.ArithDialect;
    inline for (.{ Arith.AddoOp, Arith.SuboOp, Arith.MuloOp }) |Op| {
        for (std.enums.values(OverflowMode)) |mode| {
            for (std.enums.values(OverflowUse)) |use| {
                try checkOverflowNative(Op, mode, use, null, false);
            }
        }
    }
}

test "x86_64 overflow arithmetic constants never take flagless strength reductions" {
    if (!executes) return error.SkipZigTest;
    const Arith = choir.dialects.ArithDialect;
    inline for (.{ Arith.AddoOp, Arith.SuboOp, Arith.MuloOp }) |Op| {
        for (std.enums.values(OverflowMode)) |mode| {
            for (overflow_inputs) |constant| {
                try checkOverflowNative(Op, mode, .both, constant, false);
                try checkOverflowNative(Op, mode, .both, constant, true);
            }
        }
    }
}

fn overflowIdentity(value: i64) callconv(.c) i64 {
    return value;
}

test "x86_64 overflow arithmetic survives pressure calls and a static alloca" {
    if (!executes) return error.SkipZigTest;
    const Arith = choir.dialects.ArithDialect;
    const Func = choir.dialects.FuncDialect;
    const Memref = choir.dialects.MemrefDialect;
    inline for (.{ Arith.AddoOp, Arith.SuboOp, Arith.MuloOp }) |Op| {
        var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
        defer context.deinit(std.testing.allocator);
        try choir.dialects.registerAllDialects(&context);
        const integer = try Arith.getScalarType(&context, .i64);
        const boolean = try Arith.getScalarType(&context, .bool);
        const index = try Arith.getScalarType(&context, .index);
        const module = try choir.dialects.BuiltinDialect.ModuleOp.create(&context, .unknown);
        const declaration = try Func.FuncOp.createDeclaration(&context, .unknown, "overflow_identity", &.{integer}, &.{integer});
        try module.getBodyBlock().addOperation(declaration.op);
        const function = try Func.FuncOp.create(&context, .unknown, "pressure", &.{ integer, integer }, &.{ integer, boolean });
        try module.getBodyBlock().addOperation(function.op);
        const block = function.getEntryBlock();
        const buffer = try Memref.getMemrefType1D(&context, 1, integer, .host);
        const cell = try Memref.AllocaOp.createStatic(&context, .unknown, buffer);
        try block.addOperation(cell.op);
        const zero = try Arith.ConstantOp.createInt(&context, .unknown, index, 0);
        try block.addOperation(zero.op);
        var live: [16]*choir.Value = undefined;
        for (&live, 0..) |*value, i| {
            const literal = try Arith.ConstantOp.createInt(&context, .unknown, integer, @intCast(i + 1));
            try block.addOperation(literal.op);
            const addition = try Arith.AddOp.create(&context, .unknown, function.getArgument(0), literal.getResult());
            try block.addOperation(addition.op);
            value.* = addition.getResult();
        }
        const checked = try Op.create(&context, .unknown, function.getArgument(0), function.getArgument(1));
        try block.addOperation(checked.op);
        const store = try Memref.StoreOp.create(&context, .unknown, checked.getResult(), cell.getResult(), zero.getResult());
        try block.addOperation(store.op);
        var sum = checked.getResult();
        for (live) |value| {
            const addition = try Arith.AddOp.create(&context, .unknown, sum, value);
            try block.addOperation(addition.op);
            sum = addition.getResult();
        }
        const call = try Func.CallOp.create(&context, .unknown, "overflow_identity", &.{sum}, &.{integer});
        try block.addOperation(call.op);
        const load = try Memref.LoadOp.create(&context, .unknown, cell.getResult(), zero.getResult(), integer);
        try block.addOperation(load.op);
        const equal = try Arith.CmpOp.create(&context, .unknown, .eq, load.getResult(), checked.getResult());
        try block.addOperation(equal.op);
        const selected = try Arith.SelectOp.create(&context, .unknown, equal.getResult(), checked.getResult(), call.getResult(0).?);
        try block.addOperation(selected.op);
        const ret = try Func.ReturnOp.create(&context, .unknown, &.{ selected.getResult(), checked.getOverflow() });
        try block.addOperation(ret.op);
        try choir.ir.verifyOperation(module.op, .{});
        var emitter = x86_64.Emitter.init(std.testing.allocator);
        defer emitter.deinit();
        try emitter.emitFunction(function.op);
        try std.testing.expect(emitter.value_locations.count() != 0 or emitter.value_location_ranges.items.len != 0);
        var spills: usize = 0;
        for (emitter.value_location_ranges.items) |range| {
            if (range.exit == .spill) spills += 1;
        }
        try std.testing.expect(spills != 0);
        var artifact = try x86_64.object.compileFunctionToArtifact(std.testing.allocator, function.op, "pressure");
        defer artifact.deinit();
        var runtime = try Runtime.init(std.testing.allocator, .testing);
        defer runtime.deinit();
        try runtime.registerExternalSymbol("overflow_identity", @intFromPtr(&overflowIdentity));
        const loaded = try runtime.loadArtifact(&artifact);
        const run = try runtime.getFunction(loaded, "pressure", *const fn (i64, i64) callconv(.c) Flagged);
        for (overflow_inputs) |a| for (overflow_inputs) |b| {
            try std.testing.expectEqual(overflowExpected(Op, a, b), run(a, b));
        };
    }
}

/// The values one `scf.while` carries in the program below, which is the widest
/// `emit.max_while_carried_values` admits: one counter and fifteen accumulators.
const carried_accumulators = x86_64.emit.max_while_carried_values - 1;

/// Turns the loop below takes, which fixes the answer each accumulator carries out.
const carried_turns: i64 = 2;

/// Builds `fn carried() -> i64`: one `scf.while` carrying a counter and
/// `carried_accumulators` accumulators with distinct inits, each turn adding one to
/// every accumulator and one turn to the counter, returning their sum.
///
/// THE INITS DIFFER ON PURPOSE. A loop whose carried values all start from one value
/// is its own parallel move shape, and a repair that only settled that shape would
/// pass a test built from it.
fn carriedWhile(context: *choir.Context) !choir.dialects.BuiltinDialect.ModuleOp {
    const Arith = choir.dialects.ArithDialect;
    const Func = choir.dialects.FuncDialect;
    const Scf = choir.dialects.ScfDialect;
    const loc = choir.Location.getUnknown();
    try choir.dialects.registerAllDialects(context);
    const integer = try Arith.getScalarType(context, .i64);
    const module = try choir.dialects.BuiltinDialect.ModuleOp.create(context, loc);
    const function = try Func.FuncOp.create(context, loc, "carried", &.{}, &.{integer});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();

    var inits: [carried_accumulators + 1]*choir.ir.Value = undefined;
    var init_types: [carried_accumulators + 1]choir.ir.Type = undefined;
    const turns = try Arith.ConstantOp.createInt(context, loc, integer, carried_turns);
    try entry.addOperation(turns.op);
    inits[0] = turns.getResult();
    init_types[0] = integer;
    for (0..carried_accumulators) |index| {
        const seed = try Arith.ConstantOp.createInt(context, loc, integer, @intCast(index + 1));
        try entry.addOperation(seed.op);
        inits[1 + index] = seed.getResult();
        init_types[1 + index] = integer;
    }

    var while_op = try Scf.WhileOp.create(context, loc, &inits, &init_types);
    try entry.addOperation(while_op.op);

    const before = while_op.getBeforeBlock();
    const floor = try Arith.ConstantOp.createInt(context, loc, integer, 0);
    try before.addOperation(floor.op);
    const counter = before.arguments.items[0];
    const running = try Arith.CmpOp.create(context, loc, .gt, counter, floor.getResult());
    try before.addOperation(running.op);
    const held = before.arguments.items;
    const condition = try Scf.ConditionOp.create(context, loc, running.getResult(), held);
    try before.addOperation(condition.op);

    const after = while_op.getAfterBlock();
    const one = try Arith.ConstantOp.createInt(context, loc, integer, 1);
    try after.addOperation(one.op);
    var next: [carried_accumulators + 1]*choir.ir.Value = undefined;
    const spent = try Arith.SubOp.create(context, loc, after.arguments.items[0], one.getResult());
    try after.addOperation(spent.op);
    next[0] = spent.getResult();
    for (0..carried_accumulators) |index| {
        const carried = after.arguments.items[1 + index];
        const raised = try Arith.AddOp.create(context, loc, carried, one.getResult());
        try after.addOperation(raised.op);
        next[1 + index] = raised.getResult();
    }
    const yield = try Scf.YieldOp.create(context, loc, &next);
    try after.addOperation(yield.op);

    var total = while_op.op.getResult(1) orelse return error.TestFailure;
    for (1..carried_accumulators) |index| {
        const carried = while_op.op.getResult(1 + index) orelse return error.TestFailure;
        const sum = try Arith.AddOp.create(context, loc, total, carried);
        try entry.addOperation(sum.op);
        total = sum.getResult();
    }
    const ret = try Func.ReturnOp.create(context, loc, &.{total});
    try entry.addOperation(ret.op);
    return module;
}

/// What `carried` returns: every accumulator's seed plus one for each turn.
fn carriedExpected() i64 {
    var total: i64 = 0;
    for (0..carried_accumulators) |index| total += @as(i64, @intCast(index + 1)) + carried_turns;
    return total;
}

test "a while loop at the carried bound settles every value where control arrives" {
    if (!executes) {
        return error.SkipZigTest;
    }
    var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(std.testing.allocator);
    const module = try carriedWhile(&context);
    var backend = try x86_64.backend.Backend.init(std.testing.allocator, &context);
    defer backend.deinit();
    var runtime = try Runtime.init(std.testing.allocator, .testing);
    defer runtime.deinit();
    var artifact = try backend.compileFunctionToArtifact(module.op, "carried");
    defer artifact.deinit();
    const loaded = try runtime.loadArtifact(&artifact);
    const run = try runtime.getFunction(loaded, "carried", *const fn () callconv(.c) i64);
    try std.testing.expectEqual(carriedExpected(), run());
}

const OverflowBranchShape = enum { direct, inverted, second_use, intervening, other_block, inverted_flag_reuse, inverted_result_reuse };
const OverflowBranchOptions = struct {
    mode: OverflowMode = .allocated,
    shape: OverflowBranchShape = .direct,
    wrapped_live: bool = true,
    pressure: bool = false,
    constant: ?i64 = null,
    left: bool = false,
};

fn overflowBranchFunction(comptime Op: type, context: *choir.Context, options: OverflowBranchOptions) !choir.dialects.FuncDialect.FuncOp {
    const Arith = choir.dialects.ArithDialect;
    const Func = choir.dialects.FuncDialect;
    const Scf = choir.dialects.ScfDialect;
    const integer = try Arith.getScalarType(context, .i64);
    const boolean = try Arith.getScalarType(context, .bool);
    const function = try Func.FuncOp.create(context, .unknown, "overflow_branch", &.{ integer, integer }, &.{ integer, boolean });
    const block = function.getEntryBlock();
    var lhs = function.getArgument(0);
    var rhs = function.getArgument(1);
    if (options.constant) |value| {
        const constant = try Arith.ConstantOp.createInt(context, .unknown, integer, value);
        try block.addOperation(constant.op);
        if (options.left) lhs = constant.getResult() else rhs = constant.getResult();
    }
    if (options.mode == .frame) {
        try block.addOperation((try Arith.UmulhiOp.create(context, .unknown, lhs, rhs)).op);
    }
    const zero = try Arith.ConstantOp.createInt(context, .unknown, integer, 0);
    try block.addOperation(zero.op);
    const yes = try Arith.ConstantOp.createBool(context, .unknown, true);
    const no = try Arith.ConstantOp.createBool(context, .unknown, false);
    try block.addOperation(yes.op);
    try block.addOperation(no.op);
    var live: [16]*choir.Value = undefined;
    if (options.pressure) {
        for (&live, 0..) |*value, i| {
            const literal = try Arith.ConstantOp.createInt(context, .unknown, integer, @intCast(i + 1));
            try block.addOperation(literal.op);
            const sum = try Arith.AddOp.create(context, .unknown, function.getArgument(0), literal.getResult());
            try block.addOperation(sum.op);
            value.* = sum.getResult();
        }
    }
    const checked = try Op.create(context, .unknown, lhs, rhs);
    try block.addOperation(checked.op);
    var condition = checked.getOverflow();
    if (options.shape == .inverted or options.shape == .inverted_flag_reuse or options.shape == .inverted_result_reuse) {
        const negation = try Arith.NotOp.create(context, .unknown, condition);
        try block.addOperation(negation.op);
        condition = negation.getResult();
    }
    if (options.shape == .intervening) {
        try block.addOperation((try Arith.ConstantOp.createInt(context, .unknown, integer, 13)).op);
    }
    var branch_block = block;
    var outer: ?Scf.IfOp = null;
    if (options.shape == .other_block) {
        outer = try Scf.IfOp.create(context, .unknown, yes.getResult(), &.{boolean});
        try block.addOperation(outer.?.op);
        branch_block = outer.?.getThenBlock();
        try outer.?.getElseBlock().?.addOperation((try Scf.YieldOp.create(context, .unknown, &.{no.getResult()})).op);
    }
    const branch = try Scf.IfOp.create(context, .unknown, condition, &.{boolean});
    try branch_block.addOperation(branch.op);
    const taken = if (options.shape == .second_use) condition else yes.getResult();
    try branch.getThenBlock().addOperation((try Scf.YieldOp.create(context, .unknown, &.{taken})).op);
    try branch.getElseBlock().?.addOperation((try Scf.YieldOp.create(context, .unknown, &.{no.getResult()})).op);
    if (options.shape == .inverted_flag_reuse or options.shape == .inverted_result_reuse) {
        const reused = if (options.shape == .inverted_flag_reuse) checked.getOverflow() else condition;
        try block.addOperation((try Arith.NotOp.create(context, .unknown, reused)).op);
    }
    var answer = branch.getResult(0).?;
    if (outer) |enclosing| {
        try branch_block.addOperation((try Scf.YieldOp.create(context, .unknown, &.{answer})).op);
        answer = enclosing.getResult(0).?;
    }
    var value = if (options.wrapped_live) checked.getResult() else zero.getResult();
    if (options.pressure) {
        for (live ++ [_]*choir.Value{ function.getArgument(0), function.getArgument(1) }) |held| {
            const sum = try Arith.AddOp.create(context, .unknown, value, held);
            try block.addOperation(sum.op);
            value = sum.getResult();
        }
    }
    try block.addOperation((try Func.ReturnOp.create(context, .unknown, &.{ value, answer })).op);
    return function;
}

/// Decode at instruction boundaries. The shared decoder does not yet name jo/jno,
/// so recognize their six-byte rel32 encoding before asking it about other instructions.
fn overflowBranchInterval(comptime Op: type, code: []const u8, inverted: bool) ![]const u8 {
    const Arith = choir.dialects.ArithDialect;
    const writer = if (Op == Arith.AddoOp) x86_64.encoding.addRegReg(.rax, .rcx) else if (Op == Arith.SuboOp)
        x86_64.encoding.subRegReg(.rax, .rcx)
    else
        x86_64.encoding.imulRegReg(.rax, .rcx);
    var offset: usize = 0;
    var start: ?usize = null;
    while (offset < code.len) {
        const tail = code[offset..];
        if (tail.len >= 6 and tail[0] == 0x0f and (tail[1] == 0x80 or tail[1] == 0x81)) {
            try std.testing.expectEqual(@as(u8, if (inverted) 0x80 else 0x81), tail[1]);
            return code[start orelse return error.MissingOverflowWriter .. offset];
        }
        const decoded = try @import("isa").x86.decode(tail);
        if (std.mem.startsWith(u8, tail, writer.slice())) {
            start = offset + decoded.bytes;
        } else if (start != null) {
            switch (decoded.operation) {
                .mov, .movsx, .movzx, .movdqu, .movups => {},
                else => return error.OverflowFlagClobbered,
            }
        }
        offset += decoded.bytes;
    }
    return error.MissingOverflowBranch;
}

fn checkOverflowBranch(comptime Op: type, options: OverflowBranchOptions) !void {
    var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
    defer context.deinit(std.testing.allocator);
    try choir.dialects.registerAllDialects(&context);
    const function = try overflowBranchFunction(Op, &context, options);
    try choir.ir.verifyOperation(function.op, .{});
    var emitter = x86_64.Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(function.op);
    try std.testing.expectEqual(options.mode == .allocated, emitter.value_location_ranges.items.len != 0);
    var artifact = try x86_64.object.compileFunctionToArtifact(std.testing.allocator, function.op, "overflow_branch");
    defer artifact.deinit();
    var runtime = try Runtime.init(std.testing.allocator, .testing);
    defer runtime.deinit();
    const loaded = try runtime.loadArtifact(&artifact);
    const run = try runtime.getFunction(loaded, "overflow_branch", *const fn (i64, i64) callconv(.c) Flagged);
    for (overflow_inputs) |a| for (overflow_inputs) |b| {
        const lhs = if (options.left) options.constant orelse a else a;
        const rhs = if (!options.left) options.constant orelse b else b;
        var expected = overflowExpected(Op, lhs, rhs);
        if (!options.wrapped_live) expected.value = 0;
        if (options.pressure) expected.value +%= a *% 17 +% 136 +% b;
        if (options.shape == .inverted or options.shape == .inverted_flag_reuse or options.shape == .inverted_result_reuse) expected.below = !expected.below;
        try std.testing.expectEqual(expected, run(a, b));
    };
    const fused = options.shape == .direct or options.shape == .inverted;
    const seto = x86_64.encoding.setcc(.rcx, .o);
    try std.testing.expectEqual(!fused, std.mem.indexOf(u8, emitter.getCode(), seto.slice()) != null);
    if (fused) {
        const interval = try overflowBranchInterval(Op, emitter.getCode(), options.shape == .inverted);
        if (options.pressure and options.shape == .inverted) {
            try std.testing.expect(interval.len != 0);
            var spill = false;
            var offset: usize = 0;
            while (offset < interval.len) {
                const decoded = try @import("isa").x86.decode(interval[offset..]);
                if (decoded.operand == .memory) spill = true;
                offset += decoded.bytes;
            }
            try std.testing.expect(spill);
        }
    }
}

test "x86_64 overflow branches fuse only the adjacent single-use boolean" {
    if (!executes) return error.SkipZigTest;
    const Arith = choir.dialects.ArithDialect;
    inline for (.{ Arith.AddoOp, Arith.SuboOp, Arith.MuloOp }) |Op| {
        for (std.enums.values(OverflowMode)) |mode| {
            for (std.enums.values(OverflowBranchShape)) |shape| {
                for ([_]bool{ false, true }) |wrapped_live| {
                    try checkOverflowBranch(Op, .{ .mode = mode, .shape = shape, .wrapped_live = wrapped_live });
                }
            }
        }
    }
}

test "x86_64 overflow branches preserve OF across pressure spills" {
    if (!executes) return error.SkipZigTest;
    const Arith = choir.dialects.ArithDialect;
    inline for (.{ Arith.AddoOp, Arith.SuboOp, Arith.MuloOp }) |Op| {
        try checkOverflowBranch(Op, .{ .pressure = true });
        try checkOverflowBranch(Op, .{ .pressure = true, .shape = .inverted });
    }
}

test "x86_64 overflow branches retain flag writers for either constant operand" {
    if (!executes) return error.SkipZigTest;
    const Arith = choir.dialects.ArithDialect;
    inline for (.{ Arith.AddoOp, Arith.SuboOp, Arith.MuloOp }) |Op| {
        for (std.enums.values(OverflowMode)) |mode| {
            for ([_]OverflowBranchShape{ .direct, .inverted }) |shape| {
                for (overflow_inputs) |constant| {
                    for ([_]bool{ false, true }) |left| {
                        try checkOverflowBranch(Op, .{ .mode = mode, .shape = shape, .constant = constant, .left = left });
                    }
                }
            }
        }
    }
}

test "x86_64 overflow branches feed direct and inverted while conditions" {
    if (!executes) return error.SkipZigTest;
    const Arith = choir.dialects.ArithDialect;
    const Func = choir.dialects.FuncDialect;
    const Scf = choir.dialects.ScfDialect;
    inline for (.{ Arith.AddoOp, Arith.SuboOp, Arith.MuloOp }) |Op| {
        for (std.enums.values(OverflowMode)) |mode| for ([_]bool{ false, true }) |inverted| {
            var context = try choir.Context.init(std.testing.allocator, choir.Context.Limits.testing);
            defer context.deinit(std.testing.allocator);
            try choir.dialects.registerAllDialects(&context);
            const integer = try Arith.getScalarType(&context, .i64);
            const boolean = try Arith.getScalarType(&context, .bool);
            const function = try Func.FuncOp.create(&context, .unknown, "overflow_while", &.{ integer, integer }, &.{ integer, boolean });
            const block = function.getEntryBlock();
            const lhs = function.getArgument(0);
            const rhs = function.getArgument(1);
            if (mode == .frame) try block.addOperation((try Arith.UmulhiOp.create(&context, .unknown, lhs, rhs)).op);
            const yes = try Arith.ConstantOp.createBool(&context, .unknown, true);
            const no = try Arith.ConstantOp.createBool(&context, .unknown, false);
            try block.addOperation(yes.op);
            try block.addOperation(no.op);
            const zero = try Arith.ConstantOp.createInt(&context, .unknown, integer, 0);
            try block.addOperation(zero.op);
            const loop = try Scf.WhileOp.create(&context, .unknown, &.{ lhs, rhs, zero.getResult(), no.getResult() }, &.{ integer, integer, integer, boolean });
            try block.addOperation(loop.op);
            const before = loop.getBeforeBlock();
            const checked = try Op.create(&context, .unknown, before.arguments.items[0], before.arguments.items[1]);
            try before.addOperation(checked.op);
            var condition = checked.getOverflow();
            if (inverted) {
                const negation = try Arith.NotOp.create(&context, .unknown, condition);
                try before.addOperation(negation.op);
                condition = negation.getResult();
            }
            try before.addOperation((try Scf.ConditionOp.create(&context, .unknown, condition, &.{ before.arguments.items[0], before.arguments.items[1], checked.getResult(), before.arguments.items[3] })).op);
            const after = loop.getAfterBlock();
            const stop_lhs: i64 = if (!inverted) 0 else if (Op == Arith.SuboOp) std.math.minInt(i64) else std.math.maxInt(i64);
            const stop_rhs: i64 = if (inverted) 2 else 0;
            const stop_a = try Arith.ConstantOp.createInt(&context, .unknown, integer, stop_lhs);
            const stop_b = try Arith.ConstantOp.createInt(&context, .unknown, integer, stop_rhs);
            try after.addOperation(stop_a.op);
            try after.addOperation(stop_b.op);
            try after.addOperation((try Scf.YieldOp.create(&context, .unknown, &.{ stop_a.getResult(), stop_b.getResult(), after.arguments.items[2], yes.getResult() })).op);
            try block.addOperation((try Func.ReturnOp.create(&context, .unknown, &.{ loop.op.getResult(2).?, loop.op.getResult(3).? })).op);
            try choir.ir.verifyOperation(function.op, .{});
            var emitter = x86_64.Emitter.init(std.testing.allocator);
            defer emitter.deinit();
            try emitter.emitFunction(function.op);
            try std.testing.expectEqual(mode == .allocated, emitter.value_location_ranges.items.len != 0);
            _ = try overflowBranchInterval(Op, emitter.getCode(), inverted);
            var artifact = try x86_64.object.compileFunctionToArtifact(std.testing.allocator, function.op, "overflow_while");
            defer artifact.deinit();
            var runtime = try Runtime.init(std.testing.allocator, .testing);
            defer runtime.deinit();
            const loaded = try runtime.loadArtifact(&artifact);
            const run = try runtime.getFunction(loaded, "overflow_while", *const fn (i64, i64) callconv(.c) Flagged);
            for (overflow_inputs) |a| for (overflow_inputs) |b| {
                var expected = overflowExpected(Op, a, b);
                if (inverted) expected.below = !expected.below;
                if (expected.below) expected.value = overflowExpected(Op, stop_lhs, stop_rhs).value;
                try std.testing.expectEqual(expected, run(a, b));
            };
        };
    }
}
