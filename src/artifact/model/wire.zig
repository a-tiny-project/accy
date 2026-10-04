//! A byte encoding for a table of prebuilt kernels and the chains of kernels
//! that call them, with a writer that produces the bytes and a reader that
//! checks them and builds the table again.
//!
//! A program compiled ahead of time has to carry its device code inside its own
//! binary and look up each kernel by name at startup, because the compiler is
//! absent. The bytes come from a separate build step, possibly under an older
//! version of this code, so the layout may differ from what the reader expects.
//! A count or a tag read from the input decides how much memory to take and
//! which case to parse, so a damaged input can point past its own end. The byte
//! layout and the meaning of a kernel change for different reasons and at
//! different times.
//!
//! The bytes carrying prebuilt kernels (*registry blob*) open with the eight
//! characters "ACCYKCRG" and a layout version, and every integer after them is
//! little-endian. The layout version counts changes to the encoding alone, and
//! each kernel entry carries its own version for what the kernel computes. The
//! decoder copies every field of variable length into one arena that the
//! decoded table owns. The decoder rejects a wrong magic, a version it does not
//! read, input that ends early, bytes left over at the end, two entries or two
//! chains with the same identity, a tag it does not know, and a push-constant
//! layout that lists too many members or whose offsets and sizes do not fit
//! together. Two counts, the static arguments of an entry and the dimensions of
//! a shape profile, size their allocation before any check against the bytes
//! that remain, so a damaged input can end in `error.OutOfMemory`. The same
//! little-endian writer and reader (`ByteWriter`, `ByteReader`) also serve the
//! schedule tuning files.
//!
//! - *registry entry*: one prebuilt kernel identified by its target name,
//!   version and artifact format, with its entry point, argument count, code
//!   payload and launch rule.
//! - *kernel pipeline*: an ordered chain of registry entries launched one after
//!   another over shared scratch buffers.

const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");

const pipeline_mod = @import("pipeline.zig");
const plan = @import("registry.zig");

/// The layout version written after the magic, and a registry blob that carries
/// any other number fails with `error.UnsupportedRegistryVersion`. A maintainer
/// reads this number before changing the encoding and raises it when the order
/// or width of an encoded field changes, when a tag changes meaning, or when
/// the number an enum value encodes as changes. A change to what a kernel
/// computes, with the bytes laid out as before, raises
/// `KernelCallArtifact.version` on that entry and leaves this number alone.
pub const format_version: u32 = 10;

const magic = "ACCYKCRG";
const minimum_entry_bytes: usize = 32;
const minimum_pipeline_bytes: usize = 20;

pub const Error = error{
    InvalidRegistryBlob,
    UnsupportedRegistryVersion,
    TruncatedRegistryBlob,
    InvalidRegistryTag,
} || std.mem.Allocator.Error;

/// The table `decode` builds: the entries, their lookup index, the kernel
/// chains and every payload byte, all allocated in one arena. A caller holds
/// this for as long as it looks kernels up in the decoded table. `registry`
/// gives a lookup view, and that view has no hash index when the table holds no
/// entries. Every slice stays valid until `deinit`, which frees the arena at
/// once.
pub const OwnedRegistry = struct {
    arena: std.heap.ArenaAllocator,
    entries: []plan.KernelCallArtifact = &.{},
    index: plan.KernelCallRegistryIndex = .{},
    pipelines: []pipeline_mod.KernelCallPipeline = &.{},

    pub fn registry(self: *const OwnedRegistry) plan.KernelCallRegistry {
        return .{
            .entries = self.entries,
            .index = if (self.index.slots.len == 0) null else self.index,
        };
    }

    pub fn deinit(self: *OwnedRegistry) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Writes the entries and the kernel chains into one new byte slice allocated
/// with `allocator`, and the caller frees that slice. A build step calls this
/// to produce the bytes it embeds in a program. Each list and each byte field
/// must hold fewer than 2^32 items, and the encoder does not check this limit.
pub fn encode(
    allocator: std.mem.Allocator,
    entries: []const plan.KernelCallArtifact,
    pipelines: []const pipeline_mod.KernelCallPipeline,
) ![]u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);

    try bytes.appendSlice(allocator, magic);
    try appendInt(&bytes, allocator, u32, format_version);
    try appendInt(&bytes, allocator, u32, @intCast(entries.len));
    for (entries) |entry| try encodeEntry(&bytes, allocator, entry);
    try appendInt(&bytes, allocator, u32, @intCast(pipelines.len));
    for (pipelines) |entry| try encodePipeline(&bytes, allocator, entry);
    return bytes.toOwnedSlice(allocator);
}

