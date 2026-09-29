const fixture = @import("../../fixture/root.zig");
const std = @import("std");
const serialization = @import("root.zig");
const model = @import("../root.zig");
const source_model = @import("../../source/root.zig");
const abi = @import("../../root.zig").abi;
const artifact = @import("../../../backends/root.zig").artifact;
const product = @import("../../../product/root.zig");

const format = serialization.format;
const serialize = serialization.serialize;
const deserialize = serialization.deserialize;

test {
    std.testing.refAllDecls(serialization);
    _ = serialization.reference;
    _ = serialization.codec;
}

fn testModule(allocator: std.mem.Allocator) !model.CompositionModule {
    const records = try fixture.Records.init(allocator);
    defer records.deinit();
    var partitioned = try source_model.PartitionedModule.init(allocator, "hybrid.persisted");
    defer partitioned.deinit();
    try partitioned.addBoundary(.{
        .id = .{ .value = 1 },
        .name = "lhs",
        .element_type = .f32,
        .dimensions = &.{8},
        .byte_size = 32,
        .access = .read_write,
        .ownership = .borrowed,
        .alias = .disjoint,
        .provenance = .{ .path = "persisted.chic", .symbol = "lhs", .line = 9, .column = 2 },
    });
    try partitioned.addBoundary(.{
        .id = .{ .value = 2 },
        .name = "rhs",
        .element_type = .f32,
        .dimensions = &.{8},
        .byte_size = 32,
        .access = .read_write,
        .ownership = .borrowed,
        .alias = .{ .boundary = .{ .value = 1 } },
        .provenance = .{ .path = "persisted.chic", .symbol = "rhs", .line = 10, .column = 2 },
    });
    try partitioned.addBoundary(.{
        .id = .{ .value = 3 },
        .name = "result",
        .element_type = .key,
        .dimensions = &.{4},
        .byte_size = 32,
        .access = .write,
        .ownership = .produced,
        .alias = .disjoint,
        .provenance = .{ .path = "persisted.chic", .symbol = "result", .line = 11, .column = 3 },
    });
    try partitioned.addPartition(.{
        .id = .{ .value = 10 },
        .name = "host",
        .pipeline = .choir,
        .outputs = &.{.{ .value = 1 }},
        .product = .{ .producer = "composition-fixture", .source = "101", .stage = "hybrid.host.input", .variant = "default" },
        .effect = .unknown,
        .provenance = .{ .path = "persisted.chic", .symbol = "host", .line = 7, .column = 3 },
    });
    try partitioned.addPartition(.{
        .id = .{ .value = 11 },
        .name = "kernel",
        .pipeline = .accy,
        .inputs = &.{ .{ .value = 1 }, .{ .value = 2 } },
        .outputs = &.{.{ .value = 3 }},
        .product = .{ .producer = "composition-fixture", .source = "103", .stage = "hybrid.kernel.input", .variant = "default" },
        .effect = .none,
        .provenance = .{ .path = "persisted.chic", .symbol = "kernel", .line = 11, .column = 5 },
    });
    try partitioned.addCallSite(.{
        .id = .{ .value = 30 },
        .name = "host/kernel",
        .caller = .{ .value = 10 },
        .callee = .{ .value = 11 },
        .inputs = &.{ .{ .value = 1 }, .{ .value = 2 } },
        .outputs = &.{.{ .value = 3 }},
        .provenance = .{ .path = "persisted.chic", .symbol = "kernel", .line = 12, .column = 9 },
    });

    var host_artifact = try artifact.Artifact.init(allocator, .{
        .kind = .machine_code,
        .producer = "choir-x64",
        .target = .{
            .architecture = .x86_64,
            .triple = "x86_64-unknown-linux-gnu",
            .vendor = "unknown",
            .os = "linux",
            .environment = "gnu",
            .cpu = "x86-64-v3",
            .features = &.{ "sse2", "+avx2" },
        },
        .abi = .{
            .name = "sysv",
            .calling_convention = "c",
            .object_format = "elf",
            .pointer_width_bits = 64,
            .endianness = .little,
        },
    });
    defer host_artifact.deinit();
    try host_artifact.options.add(.{ .key = "checked", .value = .{ .flag = true } });
    try host_artifact.options.add(.{ .key = "bias", .value = .{ .signed = -17 } });
    try host_artifact.options.add(.{ .key = "seed", .value = .{ .unsigned = 0xfedcba9876543210 } });
    try host_artifact.options.add(.{ .key = "mode", .value = .{ .text = "durable" } });
    try host_artifact.options.add(.{ .key = "opaque", .value = .{ .bytes = &.{ 0, 255, 7 } } });
    try host_artifact.linkage.addRequired(.{ .name = abi.invoke_symbol, .kind = .runtime, .binding = .external });
    try host_artifact.linkage.addRequired(.{ .name = "weak_data", .kind = .data, .binding = .weak });
    try host_artifact.linkage.addProvided(.{ .name = "host_entry", .kind = .function, .binding = .external });
    try host_artifact.linkage.addProvided(.{ .name = "local_data", .kind = .data, .binding = .local });
    try host_artifact.linkage.addRelocation(.{
        .offset = 2,
        .symbol = abi.invoke_symbol,
        .kind = .call,
        .addend = -4,
        .width_bits = 64,
    });
    try host_artifact.payload.addDebugRecord(.{ .name = ".debug_line", .kind = .dwarf_section, .bytes = &.{ 1, 0, 2, 0 } });
    try host_artifact.payload.addBuffer(.{ .name = "host_entry", .format = .machine_code, .bytes = &.{ 0x48, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xd0, 0xc3 }, .alignment = 32 });
    try host_artifact.payload.addTextDump(.{ .name = "lowered", .contents = "func @host_entry" });
    try host_artifact.verification.replace(host_artifact.allocator, .{ .state = .failed, .stage = "machine-verify", .message = "preserved diagnostic" });

    var kernel_artifact = try artifact.Artifact.init(allocator, .{
        .kind = .object_file,
        .producer = "accy-cpu",
        .target = .{ .architecture = .x86_64 },
    });
    defer kernel_artifact.deinit();
    try kernel_artifact.linkage.addProvided(.{ .name = "kernel_entry", .kind = .function, .binding = .external });
    try kernel_artifact.payload.addBuffer(.{ .name = "kernel_entry", .format = .object_file, .bytes = &.{ 0x7f, 'E', 'L', 'F' }, .alignment = 8 });
    try kernel_artifact.verification.replace(kernel_artifact.allocator, .{ .state = .skipped });

    var module = try model.CompositionModule.init(allocator, &partitioned);
    errdefer module.deinit();
    try module.addFragment(.{
        .id = .{ .value = 20 },
        .partition = .{ .value = 10 },
        .pipeline = .choir,
        .pipeline_input = try records.key("hybrid.host.input", "101", "201"),

        .artifacts = &.{host_artifact},
        .exports = &.{.{ .name = "host", .symbol = "host_entry", .abi_version = abi.version }},
        .imports = &.{.{ .name = "invoke", .symbol = abi.invoke_symbol, .abi_version = abi.version, .kind = .runtime }},
        .provenance = .{ .path = "persisted.chic", .symbol = "host_entry", .line = 20, .column = 4 },
    });
    try module.addFragment(.{
        .id = .{ .value = 21 },
        .partition = .{ .value = 11 },
        .pipeline = .accy,
        .pipeline_input = try records.key("hybrid.kernel.input", "103", "203"),

        .artifacts = &.{kernel_artifact},
        .exports = &.{.{ .name = "kernel", .symbol = "kernel_entry", .abi_version = abi.version }},
        .provenance = .{ .path = "persisted.chic", .symbol = "kernel_entry", .line = 24, .column = 8 },
    });
    try module.addFragment(.{
        .id = .{ .value = 22 },
        .partition = .{ .value = 11 },
        .pipeline = .accy,
        .pipeline_input = try records.key("hybrid.kernel.input", "103", "203"),

        .artifacts = &.{kernel_artifact},
        .exports = &.{.{ .name = "kernel", .symbol = "kernel_entry", .abi_version = abi.version }},
        .provenance = .{ .path = "persisted.chic", .symbol = "kernel_entry", .line = 24, .column = 8 },
    });
    try module.addVariant(.{
        .id = .{ .value = 1 },
        .choice = .{
            .target = product.productRef("composition-fixture", "301", "hybrid.target", "default"),
            .policy = product.productRef("composition-fixture", "302", "hybrid.policy", "default"),
        },
        .fragments = &.{ .{ .value = 20 }, .{ .value = 21 } },
        .call_sites = &.{.{
            .id = .{ .value = 30 },
            .name = "host/kernel",
            .caller = .{ .value = 20 },
            .caller_export = "host",
            .runtime_import = "invoke",
            .callee = .{ .value = 21 },
            .callee_export = "kernel",
            .inputs = &.{ .{ .value = 1 }, .{ .value = 2 } },
            .outputs = &.{.{ .value = 3 }},
            .abi_version = abi.version,
            .provenance = .{ .path = "persisted.chic", .symbol = "kernel", .line = 12, .column = 9 },
        }},
    });
    try module.addVariant(.{
        .id = .{ .value = 2 },
        .choice = .{
            .target = product.productRef("composition-fixture", "303", "hybrid.target", "default"),
            .policy = product.productRef("composition-fixture", "302", "hybrid.policy", "default"),
        },
        .fragments = &.{ .{ .value = 20 }, .{ .value = 22 } },
        .call_sites = &.{.{
            .id = .{ .value = 30 },
            .name = "host/kernel",
            .caller = .{ .value = 20 },
            .caller_export = "host",
            .runtime_import = "invoke",
            .callee = .{ .value = 22 },
            .callee_export = "kernel",
            .inputs = &.{ .{ .value = 1 }, .{ .value = 2 } },
            .outputs = &.{.{ .value = 3 }},
            .abi_version = abi.version,
            .provenance = .{ .path = "persisted.chic", .symbol = "kernel", .line = 12, .column = 9 },
        }},
    });
    try module.verify();
    return module;
}

