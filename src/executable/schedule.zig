const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const artifact_product = @import("../artifact/model/root.zig");
const preparation = @import("../preparation/root.zig");

const GeneratedScanSchedule = preparation.target.GeneratedScanSchedule;
const GeneratedRowPipelineSchedule = preparation.target.GeneratedRowPipelineSchedule;

const matrix_tuning = @import("../kernel/library/root.zig").tuning;
const matrix_product_family_schedule_tuning_product_name =
    matrix_tuning.matrix_product_family_schedule_tuning_product_name;
const matrix_product_family_schedule_tuning_record_version =
    matrix_tuning.matrix_product_family_schedule_tuning_record_version;
const matrix_product_family_schedule_tuning_max_candidates =
    matrix_tuning.matrix_product_family_schedule_tuning_max_candidates;
const MatrixProductFamilyScheduleThreads = matrix_tuning.MatrixProductFamilyScheduleThreads;
const MatrixProductFamilyScheduleTuningProblem =
    matrix_tuning.MatrixProductFamilyScheduleTuningProblem;
const MatrixProductFamilyScheduleTuningKey = matrix_tuning.MatrixProductFamilyScheduleTuningKey;
const MatrixProductFamilyScheduleTuningSelection =
    matrix_tuning.MatrixProductFamilyScheduleTuningSelection;
const MatrixProductFamilyScheduleTuningRecord =
    matrix_tuning.MatrixProductFamilyScheduleTuningRecord;

pub const matrix_product_family_schedule_tuning_artifact_magic: u32 = 0x41515433;
pub const matrix_product_family_schedule_tuning_artifact_version: u32 = 1;

pub const MatrixProductFamilyScheduleTuningCache = struct {
    selections: std.AutoHashMap(MatrixProductFamilyScheduleTuningKey, MatrixProductFamilyScheduleTuningSelection),

    pub fn init(allocator: std.mem.Allocator) MatrixProductFamilyScheduleTuningCache {
        return .{
            .selections = std.AutoHashMap(MatrixProductFamilyScheduleTuningKey, MatrixProductFamilyScheduleTuningSelection).init(allocator),
        };
    }

    pub fn deinit(self: *MatrixProductFamilyScheduleTuningCache) void {
        self.selections.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const MatrixProductFamilyScheduleTuningCache) usize {
        return self.selections.count();
    }

    pub fn exportRecords(
        self: *const MatrixProductFamilyScheduleTuningCache,
        result_allocator: std.mem.Allocator,
    ) gpu.BackendError![]MatrixProductFamilyScheduleTuningRecord {
        const records = result_allocator.alloc(MatrixProductFamilyScheduleTuningRecord, self.selections.count()) catch return error.OutOfMemory;
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
        std.mem.sort(MatrixProductFamilyScheduleTuningRecord, records, {}, matrixProductFamilyScheduleTuningRecordSortsBefore);
        return records;
    }

    pub fn importRecords(
        self: *MatrixProductFamilyScheduleTuningCache,
        records: []const MatrixProductFamilyScheduleTuningRecord,
    ) gpu.BackendError!void {
        for (records) |record| try validateMatrixProductFamilyScheduleTuningRecord(record);
        for (records) |record| {
            if (self.selections.getPtr(record.key)) |existing| {
                if (matrixProductFamilyScheduleSelectionBeats(record.selection, existing.*)) existing.* = record.selection;
                continue;
            }
            self.selections.put(record.key, record.selection) catch return error.OutOfMemory;
        }
    }

    pub fn recordSelection(
        self: *MatrixProductFamilyScheduleTuningCache,
        caps: gpu.BackendCapabilities,
        problem: MatrixProductFamilyScheduleTuningProblem,
        selection: MatrixProductFamilyScheduleTuningSelection,
    ) gpu.BackendError!void {
        try validateMatrixProductFamilyScheduleTuningSelection(selection);
        if (!matrixProductFamilyScheduleCandidatesContain(problem.candidates, selection.threads)) return error.LaunchArgumentMismatch;
        const key = try MatrixProductFamilyScheduleTuningKey.init(caps.identity, problem);
        if (self.selections.getPtr(key)) |existing| {
            if (matrixProductFamilyScheduleSelectionBeats(selection, existing.*)) existing.* = selection;
            return;
        }
        self.selections.put(key, selection) catch return error.OutOfMemory;
    }

    pub fn selectionForProblem(
        self: *const MatrixProductFamilyScheduleTuningCache,
        caps: gpu.BackendCapabilities,
        problem: MatrixProductFamilyScheduleTuningProblem,
    ) gpu.BackendError!?MatrixProductFamilyScheduleTuningSelection {
        const key = try MatrixProductFamilyScheduleTuningKey.init(caps.identity, problem);
        return self.selections.get(key);
    }
};

pub fn encodeMatrixProductFamilyScheduleTuningArtifact(
    result_allocator: std.mem.Allocator,
    records: []const MatrixProductFamilyScheduleTuningRecord,
) gpu.BackendError![]u8 {
    if (records.len > std.math.maxInt(u32)) return error.InvalidArtifact;
    var writer = artifact_product.wire.ByteWriter{};
    errdefer writer.deinit(result_allocator);

    try writer.writeU32(result_allocator, matrix_product_family_schedule_tuning_artifact_magic);
    try writer.writeU32(result_allocator, matrix_product_family_schedule_tuning_artifact_version);
    try writer.writeU32(result_allocator, @intCast(records.len));
    for (records) |record| {
        try validateMatrixProductFamilyScheduleTuningRecord(record);
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
        try writer.writeU64(result_allocator, record.key.m);
        try writer.writeU64(result_allocator, record.key.n);
        try writer.writeU64(result_allocator, record.key.k);
        try writer.writeEnum(result_allocator, gpu_abi.DType, record.key.dtype);
        try writer.writeEnum(result_allocator, gpu_abi.DType, record.key.accumulation_dtype);
        try writer.writeU32(result_allocator, record.key.family_version);
        try writer.writeU32(result_allocator, record.key.candidate_count);
        try writer.writeU64(result_allocator, record.key.candidate_set_fingerprint);
        try writer.writeU32(result_allocator, record.selection.threads.x);
        try writer.writeU32(result_allocator, record.selection.threads.y);
        try writer.writeU64(result_allocator, record.selection.winner_median_ns);
        try writer.writeU64(result_allocator, record.selection.runner_up_median_ns);
        try writer.writeU32(result_allocator, record.selection.sample_count);
    }

    return writer.toOwnedSlice(result_allocator) catch return error.OutOfMemory;
}

pub fn decodeMatrixProductFamilyScheduleTuningArtifact(
    result_allocator: std.mem.Allocator,
    bytes: []const u8,
) gpu.BackendError![]MatrixProductFamilyScheduleTuningRecord {
    var reader = artifact_product.wire.ByteReader{ .bytes = bytes };
    if ((try reader.readU32()) != matrix_product_family_schedule_tuning_artifact_magic) return error.InvalidArtifact;
    if ((try reader.readU32()) != matrix_product_family_schedule_tuning_artifact_version) return error.InvalidArtifact;
    const record_count = try reader.readU32();

    var records = std.ArrayListUnmanaged(MatrixProductFamilyScheduleTuningRecord).empty;
    errdefer records.deinit(result_allocator);

    var index: u32 = 0;
    while (index < record_count) : (index += 1) {
        const record = MatrixProductFamilyScheduleTuningRecord{
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
                .m = try reader.readU64(),
                .n = try reader.readU64(),
                .k = try reader.readU64(),
                .dtype = try reader.readEnum(gpu_abi.DType),
                .accumulation_dtype = try reader.readEnum(gpu_abi.DType),
                .family_version = try reader.readU32(),
                .candidate_count = try reader.readU32(),
                .candidate_set_fingerprint = try reader.readU64(),
            },
            .selection = .{
                .threads = .{
                    .x = try reader.readU32(),
                    .y = try reader.readU32(),
                },
                .winner_median_ns = try reader.readU64(),
                .runner_up_median_ns = try reader.readU64(),
                .sample_count = try reader.readU32(),
            },
        };
        try validateMatrixProductFamilyScheduleTuningRecord(record);
        records.append(result_allocator, record) catch return error.OutOfMemory;
    }
    try reader.expectDone();
    return records.toOwnedSlice(result_allocator) catch return error.OutOfMemory;
}

pub fn matrixProductFamilyScheduleTuningArtifactFingerprint(bytes: []const u8) choir.product.incremental.Fingerprint {
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes(matrix_product_family_schedule_tuning_product_name);
    builder.updateU32(matrix_product_family_schedule_tuning_artifact_version);
    builder.updateBytes(bytes);
    return builder.finish();
}

fn validateMatrixProductFamilyScheduleTuningRecord(record: MatrixProductFamilyScheduleTuningRecord) gpu.BackendError!void {
    if (record.version != matrix_product_family_schedule_tuning_record_version) return error.InvalidArtifact;
    if (record.key.m == 0 or record.key.n == 0 or record.key.k == 0) return error.InvalidArtifact;
    if (record.key.family_version == 0) return error.InvalidArtifact;
    if (record.key.candidate_count < 2) return error.InvalidArtifact;
    if (record.key.candidate_count > matrix_product_family_schedule_tuning_max_candidates) return error.InvalidArtifact;
    if (record.key.candidate_set_fingerprint == 0) return error.InvalidArtifact;
    try validateMatrixProductFamilyScheduleTuningSelection(record.selection);
}

fn validateMatrixProductFamilyScheduleTuningSelection(selection: MatrixProductFamilyScheduleTuningSelection) gpu.BackendError!void {
    try validateMatrixProductFamilyScheduleThreads(selection.threads);
    if (selection.winner_median_ns == 0) return error.InvalidArtifact;
    if (selection.runner_up_median_ns == 0) return error.InvalidArtifact;
    if (selection.runner_up_median_ns < selection.winner_median_ns) return error.InvalidArtifact;
    if (selection.sample_count == 0) return error.InvalidArtifact;
}

