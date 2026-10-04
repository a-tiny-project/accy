//! A readback witness for a golden harness. A compute kernel writes a known word into every word
//! of a device buffer, the public `readBuffer` path copies the buffer to the host, and `run`
//! compares the bytes with the pattern the host derives. The buffer first holds the pattern's
//! complement, so a stale byte, a lost write and an unordered read each show as a difference.
//!
//! `run` drives a backend through `BackendHandle` alone, in the order a golden harness reads a
//! frame back: write, launch, synchronize the device, read. The kernel is SPIR-V, so a backend
//! that loads no `vulkan_spirv` artifact refuses it by name. The caller supplies every byte `run`
//! compares.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");

/// Invocations in one workgroup of the pattern kernel. Each invocation writes one word.
pub const group_words: u32 = 64;

/// Bytes the kernel writes per workgroup. A witness buffer holds a whole number of groups.
pub const group_bytes: usize = group_words * @sizeOf(u32);

pub const entry_name = "gpu_readback_pattern";

/// The pattern kernel, assembled by `spirv-as --target-env vulkan1.1` and checked by `spirv-val`
/// for vulkan1.1 and vulkan1.3. Its source:
///
///     OpCapability Shader
///     OpMemoryModel Logical GLSL450
///     OpEntryPoint GLCompute %main "gpu_readback_pattern" %gid
///     OpDecorate %gid BuiltIn GlobalInvocationId
///     OpDecorate %group_x SpecId 0
///     OpDecorate %group_y SpecId 1
///     OpDecorate %group_z SpecId 2
///     OpDecorate %group BuiltIn WorkgroupSize
///     OpDecorate %words ArrayStride 4
///     OpMemberDecorate %block 0 Offset 0
///     OpDecorate %block Block
///     OpDecorate %buffer DescriptorSet 0
///     OpDecorate %buffer Binding 0
///     %void = OpTypeVoid
///     %fn = OpTypeFunction %void
///     %uint = OpTypeInt 32 0
///     %uint3 = OpTypeVector %uint 3
///     %input_u3 = OpTypePointer Input %uint3
///     %gid = OpVariable %input_u3 Input
///     %group_x = OpSpecConstant %uint 1
///     %group_y = OpSpecConstant %uint 1
///     %group_z = OpSpecConstant %uint 1
///     %group = OpSpecConstantComposite %uint3 %group_x %group_y %group_z
///     %words = OpTypeRuntimeArray %uint
///     %block = OpTypeStruct %words
///     %storage_bk = OpTypePointer StorageBuffer %block
///     %buffer = OpVariable %storage_bk StorageBuffer
///     %storage_u1 = OpTypePointer StorageBuffer %uint
///     %zero = OpConstant %uint 0
///     %scale = OpConstant %uint 2654435761
///     %mask = OpConstant %uint 2779096485
///     %main = OpFunction %void None %fn
///     %entry = OpLabel
///     %global = OpLoad %uint3 %gid
///     %index = OpCompositeExtract %uint %global 0
///     %product = OpIMul %uint %index %scale
///     %pattern = OpBitwiseXor %uint %product %mask
///     %slot = OpAccessChain %storage_u1 %buffer %zero %index
///     OpStore %slot %pattern
///     OpReturn
///     OpFunctionEnd
pub const spirv_words = [_]u32{
    0x07230203, 0x00010300, 0x00070000, 0x0000001a, 0x00000000, 0x00020011, 0x00000001, 0x0003000e,
    0x00000000, 0x00000001, 0x000a000f, 0x00000005, 0x00000001, 0x5f757067, 0x64616572, 0x6b636162,
    0x7461705f, 0x6e726574, 0x00000000, 0x00000002, 0x00040047, 0x00000002, 0x0000000b, 0x0000001c,
    0x00040047, 0x00000003, 0x00000001, 0x00000000, 0x00040047, 0x00000004, 0x00000001, 0x00000001,
    0x00040047, 0x00000005, 0x00000001, 0x00000002, 0x00040047, 0x00000006, 0x0000000b, 0x00000019,
    0x00040047, 0x00000007, 0x00000006, 0x00000004, 0x00050048, 0x00000008, 0x00000000, 0x00000023,
    0x00000000, 0x00030047, 0x00000008, 0x00000002, 0x00040047, 0x00000009, 0x00000022, 0x00000000,
    0x00040047, 0x00000009, 0x00000021, 0x00000000, 0x00020013, 0x0000000a, 0x00030021, 0x0000000b,
    0x0000000a, 0x00040015, 0x0000000c, 0x00000020, 0x00000000, 0x00040017, 0x0000000d, 0x0000000c,
    0x00000003, 0x00040020, 0x0000000e, 0x00000001, 0x0000000d, 0x0004003b, 0x0000000e, 0x00000002,
    0x00000001, 0x00040032, 0x0000000c, 0x00000003, 0x00000001, 0x00040032, 0x0000000c, 0x00000004,
    0x00000001, 0x00040032, 0x0000000c, 0x00000005, 0x00000001, 0x00060033, 0x0000000d, 0x00000006,
    0x00000003, 0x00000004, 0x00000005, 0x0003001d, 0x00000007, 0x0000000c, 0x0003001e, 0x00000008,
    0x00000007, 0x00040020, 0x0000000f, 0x0000000c, 0x00000008, 0x0004003b, 0x0000000f, 0x00000009,
    0x0000000c, 0x00040020, 0x00000010, 0x0000000c, 0x0000000c, 0x0004002b, 0x0000000c, 0x00000011,
    0x00000000, 0x0004002b, 0x0000000c, 0x00000012, 0x9e3779b1, 0x0004002b, 0x0000000c, 0x00000013,
    0xa5a5a5a5, 0x00050036, 0x0000000a, 0x00000001, 0x00000000, 0x0000000b, 0x000200f8, 0x00000014,
    0x0004003d, 0x0000000d, 0x00000015, 0x00000002, 0x00050051, 0x0000000c, 0x00000016, 0x00000015,
    0x00000000, 0x00050084, 0x0000000c, 0x00000017, 0x00000016, 0x00000012, 0x000500c6, 0x0000000c,
    0x00000018, 0x00000017, 0x00000013, 0x00060041, 0x00000010, 0x00000019, 0x00000009, 0x00000011,
    0x00000016, 0x0003003e, 0x00000019, 0x00000018, 0x000100fd, 0x00010038,
};

