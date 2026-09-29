const common = @import("common.zig");

const kernel_root = common.kernel_root;

fn CountIndexCallbacksType(comptime body: anytype) type {
    return struct {
        fn each(inner: anytype, active_index: kernel_root.Index1D, ctx: anytype) !void {
            const zero = try inner.constantIndex(0);
            const count = try inner.loadIndex(ctx.count_buffer, zero);
            const index_i32 = try inner.cast(active_index.index, .i32);
            const in_bounds = try inner.compare(.lt, index_i32, count);
            try inner.guardDo(in_bounds, .{
                .index = active_index,
                .payload = ctx.payload,
            }, emit);
        }

        fn emit(guarded: anytype, emit_ctx: anytype) !void {
            try body(guarded, emit_ctx.index, emit_ctx.payload);
        }
    };
}

fn CountQuadCallbacksType(comptime body: anytype) type {
    return struct {
        fn each(inner: anytype, active_index: kernel_root.Index1D, ctx: anytype) !void {
            const zero = try inner.constantIndex(0);
            const count = try inner.loadIndex(ctx.count_buffer, zero);
            const four = try inner.constantIndex(4);
            const three = try inner.constantIndex(3);
            const quad_base = try inner.mul(active_index.index, four);
            const quad_last = try inner.add(quad_base, three);
            const quad_last_i32 = try inner.cast(quad_last, .i32);
            const in_bounds = try inner.compare(.lt, quad_last_i32, count);
            try inner.guardDo(in_bounds, .{
                .base = quad_base,
                .payload = ctx.payload,
            }, emit);
        }

        fn emit(guarded: anytype, emit_ctx: anytype) !void {
            try body(guarded, emit_ctx.base, emit_ctx.payload);
        }
    };
}

pub fn countIndexDo(
    logical: anytype,
    index: kernel_root.Index1D,
    count_buffer: kernel_root.Value,
    context: anytype,
    comptime body: anytype,
) !void {
    try logical.guardIndexDo(index, .{
        .count_buffer = count_buffer,
        .payload = context,
    }, CountIndexCallbacksType(body).each);
}

pub fn countQuadDo(
    logical: anytype,
    index: kernel_root.Index1D,
    count_buffer: kernel_root.Value,
    context: anytype,
    comptime body: anytype,
) !void {
    try logical.guardIndexDo(index, .{
        .count_buffer = count_buffer,
        .payload = context,
    }, CountQuadCallbacksType(body).each);
}