fn validateMatrixProductFamilyScheduleThreads(threads: MatrixProductFamilyScheduleThreads) gpu.BackendError!void {
    if (threads.x == 0 or threads.y == 0) return error.InvalidArtifact;
}

fn matrixProductFamilyScheduleCandidatesContain(
    candidates: []const MatrixProductFamilyScheduleThreads,
    threads: MatrixProductFamilyScheduleThreads,
) bool {
    for (candidates) |candidate| {
        if (candidate.eql(threads)) return true;
    }
    return false;
}

fn matrixProductFamilyScheduleSelectionBeats(
    lhs: MatrixProductFamilyScheduleTuningSelection,
    rhs: MatrixProductFamilyScheduleTuningSelection,
) bool {
    if (lhs.winner_median_ns != rhs.winner_median_ns) return lhs.winner_median_ns < rhs.winner_median_ns;
    if (lhs.runner_up_median_ns != rhs.runner_up_median_ns) return lhs.runner_up_median_ns > rhs.runner_up_median_ns;
    if (lhs.sample_count != rhs.sample_count) return lhs.sample_count > rhs.sample_count;
    return MatrixProductFamilyScheduleThreads.lessThan({}, lhs.threads, rhs.threads);
}

fn matrixProductFamilyScheduleTuningRecordSortsBefore(
    _: void,
    lhs: MatrixProductFamilyScheduleTuningRecord,
    rhs: MatrixProductFamilyScheduleTuningRecord,
) bool {
    if (matrixProductFamilyScheduleTuningKeySortsBefore(lhs.key, rhs.key)) return true;
    if (matrixProductFamilyScheduleTuningKeySortsBefore(rhs.key, lhs.key)) return false;
    return matrixProductFamilyScheduleTuningSelectionSortsBefore(lhs.selection, rhs.selection);
}

fn matrixProductFamilyScheduleTuningKeySortsBefore(
    lhs: MatrixProductFamilyScheduleTuningKey,
    rhs: MatrixProductFamilyScheduleTuningKey,
) bool {
    if (compareEnum(gpu.BackendKind, lhs.backend, rhs.backend)) |less| return less;
    if (compareEnum(gpu.DeviceFamily, lhs.family, rhs.family)) |less| return less;
    if (compareEnum(gpu.ArtifactFormat, lhs.format, rhs.format)) |less| return less;
    if (compareU32(lhs.vendor_id, rhs.vendor_id)) |less| return less;
    if (compareBool(lhs.has_vendor_id, rhs.has_vendor_id)) |less| return less;
    if (compareU32(lhs.device_id, rhs.device_id)) |less| return less;
    if (compareBool(lhs.has_device_id, rhs.has_device_id)) |less| return less;
    if (compareU64(lhs.name_fingerprint, rhs.name_fingerprint)) |less| return less;
    if (compareU64(lhs.driver_version_fingerprint, rhs.driver_version_fingerprint)) |less| return less;
    if (compareBool(lhs.has_driver_version, rhs.has_driver_version)) |less| return less;
    if (compareU64(lhs.m, rhs.m)) |less| return less;
    if (compareU64(lhs.n, rhs.n)) |less| return less;
    if (compareU64(lhs.k, rhs.k)) |less| return less;
    if (compareEnum(gpu_abi.DType, lhs.dtype, rhs.dtype)) |less| return less;
    if (compareEnum(gpu_abi.DType, lhs.accumulation_dtype, rhs.accumulation_dtype)) |less| return less;
    if (compareU32(lhs.family_version, rhs.family_version)) |less| return less;
    if (compareU32(lhs.candidate_count, rhs.candidate_count)) |less| return less;
    if (compareU64(lhs.candidate_set_fingerprint, rhs.candidate_set_fingerprint)) |less| return less;
    return false;
}

fn matrixProductFamilyScheduleTuningSelectionSortsBefore(
    lhs: MatrixProductFamilyScheduleTuningSelection,
    rhs: MatrixProductFamilyScheduleTuningSelection,
) bool {
    if (MatrixProductFamilyScheduleThreads.lessThan({}, lhs.threads, rhs.threads)) return true;
    if (MatrixProductFamilyScheduleThreads.lessThan({}, rhs.threads, lhs.threads)) return false;
    if (compareU64(lhs.winner_median_ns, rhs.winner_median_ns)) |less| return less;
    if (compareU64(lhs.runner_up_median_ns, rhs.runner_up_median_ns)) |less| return less;
    if (compareU32(lhs.sample_count, rhs.sample_count)) |less| return less;
    return false;
}

pub const generated_scan_schedule_tuning_product_name = "accy.exec.generated_scan_schedule_tuning";
pub const generated_scan_schedule_tuning_record_version: u32 = 1;
pub const generated_scan_schedule_tuning_artifact_magic: u32 = 0x41515434;
pub const generated_scan_schedule_tuning_artifact_version: u32 = 1;
pub const generated_scan_schedule_tuning_max_candidates: usize = 4;

pub const GeneratedScanScheduleTuningProblem = struct {
    format: gpu.ArtifactFormat,
    total: u64,
    dtype: gpu_abi.DType = .f32,
    schedule_version: u32,
    candidates: []const GeneratedScanSchedule,
};

/// The key records the identity a measured scan schedule choice is stored
/// under: backend, device family, artifact format, vendor and device ids when
/// known, fingerprints of the device name and driver version, the element
/// count, the element type, the schedule version, and the candidate set. A
/// tuning run stores its winning scan schedule under this key, and a later
/// compile rebuilds the key to find it. A scan schedule is a thread count and
/// an item count per thread. `init` returns `error.InvalidArtifact` for a zero
/// element count, a zero schedule version, or a candidate set outside two to
/// four distinct valid schedules. `eql` compares every field, so a different
/// driver version gives a different key. A compile reading a tuning file skips
/// any record whose key does not match the key it rebuilds for the current
/// device and problem, so a stale or foreign record changes nothing and the
/// compile proceeds as if no record existed.
pub const GeneratedScanScheduleTuningKey = struct {
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
    total: u64,
    dtype: gpu_abi.DType,
    schedule_version: u32,
    candidate_count: u32,
    candidate_set_fingerprint: u64,

    pub fn init(
        caps: gpu.BackendCapabilities,
        problem: GeneratedScanScheduleTuningProblem,
    ) gpu.BackendError!GeneratedScanScheduleTuningKey {
        if (problem.total == 0) return error.InvalidArtifact;
        if (problem.schedule_version == 0) return error.InvalidArtifact;
        const candidate_set_fingerprint = try generatedScanScheduleCandidateSetFingerprint(problem.candidates);
        return .{
            .backend = caps.identity.backend,
            .family = caps.identity.family,
            .format = problem.format,
            .vendor_id = caps.identity.vendor_id orelse 0,
            .has_vendor_id = caps.identity.vendor_id != null,
            .device_id = caps.identity.device_id orelse 0,
            .has_device_id = caps.identity.device_id != null,
            .name_fingerprint = bytesFingerprint(generated_scan_schedule_tuning_product_name ++ ".device.name", caps.identity.name),
            .driver_version_fingerprint = if (caps.identity.driver_version) |version| bytesFingerprint(generated_scan_schedule_tuning_product_name ++ ".driver.version", version) else 0,
            .has_driver_version = caps.identity.driver_version != null,
            .total = problem.total,
            .dtype = problem.dtype,
            .schedule_version = problem.schedule_version,
            .candidate_count = @intCast(problem.candidates.len),
            .candidate_set_fingerprint = candidate_set_fingerprint,
        };
    }

    pub fn eql(self: GeneratedScanScheduleTuningKey, other: GeneratedScanScheduleTuningKey) bool {
        return self.backend == other.backend and
            self.family == other.family and
            self.format == other.format and
            self.vendor_id == other.vendor_id and
            self.has_vendor_id == other.has_vendor_id and
            self.device_id == other.device_id and
            self.has_device_id == other.has_device_id and
            self.name_fingerprint == other.name_fingerprint and
            self.driver_version_fingerprint == other.driver_version_fingerprint and
            self.has_driver_version == other.has_driver_version and
            self.total == other.total and
            self.dtype == other.dtype and
            self.schedule_version == other.schedule_version and
            self.candidate_count == other.candidate_count and
            self.candidate_set_fingerprint == other.candidate_set_fingerprint;
    }
};

pub const GeneratedScanScheduleTuningSelection = struct {
    schedule: GeneratedScanSchedule,
    winner_median_ns: u64,
    runner_up_median_ns: u64,
    sample_count: u32,
};

pub const GeneratedScanScheduleTuningRecord = struct {
    version: u32 = generated_scan_schedule_tuning_record_version,
    key: GeneratedScanScheduleTuningKey,
    selection: GeneratedScanScheduleTuningSelection,
};

