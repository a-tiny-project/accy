//! Contract tests run against a selected host target. Apple scalar witnesses declare the
//! inspected test product policy explicitly; unsupported targets skip by name.

const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const backends = @import("../root.zig");
const artifact = backends.artifact;
const debug_info = backends.debug_info;
const machine = backends.machine_code;
const sys = @import("sys");
const diagnostics = @import("../../root.zig").diagnostics;
const execution = @import("root.zig");
const fixture = @import("fixture/root.zig");

const Runtime = execution.native.Runtime;
const Handle = execution.Handle;
const builtin_count = execution.native.Target.builtin_count;
const scalar_only = execution.native.Target.architecture == .aarch64;

/// These contract witnesses are part of the inspected Apple test product. Its caller, unlike
/// an arbitrary embedding process, declares the supported non-hardened publication policy.
fn initRuntime(allocator: std.mem.Allocator, limits: execution.Limits) execution.InitError!Runtime {
    if (comptime scalar_only)
        return Runtime.initWithExecutablePolicy(allocator, limits, .macos_non_hardened);
    return Runtime.init(allocator, limits);
}

test "aarch64 native execution requires an explicit Apple product policy before allocating" {
    if (!scalar_only) return error.SkipZigTest;
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.UnsupportedPublicationPolicy, Runtime.init(failing.allocator(), .testing));
    try testing.expectError(error.UnsupportedPublicationPolicy, Runtime.initWithExecutablePolicy(
        failing.allocator(),
        .testing,
        .unsupported_hardened,
    ));
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "execution contract imports its component tests" {
    _ = @import("host.zig");
    _ = @import("limits.zig");
    _ = @import("target.zig");
    _ = @import("value.zig");
}

test "Runtime data pages stay read-only and outlive released modules" {
    if (execution.native.Target.unavailable != null or scalar_only) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const first_table = machine.DataSymbol{ .name = "table", .bytes = "first", .alignment = 16 };
    const first_module = try fixture.dataModule(&ctx, "table", first_table);
    defer first_module.erase();
    const second_table = machine.DataSymbol{ .name = "table", .bytes = "second" };
    const second_module = try fixture.dataModule(&ctx, "table", second_table);
    defer second_module.erase();

    var runtime = try initRuntime(testing.allocator, .testing);
    defer runtime.deinit();
    const first = try runtime.compile(first_module);
    const second = try runtime.compile(second_module);
    const first_address = try fixture.addressFrom(&runtime, first, "table");
    const second_address = try fixture.addressFrom(&runtime, second, "table");
    try testing.expect(std.mem.isAligned(first_address, 16));
    try testing.expectEqualStrings("first", fixture.bytesAt(first_address, 5));
    try testing.expectEqualStrings("second", fixture.bytesAt(second_address, 6));

    if (comptime @import("builtin").os.tag == .linux) {
        const maps = try fixture.readProcSelfMaps(testing.allocator);
        defer testing.allocator.free(maps);
        try testing.expectEqualStrings("r--p", fixture.mappingPermissions(maps, first_address).?);
        const code_address = try runtime.functionAddress(first, "table");
        try testing.expectEqualStrings("r-xp", fixture.mappingPermissions(maps, code_address).?);
    }

    try runtime.release(first);
    try testing.expectEqualStrings("second", fixture.bytesAt(second_address, 6));
    const reloaded = try runtime.compile(first_module);
    try testing.expectEqual(first.index, reloaded.index);
    const reloaded_address = try fixture.addressFrom(&runtime, reloaded, "table");
    try testing.expectEqualStrings("first", fixture.bytesAt(reloaded_address, 5));
}

