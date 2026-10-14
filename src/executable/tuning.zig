const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const artifact_product = @import("../artifact/root.zig");

pub const product_name = "accy.exec.tuning";

pub const LaunchCandidateMeasurement = struct {
    kernel_id: usize,
    candidate_index: usize,
    median_ns: u64,
    sample_count: u32 = 1,
};

pub const LaunchTuningSelection = struct {
    kernel_id: usize,
    candidate_index: usize,
    median_ns: u64 = 0,
    sample_count: u32 = 0,
};

pub const launch_tuning_cache_record_version: u32 = 6;
pub const launch_tuning_artifact_magic: u32 = 0x41515431;
pub const launch_tuning_artifact_version: u32 = 6;

pub fn artifactFingerprint(bytes: []const u8) choir.product.incremental.Fingerprint {
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes(product_name);
    builder.updateU32(launch_tuning_artifact_version);
    builder.updateBytes(bytes);
    return builder.finish();
}

pub fn artifactProductStamp(bytes: []const u8) choir.product.incremental.ProductStamp {
    return choir.product.incremental.productStamp(product_name, artifactFingerprint(bytes));
}

pub const LaunchTuningCacheKey = struct {
    backend: gpu.BackendKind,
    family: gpu.DeviceFamily,
    format: gpu.ArtifactFormat,
    vendor_id: u32 = 0,
    has_vendor_id: bool = false,
    device_id: u32 = 0,
    has_device_id: bool = false,
    name_fingerprint: u64 = 0,
    driver_version_fingerprint: u64 = 0,
    has_driver_version: bool = false,
    subgroup_supported: bool = false,
    subgroup_size_min: u32 = 0,
    subgroup_size_max: u32 = 0,
    subgroup_shuffle: bool = false,
    subgroup_ballot: bool = false,
    subgroup_vote: bool = false,
    subgroup_arithmetic: bool = false,
    subgroup_scan: bool = false,
    max_threads: u32 = 0,
    max_threads_per_dim_x: u32 = 0,
    max_threads_per_dim_y: u32 = 0,
    max_threads_per_dim_z: u32 = 0,
    max_grid_per_dim_x: u32 = 0,
    max_grid_per_dim_y: u32 = 0,
    max_grid_per_dim_z: u32 = 0,
    shared_memory_bytes: u32 = 0,
    dtype_bits: u64 = 0,
    tensor_cores: bool = false,
    cooperative_matrix: bool = false,
    dynamic_shared_memory: bool = false,
    output_layout_fingerprint: u64 = 0,
    input_layout_fingerprint: u64 = 0,
    element_count: u64 = 0,
    resource_class: artifact_product.LaunchResourceClass = .unknown,
    element_ops_per_kib: u64 = 0,
    static_bytes_complete: bool = false,
    tile_kind: artifact_product.LaunchTileKind = .none,
    tile_m: u32 = 0,
    tile_n: u32 = 0,
    tile_k: u32 = 0,
    tile_batch: u32 = 1,
    tile_has_input_dtype: bool = false,
    tile_input_dtype: gpu_abi.DType = .f32,
    tile_has_output_dtype: bool = false,
    tile_output_dtype: gpu_abi.DType = .f32,
    tile_input_tile_bytes: u32 = 0,
    tile_output_tile_bytes: u32 = 0,
    tile_scratch_memory_bytes: u32 = 0,
    tile_reduction_kind: artifact_product.LaunchReductionKind = .none,
    tile_reduction_rank: u32 = 0,
    tile_reduction_axis: u32 = 0,
    tile_reduction_extent: u32 = 0,
    candidate_count: u32 = 0,
    launch_resource_fingerprint: u64 = 0,

    pub fn init(
        caps: gpu.BackendCapabilities,
        planned: artifact_product.PlannedKernel,
    ) LaunchTuningCacheKey {
        const tile = planned.launch_resources.tile;
        return .{
            .backend = caps.identity.backend,
            .family = caps.identity.family,
            .format = planned.launch_resources.format,
            .vendor_id = caps.identity.vendor_id orelse 0,
            .has_vendor_id = caps.identity.vendor_id != null,
            .device_id = caps.identity.device_id orelse 0,
            .has_device_id = caps.identity.device_id != null,
            .name_fingerprint = bytesFingerprint(
                "accy.exec.tuning.device.name",
                caps.identity.name,
            ),
            .driver_version_fingerprint = if (caps.identity.driver_version) |version|
                bytesFingerprint("accy.exec.tuning.driver.version", version)
            else
                0,
            .has_driver_version = caps.identity.driver_version != null,
            .subgroup_supported = caps.subgroup.supported,
            .subgroup_size_min = caps.subgroup.size_min,
            .subgroup_size_max = caps.subgroup.size_max,
            .subgroup_shuffle = caps.subgroup.shuffle,
            .subgroup_ballot = caps.subgroup.ballot,
            .subgroup_vote = caps.subgroup.vote,
            .subgroup_arithmetic = caps.subgroup.arithmetic,
            .subgroup_scan = caps.subgroup.scan,
            .max_threads = caps.threadgroup.max_threads,
            .max_threads_per_dim_x = caps.threadgroup.max_threads_per_dim[0],
            .max_threads_per_dim_y = caps.threadgroup.max_threads_per_dim[1],
            .max_threads_per_dim_z = caps.threadgroup.max_threads_per_dim[2],
            .max_grid_per_dim_x = caps.threadgroup.max_grid_per_dim[0],
            .max_grid_per_dim_y = caps.threadgroup.max_grid_per_dim[1],
            .max_grid_per_dim_z = caps.threadgroup.max_grid_per_dim[2],
            .shared_memory_bytes = caps.threadgroup.shared_memory_bytes,
            .dtype_bits = caps.dtypes.bits,
            .tensor_cores = caps.features.tensor_cores,
            .cooperative_matrix = caps.features.cooperative_matrix,
            .dynamic_shared_memory = caps.features.dynamic_shared_memory,
            .output_layout_fingerprint = planned.output_layout_fingerprint,
            .input_layout_fingerprint = planned.input_layout_fingerprint,
            .element_count = planned.launch_resources.element_count,
            .resource_class = planned.launch_resources.resource_class,
            .element_ops_per_kib = planned.launch_resources.element_ops_per_kib,
            .static_bytes_complete = planned.launch_resources.static_bytes_complete,
            .tile_kind = tile.kind,
            .tile_m = tile.m,
            .tile_n = tile.n,
            .tile_k = tile.k,
            .tile_batch = tile.batch,
            .tile_has_input_dtype = tile.input_dtype != null,
            .tile_input_dtype = tile.input_dtype orelse .f32,
            .tile_has_output_dtype = tile.output_dtype != null,
            .tile_output_dtype = tile.output_dtype orelse .f32,
            .tile_input_tile_bytes = tile.input_tile_bytes,
            .tile_output_tile_bytes = tile.output_tile_bytes,
            .tile_scratch_memory_bytes = tile.scratch_memory_bytes,
            .tile_reduction_kind = tile.reduction_kind,
            .tile_reduction_rank = tile.reduction_rank,
            .tile_reduction_axis = tile.reduction_axis,
            .tile_reduction_extent = tile.reduction_extent,
            .candidate_count = @intCast(planned.launch_resources.candidate_count),
            .launch_resource_fingerprint = artifact_product.launchResourcePlanFingerprint(
                planned.launch_resources,
            ),
        };
    }
};

