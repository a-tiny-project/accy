const dependency_owner = @import("dependency.zig");
const register = @import("register.zig");

pub const DependencyOptions = dependency_owner.DependencyOptions;
pub const dependency = dependency_owner.dependency;
pub const dependencyWithAllocationObservation =
    dependency_owner.dependencyWithAllocationObservation;
pub const dependencyOptions = dependency_owner.dependencyOptions;
pub const build = register.build;
