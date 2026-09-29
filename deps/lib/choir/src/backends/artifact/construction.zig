const std = @import("std");
const artifact_root = @import("root.zig");

const Allocator = std.mem.Allocator;

/// Read-only bytes that a machine-code artifact carries beside its code.
/// The artifact stores them as a raw buffer and provides them as a data symbol of the same name.
pub const DataBuffer = struct {
    name: []const u8,
    bytes: []const u8,
    alignment: usize = 1,
    binding: artifact_root.SymbolBinding = .local,
};

/// Builds an artifact for one function whose parameter and result types are `signature`.
/// The code buffer comes first, followed by one raw buffer for each entry of `data`.
pub fn machineCodeArtifact(
    allocator: Allocator,
    target: artifact_root.Target,
    abi: artifact_root.Abi,
    entry: []const u8,
    signature: artifact_root.Signature,
    code: []const u8,
    data: []const DataBuffer,
    relocations: []const artifact_root.Relocation,
) Allocator.Error!artifact_root.Artifact {
    var artifact = try artifact_root.Artifact.init(allocator, .{
        .kind = .machine_code,
        .target = target,
        .abi = abi,
    });
    errdefer artifact.deinit();

    try artifact.payload.addBuffer(.{
        .name = entry,
        .format = .machine_code,
        .bytes = code,
        .alignment = 16,
    });
    try artifact.linkage.addProvided(.{
        .name = entry,
        .kind = .function,
        .binding = .external,
        .signature = signature,
    });
    for (data) |buffer| {
        try artifact.payload.addBuffer(.{
            .name = buffer.name,
            .format = .raw,
            .bytes = buffer.bytes,
            .alignment = buffer.alignment,
        });
        try artifact.linkage.addProvided(.{
            .name = buffer.name,
            .kind = .data,
            .binding = buffer.binding,
        });
    }
    for (relocations) |relocation| {
        try artifact.linkage.addRelocation(relocation);
        if (relocation.kind == .call and !artifact.linkage.hasRequired(relocation.symbol)) {
            try artifact.linkage.addRequired(.{
                .name = relocation.symbol,
                .kind = .function,
                .binding = .external,
            });
        }
    }
    return artifact;
}

pub fn objectFileArtifact(
    allocator: Allocator,
    target: artifact_root.Target,
    abi: artifact_root.Abi,
    name: []const u8,
    object: []const u8,
    relocations: []const artifact_root.Relocation,
) Allocator.Error!artifact_root.Artifact {
    var artifact = try artifact_root.Artifact.init(allocator, .{
        .kind = .object_file,
        .target = target,
        .abi = abi,
    });
    errdefer artifact.deinit();

    try artifact.payload.addBuffer(.{
        .name = name,
        .format = .object_file,
        .bytes = object,
        .alignment = 8,
    });
    try artifact.linkage.addProvided(.{
        .name = name,
        .kind = .function,
        .binding = .external,
    });
    for (relocations) |relocation| {
        try artifact.linkage.addRelocation(relocation);
        if (relocation.kind == .call and !artifact.linkage.hasRequired(relocation.symbol)) {
            try artifact.linkage.addRequired(.{
                .name = relocation.symbol,
                .kind = .function,
                .binding = .external,
            });
        }
    }
    return artifact;
}

pub fn webassemblyModuleArtifact(
    allocator: Allocator,
    name: []const u8,
    module: []const u8,
) Allocator.Error!artifact_root.Artifact {
    var artifact = try artifact_root.Artifact.init(allocator, .{
        .kind = .webassembly_module,
        .target = .{
            .architecture = .wasm,
            .triple = "wasm32-unknown-unknown",
        },
        .abi = .{
            .name = "wasm32",
            .object_format = "wasm",
            .pointer_width_bits = 32,
            .endianness = .little,
        },
    });
    errdefer artifact.deinit();

    try artifact.payload.addBuffer(.{
        .name = name,
        .format = .webassembly_module,
        .bytes = module,
        .alignment = 1,
    });
    return artifact;
}

