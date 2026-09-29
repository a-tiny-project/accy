pub fn writeNull(writer: anytype) !void {
    try writer.writeAll("null");
}

pub fn writeBool(writer: anytype, value: bool) !void {
    try writer.writeAll(if (value) "true" else "false");
}

pub fn writeInt(writer: anytype, value: anytype) !void {
    try writer.print("{d}", .{value});
}

pub fn writeNumberString(writer: anytype, value: []const u8) !void {
    try writer.writeAll(value);
}
