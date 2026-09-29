const simd = @import("simd");
const sys = @import("sys");

comptime {
    _ = simd.WaitWord;
    _ = sys.no_libc;
}
