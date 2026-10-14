const std = @import("std");
const choir = @import("../../../root.zig");
const composition = @import("../../root.zig");
const model = @import("../root.zig");
const serialization = @import("root.zig");

const artifact = choir.backends.artifact;
const product = choir.product;
const source = composition.source;
const Reader = serialization.format.Reader;
const Writer = serialization.format.Writer;

pub fn write(
    writer: *Writer,
    value: model.Fragment,
    manifests: *serialization.reference.Manifests,
) serialization.SerializeError!void {
    try writer.writeInt(u64, value.id.value);
    try writer.writeInt(u64, value.partition.value);
    try writer.writeTag(value.pipeline);
    try writeProduct(writer, value.pipeline_input, manifests);
    try writer.writeCount(value.artifacts.len);
    for (value.artifacts) |artifact_value| try writeArtifact(writer, artifact_value);
    try writer.writeCount(value.exports.len);
    for (value.exports) |export_value| try writeExport(writer, export_value);
    try writer.writeCount(value.imports.len);
    for (value.imports) |import_value| try writeImport(writer, import_value);
    try serialization.provenance.write(writer, value.provenance);
}

pub fn read(
    allocator: std.mem.Allocator,
    reader: *Reader,
    module: *model.CompositionModule,
    records: *product.revision.Store,
    manifests: *const serialization.reference.Manifests,
) serialization.DeserializeError!void {
    const id = source.FragmentId{ .value = try reader.readInt(u64) };
    const partition = source.PartitionId{ .value = try reader.readInt(u64) };
    const pipeline = try reader.readTag(source.Pipeline);
    const pipeline_input = try serialization.reference.readRecord(records, reader, manifests);

    const artifact_count = try reader.readCount();
    const artifacts = try allocator.alloc(artifact.Artifact, artifact_count);
    var artifacts_initialized: usize = 0;
    defer {
        var index = artifacts_initialized;
        while (index != 0) {
            index -= 1;
            artifacts[index].deinit();
        }
        allocator.free(artifacts);
    }
    for (artifacts) |*artifact_value| {
        artifact_value.* = try readArtifact(allocator, reader);
        artifacts_initialized += 1;
    }

    const export_count = try reader.readCount();
    const exports = try allocator.alloc(model.ExportSpec, export_count);
    defer allocator.free(exports);
    for (exports) |*export_value| export_value.* = try readExport(reader);

    const import_count = try reader.readCount();
    const imports = try allocator.alloc(model.ImportSpec, import_count);
    defer allocator.free(imports);
    for (imports) |*import_value| import_value.* = try readImport(reader);
    const provenance = try serialization.provenance.read(reader);

    try module.addFragment(.{
        .id = id,
        .partition = partition,
        .pipeline = pipeline,
        .pipeline_input = pipeline_input,
        .artifacts = artifacts,
        .exports = exports,
        .imports = imports,
        .provenance = provenance,
    });
}

fn writeProduct(
    writer: *Writer,
    key: product.ProductKey,
    manifests: *serialization.reference.Manifests,
) serialization.SerializeError!void {
    try writer.writeBlob(key.record.bytes());
    try writer.writeInt(u32, @intCast(try manifests.intern(key.record.compilerManifest())));
}

fn writeArtifact(writer: *Writer, value: artifact.Artifact) serialization.SerializeError!void {
    const bytes = try artifact.serialization.serialize(writer.allocator, &value);
    defer writer.allocator.free(bytes);
    try writer.writeBlob(bytes);
}

fn readArtifact(allocator: std.mem.Allocator, reader: *Reader) serialization.DeserializeError!artifact.Artifact {
    return try artifact.serialization.deserialize(allocator, try reader.readBlob());
}

fn writeExport(writer: *Writer, value: model.Export) serialization.SerializeError!void {
    try writer.writeString(value.name);
    try writer.writeString(value.symbol);
    try writer.writeInt(u32, value.abi_version);
}

fn readExport(reader: *Reader) serialization.DeserializeError!model.ExportSpec {
    const name = try reader.readString();
    const symbol = try reader.readString();
    const abi_version = try reader.readInt(u32);
    return .{
        .name = name,
        .symbol = symbol,
        .abi_version = abi_version,
    };
}

fn writeImport(writer: *Writer, value: model.Import) serialization.SerializeError!void {
    try writer.writeString(value.name);
    try writer.writeString(value.symbol);
    try writer.writeInt(u32, value.abi_version);
    try writer.writeTag(value.kind);
}

fn readImport(reader: *Reader) serialization.DeserializeError!model.ImportSpec {
    const name = try reader.readString();
    const symbol = try reader.readString();
    const abi_version = try reader.readInt(u32);
    const kind = try reader.readTag(model.ImportKind);
    return .{
        .name = name,
        .symbol = symbol,
        .abi_version = abi_version,
        .kind = kind,
    };
}
