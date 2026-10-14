//! Entry into SysV machine code for `execution.Runtime`.
//! A call passes every argument as a 64-bit word through one fixed C function type, then reads
//! each result where the recorded signature returns it. The runtime checks arguments first.

const std = @import("std");
const artifact = @import("../root.zig").artifact;
const dialects = @import("../../dialects/root.zig");
const abi = @import("abi.zig");
const registers = @import("registers/root.zig");
const slot_layout = @import("slots.zig");
const values = @import("../execution/value.zig");

const Signature = artifact.Signature;
const ScalarType = artifact.ScalarType;
const ValueType = artifact.ValueType;
const VectorType = artifact.VectorType;

const Value = values.Value;
const Vector = values.Vector;

const int_words = abi.max_int_arg_regs;
const float_words = abi.max_fp_arg_regs;
const stack_words = 64;

comptime {
    std.debug.assert(Signature.max_parameters + 1 - int_words <= stack_words);
}

const entry_parameter_types = blk: {
    var types: [int_words + float_words + stack_words]type = @splat(u64);
    for (types[int_words..][0..float_words]) |*parameter_type| parameter_type.* = f64;
    break :blk types;
};

fn EntryFn(comptime Return: type) type {
    return @Fn(&entry_parameter_types, &@splat(.{}), Return, .{ .@"callconv" = .c });
}

const EntryArguments = std.meta.ArgsTuple(EntryFn(void));

const Frame = struct {
    ints: [int_words]u64 = @splat(0),
    floats: [float_words]u64 = @splat(0),
    stack: [stack_words]u64 = @splat(0),

    fn place(self: *Frame, location: abi.ValueLocation, word: u64) void {
        switch (location) {
            .int_reg => |register| {
                const index = std.mem.indexOfScalar(registers.GPR, &abi.int_arg_regs, register).?;
                self.ints[index] = word;
            },
            .fp_reg => |register| {
                const index = std.mem.indexOfScalar(registers.XMM, &abi.fp_arg_regs, register).?;
                self.floats[index] = word;
            },
            .stack => |offset| {
                std.debug.assert(offset >= 0);
                const index: usize = @intCast(@divExact(offset, abi.stack_slot_size));
                self.stack[index] = word;
            },
        }
    }

    fn arguments(self: *const Frame) EntryArguments {
        var tuple: EntryArguments = undefined;
        inline for (0..int_words) |index| tuple[index] = self.ints[index];
        inline for (0..float_words) |index| tuple[int_words + index] = @bitCast(self.floats[index]);
        inline for (0..stack_words) |index| {
            tuple[int_words + float_words + index] = self.stack[index];
        }
        return tuple;
    }
};

const ResultWords = struct {
    ints: [abi.max_register_results]u64 = @splat(0),
    floats: [abi.max_register_results]u64 = @splat(0),
};

const Shape = enum { none, int, float, int_int, int_float, float_int, float_float };

const IntInt = extern struct { first: u64, second: u64 };
const IntFloat = extern struct { first: u64, second: f64 };
const FloatInt = extern struct { first: f64, second: u64 };
const FloatFloat = extern struct { first: f64, second: f64 };

/// Calls the function at `address`, whose parameter and result types are `signature`, and stores
/// its results in `results`. `args` and `results` must agree with `signature`, as
/// `execution.check` establishes.
pub fn call(
    address: usize,
    signature: *const Signature,
    args: []const Value,
    results: []Value,
) void {
    std.debug.assert(address != 0);
    std.debug.assert(abi.admitsSignature(signature));
    std.debug.assert(values.agrees(signature, args, results));
    const result_types = signature.results();
    if (result_types.len == 1 and result_types[0] == .vector) {
        results[0] = .{ .vector = callVector(address, signature, args) };
    } else if (abi.returnsThroughRecord(result_types.len)) {
        var record: [Signature.max_results]u64 = @splat(0);
        const frame = pack(signature, @intFromPtr(&record), args);
        _ = enter(address, .none, &frame);
        for (result_types, results, 0..) |result_type, *result, index| {
            std.debug.assert(abi.recordFieldOffset(index) == index * @sizeOf(u64));
            result.* = valueOf(result_type, record[index]);
        }
    } else {
        const frame = pack(signature, null, args);
        const words = enter(address, shapeOf(result_types), &frame);
        readRegisterResults(result_types, words, results);
    }
}

fn pack(signature: *const Signature, hidden: ?usize, args: []const Value) Frame {
    std.debug.assert(args.len == signature.parameter_count);
    const first: usize = @intFromBool(hidden != null);
    const count = first + args.len;
    var names: [Signature.max_parameters + 1][]const u8 = undefined;
    if (hidden != null) names[0] = "arith.index";
    for (signature.parameters(), names[first..count]) |parameter, *name| {
        name.* = typeName(parameter);
    }
    var locations: [Signature.max_parameters + 1]abi.ValueLocation = undefined;
    abi.computeArgLocations(names[0..count], locations[0..count]);
    var frame = Frame{};
    if (hidden) |result_address| frame.place(locations[0], result_address);
    for (args, locations[first..count]) |arg, location| frame.place(location, wordOf(arg));
    return frame;
}