fn expectProductEqual(expected: product.ProductKey, actual: product.ProductKey) !void {
    try std.testing.expect(expected.ref.eql(actual.ref));
    try std.testing.expectEqualSlices(u8, expected.record.bytes(), actual.record.bytes());
}

fn expectProvenanceEqual(expected: source_model.Provenance, actual: source_model.Provenance) !void {
    try std.testing.expectEqualStrings(expected.path, actual.path);
    try std.testing.expectEqualStrings(expected.symbol, actual.symbol);
    try std.testing.expectEqual(expected.line, actual.line);
    try std.testing.expectEqual(expected.column, actual.column);
}

fn expectBoundaryIdsEqual(expected: []const source_model.BoundaryId, actual: []const source_model.BoundaryId) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_id, actual_id| try std.testing.expectEqual(expected_id.value, actual_id.value);
}

fn expectModuleEqual(expected: *const model.CompositionModule, actual: *const model.CompositionModule) !void {
    try std.testing.expectEqualStrings(expected.source_module.name, actual.source_module.name);
    try std.testing.expectEqual(expected.source_module.boundaries.items.len, actual.source_module.boundaries.items.len);
    for (expected.source_module.boundaries.items, actual.source_module.boundaries.items) |expected_boundary, actual_boundary| {
        try std.testing.expectEqual(expected_boundary.id.value, actual_boundary.id.value);
        try std.testing.expectEqualStrings(expected_boundary.name, actual_boundary.name);
        try std.testing.expectEqual(expected_boundary.element_type, actual_boundary.element_type);
        try std.testing.expectEqualSlices(u64, expected_boundary.dimensions, actual_boundary.dimensions);
        try std.testing.expectEqual(expected_boundary.byte_size, actual_boundary.byte_size);
        try std.testing.expectEqual(expected_boundary.access, actual_boundary.access);
        try std.testing.expectEqual(expected_boundary.ownership, actual_boundary.ownership);
        try std.testing.expect(expected_boundary.alias.eql(actual_boundary.alias));
        try expectProvenanceEqual(expected_boundary.provenance, actual_boundary.provenance);
    }

    try std.testing.expectEqual(expected.source_module.partitions.items.len, actual.source_module.partitions.items.len);
    for (expected.source_module.partitions.items, actual.source_module.partitions.items) |expected_partition, actual_partition| {
        try std.testing.expectEqual(expected_partition.id.value, actual_partition.id.value);
        try std.testing.expectEqualStrings(expected_partition.name, actual_partition.name);
        try std.testing.expectEqual(expected_partition.pipeline, actual_partition.pipeline);
        try expectBoundaryIdsEqual(expected_partition.inputs, actual_partition.inputs);
        try expectBoundaryIdsEqual(expected_partition.outputs, actual_partition.outputs);
        try std.testing.expect(expected_partition.product.eql(actual_partition.product));
        try std.testing.expectEqual(expected_partition.effect, actual_partition.effect);
        try expectProvenanceEqual(expected_partition.provenance, actual_partition.provenance);
    }

    try std.testing.expectEqual(expected.source_module.call_sites.items.len, actual.source_module.call_sites.items.len);
    for (expected.source_module.call_sites.items, actual.source_module.call_sites.items) |expected_call, actual_call| {
        try std.testing.expectEqual(expected_call.id.value, actual_call.id.value);
        try std.testing.expectEqualStrings(expected_call.name, actual_call.name);
        try std.testing.expectEqual(expected_call.caller.value, actual_call.caller.value);
        try std.testing.expectEqual(expected_call.callee.value, actual_call.callee.value);
        try expectBoundaryIdsEqual(expected_call.inputs, actual_call.inputs);
        try expectBoundaryIdsEqual(expected_call.outputs, actual_call.outputs);
        try expectProvenanceEqual(expected_call.provenance, actual_call.provenance);
    }

    try std.testing.expectEqual(expected.fragments.items.len, actual.fragments.items.len);
    for (expected.fragments.items, actual.fragments.items) |expected_fragment, actual_fragment| {
        try std.testing.expectEqual(expected_fragment.id.value, actual_fragment.id.value);
        try std.testing.expectEqual(expected_fragment.partition.value, actual_fragment.partition.value);
        try std.testing.expectEqual(expected_fragment.pipeline, actual_fragment.pipeline);
        try expectProductEqual(expected_fragment.pipeline_input, actual_fragment.pipeline_input);
        try std.testing.expectEqual(expected_fragment.artifacts.len, actual_fragment.artifacts.len);
        for (expected_fragment.artifacts, actual_fragment.artifacts) |expected_artifact, actual_artifact| {
            try std.testing.expect(expected_artifact.eql(actual_artifact));
        }
        try std.testing.expectEqual(expected_fragment.exports.len, actual_fragment.exports.len);
        for (expected_fragment.exports, actual_fragment.exports) |expected_export, actual_export| {
            try std.testing.expectEqualStrings(expected_export.name, actual_export.name);
            try std.testing.expectEqualStrings(expected_export.symbol, actual_export.symbol);
            try std.testing.expectEqual(expected_export.abi_version, actual_export.abi_version);
        }
        try std.testing.expectEqual(expected_fragment.imports.len, actual_fragment.imports.len);
        for (expected_fragment.imports, actual_fragment.imports) |expected_import, actual_import| {
            try std.testing.expectEqualStrings(expected_import.name, actual_import.name);
            try std.testing.expectEqualStrings(expected_import.symbol, actual_import.symbol);
            try std.testing.expectEqual(expected_import.abi_version, actual_import.abi_version);
            try std.testing.expectEqual(expected_import.kind, actual_import.kind);
        }
        try expectProvenanceEqual(expected_fragment.provenance, actual_fragment.provenance);
    }

    try std.testing.expectEqual(expected.variants.items.len, actual.variants.items.len);
    for (expected.variants.items, actual.variants.items) |expected_variant, actual_variant| {
        try std.testing.expectEqual(expected_variant.id.value, actual_variant.id.value);
        try std.testing.expect(expected_variant.choice.target.eql(actual_variant.choice.target));
        try std.testing.expect(expected_variant.choice.policy.eql(actual_variant.choice.policy));
        try std.testing.expectEqual(expected_variant.fragments.len, actual_variant.fragments.len);
        for (expected_variant.fragments, actual_variant.fragments) |expected_fragment, actual_fragment| {
            try std.testing.expectEqual(expected_fragment.value, actual_fragment.value);
        }
        try std.testing.expectEqual(expected_variant.call_sites.len, actual_variant.call_sites.len);
        for (expected_variant.call_sites, actual_variant.call_sites) |expected_call, actual_call| {
            try std.testing.expectEqual(expected_call.id.value, actual_call.id.value);
            try std.testing.expectEqualStrings(expected_call.name, actual_call.name);
            try std.testing.expectEqual(expected_call.caller.value, actual_call.caller.value);
            try std.testing.expectEqualStrings(expected_call.caller_export, actual_call.caller_export);
            try std.testing.expectEqualStrings(expected_call.runtime_import, actual_call.runtime_import);
            try std.testing.expectEqual(expected_call.callee.value, actual_call.callee.value);
            try std.testing.expectEqualStrings(expected_call.callee_export, actual_call.callee_export);
            try expectBoundaryIdsEqual(expected_call.inputs, actual_call.inputs);
            try expectBoundaryIdsEqual(expected_call.outputs, actual_call.outputs);
            try std.testing.expectEqual(expected_call.abi_version, actual_call.abi_version);
            try expectProvenanceEqual(expected_call.provenance, actual_call.provenance);
        }
    }
}

