//! The libSystem functions an arm64 Mach-O product may import, each with the C
//! type a producer must declare for it. A product cannot promise a callable type
//! for a function this table does not name, or another type for one it does.
//! The table checks the declared type and not the object's call sites: a
//! relocation carries no type, so each call is trusted to follow its declaration.
const std = @import("std");
const root = @import("../../root.zig");
const Policy = root.model.MachOExecutablePolicy;
const Callable = Policy.Callable;

/// AAPCS64 passes the first eight integer and pointer arguments in x0 to x7
/// and the first eight floating arguments in v0 to v7. Products are arm64
/// only, so these are the bounds; a further argument would go on the stack.
pub const general_argument_registers = 8;
pub const floating_argument_registers = 8;

const f64_unary: Callable = .{ .result = .f64, .params = &.{.f64} };
const f64_binary: Callable = .{ .result = .f64, .params = &.{ .f64, .f64 } };
const f32_unary: Callable = .{ .result = .f32, .params = &.{.f32} };
const f32_binary: Callable = .{ .result = .f32, .params = &.{ .f32, .f32 } };

/// `pid_t getpid(void)`, the heap pair, and the libm functions Choir's arm64
/// objects call for exp, log, sin, cos, tan, tanh and pow at both widths.
pub const functions = [_]Policy.Import{
    .{ .name = "_getpid", .signature = .{ .result = .i32, .params = &.{} } },
    .{ .name = "_malloc", .signature = .{ .result = .pointer, .params = &.{.usize} } },
    .{ .name = "_free", .signature = .{ .result = null, .params = &.{.pointer} } },
    .{ .name = "_exp", .signature = f64_unary },
    .{ .name = "_log", .signature = f64_unary },
    .{ .name = "_sin", .signature = f64_unary },
    .{ .name = "_cos", .signature = f64_unary },
    .{ .name = "_tan", .signature = f64_unary },
    .{ .name = "_tanh", .signature = f64_unary },
    .{ .name = "_pow", .signature = f64_binary },
    .{ .name = "_expf", .signature = f32_unary },
    .{ .name = "_logf", .signature = f32_unary },
    .{ .name = "_sinf", .signature = f32_unary },
    .{ .name = "_cosf", .signature = f32_unary },
    .{ .name = "_tanf", .signature = f32_unary },
    .{ .name = "_tanhf", .signature = f32_unary },
    .{ .name = "_powf", .signature = f32_binary },
};

comptime {
    for (functions, 0..) |function, index| {
        std.debug.assert(passesInRegisters(function.signature));
        for (functions[0..index]) |earlier| std.debug.assert(!std.mem.eql(u8, earlier.name, function.name));
    }
}

/// Whether every argument of `callable` travels in an AAPCS64 argument register.
pub fn passesInRegisters(callable: Callable) bool {
    var general: usize = 0;
    var floating: usize = 0;
    for (callable.params) |param| switch (param) {
        .i32, .usize, .pointer => general += 1,
        .f32, .f64 => floating += 1,
    };
    return general <= general_argument_registers and floating <= floating_argument_registers;
}

/// Whether `import` names a function in the table with exactly the type the table states.
pub fn admits(import: Policy.Import) bool {
    if (!passesInRegisters(import.signature)) return false;
    for (functions) |function| {
        if (std.mem.eql(u8, function.name, import.name)) return function.signature.eql(import.signature);
    }
    return false;
}
