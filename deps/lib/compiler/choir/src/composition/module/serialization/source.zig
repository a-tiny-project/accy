const std = @import("std");
const composition = @import("../../root.zig");
const serialization = @import("root.zig");

const source = composition.source;
const Reader = serialization.format.Reader;
const Writer = serialization.format.Writer;

pub fn write(writer: *Writer, module: *const source.PartitionedModule) serialization.SerializeError!void {
    try writer.writeString(module.name);
    try writer.writeCount(module.boundaries.items.len);
    for (module.boundaries.items) |boundary_value| try writeBoundary(writer, boundary_value);
    try writer.writeCount(module.partitions.items.len);
    for (module.partitions.items) |partition_value| try writePartition(writer, partition_value);
    try writer.writeCount(module.call_sites.items.len);
    for (module.call_sites.items) |call_site| try writeCall(writer, call_site);
}

pub fn read(allocator: std.mem.Allocator, reader: *Reader) serialization.DeserializeError!source.PartitionedModule {
    var module = try source.PartitionedModule.init(allocator, try reader.readString());
    errdefer module.deinit();

    const boundary_count = try reader.readCount();
    for (0..boundary_count) |_| try readBoundary(allocator, reader, &module);
    const partition_count = try reader.readCount();
    for (0..partition_count) |_| try readPartition(allocator, reader, &module);
    const call_count = try reader.readCount();
    for (0..call_count) |_| try readCall(allocator, reader, &module);
    return module;
}

fn writeBoundary(writer: *Writer, value: source.Boundary) serialization.SerializeError!void {
    try writer.writeInt(u64, value.id.value);
    try writer.writeString(value.name);
    try writer.writeTag(value.element_type);
    try writeDimensions(writer, value.dimensions);
    try writer.writeInt(u64, value.byte_size);
    try writer.writeTag(value.access);
    try writer.writeTag(value.ownership);
    try writeAlias(writer, value.alias);
    try serialization.provenance.write(writer, value.provenance);
}

fn readBoundary(
    allocator: std.mem.Allocator,
    reader: *Reader,
    module: *source.PartitionedModule,
) serialization.DeserializeError!void {
    const id = source.BoundaryId{ .value = try reader.readInt(u64) };
    const name = try reader.readString();
    const element_type = try reader.readTag(source.ElementType);
    const dimensions = try readDimensions(allocator, reader);
    defer allocator.free(dimensions);
    const byte_size = try reader.readInt(u64);
    const access = try reader.readTag(source.Access);
    const ownership = try reader.readTag(source.Ownership);
    const alias = try readAlias(reader);
    const provenance = try serialization.provenance.read(reader);
    try module.addBoundary(.{
        .id = id,
        .name = name,
        .element_type = element_type,
        .dimensions = dimensions,
        .byte_size = byte_size,
        .access = access,
        .ownership = ownership,
        .alias = alias,
        .provenance = provenance,
    });
}

fn writeAlias(writer: *Writer, alias: source.Alias) serialization.SerializeError!void {
    const Tag = std.meta.Tag(source.Alias);
    try writer.writeTag(@as(Tag, alias));
    switch (alias) {
        .disjoint => {},
        .boundary => |id| try writer.writeInt(u64, id.value),
    }
}

fn readAlias(reader: *Reader) serialization.DeserializeError!source.Alias {
    const Tag = std.meta.Tag(source.Alias);
    return switch (try reader.readTag(Tag)) {
        .disjoint => .disjoint,
        .boundary => .{ .boundary = .{ .value = try reader.readInt(u64) } },
    };
}

fn writePartition(writer: *Writer, value: source.Partition) serialization.SerializeError!void {
    try writer.writeInt(u64, value.id.value);
    try writer.writeString(value.name);
    try writer.writeTag(value.pipeline);
    try writeBoundaryIds(writer, value.inputs);
    try writeBoundaryIds(writer, value.outputs);
    try serialization.reference.writeAddress(writer, value.product);
    try writer.writeTag(value.effect);
    try serialization.provenance.write(writer, value.provenance);
}

fn readPartition(
    allocator: std.mem.Allocator,
    reader: *Reader,
    module: *source.PartitionedModule,
) serialization.DeserializeError!void {
    const id = source.PartitionId{ .value = try reader.readInt(u64) };
    const name = try reader.readString();
    const pipeline = try reader.readTag(source.Pipeline);
    const inputs = try readBoundaryIds(allocator, reader);
    defer allocator.free(inputs);
    const outputs = try readBoundaryIds(allocator, reader);
    defer allocator.free(outputs);
    const address = try serialization.reference.readAddress(reader);
    const effect = try reader.readTag(source.Effect);
    const provenance = try serialization.provenance.read(reader);
    try module.addPartition(.{
        .id = id,
        .name = name,
        .pipeline = pipeline,
        .inputs = inputs,
        .outputs = outputs,
        .product = address,
        .effect = effect,
        .provenance = provenance,
    });
}

fn writeCall(writer: *Writer, value: source.SemanticCallSite) serialization.SerializeError!void {
    try writer.writeInt(u64, value.id.value);
    try writer.writeString(value.name);
    try writer.writeInt(u64, value.caller.value);
    try writer.writeInt(u64, value.callee.value);
    try writeBoundaryIds(writer, value.inputs);
    try writeBoundaryIds(writer, value.outputs);
    try serialization.provenance.write(writer, value.provenance);
}

fn readCall(
    allocator: std.mem.Allocator,
    reader: *Reader,
    module: *source.PartitionedModule,
) serialization.DeserializeError!void {
    const id = source.CallSiteId{ .value = try reader.readInt(u64) };
    const name = try reader.readString();
    const caller = source.PartitionId{ .value = try reader.readInt(u64) };
    const callee = source.PartitionId{ .value = try reader.readInt(u64) };
    const inputs = try readBoundaryIds(allocator, reader);
    defer allocator.free(inputs);
    const outputs = try readBoundaryIds(allocator, reader);
    defer allocator.free(outputs);
    const provenance = try serialization.provenance.read(reader);
    try module.addCallSite(.{
        .id = id,
        .name = name,
        .caller = caller,
        .callee = callee,
        .inputs = inputs,
        .outputs = outputs,
        .provenance = provenance,
    });
}

pub fn writeBoundaryIds(writer: *Writer, ids: []const source.BoundaryId) serialization.SerializeError!void {
    try writer.writeCount(ids.len);
    for (ids) |id| try writer.writeInt(u64, id.value);
}

pub fn readBoundaryIds(allocator: std.mem.Allocator, reader: *Reader) serialization.DeserializeError![]source.BoundaryId {
    const count = try reader.readCount();
    const ids = try allocator.alloc(source.BoundaryId, count);
    errdefer allocator.free(ids);
    for (ids) |*id| id.* = .{ .value = try reader.readInt(u64) };
    return ids;
}

fn writeDimensions(writer: *Writer, dimensions: []const u64) serialization.SerializeError!void {
    try writer.writeCount(dimensions.len);
    for (dimensions) |dimension| try writer.writeInt(u64, dimension);
}

fn readDimensions(allocator: std.mem.Allocator, reader: *Reader) serialization.DeserializeError![]u64 {
    const count = try reader.readCount();
    const dimensions = try allocator.alloc(u64, count);
    errdefer allocator.free(dimensions);
    for (dimensions) |*dimension| dimension.* = try reader.readInt(u64);
    return dimensions;
}