/// The word the kernel writes at `index`. It matches the kernel's `%scale` and `%mask`.
pub fn patternWord(index: u32) u32 {
    return (index *% 2654435761) ^ 2779096485;
}

/// Bytes a witness of `groups` workgroups compares, and the size of each buffer `run` takes.
pub fn byteCount(groups: u32) usize {
    return @as(usize, groups) * group_bytes;
}

/// Writes the kernel's pattern into `bytes` as host-order words.
pub fn fillPattern(bytes: []u8) void {
    fill(bytes, 0);
}

/// Writes the complement of the kernel's pattern into `bytes`, so every byte differs from it.
pub fn fillComplement(bytes: []u8) void {
    fill(bytes, std.math.maxInt(u32));
}

fn fill(bytes: []u8, flip: u32) void {
    std.debug.assert(bytes.len % @sizeOf(u32) == 0);
    const words = bytes.len / @sizeOf(u32);
    for (0..words) |index| {
        const word = patternWord(@intCast(index)) ^ flip;
        std.mem.writeInt(u32, bytes[index * 4 ..][0..4], word, builtin.cpu.arch.endian());
    }
}

pub const Difference = struct {
    offset: usize,
    expected: u8,
    actual: u8,
};

pub const Comparison = struct {
    bytes: usize,
    differing: usize,
    first: ?Difference,

    pub fn matches(self: Comparison) bool {
        return self.differing == 0;
    }
};