pub const GeneratedScanScheduleTuningCache = struct {
    selections: std.AutoHashMap(GeneratedScanScheduleTuningKey, GeneratedScanScheduleTuningSelection),

    pub fn init(allocator: std.mem.Allocator) GeneratedScanScheduleTuningCache {
        return .{
            .selections = std.AutoHashMap(GeneratedScanScheduleTuningKey, GeneratedScanScheduleTuningSelection).init(allocator),
        };
    }

    pub fn deinit(self: *GeneratedScanScheduleTuningCache) void {
        self.selections.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const GeneratedScanScheduleTuningCache) usize {
        return self.selections.count();
    }

    pub fn exportRecords(
        self: *const GeneratedScanScheduleTuningCache,
        result_allocator: std.mem.Allocator,
    ) gpu.BackendError![]GeneratedScanScheduleTuningRecord {
        const records = result_allocator.alloc(GeneratedScanScheduleTuningRecord, self.selections.count()) catch return error.OutOfMemory;
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
        std.mem.sort(GeneratedScanScheduleTuningRecord, records, {}, generatedScanScheduleTuningRecordSortsBefore);
        return records;
    }

    pub fn importRecords(
        self: *GeneratedScanScheduleTuningCache,
        records: []const GeneratedScanScheduleTuningRecord,
    ) gpu.BackendError!void {
        for (records) |record| try validateGeneratedScanScheduleTuningRecord(record);
        for (records) |record| {
            if (self.selections.getPtr(record.key)) |existing| {
                if (generatedScanScheduleSelectionBeats(record.selection, existing.*)) existing.* = record.selection;
                continue;
            }
            self.selections.put(record.key, record.selection) catch return error.OutOfMemory;
        }
    }

    pub fn recordSelection(
        self: *GeneratedScanScheduleTuningCache,
        caps: gpu.BackendCapabilities,
        problem: GeneratedScanScheduleTuningProblem,
        selection: GeneratedScanScheduleTuningSelection,
    ) gpu.BackendError!void {
        try validateGeneratedScanScheduleTuningSelection(selection);
        if (!generatedScanScheduleCandidatesContain(problem.candidates, selection.schedule)) return error.LaunchArgumentMismatch;
        const key = try GeneratedScanScheduleTuningKey.init(caps, problem);
        if (self.selections.getPtr(key)) |existing| {
            if (generatedScanScheduleSelectionBeats(selection, existing.*)) existing.* = selection;
            return;
        }
        self.selections.put(key, selection) catch return error.OutOfMemory;
    }

    pub fn selectionForProblem(
        self: *const GeneratedScanScheduleTuningCache,
        caps: gpu.BackendCapabilities,
        problem: GeneratedScanScheduleTuningProblem,
    ) gpu.BackendError!?GeneratedScanScheduleTuningSelection {
        const key = try GeneratedScanScheduleTuningKey.init(caps, problem);
        return self.selections.get(key);
    }
};

pub fn generatedScanScheduleCandidateSetFingerprint(
    candidates: []const GeneratedScanSchedule,
) gpu.BackendError!choir.product.incremental.Fingerprint {
    const set = try sortedGeneratedScanScheduleCandidates(candidates);
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes(generated_scan_schedule_tuning_product_name);
    builder.updateU32(@intCast(set.count));
    for (set.slice()) |candidate| {
        builder.updateU32(candidate.threads);
        builder.updateU32(candidate.items);
    }
    return builder.finish();
}

pub fn encodeGeneratedScanScheduleTuningArtifact(
    result_allocator: std.mem.Allocator,
    records: []const GeneratedScanScheduleTuningRecord,
) gpu.BackendError![]u8 {
    if (records.len > std.math.maxInt(u32)) return error.InvalidArtifact;
    var writer = artifact_product.wire.ByteWriter{};
    errdefer writer.deinit(result_allocator);

    try writer.writeU32(result_allocator, generated_scan_schedule_tuning_artifact_magic);
    try writer.writeU32(result_allocator, generated_scan_schedule_tuning_artifact_version);
    try writer.writeU32(result_allocator, @intCast(records.len));
    for (records) |record| {
        try validateGeneratedScanScheduleTuningRecord(record);
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
        try writer.writeU64(result_allocator, record.key.total);
        try writer.writeEnum(result_allocator, gpu_abi.DType, record.key.dtype);
        try writer.writeU32(result_allocator, record.key.schedule_version);
        try writer.writeU32(result_allocator, record.key.candidate_count);
        try writer.writeU64(result_allocator, record.key.candidate_set_fingerprint);
        try writer.writeU32(result_allocator, record.selection.schedule.threads);
        try writer.writeU32(result_allocator, record.selection.schedule.items);
        try writer.writeU64(result_allocator, record.selection.winner_median_ns);
        try writer.writeU64(result_allocator, record.selection.runner_up_median_ns);
        try writer.writeU32(result_allocator, record.selection.sample_count);
    }

    return writer.toOwnedSlice(result_allocator) catch return error.OutOfMemory;
}

pub fn decodeGeneratedScanScheduleTuningArtifact(
    result_allocator: std.mem.Allocator,
    bytes: []const u8,
) gpu.BackendError![]GeneratedScanScheduleTuningRecord {
    var reader = artifact_product.wire.ByteReader{ .bytes = bytes };
    if ((try reader.readU32()) != generated_scan_schedule_tuning_artifact_magic) return error.InvalidArtifact;
    if ((try reader.readU32()) != generated_scan_schedule_tuning_artifact_version) return error.InvalidArtifact;
    const record_count = try reader.readU32();

    var records = std.ArrayListUnmanaged(GeneratedScanScheduleTuningRecord).empty;
    errdefer records.deinit(result_allocator);

    var index: u32 = 0;
    while (index < record_count) : (index += 1) {
        const record = GeneratedScanScheduleTuningRecord{
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
                .total = try reader.readU64(),
                .dtype = try reader.readEnum(gpu_abi.DType),
                .schedule_version = try reader.readU32(),
                .candidate_count = try reader.readU32(),
                .candidate_set_fingerprint = try reader.readU64(),
            },
            .selection = .{
                .schedule = .{
                    .threads = try reader.readU32(),
                    .items = try reader.readU32(),
                },
                .winner_median_ns = try reader.readU64(),
                .runner_up_median_ns = try reader.readU64(),
                .sample_count = try reader.readU32(),
            },
        };
        try validateGeneratedScanScheduleTuningRecord(record);
        records.append(result_allocator, record) catch return error.OutOfMemory;
    }
    try reader.expectDone();
    return records.toOwnedSlice(result_allocator) catch return error.OutOfMemory;
}

pub fn generatedScanScheduleTuningArtifactFingerprint(bytes: []const u8) choir.product.incremental.Fingerprint {
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes(generated_scan_schedule_tuning_product_name);
    builder.updateU32(generated_scan_schedule_tuning_artifact_version);
    builder.updateBytes(bytes);
    return builder.finish();
}

pub fn generatedScanScheduleTuningArtifactProductStamp(bytes: []const u8) choir.product.incremental.ProductStamp {
    return choir.product.incremental.productStamp(generated_scan_schedule_tuning_product_name, generatedScanScheduleTuningArtifactFingerprint(bytes));
}

fn validateGeneratedScanScheduleTuningRecord(record: GeneratedScanScheduleTuningRecord) gpu.BackendError!void {
    if (record.version != generated_scan_schedule_tuning_record_version) return error.InvalidArtifact;
    if (record.key.total == 0) return error.InvalidArtifact;
    if (record.key.schedule_version == 0) return error.InvalidArtifact;
    if (record.key.candidate_count < 2) return error.InvalidArtifact;
    if (record.key.candidate_count > generated_scan_schedule_tuning_max_candidates) return error.InvalidArtifact;
    if (record.key.candidate_set_fingerprint == 0) return error.InvalidArtifact;
    try validateGeneratedScanScheduleTuningSelection(record.selection);
}

fn validateGeneratedScanScheduleTuningSelection(selection: GeneratedScanScheduleTuningSelection) gpu.BackendError!void {
    try validateGeneratedScanSchedule(selection.schedule);
    if (selection.winner_median_ns == 0) return error.InvalidArtifact;
    if (selection.runner_up_median_ns == 0) return error.InvalidArtifact;
    if (selection.runner_up_median_ns < selection.winner_median_ns) return error.InvalidArtifact;
    if (selection.sample_count == 0) return error.InvalidArtifact;
}

fn validateGeneratedScanSchedule(schedule: GeneratedScanSchedule) gpu.BackendError!void {
    if (schedule.threads == 0 or schedule.items == 0) return error.InvalidArtifact;
}

const GeneratedScanScheduleCandidateSet = struct {
    count: usize = 0,
    items: [generated_scan_schedule_tuning_max_candidates]GeneratedScanSchedule = @as([generated_scan_schedule_tuning_max_candidates]GeneratedScanSchedule, @splat(.{ .threads = 1, .items = 1 })),

    fn slice(self: *const GeneratedScanScheduleCandidateSet) []const GeneratedScanSchedule {
        return self.items[0..self.count];
    }
};

fn sortedGeneratedScanScheduleCandidates(
    candidates: []const GeneratedScanSchedule,
) gpu.BackendError!GeneratedScanScheduleCandidateSet {
    if (candidates.len < 2) return error.InvalidArtifact;
    if (candidates.len > generated_scan_schedule_tuning_max_candidates) return error.InvalidArtifact;
    var set = GeneratedScanScheduleCandidateSet{ .count = candidates.len };
    @memcpy(set.items[0..candidates.len], candidates);
    for (set.slice()) |candidate| try validateGeneratedScanSchedule(candidate);
    std.mem.sort(GeneratedScanSchedule, set.items[0..set.count], {}, generatedScanScheduleSortsBefore);
    for (set.slice()[1..], 1..) |candidate, index| {
        if (candidate.eql(set.items[index - 1])) return error.InvalidArtifact;
    }
    return set;
}

fn generatedScanScheduleCandidatesContain(
    candidates: []const GeneratedScanSchedule,
    schedule: GeneratedScanSchedule,
) bool {
    for (candidates) |candidate| {
        if (candidate.eql(schedule)) return true;
    }
    return false;
}

