const std = @import("std");

const library = @import("../../root.zig");

const entry = library.entry;

pub fn selectableSpecialization(specialization: entry.Specialization) bool {
    return specialization.reductionDependenciesAreValid() and
        specialization.reductionReuseScopesAreValid() and
        specialization.staticParametersAreValid();
}
pub fn specializationThreadgroup1DMatches(specialization: entry.Specialization, threads: u32) bool {
    const launch = specialization.launch orelse return false;
    return launch.threadgroup[0] == threads;
}
pub fn specializationThreadgroup2DMatches(specialization: entry.Specialization, threads: entry.Threads2D) bool {
    const launch = specialization.launch orelse return false;
    return launch.threadgroup[0] == threads.x and
        launch.threadgroup[1] == threads.y;
}
pub fn specializationThreadgroup3DMatches(specialization: entry.Specialization, threads: entry.Threads3D) bool {
    const launch = specialization.launch orelse return false;
    return launch.threadgroup[0] == threads.x and
        launch.threadgroup[1] == threads.y and
        launch.threadgroup[2] == threads.z;
}
test "kernel library catalog requires valid reduction dependency metadata" {
    const column = entry.shape1D("col", 4);
    const rows = entry.shape1D("row", 2);
    const valid = entry.Specialization{
        .reductions = &.{
            entry.reduction("score_dot", .dot_product, column),
            entry.dependentReduction("score_max", .maximum, column, &.{"score_dot"}),
        },
        .reduction_reuse = &.{entry.reductionReuse("score_max", rows)},
    };
    const invalid = entry.Specialization{
        .reductions = &.{
            entry.dependentReduction("score_max", .maximum, column, &.{"score_dot"}),
            entry.reduction("score_dot", .dot_product, column),
        },
    };
    const invalid_reuse = entry.Specialization{
        .reductions = &.{entry.reduction("score_max", .maximum, column)},
        .reduction_reuse = &.{entry.reductionReuse("score_exp_sum", rows)},
    };

    try std.testing.expect(selectableSpecialization(valid));
    try std.testing.expect(!selectableSpecialization(invalid));
    try std.testing.expect(!selectableSpecialization(invalid_reuse));
}
test "kernel library catalog matches specialization threadgroup geometry by rank" {
    const specialization = entry.Specialization{
        .launch = entry.launch3D(16, 8, 4, 4, 2, 1),
    };
    const no_launch = entry.Specialization{};

    try std.testing.expect(specializationThreadgroup1DMatches(specialization, 4));
    try std.testing.expect(specializationThreadgroup2DMatches(specialization, .{ .x = 4, .y = 2 }));
    try std.testing.expect(specializationThreadgroup3DMatches(specialization, .{ .x = 4, .y = 2, .z = 1 }));
    try std.testing.expect(!specializationThreadgroup1DMatches(specialization, 2));
    try std.testing.expect(!specializationThreadgroup2DMatches(specialization, .{ .x = 4, .y = 1 }));
    try std.testing.expect(!specializationThreadgroup3DMatches(specialization, .{ .x = 4, .y = 2, .z = 2 }));
    try std.testing.expect(!specializationThreadgroup1DMatches(no_launch, 4));
    try std.testing.expect(!specializationThreadgroup2DMatches(no_launch, .{ .x = 4, .y = 2 }));
    try std.testing.expect(!specializationThreadgroup3DMatches(no_launch, .{ .x = 4, .y = 2, .z = 1 }));
}