/// Checks one whole registry blob and copies it into a new `OwnedRegistry`, so
/// the caller may free `bytes` as soon as the call returns. A program calls
/// this at startup on its embedded bytes to get a table it can search. The
/// errors are `error.InvalidRegistryBlob` for a wrong magic, leftover bytes, a
/// zero chain version, a repeated identity or a push-constant layout that does
/// not fit together, `error.UnsupportedRegistryVersion`,
/// `error.TruncatedRegistryBlob`, `error.InvalidRegistryTag`, and
/// `error.OutOfMemory`. A blob that claims more static arguments or shape
/// dimensions than it holds can fail with `error.OutOfMemory` before the
/// decoder sees that it is short.
pub fn decode(backing_allocator: std.mem.Allocator, bytes: []const u8) Error!OwnedRegistry {
    var owned = OwnedRegistry{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    errdefer owned.arena.deinit();
    const arena = owned.arena.allocator();

    var cursor = ByteReader{ .bytes = bytes };
    const magic_bytes = try take(&cursor, magic.len);
    if (!std.mem.eql(u8, magic_bytes, magic)) return error.InvalidRegistryBlob;
    const version = try readInt(&cursor, u32);
    if (version != format_version) return error.UnsupportedRegistryVersion;

    const count = try readInt(&cursor, u32);
    if (count > cursor.remaining() / minimum_entry_bytes) return error.TruncatedRegistryBlob;
    const entries = try arena.alloc(plan.KernelCallArtifact, count);
    for (entries) |*entry| entry.* = try decodeEntry(&cursor, arena);
    const pipeline_count = try readInt(&cursor, u32);
    if (pipeline_count > cursor.remaining() / minimum_pipeline_bytes) {
        return error.TruncatedRegistryBlob;
    }
    const pipelines = try arena.alloc(pipeline_mod.KernelCallPipeline, pipeline_count);
    for (pipelines, 0..) |*entry, decoded| {
        entry.* = try decodePipeline(&cursor, arena);
        if (entry.version == 0) return error.InvalidRegistryBlob;
        if (pipeline_mod.findPipeline(pipelines[0..decoded], entry.target, entry.version) != null) {
            return error.InvalidRegistryBlob;
        }
    }
    if (cursor.remaining() != 0) return error.InvalidRegistryBlob;
    const index = plan.buildKernelCallRegistryIndex(arena, entries) catch |err| switch (err) {
        error.DuplicateKernelCallArtifact => return error.InvalidRegistryBlob,
        error.OutOfMemory => return error.OutOfMemory,
    };

    owned.entries = entries;
    owned.index = index;
    owned.pipelines = pipelines;
    return owned;
}

fn encodeEntry(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    entry: plan.KernelCallArtifact,
) !void {
    try appendSized(bytes, allocator, entry.target);
    try appendInt(bytes, allocator, u32, entry.version);
    try bytes.append(allocator, @backingInt(entry.format));
    try appendSized(bytes, allocator, entry.entry_name);
    try appendInt(bytes, allocator, u32, entry.argument_count);
    try appendInt(bytes, allocator, u64, entry.required_dtypes.bits);
    try appendInt(bytes, allocator, u16, packFeatures(entry.required_features));
    try bytes.append(allocator, packSubgroupFlags(entry.required_subgroup));
    try appendInt(bytes, allocator, u32, entry.required_subgroup.size_min);
    try appendInt(bytes, allocator, u32, entry.required_subgroup.size_max);
    try encodePayload(bytes, allocator, entry.payload);
    try encodePushConstants(bytes, allocator, &entry.push_constants);
    try encodeLaunch(bytes, allocator, entry.launch);
    try bytes.append(allocator, @backingInt(entry.element_count_argument));
    try appendInt(bytes, allocator, u32, entry.runtime_scalar_argument_count);
    try appendInt(bytes, allocator, u32, @intCast(entry.static_arguments.len));
    for (entry.static_arguments) |argument| try encodeScalar(bytes, allocator, argument);
    try encodeOptionalU64(bytes, allocator, entry.shape_family_fingerprint);
    try encodeShapeProfile(bytes, allocator, entry.shape_profile);
}

fn decodeEntry(cursor: *ByteReader, arena: std.mem.Allocator) Error!plan.KernelCallArtifact {
    const target = try takeSizedCopy(cursor, arena);
    const version = try readInt(cursor, u32);
    const format = try readEnum(cursor, gpu.ArtifactFormat);
    const entry_name = try takeSizedCopy(cursor, arena);
    const argument_count = try readInt(cursor, u32);
    const dtype_bits = try readInt(cursor, u64);
    const features = unpackFeatures(try readInt(cursor, u16));
    var subgroup = unpackSubgroupFlags(try readByte(cursor));
    subgroup.size_min = try readInt(cursor, u32);
    subgroup.size_max = try readInt(cursor, u32);
    const payload = try decodePayload(cursor, arena);
    const push_constants = try decodePushConstants(cursor);
    const launch = try decodeLaunch(cursor);
    const element_count_argument = try readEnum(cursor, plan.ElementCountArgument);
    const runtime_scalar_argument_count = try readInt(cursor, u32);
    const static_argument_count = try readInt(cursor, u32);
    const static_arguments = try arena.alloc(gpu_abi.ScalarArgument, static_argument_count);
    for (static_arguments) |*argument| argument.* = try decodeScalar(cursor);
    const shape_family_fingerprint = try decodeOptionalU64(cursor);
    const shape_profile = try decodeShapeProfile(cursor, arena);

    return .{
        .target = target,
        .version = version,
        .format = format,
        .entry_name = entry_name,
        .argument_count = argument_count,
        .shape_family_fingerprint = shape_family_fingerprint,
        .shape_profile = shape_profile,
        .required_dtypes = .{ .bits = dtype_bits },
        .required_features = features,
        .required_subgroup = subgroup,
        .push_constants = push_constants,
        .payload = payload,
        .launch = launch,
        .element_count_argument = element_count_argument,
        .runtime_scalar_argument_count = runtime_scalar_argument_count,
        .static_arguments = static_arguments,
    };
}

fn encodePushConstants(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    layout: *const gpu_abi.PushConstants,
) !void {
    std.debug.assert(layout.valid());
    try bytes.append(allocator, layout.count);
    try bytes.append(allocator, layout.byte_size);
    try bytes.appendSlice(allocator, layout.offsets[0..layout.count]);
    try bytes.appendSlice(allocator, layout.sizes[0..layout.count]);
}

fn decodePushConstants(cursor: *ByteReader) Error!gpu_abi.PushConstants {
    var layout: gpu_abi.PushConstants = .{};
    layout.count = try readByte(cursor);
    if (layout.count > gpu_abi.max_push_constant_members) return error.InvalidRegistryBlob;
    layout.byte_size = try readByte(cursor);
    @memcpy(layout.offsets[0..layout.count], try take(cursor, layout.count));
    @memcpy(layout.sizes[0..layout.count], try take(cursor, layout.count));
    if (!layout.valid()) return error.InvalidRegistryBlob;
    return layout;
}

fn encodePayload(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    payload: gpu.CompilePayload,
) !void {
    switch (payload) {
        .none => try bytes.append(allocator, 0),
        .bytes => |data| {
            try bytes.append(allocator, 1);
            try appendInt(bytes, allocator, u64, data.len);
            try bytes.appendSlice(allocator, data);
        },
        .words_u32 => |words| {
            try bytes.append(allocator, 2);
            try appendInt(bytes, allocator, u64, words.len);
            for (words) |word| try appendInt(bytes, allocator, u32, word);
        },
        .text => |text| {
            try bytes.append(allocator, 3);
            try appendInt(bytes, allocator, u64, text.len);
            try bytes.appendSlice(allocator, text);
        },
    }
}

fn decodePayload(cursor: *ByteReader, arena: std.mem.Allocator) Error!gpu.CompilePayload {
    return switch (try readByte(cursor)) {
        0 => .none,
        1 => .{ .bytes = try takeCopy(cursor, arena, try readLength(cursor)) },
        2 => blk: {
            const count = try readLength(cursor);
            if (count > cursor.remaining() / @sizeOf(u32)) return error.TruncatedRegistryBlob;
            const words = try arena.alloc(u32, count);
            for (words) |*word| word.* = try readInt(cursor, u32);
            break :blk .{ .words_u32 = words };
        },
        3 => .{ .text = try takeCopy(cursor, arena, try readLength(cursor)) },
        else => error.InvalidRegistryTag,
    };
}

fn encodeLaunch(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    launch: plan.KernelCallLaunch,
) !void {
    switch (launch) {
        .derived => |derived| {
            try bytes.append(allocator, 0);
            try encodeDerivedLaunch(bytes, allocator, derived);
        },
        .fixed => |geometry| {
            try bytes.append(allocator, 1);
            for (geometry.grid) |extent| try appendInt(bytes, allocator, u32, extent);
            for (geometry.threadgroup) |extent| try appendInt(bytes, allocator, u32, extent);
            try appendInt(bytes, allocator, u32, geometry.dynamic_shared_memory_bytes);
        },
    }
}

fn decodeLaunch(cursor: *ByteReader) Error!plan.KernelCallLaunch {
    return switch (try readByte(cursor)) {
        0 => .{ .derived = try decodeDerivedLaunch(cursor) },
        1 => blk: {
            var geometry = gpu_abi.LaunchGeometry{};
            for (&geometry.grid) |*extent| extent.* = try readInt(cursor, u32);
            for (&geometry.threadgroup) |*extent| extent.* = try readInt(cursor, u32);
            geometry.dynamic_shared_memory_bytes = try readInt(cursor, u32);
            break :blk .{ .fixed = geometry };
        },
        else => error.InvalidRegistryTag,
    };
}

fn encodeDerivedLaunch(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    launch: plan.KernelCallDerivedLaunch,
) !void {
    for (launch.grid) |axis| try encodeDerivedLaunchAxis(bytes, allocator, axis);
    for (launch.threadgroup) |extent| try appendInt(bytes, allocator, u32, extent);
    try appendInt(bytes, allocator, u32, launch.dynamic_shared_memory_bytes);
}

fn decodeDerivedLaunch(cursor: *ByteReader) Error!plan.KernelCallDerivedLaunch {
    var launch = plan.KernelCallDerivedLaunch{};
    for (&launch.grid) |*axis| axis.* = try decodeDerivedLaunchAxis(cursor);
    for (&launch.threadgroup) |*extent| extent.* = try readInt(cursor, u32);
    launch.dynamic_shared_memory_bytes = try readInt(cursor, u32);
    return launch;
}

fn encodeDerivedLaunchAxis(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    axis: plan.KernelCallDerivedLaunchAxis,
) !void {
    switch (axis) {
        .fixed => |extent| {
            try bytes.append(allocator, 0);
            try appendInt(bytes, allocator, u32, extent);
        },
        .runtime_u32_ceil_div => |runtime| {
            try bytes.append(allocator, 1);
            try appendInt(bytes, allocator, u32, runtime.argument_index);
            try appendInt(bytes, allocator, u32, runtime.divisor);
        },
    }
}

fn decodeDerivedLaunchAxis(cursor: *ByteReader) Error!plan.KernelCallDerivedLaunchAxis {
    return switch (try readByte(cursor)) {
        0 => .{ .fixed = try readInt(cursor, u32) },
        1 => .{ .runtime_u32_ceil_div = .{
            .argument_index = try readInt(cursor, u32),
            .divisor = try readInt(cursor, u32),
        } },
        else => error.InvalidRegistryTag,
    };
}

fn encodePipeline(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    entry: pipeline_mod.KernelCallPipeline,
) !void {
    try appendSized(bytes, allocator, entry.target);
    try appendInt(bytes, allocator, u32, entry.version);
    try appendInt(bytes, allocator, u32, entry.operand_count);
    try appendInt(bytes, allocator, u32, entry.result_count);
    try appendInt(bytes, allocator, u32, entry.runtime_scalar_argument_count);
    try appendInt(bytes, allocator, u32, @intCast(entry.runtime_scalar_bounds.len));
    for (entry.runtime_scalar_bounds) |bound| {
        try appendInt(bytes, allocator, u32, bound.argument_index);
        try appendInt(bytes, allocator, u32, bound.max_u32);
    }
    try appendInt(bytes, allocator, u32, @intCast(entry.intermediates.len));
    for (entry.intermediates) |intermediate| {
        try bytes.append(allocator, @backingInt(intermediate.dtype));
        try encodeScalarDerivation(bytes, allocator, intermediate.extent);
    }
    try appendInt(bytes, allocator, u32, @intCast(entry.stages.len));
    for (entry.stages) |stage| {
        try appendSized(bytes, allocator, stage.target);
        try appendInt(bytes, allocator, u32, stage.version);
        try appendInt(bytes, allocator, u32, @intCast(stage.buffers.len));
        for (stage.buffers) |ref| try encodeValueRef(bytes, allocator, ref);
        try appendInt(bytes, allocator, u32, @intCast(stage.scalars.len));
        for (stage.scalars) |derivation| try encodeScalarDerivation(bytes, allocator, derivation);
    }
}

fn decodePipeline(
    cursor: *ByteReader,
    arena: std.mem.Allocator,
) Error!pipeline_mod.KernelCallPipeline {
    const target = try takeSizedCopy(cursor, arena);
    const version = try readInt(cursor, u32);
    const operand_count = try readInt(cursor, u32);
    const result_count = try readInt(cursor, u32);
    const runtime_scalar_argument_count = try readInt(cursor, u32);
    const runtime_scalar_bound_count = try readInt(cursor, u32);
    if (runtime_scalar_bound_count > cursor.remaining() / 8) return error.TruncatedRegistryBlob;
    const runtime_scalar_bounds = try arena.alloc(
        pipeline_mod.PipelineRuntimeScalarBound,
        runtime_scalar_bound_count,
    );
    for (runtime_scalar_bounds) |*bound| {
        bound.* = .{
            .argument_index = try readInt(cursor, u32),
            .max_u32 = try readInt(cursor, u32),
        };
    }
    const intermediate_count = try readInt(cursor, u32);
    if (intermediate_count > cursor.remaining()) return error.TruncatedRegistryBlob;
    const intermediates = try arena.alloc(pipeline_mod.PipelineIntermediate, intermediate_count);
    for (intermediates) |*intermediate| {
        intermediate.* = .{
            .dtype = try readEnum(cursor, gpu_abi.DType),
            .extent = try decodeScalarDerivation(cursor),
        };
    }
    const stage_count = try readInt(cursor, u32);
    if (stage_count > cursor.remaining()) return error.TruncatedRegistryBlob;
    const stages = try arena.alloc(pipeline_mod.PipelineStage, stage_count);
    for (stages) |*stage| {
        const stage_target = try takeSizedCopy(cursor, arena);
        const stage_version = try readInt(cursor, u32);
        const buffer_count = try readInt(cursor, u32);
        if (buffer_count > cursor.remaining()) return error.TruncatedRegistryBlob;
        const buffers = try arena.alloc(pipeline_mod.PipelineValueRef, buffer_count);
        for (buffers) |*ref| ref.* = try decodeValueRef(cursor);
        const scalar_count = try readInt(cursor, u32);
        if (scalar_count > cursor.remaining()) return error.TruncatedRegistryBlob;
        const scalars = try arena.alloc(pipeline_mod.PipelineScalarDerivation, scalar_count);
        for (scalars) |*derivation| derivation.* = try decodeScalarDerivation(cursor);
        stage.* = .{
            .target = stage_target,
            .version = stage_version,
            .buffers = buffers,
            .scalars = scalars,
        };
    }
    return .{
        .target = target,
        .version = version,
        .operand_count = operand_count,
        .result_count = result_count,
        .runtime_scalar_argument_count = runtime_scalar_argument_count,
        .runtime_scalar_bounds = runtime_scalar_bounds,
        .intermediates = intermediates,
        .stages = stages,
    };
}

fn encodeValueRef(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    ref: pipeline_mod.PipelineValueRef,
) !void {
    switch (ref) {
        .operand => |index| {
            try bytes.append(allocator, 0);
            try appendInt(bytes, allocator, u32, index);
        },
        .result => |index| {
            try bytes.append(allocator, 1);
            try appendInt(bytes, allocator, u32, index);
        },
        .intermediate => |index| {
            try bytes.append(allocator, 2);
            try appendInt(bytes, allocator, u32, index);
        },
    }
}

fn decodeValueRef(cursor: *ByteReader) Error!pipeline_mod.PipelineValueRef {
    return switch (try readByte(cursor)) {
        0 => .{ .operand = try readInt(cursor, u32) },
        1 => .{ .result = try readInt(cursor, u32) },
        2 => .{ .intermediate = try readInt(cursor, u32) },
        else => error.InvalidRegistryTag,
    };
}

fn encodeScalarDerivation(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    derivation: pipeline_mod.PipelineScalarDerivation,
) !void {
    switch (derivation) {
        .forward => |index| {
            try bytes.append(allocator, 0);
            try appendInt(bytes, allocator, u32, index);
        },
        .ceil_div => |axis| {
            try bytes.append(allocator, 1);
            try appendInt(bytes, allocator, u32, axis.argument_index);
            try appendInt(bytes, allocator, u32, axis.divisor);
        },
        .ceil_div_scaled => |scaled| {
            try bytes.append(allocator, 2);
            try appendInt(bytes, allocator, u32, scaled.argument_index);
            try appendInt(bytes, allocator, u32, scaled.divisor);
            try appendInt(bytes, allocator, u32, scaled.scale);
        },
        .ceil_div_scaled_by_arg => |scaled| {
            try bytes.append(allocator, 3);
            try appendInt(bytes, allocator, u32, scaled.argument_index);
            try appendInt(bytes, allocator, u32, scaled.divisor);
            try appendInt(bytes, allocator, u32, scaled.scale_argument_index);
        },
    }
}

fn decodeScalarDerivation(cursor: *ByteReader) Error!pipeline_mod.PipelineScalarDerivation {
    return switch (try readByte(cursor)) {
        0 => .{ .forward = try readInt(cursor, u32) },
        1 => .{ .ceil_div = .{
            .argument_index = try readInt(cursor, u32),
            .divisor = try readInt(cursor, u32),
        } },
        2 => .{ .ceil_div_scaled = .{
            .argument_index = try readInt(cursor, u32),
            .divisor = try readInt(cursor, u32),
            .scale = try readInt(cursor, u32),
        } },
        3 => .{ .ceil_div_scaled_by_arg = .{
            .argument_index = try readInt(cursor, u32),
            .divisor = try readInt(cursor, u32),
            .scale_argument_index = try readInt(cursor, u32),
        } },
        else => error.InvalidRegistryTag,
    };
}

fn encodeScalar(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    argument: gpu_abi.ScalarArgument,
) !void {
    try bytes.append(allocator, @backingInt(argument));
    const value: u64 = switch (argument) {
        .i32 => |v| @as(u32, @bitCast(v)),
        .u32 => |v| v,
        .i64 => |v| @as(u64, @bitCast(v)),
        .u64 => |v| v,
        .f32 => |v| @as(u32, @bitCast(v)),
        .f64 => |v| @as(u64, @bitCast(v)),
    };
    try appendInt(bytes, allocator, u64, value);
}

fn encodeOptionalU64(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    value: ?u64,
) !void {
    try bytes.append(allocator, @intFromBool(value != null));
    if (value) |payload| try appendInt(bytes, allocator, u64, payload);
}

fn decodeOptionalU64(cursor: *ByteReader) Error!?u64 {
    return switch (try readByte(cursor)) {
        0 => null,
        1 => try readInt(cursor, u64),
        else => error.InvalidRegistryTag,
    };
}

fn encodeShapeProfile(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    profile: ?plan.KernelCallShapeProfile,
) !void {
    if (profile) |value| {
        try bytes.append(allocator, 1);
        try appendSized(bytes, allocator, value.name);
        try appendInt(bytes, allocator, u64, value.fingerprint);
        try appendInt(bytes, allocator, u32, @intCast(value.dimensions.len));
        for (value.dimensions) |dimension| {
            try appendSized(bytes, allocator, dimension.name);
            try appendInt(bytes, allocator, u32, dimension.runtime_scalar_argument_index);
            try encodeBounds(bytes, allocator, dimension.bounds);
        }
    } else {
        try bytes.append(allocator, 0);
    }
}

fn decodeShapeProfile(
    cursor: *ByteReader,
    arena: std.mem.Allocator,
) Error!?plan.KernelCallShapeProfile {
    return switch (try readByte(cursor)) {
        0 => null,
        1 => blk: {
            const name = try takeSizedCopy(cursor, arena);
            const fingerprint = try readInt(cursor, u64);
            const dimension_count = try readInt(cursor, u32);
            const dimensions = try arena.alloc(
                plan.KernelCallShapeProfileDimension,
                dimension_count,
            );
            for (dimensions) |*dimension| {
                dimension.* = .{
                    .name = try takeSizedCopy(cursor, arena),
                    .runtime_scalar_argument_index = try readInt(cursor, u32),
                    .bounds = try decodeBounds(cursor),
                };
            }
            break :blk .{
                .name = name,
                .fingerprint = fingerprint,
                .dimensions = dimensions,
            };
        },
        else => error.InvalidRegistryTag,
    };
}

fn encodeBounds(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    bounds: anytype,
) !void {
    try encodeOptionalU64(bytes, allocator, bounds.min);
    try encodeOptionalU64(bytes, allocator, bounds.opt);
    try encodeOptionalU64(bytes, allocator, bounds.max);
}

fn decodeBounds(cursor: *ByteReader) Error!plan.KernelCallShapeProfileBounds {
    return .{
        .min = try decodeOptionalU64(cursor),
        .opt = try decodeOptionalU64(cursor),
        .max = try decodeOptionalU64(cursor),
    };
}

fn decodeScalar(cursor: *ByteReader) Error!gpu_abi.ScalarArgument {
    const tag = try readEnum(cursor, std.meta.Tag(gpu_abi.ScalarArgument));
    const value = try readInt(cursor, u64);
    return switch (tag) {
        .i32 => .{ .i32 = @bitCast(@as(u32, @truncate(value))) },
        .u32 => .{ .u32 = @truncate(value) },
        .i64 => .{ .i64 = @bitCast(value) },
        .u64 => .{ .u64 = value },
        .f32 => .{ .f32 = @bitCast(@as(u32, @truncate(value))) },
        .f64 => .{ .f64 = @bitCast(value) },
    };
}

fn packFeatures(features: gpu_abi.Features) u16 {
    var packed_bits: u16 = 0;
    if (features.atomic_i32) packed_bits |= 1 << 0;
    if (features.atomic_u32) packed_bits |= 1 << 1;
    if (features.atomic_index) packed_bits |= 1 << 2;
    if (features.atomic_f32_add_device) packed_bits |= 1 << 3;
    if (features.atomic_f32_add_shared) packed_bits |= 1 << 4;
    if (features.unsupported_atomic) packed_bits |= 1 << 5;
    if (features.async_copy) packed_bits |= 1 << 6;
    if (features.tensor_cores) packed_bits |= 1 << 7;
    if (features.cooperative_matrix) packed_bits |= 1 << 8;
    if (features.dynamic_shared_memory) packed_bits |= 1 << 9;
    if (features.indirect_launch) packed_bits |= 1 << 10;
    return packed_bits;
}

fn unpackFeatures(packed_bits: u16) gpu_abi.Features {
    return .{
        .atomic_i32 = packed_bits & (1 << 0) != 0,
        .atomic_u32 = packed_bits & (1 << 1) != 0,
        .atomic_index = packed_bits & (1 << 2) != 0,
        .atomic_f32_add_device = packed_bits & (1 << 3) != 0,
        .atomic_f32_add_shared = packed_bits & (1 << 4) != 0,
        .unsupported_atomic = packed_bits & (1 << 5) != 0,
        .async_copy = packed_bits & (1 << 6) != 0,
        .tensor_cores = packed_bits & (1 << 7) != 0,
        .cooperative_matrix = packed_bits & (1 << 8) != 0,
        .dynamic_shared_memory = packed_bits & (1 << 9) != 0,
        .indirect_launch = packed_bits & (1 << 10) != 0,
    };
}

fn packSubgroupFlags(subgroup: gpu_abi.SubgroupRequirements) u8 {
    var packed_bits: u8 = 0;
    if (subgroup.supported) packed_bits |= 1 << 0;
    if (subgroup.shuffle) packed_bits |= 1 << 1;
    if (subgroup.ballot) packed_bits |= 1 << 2;
    if (subgroup.vote) packed_bits |= 1 << 3;
    if (subgroup.arithmetic) packed_bits |= 1 << 4;
    if (subgroup.scan) packed_bits |= 1 << 5;
    return packed_bits;
}

fn unpackSubgroupFlags(packed_bits: u8) gpu_abi.SubgroupRequirements {
    return .{
        .supported = packed_bits & (1 << 0) != 0,
        .shuffle = packed_bits & (1 << 1) != 0,
        .ballot = packed_bits & (1 << 2) != 0,
        .vote = packed_bits & (1 << 3) != 0,
        .arithmetic = packed_bits & (1 << 4) != 0,
        .scan = packed_bits & (1 << 5) != 0,
    };
}

fn appendInt(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    comptime T: type,
    value: T,
) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try bytes.appendSlice(allocator, &buffer);
}

