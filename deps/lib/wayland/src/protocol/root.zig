pub const schema = @import("schema.zig");
pub const generated = @import("generated/root.zig");
pub const value = @import("value/root.zig");
pub const bootstrap = @import("bootstrap/root.zig");

pub const core = generated.core;
pub const desktop = generated.desktop;
pub const extensions = generated.extensions;
pub const source = generated.source;
pub const interfaces = core.interfaces ++ desktop.interfaces;

pub fn findInterface(name: []const u8) ?*const schema.Interface {
    return schema.findInterface(&interfaces, name);
}
