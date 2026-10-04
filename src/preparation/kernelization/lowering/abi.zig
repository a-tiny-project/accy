const std = @import("std");
const gpu_abi = @import("gpu_abi");
const common = @import("common.zig");

const kernel_root = common.kernel_root;

/// Bounds the bytes of one parameter list, the ordered parameters one generated kernel takes. The
/// kernel stage charges that storage against its work bound, the costs a pass declares before it
/// runs, once per try at emitting a kernel under one candidate schedule, so compilation can refuse
/// a pass that would exceed the caller's limits before kernel generation runs. The bound allows
/// `input_count + 2` parameters and never fewer than five, plus one parameter's alignment in slack.
/// That covers every layout: the plain layout holds the output, the inputs and an element count,
/// the fused dot layout holds the output and the inputs, and the fixed gather and scatter layouts
/// hold four and five parameters. The call returns `error.WorkOverflow` when the size does not fit
/// in 64 bits or in a `usize`.
pub fn storageBound(input_count: u64) error{WorkOverflow}!u64 {
    const count = std.math.add(u64, input_count, 2) catch return error.WorkOverflow;
    const bytes = std.math.mul(u64, @max(5, count), @sizeOf(kernel_root.Param)) catch
        return error.WorkOverflow;
    const aligned = std.math.add(u64, bytes, @alignOf(kernel_root.Param)) catch
        return error.WorkOverflow;
    if (aligned > std.math.maxInt(usize)) return error.WorkOverflow;
    return aligned;
}

pub const Flat = struct {
    schema: []kernel_root.Param,
    input_count: usize,

    pub fn deinit(self: *Flat, allocator: std.mem.Allocator) void {
        allocator.free(self.schema);
        self.* = undefined;
    }

    pub fn params(self: Flat) []const kernel_root.Param {
        return self.schema;
    }

    pub fn output(_: Flat, logical: anytype) kernel_root.Value {
        return logical.argument(0);
    }

    pub fn input(_: Flat, logical: anytype, index: usize) kernel_root.Value {
        return logical.argument(1 + index);
    }

    pub fn count(self: Flat, logical: anytype) kernel_root.Value {
        return logical.argument(self.countIndex());
    }

    pub fn countIndex(self: Flat) usize {
        return self.input_count + 1;
    }
};

pub const Dot = struct {
    schema: [3]kernel_root.Param,

    pub fn params(self: *const Dot) []const kernel_root.Param {
        return self.schema[0..];
    }

    pub fn output(_: Dot, logical: anytype) kernel_root.Value {
        return logical.argument(0);
    }

    pub fn lhs(_: Dot, logical: anytype) kernel_root.Value {
        return logical.argument(1);
    }

    pub fn rhs(_: Dot, logical: anytype) kernel_root.Value {
        return logical.argument(2);
    }

    pub fn input(_: Dot, logical: anytype, index: usize) kernel_root.Value {
        return logical.argument(1 + index);
    }
};

pub const Reduction = struct {
    schema: [4]kernel_root.Param,
    has_init_buffer: bool,

    pub fn params(self: *const Reduction) []const kernel_root.Param {
        return self.schema[0..self.argumentCount()];
    }

    pub fn output(_: Reduction, logical: anytype) kernel_root.Value {
        return logical.argument(0);
    }

    pub fn input(_: Reduction, logical: anytype) kernel_root.Value {
        return logical.argument(1);
    }

    pub fn init(self: Reduction, logical: anytype) kernel_root.Value {
        if (!self.has_init_buffer) unreachable;
        return logical.argument(2);
    }

    pub fn count(self: Reduction, logical: anytype) kernel_root.Value {
        return logical.argument(self.countIndex());
    }

    fn countIndex(self: Reduction) usize {
        return if (self.has_init_buffer) 3 else 2;
    }

    fn argumentCount(self: Reduction) usize {
        return self.countIndex() + 1;
    }
};