fn generatedScanScheduleSelectionBeats(
    lhs: GeneratedScanScheduleTuningSelection,
    rhs: GeneratedScanScheduleTuningSelection,
) bool {
    if (lhs.winner_median_ns != rhs.winner_median_ns) return lhs.winner_median_ns < rhs.winner_median_ns;
    if (lhs.runner_up_median_ns != rhs.runner_up_median_ns) return lhs.runner_up_median_ns > rhs.runner_up_median_ns;
    if (lhs.sample_count != rhs.sample_count) return lhs.sample_count > rhs.sample_count;
    return generatedScanScheduleSortsBefore({}, lhs.schedule, rhs.schedule);
}

fn generatedScanScheduleTuningRecordSortsBefore(
    _: void,
    lhs: GeneratedScanScheduleTuningRecord,
    rhs: GeneratedScanScheduleTuningRecord,
) bool {
    if (generatedScanScheduleTuningKeySortsBefore(lhs.key, rhs.key)) return true;
    if (generatedScanScheduleTuningKeySortsBefore(rhs.key, lhs.key)) return false;
    return generatedScanScheduleTuningSelectionSortsBefore(lhs.selection, rhs.selection);
}

fn generatedScanScheduleTuningKeySortsBefore(
    lhs: GeneratedScanScheduleTuningKey,
    rhs: GeneratedScanScheduleTuningKey,
) bool {
    if (compareEnum(gpu.BackendKind, lhs.backend, rhs.backend)) |less| return less;
    if (compareEnum(gpu.DeviceFamily, lhs.family, rhs.family)) |less| return less;
    if (compareEnum(gpu.ArtifactFormat, lhs.format, rhs.format)) |less| return less;
    if (compareU32(lhs.vendor_id, rhs.vendor_id)) |less| return less;
    if (compareBool(lhs.has_vendor_id, rhs.has_vendor_id)) |less| return less;
    if (compareU32(lhs.device_id, rhs.device_id)) |less| return less;
    if (compareBool(lhs.has_device_id, rhs.has_device_id)) |less| return less;
    if (compareU64(lhs.name_fingerprint, rhs.name_fingerprint)) |less| return less;
    if (compareU64(lhs.driver_version_fingerprint, rhs.driver_version_fingerprint)) |less| return less;
    if (compareBool(lhs.has_driver_version, rhs.has_driver_version)) |less| return less;
    if (compareU64(lhs.total, rhs.total)) |less| return less;
    if (compareEnum(gpu_abi.DType, lhs.dtype, rhs.dtype)) |less| return less;
    if (compareU32(lhs.schedule_version, rhs.schedule_version)) |less| return less;
    if (compareU32(lhs.candidate_count, rhs.candidate_count)) |less| return less;
    if (compareU64(lhs.candidate_set_fingerprint, rhs.candidate_set_fingerprint)) |less| return less;
    return false;
}

fn generatedScanScheduleTuningSelectionSortsBefore(
    lhs: GeneratedScanScheduleTuningSelection,
    rhs: GeneratedScanScheduleTuningSelection,
) bool {
    if (generatedScanScheduleSortsBefore({}, lhs.schedule, rhs.schedule)) return true;
    if (generatedScanScheduleSortsBefore({}, rhs.schedule, lhs.schedule)) return false;
    if (compareU64(lhs.winner_median_ns, rhs.winner_median_ns)) |less| return less;
    if (compareU64(lhs.runner_up_median_ns, rhs.runner_up_median_ns)) |less| return less;
    if (compareU32(lhs.sample_count, rhs.sample_count)) |less| return less;
    return false;
}

fn generatedScanScheduleSortsBefore(
    _: void,
    lhs: GeneratedScanSchedule,
    rhs: GeneratedScanSchedule,
) bool {
    if (compareU32(lhs.threads, rhs.threads)) |less| return less;
    if (compareU32(lhs.items, rhs.items)) |less| return less;
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

pub const generated_row_pipeline_schedule_tuning_product_name = "accy.exec.generated_row_pipeline_schedule_tuning";
pub const generated_row_pipeline_schedule_tuning_record_version: u32 = 1;
pub const generated_row_pipeline_schedule_tuning_artifact_magic: u32 = 0x41515435;
pub const generated_row_pipeline_schedule_tuning_artifact_version: u32 = 1;
pub const generated_row_pipeline_schedule_tuning_max_candidates: usize = 4;

pub const GeneratedRowPipelineScheduleTuningProblem = struct {
    format: gpu.ArtifactFormat,
    rows: u64,
    cols: u64,
    dtype: gpu_abi.DType = .f32,
    schedule_version: u32,
    candidates: []const GeneratedRowPipelineSchedule,
};

/// The key records the identity a measured row-pipeline schedule choice is
/// stored under: the same device, format, element type, schedule version and
/// candidate-set fields as the scan key, with the row and column counts as the
/// problem size. A tuning run stores its winning row-pipeline schedule under
/// this key, and a later compile rebuilds the key to find it. A row-pipeline
/// schedule is a thread count. `init` returns `error.InvalidArtifact` for zero
/// rows, zero columns, a zero schedule version, or an invalid candidate set. A
/// compile reading a tuning file skips any record whose key does not match the
/// key it rebuilds, so a stale or foreign record changes nothing.
pub const GeneratedRowPipelineScheduleTuningKey = struct {
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
    rows: u64,
    cols: u64,
    dtype: gpu_abi.DType,
    schedule_version: u32,
    candidate_count: u32,
    candidate_set_fingerprint: u64,

    pub fn init(
        caps: gpu.BackendCapabilities,
        problem: GeneratedRowPipelineScheduleTuningProblem,
    ) gpu.BackendError!GeneratedRowPipelineScheduleTuningKey {
        if (problem.rows == 0 or problem.cols == 0) return error.InvalidArtifact;
        if (problem.schedule_version == 0) return error.InvalidArtifact;
        const candidate_set_fingerprint = try generatedRowPipelineScheduleCandidateSetFingerprint(problem.candidates);
        return .{
            .backend = caps.identity.backend,
            .family = caps.identity.family,
            .format = problem.format,
            .vendor_id = caps.identity.vendor_id orelse 0,
            .has_vendor_id = caps.identity.vendor_id != null,
            .device_id = caps.identity.device_id orelse 0,
            .has_device_id = caps.identity.device_id != null,
            .name_fingerprint = bytesFingerprint(generated_row_pipeline_schedule_tuning_product_name ++ ".device.name", caps.identity.name),
            .driver_version_fingerprint = if (caps.identity.driver_version) |version| bytesFingerprint(generated_row_pipeline_schedule_tuning_product_name ++ ".driver.version", version) else 0,
            .has_driver_version = caps.identity.driver_version != null,
            .rows = problem.rows,
            .cols = problem.cols,
            .dtype = problem.dtype,
            .schedule_version = problem.schedule_version,
            .candidate_count = @intCast(problem.candidates.len),
            .candidate_set_fingerprint = candidate_set_fingerprint,
        };
    }

    pub fn eql(self: GeneratedRowPipelineScheduleTuningKey, other: GeneratedRowPipelineScheduleTuningKey) bool {
        return self.backend == other.backend and
            self.family == other.family and
            self.format == other.format and
            self.vendor_id == other.vendor_id and
            self.has_vendor_id == other.has_vendor_id and
            self.device_id == other.device_id and
            self.has_device_id == other.has_device_id and
            self.name_fingerprint == other.name_fingerprint and
            self.driver_version_fingerprint == other.driver_version_fingerprint and
            self.has_driver_version == other.has_driver_version and
            self.rows == other.rows and
            self.cols == other.cols and
            self.dtype == other.dtype and
            self.schedule_version == other.schedule_version and
            self.candidate_count == other.candidate_count and
            self.candidate_set_fingerprint == other.candidate_set_fingerprint;
    }
};

pub const GeneratedRowPipelineScheduleTuningSelection = struct {
    schedule: GeneratedRowPipelineSchedule,
    winner_median_ns: u64,
    runner_up_median_ns: u64,
    sample_count: u32,
};

pub const GeneratedRowPipelineScheduleTuningRecord = struct {
    version: u32 = generated_row_pipeline_schedule_tuning_record_version,
    key: GeneratedRowPipelineScheduleTuningKey,
    selection: GeneratedRowPipelineScheduleTuningSelection,
};

pub const GeneratedRowPipelineScheduleTuningCache = struct {
    selections: std.AutoHashMap(GeneratedRowPipelineScheduleTuningKey, GeneratedRowPipelineScheduleTuningSelection),

    pub fn init(allocator: std.mem.Allocator) GeneratedRowPipelineScheduleTuningCache {
        return .{
            .selections = std.AutoHashMap(GeneratedRowPipelineScheduleTuningKey, GeneratedRowPipelineScheduleTuningSelection).init(allocator),
        };
    }

    pub fn deinit(self: *GeneratedRowPipelineScheduleTuningCache) void {
        self.selections.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const GeneratedRowPipelineScheduleTuningCache) usize {
        return self.selections.count();
    }

    pub fn exportRecords(
        self: *const GeneratedRowPipelineScheduleTuningCache,
        result_allocator: std.mem.Allocator,
    ) gpu.BackendError![]GeneratedRowPipelineScheduleTuningRecord {
        const records = result_allocator.alloc(GeneratedRowPipelineScheduleTuningRecord, self.selections.count()) catch return error.OutOfMemory;
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
        std.mem.sort(GeneratedRowPipelineScheduleTuningRecord, records, {}, generatedRowPipelineScheduleTuningRecordSortsBefore);
        return records;
    }

    pub fn importRecords(
        self: *GeneratedRowPipelineScheduleTuningCache,
        records: []const GeneratedRowPipelineScheduleTuningRecord,
    ) gpu.BackendError!void {
        for (records) |record| try validateGeneratedRowPipelineScheduleTuningRecord(record);
        for (records) |record| {
            if (self.selections.getPtr(record.key)) |existing| {
                if (generatedRowPipelineScheduleSelectionBeats(record.selection, existing.*)) existing.* = record.selection;
                continue;
            }
            self.selections.put(record.key, record.selection) catch return error.OutOfMemory;
        }
    }

    pub fn recordSelection(
        self: *GeneratedRowPipelineScheduleTuningCache,
        caps: gpu.BackendCapabilities,
        problem: GeneratedRowPipelineScheduleTuningProblem,
        selection: GeneratedRowPipelineScheduleTuningSelection,
    ) gpu.BackendError!void {
        try validateGeneratedRowPipelineScheduleTuningSelection(selection);
        if (!generatedRowPipelineScheduleCandidatesContain(problem.candidates, selection.schedule)) return error.LaunchArgumentMismatch;
        const key = try GeneratedRowPipelineScheduleTuningKey.init(caps, problem);
        if (self.selections.getPtr(key)) |existing| {
            if (generatedRowPipelineScheduleSelectionBeats(selection, existing.*)) existing.* = selection;
            return;
        }
        self.selections.put(key, selection) catch return error.OutOfMemory;
    }

    pub fn selectionForProblem(
        self: *const GeneratedRowPipelineScheduleTuningCache,
        caps: gpu.BackendCapabilities,
        problem: GeneratedRowPipelineScheduleTuningProblem,
    ) gpu.BackendError!?GeneratedRowPipelineScheduleTuningSelection {
        const key = try GeneratedRowPipelineScheduleTuningKey.init(caps, problem);
        return self.selections.get(key);
    }
};

pub fn generatedRowPipelineScheduleCandidateSetFingerprint(
    candidates: []const GeneratedRowPipelineSchedule,
) gpu.BackendError!choir.product.incremental.Fingerprint {
    const set = try sortedGeneratedRowPipelineScheduleCandidates(candidates);
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes(generated_row_pipeline_schedule_tuning_product_name);
    builder.updateU32(@intCast(set.count));
    for (set.slice()) |candidate| {
        builder.updateU32(candidate.threads);
    }
    return builder.finish();
}

pub fn encodeGeneratedRowPipelineScheduleTuningArtifact(
    result_allocator: std.mem.Allocator,
    records: []const GeneratedRowPipelineScheduleTuningRecord,
) gpu.BackendError![]u8 {
    if (records.len > std.math.maxInt(u32)) return error.InvalidArtifact;
    var writer = artifact_product.wire.ByteWriter{};
    errdefer writer.deinit(result_allocator);

    try writer.writeU32(result_allocator, generated_row_pipeline_schedule_tuning_artifact_magic);
    try writer.writeU32(result_allocator, generated_row_pipeline_schedule_tuning_artifact_version);
    try writer.writeU32(result_allocator, @intCast(records.len));
    for (records) |record| {
        try validateGeneratedRowPipelineScheduleTuningRecord(record);
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
        try writer.writeU64(result_allocator, record.key.rows);
        try writer.writeU64(result_allocator, record.key.cols);
        try writer.writeEnum(result_allocator, gpu_abi.DType, record.key.dtype);
        try writer.writeU32(result_allocator, record.key.schedule_version);
        try writer.writeU32(result_allocator, record.key.candidate_count);
        try writer.writeU64(result_allocator, record.key.candidate_set_fingerprint);
        try writer.writeU32(result_allocator, record.selection.schedule.threads);
        try writer.writeU64(result_allocator, record.selection.winner_median_ns);
        try writer.writeU64(result_allocator, record.selection.runner_up_median_ns);
        try writer.writeU32(result_allocator, record.selection.sample_count);
    }

    return writer.toOwnedSlice(result_allocator) catch return error.OutOfMemory;
}

pub fn decodeGeneratedRowPipelineScheduleTuningArtifact(
    result_allocator: std.mem.Allocator,
    bytes: []const u8,
) gpu.BackendError![]GeneratedRowPipelineScheduleTuningRecord {
    var reader = artifact_product.wire.ByteReader{ .bytes = bytes };
    if ((try reader.readU32()) != generated_row_pipeline_schedule_tuning_artifact_magic) return error.InvalidArtifact;
    if ((try reader.readU32()) != generated_row_pipeline_schedule_tuning_artifact_version) return error.InvalidArtifact;
    const record_count = try reader.readU32();

    var records = std.ArrayListUnmanaged(GeneratedRowPipelineScheduleTuningRecord).empty;
    errdefer records.deinit(result_allocator);

    var index: u32 = 0;
    while (index < record_count) : (index += 1) {
        const record = GeneratedRowPipelineScheduleTuningRecord{
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
                .rows = try reader.readU64(),
                .cols = try reader.readU64(),
                .dtype = try reader.readEnum(gpu_abi.DType),
                .schedule_version = try reader.readU32(),
                .candidate_count = try reader.readU32(),
                .candidate_set_fingerprint = try reader.readU64(),
            },
            .selection = .{
                .schedule = .{
                    .threads = try reader.readU32(),
                },
                .winner_median_ns = try reader.readU64(),
                .runner_up_median_ns = try reader.readU64(),
                .sample_count = try reader.readU32(),
            },
        };
        try validateGeneratedRowPipelineScheduleTuningRecord(record);
        records.append(result_allocator, record) catch return error.OutOfMemory;
    }
    try reader.expectDone();
    return records.toOwnedSlice(result_allocator) catch return error.OutOfMemory;
}

