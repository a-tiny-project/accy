const std = @import("std");
const gpu_abi = @import("gpu_abi");

const descriptor_mod = @import("../root.zig");
const geometry = @import("../../root.zig").geometry;
const stencil = @import("../../root.zig").stencil;
const match_mod = @import("../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const StencilQuery = query_mod.StencilQuery;

pub const StencilWindowCandidateDescriptors = struct {
    count: usize = 0,
    items: [geometry.max_thread_candidates]OwnedDescriptor = undefined,

    pub fn slice(self: *const StencilWindowCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *StencilWindowCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};

pub fn selectStencilWindow(backing_allocator: std.mem.Allocator, query: StencilQuery) !?OwnedDescriptor {
    const accumulation_dtype = stencil.windowAccumulationDType(query.dtype) orelse return null;
    if (!canonicalStencilWindow(query)) return null;
    const instance = stencilWindowInstance(query, accumulation_dtype) orelse return null;
    return try stencilWindowDescriptorForInstance(backing_allocator, instance, query);
}

pub fn selectStencilWindowCandidates(
    backing_allocator: std.mem.Allocator,
    query: StencilQuery,
) !StencilWindowCandidateDescriptors {
    var result = StencilWindowCandidateDescriptors{};
    errdefer result.deinit();

    const accumulation_dtype = stencil.windowAccumulationDType(query.dtype) orelse return result;
    if (!canonicalStencilWindow(query)) return result;
    if (query.schedule != null) {
        if (try selectStencilWindow(backing_allocator, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
        return result;
    }

    const thread_candidates = stencil.windowThreadCandidatesForExtents(query.rows, query.cols);
    for (thread_candidates.slice()) |threads| {
        const instance = stencil.Window{
            .rows = query.rows,
            .cols = query.cols,
            .radius = query.radius,
            .dtype = query.dtype,
            .accumulation_dtype = accumulation_dtype,
            .threads = threads,
        };
        if (try stencilWindowDescriptorForInstance(backing_allocator, instance, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
    }
    return result;
}

fn canonicalStencilWindow(query: StencilQuery) bool {
    if (query.kind != .window) return false;
    if (query.rows == 0 or query.cols == 0) return false;
    return stencil.windowRadiusValid(query.radius);
}

fn stencilWindowDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: stencil.Window,
    query: StencilQuery,
) !?OwnedDescriptor {
    var specialization = try stencil.windowFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try stencil.windowFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try stencil.windowFamilyTarget(lifetime_allocator, instance),
            .version = stencil.window_family_version,
            .layer = .logical,
            .category = .stencil,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.stencilWindowDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn stencilWindowInstance(query: StencilQuery, accumulation_dtype: gpu_abi.DType) ?stencil.Window {
    var instance = stencil.Window{
        .rows = query.rows,
        .cols = query.cols,
        .radius = query.radius,
        .dtype = query.dtype,
        .accumulation_dtype = accumulation_dtype,
        .threads = stencil.windowThreadsForExtents(query.rows, query.cols),
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads.x == 0 or threads.y == 0) return null;
                instance.threads = threads;
            },
        }
    }
    return instance;
}
