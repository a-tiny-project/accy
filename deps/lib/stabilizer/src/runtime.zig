const std = @import("std");

const config = @import("config.zig");
const code_mod = @import("code.zig");
const CodeRandomizer = code_mod.CodeRandomizer;
const ShuffleAllocator = @import("heap.zig").ShuffleAllocator;
const Marsaglia = @import("rng.zig").Marsaglia;
const stack = @import("stack.zig");

const Allocator = std.mem.Allocator;

pub const ConstructorFn = *const fn () callconv(.c) void;

pub const Runtime = struct {
    allocator: Allocator,
    config: config.Config,
    heap: ShuffleAllocator,
    stack: stack.StackPads,
    code: CodeRandomizer,
    rng: Marsaglia,
    stack_pad_slots: std.ArrayListUnmanaged(*u8) = .empty,
    constructors: std.ArrayListUnmanaged(ConstructorFn) = .empty,

    pub fn init(allocator: Allocator, runtime_config: config.Config) !Runtime {
        var rng = Marsaglia.init(runtime_config.seed);
        var stack_pads = try stack.StackPads.init(allocator, runtime_config.stack, &rng);
        errdefer stack_pads.deinit();
        return .{
            .allocator = allocator,
            .config = runtime_config,
            .heap = ShuffleAllocator.init(allocator, runtime_config.heap, runtime_config.seed ^ 0x4845_4150),
            .stack = stack_pads,
            .code = CodeRandomizer.init(allocator, runtime_config.code, runtime_config.seed ^ 0x434f_4445),
            .rng = rng,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.constructors.deinit(self.allocator);
        self.stack_pad_slots.deinit(self.allocator);
        self.code.deinit();
        self.stack.deinit();
        self.heap.deinit();
        self.* = undefined;
    }

    pub fn randomizedAllocator(self: *Runtime) Allocator {
        return self.heap.allocator();
    }

    pub fn malloc(self: *Runtime, len: usize) ![*]u8 {
        return self.heap.malloc(len);
    }

    pub fn calloc(self: *Runtime, count: usize, len: usize) ![*]u8 {
        return self.heap.calloc(count, len);
    }

    pub fn realloc(self: *Runtime, ptr: ?[*]u8, new_len: usize) !?[*]u8 {
        return self.heap.realloc(ptr, new_len);
    }

    pub fn free(self: *Runtime, ptr: ?[*]u8) void {
        self.heap.freePointer(ptr);
    }

    pub fn freeIfOwned(self: *Runtime, ptr: ?[*]u8) bool {
        return self.heap.freePointerIfOwned(ptr);
    }

    pub fn ownsPointer(self: *const Runtime, ptr: ?[*]u8) bool {
        return self.heap.ownsPointer(ptr);
    }

    pub fn registerStackPad(self: *Runtime, slot: *u8) !void {
        for (self.stack_pad_slots.items) |existing| {
            if (existing == slot) return;
        }
        try self.stack_pad_slots.append(self.allocator, slot);
    }

    pub fn registeredStackPadCount(self: *const Runtime) usize {
        return self.stack_pad_slots.items.len;
    }

    pub fn registerConstructor(self: *Runtime, constructor: ConstructorFn) !void {
        try self.constructors.append(self.allocator, constructor);
    }

    pub fn constructorCount(self: *const Runtime) usize {
        return self.constructors.items.len;
    }

    pub fn runConstructors(self: *Runtime) void {
        for (self.constructors.items) |constructor| constructor();
    }

    pub fn registerFunctionRange(self: *Runtime, options: code_mod.FunctionRangeOptions) !code_mod.FunctionId {
        return self.code.registerFunctionRange(options);
    }

    pub fn enterFunction(self: *Runtime, id: code_mod.FunctionId, roots: []const usize) !?usize {
        const location = try self.code.enterFunction(id, roots);
        return if (location) |active| active.base else null;
    }

    pub fn trapFunction(self: *Runtime, id: code_mod.FunctionId, roots: []const usize) !usize {
        const location = try self.code.trap(id, roots);
        return location.base;
    }

    pub fn adjustAddress(self: *const Runtime, address: usize) usize {
        return self.code.adjustAddress(address);
    }

    pub fn adjustBacktrace(self: *const Runtime, adjusted: []usize, real: []const usize) []usize {
        const count = @min(adjusted.len, real.len);
        for (real[0..count], adjusted[0..count]) |address, *out| {
            out.* = self.adjustAddress(address);
        }
        return adjusted[0..count];
    }

    pub fn runProgram(self: *Runtime, main: anytype, args: anytype) @TypeOf(@call(.auto, main, args)) {
        self.code.trapRegisteredFunctions();
        self.runConstructors();
        return @call(.auto, main, args);
    }

    pub fn nextStackPad(self: *Runtime) stack.StackPad {
        return self.stack.next(&self.rng);
    }

    pub fn rerandomize(self: *Runtime) void {
        _ = self.rerandomizeAt(0);
    }

    pub fn rerandomizeAt(self: *Runtime, instruction_pointer: usize) usize {
        if (self.config.code.enabled) {
            if (self.code.functionCount() == 0) self.rerandomizeStackPads();
            return self.code.beginRerandomizationAt(instruction_pointer);
        } else {
            self.rerandomizeStackPads();
            return instruction_pointer;
        }
    }

    fn rerandomizeStackPads(self: *Runtime) void {
        if (!self.config.stack.enabled) return;
        self.stack.refill(&self.rng);
        for (self.stack_pad_slots.items) |slot| {
            slot.* = self.rng.nextByte();
        }
    }
};

test "runtime rerandomizes registered stack pad slots" {
    const seed = 9;
    var expected_rng = Marsaglia.init(seed);
    _ = expected_rng.nextByte();

    var runtime = try Runtime.init(std.testing.allocator, .{
        .seed = seed,
        .stack = .{ .entries = 1 },
        .code = .{ .enabled = false },
    });
    defer runtime.deinit();

    var first: u8 = 0;
    var second: u8 = 0;
    try runtime.registerStackPad(&first);
    try runtime.registerStackPad(&second);
    try runtime.registerStackPad(&first);
    try std.testing.expectEqual(@as(usize, 2), runtime.registeredStackPadCount());

    const expected_stack = expected_rng.nextByte();
    const expected_first = expected_rng.nextByte();
    const expected_second = expected_rng.nextByte();

    runtime.rerandomize();

    try std.testing.expectEqual(expected_stack, runtime.nextStackPad().unit);
    try std.testing.expectEqual(expected_first, first);
    try std.testing.expectEqual(expected_second, second);
}

test "runtime rerandomize forwards interrupts at live function entries" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .seed = 9,
        .code = .{ .enabled = true },
    });
    defer runtime.deinit();

    const active = try runtime.code.registerFunction(.{ .code_size = 64 });
    const inactive = try runtime.code.registerFunction(.{ .code_size = 64 });
    const active_base = (try runtime.enterFunction(active, &.{})).?;
    const active_original = runtime.code.originalBase(active).?;
    const inactive_original = runtime.code.originalBase(inactive).?;

    try std.testing.expectEqual(active_base, runtime.rerandomizeAt(active_original));
    try std.testing.expectEqual(code_mod.FunctionEntryState.trap, runtime.code.entryState(active).?);
    try std.testing.expectEqual(code_mod.FunctionEntryState.trap, runtime.code.entryState(inactive).?);
    try std.testing.expect(runtime.code.rerandomizing);
    try std.testing.expectEqual(@as(usize, 0), runtime.code.live.items.len);
    try std.testing.expectEqual(active_original + 1, runtime.rerandomizeAt(active_original + 1));
    try std.testing.expectEqual(inactive_original, runtime.rerandomizeAt(inactive_original));
}

