const sys = @import("../root.zig");

pub const required_capabilities = sys.capabilities.host(&.{.platform_frameworks});

pub const coregraphics = @import("coregraphics.zig");
pub const cocoa = @import("cocoa.zig");
pub const dispatch = @import("dispatch.zig");
pub const foundation = @import("foundation.zig");
pub const gamecontroller = @import("gamecontroller.zig");
pub const metal = @import("metal.zig");
pub const objc = @import("objc.zig");