pub const LaunchTuningCacheRecord = struct {
    version: u32 = launch_tuning_cache_record_version,
    key: LaunchTuningCacheKey,
    selection: LaunchTuningSelection,
};

pub const LaunchTuningCache = struct {
    selections: std.AutoHashMap(LaunchTuningCacheKey, LaunchTuningSelection),

    pub fn init(allocator: std.mem.Allocator) LaunchTuningCache {
        return .{
            .selections = std.AutoHashMap(
                LaunchTuningCacheKey,
                LaunchTuningSelection,
            ).init(allocator),
        };
    }

    pub fn deinit(self: *LaunchTuningCache) void {
        self.selections.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const LaunchTuningCache) usize {
        return self.selections.count();
    }

    pub fn exportRecords(
        self: *const LaunchTuningCache,
        result_allocator: std.mem.Allocator,
    ) gpu.BackendError![]LaunchTuningCacheRecord {
        const records = result_allocator.alloc(
            LaunchTuningCacheRecord,
            self.selections.count(),
        ) catch return error.OutOfMemory;
        errdefer result_allocator.free(records);

        var iterator = self.selections.iterator();
        var index: usize = 0;
        while (iterator.next()) |entry| {
            records[index] = .{
                .key = entry.key_ptr.*,
                .selection = entry.value_ptr.*,
            };
            index += 1;
        }
        std.mem.sort(LaunchTuningCacheRecord, records, {}, launchTuningCacheRecordSortsBefore);
        return records;
    }

    pub fn importRecords(
        self: *LaunchTuningCache,
        records: []const LaunchTuningCacheRecord,
    ) gpu.BackendError!void {
        for (records) |record| try validateLaunchTuningCacheRecord(record);
        for (records) |record| {
            if (self.selections.getPtr(record.key)) |existing| {
                if (launchSelectionBeats(record.selection, existing.*)) {
                    existing.* = record.selection;
                }
                continue;
            }
            self.selections.put(record.key, record.selection) catch return error.OutOfMemory;
        }
    }

    pub fn recordMeasurements(
        self: *LaunchTuningCache,
        caps: gpu.BackendCapabilities,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        measurements: []const LaunchCandidateMeasurement,
    ) gpu.BackendError!void {
        for (artifact_plan.kernels.items) |planned| {
            if (try selectedLaunchMeasurement(planned, measurements)) |measurement| {
                try self.recordMeasuredSelection(caps, planned, .{
                    .kernel_id = measurement.kernel_id,
                    .candidate_index = measurement.candidate_index,
                    .median_ns = measurement.median_ns,
                    .sample_count = measurement.sample_count,
                });
            }
        }
    }

    pub fn recordMeasuredSelection(
        self: *LaunchTuningCache,
        caps: gpu.BackendCapabilities,
        planned: artifact_product.PlannedKernel,
        selection: LaunchTuningSelection,
    ) gpu.BackendError!void {
        if (selection.kernel_id != planned.kernel_id) return error.LaunchArgumentMismatch;
        if (selection.candidate_index >= planned.launch_resources.candidate_count) {
            return error.LaunchArgumentMismatch;
        }
        if (selection.sample_count == 0) return error.LaunchArgumentMismatch;
        const key = LaunchTuningCacheKey.init(caps, planned);
        if (self.selections.getPtr(key)) |existing| {
            if (launchSelectionBeats(selection, existing.*)) existing.* = selection;
            return;
        }
        self.selections.put(key, selection) catch return error.OutOfMemory;
    }

    pub fn selectionForKernel(
        self: *const LaunchTuningCache,
        caps: gpu.BackendCapabilities,
        planned: artifact_product.PlannedKernel,
    ) gpu.BackendError!?LaunchTuningSelection {
        const key = LaunchTuningCacheKey.init(caps, planned);
        if (self.selections.get(key)) |selection| {
            if (selection.candidate_index >= planned.launch_resources.candidate_count) {
                return error.LaunchArgumentMismatch;
            }
            return .{
                .kernel_id = planned.kernel_id,
                .candidate_index = selection.candidate_index,
                .median_ns = selection.median_ns,
                .sample_count = selection.sample_count,
            };
        }
        return null;
    }
};

