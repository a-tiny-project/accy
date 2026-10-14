const std = @import("std");

pub const Kind = enum {
    gelu,
    relu,
    silu,

    pub fn fromName(name: []const u8) ?Kind {
        inline for (
            @typeInfo(Kind).@"enum".field_names,
            @typeInfo(Kind).@"enum".field_values,
        ) |field_name, field_name_value| {
            const field = .{ .name = field_name, .value = field_name_value };
            if (std.mem.eql(u8, name, field.name)) return @fromBackingInt(@intCast(field.value));
        }
        return null;
    }
};
