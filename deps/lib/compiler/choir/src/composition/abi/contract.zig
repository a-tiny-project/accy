const std = @import("std");
const source = @import("../source/root.zig");

pub const version: u32 = 1;
pub const invoke_symbol = "choir_compose_invoke_v1";
pub const max_resources: u32 = 1024;

pub const Status = enum(u32) {
    ok = 0,
    incompatible_context = 1,
    incompatible_frame = 2,
    unknown_call_site = 3,
    missing_fragment = 4,
    invalid_resource = 5,
    fragment_failure = 6,
    composition_closing = 7,
};

pub const Access = source.Access;

pub fn decodeStatus(raw: anytype) Status {
    const value = std.math.cast(u32, raw) orelse return .fragment_failure;
    inline for (std.meta.tags(Status)) |status| {
        if (value == @backingInt(status)) return status;
    }
    return .fragment_failure;
}

pub fn decodeAccess(raw: u32) ?Access {
    inline for (std.meta.tags(Access)) |access| {
        if (raw == @backingInt(access)) return access;
    }
    return null;
}
