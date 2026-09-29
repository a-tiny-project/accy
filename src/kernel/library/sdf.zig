const std = @import("std");

const kernel = @import("../root.zig");

pub const grid_sample_family_version: u32 = 1;

pub const GridSample = struct {
    gradient: bool = false,
    threads: u32 = 256,
};

pub fn gridSampleInstanceValid(instance: GridSample) bool {
    return instance.threads > 0 and instance.threads <= 1024;
}

const AxisState = struct {
    lo: kernel.Value,
    frac: kernel.Value,
    extent: kernel.Value,
};

fn axisState(
    inner: anytype,
    coordinate: kernel.Value,
    origin: kernel.Value,
    inv_spacing: kernel.Value,
    vertex_count: kernel.Value,
) !AxisState {
    const zero = try inner.constantFloat(.f32, 0);
    const one = try inner.constantFloat(.f32, 1);
    const negative_origin = try inner.mul(origin, try inner.constantFloat(.f32, -1));
    const local = try inner.mul(try inner.add(coordinate, negative_origin), inv_spacing);
    const last = try inner.sub(try inner.cast(vertex_count, .f32), one);
    const clamped = try inner.min(try inner.max(local, zero), last);
    const lo_f = try inner.floor(clamped);
    const lo_capped = try inner.min(lo_f, try inner.sub(last, one));
    const lo_safe = try inner.max(lo_capped, zero);
    const frac = try inner.sub(clamped, lo_safe);
    return .{
        .lo = try inner.castIndex(try inner.cast(lo_safe, .u32)),
        .frac = frac,
        .extent = try inner.castIndex(vertex_count),
    };
}

fn lerp(inner: anytype, from: kernel.Value, to: kernel.Value, t: kernel.Value) !kernel.Value {
    return inner.fma(try inner.sub(to, from), t, from);
}

fn gridSampleBody2Plain(k: anytype, spec: GridSample, args: anytype) !void {
    return gridSampleBody2(k, spec, args, false);
}

fn gridSampleBody2Gradient(k: anytype, spec: GridSample, args: anytype) !void {
    return gridSampleBody2(k, spec, args, true);
}

fn grid_sample_body2_active(inner: anytype, ctx: anytype) !void {
    const one_index = try inner.constantIndex(1);
    const x = (try ctx.args.param(.xs).load(inner, ctx.point)).raw();
    const y = (try ctx.args.param(.ys).load(inner, ctx.point)).raw();
    const sx = try axisState(inner, x, ctx.args.param(.origin_x).raw(), ctx.args.param(.inv_dx).raw(), ctx.args.param(.nx).raw());
    const sy = try axisState(inner, y, ctx.args.param(.origin_y).raw(), ctx.args.param(.inv_dy).raw(), ctx.args.param(.ny).raw());

    const row0 = try inner.mul(sy.lo, sx.extent);
    const row1 = try inner.mul(try inner.add(sy.lo, one_index), sx.extent);
    const x1 = try inner.add(sx.lo, one_index);
    const v00 = (try ctx.args.param(.values).load(inner, try inner.add(row0, sx.lo))).raw();
    const v10 = (try ctx.args.param(.values).load(inner, try inner.add(row0, x1))).raw();
    const v01 = (try ctx.args.param(.values).load(inner, try inner.add(row1, sx.lo))).raw();
    const v11 = (try ctx.args.param(.values).load(inner, try inner.add(row1, x1))).raw();

    const bottom = try lerp(inner, v00, v10, sx.frac);
    const top = try lerp(inner, v01, v11, sx.frac);
    const distance = try lerp(inner, bottom, top, sy.frac);
    try ctx.args.param(.dist).store(inner, distance, ctx.point);

    if (comptime ctx.gradient) {
        const dx_bottom = try inner.sub(v10, v00);
        const dx_top = try inner.sub(v11, v01);
        const dx = try lerp(inner, dx_bottom, dx_top, sy.frac);
        const dy_left = try inner.sub(v01, v00);
        const dy_right = try inner.sub(v11, v10);
        const dy = try lerp(inner, dy_left, dy_right, sx.frac);
        try ctx.args.param(.grad_x).store(inner, try inner.mul(dx, ctx.args.param(.inv_dx).raw()), ctx.point);
        try ctx.args.param(.grad_y).store(inner, try inner.mul(dy, ctx.args.param(.inv_dy).raw()), ctx.point);
    }
}

