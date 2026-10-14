const sys = @import("../root.zig");
const catalog = @import("catalog.zig");
const roots = @import("roots.zig");
const walk = @import("walk.zig");

pub const required_capabilities = sys.capabilities.host(&.{ .environment, .filesystem });

pub const fixture = @import("fixture.zig");

pub const Catalog = catalog.Catalog;
pub const Directory = catalog.Directory;
pub const Entry = catalog.Entry;
pub const Format = catalog.Format;
pub const directories_max = catalog.directories_max;
pub const entries_max = catalog.entries_max;
pub const extension_bytes_max = catalog.extension_bytes_max;
pub const path_bytes_limit = catalog.path_bytes_limit;
pub const path_bytes_max = catalog.path_bytes_max;

pub const Environment = roots.Environment;
pub const RootSet = roots.RootSet;
pub const Support = roots.Support;
pub const Unsupported = roots.Unsupported;
pub const defaultRoots = roots.defaultRoots;
pub const rootsFor = roots.rootsFor;
pub const hostEnvironment = roots.hostEnvironment;
pub const root_bytes_max = roots.root_bytes_max;
pub const roots_max = roots.roots_max;

pub const Error = walk.Error;
pub const Options = walk.Options;
pub const Stats = walk.Stats;
pub const depth_limit = walk.depth_limit;
pub const entries_per_directory_max = walk.entries_per_directory_max;
pub const enumerate = walk.enumerate;
