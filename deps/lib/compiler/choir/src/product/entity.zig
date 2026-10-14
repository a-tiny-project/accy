const std = @import("std");
const revision = @import("root.zig").revision;
const bytecode = @import("../bytecode/root.zig");

/// A retained view owns only immutable bytes and bytecode lookup metadata.
pub const Image = opaque {
    pub fn create(
        allocator: std.mem.Allocator,
        published: *const revision.Revision,
        limits: bytecode.image.Limits,
        expected_version: u32,
    ) !*Image {
        const retained = try published.retain();
        errdefer retained.release();
        const state = try allocator.create(ImageData);
        errdefer allocator.destroy(state);
        var reader = try revision.record.Reader.init(published.view().exact.image);
        if (try reader.readInt(u32) != expected_version) return error.UnknownSchema;
        const count = try reader.readCount();
        if (count > limits.entities) return error.ImageLimit;
        const roots = try allocator.alloc(*bytecode.image.Index, count);
        errdefer allocator.free(roots);
        var initialized: usize = 0;
        errdefer for (roots[0..initialized]) |index| index.destroy();
        for (roots) |*index| {
            index.* = try bytecode.image.Index.create(allocator, try reader.readBlob(), limits);
            initialized += 1;
        }
        state.* = .{
            .allocator = allocator,
            .revision = retained,
            .roots = roots,
            .stage = try reader.readBlob(),
        };
        if (!reader.atEnd()) return error.InvalidRecord;
        return @ptrCast(state);
    }

    pub fn destroy(self: *Image) void {
        const state = imageData(self);
        for (state.roots) |index| index.destroy();
        state.allocator.free(state.roots);
        state.revision.release();
        state.allocator.destroy(state);
    }

    pub fn root(self: *const Image, ordinal: u32) ?bytecode.image.View {
        const state: *const ImageData = @ptrCast(@alignCast(self));
        if (ordinal >= state.roots.len) return null;
        return state.roots[ordinal].view();
    }

    pub fn stage(self: *const Image) []const u8 {
        const state: *const ImageData = @ptrCast(@alignCast(self));
        return state.stage;
    }

    pub fn operation(
        self: *const Image,
        ref: revision.store.Entity,
    ) !Located(bytecode.image.Operation) {
        return self.locate(ref, .operation, "operations", bytecode.image.Operation);
    }

    pub fn block(self: *const Image, ref: revision.store.Entity) !Located(bytecode.image.Block) {
        return self.locate(ref, .block, "blocks", bytecode.image.Block);
    }

    pub fn value(self: *const Image, ref: revision.store.Entity) !Located(bytecode.image.Value) {
        return self.locate(ref, .value, "values", bytecode.image.Value);
    }

    pub fn region(self: *const Image, ref: revision.store.Entity) !Located(bytecode.image.Region) {
        return self.locate(ref, .region, "regions", bytecode.image.Region);
    }

    pub fn attribute(self: *const Image, ref: revision.store.Entity) !Located([]const u8) {
        return self.locate(ref, .attribute, "attributes", []const u8);
    }

    fn locate(
        self: *const Image,
        ref: revision.store.Entity,
        comptime namespace: revision.record.Namespace,
        comptime field: []const u8,
        comptime T: type,
    ) !Located(T) {
        const state: *const ImageData = @ptrCast(@alignCast(self));
        if (!ref.revision.eql(state.revision)) return error.StaleEntity;
        if (ref.namespace != namespace) return error.InvalidEntity;
        var ordinal = ref.ordinal;
        for (state.roots, 0..) |index, root_ordinal| {
            const items = @field(index.view(), field);
            if (ordinal < items.len) return .{
                .root = @intCast(root_ordinal),
                .value = items[ordinal],
            };
            ordinal -= @intCast(items.len);
        }
        return error.InvalidEntity;
    }
};

pub fn Located(comptime T: type) type {
    return struct { root: u32, value: T };
}

const ImageData = struct {
    allocator: std.mem.Allocator,
    revision: *const revision.Revision,
    roots: []*bytecode.image.Index,
    stage: []const u8,
};

fn imageData(image: *Image) *ImageData {
    return @ptrCast(@alignCast(image));
}
