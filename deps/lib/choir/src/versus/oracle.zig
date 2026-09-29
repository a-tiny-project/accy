const std = @import("std");

const workload_mod = @import("workload.zig");

const Allocator = std.mem.Allocator;
const Workload = workload_mod.Workload;

pub const float32_tolerance = 1e-4;
pub const float64_tolerance = 1e-9;

pub const Buffers = union(workload_mod.Kind) {
    saxpy: struct { a: []f32, x: []f32, y: []f32, out: []f32 },
    dot: struct { x: []f64, y: []f64, out: []f64 },
    sum: struct { x: []i64, out: []i64 },
    matmul: struct { a: []f64, b: []f64, c: []f64 },
    polybench_gemm: struct { a: []f64, b: []f64, c_initial: []f64, c: []f64 },
    stencil3: struct { in: []f64, out: []f64 },
    clampsum: struct { x: []i64, out: []i64 },

    pub fn alloc(allocator: Allocator, workload: Workload) !Buffers {
        const n: usize = @intCast(workload.n);
        switch (workload.kind) {
            .saxpy => {
                const a = try allocator.alloc(f32, 1);
                const x = try allocator.alloc(f32, n);
                const y = try allocator.alloc(f32, n);
                const out = try allocator.alloc(f32, n);
                workload_mod.fillUnit(f32, a, 0);
                workload_mod.fillUnit(f32, x, 1);
                workload_mod.fillUnit(f32, y, 1 + workload.n);
                @memset(out, 0);
                return .{ .saxpy = .{ .a = a, .x = x, .y = y, .out = out } };
            },
            .dot => {
                const x = try allocator.alloc(f64, n);
                const y = try allocator.alloc(f64, n);
                const out = try allocator.alloc(f64, 1);
                workload_mod.fillUnit(f64, x, 0);
                workload_mod.fillUnit(f64, y, workload.n);
                @memset(out, 0);
                return .{ .dot = .{ .x = x, .y = y, .out = out } };
            },
            .sum => {
                const x = try allocator.alloc(i64, n);
                const out = try allocator.alloc(i64, 1);
                workload_mod.fillInt(x, 0);
                @memset(out, 0);
                return .{ .sum = .{ .x = x, .out = out } };
            },
            .matmul => {
                const cells = n * n;
                const a = try allocator.alloc(f64, cells);
                const b = try allocator.alloc(f64, cells);
                const c = try allocator.alloc(f64, cells);
                workload_mod.fillUnit(f64, a, 0);
                workload_mod.fillUnit(f64, b, workload.n * workload.n);
                @memset(c, 0);
                return .{ .matmul = .{ .a = a, .b = b, .c = c } };
            },
            .polybench_gemm => {
                const cells = n * n;
                const a = try allocator.alloc(f64, cells);
                const b = try allocator.alloc(f64, cells);
                const c_initial = try allocator.alloc(f64, cells);
                const c = try allocator.alloc(f64, cells);
                workload_mod.fillUnit(f64, a, 0);
                workload_mod.fillUnit(f64, b, workload.n * workload.n);
                workload_mod.fillUnit(f64, c_initial, 2 * workload.n * workload.n);
                @memcpy(c, c_initial);
                return .{ .polybench_gemm = .{ .a = a, .b = b, .c_initial = c_initial, .c = c } };
            },
            .stencil3 => {
                const in = try allocator.alloc(f64, n);
                const out = try allocator.alloc(f64, n);
                workload_mod.fillUnit(f64, in, 0);
                @memset(out, 0);
                return .{ .stencil3 = .{ .in = in, .out = out } };
            },
            .clampsum => {
                const x = try allocator.alloc(i64, n);
                const out = try allocator.alloc(i64, 1);
                workload_mod.fillInt(x, 0);
                @memset(out, 0);
                return .{ .clampsum = .{ .x = x, .out = out } };
            },
        }
    }

    pub fn reset(self: *Buffers) void {
        switch (self.*) {
            .saxpy => |buffers| @memset(buffers.out, 0),
            .dot => |buffers| @memset(buffers.out, 0),
            .sum => |buffers| @memset(buffers.out, 0),
            .matmul => |buffers| @memset(buffers.c, 0),
            .polybench_gemm => |buffers| @memcpy(buffers.c, buffers.c_initial),
            .stencil3 => |buffers| @memset(buffers.out, 0),
            .clampsum => |buffers| @memset(buffers.out, 0),
        }
    }

    pub fn deinit(self: *Buffers, allocator: Allocator) void {
        switch (self.*) {
            .saxpy => |buffers| {
                allocator.free(buffers.a);
                allocator.free(buffers.x);
                allocator.free(buffers.y);
                allocator.free(buffers.out);
            },
            .dot => |buffers| {
                allocator.free(buffers.x);
                allocator.free(buffers.y);
                allocator.free(buffers.out);
            },
            .sum => |buffers| {
                allocator.free(buffers.x);
                allocator.free(buffers.out);
            },
            .matmul => |buffers| {
                allocator.free(buffers.a);
                allocator.free(buffers.b);
                allocator.free(buffers.c);
            },
            .polybench_gemm => |buffers| {
                allocator.free(buffers.a);
                allocator.free(buffers.b);
                allocator.free(buffers.c_initial);
                allocator.free(buffers.c);
            },
            .stencil3 => |buffers| {
                allocator.free(buffers.in);
                allocator.free(buffers.out);
            },
            .clampsum => |buffers| {
                allocator.free(buffers.x);
                allocator.free(buffers.out);
            },
        }
    }
};

