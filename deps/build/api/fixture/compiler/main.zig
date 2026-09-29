const std = @import("std");
const settings = @import("settings");
const constants = @import("constants");

pub fn main() void {
    std.debug.assert(!settings.enabled);
    std.debug.assert(std.mem.eql(u8, constants.value, "generated compiler input\n"));
}
