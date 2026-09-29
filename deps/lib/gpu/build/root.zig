const dependency_owner = @import("dependency.zig");
const package = @import("public.zig");

pub const DependencyOptions = dependency_owner.DependencyOptions;
pub const build = package.build;
pub const dependency = dependency_owner.dependency;
pub const dependencyOptions = dependency_owner.dependencyOptions;
pub const dependencyOptionsWithAlloc =
    dependency_owner.dependencyOptionsWithAlloc;