test "Runtime recompiles keep handed-out code until release" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const one = try fixture.constantModule(&ctx, "value", 1);
    defer one.erase();
    const two = try fixture.constantModule(&ctx, "value", 2);
    defer two.erase();

    const Value = *const fn () callconv(.c) i64;
    var runtime = try initRuntime(testing.allocator, .testing);
    defer runtime.deinit();
    const first = try runtime.compile(one);
    const first_value = try runtime.getFunction(first, "value", Value);
    const second = try runtime.compile(two);
    try testing.expectEqual(@as(i64, 1), first_value());
    try testing.expectEqual(@as(i64, 2), (try runtime.getFunction(second, "value", Value))());

    try runtime.release(first);
    const third = try runtime.compile(one);
    try testing.expectEqual(first.index, third.index);
    try testing.expect(first.generation != third.generation);
    try testing.expectError(error.InvalidModuleHandle, runtime.functionAddress(first, "value"));
    try testing.expectEqual(@as(i64, 1), (try runtime.getFunction(third, "value", Value))());
    try testing.expectEqual(@as(i64, 2), (try runtime.getFunction(second, "value", Value))());
    try testing.expectError(error.FunctionNotFound, runtime.functionAddress(third, "missing"));
    const unissued = Handle{ .index = 2, .generation = 1 };
    try testing.expectError(error.InvalidModuleHandle, runtime.functionAddress(unissued, "value"));
}

test "Runtime publishes used code and credits its owned mapping on release" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    const Value = *const fn () callconv(.c) i64;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try fixture.constantModule(&ctx, "value", 42);
    defer module.erase();

    var runtime = try initRuntime(testing.allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    const code = &runtime.modules.items[handle.index].code.?;
    try testing.expect(code.used > 0);
    try testing.expect(code.used < code.mappedBytes());
    try testing.expectEqual(try code.callableAddress(), try runtime.functionAddress(handle, "value"));
    try testing.expectEqual(@as(u64, code.mappedBytes()), runtime.mapped_bytes);
    try testing.expectEqual(@as(i64, 42), (try runtime.getFunction(handle, "value", Value))());
    try runtime.release(handle);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
    try testing.expectError(error.InvalidModuleHandle, runtime.functionAddress(handle, "value"));
}

test "Runtime function addresses survive module list growth" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try fixture.constantModule(&ctx, "entry", 5);
    defer module.erase();

    var runtime = try initRuntime(testing.allocator, .testing);
    defer runtime.deinit();
    const first = try runtime.compile(module);
    const before = try runtime.functionAddress(first, "entry");
    for (0..8) |_| _ = try runtime.compile(module);
    try testing.expectEqual(before, try runtime.functionAddress(first, "entry"));
    const entry = try runtime.getFunction(first, "entry", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 5), entry());
}

test "Runtime admits modules up to its module count and rejects the next" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try fixture.constantModule(&ctx, "entry", 7);
    defer module.erase();

    const limit = 3;
    var runtime = try initRuntime(testing.allocator, .{
        .live_modules = limit,
        .mapped_bytes = execution.Limits.testing.mapped_bytes,
    });
    defer runtime.deinit();

    var handles: [limit]Handle = undefined;
    for (&handles) |*handle| handle.* = try runtime.compile(module);
    try testing.expectEqual(@as(u32, limit), runtime.live_modules);
    try testing.expectError(error.JitRuntimeFull, runtime.compile(module));

    try runtime.release(handles[1]);
    try testing.expectEqual(@as(u32, limit - 1), runtime.live_modules);
    handles[1] = try runtime.compile(module);
    try testing.expectError(error.JitRuntimeFull, runtime.compile(module));

    try testing.expectEqual(@as(u32, 1), handles[1].index);
    try testing.expectEqual(@as(u32, 2), handles[1].generation);
    try testing.expectEqual(@as(usize, limit), runtime.modules.items.len);

    const entry = try runtime.getFunction(handles[0], "entry", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 7), entry());
}