fn expectClose(expected: f64, actual: f64, tolerance: f64) !void {
    if (!std.math.isFinite(expected) or !std.math.isFinite(actual)) return error.OracleMismatch;
    const magnitude = @max(@abs(expected), 1.0);
    if (@abs(expected - actual) > tolerance * magnitude) return error.OracleMismatch;
}

pub fn verify(workload: Workload, buffers: *const Buffers) !void {
    switch (buffers.*) {
        .saxpy => |b| {
            for (b.x, b.y, b.out) |x, y, actual| {
                const expected = @as(f64, b.a[0]) * @as(f64, x) + @as(f64, y);
                try expectClose(expected, @as(f64, actual), float32_tolerance);
            }
        },
        .dot => |b| {
            var acc: f64 = 0;
            for (b.x, b.y) |x, y| acc += x * y;
            try expectClose(acc, b.out[0], float64_tolerance);
        },
        .sum => |b| {
            var acc: i64 = 0;
            for (b.x) |x| acc +%= x;
            if (acc != b.out[0]) return error.OracleMismatch;
        },
        .matmul => |b| {
            const n: usize = @intCast(workload.n);
            for (b.c, 0..) |actual, cell| {
                const row = cell / n;
                const col = cell % n;
                var acc: f64 = 0;
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    acc += b.a[row * n + k] * b.b[k * n + col];
                }
                try expectClose(acc, actual, float64_tolerance);
            }
        },
        .polybench_gemm => |b| {
            const n: usize = @intCast(workload.n);
            for (b.c, 0..) |actual, cell| {
                const row = cell / n;
                const col = cell % n;
                var acc = workload_mod.gemm_beta * b.c_initial[cell];
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    acc += workload_mod.gemm_alpha * b.a[row * n + k] * b.b[k * n + col];
                }
                try expectClose(acc, actual, float64_tolerance);
            }
        },
        .stencil3 => |b| {
            for (b.out, 0..) |actual, cell| {
                const expected = if (cell == 0 or cell + 1 == b.out.len)
                    0
                else
                    0.25 * b.in[cell - 1] + 0.5 * b.in[cell] + 0.25 * b.in[cell + 1];
                try expectClose(expected, actual, float64_tolerance);
            }
        },
        .clampsum => |b| {
            var acc: i64 = 0;
            for (b.x) |x| {
                acc +%= std.math.clamp(x, workload_mod.clamp_lo, workload_mod.clamp_hi);
            }
            if (acc != b.out[0]) return error.OracleMismatch;
        },
    }
}

