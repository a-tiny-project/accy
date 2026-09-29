const dependency_contract = @import("dependency.zig");
const module = @import("module.zig");
const profile = @import("profile.zig");
const register = @import("register.zig");

pub const Inputs = module.Inputs;
pub const createModule = module.createModule;
pub const DependencyOptions = dependency_contract.DependencyOptions;
pub const dependencyOptions = dependency_contract.dependencyOptions;
pub const dependency = dependency_contract.dependency;
pub const profileBuildOptions = profile.profileBuildOptions;
pub const build = register.build;
