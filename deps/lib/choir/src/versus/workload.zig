const std = @import("std");

pub const Kind = enum {
    saxpy,
    dot,
    sum,
    matmul,
    polybench_gemm,
    stencil3,
    clampsum,

    pub fn symbol(self: Kind) [:0]const u8 {
        return switch (self) {
            .saxpy => "kernel_saxpy",
            .dot => "kernel_dot",
            .sum => "kernel_sum",
            .matmul => "kernel_matmul",
            .polybench_gemm => "kernel_gemm",
            .stencil3 => "kernel_stencil3",
            .clampsum => "kernel_clampsum",
        };
    }

    pub fn source(self: Kind) []const u8 {
        return switch (self) {
            .saxpy => @embedFile("corpus/saxpy.c"),
            .dot => @embedFile("corpus/dot.c"),
            .sum => @embedFile("corpus/sum.c"),
            .matmul => @embedFile("corpus/matmul.c"),
            .polybench_gemm => @embedFile("corpus/polybench_gemm.c"),
            .stencil3 => @embedFile("corpus/stencil3.c"),
            .clampsum => @embedFile("corpus/clampsum.c"),
        };
    }
};

pub const Workload = struct {
    name: []const u8,
    kind: Kind,
    n: u64,

    pub fn elements(self: Workload) u64 {
        return switch (self.kind) {
            .matmul, .polybench_gemm => self.n * self.n,
            else => self.n,
        };
    }

    pub fn flops(self: Workload) u64 {
        return switch (self.kind) {
            .saxpy => 2 * self.n,
            .dot => 2 * self.n,
            .matmul => 2 * self.n * self.n * self.n,
            .polybench_gemm => 3 * self.n * self.n * self.n + self.n * self.n,
            .stencil3 => 5 * self.n,
            .sum, .clampsum => 0,
        };
    }

    pub fn movedBytes(self: Workload) u64 {
        return switch (self.kind) {
            .saxpy => 12 * self.n,
            .dot => 16 * self.n,
            .sum => 8 * self.n,
            .matmul => 24 * self.n * self.n,
            .polybench_gemm => 32 * self.n * self.n,
            .stencil3 => 16 * self.n,
            .clampsum => 8 * self.n,
        };
    }
};

pub const battery = [_]Workload{
    .{ .name = "saxpy_f32_1m", .kind = .saxpy, .n = 1 << 20 },
    .{ .name = "dot_f64_1m", .kind = .dot, .n = 1 << 20 },
    .{ .name = "sum_i64_1m", .kind = .sum, .n = 1 << 20 },
    .{ .name = "matmul_f64_192", .kind = .matmul, .n = 192 },
    .{ .name = "polybench_gemm_f64_128", .kind = .polybench_gemm, .n = 128 },
    .{ .name = "stencil3_f64_1m", .kind = .stencil3, .n = 1 << 20 },
    .{ .name = "clampsum_i64_1m", .kind = .clampsum, .n = 1 << 20 },
};

pub fn byName(name: []const u8) ?Workload {
    for (battery) |workload| {
        if (std.mem.eql(u8, workload.name, name)) return workload;
    }
    return null;
}

pub const clamp_lo: i64 = -500;
pub const clamp_hi: i64 = 500;
pub const gemm_alpha: f64 = 1.5;
pub const gemm_beta: f64 = 1.2;

fn splitmix(index: u64) u64 {
    var z = index +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

pub fn fillUnit(comptime T: type, values: []T, offset: u64) void {
    for (values, 0..) |*value, index| {
        const bits = splitmix(offset + index);
        const unit = @as(T, @floatFromInt(bits >> 11)) / @as(T, @floatFromInt(@as(u64, 1) << 53));
        value.* = unit - 0.5;
    }
}

pub fn fillInt(values: []i64, offset: u64) void {
    for (values, 0..) |*value, index| {
        const bits = splitmix(offset + index);
        value.* = @as(i64, @intCast(bits % 2001)) - 1000;
    }
}

test "battery names resolve" {
    for (battery) |workload| {
        try std.testing.expectEqual(workload.kind, byName(workload.name).?.kind);
    }
    try std.testing.expect(byName("bogus") == null);
}

test "fills are deterministic" {
    var a: [8]f64 = undefined;
    var b: [8]f64 = undefined;
    fillUnit(f64, a[0..], 7);
    fillUnit(f64, b[0..], 7);
    for (a, b) |left, right| try std.testing.expectEqual(left, right);
    for (a) |value| try std.testing.expect(value >= -0.5 and value < 0.5);

    var xs: [8]i64 = undefined;
    fillInt(xs[0..], 3);
    for (xs) |value| try std.testing.expect(value >= -1000 and value <= 1000);
}
