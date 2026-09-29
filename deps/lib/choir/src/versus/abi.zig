const std = @import("std");

const oracle = @import("oracle.zig");
const workload_mod = @import("workload.zig");

pub const SaxpyFn = *const fn (i64, [*]const f32, [*]const f32, [*]const f32, [*]f32) callconv(.c) void;
pub const DotFn = *const fn (i64, [*]const f64, [*]const f64, [*]f64) callconv(.c) void;
pub const SumFn = *const fn (i64, [*]const i64, [*]i64) callconv(.c) void;
pub const MatmulFn = *const fn (i64, [*]const f64, [*]const f64, [*]f64) callconv(.c) void;
pub const PolybenchGemmFn = *const fn (i32, i32, i32, f64, f64, [*]f64, [*]f64, [*]f64) callconv(.c) void;
pub const Stencil3Fn = *const fn (i64, [*]const f64, [*]f64) callconv(.c) void;
pub const ClampsumFn = *const fn (i64, [*]const i64, i64, i64, [*]i64) callconv(.c) void;

pub fn FnType(comptime kind: workload_mod.Kind) type {
    return switch (kind) {
        .saxpy => SaxpyFn,
        .dot => DotFn,
        .sum => SumFn,
        .matmul => MatmulFn,
        .polybench_gemm => PolybenchGemmFn,
        .stencil3 => Stencil3Fn,
        .clampsum => ClampsumFn,
    };
}

pub const Kernel = union(workload_mod.Kind) {
    saxpy: SaxpyFn,
    dot: DotFn,
    sum: SumFn,
    matmul: MatmulFn,
    polybench_gemm: PolybenchGemmFn,
    stencil3: Stencil3Fn,
    clampsum: ClampsumFn,

    pub fn call(self: Kernel, workload: workload_mod.Workload, buffers: *const oracle.Buffers) void {
        const n: i64 = @intCast(workload.n);
        switch (self) {
            .saxpy => |kernel| kernel(n, buffers.saxpy.a.ptr, buffers.saxpy.x.ptr, buffers.saxpy.y.ptr, buffers.saxpy.out.ptr),
            .dot => |kernel| kernel(n, buffers.dot.x.ptr, buffers.dot.y.ptr, buffers.dot.out.ptr),
            .sum => |kernel| kernel(n, buffers.sum.x.ptr, buffers.sum.out.ptr),
            .matmul => |kernel| kernel(n, buffers.matmul.a.ptr, buffers.matmul.b.ptr, buffers.matmul.c.ptr),
            .polybench_gemm => |kernel| {
                const dim: i32 = @intCast(workload.n);
                kernel(dim, dim, dim, workload_mod.gemm_alpha, workload_mod.gemm_beta, buffers.polybench_gemm.c.ptr, buffers.polybench_gemm.a.ptr, buffers.polybench_gemm.b.ptr);
            },
            .stencil3 => |kernel| kernel(n, buffers.stencil3.in.ptr, buffers.stencil3.out.ptr),
            .clampsum => |kernel| kernel(n, buffers.clampsum.x.ptr, workload_mod.clamp_lo, workload_mod.clamp_hi, buffers.clampsum.out.ptr),
        }
    }
};

fn referenceSaxpy(n: i64, a: [*]const f32, x: [*]const f32, y: [*]const f32, out: [*]f32) callconv(.c) void {
    const s = a[0];
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        out[i] = s * x[i] + y[i];
    }
}

test "kernel dispatch calls through the C ABI" {
    const workload = workload_mod.Workload{ .name = "saxpy_test", .kind = .saxpy, .n = 64 };
    var buffers = try oracle.Buffers.alloc(std.testing.allocator, workload);
    defer buffers.deinit(std.testing.allocator);

    const kernel = Kernel{ .saxpy = referenceSaxpy };
    kernel.call(workload, &buffers);
    try oracle.verify(workload, &buffers);
}