fn appendSized(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    data: []const u8,
) !void {
    try appendInt(bytes, allocator, u32, @intCast(data.len));
    try bytes.appendSlice(allocator, data);
}

fn readEnum(cursor: *ByteReader, comptime E: type) Error!E {
    return std.enums.fromInt(E, try readByte(cursor)) orelse error.InvalidRegistryTag;
}

fn takeSizedCopy(cursor: *ByteReader, arena: std.mem.Allocator) Error![]u8 {
    const length = try readInt(cursor, u32);
    return takeCopy(cursor, arena, length);
}

fn takeCopy(cursor: *ByteReader, arena: std.mem.Allocator, length: usize) Error![]u8 {
    return arena.dupe(u8, try take(cursor, length));
}

fn take(cursor: *ByteReader, count: usize) Error![]const u8 {
    return cursor.readBytes(count) catch return error.TruncatedRegistryBlob;
}

fn readByte(cursor: *ByteReader) Error!u8 {
    return cursor.readByte() catch return error.TruncatedRegistryBlob;
}

fn readInt(cursor: *ByteReader, comptime T: type) Error!T {
    return cursor.readInt(T) catch return error.TruncatedRegistryBlob;
}

fn readLength(cursor: *ByteReader) Error!usize {
    const length = try readInt(cursor, u64);
    return std.math.cast(usize, length) orelse error.TruncatedRegistryBlob;
}