test "Runtime admits modules up to its mapped-byte budget and rejects the next" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try fixture.constantModule(&ctx, "entry", 9);
    defer module.erase();

    const bytes_per_module = sys.memory.pageAlign(1).?;
    const admitted_modules = 3;
    const budget: u64 = admitted_modules * bytes_per_module;
    var runtime = try initRuntime(testing.allocator, .{
        .live_modules = execution.Limits.testing.live_modules,
        .mapped_bytes = budget,
    });
    defer runtime.deinit();

    var handles: [admitted_modules]Handle = undefined;
    for (&handles) |*handle| handle.* = try runtime.compile(module);
    try testing.expectEqual(budget, runtime.mapped_bytes);
    try testing.expectEqual(@as(u32, admitted_modules), runtime.live_modules);

    try testing.expectError(error.JitRuntimeFull, runtime.compile(module));
    try testing.expectEqual(budget, runtime.mapped_bytes);
    try testing.expectEqual(@as(u32, admitted_modules), runtime.live_modules);

    try runtime.release(handles[1]);
    try testing.expectEqual(budget - bytes_per_module, runtime.mapped_bytes);
    handles[1] = try runtime.compile(module);
    try testing.expectEqual(budget, runtime.mapped_bytes);
    try testing.expectError(error.JitRuntimeFull, runtime.compile(module));

    const entry = try runtime.getFunction(handles[0], "entry", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 9), entry());
}

test "Runtime charges a module's data mapping alongside its code" {
    if (execution.native.Target.unavailable != null or scalar_only) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const table = machine.DataSymbol{ .name = "table", .bytes = "payload" };
    const module = try fixture.dataModule(&ctx, "table", table);
    defer module.erase();

    const page = sys.memory.pageAlign(1).?;
    var runtime = try initRuntime(testing.allocator, .testing);
    defer runtime.deinit();

    const handle = try runtime.compile(module);
    try testing.expectEqual(@as(u64, 2 * page), runtime.mapped_bytes);
    try runtime.release(handle);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}

test "Runtime counts a data mapping against the mapped-byte budget" {
    if (execution.native.Target.unavailable != null or scalar_only) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const table = machine.DataSymbol{ .name = "table", .bytes = "payload" };
    const module = try fixture.dataModule(&ctx, "table", table);
    defer module.erase();

    const page = sys.memory.pageAlign(1).?;
    var runtime = try initRuntime(testing.allocator, .{
        .live_modules = execution.Limits.testing.live_modules,
        .mapped_bytes = 2 * page,
    });
    defer runtime.deinit();

    const handle = try runtime.compile(module);
    try testing.expectEqual(@as(u64, 2 * page), runtime.mapped_bytes);
    try testing.expectError(error.JitRuntimeFull, runtime.compile(module));

    try runtime.release(handle);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
    const again = try runtime.compile(module);
    try testing.expectEqual(@as(u64, 2 * page), runtime.mapped_bytes);
    try runtime.release(again);
}

test "Runtime debug map includes line locations" {
    if (execution.native.Target.unavailable != null or scalar_only) return error.SkipZigTest;

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

    const loc = ir.Location.getFile("test.choir", 4, 2);
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "debug_map", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var constant = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 7);
    try entry.addOperation(constant.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{constant.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try initRuntime(allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);

    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const emitted = try runtime.writeDebugMap(&writer);
    const output = writer.buffered();

    try testing.expect(emitted);
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "debug_map"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "test.choir:4:2"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "arith.constant"));

    try runtime.release(handle);
    var released_writer = std.Io.Writer.fixed(&buf);
    try testing.expect(!try runtime.writeDebugMap(&released_writer));
}

test "Runtime that declines line tables keeps none, and code stays in its reservation" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

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

    const loc = ir.Location.getFile("test.choir", 4, 2);
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "no_lines", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var constant = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 7);
    try entry.addOperation(constant.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{constant.getResult()});
    try entry.addOperation(ret.op);

    var limits = execution.Limits.testing;
    limits.line_tables = false;
    var runtime = try initRuntime(allocator, limits);
    defer runtime.deinit();
    const handle = try runtime.compile(module.op);
    defer runtime.release(handle) catch {};

    const function = runtime.modules.items[handle.index].functions.get("no_lines").?;
    try testing.expect(function.line_table == null);
    try testing.expectEqual(@as(u64, @intFromBool(scalar_only)), runtime.code_fallbacks);

    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try testing.expect(try runtime.writeDebugMap(&writer));
    try testing.expect(std.mem.containsAtLeast(u8, writer.buffered(), 1, "(no line info)"));
}