pub fn encodeLaunchTuningArtifact(
    result_allocator: std.mem.Allocator,
    records: []const LaunchTuningCacheRecord,
) gpu.BackendError![]u8 {
    if (records.len > std.math.maxInt(u32)) return error.InvalidArtifact;
    var writer = artifact_product.wire.ByteWriter{};
    errdefer writer.deinit(result_allocator);

    try writer.writeU32(result_allocator, launch_tuning_artifact_magic);
    try writer.writeU32(result_allocator, launch_tuning_artifact_version);
    try writer.writeU32(result_allocator, @intCast(records.len));
    for (records) |record| {
        try validateLaunchTuningCacheRecord(record);
        try writer.writeU32(result_allocator, record.version);
        try writer.writeEnum(result_allocator, gpu.BackendKind, record.key.backend);
        try writer.writeEnum(result_allocator, gpu.DeviceFamily, record.key.family);
        try writer.writeEnum(result_allocator, gpu.ArtifactFormat, record.key.format);
        try writer.writeU32(result_allocator, record.key.vendor_id);
        try writer.writeBool(result_allocator, record.key.has_vendor_id);
        try writer.writeU32(result_allocator, record.key.device_id);
        try writer.writeBool(result_allocator, record.key.has_device_id);
        try writer.writeU64(result_allocator, record.key.name_fingerprint);
        try writer.writeU64(result_allocator, record.key.driver_version_fingerprint);
        try writer.writeBool(result_allocator, record.key.has_driver_version);
        try writer.writeBool(result_allocator, record.key.subgroup_supported);
        try writer.writeU32(result_allocator, record.key.subgroup_size_min);
        try writer.writeU32(result_allocator, record.key.subgroup_size_max);
        try writer.writeBool(result_allocator, record.key.subgroup_shuffle);
        try writer.writeBool(result_allocator, record.key.subgroup_ballot);
        try writer.writeBool(result_allocator, record.key.subgroup_vote);
        try writer.writeBool(result_allocator, record.key.subgroup_arithmetic);
        try writer.writeBool(result_allocator, record.key.subgroup_scan);
        try writer.writeU32(result_allocator, record.key.max_threads);
        try writer.writeU32(result_allocator, record.key.max_threads_per_dim_x);
        try writer.writeU32(result_allocator, record.key.max_threads_per_dim_y);
        try writer.writeU32(result_allocator, record.key.max_threads_per_dim_z);
        try writer.writeU32(result_allocator, record.key.max_grid_per_dim_x);
        try writer.writeU32(result_allocator, record.key.max_grid_per_dim_y);
        try writer.writeU32(result_allocator, record.key.max_grid_per_dim_z);
        try writer.writeU32(result_allocator, record.key.shared_memory_bytes);
        try writer.writeU64(result_allocator, record.key.dtype_bits);
        try writer.writeBool(result_allocator, record.key.tensor_cores);
        try writer.writeBool(result_allocator, record.key.cooperative_matrix);
        try writer.writeBool(result_allocator, record.key.dynamic_shared_memory);
        try writer.writeU64(result_allocator, record.key.output_layout_fingerprint);
        try writer.writeU64(result_allocator, record.key.input_layout_fingerprint);
        try writer.writeU64(result_allocator, record.key.element_count);
        try writer.writeEnum(
            result_allocator,
            artifact_product.LaunchResourceClass,
            record.key.resource_class,
        );
        try writer.writeU64(result_allocator, record.key.element_ops_per_kib);
        try writer.writeBool(result_allocator, record.key.static_bytes_complete);
        try writer.writeEnum(
            result_allocator,
            artifact_product.LaunchTileKind,
            record.key.tile_kind,
        );
        try writer.writeU32(result_allocator, record.key.tile_m);
        try writer.writeU32(result_allocator, record.key.tile_n);
        try writer.writeU32(result_allocator, record.key.tile_k);
        try writer.writeU32(result_allocator, record.key.tile_batch);
        try writer.writeBool(result_allocator, record.key.tile_has_input_dtype);
        try writer.writeEnum(result_allocator, gpu_abi.DType, record.key.tile_input_dtype);
        try writer.writeBool(result_allocator, record.key.tile_has_output_dtype);
        try writer.writeEnum(result_allocator, gpu_abi.DType, record.key.tile_output_dtype);
        try writer.writeU32(result_allocator, record.key.tile_input_tile_bytes);
        try writer.writeU32(result_allocator, record.key.tile_output_tile_bytes);
        try writer.writeU32(result_allocator, record.key.tile_scratch_memory_bytes);
        try writer.writeEnum(
            result_allocator,
            artifact_product.LaunchReductionKind,
            record.key.tile_reduction_kind,
        );
        try writer.writeU32(result_allocator, record.key.tile_reduction_rank);
        try writer.writeU32(result_allocator, record.key.tile_reduction_axis);
        try writer.writeU32(result_allocator, record.key.tile_reduction_extent);
        try writer.writeU32(result_allocator, record.key.candidate_count);
        try writer.writeU64(result_allocator, record.key.launch_resource_fingerprint);
        try writer.writeUsize(result_allocator, record.selection.kernel_id);
        try writer.writeUsize(result_allocator, record.selection.candidate_index);
        try writer.writeU64(result_allocator, record.selection.median_ns);
        try writer.writeU32(result_allocator, record.selection.sample_count);
    }

    return writer.toOwnedSlice(result_allocator) catch return error.OutOfMemory;
}