test "artifact wire round-trips a synthetic registry" {
    const static_arguments = [_]gpu_abi.ScalarArgument{
        .{ .i32 = -7 },
        .{ .u32 = 9 },
        .{ .i64 = -1234567890123 },
        .{ .u64 = 9876543210987 },
        .{ .f32 = 1.5 },
        .{ .f64 = -2.25 },
    };
    const words = [_]u32{ 0xdeadbeef, 1, 2, 3 };
    const shape_profile_dimensions = [_]plan.KernelCallShapeProfileDimension{
        .{
            .name = "m",
            .runtime_scalar_argument_index = 0,
            .bounds = .{ .min = 1, .opt = 128, .max = 4096 },
        },
        .{
            .name = "n",
            .runtime_scalar_argument_index = 1,
            .bounds = .{ .min = 1, .opt = 128, .max = 4096 },
        },
    };
    var push_constants: gpu_abi.PushConstants = .{};
    _ = try push_constants.append(4, .{});
    _ = try push_constants.append(8, .{});
    const entries = [_]plan.KernelCallArtifact{
        .{
            .target = "accy.kernel.linalg.matmul5x7x3_4x2_f32",
            .version = 1,
            .format = .cuda_ptx,
            .entry_name = "accy_kernel_linalg_matmul5x7x3_4x2_f32",
            .argument_count = 3,
            .required_dtypes = gpu.DTypeSet.init(&.{.f32}),
            .payload = .{ .text = "// ptx text" },
            .launch = .{ .fixed = .{
                .grid = .{ 2, 3, 1 },
                .threadgroup = .{ 4, 2, 1 },
            } },
        },
        .{
            .target = "accy.kernel.test.full",
            .version = 7,
            .format = .vulkan_spirv,
            .entry_name = "accy_kernel_test_full",
            .argument_count = 9,
            .required_dtypes = gpu.DTypeSet.init(&.{ .f32, .i32 }),
            .required_features = .{
                .atomic_i32 = true,
                .atomic_f32_add_device = true,
                .dynamic_shared_memory = true,
            },
            .required_subgroup = .{
                .supported = true,
                .size_min = 16,
                .size_max = 64,
                .shuffle = true,
                .scan = true,
            },
            .push_constants = push_constants,
            .payload = .{ .words_u32 = words[0..] },
            .launch = .{ .derived = .{
                .grid = .{
                    .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = 8 } },
                    .{ .runtime_u32_ceil_div = .{ .argument_index = 1, .divisor = 4 } },
                    .{ .fixed = 1 },
                },
                .threadgroup = .{ 8, 4, 1 },
                .dynamic_shared_memory_bytes = 256,
            } },
            .element_count_argument = .scalar_u32,
            .runtime_scalar_argument_count = 2,
            .static_arguments = static_arguments[0..],
            .shape_family_fingerprint = 0x1234_5678_90ab_cdef,
            .shape_profile = .{
                .name = "matrix_product",
                .fingerprint = 0x1234_5678_90ab_cdef,
                .dimensions = shape_profile_dimensions[0..],
            },
        },
        .{
            .target = "accy.kernel.test.bytes",
            .version = 2,
            .format = .metal_metallib,
            .entry_name = "accy_kernel_test_bytes",
            .argument_count = 1,
            .payload = .{ .bytes = "\x00\x01\x02binary" },
        },
    };

    const encoded = try encode(std.testing.allocator, entries[0..], &.{});
    defer std.testing.allocator.free(encoded);

    var decoded = try decode(std.testing.allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(entries.len, decoded.entries.len);
    try std.testing.expect(decoded.index.slots.len >= entries.len);
    try std.testing.expect(decoded.registry().index != null);
    for (entries[0..], decoded.entries) |expected, actual| {
        try std.testing.expectEqualDeep(expected, actual);
    }

    const found = decoded.registry().find("accy.kernel.test.full", 7, .vulkan_spirv) orelse {
        return error.TestExpectedRegistryEntry;
    };
    try std.testing.expectEqual(@as(u32, 9), found.argument_count);
    try std.testing.expectEqual(plan.ElementCountArgument.scalar_u32, found.element_count_argument);
    try std.testing.expectEqual(@as(u32, 2), found.runtime_scalar_argument_count);
    try std.testing.expectEqual(@as(?u64, 0x1234_5678_90ab_cdef), found.shape_family_fingerprint);
    const profile = found.shape_profile orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("matrix_product", profile.name);
    try std.testing.expectEqual(@as(u64, 0x1234_5678_90ab_cdef), profile.fingerprint);
    try std.testing.expectEqual(@as(usize, 2), profile.dimensions.len);
    const n_dimension = profile.dimension("n") orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqual(@as(u32, 1), n_dimension.runtime_scalar_argument_index);
    try std.testing.expectEqual(@as(?u64, 4096), n_dimension.bounds.max);
    switch (found.launch) {
        .derived => |launch| {
            try std.testing.expectEqual(@as(u32, 8), launch.threadgroup[0]);
            try std.testing.expectEqual(@as(u32, 4), launch.threadgroup[1]);
            try std.testing.expectEqual(@as(u32, 256), launch.dynamic_shared_memory_bytes);
        },
        .fixed => return error.TestExpectedDerivedLaunch,
    }
}

