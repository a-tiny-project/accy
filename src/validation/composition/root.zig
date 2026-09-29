const sys = @import("sys");

const supports_hybrid_host = sys.capabilities.current.supportsX86_64Execution();

pub const host = if (supports_hybrid_host) @import("host.zig") else struct {};
pub const model = @import("model.zig");
pub const source = @import("source.zig");

pub const fixture = @import("fixture.zig");
