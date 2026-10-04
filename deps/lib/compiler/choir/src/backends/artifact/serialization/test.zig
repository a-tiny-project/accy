const std = @import("std");
const artifact = @import("../root.zig");
const binary = @import("../../../serialization/root.zig").binary;
const serialization = @import("root.zig");

test {
    std.testing.refAllDecls(serialization);
}

test "artifact serialization uses stable model-owned tags" {
    try std.testing.expectEqual(@as(u8, 1), try binary.encodeTag(artifact.ArtifactKind.unknown));
    try std.testing.expectEqual(@as(u8, 8), try binary.encodeTag(artifact.ArtifactKind.container));
    try std.testing.expectEqual(@as(u8, 5), try binary.encodeTag(artifact.OptionValueTag.bytes));
    try std.testing.expectEqual(artifact.BufferFormat.object_file, try binary.decodeTag(artifact.BufferFormat, 3));
    try std.testing.expectError(error.InvalidTag, binary.decodeTag(artifact.BufferFormat, 0xff));
}

test "artifact binary serialization round-trips every owned concern" {
    var original = try artifact.Artifact.init(std.testing.allocator, .{
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
    defer original.deinit();
    try original.options.add(.{ .key = "checked", .value = .{ .flag = true } });
    try original.options.add(.{ .key = "bias", .value = .{ .signed = -17 } });
    try original.options.add(.{ .key = "seed", .value = .{ .unsigned = 42 } });
    try original.options.add(.{ .key = "mode", .value = .{ .text = "durable" } });
    try original.options.add(.{ .key = "opaque", .value = .{ .bytes = &.{ 0, 255, 7 } } });
    try original.linkage.addRequired(.{ .name = "runtime", .kind = .runtime, .binding = .weak });
    const lanes = artifact.ValueType{ .vector = .{ .element = .f32, .lanes = 4 } };
    const signature = try artifact.Signature.init(&.{ .{ .scalar = .u16 }, .memref }, &.{lanes});
    try original.linkage.addProvided(.{
        .name = "entry",
        .kind = .function,
        .binding = .external,
        .signature = signature,
    });
    try original.linkage.addProvided(.{ .name = "table", .kind = .data, .binding = .local });
    try original.linkage.addRelocation(.{ .offset = 2, .symbol = "runtime", .kind = .call, .addend = -4, .width_bits = 64 });
    try original.payload.addDebugRecord(.{ .name = ".debug_line", .kind = .dwarf_section, .bytes = &.{ 1, 0, 2, 0 } });
    try original.payload.addBuffer(.{ .name = "entry", .format = .machine_code, .bytes = &.{ 0x48, 0xb8, 0xff, 0xd0, 0xc3 }, .alignment = 32 });
    try original.payload.addTextDump(.{ .name = "lowered", .contents = "func @entry" });
    try original.verification.replace(original.allocator, .{ .state = .failed, .stage = "machine-verify", .message = "preserved" });

    const encoded = try serialization.serialize(std.testing.allocator, &original);
    defer std.testing.allocator.free(encoded);
    var decoded = try serialization.deserialize(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expect(original.eql(decoded));
    try std.testing.expect(decoded.linkage.provided_symbols.items[0].signature.?.eql(&signature));
    try std.testing.expect(decoded.linkage.provided_symbols.items[1].signature == null);

    const reencoded = try serialization.serialize(std.testing.allocator, &decoded);
    defer std.testing.allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, encoded, reencoded);
}

test "artifact linkage deserialization refuses malformed signatures" {
    const scalar = @backingInt(artifact.ValueKind.scalar);
    const memref = @backingInt(artifact.ValueKind.memref);
    const vector = @backingInt(artifact.ValueKind.vector);
    const f32_tag = @backingInt(artifact.ScalarType.f32);
    const f64_tag = @backingInt(artifact.ScalarType.f64);

    var linkage = try readSignedSymbol(&.{ 1, 1, memref, vector, f32_tag, 4 });
    defer linkage.deinit();
    const lanes = artifact.ValueType{ .vector = .{ .element = .f32, .lanes = 4 } };
    const signature = try artifact.Signature.init(&.{.memref}, &.{lanes});
    try std.testing.expect(linkage.provided_symbols.items[0].signature.?.eql(&signature));

    try expectMalformed(error.LimitExceeded, &.{ artifact.Signature.max_parameters + 1, 0 });
    try expectMalformed(error.LimitExceeded, &.{ 0, artifact.Signature.max_results + 1 });
    try expectMalformed(error.InvalidTag, &.{ 1, 0, vector + 1 });
    try expectMalformed(error.InvalidTag, &.{ 1, 0, scalar, f64_tag + 1 });
    try expectMalformed(error.InvalidValue, &.{ 0, 1, vector, f32_tag, 0 });
    try expectMalformed(error.InvalidValue, &.{ 0, 1, vector, f32_tag, 17 });
}

fn expectMalformed(expected: anyerror, signature: []const u8) !void {
    try std.testing.expectError(expected, readSignedSymbol(signature));
}

fn readSignedSymbol(signature: []const u8) !artifact.Linkage {
    var writer = serialization.format.Writer.init(std.testing.allocator);
    defer writer.deinit();
    try writer.writeCount(0);
    try writer.writeCount(1);
    try writer.writeString("entry");
    try writer.writeTag(artifact.SymbolKind.function);
    try writer.writeTag(artifact.SymbolBinding.external);
    try writer.writeBool(true);
    try writer.writeRaw(signature);
    try writer.writeCount(0);

    var reader = try serialization.format.Reader.init(writer.bytes.items);
    var linkage = artifact.Linkage.init(std.testing.allocator);
    errdefer linkage.deinit();
    try serialization.linkage.readInto(&reader, &linkage);
    try std.testing.expect(reader.atEnd());
    return linkage;
}