test "artifact wire rejects malformed registry blobs" {
    const entries = [_]plan.KernelCallArtifact{.{
        .target = "accy.kernel.test.copy",
        .version = 1,
        .format = .cuda_ptx,
        .entry_name = "accy_kernel_test_copy",
        .argument_count = 2,
        .payload = .{ .text = "// ptx" },
    }};

    const encoded = try encode(std.testing.allocator, entries[0..], &.{});
    defer std.testing.allocator.free(encoded);

    var bad_magic = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_magic);
    bad_magic[0] = 'X';
    try std.testing.expectError(
        error.InvalidRegistryBlob,
        decode(std.testing.allocator, bad_magic),
    );

    var bad_version = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_version);
    std.mem.writeInt(u32, bad_version[magic.len..][0..4], format_version + 1, .little);
    try std.testing.expectError(
        error.UnsupportedRegistryVersion,
        decode(std.testing.allocator, bad_version),
    );

    var prefix_length: usize = magic.len + @sizeOf(u32);
    while (prefix_length < encoded.len) : (prefix_length += 7) {
        try std.testing.expectError(
            error.TruncatedRegistryBlob,
            decode(std.testing.allocator, encoded[0..prefix_length]),
        );
    }

    const trailing = try std.mem.concat(std.testing.allocator, u8, &.{ encoded, "junk" });
    defer std.testing.allocator.free(trailing);
    try std.testing.expectError(error.InvalidRegistryBlob, decode(std.testing.allocator, trailing));
}