test "Runtime debug map is best-effort when registration fails" {
    if (execution.native.Target.unavailable != null or scalar_only) return error.SkipZigTest;

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    if (!debug_info.supportsJitDebugInfo(sys.capabilities.current.arch)) {
        return error.SkipZigTest;
    }

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();

    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const loc = ir.Location.getFile("test.choir", 1, 1);
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "debug_map_fail", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var constant = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 1);
    try entry.addOperation(constant.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{constant.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try initRuntime(allocator, .testing);
    defer runtime.deinit();
    _ = try runtime.compile(module.op);

    failing.fail_index = failing.alloc_index;

    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const emitted = try runtime.writeDebugMap(&writer);
    const output = writer.buffered();

    try testing.expect(emitted);
    try testing.expect(failing.has_induced_failure);
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "debug_map_fail"));
}

test "Runtime admits external symbols at each preset, built-ins included, and refuses one past" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    for ([_]execution.Limits{ .testing, .standard }) |limits| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var runtime = try initRuntime(failing.allocator(), limits);
        defer runtime.deinit();
        try testing.expectEqual(@as(u32, builtin_count), runtime.external_symbols.count());
        var name: [32]u8 = undefined;
        for (builtin_count..limits.external_symbols) |index| {
            const symbol = try std.fmt.bufPrint(&name, "external_{d}", .{index});
            try runtime.registerExternalSymbol(symbol, index + 1);
        }
        try testing.expectEqual(limits.external_symbols, runtime.external_symbols.count());
        const bytes = failing.allocated_bytes - failing.freed_bytes;
        const allocations = failing.alloc_index;
        const metadata = runtime.external_symbols.metadata;
        const table_capacity = runtime.external_symbols.capacity();
        var first_buffer: [32]u8 = undefined;
        const first_symbol = try std.fmt.bufPrint(&first_buffer, "external_{d}", .{builtin_count});
        const first_name = runtime.external_symbols.getEntry(first_symbol).?.key_ptr.*.ptr;

        try testing.expectError(
            error.JitRuntimeFull,
            runtime.registerExternalSymbol("one_past", 1),
        );
        const refusal = runtime.refusal.?;
        try testing.expectEqual(execution.Refusal.Limit.external_symbols, refusal.limit);
        try testing.expectEqual(@as(u64, limits.external_symbols), refusal.bound);
        try testing.expectEqual(@as(u64, limits.external_symbols), refusal.in_use);
        try testing.expectEqual(@as(u64, 1), refusal.requested);
        try testing.expectEqual(limits.external_symbols, runtime.external_symbols.count());
        try testing.expect(!runtime.external_symbols.contains("one_past"));
        try testing.expectEqual(bytes, failing.allocated_bytes - failing.freed_bytes);
        try testing.expectEqual(allocations, failing.alloc_index);
        try testing.expectEqual(metadata, runtime.external_symbols.metadata);
        try testing.expectEqual(table_capacity, runtime.external_symbols.capacity());

        failing.fail_index = failing.alloc_index;
        try runtime.registerExternalSymbol(first_symbol, 99);
        try testing.expectEqual(@as(?usize, 99), runtime.external_symbols.get(first_symbol));
        try testing.expectEqual(
            first_name,
            runtime.external_symbols.getEntry(first_symbol).?.key_ptr.*.ptr,
        );
        try testing.expectEqual(limits.external_symbols, runtime.external_symbols.count());
        try testing.expectEqual(allocations, failing.alloc_index);
        try testing.expectEqual(bytes, failing.allocated_bytes - failing.freed_bytes);
    }
}