fn expectEveryCorruptionRejected(comptime T: type, workload: Workload, buffers: *const Buffers, outputs: []T) !void {
    for (outputs) |*actual| {
        actual.* += 1;
        try std.testing.expectError(error.OracleMismatch, verify(workload, buffers));
        actual.* -= 1;
    }
}

test "verify accepts reference outputs and rejects corrupted ones" {
    const allocator = std.testing.allocator;
    const workload = workload_mod.Workload{ .name = "sum_test", .kind = .sum, .n = 128 };
    var buffers = try Buffers.alloc(allocator, workload);
    defer buffers.deinit(allocator);

    var acc: i64 = 0;
    for (buffers.sum.x) |x| acc +%= x;
    buffers.sum.out[0] = acc;
    try verify(workload, &buffers);

    buffers.sum.out[0] += 1;
    try std.testing.expectError(error.OracleMismatch, verify(workload, &buffers));
}

test "verify rejects corruption at every stencil cell" {
    const allocator = std.testing.allocator;
    const workload = workload_mod.Workload{ .name = "stencil_test", .kind = .stencil3, .n = 9 };
    var buffers = try Buffers.alloc(allocator, workload);
    defer buffers.deinit(allocator);

    const b = buffers.stencil3;
    var i: usize = 1;
    while (i < b.in.len - 1) : (i += 1) {
        b.out[i] = 0.25 * b.in[i - 1] + 0.5 * b.in[i] + 0.25 * b.in[i + 1];
    }
    try verify(workload, &buffers);

    try expectEveryCorruptionRejected(f64, workload, &buffers, b.out);
}

test "verify rejects corruption at every saxpy cell" {
    const allocator = std.testing.allocator;
    const workload = workload_mod.Workload{ .name = "saxpy_test", .kind = .saxpy, .n = 9 };
    var buffers = try Buffers.alloc(allocator, workload);
    defer buffers.deinit(allocator);

    const b = buffers.saxpy;
    for (b.x, b.y, b.out) |x, y, *out| out.* = b.a[0] * x + y;
    try verify(workload, &buffers);

    try expectEveryCorruptionRejected(f32, workload, &buffers, b.out);
}

test "verify rejects corruption at every matrix cell" {
    const allocator = std.testing.allocator;
    const workload = workload_mod.Workload{ .name = "matmul_test", .kind = .matmul, .n = 4 };
    var buffers = try Buffers.alloc(allocator, workload);
    defer buffers.deinit(allocator);

    const b = buffers.matmul;
    const n: usize = @intCast(workload.n);
    for (b.c, 0..) |*out, cell| {
        const row = cell / n;
        const col = cell % n;
        for (0..n) |k| out.* += b.a[row * n + k] * b.b[k * n + col];
    }
    try verify(workload, &buffers);

    try expectEveryCorruptionRejected(f64, workload, &buffers, b.c);
}

test "verify rejects corruption at every PolyBench GEMM cell" {
    const allocator = std.testing.allocator;
    const workload = workload_mod.Workload{ .name = "gemm_test", .kind = .polybench_gemm, .n = 4 };
    var buffers = try Buffers.alloc(allocator, workload);
    defer buffers.deinit(allocator);

    const b = buffers.polybench_gemm;
    const n: usize = @intCast(workload.n);
    for (0..n) |row| {
        for (0..n) |col| b.c[row * n + col] *= workload_mod.gemm_beta;
        for (0..n) |k| {
            for (0..n) |col| {
                b.c[row * n + col] += workload_mod.gemm_alpha * b.a[row * n + k] * b.b[k * n + col];
            }
        }
    }
    try verify(workload, &buffers);

    try expectEveryCorruptionRejected(f64, workload, &buffers, b.c);
}

test "verify rejects non-finite floating results" {
    const allocator = std.testing.allocator;
    const workload = workload_mod.Workload{ .name = "dot_test", .kind = .dot, .n = 128 };
    var buffers = try Buffers.alloc(allocator, workload);
    defer buffers.deinit(allocator);

    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |non_finite| {
        buffers.dot.out[0] = non_finite;
        try std.testing.expectError(error.OracleMismatch, verify(workload, &buffers));
    }
}