pub fn generatedRowPipelineScheduleTuningArtifactFingerprint(bytes: []const u8) choir.product.incremental.Fingerprint {
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes(generated_row_pipeline_schedule_tuning_product_name);
    builder.updateU32(generated_row_pipeline_schedule_tuning_artifact_version);
    builder.updateBytes(bytes);
    return builder.finish();
}

pub fn generatedRowPipelineScheduleTuningArtifactProductStamp(bytes: []const u8) choir.product.incremental.ProductStamp {
    return choir.product.incremental.productStamp(generated_row_pipeline_schedule_tuning_product_name, generatedRowPipelineScheduleTuningArtifactFingerprint(bytes));
}

fn validateGeneratedRowPipelineScheduleTuningRecord(record: GeneratedRowPipelineScheduleTuningRecord) gpu.BackendError!void {
    if (record.version != generated_row_pipeline_schedule_tuning_record_version) return error.InvalidArtifact;
    if (record.key.rows == 0 or record.key.cols == 0) return error.InvalidArtifact;
    if (record.key.schedule_version == 0) return error.InvalidArtifact;
    if (record.key.candidate_count < 2) return error.InvalidArtifact;
    if (record.key.candidate_count > generated_row_pipeline_schedule_tuning_max_candidates) return error.InvalidArtifact;
    if (record.key.candidate_set_fingerprint == 0) return error.InvalidArtifact;
    try validateGeneratedRowPipelineScheduleTuningSelection(record.selection);
}

fn validateGeneratedRowPipelineScheduleTuningSelection(selection: GeneratedRowPipelineScheduleTuningSelection) gpu.BackendError!void {
    try validateGeneratedRowPipelineSchedule(selection.schedule);
    if (selection.winner_median_ns == 0) return error.InvalidArtifact;
    if (selection.runner_up_median_ns == 0) return error.InvalidArtifact;
    if (selection.runner_up_median_ns < selection.winner_median_ns) return error.InvalidArtifact;
    if (selection.sample_count == 0) return error.InvalidArtifact;
}

fn validateGeneratedRowPipelineSchedule(schedule: GeneratedRowPipelineSchedule) gpu.BackendError!void {
    if (schedule.threads == 0) return error.InvalidArtifact;
}

const GeneratedRowPipelineScheduleCandidateSet = struct {
    count: usize = 0,
    items: [generated_row_pipeline_schedule_tuning_max_candidates]GeneratedRowPipelineSchedule = @as([generated_row_pipeline_schedule_tuning_max_candidates]GeneratedRowPipelineSchedule, @splat(.{ .threads = 1 })),

    fn slice(self: *const GeneratedRowPipelineScheduleCandidateSet) []const GeneratedRowPipelineSchedule {
        return self.items[0..self.count];
    }
};

fn sortedGeneratedRowPipelineScheduleCandidates(
    candidates: []const GeneratedRowPipelineSchedule,
) gpu.BackendError!GeneratedRowPipelineScheduleCandidateSet {
    if (candidates.len < 2) return error.InvalidArtifact;
    if (candidates.len > generated_row_pipeline_schedule_tuning_max_candidates) return error.InvalidArtifact;
    var set = GeneratedRowPipelineScheduleCandidateSet{ .count = candidates.len };
    @memcpy(set.items[0..candidates.len], candidates);
    for (set.slice()) |candidate| try validateGeneratedRowPipelineSchedule(candidate);
    std.mem.sort(GeneratedRowPipelineSchedule, set.items[0..set.count], {}, generatedRowPipelineScheduleSortsBefore);
    for (set.slice()[1..], 1..) |candidate, index| {
        if (candidate.eql(set.items[index - 1])) return error.InvalidArtifact;
    }
    return set;
}

fn generatedRowPipelineScheduleCandidatesContain(
    candidates: []const GeneratedRowPipelineSchedule,
    schedule: GeneratedRowPipelineSchedule,
) bool {
    for (candidates) |candidate| {
        if (candidate.eql(schedule)) return true;
    }
    return false;
}

fn generatedRowPipelineScheduleSelectionBeats(
    lhs: GeneratedRowPipelineScheduleTuningSelection,
    rhs: GeneratedRowPipelineScheduleTuningSelection,
) bool {
    if (lhs.winner_median_ns != rhs.winner_median_ns) return lhs.winner_median_ns < rhs.winner_median_ns;
    if (lhs.runner_up_median_ns != rhs.runner_up_median_ns) return lhs.runner_up_median_ns > rhs.runner_up_median_ns;
    if (lhs.sample_count != rhs.sample_count) return lhs.sample_count > rhs.sample_count;
    return generatedRowPipelineScheduleSortsBefore({}, lhs.schedule, rhs.schedule);
}