pub fn flat(
    allocator: std.mem.Allocator,
    dtype: gpu_abi.DType,
    input_count: usize,
) common.LoweringError!Flat {
    const parameter_count = std.math.add(usize, input_count, 2) catch return error.WorkOverflow;
    _ = std.math.mul(usize, parameter_count, @sizeOf(kernel_root.Param)) catch
        return error.WorkOverflow;
    const schema = allocator.alloc(kernel_root.Param, parameter_count) catch
        return error.OutOfMemory;
    errdefer allocator.free(schema);

    schema[0] = kernel_root.dynamicBuffer(dtype);
    var input_index: usize = 0;
    while (input_index < input_count) : (input_index += 1) {
        schema[1 + input_index] = kernel_root.dynamicBuffer(dtype);
    }
    schema[input_count + 1] = kernel_root.dynamicBuffer(.i32);

    return .{
        .schema = schema,
        .input_count = input_count,
    };
}

pub fn flatTyped(
    allocator: std.mem.Allocator,
    output_dtype: gpu_abi.DType,
    input_dtypes: []const gpu_abi.DType,
) common.LoweringError!Flat {
    const input_count = input_dtypes.len;
    const parameter_count = std.math.add(usize, input_count, 2) catch return error.WorkOverflow;
    _ = std.math.mul(usize, parameter_count, @sizeOf(kernel_root.Param)) catch
        return error.WorkOverflow;
    const schema = allocator.alloc(kernel_root.Param, parameter_count) catch
        return error.OutOfMemory;
    errdefer allocator.free(schema);

    schema[0] = kernel_root.dynamicBuffer(output_dtype);
    for (input_dtypes, 0..) |input_dtype, input_index| {
        schema[1 + input_index] = kernel_root.dynamicBuffer(input_dtype);
    }
    schema[input_count + 1] = kernel_root.dynamicBuffer(.i32);

    return .{
        .schema = schema,
        .input_count = input_count,
    };
}

pub fn gather(allocator: std.mem.Allocator, dtype: gpu_abi.DType) common.LoweringError!Flat {
    const schema = allocator.alloc(kernel_root.Param, 4) catch return error.OutOfMemory;
    errdefer allocator.free(schema);
    schema[0] = kernel_root.dynamicBuffer(dtype);
    schema[1] = kernel_root.dynamicBuffer(dtype);
    schema[2] = kernel_root.dynamicBuffer(.i32);
    schema[3] = kernel_root.dynamicBuffer(.i32);
    return .{
        .schema = schema,
        .input_count = 2,
    };
}

pub fn convert(
    allocator: std.mem.Allocator,
    output_dtype: gpu_abi.DType,
    input_dtype: gpu_abi.DType,
) common.LoweringError!Flat {
    const input_dtypes = [_]gpu_abi.DType{input_dtype};
    return flatTyped(allocator, output_dtype, &input_dtypes);
}

pub fn scatter(allocator: std.mem.Allocator, dtype: gpu_abi.DType) common.LoweringError!Flat {
    const schema = allocator.alloc(kernel_root.Param, 5) catch return error.OutOfMemory;
    errdefer allocator.free(schema);
    schema[0] = kernel_root.dynamicBuffer(dtype);
    schema[1] = kernel_root.dynamicBuffer(dtype);
    schema[2] = kernel_root.dynamicBuffer(.i32);
    schema[3] = kernel_root.dynamicBuffer(dtype);
    schema[4] = kernel_root.dynamicBuffer(.i32);
    return .{
        .schema = schema,
        .input_count = 3,
    };
}

pub fn dot(input_dtype: gpu_abi.DType, output_dtype: gpu_abi.DType) Dot {
    return .{
        .schema = .{
            kernel_root.dynamicBuffer(output_dtype),
            kernel_root.dynamicBuffer(input_dtype),
            kernel_root.dynamicBuffer(input_dtype),
        },
    };
}

