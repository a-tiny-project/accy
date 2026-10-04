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
pub fn specializationThreadgroup2DMatches(
    specialization: entry.Specialization,
    threads: entry.Threads2D,
) bool {
    const launch = specialization.launch orelse return false;
    return launch.threadgroup[0] == threads.x and
        launch.threadgroup[1] == threads.y;
}
pub fn specializationThreadgroup3DMatches(
    specialization: entry.Specialization,
    threads: entry.Threads3D,
) bool {
    const launch = specialization.launch orelse return false;
    return launch.threadgroup[0] == threads.x and
        launch.threadgroup[1] == threads.y and
        launch.threadgroup[2] == threads.z;
}
