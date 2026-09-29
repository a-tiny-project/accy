const common = @import("common.zig");
const product_mod = @import("../model/root.zig");

const kernel_root = common.kernel_root;

const flat_threads = kernel_root.logical.schedule.Threads{ .x = 64 };
const matrix_threads = kernel_root.logical.schedule.Threads{ .x = 16, .y = 16 };

pub const Flat = @TypeOf(kernel_root.logical.schedule.stack(.{
    kernel_root.logical.schedule.useThreads(flat_threads),
}));

pub const Matrix = @TypeOf(kernel_root.logical.schedule.stack(.{
    kernel_root.logical.schedule.useThreads(matrix_threads),
}));

pub fn Plan(comptime Policy: type) type {
    return struct {
        policy: Policy,
        generated: product_mod.GeneratedSchedule,
    };
}

pub fn flat() Plan(Flat) {
    return withGeneratedSchedule(kernel_root.logical.schedule.stack(.{
        kernel_root.logical.schedule.useThreads(flat_threads),
    }), .{
        .kind = .flat,
        .threads = flat_threads,
    });
}

pub fn flatThreads(threads_x: u32) Plan(Flat) {
    const threads = kernel_root.logical.schedule.Threads{ .x = threads_x };
    return withGeneratedSchedule(kernel_root.logical.schedule.stack(.{
        kernel_root.logical.schedule.useThreads(threads),
    }), .{
        .kind = .flat,
        .threads = threads,
    });
}

pub fn matrix() Plan(Matrix) {
    return withGeneratedSchedule(kernel_root.logical.schedule.stack(.{
        kernel_root.logical.schedule.useThreads(matrix_threads),
    }), .{
        .kind = .matrix,
        .threads = matrix_threads,
    });
}

pub fn matrixThreads(threads_x: u32, threads_y: u32) Plan(Matrix) {
    const threads = kernel_root.logical.schedule.Threads{ .x = threads_x, .y = threads_y };
    return withGeneratedSchedule(kernel_root.logical.schedule.stack(.{
        kernel_root.logical.schedule.useThreads(threads),
    }), .{
        .kind = .matrix,
        .threads = threads,
    });
}

fn withGeneratedSchedule(policy: anytype, generated: product_mod.GeneratedSchedule) Plan(@TypeOf(policy)) {
    return .{
        .policy = policy,
        .generated = generated,
    };
}