test "artifact records machine code metadata without x86-specific structs" {
    const relocations = [_]artifact_root.Relocation{
        .{ .offset = 4, .symbol = "runtime_entry", .kind = .call },
    };
    const parameters = [_]artifact_root.ValueType{ .{ .scalar = .i32 }, .memref };
    const signature = try artifact_root.Signature.init(&parameters, &.{.{ .scalar = .f64 }});

    var artifact = try machineCodeArtifact(
        std.testing.allocator,
        .{
            .architecture = .x86_64,
            .triple = "x86_64-unknown-linux-gnu",
            .cpu = "x86-64-v3",
            .features = &.{ "sse2", "avx2" },
        },
        .{
            .name = "sysv",
            .calling_convention = "c",
            .object_format = "elf",
            .pointer_width_bits = 64,
            .endianness = .little,
        },
        "main",
        signature,
        &.{ 0x55, 0x48, 0x89, 0xe5 },
        &.{.{ .name = "table", .bytes = "\x01\x02\x03", .alignment = 8 }},
        &relocations,
    );
    defer artifact.deinit();

    try artifact.options.add(.{ .key = "pic", .value = .{ .flag = true } });
    try artifact.linkage.addRequired(.{ .name = "runtime_entry", .kind = .function });
    try artifact.payload.addDebugRecord(.{
        .name = ".debug_line",
        .kind = .line_table,
        .bytes = &.{ 1, 2, 3 },
    });
    try artifact.payload.addTextDump(.{ .name = "disassembly", .contents = "push rbp" });
    try artifact.verification.replace(artifact.allocator, .{
        .state = .passed,
        .stage = "backend/x86_64/verify",
    });

    try std.testing.expectEqual(artifact_root.ArtifactKind.machine_code, artifact.metadata.kind);
    try std.testing.expectEqual(artifact_root.Architecture.x86_64, artifact.metadata.target.architecture);
    try std.testing.expectEqualStrings("x86-64-v3", artifact.metadata.target.cpu.?);
    try std.testing.expectEqualStrings("avx2", artifact.metadata.target.features[1]);
    try std.testing.expectEqual(@as(u16, 64), artifact.metadata.abi.pointer_width_bits.?);
    try std.testing.expectEqual(artifact_root.Endianness.little, artifact.metadata.abi.endianness.?);
    const buffers = artifact.payload.buffers.items;
    try std.testing.expectEqual(@as(usize, 2), buffers.len);
    try std.testing.expectEqual(artifact_root.BufferFormat.machine_code, buffers[0].format);
    try std.testing.expectEqual(artifact_root.BufferFormat.raw, buffers[1].format);
    try std.testing.expectEqualStrings("table", buffers[1].name);
    try std.testing.expectEqualSlices(u8, "\x01\x02\x03", buffers[1].bytes);
    try std.testing.expectEqual(@as(usize, 8), buffers[1].alignment);
    const provided = artifact.linkage.provided_symbols.items;
    try std.testing.expectEqual(@as(usize, 2), provided.len);
    try std.testing.expect(artifact.linkage.hasProvided("main"));
    try std.testing.expect(provided[0].signature.?.eql(&signature));
    try std.testing.expectEqual(@as(?artifact_root.Signature, null), provided[1].signature);
    try std.testing.expectEqual(artifact_root.SymbolKind.data, provided[1].kind);
    try std.testing.expectEqual(artifact_root.SymbolBinding.local, provided[1].binding);
    try std.testing.expectEqual(@as(usize, 1), artifact.linkage.relocations.items.len);
    try std.testing.expectEqual(artifact_root.RelocationKind.call, artifact.linkage.relocations.items[0].kind);
    try std.testing.expect(artifact.linkage.hasRequired("runtime_entry"));
    try std.testing.expectEqual(artifact_root.VerificationState.passed, artifact.verification.state);
}

test "artifact records object file buffers and required symbols" {
    const relocations = [_]artifact_root.Relocation{
        .{ .offset = 8, .symbol = "__tiny_runtime_call", .kind = .call },
        .{ .offset = 24, .symbol = "__tiny_runtime_call", .kind = .call },
        .{ .offset = 40, .symbol = ".Ltiny_literal_0", .kind = .absolute },
    };

    var artifact = try objectFileArtifact(
        std.testing.allocator,
        .{
            .architecture = .x86_64,
            .triple = "x86_64-unknown-linux-gnu",
        },
        .{
            .name = "sysv",
            .calling_convention = "c",
            .object_format = "elf",
            .pointer_width_bits = 64,
            .endianness = .little,
        },
        "tiny_entry",
        &.{ 0x7f, 'E', 'L', 'F' },
        &relocations,
    );
    defer artifact.deinit();

    try std.testing.expectEqual(artifact_root.ArtifactKind.object_file, artifact.metadata.kind);
    try std.testing.expectEqual(@as(usize, 1), artifact.payload.buffers.items.len);
    try std.testing.expectEqual(artifact_root.BufferFormat.object_file, artifact.payload.buffers.items[0].format);
    try std.testing.expectEqual(@as(usize, 3), artifact.linkage.relocations.items.len);
    try std.testing.expectEqual(artifact_root.RelocationKind.absolute, artifact.linkage.relocations.items[2].kind);
    try std.testing.expectEqual(@as(usize, 1), artifact.linkage.required_symbols.items.len);
    try std.testing.expect(artifact.linkage.hasRequired("__tiny_runtime_call"));
    try std.testing.expectEqual(@as(usize, 1), artifact.linkage.provided_symbols.items.len);
    try std.testing.expect(artifact.linkage.hasProvided("tiny_entry"));
}

test "artifact records webassembly module buffers" {
    var artifact = try webassemblyModuleArtifact(
        std.testing.allocator,
        "module",
        &.{ 0x00, 0x61, 0x73, 0x6d },
    );
    defer artifact.deinit();

    try std.testing.expectEqual(artifact_root.ArtifactKind.webassembly_module, artifact.metadata.kind);
    try std.testing.expectEqual(artifact_root.Architecture.wasm, artifact.metadata.target.architecture);
    try std.testing.expectEqual(@as(u16, 32), artifact.metadata.abi.pointer_width_bits.?);
    try std.testing.expectEqual(@as(usize, 1), artifact.payload.buffers.items.len);
    try std.testing.expectEqual(artifact_root.BufferFormat.webassembly_module, artifact.payload.buffers.items[0].format);
}
