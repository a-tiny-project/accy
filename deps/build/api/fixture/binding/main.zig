const std = @import("std");
const settings = @import("settings");

pub fn main() void {
    std.process.exit(settings.value);
}
