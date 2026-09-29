const choir = @import("../../root.zig");
const source = @import("root.zig");

const product = choir.product;

/// Binds one verified source partition to one pipeline product identity.
/// The `ProductKey` is borrowed and must outlive this value.
pub const PipelineInput = struct {
    partition: source.PartitionId,
    pipeline: source.Pipeline,
    product: product.ProductKey,

    pub fn init(
        source_module: *const source.PartitionedModule,
        partition: source.PartitionId,
        pipeline: source.Pipeline,
        product_key: product.ProductKey,
    ) source.VerificationError!PipelineInput {
        product_key.validate() catch return error.ProductIdentityMismatch;
        const partition_value = source_module.partition(partition) orelse return error.MissingPartition;
        if (partition_value.pipeline != pipeline) return error.PipelineMismatch;
        if (!partition_value.product.eql(product_key.ref)) return error.ProductIdentityMismatch;
        return .{
            .partition = partition,
            .pipeline = pipeline,
            .product = product_key,
        };
    }
};