fn enter(address: usize, shape: Shape, frame: *const Frame) ResultWords {
    const arguments = frame.arguments();
    var words = ResultWords{};
    switch (shape) {
        .none => @call(.auto, entryAt(void, address), arguments),
        .int => words.ints[0] = @call(.auto, entryAt(u64, address), arguments),
        .float => words.floats[0] = @bitCast(@call(.auto, entryAt(f64, address), arguments)),
        .int_int => {
            const pair = @call(.auto, entryAt(IntInt, address), arguments);
            words.ints = .{ pair.first, pair.second };
        },
        .int_float => {
            const pair = @call(.auto, entryAt(IntFloat, address), arguments);
            words.ints[0] = pair.first;
            words.floats[0] = @bitCast(pair.second);
        },
        .float_int => {
            const pair = @call(.auto, entryAt(FloatInt, address), arguments);
            words.floats[0] = @bitCast(pair.first);
            words.ints[0] = pair.second;
        },
        .float_float => {
            const pair = @call(.auto, entryAt(FloatFloat, address), arguments);
            words.floats = .{ @bitCast(pair.first), @bitCast(pair.second) };
        },
    }
    return words;
}

fn entryAt(comptime Return: type, address: usize) *const EntryFn(Return) {
    return @ptrFromInt(address);
}

fn shapeOf(result_types: []const ValueType) Shape {
    std.debug.assert(result_types.len <= abi.max_register_results);
    if (result_types.len == 0) return .none;
    const first = abi.classifyType(typeName(result_types[0]));
    if (result_types.len == 1) return switch (first) {
        .integer => .int,
        .floating_point => .float,
    };
    return switch (first) {
        .integer => switch (abi.classifyType(typeName(result_types[1]))) {
            .integer => .int_int,
            .floating_point => .int_float,
        },
        .floating_point => switch (abi.classifyType(typeName(result_types[1]))) {
            .integer => .float_int,
            .floating_point => .float_float,
        },
    };
}

fn readRegisterResults(result_types: []const ValueType, words: ResultWords, results: []Value) void {
    std.debug.assert(result_types.len == results.len);
    std.debug.assert(result_types.len <= abi.max_register_results);
    var names: [abi.max_register_results][]const u8 = undefined;
    for (result_types, names[0..result_types.len]) |result_type, *name| {
        name.* = typeName(result_type);
    }
    var locations: [abi.max_register_results]abi.ValueLocation = undefined;
    abi.computeReturnLocations(names[0..result_types.len], &locations);
    for (result_types, locations[0..result_types.len], results) |result_type, location, *result| {
        const word = switch (location) {
            .int_reg => |register| words.ints[
                std.mem.indexOfScalar(registers.GPR, &abi.int_return_regs, register).?
            ],
            .fp_reg => |register| words.floats[
                std.mem.indexOfScalar(registers.XMM, &abi.fp_return_regs, register).?
            ],
            .stack => unreachable,
        };
        result.* = valueOf(result_type, word);
    }
}

fn callVector(address: usize, signature: *const Signature, args: []const Value) Vector {
    const vector = signature.results()[0].vector;
    std.debug.assert(vector.lanes != 0);
    std.debug.assert(vector.lanes <= VectorType.max_lanes);
    const lane = slot_layout.Slot{ .offset = 0, .width = scalarBits(vector.element), .ext = .unsigned };
    const stride = slot_layout.laneStride(lane);
    var bytes: [VectorType.max_lanes * @sizeOf(u64)]u8 = @splat(0);
    const top = (@as(usize, vector.lanes) - 1) * stride;
    const frame = pack(signature, @intFromPtr(&bytes[top]), args);
    _ = enter(address, .none, &frame);
    var result = Vector{ .element = vector.element, .lanes = vector.lanes, .bits = @splat(0) };
    for (result.bits[0..vector.lanes], 0..) |*bits, index| {
        const below: usize = @intCast(-slot_layout.laneDisplacement(lane, index));
        bits.* = std.mem.readVarInt(u64, bytes[top - below ..][0..stride], .little);
    }
    return result;
}

fn scalarBits(scalar: ScalarType) u8 {
    return switch (scalar) {
        .i8, .u8, .bool => 8,
        .i16, .u16 => 16,
        .i32, .u32, .f32 => 32,
        .i64, .u64, .index, .f64 => 64,
    };
}

fn typeName(value_type: ValueType) []const u8 {
    return switch (value_type) {
        .scalar => |scalar| switch (scalar) {
            inline else => |tag| "arith." ++ @tagName(tag),
        },
        .memref => dialects.MemrefDialect.name,
        .vector => unreachable,
    };
}

fn wordOf(value: Value) u64 {
    return switch (value) {
        inline .i8, .i16, .i32, .i64 => |signed| @bitCast(@as(i64, signed)),
        inline .u8, .u16, .u32, .u64, .index, .memref => |unsigned| unsigned,
        .bool => |flag| @intFromBool(flag),
        .f32 => |float| @as(u32, @bitCast(float)),
        .f64 => |float| @bitCast(float),
        .vector => unreachable,
    };
}

fn valueOf(value_type: ValueType, word: u64) Value {
    switch (value_type) {
        .memref => return .{ .memref = word },
        .vector => unreachable,
        .scalar => |scalar| switch (scalar) {
            .index => return .{ .index = word },
            .f64 => return .{ .f64 = @bitCast(word) },
            .f32 => return .{ .f32 = @bitCast(@as(u32, @truncate(word))) },
            .bool => {
                const byte: u8 = @truncate(word);
                std.debug.assert(byte <= 1);
                return .{ .bool = byte == 1 };
            },
            inline .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |tag| {
                const Integer = @FieldType(Value, @tagName(tag));
                const Bits = @Int(.unsigned, @bitSizeOf(Integer));
                return @unionInit(Value, @tagName(tag), @bitCast(@as(Bits, @truncate(word))));
            },
        },
    }
}
