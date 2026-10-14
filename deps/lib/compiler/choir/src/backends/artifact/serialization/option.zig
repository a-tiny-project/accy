const std = @import("std");
const artifact = @import("../root.zig");
const format = @import("root.zig").format;

pub fn write(writer: *format.Writer, value: artifact.Options) format.WriteError!void {
    try writer.writeCount(value.values.items.len);
    for (value.values.items) |option| {
        try writer.writeString(option.key);
        try writer.writeTag(std.meta.activeTag(option.value));
        switch (option.value) {
            .flag => |flag| try writer.writeBool(flag),
            .signed => |signed| try writer.writeInt(i64, signed),
            .unsigned => |unsigned| try writer.writeInt(u64, unsigned),
            .text => |text| try writer.writeString(text),
            .bytes => |bytes| try writer.writeBlob(bytes),
        }
    }
}

pub fn readInto(reader: *format.Reader, value: *artifact.Options) (format.Error || std.mem.Allocator.Error)!void {
    const count = try reader.readCount();
    for (0..count) |_| {
        const key = try reader.readString();
        const option_value: artifact.OptionValue = switch (try reader.readTag(artifact.OptionValueTag)) {
            .flag => .{ .flag = try reader.readBool() },
            .signed => .{ .signed = try reader.readInt(i64) },
            .unsigned => .{ .unsigned = try reader.readInt(u64) },
            .text => .{ .text = try reader.readString() },
            .bytes => .{ .bytes = try reader.readBlob() },
        };
        try value.add(.{ .key = key, .value = option_value });
    }
}