fn gridSampleBody2(k: anytype, spec: GridSample, args: anytype, comptime gradient: bool) !void {
    if (!gridSampleInstanceValid(spec)) return error.UnsupportedGridSampleInstance;
    const point = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const active = try k.compare(.lt, point, count);
    try k.guardDo(active, .{ .args = args, .point = point, .gradient = gradient }, grid_sample_body2_active);
}

fn gridSampleBody3Plain(k: anytype, spec: GridSample, args: anytype) !void {
    return gridSampleBody3(k, spec, args, false);
}

fn gridSampleBody3Gradient(k: anytype, spec: GridSample, args: anytype) !void {
    return gridSampleBody3(k, spec, args, true);
}

fn grid_sample_body3_active(inner: anytype, ctx: anytype) !void {
    const one_index = try inner.constantIndex(1);
    const x = (try ctx.args.param(.xs).load(inner, ctx.point)).raw();
    const y = (try ctx.args.param(.ys).load(inner, ctx.point)).raw();
    const z = (try ctx.args.param(.zs).load(inner, ctx.point)).raw();
    const sx = try axisState(inner, x, ctx.args.param(.origin_x).raw(), ctx.args.param(.inv_dx).raw(), ctx.args.param(.nx).raw());
    const sy = try axisState(inner, y, ctx.args.param(.origin_y).raw(), ctx.args.param(.inv_dy).raw(), ctx.args.param(.ny).raw());
    const sz = try axisState(inner, z, ctx.args.param(.origin_z).raw(), ctx.args.param(.inv_dz).raw(), ctx.args.param(.nz).raw());

    const x1 = try inner.add(sx.lo, one_index);
    const plane = try inner.mul(sy.extent, sx.extent);
    const slab0 = try inner.mul(sz.lo, plane);
    const slab1 = try inner.mul(try inner.add(sz.lo, one_index), plane);
    const row00 = try inner.add(slab0, try inner.mul(sy.lo, sx.extent));
    const row01 = try inner.add(slab0, try inner.mul(try inner.add(sy.lo, one_index), sx.extent));
    const row10 = try inner.add(slab1, try inner.mul(sy.lo, sx.extent));
    const row11 = try inner.add(slab1, try inner.mul(try inner.add(sy.lo, one_index), sx.extent));

    const v000 = (try ctx.args.param(.values).load(inner, try inner.add(row00, sx.lo))).raw();
    const v100 = (try ctx.args.param(.values).load(inner, try inner.add(row00, x1))).raw();
    const v010 = (try ctx.args.param(.values).load(inner, try inner.add(row01, sx.lo))).raw();
    const v110 = (try ctx.args.param(.values).load(inner, try inner.add(row01, x1))).raw();
    const v001 = (try ctx.args.param(.values).load(inner, try inner.add(row10, sx.lo))).raw();
    const v101 = (try ctx.args.param(.values).load(inner, try inner.add(row10, x1))).raw();
    const v011 = (try ctx.args.param(.values).load(inner, try inner.add(row11, sx.lo))).raw();
    const v111 = (try ctx.args.param(.values).load(inner, try inner.add(row11, x1))).raw();

    const bottom0 = try lerp(inner, v000, v100, sx.frac);
    const top0 = try lerp(inner, v010, v110, sx.frac);
    const slab0_value = try lerp(inner, bottom0, top0, sy.frac);
    const bottom1 = try lerp(inner, v001, v101, sx.frac);
    const top1 = try lerp(inner, v011, v111, sx.frac);
    const slab1_value = try lerp(inner, bottom1, top1, sy.frac);
    const distance = try lerp(inner, slab0_value, slab1_value, sz.frac);
    try ctx.args.param(.dist).store(inner, distance, ctx.point);

    if (comptime ctx.gradient) {
        const dx00 = try inner.sub(v100, v000);
        const dx01 = try inner.sub(v110, v010);
        const dx10 = try inner.sub(v101, v001);
        const dx11 = try inner.sub(v111, v011);
        const dx0 = try lerp(inner, dx00, dx01, sy.frac);
        const dx1 = try lerp(inner, dx10, dx11, sy.frac);
        const dx = try lerp(inner, dx0, dx1, sz.frac);

        const dy00 = try inner.sub(v010, v000);
        const dy10 = try inner.sub(v110, v100);
        const dy01 = try inner.sub(v011, v001);
        const dy11 = try inner.sub(v111, v101);
        const dy0 = try lerp(inner, dy00, dy10, sx.frac);
        const dy1 = try lerp(inner, dy01, dy11, sx.frac);
        const dy = try lerp(inner, dy0, dy1, sz.frac);

        const dz00 = try inner.sub(v001, v000);
        const dz10 = try inner.sub(v101, v100);
        const dz01 = try inner.sub(v011, v010);
        const dz11 = try inner.sub(v111, v110);
        const dz0 = try lerp(inner, dz00, dz10, sx.frac);
        const dz1 = try lerp(inner, dz01, dz11, sx.frac);
        const dz = try lerp(inner, dz0, dz1, sy.frac);

        try ctx.args.param(.grad_x).store(inner, try inner.mul(dx, ctx.args.param(.inv_dx).raw()), ctx.point);
        try ctx.args.param(.grad_y).store(inner, try inner.mul(dy, ctx.args.param(.inv_dy).raw()), ctx.point);
        try ctx.args.param(.grad_z).store(inner, try inner.mul(dz, ctx.args.param(.inv_dz).raw()), ctx.point);
    }
}

