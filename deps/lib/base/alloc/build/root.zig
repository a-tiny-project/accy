const dependency_owner = @import("dependency.zig");
const model = @import("model.zig");
const module = @import("module.zig");
const register = @import("register.zig");

pub const DependencyOptions = model.DependencyOptions;
pub const Inputs = model.Inputs;
pub const createModule = module.createModule;
pub const createTestModule = module.createTestModule;
pub const createTimedTestModule = module.createTimedTestModule;
pub const dependencyOptions = dependency_owner.dependencyOptions;
pub const dependency = dependency_owner.dependency;
pub const build = register.build;