pub const DotFused = struct {
    schema: []kernel_root.Param,

    pub fn deinit(self: *DotFused, allocator: std.mem.Allocator) void {
        allocator.free(self.schema);
        self.* = undefined;
    }

    pub fn params(self: *const DotFused) []const kernel_root.Param {
        return self.schema;
    }

    pub fn output(_: DotFused, logical: anytype) kernel_root.Value {
        return logical.argument(0);
    }

    pub fn lhs(self: DotFused, logical: anytype) kernel_root.Value {
        return self.input(logical, 0);
    }

    pub fn rhs(self: DotFused, logical: anytype) kernel_root.Value {
        return self.input(logical, 1);
    }

    pub fn input(_: DotFused, logical: anytype, index: usize) kernel_root.Value {
        return logical.argument(1 + index);
    }
};

pub fn dotFused(
    allocator: std.mem.Allocator,
    output_dtype: gpu_abi.DType,
    input_dtypes: []const gpu_abi.DType,
) common.LoweringError!DotFused {
    const count = std.math.add(usize, input_dtypes.len, 1) catch return error.WorkOverflow;
    _ = std.math.mul(usize, count, @sizeOf(kernel_root.Param)) catch return error.WorkOverflow;
    const schema = allocator.alloc(kernel_root.Param, count) catch return error.OutOfMemory;
    schema[0] = kernel_root.dynamicBuffer(output_dtype);
    for (input_dtypes, 0..) |input_dtype, index| {
        schema[1 + index] = kernel_root.dynamicBuffer(input_dtype);
    }
    return .{ .schema = schema };
}

pub fn reduction(
    input_dtype: gpu_abi.DType,
    output_dtype: gpu_abi.DType,
    has_init_buffer: bool,
) Reduction {
    var result = Reduction{
        .schema = undefined,
        .has_init_buffer = has_init_buffer,
    };
    result.schema[0] = kernel_root.dynamicBuffer(output_dtype);
    result.schema[1] = kernel_root.dynamicBuffer(input_dtype);
    if (has_init_buffer) {
        result.schema[2] = kernel_root.dynamicBuffer(input_dtype);
    }
    result.schema[result.countIndex()] = kernel_root.dynamicBuffer(.i32);
    return result;
}

test "kernelization generated builder ABI fits its reserved schema storage" {
    for ([_]usize{ 0, 1, 3, 62, 64, 256 }) |count| try checkStorage(count);
    try std.testing.expectError(error.WorkOverflow, storageBound(std.math.maxInt(u64)));
    try std.testing.expectError(
        error.WorkOverflow,
        storageBound(std.math.maxInt(usize) / @sizeOf(kernel_root.Param)),
    );
}

fn checkStorage(count: usize) !void {
    const testing = std.testing;
    const bytes = try testing.allocator.alloc(u8, @intCast(try storageBound(count)));
    defer testing.allocator.free(bytes);
    const dtypes = try testing.allocator.alloc(gpu_abi.DType, count);
    defer testing.allocator.free(dtypes);
    @memset(dtypes, .f32);
    for (0..5) |variant| {
        var buffer = std.heap.FixedBufferAllocator.init(bytes);
        const allocator = buffer.allocator();
        const schema = switch (variant) {
            0 => (try flat(allocator, .f32, count)).schema,
            1 => (try flatTyped(allocator, .f32, dtypes)).schema,
            2 => (try dotFused(allocator, .f32, dtypes)).schema,
            3 => (try gather(allocator, .f32)).schema,
            4 => (try scatter(allocator, .f32)).schema,
            else => unreachable,
        };
        const expected = switch (variant) {
            0, 1 => count + 2,
            2 => count + 1,
            3 => 4,
            4 => 5,
            else => unreachable,
        };
        try testing.expectEqual(expected, schema.len);
        try testing.expectEqual(.f32, schema[0].buffer.dtype);
        try testing.expect(buffer.end_index <= bytes.len);
    }
}
