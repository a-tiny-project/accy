const std = @import("std");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");

pub fn elementType(value: gpu_abi.DType) choir.composition.ElementType {
    return switch (value) {
        .i1 => .i1,
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .u64 => .u64,
        .f16 => .f16,
        .bf16 => .bf16,
        .f32 => .f32,
        .f64 => .f64,
        .key => .key,
    };
}

pub fn dtype(element_type: choir.composition.ElementType) gpu_abi.DType {
    return switch (element_type) {
        .i1 => .i1,
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .u64 => .u64,
        .f16 => .f16,
        .bf16 => .bf16,
        .f32 => .f32,
        .f64 => .f64,
        .key => .key,
    };
}
