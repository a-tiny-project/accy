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
