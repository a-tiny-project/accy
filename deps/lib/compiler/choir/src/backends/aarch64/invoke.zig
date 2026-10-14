//! Checked scalar and borrowed-address entry into Apple arm64 code.
//!
//! Integer/address and homogeneous f32 or f64 arguments use independent x0..x7
//! and s0..s7 or d0..d7 banks.
//! Extra physical arguments are zero; no admitted signature needs stack arguments.

const std = @import("std");
const artifact = @import("../root.zig").artifact;
const generated = @import("../execution/entry.zig");
const values = @import("../execution/value.zig");

const Signature = artifact.Signature;
const Value = values.Value;

fn Entry(comptime Float: type, comptime Return: type) type {
    return *const fn (u64, u64, u64, u64, u64, u64, u64, u64, Float, Float, Float, Float, Float, Float, Float, Float) callconv(.c) Return;
}

/// The runtime checked the signature and value types before this call.
pub fn call(address: usize, signature: *const Signature, args: []const Value, results: []Value) void {
    std.debug.assert(address != 0);
    std.debug.assert(args.len <= 8);
    std.debug.assert(results.len <= 1);
    std.debug.assert(values.agrees(signature, args, results));
    // The qualified product promises FPCR==0 throughout generated calls and
    // callbacks. This assertion catches a broken caller in checked builds;
    // the ABI bridge never changes thread-global floating state itself.
    if (hasFloating(signature)) std.debug.assert(defaultFpcr());

    if (floatWidth(signature) == .f32)
        callBridge(f32, address, signature, args, results)
    else
        callBridge(f64, address, signature, args, results);
}

fn callBridge(comptime Float: type, address: usize, signature: *const Signature, args: []const Value, results: []Value) void {
    var words: [8]u64 = @splat(0);
    var floats: [8]Float = @splat(0);
    var word_count: usize = 0;
    var float_count: usize = 0;
    for (args) |arg| switch (arg) {
        .f32 => |number| {
            floats[float_count] = @floatCast(number);
            float_count += 1;
        },
        .f64 => |number| {
            floats[float_count] = @floatCast(number);
            float_count += 1;
        },
        else => {
            words[word_count] = wordOf(arg);
            word_count += 1;
        },
    };
    generated.calling();
    if (results.len == 0) {
        const entry: Entry(Float, void) = @ptrFromInt(address);
        entry(words[0], words[1], words[2], words[3], words[4], words[5], words[6], words[7], floats[0], floats[1], floats[2], floats[3], floats[4], floats[5], floats[6], floats[7]);
        return;
    }
    if (signature.results()[0] == .scalar and signature.results()[0].scalar == .f32) {
        const entry: Entry(Float, f32) = @ptrFromInt(address);
        const number = entry(words[0], words[1], words[2], words[3], words[4], words[5], words[6], words[7], floats[0], floats[1], floats[2], floats[3], floats[4], floats[5], floats[6], floats[7]);
        results[0] = .{ .f32 = number };
    } else if (signature.results()[0] == .scalar and signature.results()[0].scalar == .f64) {
        const entry: Entry(Float, f64) = @ptrFromInt(address);
        const number = entry(words[0], words[1], words[2], words[3], words[4], words[5], words[6], words[7], floats[0], floats[1], floats[2], floats[3], floats[4], floats[5], floats[6], floats[7]);
        results[0] = .{ .f64 = number };
    } else {
        const entry: Entry(Float, u64) = @ptrFromInt(address);
        const word = entry(words[0], words[1], words[2], words[3], words[4], words[5], words[6], words[7], floats[0], floats[1], floats[2], floats[3], floats[4], floats[5], floats[6], floats[7]);
        results[0] = valueOf(signature.results()[0], word);
    }
}

fn hasFloating(signature: *const Signature) bool {
    for (signature.parameters()) |parameter| {
        if (parameter == .scalar and (parameter.scalar == .f32 or parameter.scalar == .f64)) return true;
    }
    for (signature.results()) |result| {
        if (result == .scalar and (result.scalar == .f32 or result.scalar == .f64)) return true;
    }
    return false;
}

fn floatWidth(signature: *const Signature) artifact.ScalarType {
    for (signature.parameters()) |parameter| {
        if (parameter == .scalar and (parameter.scalar == .f32 or parameter.scalar == .f64)) return parameter.scalar;
    }
    for (signature.results()) |result| {
        if (result == .scalar and (result.scalar == .f32 or result.scalar == .f64)) return result.scalar;
    }
    return .f64;
}

pub fn defaultFpcr() bool {
    const builtin = @import("builtin");
    if (comptime builtin.cpu.arch == .aarch64) {
        const value = asm volatile ("mrs %[value], fpcr"
            : [value] "=r" (-> usize),
        );
        return value == 0;
    }
    return false;
}

fn wordOf(arg: Value) u64 {
    return switch (arg) {
        inline .i8, .i16, .i32, .i64 => |integer| @bitCast(@as(i64, integer)),
        inline .u8, .u16, .u32, .u64, .index => |integer| integer,
        .bool => |flag| @intFromBool(flag),
        .memref => |address| @intCast(address),
        else => unreachable,
    };
}

fn valueOf(value_type: artifact.ValueType, word: u64) Value {
    return switch (value_type) {
        .scalar => |scalar| switch (scalar) {
            .index => .{ .index = word },
            .bool => .{ .bool = @as(u8, @truncate(word)) != 0 },
            inline .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |tag| blk: {
                const Integer = @FieldType(Value, @tagName(tag));
                const Bits = @Int(.unsigned, @bitSizeOf(Integer));
                break :blk @unionInit(Value, @tagName(tag), @bitCast(@as(Bits, @truncate(word))));
            },
            else => unreachable,
        },
        else => unreachable,
    };
}

fn typedNarrowProbe(signed: i8, unsigned: u8, middle: u16, flag: bool, index: usize) callconv(.c) u16 {
    std.debug.assert(signed == -1);
    std.debug.assert(unsigned == 0xff);
    std.debug.assert(middle == 0x8001);
    std.debug.assert(flag);
    std.debug.assert(index == std.math.maxInt(usize));
    return 0x8001;
}
