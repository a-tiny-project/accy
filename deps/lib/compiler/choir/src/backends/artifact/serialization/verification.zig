const std = @import("std");
const artifact = @import("../root.zig");
const format = @import("root.zig").format;

pub fn write(writer: *format.Writer, value: artifact.VerificationStatus) format.WriteError!void {
    try writer.writeTag(value.state);
    try writer.writeOptionalString(value.stage);
    try writer.writeOptionalString(value.message);
}

pub fn readInto(
    reader: *format.Reader,
    allocator: std.mem.Allocator,
    value: *artifact.VerificationStatus,
) (format.Error || std.mem.Allocator.Error)!void {
    try value.replace(allocator, .{
        .state = try reader.readTag(artifact.VerificationState),
        .stage = try reader.readOptionalString(),
        .message = try reader.readOptionalString(),
    });
}
