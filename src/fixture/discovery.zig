const std = @import("std");

pub fn discover(comptime Namespace: type) void {
    inline for (comptime std.meta.declarations(Namespace)) |name| {
        if (@typeInfo(@TypeOf(@field(Namespace, name))) != .@"fn") {
            _ = &@field(Namespace, name);
        }
    }
}