test "runtime rerandomizeAt preserves instruction pointer in stack-only mode" {
    const seed = 9;
    var expected_rng = Marsaglia.init(seed);
    _ = expected_rng.nextByte();

    var runtime = try Runtime.init(std.testing.allocator, .{
        .seed = seed,
        .stack = .{ .entries = 1 },
        .code = .{ .enabled = false },
    });
    defer runtime.deinit();

    const expected_stack = expected_rng.nextByte();
    try std.testing.expectEqual(@as(usize, 0x1234), runtime.rerandomizeAt(0x1234));
    try std.testing.expectEqual(expected_stack, runtime.nextStackPad().unit);
}

test "runtime enterFunction relocates traps and preserves rooted code locations" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .code = .{ .enabled = true },
    });
    defer runtime.deinit();

    const first = try runtime.code.registerFunction(.{ .code_size = 64 });
    const second = try runtime.code.registerFunction(.{ .code_size = 64 });
    const second_original = runtime.code.originalBase(second).?;

    const first_base = (try runtime.enterFunction(first, &.{})).?;
    const second_base = (try runtime.enterFunction(second, &.{})).?;

    runtime.rerandomize();
    const second_next = (try runtime.enterFunction(second, &.{first_base})).?;
    try std.testing.expect(second_next != second_base);
    try std.testing.expectEqual(second_original, runtime.adjustAddress(second_base));

    runtime.rerandomize();
    _ = try runtime.enterFunction(first, &.{second_base});
    try std.testing.expectEqual(second_original, runtime.adjustAddress(second_base));

    runtime.rerandomize();
    _ = try runtime.enterFunction(first, &.{});
    try std.testing.expectEqual(second_base, runtime.adjustAddress(second_base));
}

