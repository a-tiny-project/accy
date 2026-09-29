const std = @import("std");

const model = @import("model.zig");

const Histogram = model.Histogram;

pub fn histogramFamilyTarget(allocator: std.mem.Allocator, instance: Histogram) ![]u8 {
    return switch (instance.variant) {
        .direct => std.fmt.allocPrint(
            allocator,
            "accy.kernel.histogram.histogram_family_{d}_{s}",
            .{ instance.threads, instance.dtype.name() },
        ),
        .shared_bins => std.fmt.allocPrint(
            allocator,
            "accy.kernel.histogram.histogram_family_shared{d}_{d}_{s}",
            .{ instance.bins, instance.threads, instance.dtype.name() },
        ),
    };
}

pub fn histogramFamilyEntryName(allocator: std.mem.Allocator, instance: Histogram) ![]u8 {
    return switch (instance.variant) {
        .direct => std.fmt.allocPrint(
            allocator,
            "accy_kernel_histogram_histogram_family_{d}_{s}",
            .{ instance.threads, instance.dtype.name() },
        ),
        .shared_bins => std.fmt.allocPrint(
            allocator,
            "accy_kernel_histogram_histogram_family_shared{d}_{d}_{s}",
            .{ instance.bins, instance.threads, instance.dtype.name() },
        ),
    };
}