pub fn decodeLaunchTuningArtifact(
    result_allocator: std.mem.Allocator,
    bytes: []const u8,
) gpu.BackendError![]LaunchTuningCacheRecord {
    var reader = artifact_product.wire.ByteReader{ .bytes = bytes };
    if ((try reader.readU32()) != launch_tuning_artifact_magic) return error.InvalidArtifact;
    if ((try reader.readU32()) != launch_tuning_artifact_version) return error.InvalidArtifact;
    const record_count = try reader.readU32();

    var records = std.ArrayListUnmanaged(LaunchTuningCacheRecord).empty;
    errdefer records.deinit(result_allocator);

    var index: u32 = 0;
    while (index < record_count) : (index += 1) {
        const record = LaunchTuningCacheRecord{
            .version = try reader.readU32(),
            .key = .{
                .backend = try reader.readEnum(gpu.BackendKind),
                .family = try reader.readEnum(gpu.DeviceFamily),
                .format = try reader.readEnum(gpu.ArtifactFormat),
                .vendor_id = try reader.readU32(),
                .has_vendor_id = try reader.readBool(),
                .device_id = try reader.readU32(),
                .has_device_id = try reader.readBool(),
                .name_fingerprint = try reader.readU64(),
                .driver_version_fingerprint = try reader.readU64(),
                .has_driver_version = try reader.readBool(),
                .subgroup_supported = try reader.readBool(),
                .subgroup_size_min = try reader.readU32(),
                .subgroup_size_max = try reader.readU32(),
                .subgroup_shuffle = try reader.readBool(),
                .subgroup_ballot = try reader.readBool(),
                .subgroup_vote = try reader.readBool(),
                .subgroup_arithmetic = try reader.readBool(),
                .subgroup_scan = try reader.readBool(),
                .max_threads = try reader.readU32(),
                .max_threads_per_dim_x = try reader.readU32(),
                .max_threads_per_dim_y = try reader.readU32(),
                .max_threads_per_dim_z = try reader.readU32(),
                .max_grid_per_dim_x = try reader.readU32(),
                .max_grid_per_dim_y = try reader.readU32(),
                .max_grid_per_dim_z = try reader.readU32(),
                .shared_memory_bytes = try reader.readU32(),
                .dtype_bits = try reader.readU64(),
                .tensor_cores = try reader.readBool(),
                .cooperative_matrix = try reader.readBool(),
                .dynamic_shared_memory = try reader.readBool(),
                .output_layout_fingerprint = try reader.readU64(),
                .input_layout_fingerprint = try reader.readU64(),
                .element_count = try reader.readU64(),
                .resource_class = try reader.readEnum(artifact_product.LaunchResourceClass),
                .element_ops_per_kib = try reader.readU64(),
                .static_bytes_complete = try reader.readBool(),
                .tile_kind = try reader.readEnum(artifact_product.LaunchTileKind),
                .tile_m = try reader.readU32(),
                .tile_n = try reader.readU32(),
                .tile_k = try reader.readU32(),
                .tile_batch = try reader.readU32(),
                .tile_has_input_dtype = try reader.readBool(),
                .tile_input_dtype = try reader.readEnum(gpu_abi.DType),
                .tile_has_output_dtype = try reader.readBool(),
                .tile_output_dtype = try reader.readEnum(gpu_abi.DType),
                .tile_input_tile_bytes = try reader.readU32(),
                .tile_output_tile_bytes = try reader.readU32(),
                .tile_scratch_memory_bytes = try reader.readU32(),
                .tile_reduction_kind = try reader.readEnum(artifact_product.LaunchReductionKind),
                .tile_reduction_rank = try reader.readU32(),
                .tile_reduction_axis = try reader.readU32(),
                .tile_reduction_extent = try reader.readU32(),
                .candidate_count = try reader.readU32(),
                .launch_resource_fingerprint = try reader.readU64(),
            },
            .selection = .{
                .kernel_id = try reader.readUsize(),
                .candidate_index = try reader.readUsize(),
                .median_ns = try reader.readU64(),
                .sample_count = try reader.readU32(),
            },
        };
        try validateLaunchTuningCacheRecord(record);
        records.append(result_allocator, record) catch return error.OutOfMemory;
    }
    try reader.expectDone();
    return records.toOwnedSlice(result_allocator) catch return error.OutOfMemory;
}
pub const LaunchTuning = struct {
    selections: []const LaunchTuningSelection = &.{},
    measurements: []const LaunchCandidateMeasurement = &.{},

    pub fn selectedCandidateIndex(
        self: LaunchTuning,
        planned: artifact_product.PlannedKernel,
    ) gpu.BackendError!usize {
        if (try selectedLaunchSelection(planned, self.selections)) |selection| {
            return selection.candidate_index;
        }
        if (try selectedLaunchMeasurement(planned, self.measurements)) |measurement| {
            return measurement.candidate_index;
        }
        return 0;
    }
};
pub fn launchTuningIsEmpty(tuning: LaunchTuning) bool {
    return tuning.selections.len == 0 and tuning.measurements.len == 0;
}