test "Runtime failed external registration preserves storage and permits retry" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    var limits: execution.Limits = .testing;
    limits.external_symbols = 4 * builtin_count + 8;
    for (0..2) |fail_offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var runtime = try initRuntime(failing.allocator(), limits);
        defer runtime.deinit();
        try runtime.registerExternalSymbol("external_0", 1);
        const first = runtime.external_symbols.count() - 1;
        const initial_entries = runtime.external_symbols.capacity() *
            std.hash_map.default_max_load_percentage / 100;
        try testing.expect(initial_entries < limits.external_symbols);
        var name: [32]u8 = undefined;
        for (first + 1..initial_entries) |index| {
            const symbol = try std.fmt.bufPrint(&name, "external_{d}", .{index - first});
            try runtime.registerExternalSymbol(symbol, index - first + 1);
        }
        const bytes = failing.allocated_bytes - failing.freed_bytes;
        const metadata = runtime.external_symbols.metadata;
        const table_capacity = runtime.external_symbols.capacity();
        failing.fail_index = failing.alloc_index + fail_offset;
        try testing.expectError(
            error.OutOfMemory,
            runtime.registerExternalSymbol("next", initial_entries + 1),
        );
        try testing.expect(failing.has_induced_failure);
        try testing.expectEqual(@as(u32, initial_entries), runtime.external_symbols.count());
        try testing.expect(!runtime.external_symbols.contains("next"));
        try testing.expectEqual(bytes, failing.allocated_bytes - failing.freed_bytes);
        try testing.expectEqual(metadata, runtime.external_symbols.metadata);
        try testing.expectEqual(table_capacity, runtime.external_symbols.capacity());
        for (0..initial_entries - first) |index| {
            const symbol = try std.fmt.bufPrint(&name, "external_{d}", .{index});
            try testing.expectEqual(@as(?usize, index + 1), runtime.external_symbols.get(symbol));
        }
        failing.fail_index = std.math.maxInt(usize);
        try runtime.registerExternalSymbol("next", initial_entries + 1);
        try testing.expectEqual(@as(u32, initial_entries + 1), runtime.external_symbols.count());
        try testing.expectEqual(
            @as(?usize, initial_entries + 1),
            runtime.external_symbols.get("next"),
        );
    }
}

test "Runtime zero external symbol limit refuses before allocating" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    var limits: execution.Limits = .testing;
    limits.external_symbols = 0;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    if (builtin_count != 0) {
        try testing.expectError(error.JitRuntimeFull, initRuntime(failing.allocator(), limits));
    } else {
        var runtime = try initRuntime(failing.allocator(), limits);
        defer runtime.deinit();
        try testing.expectError(error.JitRuntimeFull, runtime.registerExternalSymbol("first", 1));
        try testing.expectEqual(@as(u32, 0), runtime.external_symbols.count());
    }
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expect(!failing.has_induced_failure);
}

/// Forwards to `child`, overwriting every byte it gives back before returning it, so a pointer
/// kept past a free reads the pattern rather than the old contents.
const Poisoning = struct {
    child: std.mem.Allocator,

    const pattern: u8 = 0xa5;

    fn allocator(self: *Poisoning) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Poisoning = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(len, alignment, ret);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        len: usize,
        ret: usize,
    ) bool {
        const self: *Poisoning = @ptrCast(@alignCast(context));
        if (len >= memory.len) return self.child.rawResize(memory, alignment, len, ret);
        if (!self.child.rawResize(memory, alignment, len, ret)) return false;
        @memset(memory[len..], pattern);
        return true;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Poisoning = @ptrCast(@alignCast(context));
        @memset(memory, pattern);
        self.child.rawFree(memory, alignment, ret);
    }
};

