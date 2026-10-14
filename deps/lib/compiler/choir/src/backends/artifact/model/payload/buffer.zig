const std = @import("std");
const payload = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const BufferFormat = enum(u8) {
    raw = 1,
    machine_code = 2,
    object_file = 3,
    webassembly_module = 4,
    assembly = 5,
    source_text = 6,
    debug_section = 7,
    vendor = 8,
};

pub const ArtifactBuffer = struct {
    name: []const u8,
    format: BufferFormat,
    bytes: []const u8,
    alignment: usize = 1,

    pub fn dupe(self: ArtifactBuffer, allocator: Allocator) Allocator.Error!ArtifactBuffer {
        const name = try payload.slice.dupe(allocator, self.name);
        errdefer payload.slice.free(allocator, name);
        return .{
            .name = name,
            .format = self.format,
            .bytes = try payload.slice.dupe(allocator, self.bytes),
            .alignment = self.alignment,
        };
    }

    pub fn deinit(self: ArtifactBuffer, allocator: Allocator) void {
        payload.slice.free(allocator, self.name);
        payload.slice.free(allocator, self.bytes);
    }

    pub fn eql(self: ArtifactBuffer, other: ArtifactBuffer) bool {
        return self.format == other.format and
            self.alignment == other.alignment and
            std.mem.eql(u8, self.name, other.name) and
            std.mem.eql(u8, self.bytes, other.bytes);
    }
};
