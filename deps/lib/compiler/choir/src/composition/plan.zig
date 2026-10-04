const fixture = @import("fixture/root.zig");
const std = @import("std");
const choir = @import("../root.zig");
const source = @import("source/root.zig");

const Allocator = std.mem.Allocator;
const product = choir.product;

/// An owned pipeline proposal for one partition and shared ABI version.
/// It retains the exact input record and names an artifact export; native work stays transient.
pub const FragmentPlan = struct {
    allocator: Allocator,
    id: source.FragmentId,
    input: source.PipelineInput,
    export_symbol: []const u8,
    abi_version: u32,

    pub fn init(
        allocator: Allocator,
        id: source.FragmentId,
        input: source.PipelineInput,
        export_symbol: []const u8,
        abi_version: u32,
    ) product.ProductMetadataError!FragmentPlan {
        const input_product = try product.cloneProductKey(allocator, input.product);
        errdefer product.deinitProductKey(allocator, input_product);
        return .{
            .allocator = allocator,
            .id = id,
            .input = .{
                .partition = input.partition,
                .pipeline = input.pipeline,
                .product = input_product,
            },
            .export_symbol = try allocator.dupe(u8, export_symbol),
            .abi_version = abi_version,
        };
    }

    pub fn deinit(self: *FragmentPlan) void {
        self.allocator.free(self.export_symbol);
        product.deinitProductKey(self.allocator, self.input.product);
        self.* = undefined;
    }
};