test "aarch64 native execution Runtime keeps a module callable after its context is poisoned" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    const Constant = *const fn () callconv(.c) i64;
    var runtime = try initRuntime(testing.allocator, .testing);
    defer runtime.deinit();

    var poisoning = Poisoning{ .child = testing.allocator };
    const handle = handle: {
        const context_allocator = poisoning.allocator();
        var ctx = try ir.Context.init(context_allocator, ir.Context.Limits.testing);
        defer ctx.deinit(context_allocator);
        try dialects.registerAllDialects(&ctx);
        const module = try fixture.constantModule(&ctx, "survivor", 29);
        if (!scalar_only)
            try fixture.addFunction(module, try fixture.callingFunction(&ctx, "caller", "survivor"));
        const compiled = try runtime.compile(module);
        if (!scalar_only) {
            const caller = try runtime.getFunction(compiled, "caller", Constant);
            try testing.expectEqual(@as(i64, 29), caller());
        }
        break :handle compiled;
    };

    const survivor = try runtime.getFunction(handle, "survivor", Constant);
    try testing.expectEqual(@as(i64, 29), survivor());
    if (!scalar_only) {
        const caller = try runtime.getFunction(handle, "caller", Constant);
        try testing.expectEqual(@as(i64, 29), caller());
    }
    const signature = try runtime.functionSignature(handle, "survivor");
    try testing.expect(signature.eql(&fixture.nullary_integer));

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try testing.expect(try runtime.writeDebugMap(&writer));
    const map = writer.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, map, 1, "fn survivor "));
    if (scalar_only) {
        try testing.expect(std.mem.containsAtLeast(u8, map, 1, "(no line info)"));
    } else {
        try testing.expect(std.mem.containsAtLeast(u8, map, 1, "temporary-jit.choir:1:1"));
        try testing.expect(std.mem.containsAtLeast(u8, map, 1, "op=arith.constant"));
    }
    try testing.expect(std.mem.indexOfScalar(u8, map, Poisoning.pattern) == null);

    try runtime.release(handle);
    try testing.expectEqual(@as(u32, 0), runtime.live_modules);
    try testing.expectEqual(@as(u64, 0), runtime.mapped_bytes);
}

test "aarch64 native execution Runtime checked entries allocate nothing" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try fixture.constantModule(&ctx, "value", 11);
    defer module.erase();

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var runtime = try initRuntime(failing.allocator(), .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(module);

    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    const value = try runtime.getFunction(handle, "value", *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 11), value());
    var results = [_]execution.Value{.{ .i64 = 0 }};
    try runtime.call(handle, "value", &.{}, &results);
    try testing.expectEqual(@as(i64, 11), results[0].i64);
    _ = try runtime.functionAddress(handle, "value");
    _ = try runtime.functionSignature(handle, "value");

    try testing.expectEqual(allocations, failing.alloc_index);
    try testing.expect(!failing.has_induced_failure);
}

var counted_calls: u32 = 0;

fn countedIncrement(value: i64) callconv(.c) i64 {
    counted_calls += 1;
    return value + 1;
}

test "aarch64 native execution Runtime refuses wrong calls before entering" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer module.op.erase();
    if (!scalar_only) {
        const declaration = try FuncDialect.FuncOp.createDeclaration(
            &ctx,
            loc,
            "counted_increment",
            &.{i64_type},
            &.{i64_type},
        );
        try module.getBodyBlock().addOperation(declaration.op);
    }
    const counted = try FuncDialect.FuncOp.create(&ctx, loc, "counted", &.{i64_type}, &.{i64_type});
    try module.getBodyBlock().addOperation(counted.op);
    const value = if (scalar_only)
        counted.getArgument(0)
    else blk: {
        const call = try FuncDialect.CallOp.create(
            &ctx,
            loc,
            "counted_increment",
            &.{counted.getArgument(0)},
            &.{i64_type},
        );
        try counted.getEntryBlock().addOperation(call.op);
        break :blk call.getResult(0).?;
    };
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{value});
    try counted.getEntryBlock().addOperation(ret.op);

    var runtime = try initRuntime(testing.allocator, .testing);
    defer runtime.deinit();
    if (!scalar_only)
        try runtime.registerExternalSymbol("counted_increment", @intFromPtr(&countedIncrement));
    const handle = try runtime.compile(module.op);
    counted_calls = 0;

    var one = [_]execution.Value{.{ .i64 = 0 }};
    var none = [_]execution.Value{};
    const no_arguments = runtime.call(handle, "counted", &.{}, &one);
    try testing.expectError(error.SignatureMismatch, no_arguments);
    const two = [_]execution.Value{ .{ .i64 = 1 }, .{ .i64 = 2 } };
    const two_arguments = runtime.call(handle, "counted", &two, &one);
    try testing.expectError(error.SignatureMismatch, two_arguments);
    const narrow = runtime.call(handle, "counted", &.{.{ .i32 = 1 }}, &one);
    try testing.expectError(error.SignatureMismatch, narrow);
    const no_results = runtime.call(handle, "counted", &.{.{ .i64 = 1 }}, &none);
    try testing.expectError(error.SignatureMismatch, no_results);
    const unsigned = [_]execution.Value{.{ .u64 = 1 }};
    const unsigned_call = runtime.call(handle, "counted", &unsigned, &one);
    try testing.expectError(error.SignatureMismatch, unsigned_call);
    const Nullary = *const fn () callconv(.c) i64;
    const nullary = runtime.getFunction(handle, "counted", Nullary);
    try testing.expectError(error.SignatureMismatch, nullary);
    if (!scalar_only) try testing.expectEqual(@as(u32, 0), counted_calls);

    try runtime.call(handle, "counted", &.{.{ .i64 = 41 }}, &one);
    try testing.expectEqual(@as(i64, if (scalar_only) 41 else 42), one[0].i64);
    if (!scalar_only) try testing.expectEqual(@as(u32, 1), counted_calls);
}