test "runtime adjusts relocated addresses back to original code" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .code = .{ .shuffle_slots = 4 },
    });
    defer runtime.deinit();

    const function = try runtime.code.registerFunction(.{
        .code_size = 64,
        .table_size = 16,
        .table_adjacent = true,
    });
    const original = runtime.code.originalBase(function).?;
    const first = try runtime.code.relocate(function);
    const first_base = first.base;
    const first_size = first.size;
    try std.testing.expectEqual(original + 5, runtime.adjustAddress(first_base + 5));
    try std.testing.expectEqual(original + 70, runtime.adjustAddress(first_base + 70));

    const unrelated = first_base + first_size + 1024;
    try std.testing.expectEqual(unrelated, runtime.adjustAddress(unrelated));

    const second = try runtime.code.relocate(function);
    const second_base = second.base;
    try std.testing.expectEqual(original + 9, runtime.adjustAddress(first_base + 9));
    try std.testing.expectEqual(original + 9, runtime.adjustAddress(second_base + 9));

    const real_backtrace = [_]usize{ first_base + 1, unrelated, second_base + 2 };
    var adjusted_backtrace: [real_backtrace.len + 1]usize = undefined;
    const adjusted = runtime.adjustBacktrace(adjusted_backtrace[0..], real_backtrace[0..]);
    try std.testing.expectEqual(@as(usize, real_backtrace.len), adjusted.len);
    try std.testing.expectEqual(original + 1, adjusted[0]);
    try std.testing.expectEqual(unrelated, adjusted[1]);
    try std.testing.expectEqual(original + 2, adjusted[2]);

    const truncated = runtime.adjustBacktrace(adjusted_backtrace[0..1], real_backtrace[0..]);
    try std.testing.expectEqual(@as(usize, 1), truncated.len);
    try std.testing.expectEqual(original + 1, truncated[0]);

    runtime.code.sweep();
    try std.testing.expectEqual(first_base + 9, runtime.adjustAddress(first_base + 9));
    try std.testing.expectEqual(original + 9, runtime.adjustAddress(second_base + 9));
}

var constructor_trace: [64]u8 = undefined;
var constructor_trace_len: usize = 0;

fn resetConstructorTrace() void {
    @memset(&constructor_trace, 0);
    constructor_trace_len = 0;
}

fn appendConstructorTrace(value: u8) void {
    constructor_trace[constructor_trace_len] = value;
    constructor_trace_len += 1;
}

fn traceConstructor1() callconv(.c) void {
    appendConstructorTrace(1);
}

fn traceConstructor2() callconv(.c) void {
    appendConstructorTrace(2);
}

fn traceConstructor3() callconv(.c) void {
    appendConstructorTrace(3);
}

fn traceProgramMain() u8 {
    appendConstructorTrace(9);
    return 42;
}

test "runtime runs registered constructors in insertion order" {
    resetConstructorTrace();

    var runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    try runtime.registerConstructor(traceConstructor2);
    try runtime.registerConstructor(traceConstructor1);
    try runtime.registerConstructor(traceConstructor2);
    try std.testing.expectEqual(@as(usize, 3), runtime.constructorCount());

    runtime.runConstructors();

    try std.testing.expectEqual(@as(usize, 3), constructor_trace_len);
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 2 }, constructor_trace[0..constructor_trace_len]);
}

test "runtime arms code and runs constructors before program main" {
    resetConstructorTrace();

    var runtime = try Runtime.init(std.testing.allocator, .{
        .code = .{ .enabled = true },
    });
    defer runtime.deinit();

    const function = try runtime.code.registerFunction(.{ .code_size = 64 });
    _ = try runtime.enterFunction(function, &.{});
    try std.testing.expectEqual(code_mod.FunctionEntryState.forwarding, runtime.code.entryState(function).?);

    try runtime.registerConstructor(traceConstructor1);
    try runtime.registerConstructor(traceConstructor3);
    const result = runtime.runProgram(traceProgramMain, .{});

    try std.testing.expectEqual(@as(u8, 42), result);
    try std.testing.expectEqual(code_mod.FunctionEntryState.trap, runtime.code.entryState(function).?);
    try std.testing.expectEqual(@as(usize, 0), runtime.code.live.items.len);
    try std.testing.expect(!runtime.code.rerandomizing);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 9 }, constructor_trace[0..constructor_trace_len]);
}
