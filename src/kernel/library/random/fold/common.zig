const random = @import("../root.zig");

const base = random.base;
const block = random.block;

const DType = base.DType;
const kernel = base.kernel;
const outputWord = block.outputWord;

pub fn foldInitial(k: anytype, comptime dtype: DType) !kernel.Value {
    return switch (dtype) {
        .i32 => k.constantInt(.i32, 0),
        .f32 => k.constantFloat(.f32, 0.0),
        else => @compileError("random fold kernels support dtype .i32 or .f32"),
    };
}

pub fn foldCombine(k: anytype, comptime dtype: DType, accumulator: kernel.Value, word: kernel.Value) !kernel.Value {
    return switch (dtype) {
        .i32 => k.xor(accumulator, word),
        .f32 => k.add(accumulator, try outputWord(k, .f32, word)),
        else => @compileError("random fold kernels support dtype .i32 or .f32"),
    };
}