fn selectedLaunchSelection(
    planned: artifact_product.PlannedKernel,
    selections: []const LaunchTuningSelection,
) gpu.BackendError!?LaunchTuningSelection {
    var selected: ?LaunchTuningSelection = null;
    for (selections) |selection| {
        if (selection.kernel_id != planned.kernel_id) continue;
        if (selection.candidate_index >= planned.launch_resources.candidate_count) {
            return error.LaunchArgumentMismatch;
        }
        if (selected != null) return error.LaunchArgumentMismatch;
        selected = selection;
    }
    return selected;
}

pub fn selectedLaunchMeasurement(
    planned: artifact_product.PlannedKernel,
    measurements: []const LaunchCandidateMeasurement,
) gpu.BackendError!?LaunchCandidateMeasurement {
    var best: ?LaunchCandidateMeasurement = null;
    for (measurements) |measurement| {
        if (measurement.kernel_id != planned.kernel_id) continue;
        if (measurement.candidate_index >= planned.launch_resources.candidate_count) {
            return error.LaunchArgumentMismatch;
        }
        if (measurement.sample_count == 0) continue;
        if (best == null or
            measurement.median_ns < best.?.median_ns or
            (measurement.median_ns == best.?.median_ns and
                measurement.sample_count > best.?.sample_count) or
            (measurement.median_ns == best.?.median_ns and measurement.sample_count ==
                best.?.sample_count and measurement.candidate_index < best.?.candidate_index))
        {
            best = measurement;
        }
    }
    return best;
}

