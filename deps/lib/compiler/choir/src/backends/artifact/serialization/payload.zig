const std = @import("std");
const artifact = @import("../root.zig");
const format = @import("root.zig").format;

pub fn write(writer: *format.Writer, value: artifact.Payload) format.WriteError!void {
    try writer.writeCount(value.debug_records.items.len);
    for (value.debug_records.items) |record| {
        try writer.writeString(record.name);
        try writer.writeTag(record.kind);
        try writer.writeBlob(record.bytes);
    }
    try writer.writeCount(value.buffers.items.len);
    for (value.buffers.items) |buffer| {
        try writer.writeString(buffer.name);
        try writer.writeTag(buffer.format);
        try writer.writeBlob(buffer.bytes);
        const alignment = std.math.cast(u64, buffer.alignment) orelse return error.LimitExceeded;
        try writer.writeInt(u64, alignment);
    }
    try writer.writeCount(value.text_dumps.items.len);
    for (value.text_dumps.items) |dump| {
        try writer.writeString(dump.name);
        try writer.writeBlob(dump.contents);
    }
}

pub fn readInto(reader: *format.Reader, value: *artifact.Payload) (format.Error || std.mem.Allocator.Error)!void {
    const debug_count = try reader.readCount();
    for (0..debug_count) |_| {
        try value.addDebugRecord(.{
            .name = try reader.readString(),
            .kind = try reader.readTag(artifact.DebugRecordKind),
            .bytes = try reader.readBlob(),
        });
    }
    const buffer_count = try reader.readCount();
    for (0..buffer_count) |_| {
        const name = try reader.readString();
        const buffer_format = try reader.readTag(artifact.BufferFormat);
        const bytes = try reader.readBlob();
        const alignment = std.math.cast(usize, try reader.readInt(u64)) orelse return error.LimitExceeded;
        try value.addBuffer(.{
            .name = name,
            .format = buffer_format,
            .bytes = bytes,
            .alignment = alignment,
        });
    }
    const text_count = try reader.readCount();
    for (0..text_count) |_| {
        try value.addTextDump(.{
            .name = try reader.readString(),
            .contents = try reader.readBlob(),
        });
    }
}
