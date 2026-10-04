const std = @import("std");
const model = @import("../root.zig");
const serialization = @import("root.zig");
const format = serialization.format;
const source = serialization.source;
const fragment = serialization.fragment;
const variant = serialization.variant;
const SerializeError = serialization.SerializeError;
const DeserializeError = serialization.DeserializeError;

pub fn serialize(
    allocator: std.mem.Allocator,
    module: *const model.CompositionModule,
) SerializeError![]u8 {
    try module.verify();
    var manifests = serialization.reference.Manifests{};
    for (module.fragments.items) |fragment_value| {
        _ = try manifests.intern(fragment_value.pipeline_input.record.compilerManifest());
    }
    var writer = try format.initWriter(allocator);
    errdefer writer.deinit();
    try source.write(&writer, &module.source_module);
    try serialization.reference.writeManifests(&writer, &manifests);
    try writer.writeCount(module.fragments.items.len);
    for (module.fragments.items) |fragment_value| {
        try fragment.write(&writer, fragment_value, &manifests);
    }
    try writer.writeCount(module.variants.items.len);
    for (module.variants.items) |variant_value| try variant.write(&writer, variant_value);
    return try format.finishWriter(&writer);
}

pub fn deserialize(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) DeserializeError!model.CompositionModule {
    var reader = try format.readPayload(bytes);
    var source_module = try source.read(allocator, &reader);
    var source_owned = true;
    errdefer if (source_owned) source_module.deinit();
    var module = model.CompositionModule{
        .allocator = allocator,
        .source_module = source_module,
    };
    source_owned = false;
    errdefer module.deinit();

    const manifests = try serialization.reference.readManifests(&reader);
    const fragment_count = try reader.readCount();
    const records = try serialization.reference.createStore(allocator, fragment_count);
    defer records.release();
    for (0..fragment_count) |_| {
        try fragment.read(allocator, &reader, &module, records, &manifests);
    }
    const variant_count = try reader.readCount();
    for (0..variant_count) |_| try variant.read(allocator, &reader, &module);
    if (!reader.atEnd()) return error.TrailingBytes;
    try module.verify();
    return module;
}