test "composition module binary serialization round-trips every owned field" {
    const testing = std.testing;
    var original = try testModule(testing.allocator);
    var original_owned = true;
    defer if (original_owned) original.deinit();
    const encoded = try serialize(testing.allocator, &original);
    defer testing.allocator.free(encoded);
    try testing.expectEqual(@as(usize, 2885), encoded.len);
    try testing.expectEqual(@as(u32, 3643165904), format.checksum(encoded));

    var decoded = try deserialize(testing.allocator, encoded);
    defer decoded.deinit();
    try expectModuleEqual(&original, &decoded);
    try testing.expectEqual(@as(usize, 2), decoded.variants.items.len);
    const first_variant = decoded.selectVariant(.{
        .target = product.productRef("composition-fixture", "301", "hybrid.target", "default"),
        .policy = product.productRef("composition-fixture", "302", "hybrid.policy", "default"),
    }) orelse return error.TestExpectedResult;
    const second_variant = decoded.selectVariant(.{
        .target = product.productRef("composition-fixture", "303", "hybrid.target", "default"),
        .policy = product.productRef("composition-fixture", "302", "hybrid.policy", "default"),
    }) orelse return error.TestExpectedResult;
    try testing.expectEqualSlices(
        source_model.FragmentId,
        &.{ .{ .value = 20 }, .{ .value = 21 } },
        first_variant.fragments,
    );
    try testing.expectEqualSlices(
        source_model.FragmentId,
        &.{ .{ .value = 20 }, .{ .value = 22 } },
        second_variant.fragments,
    );
    try testing.expectEqual(source_model.Effect.unknown, decoded.source_module.partitions.items[0].effect);
    const reencoded = try serialize(testing.allocator, &decoded);
    defer testing.allocator.free(reencoded);
    try testing.expectEqualSlices(u8, encoded, reencoded);

    original.deinit();
    original_owned = false;
    @memset(encoded, 0);
    const independent = try serialize(testing.allocator, &decoded);
    defer testing.allocator.free(independent);
    try testing.expectEqualSlices(u8, reencoded, independent);
    try testing.expectEqualStrings("preserved diagnostic", decoded.fragments.items[0].artifacts[0].verification.message.?);
}

