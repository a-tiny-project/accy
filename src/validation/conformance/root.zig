const sys = @import("sys");

pub const cases = @import("cases.zig");
pub const harness = @import("harness.zig");
pub const records = @import("records.zig");

const run = @import("run.zig");

pub fn main(init: sys.process.Init) !void {
    try run.main(init);
}
