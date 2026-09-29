const std = @import("std");

const descriptor_mod = @import("../root.zig");
const entry = @import("../../root.zig").entry;
const geometry = @import("../../root.zig").geometry;
const image = @import("../../root.zig").image;
const match_mod = @import("../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const ImageQuery = query_mod.ImageQuery;

pub const ImageCandidateDescriptors = struct {
    count: usize = 0,
    items: [geometry.max_thread_candidates]OwnedDescriptor = undefined,

    pub fn slice(self: *const ImageCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *ImageCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};

pub fn selectImage(backing_allocator: std.mem.Allocator, query: ImageQuery) !?OwnedDescriptor {
    if (!canonicalImage(query)) return null;
    const threads = imageQueryThreads(query) orelse return null;
    return try imageDescriptorForThreads(backing_allocator, query, threads);
}

pub fn selectImageCandidates(
    backing_allocator: std.mem.Allocator,
    query: ImageQuery,
) !ImageCandidateDescriptors {
    var result = ImageCandidateDescriptors{};
    errdefer result.deinit();

    if (!canonicalImage(query)) return result;
    if (query.schedule != null) {
        if (try selectImage(backing_allocator, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
        return result;
    }

    const thread_candidates = image.imageThreadCandidatesForExtents(query.width, query.height);
    for (thread_candidates.slice()) |threads| {
        if (result.count >= result.items.len) break;
        if (try imageDescriptorForThreads(backing_allocator, query, threads)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
    }
    return result;
}

fn canonicalImage(query: ImageQuery) bool {
    if (query.dtype != .u32) return false;
    if (!image.imageExtentValid(query.width) or !image.imageExtentValid(query.height)) return false;
    return switch (query.kind) {
        .blur_pass => |facts| image.blurPassInstanceValid(.{
            .radius = facts.radius,
            .axis = facts.axis,
            .width = query.width,
            .height = query.height,
        }),
        .resize_bilinear => |facts| image.resizeInstanceValid(.{
            .dst_width = query.width,
            .dst_height = query.height,
            .src_width = facts.src_width,
            .src_height = facts.src_height,
        }),
    };
}

fn imageQueryThreads(query: ImageQuery) ?entry.Threads2D {
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads.x == 0 or threads.y == 0) return null;
                return threads;
            },
        }
    }
    return image.imageThreadsForExtents(query.width, query.height);
}

fn imageDescriptorForThreads(
    backing_allocator: std.mem.Allocator,
    query: ImageQuery,
    threads: entry.Threads2D,
) !?OwnedDescriptor {
    switch (query.kind) {
        .blur_pass => |facts| {
            const instance = image.BlurPass{
                .radius = facts.radius,
                .axis = facts.axis,
                .width = query.width,
                .height = query.height,
                .threads = threads,
            };
            if (!image.blurPassInstanceValid(instance)) return null;
            var specialization = try image.blurPassFamilySpecialization(backing_allocator, instance);
            errdefer specialization.deinit();
            const lifetime_allocator = specialization.allocator();
            const descriptor = Descriptor{
                .name = try image.blurPassFamilyEntryName(lifetime_allocator, instance),
                .metadata = .{
                    .target = try image.blurPassFamilyTarget(lifetime_allocator, instance),
                    .version = image.blur_family_version,
                    .layer = .logical,
                    .category = .image,
                    .specialization = specialization.value,
                },
            };
            if (!match_mod.imageDescriptorMatches(descriptor, query)) {
                specialization.deinit();
                return null;
            }
            return .{ .descriptor = descriptor, .specialization = specialization };
        },
        .resize_bilinear => |facts| {
            const instance = image.Resize{
                .dst_width = query.width,
                .dst_height = query.height,
                .src_width = facts.src_width,
                .src_height = facts.src_height,
                .threads = threads,
            };
            if (!image.resizeInstanceValid(instance)) return null;
            var specialization = try image.resizeFamilySpecialization(backing_allocator, instance);
            errdefer specialization.deinit();
            const lifetime_allocator = specialization.allocator();
            const descriptor = Descriptor{
                .name = try image.resizeFamilyEntryName(lifetime_allocator, instance),
                .metadata = .{
                    .target = try image.resizeFamilyTarget(lifetime_allocator, instance),
                    .version = image.resize_family_version,
                    .layer = .logical,
                    .category = .image,
                    .specialization = specialization.value,
                },
            };
            if (!match_mod.imageDescriptorMatches(descriptor, query)) {
                specialization.deinit();
                return null;
            }
            return .{ .descriptor = descriptor, .specialization = specialization };
        },
    }
}
