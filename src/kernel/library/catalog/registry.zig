const std = @import("std");

const attention = @import("../root.zig").attention;
const compaction = @import("../root.zig").compaction;
const descriptor_mod = @import("descriptor.zig");
const elementwise = @import("../root.zig").elementwise;
const fused = @import("../root.zig").fused;
const indexing = @import("../root.zig").indexing;
const layout = @import("../root.zig").layout;
const linalg = @import("../root.zig").linalg;
const normalization = @import("../root.zig").normalization;
const random = @import("../root.zig").random;
const reduction = @import("../root.zig").reduction;
const scan = @import("../root.zig").scan;
const segmented = @import("../root.zig").segmented;
const stencil = @import("../root.zig").stencil;

pub const Descriptor = descriptor_mod.Descriptor;

pub const entries = .{
    attention.ScaledDotProductAttention2x2x3x2x2F32,
    elementwise.VectorAdd8F32,
    elementwise.Axpy8F32,
    elementwise.Gelu8F32,
    elementwise.Relu8F32,
    elementwise.Silu8F32,
    elementwise.AuthoredScale8F32,
    fused.BiasGelu8F32,
    fused.BiasRelu8F32,
    fused.BiasSilu8F32,
    fused.GeGlu8F32,
    fused.ReGlu8F32,
    fused.SwiGlu8F32,
    fused.MatrixProductBiasGelu2x3x4F32,
    fused.MatrixProductBiasGelu2x3x4ThreadBlocks1x2F32,
    fused.MatrixProductBiasRelu2x3x4F32,
    fused.MatrixProductBiasSilu2x3x4F32,
    fused.MatrixVectorProductBiasGelu4x8F32,
    fused.MatrixVectorProductBiasRelu4x8F32,
    fused.MatrixVectorProductBiasSilu4x8F32,
    normalization.RowResidualRmsNorm2x4F32,
    layout.Transpose8x16F32,
    reduction.Sum8F32,
    reduction.Dot8F32,
    normalization.RowSoftmax2x4F32,
    normalization.RowSoftmax2x4ThreadBlocks2x2F32,
    normalization.RowLogSoftmax2x4F32,
    normalization.RowRmsNorm2x4F32,
    normalization.RowLayerNorm2x4F32,
    normalization.RowAffineLayerNorm2x4F32,
    linalg.MatrixProduct4x16x8F32,
    linalg.MatrixProduct4x16x8ThreadBlocks4x2F32,
    stencil.Window2x3R1F32,
    indexing.Gather8F32,
    indexing.Scatter8F32,
    compaction.Filter8F32,
    random.Philox8F32,
    random.Threefry8F32,
    segmented.SegmentSum4F32,
    scan.PrefixSum8F32,
};

pub const descriptors = buildDescriptors(entries);

fn buildDescriptors(comptime entry_types: anytype) [entry_types.len]Descriptor {
    var result: [entry_types.len]Descriptor = undefined;
    inline for (entry_types, 0..) |EntryType, index| {
        result[index] = descriptorFor(EntryType);
    }
    return result;
}

fn descriptorFor(comptime EntryType: type) Descriptor {
    return .{
        .name = EntryType.name,
        .metadata = EntryType.metadata,
    };
}

pub fn findEntry(target: []const u8, version: u32) ?Descriptor {
    for (descriptors) |descriptor| {
        if (descriptor.metadata.version != version) continue;
        if (!std.mem.eql(u8, descriptor.metadata.target, target)) continue;
        return descriptor;
    }
    return null;
}