fn launchSelectionBeats(
    lhs: LaunchTuningSelection,
    rhs: LaunchTuningSelection,
) bool {
    if (lhs.median_ns != rhs.median_ns) return lhs.median_ns < rhs.median_ns;
    if (lhs.sample_count != rhs.sample_count) return lhs.sample_count > rhs.sample_count;
    return lhs.candidate_index < rhs.candidate_index;
}

fn validateLaunchTuningCacheRecord(record: LaunchTuningCacheRecord) gpu.BackendError!void {
    if (record.version != launch_tuning_cache_record_version) return error.InvalidArtifact;
    try validateLaunchTuningTileKey(record.key);
    if (record.key.candidate_count == 0) return error.InvalidArtifact;
    if (record.selection.sample_count == 0) return error.LaunchArgumentMismatch;
    if (record.selection.candidate_index >= @as(usize, record.key.candidate_count)) {
        return error.LaunchArgumentMismatch;
    }
}

fn validateLaunchTuningTileKey(key: LaunchTuningCacheKey) gpu.BackendError!void {
    switch (key.tile_kind) {
        .none => {
            if (key.tile_m != 0 or key.tile_n != 0 or key.tile_k != 0) return error.InvalidArtifact;
            if (key.tile_batch != 1) return error.InvalidArtifact;
            if (key.tile_has_input_dtype or key.tile_has_output_dtype) return error.InvalidArtifact;
            if (key.tile_input_tile_bytes != 0 or key.tile_output_tile_bytes != 0) {
                return error.InvalidArtifact;
            }
            if (key.tile_scratch_memory_bytes != 0) return error.InvalidArtifact;
            if (key.tile_reduction_kind != .none) return error.InvalidArtifact;
            if (key.tile_reduction_rank != 0 or key.tile_reduction_axis != 0) {
                return error.InvalidArtifact;
            }
            if (key.tile_reduction_extent != 0) return error.InvalidArtifact;
        },
        .dot_general => {
            if (key.tile_m == 0 or key.tile_n == 0 or key.tile_k == 0) return error.InvalidArtifact;
            if (key.tile_batch == 0) return error.InvalidArtifact;
            if (!key.tile_has_input_dtype or !key.tile_has_output_dtype) {
                return error.InvalidArtifact;
            }
            if (key.tile_input_tile_bytes == 0 or key.tile_output_tile_bytes == 0) {
                return error.InvalidArtifact;
            }
            if (key.tile_reduction_kind != .none) return error.InvalidArtifact;
            if (key.tile_reduction_rank != 0 or key.tile_reduction_axis != 0) {
                return error.InvalidArtifact;
            }
            if (key.tile_reduction_extent != 0) return error.InvalidArtifact;
        },
        .reduction => {
            if (key.tile_m == 0 or key.tile_n == 0) return error.InvalidArtifact;
            if (key.tile_batch != 1) return error.InvalidArtifact;
            if (!key.tile_has_input_dtype or !key.tile_has_output_dtype) {
                return error.InvalidArtifact;
            }
            if (key.tile_input_tile_bytes == 0 or key.tile_output_tile_bytes == 0) {
                return error.InvalidArtifact;
            }
            if (key.tile_reduction_kind == .none) return error.InvalidArtifact;
            if (key.tile_reduction_rank == 0 or key.tile_reduction_extent == 0) {
                return error.InvalidArtifact;
            }
            if (key.tile_reduction_axis >= key.tile_reduction_rank) return error.InvalidArtifact;
            if (key.tile_k != key.tile_reduction_axis) return error.InvalidArtifact;
            if (key.tile_n != key.tile_reduction_extent) return error.InvalidArtifact;
        },
        .elementwise_rank2 => {
            if (key.tile_m == 0 or key.tile_n == 0 or key.tile_k != 0) return error.InvalidArtifact;
            if (key.tile_batch != 1) return error.InvalidArtifact;
            if (key.tile_has_input_dtype or key.tile_has_output_dtype) return error.InvalidArtifact;
            if (key.tile_input_tile_bytes != 0 or key.tile_output_tile_bytes != 0) {
                return error.InvalidArtifact;
            }
            if (key.tile_scratch_memory_bytes != 0) return error.InvalidArtifact;
            if (key.tile_reduction_kind != .none) return error.InvalidArtifact;
            if (key.tile_reduction_rank != 0 or key.tile_reduction_axis != 0) {
                return error.InvalidArtifact;
            }
            if (key.tile_reduction_extent != 0) return error.InvalidArtifact;
        },
    }
}