test "artifact wire round-trips an empty registry" {
    const encoded = try encode(std.testing.allocator, &.{}, &.{});
    defer std.testing.allocator.free(encoded);

    var decoded = try decode(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 0), decoded.entries.len);
    try std.testing.expect(decoded.registry().find("missing", 1, .cuda_ptx) == null);
}

test "artifact wire rejects duplicate registry keys" {
    const entries = [_]plan.KernelCallArtifact{
        .{
            .target = "accy.kernel.test.duplicate",
            .version = 1,
            .format = .cuda_ptx,
            .entry_name = "duplicate_first",
            .argument_count = 1,
            .payload = .{ .text = "// first" },
        },
        .{
            .target = "accy.kernel.test.duplicate",
            .version = 1,
            .format = .cuda_ptx,
            .entry_name = "duplicate_second",
            .argument_count = 1,
            .payload = .{ .text = "// second" },
        },
    };

    const encoded = try encode(std.testing.allocator, entries[0..], &.{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(error.InvalidRegistryBlob, decode(std.testing.allocator, encoded));
}

pub const ByteWriter = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *ByteWriter, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = undefined;
    }

    pub fn toOwnedSlice(
        self: *ByteWriter,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]u8 {
        return self.bytes.toOwnedSlice(allocator);
    }

    pub fn writeU32(
        self: *ByteWriter,
        allocator: std.mem.Allocator,
        value: u32,
    ) gpu.BackendError!void {
        try self.writeInt(allocator, u32, value);
    }

    pub fn writeU64(
        self: *ByteWriter,
        allocator: std.mem.Allocator,
        value: u64,
    ) gpu.BackendError!void {
        try self.writeInt(allocator, u64, value);
    }

    pub fn writeUsize(
        self: *ByteWriter,
        allocator: std.mem.Allocator,
        value: usize,
    ) gpu.BackendError!void {
        try self.writeU64(allocator, @intCast(value));
    }

    pub fn writeBool(
        self: *ByteWriter,
        allocator: std.mem.Allocator,
        value: bool,
    ) gpu.BackendError!void {
        self.bytes.append(allocator, @intFromBool(value)) catch return error.OutOfMemory;
    }

    pub fn writeLengthPrefixedBytes(
        self: *ByteWriter,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) gpu.BackendError!void {
        if (bytes.len > std.math.maxInt(u32)) return error.InvalidArtifact;
        try self.writeU32(allocator, @intCast(bytes.len));
        self.bytes.appendSlice(allocator, bytes) catch return error.OutOfMemory;
    }

    pub fn writeEnum(
        self: *ByteWriter,
        allocator: std.mem.Allocator,
        comptime T: type,
        value: T,
    ) gpu.BackendError!void {
        try self.writeU32(allocator, @intCast(@backingInt(value)));
    }

    fn writeInt(
        self: *ByteWriter,
        allocator: std.mem.Allocator,
        comptime T: type,
        value: T,
    ) gpu.BackendError!void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, value, .little);
        self.bytes.appendSlice(allocator, &buf) catch return error.OutOfMemory;
    }
};

