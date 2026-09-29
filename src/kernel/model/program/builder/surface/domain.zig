const std = @import("std");

const core = @import("../../../core/root.zig");
const builder_schedule = @import("schedule.zig");
const builder = core.builder;
const domain_mod = core.domain;
const schedule_mod = core.schedule;

pub const Index1D = domain_mod.Index1D;
pub const VectorIndex1D = domain_mod.VectorIndex1D;
pub const DomainAxis = domain_mod.DomainAxis;
pub const Domain2D = domain_mod.Domain2D;
pub const Domain3D = domain_mod.Domain3D;
pub const Index2D = domain_mod.Index2D;
pub const Index3D = domain_mod.Index3D;

pub fn index1D(owner: anytype, name: []const u8, extent: u64, threads_per_block: u32) !Index1D {
    return indexDimension(owner, domain_mod.domainAxis(name, extent, threads_per_block), .x);
}

pub fn vectorIndex1D(owner: anytype, name: []const u8, extent: u64, width: u32, threads_per_block: u32) !VectorIndex1D {
    if (extent == 0 or width == 0 or threads_per_block == 0) return error.InvalidFactor;
    const lane_count: u64 = @intCast(width);
    if (extent % lane_count != 0) return error.ExtentNotDivisible;
    const packet_extent = extent / lane_count;
    const thread_packets: u64 = @intCast(threads_per_block);
    const logical_thread_span = std.math.mul(u64, thread_packets, lane_count) catch return error.LaunchDimensionOverflow;
    const axis_id = try owner.axis(name, extent);
    var tiled_axis: ?schedule_mod.Split = null;
    if (packet_extent <= thread_packets) {
        try owner.vectorize(axis_id, width);
        try owner.bind(axis_id, threadTarget(.x));
    } else {
        const tiled = try builder_schedule.tile(owner, axis_id, logical_thread_span);
        tiled_axis = tiled;
        try owner.vectorize(tiled.inner, width);
        try owner.bind(tiled.outer, blockTarget(.x));
        try owner.bind(tiled.inner, threadTarget(.x));
    }

    const packet = try owner.globalId(.x);
    const width_value = try constantIndexFromU64(owner, lane_count);
    const base = try owner.mul(packet, width_value);
    const packet_bound = try constantIndexFromU64(owner, packet_extent);
    const bound = try constantIndexFromU64(owner, extent);
    return .{
        .domain = axis_id,
        .tile = tiled_axis,
        .packet = packet,
        .packet_bound = packet_bound,
        .base = base,
        .bound = bound,
        .extent = extent,
        .width = width,
        .packets = packet_extent,
    };
}

pub fn index2D(owner: anytype, domain: Domain2D) !Index2D {
    return .{
        .x = try indexDimension(owner, domain.x, .x),
        .y = try indexDimension(owner, domain.y, .y),
    };
}

pub fn index3D(owner: anytype, domain: Domain3D) !Index3D {
    return .{
        .x = try indexDimension(owner, domain.x, .x),
        .y = try indexDimension(owner, domain.y, .y),
        .z = try indexDimension(owner, domain.z, .z),
    };
}

pub fn guardIndexDo(owner: anytype, index: Index1D, context: anytype, comptime body: anytype) !void {
    var active_guard = try owner.guardIndex(index);
    errdefer active_guard.abort();
    try body(owner, index, context);
    try active_guard.leave();
}

pub fn guardVectorIndexDo(owner: anytype, index: VectorIndex1D, context: anytype, comptime body: anytype) !void {
    const in_bounds = try owner.compare(.lt, index.packet, index.packet_bound);
    var active_guard = try owner.guard(in_bounds);
    errdefer active_guard.abort();
    try body(owner, index, context);
    try active_guard.leave();
}

pub fn guardIndex2DDo(owner: anytype, index: Index2D, context: anytype, comptime body: anytype) !void {
    var x_guard = try owner.guardIndex(index.x);
    errdefer x_guard.abort();
    var y_guard = try owner.guardIndex(index.y);
    errdefer y_guard.abort();
    try body(owner, index, context);
    try y_guard.leave();
    try x_guard.leave();
}

pub fn guardIndex3DDo(owner: anytype, index: Index3D, context: anytype, comptime body: anytype) !void {
    var x_guard = try owner.guardIndex(index.x);
    errdefer x_guard.abort();
    var y_guard = try owner.guardIndex(index.y);
    errdefer y_guard.abort();
    var z_guard = try owner.guardIndex(index.z);
    errdefer z_guard.abort();
    try body(owner, index, context);
    try z_guard.leave();
    try y_guard.leave();
    try x_guard.leave();
}

pub fn forEach1D(owner: anytype, name: []const u8, extent: u64, threads_per_block: u32, context: anytype, comptime body: anytype) !Index1D {
    const index = try index1D(owner, name, extent, threads_per_block);
    try guardIndexDo(owner, index, context, body);
    return index;
}

pub fn forEachVector1D(owner: anytype, name: []const u8, extent: u64, width: u32, threads_per_block: u32, context: anytype, comptime body: anytype) !VectorIndex1D {
    const index = try vectorIndex1D(owner, name, extent, width, threads_per_block);
    try guardVectorIndexDo(owner, index, context, body);
    return index;
}

pub fn forEach2D(owner: anytype, domain: Domain2D, context: anytype, comptime body: anytype) !Index2D {
    const index = try index2D(owner, domain);
    try guardIndex2DDo(owner, index, context, body);
    return index;
}

pub fn forEach3D(owner: anytype, domain: Domain3D, context: anytype, comptime body: anytype) !Index3D {
    const index = try index3D(owner, domain);
    try guardIndex3DDo(owner, index, context, body);
    return index;
}

fn indexDimension(owner: anytype, domain_axis: DomainAxis, dimension: builder.Dimension) !Index1D {
    if (domain_axis.extent == 0 or domain_axis.threads_per_block == 0) return error.InvalidFactor;
    const axis_id = try owner.axis(domain_axis.name, domain_axis.extent);
    var tiled_axis: ?schedule_mod.Split = null;
    if (domain_axis.extent <= domain_axis.threads_per_block) {
        try owner.bind(axis_id, threadTarget(dimension));
    } else {
        const tiled = try builder_schedule.tile(owner, axis_id, domain_axis.threads_per_block);
        tiled_axis = tiled;
        try owner.bind(tiled.outer, blockTarget(dimension));
        try owner.bind(tiled.inner, threadTarget(dimension));
    }

    const index = try owner.globalId(dimension);
    const bound_value = try owner.constantIndex(std.math.cast(i64, domain_axis.extent) orelse return error.LaunchDimensionOverflow);
    return .{
        .domain = axis_id,
        .tile = tiled_axis,
        .index = index,
        .bound = bound_value,
        .extent = domain_axis.extent,
    };
}

fn constantIndexFromU64(owner: anytype, value: u64) !builder.Value {
    return owner.constantIndex(std.math.cast(i64, value) orelse return error.LaunchDimensionOverflow);
}

fn blockTarget(dimension: builder.Dimension) schedule_mod.BindTarget {
    return switch (dimension) {
        .x => .block_x,
        .y => .block_y,
        .z => .block_z,
    };
}

fn threadTarget(dimension: builder.Dimension) schedule_mod.BindTarget {
    return switch (dimension) {
        .x => .thread_x,
        .y => .thread_y,
        .z => .thread_z,
    };
}
