const dependency_owner = @import("dependency.zig");
const module = @import("module.zig");
const register = @import("register.zig");

pub const DependencyOptions = dependency_owner.DependencyOptions;
pub const Inputs = module.Inputs;
pub const createModule = module.createModule;
pub const dependency = dependency_owner.dependency;
pub const dependencyOptions = dependency_owner.dependencyOptions;
pub const build = register.build;