fn generatedRowPipelineScheduleTuningRecordSortsBefore(
    _: void,
    lhs: GeneratedRowPipelineScheduleTuningRecord,
    rhs: GeneratedRowPipelineScheduleTuningRecord,
) bool {
    if (generatedRowPipelineScheduleTuningKeySortsBefore(lhs.key, rhs.key)) return true;
    if (generatedRowPipelineScheduleTuningKeySortsBefore(rhs.key, lhs.key)) return false;
    return generatedRowPipelineScheduleTuningSelectionSortsBefore(lhs.selection, rhs.selection);
}

fn generatedRowPipelineScheduleTuningKeySortsBefore(
    lhs: GeneratedRowPipelineScheduleTuningKey,
    rhs: GeneratedRowPipelineScheduleTuningKey,
) bool {
    if (compareEnum(gpu.BackendKind, lhs.backend, rhs.backend)) |less| return less;
    if (compareEnum(gpu.DeviceFamily, lhs.family, rhs.family)) |less| return less;
    if (compareEnum(gpu.ArtifactFormat, lhs.format, rhs.format)) |less| return less;
    if (compareU32(lhs.vendor_id, rhs.vendor_id)) |less| return less;
    if (compareBool(lhs.has_vendor_id, rhs.has_vendor_id)) |less| return less;
    if (compareU32(lhs.device_id, rhs.device_id)) |less| return less;
    if (compareBool(lhs.has_device_id, rhs.has_device_id)) |less| return less;
    if (compareU64(lhs.name_fingerprint, rhs.name_fingerprint)) |less| return less;
    if (compareU64(lhs.driver_version_fingerprint, rhs.driver_version_fingerprint)) |less| return less;
    if (compareBool(lhs.has_driver_version, rhs.has_driver_version)) |less| return less;
    if (compareU64(lhs.rows, rhs.rows)) |less| return less;
    if (compareU64(lhs.cols, rhs.cols)) |less| return less;
    if (compareEnum(gpu_abi.DType, lhs.dtype, rhs.dtype)) |less| return less;
    if (compareU32(lhs.schedule_version, rhs.schedule_version)) |less| return less;
    if (compareU32(lhs.candidate_count, rhs.candidate_count)) |less| return less;
    if (compareU64(lhs.candidate_set_fingerprint, rhs.candidate_set_fingerprint)) |less| return less;
    return false;
}

fn generatedRowPipelineScheduleTuningSelectionSortsBefore(
    lhs: GeneratedRowPipelineScheduleTuningSelection,
    rhs: GeneratedRowPipelineScheduleTuningSelection,
) bool {
    if (generatedRowPipelineScheduleSortsBefore({}, lhs.schedule, rhs.schedule)) return true;
    if (generatedRowPipelineScheduleSortsBefore({}, rhs.schedule, lhs.schedule)) return false;
    if (compareU64(lhs.winner_median_ns, rhs.winner_median_ns)) |less| return less;
    if (compareU64(lhs.runner_up_median_ns, rhs.runner_up_median_ns)) |less| return less;
    if (compareU32(lhs.sample_count, rhs.sample_count)) |less| return less;
    return false;
}

fn generatedRowPipelineScheduleSortsBefore(
    _: void,
    lhs: GeneratedRowPipelineSchedule,
    rhs: GeneratedRowPipelineSchedule,
) bool {
    if (compareU32(lhs.threads, rhs.threads)) |less| return less;
    return false;
}

const testing = std.testing;

fn matrixProductFamilyScheduleTestCapabilities(device_id: u32) gpu.BackendCapabilities {
    return .{
        .identity = .{
            .backend = .cuda,
            .family = .nvidia_cuda,
            .name = "test-cuda-device",
            .vendor_id = 0x10de,
            .device_id = device_id,
            .driver_version = "550.54",
        },
        .artifact_formats = gpu.ArtifactFormatSet.init(&.{.cuda_ptx}),
    };
}

fn matrixProductFamilyScheduleTestProblem(candidates: []const MatrixProductFamilyScheduleThreads) MatrixProductFamilyScheduleTuningProblem {
    return .{
        .format = .cuda_ptx,
        .m = 17,
        .n = 17,
        .k = 13,
        .dtype = .f32,
        .accumulation_dtype = .f32,
        .family_version = 1,
        .candidates = candidates,
    };
}

fn expectMatrixProductFamilyScheduleSelection(
    expected: MatrixProductFamilyScheduleTuningSelection,
    actual: MatrixProductFamilyScheduleTuningSelection,
) !void {
    try testing.expect(expected.threads.eql(actual.threads));
    try testing.expectEqual(expected.winner_median_ns, actual.winner_median_ns);
    try testing.expectEqual(expected.runner_up_median_ns, actual.runner_up_median_ns);
    try testing.expectEqual(expected.sample_count, actual.sample_count);
}

test "matrix product family schedule tuning cache records device keyed selections" {
    const allocator = testing.allocator;
    const candidates = [_]MatrixProductFamilyScheduleThreads{
        .{ .x = 17, .y = 9 },
        .{ .x = 16, .y = 16 },
        .{ .x = 8, .y = 8 },
    };
    const caps = matrixProductFamilyScheduleTestCapabilities(0x2684);
    const problem = matrixProductFamilyScheduleTestProblem(candidates[0..]);

    var cache = MatrixProductFamilyScheduleTuningCache.init(allocator);
    defer cache.deinit();

    const selected = MatrixProductFamilyScheduleTuningSelection{
        .threads = candidates[0],
        .winner_median_ns = 1000,
        .runner_up_median_ns = 1300,
        .sample_count = 30,
    };
    try cache.recordSelection(caps, problem, selected);
    try testing.expectEqual(@as(usize, 1), cache.count());

    const hit = (try cache.selectionForProblem(caps, problem)) orelse return error.TestExpectedTuningRecord;
    try expectMatrixProductFamilyScheduleSelection(selected, hit);

    try cache.recordSelection(caps, problem, .{
        .threads = candidates[1],
        .winner_median_ns = 1200,
        .runner_up_median_ns = 1400,
        .sample_count = 40,
    });
    try expectMatrixProductFamilyScheduleSelection(selected, (try cache.selectionForProblem(caps, problem)).?);

    const faster = MatrixProductFamilyScheduleTuningSelection{
        .threads = candidates[1],
        .winner_median_ns = 900,
        .runner_up_median_ns = 1300,
        .sample_count = 20,
    };
    try cache.recordSelection(caps, problem, faster);
    try expectMatrixProductFamilyScheduleSelection(faster, (try cache.selectionForProblem(caps, problem)).?);

    try testing.expectEqual(@as(?MatrixProductFamilyScheduleTuningSelection, null), try cache.selectionForProblem(matrixProductFamilyScheduleTestCapabilities(0x1b80), problem));

    var other_problem = problem;
    other_problem.m = 32;
    try testing.expectEqual(@as(?MatrixProductFamilyScheduleTuningSelection, null), try cache.selectionForProblem(caps, other_problem));

    try testing.expectError(error.LaunchArgumentMismatch, cache.recordSelection(caps, problem, .{
        .threads = .{ .x = 3, .y = 3 },
        .winner_median_ns = 850,
        .runner_up_median_ns = 1300,
        .sample_count = 30,
    }));

    const records = try cache.exportRecords(allocator);
    defer allocator.free(records);
    try testing.expectEqual(@as(usize, 1), records.len);
    try expectMatrixProductFamilyScheduleSelection(faster, records[0].selection);

    var imported = MatrixProductFamilyScheduleTuningCache.init(allocator);
    defer imported.deinit();
    try imported.importRecords(records);
    try expectMatrixProductFamilyScheduleSelection(faster, (try imported.selectionForProblem(caps, problem)).?);
}

test "matrix product family schedule tuning artifact round trips through the wire" {
    const allocator = testing.allocator;
    const candidates = [_]MatrixProductFamilyScheduleThreads{
        .{ .x = 17, .y = 9 },
        .{ .x = 16, .y = 16 },
        .{ .x = 8, .y = 8 },
    };
    const caps = matrixProductFamilyScheduleTestCapabilities(0x2684);
    const problem = matrixProductFamilyScheduleTestProblem(candidates[0..]);
    const other_problem = MatrixProductFamilyScheduleTuningProblem{
        .format = .cuda_ptx,
        .m = 64,
        .n = 32,
        .k = 16,
        .dtype = .f16,
        .accumulation_dtype = .f32,
        .family_version = 1,
        .candidates = candidates[0..],
    };
    const records = [_]MatrixProductFamilyScheduleTuningRecord{
        .{
            .key = try MatrixProductFamilyScheduleTuningKey.init(caps.identity, problem),
            .selection = .{
                .threads = candidates[0],
                .winner_median_ns = 1000,
                .runner_up_median_ns = 1300,
                .sample_count = 30,
            },
        },
        .{
            .key = try MatrixProductFamilyScheduleTuningKey.init(caps.identity, other_problem),
            .selection = .{
                .threads = candidates[1],
                .winner_median_ns = 700,
                .runner_up_median_ns = 900,
                .sample_count = 30,
            },
        },
    };

    const encoded = try encodeMatrixProductFamilyScheduleTuningArtifact(allocator, records[0..]);
    defer allocator.free(encoded);

    const decoded = try decodeMatrixProductFamilyScheduleTuningArtifact(allocator, encoded);
    defer allocator.free(decoded);

    try testing.expectEqual(records.len, decoded.len);
    for (records, decoded) |want, got| {
        try testing.expect(want.key.eql(got.key));
        try expectMatrixProductFamilyScheduleSelection(want.selection, got.selection);
    }

    const encoded_again = try encodeMatrixProductFamilyScheduleTuningArtifact(allocator, decoded);
    defer allocator.free(encoded_again);
    try testing.expectEqualSlices(u8, encoded, encoded_again);
}