test "composition module round trip keeps two compilers apart at one product ref" {
    const testing = std.testing;
    const records = try fixture.Records.init(testing.allocator);
    defer records.deinit();
    const left = try records.importUnder("hybrid.target", "301", "image", "toolchain-a");
    const right = try records.importUnder("hybrid.target", "301", "image", "toolchain-b");
    try testing.expectEqualSlices(u8, left.record.bytes(), right.record.bytes());
    try testing.expect(left.ref.eql(right.ref));
    try testing.expect(!left.eql(right));

    var manifests = serialization.reference.Manifests{};
    var writer = format.Writer.init(testing.allocator);
    defer writer.deinit();
    try writer.writeBlob(left.record.bytes());
    try writer.writeInt(u32, @intCast(try manifests.intern(left.record.compilerManifest())));
    try writer.writeBlob(right.record.bytes());
    try writer.writeInt(u32, @intCast(try manifests.intern(right.record.compilerManifest())));
    try testing.expectEqual(@as(usize, 2), manifests.count);

    var table = format.Writer.init(testing.allocator);
    defer table.deinit();
    try serialization.reference.writeManifests(&table, &manifests);
    var table_reader = try format.Reader.init(table.bytes.items);
    const restored = try serialization.reference.readManifests(&table_reader);
    try testing.expect(table_reader.atEnd());

    const owner = try serialization.reference.createStore(testing.allocator, 2);
    defer owner.release();
    var reader = try format.Reader.init(writer.bytes.items);
    const first = try serialization.reference.readRecord(owner, &reader, &restored);
    const second = try serialization.reference.readRecord(owner, &reader, &restored);
    try testing.expect(reader.atEnd());
    try testing.expect(first.ref.eql(second.ref));
    try testing.expectEqualSlices(u8, first.record.bytes(), second.record.bytes());
    try testing.expect(!first.eql(second));
    try testing.expectEqualStrings("toolchain-a", first.record.compilerManifest());
    try testing.expectEqualStrings("toolchain-b", second.record.compilerManifest());
}