fn gridSampleBody3(k: anytype, spec: GridSample, args: anytype, comptime gradient: bool) !void {
    if (!gridSampleInstanceValid(spec)) return error.UnsupportedGridSampleInstance;
    const point = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const active = try k.compare(.lt, point, count);
    try k.guardDo(active, .{ .args = args, .point = point, .gradient = gradient }, grid_sample_body3_active);
}

fn gridSampleSchedule(instance: GridSample) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

pub const GridSampleFamily2D = kernel.logical.Family(.{
    .name = "accy_kernel_sdf_grid_sample_2d_f32",
    .parameters = .{
        .dist = kernel.dynamicBuffer(.f32),
        .values = kernel.dynamicBuffer(.f32),
        .xs = kernel.dynamicBuffer(.f32),
        .ys = kernel.dynamicBuffer(.f32),
        .count = kernel.scalar(.i32),
        .origin_x = kernel.scalar(.f32),
        .origin_y = kernel.scalar(.f32),
        .inv_dx = kernel.scalar(.f32),
        .inv_dy = kernel.scalar(.f32),
        .nx = kernel.scalar(.i32),
        .ny = kernel.scalar(.i32),
    },
    .Instance = GridSample,
    .schedule = gridSampleSchedule,
    .body = gridSampleBody2Plain,
});

pub const GridSampleGradientFamily2D = kernel.logical.Family(.{
    .name = "accy_kernel_sdf_grid_sample_gradient_2d_f32",
    .parameters = .{
        .dist = kernel.dynamicBuffer(.f32),
        .grad_x = kernel.dynamicBuffer(.f32),
        .grad_y = kernel.dynamicBuffer(.f32),
        .values = kernel.dynamicBuffer(.f32),
        .xs = kernel.dynamicBuffer(.f32),
        .ys = kernel.dynamicBuffer(.f32),
        .count = kernel.scalar(.i32),
        .origin_x = kernel.scalar(.f32),
        .origin_y = kernel.scalar(.f32),
        .inv_dx = kernel.scalar(.f32),
        .inv_dy = kernel.scalar(.f32),
        .nx = kernel.scalar(.i32),
        .ny = kernel.scalar(.i32),
    },
    .Instance = GridSample,
    .schedule = gridSampleSchedule,
    .body = gridSampleBody2Gradient,
});