pub const ByteReader = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn remaining(self: *const ByteReader) usize {
        if (self.offset > self.bytes.len) return 0;
        return self.bytes.len - self.offset;
    }

    pub fn readByte(self: *ByteReader) gpu.BackendError!u8 {
        const bytes = try self.readBytes(1);
        return bytes[0];
    }

    pub fn readU32(self: *ByteReader) gpu.BackendError!u32 {
        return try self.readInt(u32);
    }

    pub fn readU64(self: *ByteReader) gpu.BackendError!u64 {
        return try self.readInt(u64);
    }

    pub fn readUsize(self: *ByteReader) gpu.BackendError!usize {
        const value = try self.readU64();
        if (value > std.math.maxInt(usize)) return error.InvalidArtifact;
        return @intCast(value);
    }

    pub fn readLengthPrefixedBytes(self: *ByteReader) gpu.BackendError![]const u8 {
        const length = try self.readU32();
        return try self.readBytes(length);
    }

    pub fn readBool(self: *ByteReader) gpu.BackendError!bool {
        const bytes = try self.readBytes(1);
        return switch (bytes[0]) {
            0 => false,
            1 => true,
            else => error.InvalidArtifact,
        };
    }

    pub fn readEnum(
        self: *ByteReader,
        comptime T: type,
    ) gpu.BackendError!T {
        return try byteEnumFromU32(T, try self.readU32());
    }

    pub fn readInt(
        self: *ByteReader,
        comptime T: type,
    ) gpu.BackendError!T {
        const bytes = try self.readBytes(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }

    pub fn readBytes(
        self: *ByteReader,
        count: usize,
    ) gpu.BackendError![]const u8 {
        if (self.offset > self.bytes.len or count > self.bytes.len - self.offset) {
            return error.InvalidArtifact;
        }
        const start = self.offset;
        self.offset += count;
        return self.bytes[start..self.offset];
    }

    pub fn expectDone(self: ByteReader) gpu.BackendError!void {
        if (self.offset != self.bytes.len) return error.InvalidArtifact;
    }
};