/// Compares two byte slices of one length, counting every differing byte and keeping the first.
pub fn compare(expected: []const u8, actual: []const u8) Comparison {
    std.debug.assert(expected.len == actual.len);
    var result: Comparison = .{ .bytes = expected.len, .differing = 0, .first = null };
    for (expected, actual, 0..) |want, got, offset| {
        if (want == got) continue;
        if (result.first == null) result.first = .{ .offset = offset, .expected = want, .actual = got };
        result.differing += 1;
    }
    return result;
}

/// The caller's storage for one witness run. Both slices hold `byteCount(groups)` bytes.
pub const Storage = struct {
    /// Receives the pattern the kernel must write.
    expected: []u8,
    /// Holds the complement `run` uploads, then the bytes `readBuffer` returns.
    readback: []u8,
};

/// Launches the pattern kernel over `groups` workgroups on `handle`'s default stream, reads the
/// buffer back through `readBuffer` after a device synchronize, and compares it with the pattern.
/// A mismatch is a `Comparison` with a nonzero `differing`, never an error.
pub fn run(handle: contract.BackendHandle, groups: u32, storage: Storage) contract.BackendError!Comparison {
    const bytes = byteCount(groups);
    std.debug.assert(groups != 0);
    std.debug.assert(storage.expected.len == bytes);
    std.debug.assert(storage.readback.len == bytes);

    const capabilities = try handle.queryCapabilities();
    var artifact = try handle.createArtifact(.{
        .kernel_name = entry_name,
        .requested_format = .vulkan_spirv,
        .argument_count = 1,
        .diagnostic_id = entry_name,
        .payload = .{ .words_u32 = &spirv_words },
    });
    defer artifact.deinit();
    const loaded = try handle.loadArtifact(&artifact);
    defer handle.destroyObject(loaded.id);

    const buffer = try handle.allocateBuffer(.{
        .byte_size = bytes,
        .alignment = @max(@sizeOf(u32), capabilities.memory.min_buffer_alignment),
    });
    defer handle.destroyObject(buffer.id);

    fillComplement(storage.readback);
    try handle.writeBuffer(.{ .handle = buffer, .bytes = storage.readback });
    const bindings = [_]contract.BufferBinding{.{
        .handle = buffer,
        .access = .write_only,
        .ownership = .backend,
        .byte_size = bytes,
    }};
    try handle.launch(.{
        .artifact = &artifact,
        .loaded_artifact = loaded,
        .buffers = &bindings,
        .geometry = .{ .grid = .{ groups, 1, 1 }, .threadgroup = .{ group_words, 1, 1 } },
    });
    try handle.synchronize(.{ .scope = .device });
    try handle.readBuffer(.{ .handle = buffer, .bytes = storage.readback });

    fillPattern(storage.expected);
    return compare(storage.expected, storage.readback);
}

test "the pattern and its complement differ in every byte" {
    var pattern: [group_bytes]u8 = undefined;
    var complement: [group_bytes]u8 = undefined;
    fillPattern(&pattern);
    fillComplement(&complement);
    const comparison = compare(&pattern, &complement);
    try std.testing.expectEqual(pattern.len, comparison.differing);
    try std.testing.expectEqual(@as(usize, 0), comparison.first.?.offset);
}

test "compare reports the first differing byte and the count" {
    var expected: [8]u8 = @splat(7);
    var actual: [8]u8 = @splat(7);
    actual[3] = 9;
    actual[6] = 1;
    const comparison = compare(&expected, &actual);
    try std.testing.expect(!comparison.matches());
    try std.testing.expectEqual(@as(usize, 2), comparison.differing);
    try std.testing.expectEqual(Difference{ .offset = 3, .expected = 7, .actual = 9 }, comparison.first.?);
    try std.testing.expect(compare(&expected, &expected).matches());
}

test "the embedded kernel is SPIR-V naming the pattern entry" {
    try std.testing.expectEqual(@as(u32, 0x07230203), spirv_words[0]);
    const name = std.mem.sliceAsBytes(spirv_words[13..19]);
    try std.testing.expectEqualStrings(entry_name, name[0..entry_name.len]);
}