/// A module that fails verification: `mismatched` raises an f32 base to an f64 exponent.
fn unverifiedModule(ctx: *ir.Context) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const f32_type = try ArithDialect.getScalarType(ctx, .f32);
    const f64_type = try ArithDialect.getScalarType(ctx, .f64);
    const mismatched = try FuncDialect.FuncOp.create(ctx, loc, "mismatched", &.{}, &.{f32_type});
    try module.getBodyBlock().addOperation(mismatched.op);
    const body = mismatched.getEntryBlock();
    const base = try ArithDialect.ConstantOp.createFloat(ctx, loc, f32_type, 2.0);
    try body.addOperation(base.op);
    const exponent = try ArithDialect.ConstantOp.createFloat(ctx, loc, f64_type, 3.0);
    try body.addOperation(exponent.op);
    const power = try ArithDialect.PowOp.create(ctx, loc, base.getResult(), exponent.getResult());
    try body.addOperation(power.op);
    const returned = try FuncDialect.ReturnOp.create(ctx, loc, &.{power.getResult()});
    try body.addOperation(returned.op);
    return module.op;
}

test "aarch64 native execution Runtime refusals preserve earlier callable code and budgets" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const Constant = *const fn () callconv(.c) i64;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    var reports = diagnostics.CaptureBuffer.init(testing.allocator);
    defer reports.deinit();
    var capture = ctx.captureDiagnostics(&reports);
    var guard = capture.enter();
    defer guard.deinit();

    var limits: execution.Limits = .testing;
    limits.live_modules = 2;
    var runtime = try initRuntime(testing.allocator, limits);
    defer runtime.deinit();
    const kept_module = try fixture.constantModule(&ctx, "kept", 17);
    defer kept_module.erase();
    const kept = try runtime.compile(kept_module);
    const kept_value = try runtime.getFunction(kept, "kept", Constant);
    const live = runtime.live_modules;
    const mapped = runtime.mapped_bytes;
    const slots = runtime.modules.items.len;

    const loc = ir.Location.getUnknown();
    const unverified = try unverifiedModule(&ctx);
    defer unverified.erase();
    try testing.expectError(error.VerificationFailed, runtime.compile(unverified));

    if (!scalar_only) {
        const unresolved = try fixture.constantModule(&ctx, "entry", 1);
        defer unresolved.erase();
        const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
        const absent =
            try FuncDialect.FuncOp.createDeclaration(&ctx, loc, "absent", &.{}, &.{i64_type});
        try fixture.addFunction(unresolved, absent.op);
        try fixture.addFunction(unresolved, try fixture.callingFunction(&ctx, "orphan", "absent"));
        try testing.expectError(error.SymbolNotFound, runtime.compile(unresolved));
    }

    const code = @as([16]u8, @splat(0));
    var foreign = try artifact.machineCodeArtifact(
        testing.allocator,
        .{ .architecture = .unknown },
        execution.native.Target.abi,
        "foreign",
        fixture.nullary_integer,
        &code,
        &.{},
        &.{},
    );
    defer foreign.deinit();
    try testing.expectError(error.InvalidArtifact, runtime.loadArtifact(&foreign));

    try testing.expectEqual(live, runtime.live_modules);
    try testing.expectEqual(mapped, runtime.mapped_bytes);
    try testing.expectEqual(slots, runtime.modules.items.len);
    try testing.expectEqual(@as(i64, 17), kept_value());
    try testing.expectEqual(@as(?execution.Refusal, null), runtime.refusal);
}