pub const GridSampleFamily3D = kernel.logical.Family(.{
    .name = "accy_kernel_sdf_grid_sample_3d_f32",
    .parameters = .{
        .dist = kernel.dynamicBuffer(.f32),
        .values = kernel.dynamicBuffer(.f32),
        .xs = kernel.dynamicBuffer(.f32),
        .ys = kernel.dynamicBuffer(.f32),
        .zs = kernel.dynamicBuffer(.f32),
        .count = kernel.scalar(.i32),
        .origin_x = kernel.scalar(.f32),
        .origin_y = kernel.scalar(.f32),
        .origin_z = kernel.scalar(.f32),
        .inv_dx = kernel.scalar(.f32),
        .inv_dy = kernel.scalar(.f32),
        .inv_dz = kernel.scalar(.f32),
        .nx = kernel.scalar(.i32),
        .ny = kernel.scalar(.i32),
        .nz = kernel.scalar(.i32),
    },
    .Instance = GridSample,
    .schedule = gridSampleSchedule,
    .body = gridSampleBody3Plain,
});

pub const GridSampleGradientFamily3D = kernel.logical.Family(.{
    .name = "accy_kernel_sdf_grid_sample_gradient_3d_f32",
    .parameters = .{
        .dist = kernel.dynamicBuffer(.f32),
        .grad_x = kernel.dynamicBuffer(.f32),
        .grad_y = kernel.dynamicBuffer(.f32),
        .grad_z = kernel.dynamicBuffer(.f32),
        .values = kernel.dynamicBuffer(.f32),
        .xs = kernel.dynamicBuffer(.f32),
        .ys = kernel.dynamicBuffer(.f32),
        .zs = kernel.dynamicBuffer(.f32),
        .count = kernel.scalar(.i32),
        .origin_x = kernel.scalar(.f32),
        .origin_y = kernel.scalar(.f32),
        .origin_z = kernel.scalar(.f32),
        .inv_dx = kernel.scalar(.f32),
        .inv_dy = kernel.scalar(.f32),
        .inv_dz = kernel.scalar(.f32),
        .nx = kernel.scalar(.i32),
        .ny = kernel.scalar(.i32),
        .nz = kernel.scalar(.i32),
    },
    .Instance = GridSample,
    .schedule = gridSampleSchedule,
    .body = gridSampleBody3Gradient,
});

pub fn gridSampleBlockCount(count: u64, threads: u32) u64 {
    return (count + threads - 1) / threads;
}

pub const ReferenceGrid2 = struct {
    values: []const f32,
    nx: u32,
    ny: u32,
    origin_x: f32,
    origin_y: f32,
    inv_dx: f32,
    inv_dy: f32,
};

pub const ReferenceGrid3 = struct {
    values: []const f32,
    nx: u32,
    ny: u32,
    nz: u32,
    origin_x: f32,
    origin_y: f32,
    origin_z: f32,
    inv_dx: f32,
    inv_dy: f32,
    inv_dz: f32,
};

const ReferenceAxis = struct {
    lo: usize,
    frac: f32,
};

fn referenceAxis(coordinate: f32, origin: f32, inv_spacing: f32, vertex_count: u32) ReferenceAxis {
    const local = (coordinate + origin * -1) * inv_spacing;
    const last = @as(f32, @floatFromInt(vertex_count)) - 1;
    const clamped = @max(@as(f32, 0), @min(local, last));
    const lo_f = @floor(clamped);
    const lo_safe = @max(@as(f32, 0), @min(lo_f, last - 1));
    return .{
        .lo = @intFromFloat(lo_safe),
        .frac = clamped - lo_safe,
    };
}

fn referenceLerp(from: f32, to: f32, t: f32) f32 {
    return @mulAdd(f32, to - from, t, from);
}

