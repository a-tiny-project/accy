//! Layout, version 1, of a tensor program written as bytes, shared by the encoder and the decoder.
//! A program written by one process has to be read back by another with every type intact, and a
//! reader has to reject bytes it cannot trust, because a reader that took result types from the
//! bytes would trust whatever type the sender wrote, correct or not.
//!
//! A program's bytes (its *wire bytes*) hold a magic number, a version, the program name and its
//! root graph. A graph is written as an operation count, the operations, and the ids of its
//! outputs. Each operation starts with a number that says which kind of operation it is (its *kind
//! code*), then only the fields that `Builder.operation` needs for that kind, so the decoder works
//! out every other result type itself. An operation can repeat a body graph a set number of times,
//! carrying values from one step to the next (a *scan*), and such an operation also writes its
//! length and the ids of its initial values, with its body graph after it. Integers are
//! little-endian, and every list, whether of bytes, ids, dimensions or integers, starts with its
//! length as a 32-bit count.
const std = @import("std");
const tensor = @import("../root.zig");

const program = tensor.program;

/// A reader checks these four bytes first to tell wire bytes, the versioned byte encoding of a
/// tensor program, from other data: the value is the four bytes "ACTP" read as a little-endian
/// 32-bit number.
pub const magic: u32 = std.mem.readInt(u32, "ACTP", .little);
/// A writer and a reader agree on the layout through this number: the current layout is version 1.
/// The version is raised before any change to how this format writes anything.
pub const version: u32 = 1;
/// A caller relies on this bound when building programs for transfer with nested scans that repeat
/// a body graph: a program may nest scans inside scan bodies at most eight levels deep. Encoding a
/// deeper program returns `error.ScanTooDeep`.
pub const max_scan_depth: usize = 8;

/// A caller matches on these to tell why a program failed to encode or decode, so the set lists the
/// wire failures other than bytes that end early or run past the program: a wrong magic number,
/// another version, an unknown code, a reference to a missing value, too many operands and scans
/// nested too deep. Bytes that end early or run past the program return `error.InvalidArtifact`.
pub const Error = error{
    BadMagic,
    UnsupportedVersion,
    UnknownTag,
    InvalidReference,
    TooManyOperands,
    ScanTooDeep,
};

/// The function assigns each operation kind, element type and option a fixed number on the wire: it
/// gives each value of `E` the number of its position in `order`. A compile-time check fails the
/// build when `order` leaves out a value of `E` or lists one twice. Decoding a number past the end
/// of `order` returns `error.UnknownTag`.
pub fn Codes(comptime E: type, comptime order: []const E) type {
    comptime {
        if (order.len != @typeInfo(E).@"enum".field_names.len) {
            @compileError("wire codes must cover every value of " ++ @typeName(E));
        }
        for (order, 0..) |value, index| {
            for (order[0..index]) |previous| {
                if (previous == value) @compileError("duplicate wire code in " ++ @typeName(E));
            }
        }
    }
    return struct {
        pub fn code(value: E) u32 {
            for (order, 0..) |candidate, index| {
                if (candidate == value) return @intCast(index);
            }
            unreachable;
        }

        pub fn decode(value_code: u32) Error!E {
            if (value_code >= order.len) return error.UnknownTag;
            const value = order[value_code];
            std.debug.assert(code(value) == value_code);
            return value;
        }
    };
}

pub const Tag = std.meta.Tag(program.Kind);

pub const kind_codes = Codes(Tag, &.{
    .parameter,
    .constant,
    .unary,
    .binary,
    .iota,
    .broadcast,
    .broadcast_in_dim,
    .reshape,
    .transpose,
    .reduce,
    .gather,
    .scatter_add,
    .sparse_cross_entropy,
    .dot_general,
    .compare,
    .select,
    .custom_call,
    .scan,
    .projection,
});

pub const dtype_codes = Codes(tensor.DType, &.{
    .i1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f16, .bf16, .f32, .f64, .key,
});

pub const unary_codes = Codes(program.Unary, &.{
    .neg, .abs, .exp, .log, .sqrt, .tanh, .sin, .cos, .tan,
});

pub const binary_codes = Codes(program.Binary, &.{ .add, .sub, .mul, .div, .max, .min, .pow });

pub const reducer_codes = Codes(program.Reducer, &.{ .sum, .max, .min });

pub const compare_codes = Codes(program.CompareDirection, &.{ .lt, .le, .gt, .ge, .eq, .ne });

test "tensor wire codes pin enum positions and reject unknown codes" {
    try std.testing.expectEqual(@as(u32, 0), kind_codes.code(.parameter));
    try std.testing.expectEqual(@as(u32, 18), kind_codes.code(.projection));
    try std.testing.expectEqual(Tag.scan, try kind_codes.decode(17));
    try std.testing.expectEqual(program.Unary.tan, try unary_codes.decode(8));
    try std.testing.expectEqual(tensor.DType.key, try dtype_codes.decode(13));
    try std.testing.expectError(error.UnknownTag, unary_codes.decode(9));
    try std.testing.expectError(error.UnknownTag, dtype_codes.decode(14));
    try std.testing.expectError(error.UnknownTag, kind_codes.decode(std.math.maxInt(u32)));
}
