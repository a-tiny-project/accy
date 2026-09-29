const std = @import("std");
const product = @import("../../product/root.zig");
const revision = product.revision;

/// Test metadata is structurally complete and deliberately has no sealed receipt.
pub const Records = struct {
    allocator: std.mem.Allocator,
    owner: *revision.Store,

    pub fn init(allocator: std.mem.Allocator) !Records {
        return .{ .allocator = allocator, .owner = try revision.Store.create(allocator, .{
            .revisions = 64,
            .kinds = 1,
            .builders = 1,
            .compiler_manifests = 2,
            .record_bytes = 64 * 1024,
            .gate_scratch_bytes = 0,
            .candidate_count = 1,
            .screening_bytes = 0,
        }) };
    }

    pub fn deinit(self: Records) void {
        self.owner.release();
    }

    pub fn key(
        self: Records,
        stage: []const u8,
        source: []const u8,
        image: []const u8,
    ) !product.ProductKey {
        return self.importUnder(stage, source, image, "composition-fixture-v1");
    }

    /// Builds the same record under a named compiler, so a caller can place two
    /// products at one address and differ only in what produced them.
    pub fn importUnder(
        self: Records,
        stage: []const u8,
        source: []const u8,
        image: []const u8,
        manifest: []const u8,
    ) !product.ProductKey {
        const address = try revision.record.encodeAddress(
            self.allocator,
            product.productRef("composition-fixture", source, stage, "default"),
        );
        defer self.allocator.free(address);
        const inputs = try revision.record.encodeInputs(self.allocator, .{
            .compiler_manifest = manifest,
            .versions = &.{},
            .pipeline = &.{},
            .options = "",
            .policy = "",
        }, &.{}, "fixture-metadata");
        defer self.allocator.free(inputs);
        const bytes = try revision.record.encodeExact(self.allocator, .{
            .address = address,
            .inputs = inputs,
            .image = image,
        });
        defer self.allocator.free(bytes);
        const imported = try self.owner.importRecord(bytes, manifest, .{
            .bytes = 64 * 1024,
            .records = 1,
            .depth = 1,
        });
        imported.release();
        return product.productKey(imported);
    }
};
