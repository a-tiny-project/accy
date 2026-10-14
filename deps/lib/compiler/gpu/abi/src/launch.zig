const std = @import("std");
const Error = @import("errors.zig").Error;

/// One scalar kernel argument, passed by value at launch.
pub const ScalarArgument = union(enum) {
    i32: i32,
    u32: u32,
    i64: i64,
    u64: u64,
    f32: f32,
    f64: f64,

    pub fn byteSize(self: ScalarArgument) u32 {
        return switch (self) {
            .i32, .u32, .f32 => 4,
            .i64, .u64, .f64 => 8,
        };
    }
};

/// Grid and threadgroup extents of one kernel launch.
pub const LaunchGeometry = struct {
    grid: [3]u32 = .{ 1, 1, 1 },
    threadgroup: [3]u32 = .{ 1, 1, 1 },
    dynamic_shared_memory_bytes: u32 = 0,

    pub fn threadCount(self: LaunchGeometry) Error!u64 {
        var count: u64 = 1;
        for (self.grid ++ self.threadgroup) |value| {
            count = std.math.mul(u64, count, value) catch return error.CapabilityMismatch;
        }
        return count;
    }
};

/// Host-loop launch ABI: a GPU kernel lowered to a CPU loop receives its
/// launch shape as trailing `u32` scalars, in the order first, upper, grid
/// x y z, threadgroup x y z. It runs invocations [first, upper) of the
/// launch's linear order, so threads that split one launch into disjoint
/// ranges together run exactly the invocations one call over the whole
/// launch runs.
pub const launch_shape_argument_count: u32 = 8;

pub const LaunchShape = struct {
    /// The first linear invocation this call runs.
    first: u32,
    /// One past the last linear invocation this call runs.
    upper: u32,
    grid: [3]u32,
    threadgroup: [3]u32,

    /// The same launch restricted to invocations [first, upper). A harness
    /// that splits one launch among its threads computes the ranges itself,
    /// so a range outside this shape is a bug in that arithmetic.
    pub fn range(self: LaunchShape, first: u32, upper: u32) LaunchShape {
        std.debug.assert(self.first <= first);
        std.debug.assert(first <= upper);
        std.debug.assert(upper <= self.upper);
        var restricted = self;
        restricted.first = first;
        restricted.upper = upper;
        return restricted;
    }

    pub fn scalarArguments(self: LaunchShape, out: []ScalarArgument) Error!void {
        if (out.len < launch_shape_argument_count) return error.InvalidArtifact;
        out[0] = .{ .u32 = self.first };
        out[1] = .{ .u32 = self.upper };
        out[2] = .{ .u32 = self.grid[0] };
        out[3] = .{ .u32 = self.grid[1] };
        out[4] = .{ .u32 = self.grid[2] };
        out[5] = .{ .u32 = self.threadgroup[0] };
        out[6] = .{ .u32 = self.threadgroup[1] };
        out[7] = .{ .u32 = self.threadgroup[2] };
    }
};

/// Argument count of a host-loop kernel with `argument_count` source arguments.
pub fn kernelArgumentCount(argument_count: u32) Error!u32 {
    return std.math.add(u32, argument_count, launch_shape_argument_count) catch
        return error.InvalidArtifact;
}

pub fn launchShape(total_count: u64, geometry: LaunchGeometry) Error!LaunchShape {
    const thread_count = geometry.threadCount() catch return error.InvalidArtifact;
    if (total_count > thread_count) return error.InvalidArtifact;
    const shape = LaunchShape{
        .first = 0,
        .upper = std.math.cast(u32, total_count) orelse return error.InvalidArtifact,
        .grid = try launchAxisExtents(geometry.grid),
        .threadgroup = try launchAxisExtents(geometry.threadgroup),
    };
    std.debug.assert(shape.upper <= thread_count);
    return shape;
}

pub fn launchShapeArguments(
    allocator: std.mem.Allocator,
    total_count: u64,
    geometry: LaunchGeometry,
) Error![]ScalarArgument {
    const shape = try launchShape(total_count, geometry);
    const arguments = allocator.alloc(ScalarArgument, launch_shape_argument_count) catch
        return error.OutOfMemory;
    errdefer allocator.free(arguments);
    try shape.scalarArguments(arguments);
    return arguments;
}

fn launchAxisExtents(values: [3]u32) Error![3]u32 {
    for (values) |value| {
        if (value == 0) return error.InvalidArtifact;
    }
    return values;
}