test "composition module refuses the record shape this format replaced" {
    const testing = std.testing;
    var original = try testModule(testing.allocator);
    defer original.deinit();
    const encoded = try serialize(testing.allocator, &original);
    defer testing.allocator.free(encoded);
    try testing.expectEqual(@as(u32, 6), format.version);
    std.mem.writeInt(u32, encoded[format.magic.len..][0..4], 5, .little);
    try testing.expectError(error.UnsupportedVersion, deserialize(testing.allocator, encoded));
}

test "composition module binary deserialization rejects malformed inputs" {
    const testing = std.testing;
    var module = try testModule(testing.allocator);
    defer module.deinit();
    const encoded = try serialize(testing.allocator, &module);
    defer testing.allocator.free(encoded);

    const invalid_magic = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(invalid_magic);
    invalid_magic[0] ^= 0xff;
    try testing.expectError(error.InvalidMagic, deserialize(testing.allocator, invalid_magic));

    const unsupported_version = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(unsupported_version);
    std.mem.writeInt(u32, unsupported_version[format.magic.len..][0..4], format.version + 1, .little);
    try testing.expectError(error.UnsupportedVersion, deserialize(testing.allocator, unsupported_version));

    const invalid_length = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(invalid_length);
    const length_offset = format.magic.len + @sizeOf(u32);
    std.mem.writeInt(u64, invalid_length[length_offset..][0..@sizeOf(u64)], std.math.maxInt(u64), .little);
    var length_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.LimitExceeded, deserialize(length_allocator.allocator(), invalid_length));

    const source_name_offset = format.header_size;
    const boundary_count_offset = source_name_offset + @sizeOf(u32) + module.source_module.name.len;
    const first_boundary = module.source_module.boundaries.items[0];
    const first_element_type_offset = boundary_count_offset + @sizeOf(u32) + @sizeOf(u64) + @sizeOf(u32) + first_boundary.name.len;
    const invalid_tag = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(invalid_tag);
    invalid_tag[first_element_type_offset] = 0xff;
    refreshChecksum(invalid_tag);
    try testing.expectError(error.InvalidTag, deserialize(testing.allocator, invalid_tag));

    try testing.expectError(error.Truncated, deserialize(testing.allocator, encoded[0 .. encoded.len - 1]));

    const trailing = try testing.allocator.alloc(u8, encoded.len + 1);
    defer testing.allocator.free(trailing);
    @memcpy(trailing[0..encoded.len], encoded);
    trailing[encoded.len] = 0;
    try testing.expectError(error.TrailingBytes, deserialize(testing.allocator, trailing));

    const count_bomb = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(count_bomb);
    const first_dimensions_count_offset = first_element_type_offset + @sizeOf(u8);
    std.mem.writeInt(u32, count_bomb[first_dimensions_count_offset..][0..4], std.math.maxInt(u32), .little);
    refreshChecksum(count_bomb);
    try testing.expectError(error.LimitExceeded, deserialize(testing.allocator, count_bomb));

    const artifact_offset = std.mem.indexOf(u8, encoded, artifact.serialization.magic).?;
    const artifact_payload_offset = artifact_offset + artifact.serialization.magic.len + @sizeOf(u32);

    const invalid_bool = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(invalid_bool);
    invalid_bool[artifact_payload_offset + @sizeOf(u8)] = 2;
    refreshChecksum(invalid_bool);
    try testing.expectError(error.InvalidValue, deserialize(testing.allocator, invalid_bool));

    const invalid_string = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(invalid_string);
    const producer_length_offset = artifact_payload_offset + @sizeOf(u8) + @sizeOf(u8);
    std.mem.writeInt(u32, invalid_string[producer_length_offset..][0..@sizeOf(u32)], artifact.serialization.format.max_string_bytes + 1, .little);
    refreshChecksum(invalid_string);
    try testing.expectError(error.LimitExceeded, deserialize(testing.allocator, invalid_string));

    const invalid_blob = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(invalid_blob);
    const executable = module.fragments.items[0].artifacts[0].payload.buffers.items[0].bytes;
    const executable_offset = std.mem.indexOf(u8, invalid_blob, executable).?;
    const executable_length_offset = executable_offset - @sizeOf(u32);
    std.mem.writeInt(u32, invalid_blob[executable_length_offset..][0..@sizeOf(u32)], artifact.serialization.format.max_blob_bytes + 1, .little);
    refreshChecksum(invalid_blob);
    try testing.expectError(error.LimitExceeded, deserialize(testing.allocator, invalid_blob));

    const executable_corruption = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(executable_corruption);
    const corruption_offset = std.mem.indexOf(u8, executable_corruption, executable).?;
    executable_corruption[corruption_offset + executable.len / 2] ^= 0x80;
    var checksum_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.InvalidChecksum, deserialize(checksum_allocator.allocator(), executable_corruption));
}

fn refreshChecksum(bytes: []u8) void {
    const payload = bytes[format.header_size .. bytes.len - format.checksum_size];
    std.mem.writeInt(u32, bytes[bytes.len - format.checksum_size ..][0..format.checksum_size], format.checksum(payload), .little);
}

test "composition module binary serialization survives every allocation failure" {
    const testing = std.testing;
    var module = try testModule(testing.allocator);
    defer module.deinit();
    const encoded = try serialize(testing.allocator, &module);
    defer testing.allocator.free(encoded);

    const Harness = struct {
        fn serializeRun(allocator: std.mem.Allocator, value: *const model.CompositionModule) !void {
            const bytes = try serialize(allocator, value);
            defer allocator.free(bytes);
        }

        fn deserializeRun(allocator: std.mem.Allocator, bytes: []const u8) !void {
            var decoded = try deserialize(allocator, bytes);
            defer decoded.deinit();
        }
    };

    var backing = testing.FailingAllocator.init(testing.allocator, .{
        .resize_fail_index = 0,
    });
    try testing.checkAllAllocationFailures(backing.allocator(), Harness.serializeRun, .{&module});
    try testing.checkAllAllocationFailures(backing.allocator(), Harness.deserializeRun, .{encoded});
}