test "matrix product family schedule tuning artifact rejects invalid records" {
    const allocator = testing.allocator;
    const candidates = [_]MatrixProductFamilyScheduleThreads{
        .{ .x = 17, .y = 9 },
        .{ .x = 16, .y = 16 },
    };
    const caps = matrixProductFamilyScheduleTestCapabilities(0x2684);
    const problem = matrixProductFamilyScheduleTestProblem(candidates[0..]);
    const valid = MatrixProductFamilyScheduleTuningRecord{
        .key = try MatrixProductFamilyScheduleTuningKey.init(caps.identity, problem),
        .selection = .{
            .threads = candidates[0],
            .winner_median_ns = 1000,
            .runner_up_median_ns = 1300,
            .sample_count = 30,
        },
    };
    const encoded = try encodeMatrixProductFamilyScheduleTuningArtifact(allocator, &.{valid});
    defer allocator.free(encoded);

    try testing.expectError(error.InvalidArtifact, decodeMatrixProductFamilyScheduleTuningArtifact(allocator, encoded[0 .. encoded.len - 1]));

    var bad_count = valid;
    bad_count.key.candidate_count = 1;
    try testing.expectError(error.InvalidArtifact, encodeMatrixProductFamilyScheduleTuningArtifact(allocator, &.{bad_count}));

    var bad_selection = valid;
    bad_selection.selection.runner_up_median_ns = 999;
    try testing.expectError(error.InvalidArtifact, encodeMatrixProductFamilyScheduleTuningArtifact(allocator, &.{bad_selection}));

    var extra = std.ArrayListUnmanaged(u8).empty;
    defer extra.deinit(allocator);
    try extra.appendSlice(allocator, encoded);
    try extra.append(allocator, 0);
    try testing.expectError(error.InvalidArtifact, decodeMatrixProductFamilyScheduleTuningArtifact(allocator, extra.items));
}

test "matrix product family schedule tuning artifact fingerprint tracks bytes" {
    const allocator = testing.allocator;
    const candidates = [_]MatrixProductFamilyScheduleThreads{
        .{ .x = 17, .y = 9 },
        .{ .x = 16, .y = 16 },
    };
    const caps = matrixProductFamilyScheduleTestCapabilities(0x2684);
    const problem = matrixProductFamilyScheduleTestProblem(candidates[0..]);
    const record = MatrixProductFamilyScheduleTuningRecord{
        .key = try MatrixProductFamilyScheduleTuningKey.init(caps.identity, problem),
        .selection = .{
            .threads = candidates[0],
            .winner_median_ns = 1000,
            .runner_up_median_ns = 1300,
            .sample_count = 30,
        },
    };
    const encoded = try encodeMatrixProductFamilyScheduleTuningArtifact(allocator, &.{record});
    defer allocator.free(encoded);

    const fingerprint = matrixProductFamilyScheduleTuningArtifactFingerprint(encoded);
    try testing.expectEqual(fingerprint, matrixProductFamilyScheduleTuningArtifactFingerprint(encoded));

    const mutated = try allocator.dupe(u8, encoded);
    defer allocator.free(mutated);
    mutated[mutated.len - 1] +%= 1;
    try testing.expect(matrixProductFamilyScheduleTuningArtifactFingerprint(mutated) != fingerprint);
}

fn generatedScanScheduleTestProblem(candidates: []const GeneratedScanSchedule) GeneratedScanScheduleTuningProblem {
    return .{
        .format = .cuda_ptx,
        .total = 16777216,
        .dtype = .f32,
        .schedule_version = 1,
        .candidates = candidates,
    };
}

fn expectGeneratedScanScheduleSelection(
    want: GeneratedScanScheduleTuningSelection,
    got: GeneratedScanScheduleTuningSelection,
) !void {
    try testing.expect(want.schedule.eql(got.schedule));
    try testing.expectEqual(want.winner_median_ns, got.winner_median_ns);
    try testing.expectEqual(want.runner_up_median_ns, got.runner_up_median_ns);
    try testing.expectEqual(want.sample_count, got.sample_count);
}

test "generated scan schedule candidate set fingerprint canonicalizes candidates" {
    const forward = [_]GeneratedScanSchedule{
        .{ .threads = 512, .items = 16 },
        .{ .threads = 256, .items = 16 },
    };
    const reversed = [_]GeneratedScanSchedule{
        .{ .threads = 256, .items = 16 },
        .{ .threads = 512, .items = 16 },
    };
    const forward_fingerprint = try generatedScanScheduleCandidateSetFingerprint(forward[0..]);
    try testing.expectEqual(forward_fingerprint, try generatedScanScheduleCandidateSetFingerprint(reversed[0..]));

    const widened = [_]GeneratedScanSchedule{
        .{ .threads = 512, .items = 16 },
        .{ .threads = 256, .items = 16 },
        .{ .threads = 128, .items = 16 },
    };
    try testing.expect(forward_fingerprint != try generatedScanScheduleCandidateSetFingerprint(widened[0..]));

    const duplicated = [_]GeneratedScanSchedule{
        .{ .threads = 512, .items = 16 },
        .{ .threads = 512, .items = 16 },
    };
    try testing.expectError(error.InvalidArtifact, generatedScanScheduleCandidateSetFingerprint(duplicated[0..]));
    try testing.expectError(error.InvalidArtifact, generatedScanScheduleCandidateSetFingerprint(forward[0..1]));
}

test "generated scan schedule tuning cache records device keyed selections" {
    const allocator = testing.allocator;
    const candidates = [_]GeneratedScanSchedule{
        .{ .threads = 512, .items = 16 },
        .{ .threads = 256, .items = 16 },
    };
    const caps = matrixProductFamilyScheduleTestCapabilities(0x2684);
    const problem = generatedScanScheduleTestProblem(candidates[0..]);

    var cache = GeneratedScanScheduleTuningCache.init(allocator);
    defer cache.deinit();

    const selected = GeneratedScanScheduleTuningSelection{
        .schedule = candidates[1],
        .winner_median_ns = 160000,
        .runner_up_median_ns = 164000,
        .sample_count = 10,
    };
    try cache.recordSelection(caps, problem, selected);
    try testing.expectEqual(@as(usize, 1), cache.count());

    const hit = (try cache.selectionForProblem(caps, problem)) orelse return error.TestExpectedTuningRecord;
    try expectGeneratedScanScheduleSelection(selected, hit);

    try cache.recordSelection(caps, problem, .{
        .schedule = candidates[0],
        .winner_median_ns = 170000,
        .runner_up_median_ns = 175000,
        .sample_count = 10,
    });
    try expectGeneratedScanScheduleSelection(selected, (try cache.selectionForProblem(caps, problem)).?);

    const faster = GeneratedScanScheduleTuningSelection{
        .schedule = candidates[0],
        .winner_median_ns = 150000,
        .runner_up_median_ns = 160000,
        .sample_count = 10,
    };
    try cache.recordSelection(caps, problem, faster);
    try expectGeneratedScanScheduleSelection(faster, (try cache.selectionForProblem(caps, problem)).?);

    try testing.expectEqual(@as(?GeneratedScanScheduleTuningSelection, null), try cache.selectionForProblem(matrixProductFamilyScheduleTestCapabilities(0x1b80), problem));

    var other_problem = problem;
    other_problem.total = 8388608;
    try testing.expectEqual(@as(?GeneratedScanScheduleTuningSelection, null), try cache.selectionForProblem(caps, other_problem));

    try testing.expectError(error.LaunchArgumentMismatch, cache.recordSelection(caps, problem, .{
        .schedule = .{ .threads = 128, .items = 16 },
        .winner_median_ns = 140000,
        .runner_up_median_ns = 150000,
        .sample_count = 10,
    }));

    const records = try cache.exportRecords(allocator);
    defer allocator.free(records);
    try testing.expectEqual(@as(usize, 1), records.len);
    try expectGeneratedScanScheduleSelection(faster, records[0].selection);

    var imported = GeneratedScanScheduleTuningCache.init(allocator);
    defer imported.deinit();
    try imported.importRecords(records);
    try expectGeneratedScanScheduleSelection(faster, (try imported.selectionForProblem(caps, problem)).?);
}

test "generated scan schedule tuning artifact round trips through the wire" {
    const allocator = testing.allocator;
    const candidates = [_]GeneratedScanSchedule{
        .{ .threads = 512, .items = 16 },
        .{ .threads = 256, .items = 16 },
    };
    const caps = matrixProductFamilyScheduleTestCapabilities(0x2684);
    const problem = generatedScanScheduleTestProblem(candidates[0..]);
    var other_problem = problem;
    other_problem.total = 8388608;
    const records = [_]GeneratedScanScheduleTuningRecord{
        .{
            .key = try GeneratedScanScheduleTuningKey.init(caps, problem),
            .selection = .{
                .schedule = candidates[0],
                .winner_median_ns = 160000,
                .runner_up_median_ns = 164000,
                .sample_count = 10,
            },
        },
        .{
            .key = try GeneratedScanScheduleTuningKey.init(caps, other_problem),
            .selection = .{
                .schedule = candidates[1],
                .winner_median_ns = 80000,
                .runner_up_median_ns = 90000,
                .sample_count = 10,
            },
        },
    };

    const encoded = try encodeGeneratedScanScheduleTuningArtifact(allocator, records[0..]);
    defer allocator.free(encoded);

    const decoded = try decodeGeneratedScanScheduleTuningArtifact(allocator, encoded);
    defer allocator.free(decoded);

    try testing.expectEqual(records.len, decoded.len);
    for (records, decoded) |want, got| {
        try testing.expect(want.key.eql(got.key));
        try expectGeneratedScanScheduleSelection(want.selection, got.selection);
    }

    const encoded_again = try encodeGeneratedScanScheduleTuningArtifact(allocator, decoded);
    defer allocator.free(encoded_again);
    try testing.expectEqualSlices(u8, encoded, encoded_again);
}

