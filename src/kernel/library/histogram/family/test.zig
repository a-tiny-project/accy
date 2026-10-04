const std = @import("std");
const family = @import("root.zig");

const Histogram = family.Histogram;
const histogram_shared_bins_cap = family.histogram_shared_bins_cap;
const histogram_binning_policy_parameter = family.histogram_binning_policy_parameter;
const histogramInstanceValid = family.histogramInstanceValid;
const histogramBinningPolicyCode = family.histogramBinningPolicyCode;
const histogramFamilyTarget = family.histogramFamilyTarget;
const histogramFamilySpecialization = family.histogramFamilySpecialization;

test {
    @import("test_discovery").discover(@import("binning.zig"));
    @import("test_discovery").discover(@import("model.zig"));
    @import("test_discovery").discover(@import("naming.zig"));
    _ = @import("runtime/test.zig");
    @import("test_discovery").discover(@import("shape.zig"));
    _ = @import("specialization.zig");
    _ = @import("tuning.zig");
    @import("test_discovery").discover(family);
}

test "histogram identity and validity" {
    const shared_instance = Histogram{
        .bins = 256,
        .count = 8192,
        .variant = .shared_bins,
        .threads = 128,
    };
    const shared_target = try histogramFamilyTarget(std.testing.allocator, shared_instance);
    defer std.testing.allocator.free(shared_target);
    try std.testing.expectEqualStrings(
        "accy.kernel.histogram.histogram_family_shared256_128_f32",
        shared_target,
    );

    try std.testing.expect(histogramInstanceValid(shared_instance));
    try std.testing.expect(!histogramInstanceValid(.{ .bins = 8, .count = 0 }));
    try std.testing.expect(!histogramInstanceValid(.{ .bins = 8, .count = 16, .width = 0 }));
    try std.testing.expect(!histogramInstanceValid(.{
        .bins = histogram_shared_bins_cap + 1,
        .count = 16,
        .variant = .shared_bins,
    }));

    var owned = try histogramFamilySpecialization(
        std.testing.allocator,
        .{ .bins = 64, .count = 4096, .variant = .shared_bins, .threads = 64 },
    );
    defer owned.deinit();
    try std.testing.expect(owned.value.structureIs("shared_bins"));
    try std.testing.expect(owned.value.operationIs(.{ .indexing = .histogram }));
    try std.testing.expectEqual(@as(usize, 1), owned.value.static_parameters.len);
    try std.testing.expect(owned.value.staticParameterMatches(
        histogram_binning_policy_parameter,
        histogramBinningPolicyCode(.lower_inclusive_upper_exclusive),
    ));
}

test "accy kernel library histogram family declaration coverage" {
    std.testing.refAllDecls(@import("binning.zig"));
    std.testing.refAllDecls(@import("model.zig"));
    std.testing.refAllDecls(@import("naming.zig"));
    std.testing.refAllDecls(@import("shape.zig"));
    std.testing.refAllDecls(family);
}