pub fn referenceGridSample2(grid: ReferenceGrid2, x: f32, y: f32, gradient: ?*[2]f32) f32 {
    const sx = referenceAxis(x, grid.origin_x, grid.inv_dx, grid.nx);
    const sy = referenceAxis(y, grid.origin_y, grid.inv_dy, grid.ny);
    const row0 = sy.lo * grid.nx;
    const row1 = (sy.lo + 1) * grid.nx;
    const v00 = grid.values[row0 + sx.lo];
    const v10 = grid.values[row0 + sx.lo + 1];
    const v01 = grid.values[row1 + sx.lo];
    const v11 = grid.values[row1 + sx.lo + 1];
    const bottom = referenceLerp(v00, v10, sx.frac);
    const top = referenceLerp(v01, v11, sx.frac);
    if (gradient) |out| {
        out[0] = referenceLerp(v10 - v00, v11 - v01, sy.frac) * grid.inv_dx;
        out[1] = referenceLerp(v01 - v00, v11 - v10, sx.frac) * grid.inv_dy;
    }
    return referenceLerp(bottom, top, sy.frac);
}

pub fn referenceGridSample3(grid: ReferenceGrid3, x: f32, y: f32, z: f32, gradient: ?*[3]f32) f32 {
    const sx = referenceAxis(x, grid.origin_x, grid.inv_dx, grid.nx);
    const sy = referenceAxis(y, grid.origin_y, grid.inv_dy, grid.ny);
    const sz = referenceAxis(z, grid.origin_z, grid.inv_dz, grid.nz);
    const plane = @as(usize, grid.ny) * grid.nx;
    const slab0 = sz.lo * plane;
    const slab1 = (sz.lo + 1) * plane;
    const row00 = slab0 + sy.lo * grid.nx;
    const row01 = slab0 + (sy.lo + 1) * grid.nx;
    const row10 = slab1 + sy.lo * grid.nx;
    const row11 = slab1 + (sy.lo + 1) * grid.nx;
    const v000 = grid.values[row00 + sx.lo];
    const v100 = grid.values[row00 + sx.lo + 1];
    const v010 = grid.values[row01 + sx.lo];
    const v110 = grid.values[row01 + sx.lo + 1];
    const v001 = grid.values[row10 + sx.lo];
    const v101 = grid.values[row10 + sx.lo + 1];
    const v011 = grid.values[row11 + sx.lo];
    const v111 = grid.values[row11 + sx.lo + 1];
    const bottom0 = referenceLerp(v000, v100, sx.frac);
    const top0 = referenceLerp(v010, v110, sx.frac);
    const slab0_value = referenceLerp(bottom0, top0, sy.frac);
    const bottom1 = referenceLerp(v001, v101, sx.frac);
    const top1 = referenceLerp(v011, v111, sx.frac);
    const slab1_value = referenceLerp(bottom1, top1, sy.frac);
    if (gradient) |out| {
        const dx0 = referenceLerp(v100 - v000, v110 - v010, sy.frac);
        const dx1 = referenceLerp(v101 - v001, v111 - v011, sy.frac);
        out[0] = referenceLerp(dx0, dx1, sz.frac) * grid.inv_dx;
        const dy0 = referenceLerp(v010 - v000, v110 - v100, sx.frac);
        const dy1 = referenceLerp(v011 - v001, v111 - v101, sx.frac);
        out[1] = referenceLerp(dy0, dy1, sz.frac) * grid.inv_dy;
        const dz0 = referenceLerp(v001 - v000, v101 - v100, sx.frac);
        const dz1 = referenceLerp(v011 - v010, v111 - v110, sx.frac);
        out[2] = referenceLerp(dz0, dz1, sy.frac) * grid.inv_dz;
    }
    return referenceLerp(slab0_value, slab1_value, sz.frac);
}

const testing = std.testing;

fn diskDistance(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y) - 0.75;
}

fn fillDiskGrid(values: []f32, nx: u32, ny: u32, origin: f32, spacing: f32) void {
    var iy: u32 = 0;
    while (iy < ny) : (iy += 1) {
        var ix: u32 = 0;
        while (ix < nx) : (ix += 1) {
            const x = origin + @as(f32, @floatFromInt(ix)) * spacing;
            const y = origin + @as(f32, @floatFromInt(iy)) * spacing;
            values[@as(usize, iy) * nx + ix] = diskDistance(x, y);
        }
    }
}

