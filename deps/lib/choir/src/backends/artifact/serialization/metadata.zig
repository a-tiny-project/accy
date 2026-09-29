const std = @import("std");
const artifact = @import("../root.zig");
const format = @import("root.zig").format;

pub const Decoded = struct {
    allocator: std.mem.Allocator,
    value: artifact.Metadata,

    pub fn deinit(self: *Decoded) void {
        self.allocator.free(@constCast(self.value.target.features));
        self.* = undefined;
    }
};

pub fn write(writer: *format.Writer, value: artifact.Metadata) format.WriteError!void {
    try writer.writeTag(value.kind);
    try writer.writeOptionalString(value.producer);
    try writer.writeTag(value.target.architecture);
    try writer.writeOptionalString(value.target.triple);
    try writer.writeOptionalString(value.target.vendor);
    try writer.writeOptionalString(value.target.os);
    try writer.writeOptionalString(value.target.environment);
    try writer.writeOptionalString(value.target.cpu);
    try writer.writeCount(value.target.features.len);
    for (value.target.features) |feature| try writer.writeString(feature);
    try writer.writeOptionalString(value.abi.name);
    try writer.writeOptionalString(value.abi.calling_convention);
    try writer.writeOptionalString(value.abi.object_format);
    try writer.writeOptionalU16(value.abi.pointer_width_bits);
    try writer.writeBool(value.abi.endianness != null);
    if (value.abi.endianness) |endianness| try writer.writeTag(endianness);
}

pub fn read(allocator: std.mem.Allocator, reader: *format.Reader) (format.Error || std.mem.Allocator.Error)!Decoded {
    const kind = try reader.readTag(artifact.ArtifactKind);
    const producer = try reader.readOptionalString();
    const architecture = try reader.readTag(artifact.Architecture);
    const triple = try reader.readOptionalString();
    const vendor = try reader.readOptionalString();
    const os = try reader.readOptionalString();
    const environment = try reader.readOptionalString();
    const cpu = try reader.readOptionalString();
    const feature_count = try reader.readCount();
    const features = try allocator.alloc([]const u8, feature_count);
    errdefer allocator.free(features);
    for (features) |*feature| feature.* = try reader.readString();
    const abi_name = try reader.readOptionalString();
    const calling_convention = try reader.readOptionalString();
    const object_format = try reader.readOptionalString();
    const pointer_width_bits = try reader.readOptionalU16();
    const endianness = if (try reader.readBool()) try reader.readTag(artifact.Endianness) else null;
    return .{
        .allocator = allocator,
        .value = .{
            .kind = kind,
            .producer = producer,
            .target = .{
                .architecture = architecture,
                .triple = triple,
                .vendor = vendor,
                .os = os,
                .environment = environment,
                .cpu = cpu,
                .features = features,
            },
            .abi = .{
                .name = abi_name,
                .calling_convention = calling_convention,
                .object_format = object_format,
                .pointer_width_bits = pointer_width_bits,
                .endianness = endianness,
            },
        },
    };
}
