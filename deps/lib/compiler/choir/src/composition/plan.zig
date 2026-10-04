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

test "fragment plan owns product names and export symbol" {
    const Harness = struct {
        fn run(allocator: Allocator) !void {
            const records = try fixture.Records.init(allocator);
            defer records.deinit();
            var input_name = [_]u8{ 'i', 'n' };
            var export_symbol = [_]u8{ 'r', 'u', 'n' };
            var plan = try FragmentPlan.init(
                allocator,
                .{ .value = 3 },
                .{
                    .partition = .{ .value = 2 },
                    .pipeline = .accy,
                    .product = try records.key(&input_name, "4", "5"),
                },
                &export_symbol,
                1,
            );
            defer plan.deinit();
            input_name[0] = 'x';
            export_symbol[0] = 'x';
            try std.testing.expectEqualStrings("in", plan.input.product.ref.stage);
            try std.testing.expectEqualStrings("run", plan.export_symbol);
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}