test "2d grid sample with gradient matches the reference on the interpreter" {
    const allocator = testing.allocator;
    const nx: u32 = 17;
    const ny: u32 = 13;
    const origin: f32 = -1.0;
    const spacing: f32 = 0.125;
    const count: u32 = 64;

    const values = try allocator.alloc(f32, @as(usize, nx) * ny);
    defer allocator.free(values);
    fillDiskGrid(values, nx, ny, origin, spacing);

    const xs = try allocator.alloc(f32, count);
    defer allocator.free(xs);
    const ys = try allocator.alloc(f32, count);
    defer allocator.free(ys);
    for (0..count) |point| {
        xs[point] = -1.4 + @as(f32, @floatFromInt(point % 11)) * 0.27;
        ys[point] = -1.2 + @as(f32, @floatFromInt(point % 7)) * 0.31;
    }

    const grid = ReferenceGrid2{
        .values = values,
        .nx = nx,
        .ny = ny,
        .origin_x = origin,
        .origin_y = origin,
        .inv_dx = 1.0 / spacing,
        .inv_dy = 1.0 / spacing,
    };

    const expected_dist = try allocator.alloc(f32, count);
    defer allocator.free(expected_dist);
    const expected_gx = try allocator.alloc(f32, count);
    defer allocator.free(expected_gx);
    const expected_gy = try allocator.alloc(f32, count);
    defer allocator.free(expected_gy);
    for (0..count) |point| {
        var gradient: [2]f32 = undefined;
        expected_dist[point] = referenceGridSample2(grid, xs[point], ys[point], &gradient);
        expected_gx[point] = gradient[0];
        expected_gy[point] = gradient[1];
    }

    const dist = try allocator.alloc(f32, count);
    defer allocator.free(dist);
    const gx = try allocator.alloc(f32, count);
    defer allocator.free(gx);
    const gy = try allocator.alloc(f32, count);
    defer allocator.free(gy);
    @memset(dist, 0);
    @memset(gx, 0);
    @memset(gy, 0);

    const instance = GridSample{ .gradient = true, .threads = 32 };
    var graph = try GridSampleGradientFamily2D.build(allocator, GridSampleGradientFamily2D.Limits.testing, instance);
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dist),
        kernel.argumentBuffer(f32, gx),
        kernel.argumentBuffer(f32, gy),
        kernel.argumentBuffer(f32, values),
        kernel.argumentBuffer(f32, xs),
        kernel.argumentBuffer(f32, ys),
        kernel.argumentI32(@intCast(count)),
        kernel.argumentF32(origin),
        kernel.argumentF32(origin),
        kernel.argumentF32(1.0 / spacing),
        kernel.argumentF32(1.0 / spacing),
        kernel.argumentI32(@intCast(nx)),
        kernel.argumentI32(@intCast(ny)),
    }, .{
        .grid = .{ @intCast(gridSampleBlockCount(count, instance.threads)), 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    try testing.expectEqualSlices(f32, expected_dist, dist);
    try testing.expectEqualSlices(f32, expected_gx, gx);
    try testing.expectEqualSlices(f32, expected_gy, gy);
}

test "3d grid sample matches the reference on the interpreter" {
    const allocator = testing.allocator;
    const nx: u32 = 9;
    const ny: u32 = 7;
    const nz: u32 = 6;
    const origin: f32 = -1.0;
    const spacing: f32 = 0.3;
    const count: u32 = 48;

    const values = try allocator.alloc(f32, @as(usize, nx) * ny * nz);
    defer allocator.free(values);
    for (values, 0..) |*value, index| {
        const iz = index / (@as(usize, nx) * ny);
        const rem = index % (@as(usize, nx) * ny);
        const iy = rem / nx;
        const ix = rem % nx;
        const x = origin + @as(f32, @floatFromInt(ix)) * spacing;
        const y = origin + @as(f32, @floatFromInt(iy)) * spacing;
        const z = origin + @as(f32, @floatFromInt(iz)) * spacing;
        value.* = @sqrt(x * x + y * y + z * z) - 0.9;
    }

    const xs = try allocator.alloc(f32, count);
    defer allocator.free(xs);
    const ys = try allocator.alloc(f32, count);
    defer allocator.free(ys);
    const zs = try allocator.alloc(f32, count);
    defer allocator.free(zs);
    for (0..count) |point| {
        xs[point] = -1.5 + @as(f32, @floatFromInt(point % 9)) * 0.36;
        ys[point] = -1.1 + @as(f32, @floatFromInt(point % 5)) * 0.44;
        zs[point] = -1.3 + @as(f32, @floatFromInt(point % 6)) * 0.41;
    }

    const grid = ReferenceGrid3{
        .values = values,
        .nx = nx,
        .ny = ny,
        .nz = nz,
        .origin_x = origin,
        .origin_y = origin,
        .origin_z = origin,
        .inv_dx = 1.0 / spacing,
        .inv_dy = 1.0 / spacing,
        .inv_dz = 1.0 / spacing,
    };

    const expected = try allocator.alloc(f32, count);
    defer allocator.free(expected);
    for (0..count) |point| {
        expected[point] = referenceGridSample3(grid, xs[point], ys[point], zs[point], null);
    }

    const dist = try allocator.alloc(f32, count);
    defer allocator.free(dist);
    @memset(dist, 0);

    const instance = GridSample{ .threads = 32 };
    var graph = try GridSampleFamily3D.build(allocator, GridSampleFamily3D.Limits.testing, instance);
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dist),
        kernel.argumentBuffer(f32, values),
        kernel.argumentBuffer(f32, xs),
        kernel.argumentBuffer(f32, ys),
        kernel.argumentBuffer(f32, zs),
        kernel.argumentI32(@intCast(count)),
        kernel.argumentF32(origin),
        kernel.argumentF32(origin),
        kernel.argumentF32(origin),
        kernel.argumentF32(1.0 / spacing),
        kernel.argumentF32(1.0 / spacing),
        kernel.argumentF32(1.0 / spacing),
        kernel.argumentI32(@intCast(nx)),
        kernel.argumentI32(@intCast(ny)),
        kernel.argumentI32(@intCast(nz)),
    }, .{
        .grid = .{ @intCast(gridSampleBlockCount(count, instance.threads)), 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    try testing.expectEqualSlices(f32, expected, dist);
}

test "grid sample clamps queries outside the grid to the boundary" {
    const grid = ReferenceGrid2{
        .values = &.{ 0, 1, 2, 3 },
        .nx = 2,
        .ny = 2,
        .origin_x = 0,
        .origin_y = 0,
        .inv_dx = 1,
        .inv_dy = 1,
    };
    try testing.expectEqual(@as(f32, 0), referenceGridSample2(grid, -5, -5, null));
    try testing.expectEqual(@as(f32, 3), referenceGridSample2(grid, 5, 5, null));
}

test "grid sample gradient recovers a linear field exactly" {
    const spacing: f32 = 0.5;
    var values: [9]f32 = undefined;
    for (&values, 0..) |*value, index| {
        const ix = index % 3;
        const iy = index / 3;
        value.* = 2.0 * (@as(f32, @floatFromInt(ix)) * spacing) + 3.0 * (@as(f32, @floatFromInt(iy)) * spacing);
    }
    const grid = ReferenceGrid2{
        .values = values[0..],
        .nx = 3,
        .ny = 3,
        .origin_x = 0,
        .origin_y = 0,
        .inv_dx = 1.0 / spacing,
        .inv_dy = 1.0 / spacing,
    };
    var gradient: [2]f32 = undefined;
    _ = referenceGridSample2(grid, 0.6, 0.4, &gradient);
    try testing.expectApproxEqAbs(@as(f32, 2), gradient[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 3), gradient[1], 0.0001);
}