test "Runtime records a refused module with its bound, holding and request" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    const Constant = *const fn () callconv(.c) i64;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);

    var limits: execution.Limits = .testing;
    limits.live_modules = 2;
    var runtime = try initRuntime(testing.allocator, limits);
    defer runtime.deinit();
    const kept_module = try fixture.constantModule(&ctx, "kept", 17);
    defer kept_module.erase();
    const kept = try runtime.compile(kept_module);
    const kept_value = try runtime.getFunction(kept, "kept", Constant);
    const mapped = runtime.mapped_bytes;

    const filler_module = try fixture.constantModule(&ctx, "filler", 3);
    defer filler_module.erase();
    const filler = try runtime.compile(filler_module);
    const full_mapped = runtime.mapped_bytes;
    try testing.expectError(error.JitRuntimeFull, runtime.compile(filler_module));
    const refusal = runtime.refusal.?;
    try testing.expectEqual(execution.Refusal.Limit.live_modules, refusal.limit);
    try testing.expectEqual(@as(u64, 2), refusal.bound);
    try testing.expectEqual(@as(u64, 2), refusal.in_use);
    try testing.expectEqual(@as(u64, 1), refusal.requested);
    try testing.expectEqual(full_mapped, runtime.mapped_bytes);
    try testing.expectEqual(@as(i64, 17), kept_value());
    try runtime.release(filler);
    try testing.expectEqual(mapped, runtime.mapped_bytes);
    try testing.expectEqual(@as(i64, 17), (try runtime.getFunction(kept, "kept", Constant))());
}

test "Runtime records a refused mapping with its budget, holding and charge" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try fixture.constantModule(&ctx, "entry", 4);
    defer module.erase();

    const page = sys.memory.pageAlign(1).?;
    var limits: execution.Limits = .testing;
    limits.mapped_bytes = page;
    var runtime = try initRuntime(testing.allocator, limits);
    defer runtime.deinit();
    _ = try runtime.compile(module);
    try testing.expectError(error.JitRuntimeFull, runtime.compile(module));
    const refusal = runtime.refusal.?;
    try testing.expectEqual(execution.Refusal.Limit.mapped_bytes, refusal.limit);
    try testing.expectEqual(@as(u64, page), refusal.bound);
    try testing.expectEqual(@as(u64, page), refusal.in_use);
    try testing.expectEqual(@as(u64, page), refusal.requested);
}

test "Runtime init refuses limits below its built-in names and leaks nothing" {
    if (execution.native.Target.unavailable != null) return error.SkipZigTest;
    if (builtin_count == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    try std.testing.expect(builtin_count <= execution.Limits.testing.external_symbols);
    var limits: execution.Limits = .testing;
    limits.external_symbols = builtin_count - 1;
    try std.testing.expectError(error.JitRuntimeFull, initRuntime(allocator, limits));

    limits.external_symbols = builtin_count;
    var runtime = try initRuntime(allocator, limits);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(u32, builtin_count), runtime.external_symbols.count());
    const extra = runtime.registerExternalSymbol("host_extra", 1);
    try std.testing.expectError(error.JitRuntimeFull, extra);
    const first = execution.native.Target.builtin(0);
    try runtime.registerExternalSymbol(first.name, first.address);
    try std.testing.expectEqual(@as(u32, builtin_count), runtime.external_symbols.count());
}