fn launchTuningCacheRecordSortsBefore(
    _: void,
    lhs: LaunchTuningCacheRecord,
    rhs: LaunchTuningCacheRecord,
) bool {
    if (launchTuningCacheKeySortsBefore(lhs.key, rhs.key)) return true;
    if (launchTuningCacheKeySortsBefore(rhs.key, lhs.key)) return false;
    return launchTuningSelectionSortsBefore(lhs.selection, rhs.selection);
}

fn launchTuningCacheKeySortsBefore(
    lhs: LaunchTuningCacheKey,
    rhs: LaunchTuningCacheKey,
) bool {
    if (compareEnum(gpu.BackendKind, lhs.backend, rhs.backend)) |less| return less;
    if (compareEnum(gpu.DeviceFamily, lhs.family, rhs.family)) |less| return less;
    if (compareEnum(gpu.ArtifactFormat, lhs.format, rhs.format)) |less| return less;
    if (compareU32(lhs.vendor_id, rhs.vendor_id)) |less| return less;
    if (compareBool(lhs.has_vendor_id, rhs.has_vendor_id)) |less| return less;
    if (compareU32(lhs.device_id, rhs.device_id)) |less| return less;
    if (compareBool(lhs.has_device_id, rhs.has_device_id)) |less| return less;
    if (compareU64(lhs.name_fingerprint, rhs.name_fingerprint)) |less| return less;
    if (compareU64(lhs.driver_version_fingerprint, rhs.driver_version_fingerprint)) |less| {
        return less;
    }
    if (compareBool(lhs.has_driver_version, rhs.has_driver_version)) |less| return less;
    if (compareBool(lhs.subgroup_supported, rhs.subgroup_supported)) |less| return less;
    if (compareU32(lhs.subgroup_size_min, rhs.subgroup_size_min)) |less| return less;
    if (compareU32(lhs.subgroup_size_max, rhs.subgroup_size_max)) |less| return less;
    if (compareBool(lhs.subgroup_shuffle, rhs.subgroup_shuffle)) |less| return less;
    if (compareBool(lhs.subgroup_ballot, rhs.subgroup_ballot)) |less| return less;
    if (compareBool(lhs.subgroup_vote, rhs.subgroup_vote)) |less| return less;
    if (compareBool(lhs.subgroup_arithmetic, rhs.subgroup_arithmetic)) |less| return less;
    if (compareBool(lhs.subgroup_scan, rhs.subgroup_scan)) |less| return less;
    if (compareU32(lhs.max_threads, rhs.max_threads)) |less| return less;
    if (compareU32(lhs.max_threads_per_dim_x, rhs.max_threads_per_dim_x)) |less| return less;
    if (compareU32(lhs.max_threads_per_dim_y, rhs.max_threads_per_dim_y)) |less| return less;
    if (compareU32(lhs.max_threads_per_dim_z, rhs.max_threads_per_dim_z)) |less| return less;
    if (compareU32(lhs.max_grid_per_dim_x, rhs.max_grid_per_dim_x)) |less| return less;
    if (compareU32(lhs.max_grid_per_dim_y, rhs.max_grid_per_dim_y)) |less| return less;
    if (compareU32(lhs.max_grid_per_dim_z, rhs.max_grid_per_dim_z)) |less| return less;
    if (compareU32(lhs.shared_memory_bytes, rhs.shared_memory_bytes)) |less| return less;
    if (compareU64(lhs.dtype_bits, rhs.dtype_bits)) |less| return less;
    if (compareBool(lhs.tensor_cores, rhs.tensor_cores)) |less| return less;
    if (compareBool(lhs.cooperative_matrix, rhs.cooperative_matrix)) |less| return less;
    if (compareBool(lhs.dynamic_shared_memory, rhs.dynamic_shared_memory)) |less| return less;
    if (compareU64(lhs.output_layout_fingerprint, rhs.output_layout_fingerprint)) |less| {
        return less;
    }
    if (compareU64(lhs.input_layout_fingerprint, rhs.input_layout_fingerprint)) |less| return less;
    if (compareU64(lhs.element_count, rhs.element_count)) |less| return less;
    if (compareEnum(
        artifact_product.LaunchResourceClass,
        lhs.resource_class,
        rhs.resource_class,
    )) |less| return less;
    if (compareU64(lhs.element_ops_per_kib, rhs.element_ops_per_kib)) |less| return less;
    if (compareBool(lhs.static_bytes_complete, rhs.static_bytes_complete)) |less| return less;
    if (compareEnum(artifact_product.LaunchTileKind, lhs.tile_kind, rhs.tile_kind)) |less| {
        return less;
    }
    if (compareU32(lhs.tile_m, rhs.tile_m)) |less| return less;
    if (compareU32(lhs.tile_n, rhs.tile_n)) |less| return less;
    if (compareU32(lhs.tile_k, rhs.tile_k)) |less| return less;
    if (compareU32(lhs.tile_batch, rhs.tile_batch)) |less| return less;
    if (compareBool(lhs.tile_has_input_dtype, rhs.tile_has_input_dtype)) |less| return less;
    if (compareEnum(gpu_abi.DType, lhs.tile_input_dtype, rhs.tile_input_dtype)) |less| return less;
    if (compareBool(lhs.tile_has_output_dtype, rhs.tile_has_output_dtype)) |less| return less;
    if (compareEnum(gpu_abi.DType, lhs.tile_output_dtype, rhs.tile_output_dtype)) |less| {
        return less;
    }
    if (compareU32(lhs.tile_input_tile_bytes, rhs.tile_input_tile_bytes)) |less| return less;
    if (compareU32(lhs.tile_output_tile_bytes, rhs.tile_output_tile_bytes)) |less| return less;
    if (compareU32(lhs.tile_scratch_memory_bytes, rhs.tile_scratch_memory_bytes)) |less| {
        return less;
    }
    if (compareEnum(
        artifact_product.LaunchReductionKind,
        lhs.tile_reduction_kind,
        rhs.tile_reduction_kind,
    )) |less| return less;
    if (compareU32(lhs.tile_reduction_rank, rhs.tile_reduction_rank)) |less| return less;
    if (compareU32(lhs.tile_reduction_axis, rhs.tile_reduction_axis)) |less| return less;
    if (compareU32(lhs.tile_reduction_extent, rhs.tile_reduction_extent)) |less| return less;
    if (compareU32(lhs.candidate_count, rhs.candidate_count)) |less| return less;
    if (compareU64(lhs.launch_resource_fingerprint, rhs.launch_resource_fingerprint)) |less| {
        return less;
    }
    return false;
}