test "generated scan schedule tuning artifact rejects invalid records" {
    const allocator = testing.allocator;
    const candidates = [_]GeneratedScanSchedule{
        .{ .threads = 512, .items = 16 },
        .{ .threads = 256, .items = 16 },
    };
    const caps = matrixProductFamilyScheduleTestCapabilities(0x2684);
    const problem = generatedScanScheduleTestProblem(candidates[0..]);

    var stale = GeneratedScanScheduleTuningRecord{
        .key = try GeneratedScanScheduleTuningKey.init(caps, problem),
        .selection = .{
            .schedule = candidates[0],
            .winner_median_ns = 160000,
            .runner_up_median_ns = 164000,
            .sample_count = 10,
        },
    };
    stale.version = generated_scan_schedule_tuning_record_version + 1;
    try testing.expectError(error.InvalidArtifact, encodeGeneratedScanScheduleTuningArtifact(allocator, &.{stale}));

    var inverted = stale;
    inverted.version = generated_scan_schedule_tuning_record_version;
    inverted.selection.runner_up_median_ns = inverted.selection.winner_median_ns - 1;
    try testing.expectError(error.InvalidArtifact, encodeGeneratedScanScheduleTuningArtifact(allocator, &.{inverted}));

    try testing.expectError(error.InvalidArtifact, decodeGeneratedScanScheduleTuningArtifact(allocator, &.{ 1, 2, 3 }));
}

fn generatedRowPipelineScheduleTestProblem(candidates: []const GeneratedRowPipelineSchedule) GeneratedRowPipelineScheduleTuningProblem {
    return .{
        .format = .cuda_ptx,
        .rows = 4096,
        .cols = 4096,
        .dtype = .f32,
        .schedule_version = 1,
        .candidates = candidates,
    };
}

fn expectGeneratedRowPipelineScheduleSelection(
    want: GeneratedRowPipelineScheduleTuningSelection,
    got: GeneratedRowPipelineScheduleTuningSelection,
) !void {
    try testing.expect(want.schedule.eql(got.schedule));
    try testing.expectEqual(want.winner_median_ns, got.winner_median_ns);
    try testing.expectEqual(want.runner_up_median_ns, got.runner_up_median_ns);
    try testing.expectEqual(want.sample_count, got.sample_count);
}

test "generated row pipeline schedule tuning cache records device keyed selections" {
    const allocator = testing.allocator;
    const candidates = [_]GeneratedRowPipelineSchedule{
        .{ .threads = 256 },
        .{ .threads = 512 },
        .{ .threads = 128 },
    };
    const caps = matrixProductFamilyScheduleTestCapabilities(0x2684);
    const problem = generatedRowPipelineScheduleTestProblem(candidates[0..]);

    var cache = GeneratedRowPipelineScheduleTuningCache.init(allocator);
    defer cache.deinit();

    const selected = GeneratedRowPipelineScheduleTuningSelection{
        .schedule = candidates[1],
        .winner_median_ns = 145000,
        .runner_up_median_ns = 150000,
        .sample_count = 10,
    };
    try cache.recordSelection(caps, problem, selected);
    try expectGeneratedRowPipelineScheduleSelection(selected, (try cache.selectionForProblem(caps, problem)).?);

    try testing.expectEqual(@as(?GeneratedRowPipelineScheduleTuningSelection, null), try cache.selectionForProblem(matrixProductFamilyScheduleTestCapabilities(0x1b80), problem));

    var other_problem = problem;
    other_problem.cols = 2048;
    try testing.expectEqual(@as(?GeneratedRowPipelineScheduleTuningSelection, null), try cache.selectionForProblem(caps, other_problem));

    try testing.expectError(error.LaunchArgumentMismatch, cache.recordSelection(caps, problem, .{
        .schedule = .{ .threads = 64 },
        .winner_median_ns = 140000,
        .runner_up_median_ns = 150000,
        .sample_count = 10,
    }));

    const records = try cache.exportRecords(allocator);
    defer allocator.free(records);
    try testing.expectEqual(@as(usize, 1), records.len);

    var imported = GeneratedRowPipelineScheduleTuningCache.init(allocator);
    defer imported.deinit();
    try imported.importRecords(records);
    try expectGeneratedRowPipelineScheduleSelection(selected, (try imported.selectionForProblem(caps, problem)).?);
}

test "generated row pipeline schedule tuning artifact round trips through the wire" {
    const allocator = testing.allocator;
    const candidates = [_]GeneratedRowPipelineSchedule{
        .{ .threads = 256 },
        .{ .threads = 512 },
    };
    const caps = matrixProductFamilyScheduleTestCapabilities(0x2684);
    const problem = generatedRowPipelineScheduleTestProblem(candidates[0..]);
    var other_problem = problem;
    other_problem.rows = 8;
    other_problem.cols = 2048;
    const records = [_]GeneratedRowPipelineScheduleTuningRecord{
        .{
            .key = try GeneratedRowPipelineScheduleTuningKey.init(caps, problem),
            .selection = .{
                .schedule = candidates[1],
                .winner_median_ns = 145000,
                .runner_up_median_ns = 150000,
                .sample_count = 10,
            },
        },
        .{
            .key = try GeneratedRowPipelineScheduleTuningKey.init(caps, other_problem),
            .selection = .{
                .schedule = candidates[0],
                .winner_median_ns = 9000,
                .runner_up_median_ns = 9500,
                .sample_count = 10,
            },
        },
    };

    const encoded = try encodeGeneratedRowPipelineScheduleTuningArtifact(allocator, records[0..]);
    defer allocator.free(encoded);

    const decoded = try decodeGeneratedRowPipelineScheduleTuningArtifact(allocator, encoded);
    defer allocator.free(decoded);

    try testing.expectEqual(records.len, decoded.len);
    for (records, decoded) |want, got| {
        try testing.expect(want.key.eql(got.key));
        try expectGeneratedRowPipelineScheduleSelection(want.selection, got.selection);
    }

    const encoded_again = try encodeGeneratedRowPipelineScheduleTuningArtifact(allocator, decoded);
    defer allocator.free(encoded_again);
    try testing.expectEqualSlices(u8, encoded, encoded_again);

    try testing.expectError(error.InvalidArtifact, decodeGeneratedRowPipelineScheduleTuningArtifact(allocator, &.{ 9, 9 }));
}

const MatrixScheduleCandidates =
    [matrix_product_family_schedule_tuning_max_candidates]MatrixProductFamilyScheduleThreads;

fn matrixScheduleReaderProblem(
    instance: @import("../kernel/library/root.zig").linalg.MatrixProduct,
    storage: *MatrixScheduleCandidates,
) MatrixProductFamilyScheduleTuningProblem {
    const linalg = @import("../kernel/library/root.zig").linalg;
    const candidates = linalg.matrixProductThreadCandidatesForExtents(instance.m, instance.n);
    for (candidates.slice(), 0..) |candidate, index| {
        storage[index] = .{ .x = candidate.x, .y = candidate.y };
    }
    return .{
        .format = .cuda_ptx,
        .m = instance.m,
        .n = instance.n,
        .k = instance.k,
        .dtype = instance.dtype,
        .accumulation_dtype = instance.accumulation_dtype,
        .family_version = linalg.matrix_product_family_version,
        .candidates = storage[0..candidates.slice().len],
    };
}

test "matrix product schedule reader agrees with cache hits and missing keys" {
    const linalg = @import("../kernel/library/root.zig").linalg;
    const allocator = std.testing.allocator;
    const caps = matrixProductFamilyScheduleTestCapabilities(42);
    const probes = [_]linalg.MatrixProduct{
        .{ .m = 5, .n = 7, .k = 3 },
        .{ .m = 64, .n = 32, .k = 16 },
        .{ .m = 64, .n = 32, .k = 16, .dtype = .f16 },
    };
    var cache = MatrixProductFamilyScheduleTuningCache.init(allocator);
    defer cache.deinit();
    for (probes) |probe| {
        var storage: MatrixScheduleCandidates = undefined;
        const problem = matrixScheduleReaderProblem(probe, &storage);
        try cache.recordSelection(caps, problem, .{
            .threads = problem.candidates[problem.candidates.len - 1],
            .winner_median_ns = 3,
            .runner_up_median_ns = 5,
            .sample_count = 7,
        });
    }
    const entries = try cache.exportRecords(allocator);
    defer allocator.free(entries);
    const reader: linalg.MatrixProductScheduleReader = .{
        .device = caps.identity,
        .format = .cuda_ptx,
        .records = entries,
    };
    for (probes) |probe| {
        var storage: MatrixScheduleCandidates = undefined;
        const problem = matrixScheduleReaderProblem(probe, &storage);
        const expected = (try cache.selectionForProblem(caps, problem)).?;
        const actual = (try reader.resolve(probe)).?;
        try testing.expectEqual(expected.threads.x, actual.x);
        try testing.expectEqual(expected.threads.y, actual.y);
        var missing = probe;
        missing.k += 1;
        try testing.expectEqual(null, try cache.selectionForProblem(
            caps,
            matrixScheduleReaderProblem(missing, &storage),
        ));
        try testing.expectEqual(null, try reader.resolve(missing));
        var other = reader;
        other.device.driver_version = "new driver";
        var other_caps = caps;
        other_caps.identity = other.device;
        try testing.expectEqual(null, try cache.selectionForProblem(other_caps, problem));
        try testing.expectEqual(null, try other.resolve(probe));
    }
}
