const std = @import("std");
const composition = @import("../../root.zig");
const model = @import("../root.zig");
const serialization = @import("root.zig");

const source = composition.source;
const Reader = serialization.format.Reader;
const Writer = serialization.format.Writer;

pub fn write(writer: *Writer, value: model.CallSite) serialization.SerializeError!void {
    try writer.writeInt(u64, value.id.value);
    try writer.writeString(value.name);
    try writer.writeInt(u64, value.caller.value);
    try writer.writeString(value.caller_export);
    try writer.writeString(value.runtime_import);
    try writer.writeInt(u64, value.callee.value);
    try writer.writeString(value.callee_export);
    try serialization.source.writeBoundaryIds(writer, value.inputs);
    try serialization.source.writeBoundaryIds(writer, value.outputs);
    try writer.writeInt(u32, value.abi_version);
    try serialization.provenance.write(writer, value.provenance);
}

pub fn read(
    allocator: std.mem.Allocator,
    reader: *Reader,
) serialization.DeserializeError!model.CallSiteSpec {
    const id = source.CallSiteId{ .value = try reader.readInt(u64) };
    const name = try reader.readString();
    const caller = source.FragmentId{ .value = try reader.readInt(u64) };
    const caller_export = try reader.readString();
    const runtime_import = try reader.readString();
    const callee = source.FragmentId{ .value = try reader.readInt(u64) };
    const callee_export = try reader.readString();
    const inputs = try serialization.source.readBoundaryIds(allocator, reader);
    errdefer allocator.free(inputs);
    const outputs = try serialization.source.readBoundaryIds(allocator, reader);
    errdefer allocator.free(outputs);
    const abi_version = try reader.readInt(u32);
    const provenance = try serialization.provenance.read(reader);
    return .{
        .id = id,
        .name = name,
        .caller = caller,
        .caller_export = caller_export,
        .runtime_import = runtime_import,
        .callee = callee,
        .callee_export = callee_export,
        .inputs = inputs,
        .outputs = outputs,
        .abi_version = abi_version,
        .provenance = provenance,
    };
}

pub fn deinitReadSpec(allocator: std.mem.Allocator, spec: model.CallSiteSpec) void {
    allocator.free(spec.outputs);
    allocator.free(spec.inputs);
}