fn launchTuningSelectionSortsBefore(
    lhs: LaunchTuningSelection,
    rhs: LaunchTuningSelection,
) bool {
    if (compareUsize(lhs.kernel_id, rhs.kernel_id)) |less| return less;
    if (compareUsize(lhs.candidate_index, rhs.candidate_index)) |less| return less;
    if (compareU64(lhs.median_ns, rhs.median_ns)) |less| return less;
    if (compareU32(lhs.sample_count, rhs.sample_count)) |less| return less;
    return false;
}

fn compareEnum(comptime T: type, lhs: T, rhs: T) ?bool {
    return compareU64(@backingInt(lhs), @backingInt(rhs));
}

fn compareBool(lhs: bool, rhs: bool) ?bool {
    if (lhs == rhs) return null;
    return !lhs and rhs;
}

fn compareU32(lhs: u32, rhs: u32) ?bool {
    if (lhs == rhs) return null;
    return lhs < rhs;
}

fn compareUsize(lhs: usize, rhs: usize) ?bool {
    if (lhs == rhs) return null;
    return lhs < rhs;
}

fn compareU64(lhs: u64, rhs: u64) ?bool {
    if (lhs == rhs) return null;
    return lhs < rhs;
}

fn bytesFingerprint(domain: []const u8, bytes: []const u8) choir.product.incremental.Fingerprint {
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes(domain);
    builder.updateBytes(bytes);
    return builder.finish();
}