fn byteEnumFromU32(comptime T: type, value: u32) gpu.BackendError!T {
    inline for (
        @typeInfo(T).@"enum".field_names,
        @typeInfo(T).@"enum".field_values,
    ) |field_name, field_name_value| {
        const field = .{ .name = field_name, .value = field_name_value };
        if (value == field.value) return @fromBackingInt(@intCast(field.value));
    }
    return error.InvalidArtifact;
}

test "byte writer and reader round-trip primitive values" {
    const allocator = std.testing.allocator;
    var writer = ByteWriter{};
    errdefer writer.deinit(allocator);

    try writer.writeU32(allocator, 7);
    try writer.writeU64(allocator, 1 << 40);
    try writer.writeBool(allocator, true);
    try writer.writeLengthPrefixedBytes(allocator, "target");
    try writer.writeEnum(allocator, gpu.BackendKind, .cuda);

    const encoded = try writer.toOwnedSlice(allocator);
    defer allocator.free(encoded);

    var reader = ByteReader{ .bytes = encoded };
    try std.testing.expectEqual(@as(u32, 7), try reader.readU32());
    try std.testing.expectEqual(@as(u64, 1 << 40), try reader.readU64());
    try std.testing.expectEqual(true, try reader.readBool());
    try std.testing.expectEqualStrings("target", try reader.readLengthPrefixedBytes());
    try std.testing.expectEqual(gpu.BackendKind.cuda, try reader.readEnum(gpu.BackendKind));
    try reader.expectDone();

    var truncated = ByteReader{ .bytes = encoded[0 .. encoded.len - 1] };
    _ = try truncated.readU32();
    _ = try truncated.readU64();
    _ = try truncated.readBool();
    _ = try truncated.readLengthPrefixedBytes();
    try std.testing.expectError(error.InvalidArtifact, truncated.readEnum(gpu.BackendKind));
}

test "artifact wire round-trips pipelines beside entries" {
    const entries = [_]plan.KernelCallArtifact{
        .{
            .target = "accy.kernel.test.block_scan",
            .version = 1,
            .format = .cuda_ptx,
            .entry_name = "block_scan",
            .argument_count = 4,
            .payload = .{ .text = "// block scan" },
            .runtime_scalar_argument_count = 1,
        },
        .{
            .target = "accy.kernel.test.add_base",
            .version = 1,
            .format = .cuda_ptx,
            .entry_name = "add_base",
            .argument_count = 3,
            .payload = .{ .text = "// add base" },
            .runtime_scalar_argument_count = 1,
        },
    };
    const pipelines = [_]pipeline_mod.KernelCallPipeline{.{
        .target = "accy.kernel.test.device_scan",
        .version = 3,
        .operand_count = 1,
        .result_count = 1,
        .runtime_scalar_argument_count = 1,
        .runtime_scalar_bounds = &.{.{ .argument_index = 0, .max_u32 = 6144 }},
        .intermediates = &.{
            .{ .dtype = .f32, .extent = .{ .ceil_div = .{ .argument_index = 0, .divisor = 64 } } },
            .{ .dtype = .f32, .extent = .{
                .ceil_div_scaled = .{ .argument_index = 0, .divisor = 64, .scale = 16 },
            } },
            .{ .dtype = .f32, .extent = .{ .ceil_div_scaled_by_arg = .{
                .argument_index = 0,
                .divisor = 64,
                .scale_argument_index = 0,
            } } },
        },
        .stages = &.{
            .{
                .target = "accy.kernel.test.block_scan",
                .version = 1,
                .buffers = &.{ .{ .result = 0 }, .{ .operand = 0 }, .{ .intermediate = 0 } },
                .scalars = &.{.{ .forward = 0 }},
            },
            .{
                .target = "accy.kernel.test.add_base",
                .version = 1,
                .buffers = &.{ .{ .result = 0 }, .{ .intermediate = 0 } },
                .scalars = &.{.{ .ceil_div = .{ .argument_index = 0, .divisor = 64 } }},
            },
        },
    }};

    const encoded = try encode(std.testing.allocator, entries[0..], pipelines[0..]);
    defer std.testing.allocator.free(encoded);

    var decoded = try decode(std.testing.allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(pipelines.len, decoded.pipelines.len);
    for (pipelines[0..], decoded.pipelines) |expected, actual| {
        try std.testing.expectEqualDeep(expected, actual);
    }

    const found = pipeline_mod.findPipeline(
        decoded.pipelines,
        "accy.kernel.test.device_scan",
        3,
    ) orelse {
        return error.TestExpectedPipeline;
    };
    try found.validate(decoded.registry(), .cuda_ptx);

    var prefix_length: usize = magic.len + @sizeOf(u32);
    while (prefix_length < encoded.len) : (prefix_length += 7) {
        const result = decode(std.testing.allocator, encoded[0..prefix_length]);
        try std.testing.expectError(error.TruncatedRegistryBlob, result);
    }
}

test "artifact wire rejects duplicate pipeline identities" {
    const duplicate = pipeline_mod.KernelCallPipeline{
        .target = "accy.kernel.test.device_scan",
        .version = 1,
        .stages = &.{.{ .target = "accy.kernel.test.stage", .version = 1 }},
    };
    const pipelines = [_]pipeline_mod.KernelCallPipeline{ duplicate, duplicate };
    const encoded = try encode(std.testing.allocator, &.{}, pipelines[0..]);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(error.InvalidRegistryBlob, decode(std.testing.allocator, encoded));
}

test "artifact wire rejects zero-version pipeline identities" {
    const zero_version = pipeline_mod.KernelCallPipeline{
        .target = "accy.kernel.test.device_scan",
        .version = 0,
        .stages = &.{.{ .target = "accy.kernel.test.stage", .version = 1 }},
    };
    const encoded = try encode(std.testing.allocator, &.{}, &.{zero_version});
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(error.InvalidRegistryBlob, decode(std.testing.allocator, encoded));
}
