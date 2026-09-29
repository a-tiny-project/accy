const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");

const artifact = @import("../../artifact/model/root.zig");

pub const product_name = "accy.kernel.family_tuning";

pub const family_tuning_artifact_magic: u32 = 0x41515432;
pub const family_tuning_artifact_version: u32 = 1;
pub const family_tuning_max_extents: usize = 8;
pub const family_tuning_default_margin_percent: u32 = 2;

/// A caller builds this key to look up or record the measured schedule, the thread and block
/// structure a kernel runs with, for one problem on one device. The key identifies a problem by
/// device, the shape of a family, which is a group of related hand-written kernels such as sorts or
/// matrix products, operation, element type, family version, and up to eight problem sizes, so
/// `init` returns null when more than eight sizes are given. Two keys are equal only when every
/// field and every size is equal.
pub const FamilyTuningKey = struct {
    device_fingerprint: u64,
    family_fingerprint: u64,
    operation_fingerprint: u64,
    dtype: gpu_abi.DType,
    family_version: u32,
    extent_count: u32 = 0,
    extents: [family_tuning_max_extents]u64 = @as([family_tuning_max_extents]u64, @splat(0)),

    pub fn init(
        device_fingerprint: u64,
        family_fingerprint: u64,
        operation_fingerprint: u64,
        key_dtype: gpu_abi.DType,
        family_version: u32,
        extents: []const u64,
    ) ?FamilyTuningKey {
        if (extents.len > family_tuning_max_extents) return null;
        var key = FamilyTuningKey{
            .device_fingerprint = device_fingerprint,
            .family_fingerprint = family_fingerprint,
            .operation_fingerprint = operation_fingerprint,
            .dtype = key_dtype,
            .family_version = family_version,
            .extent_count = @intCast(extents.len),
        };
        @memcpy(key.extents[0..extents.len], extents);
        return key;
    }

    pub fn extentSlice(self: *const FamilyTuningKey) []const u64 {
        return self.extents[0..self.extent_count];
    }

    pub fn eql(self: FamilyTuningKey, other: FamilyTuningKey) bool {
        return self.device_fingerprint == other.device_fingerprint and
            self.family_fingerprint == other.family_fingerprint and
            self.operation_fingerprint == other.operation_fingerprint and
            self.dtype == other.dtype and
            self.family_version == other.family_version and
            self.extent_count == other.extent_count and
            std.mem.eql(u64, self.extents[0..self.extent_count], other.extents[0..other.extent_count]);
    }
};

pub fn deviceFingerprint(caps: gpu.BackendCapabilities) u64 {
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes(product_name);
    builder.updateU32(@backingInt(caps.identity.backend));
    builder.updateU32(@backingInt(caps.identity.family));
    builder.updateU32(caps.identity.vendor_id orelse 0);
    builder.updateU32(@intFromBool(caps.identity.vendor_id != null));
    builder.updateU32(caps.identity.device_id orelse 0);
    builder.updateU32(@intFromBool(caps.identity.device_id != null));
    builder.updateBytes(caps.identity.name);
    return builder.finish();
}

pub const FamilyCandidateMeasurement = struct {
    key: FamilyTuningKey,
    target: []const u8,
    median_ns: u64,
    sample_count: u32 = 1,
};

pub const FamilyMeasurementAccumulator = struct {
    allocator: std.mem.Allocator,
    measurements: std.ArrayListUnmanaged(FamilyCandidateMeasurement) = .empty,

    pub fn init(measurement_allocator: std.mem.Allocator) FamilyMeasurementAccumulator {
        return .{ .allocator = measurement_allocator };
    }

    pub fn count(self: *const FamilyMeasurementAccumulator) usize {
        return self.measurements.items.len;
    }

    pub fn append(
        self: *FamilyMeasurementAccumulator,
        key: FamilyTuningKey,
        target: []const u8,
        median_ns: u64,
        sample_count: u32,
    ) gpu.BackendError!void {
        if (target.len == 0 or median_ns == 0) return error.InvalidArtifact;
        const owned_target = self.allocator.dupe(u8, target) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_target);
        self.measurements.append(self.allocator, .{
            .key = key,
            .target = owned_target,
            .median_ns = median_ns,
            .sample_count = sample_count,
        }) catch return error.OutOfMemory;
    }

    pub fn selectWinners(
        self: *const FamilyMeasurementAccumulator,
        result_allocator: std.mem.Allocator,
        margin_percent: u32,
    ) gpu.BackendError!OwnedFamilyTuningRecords {
        return selectFamilyWinners(result_allocator, self.measurements.items, margin_percent);
    }

    pub fn deinit(self: *FamilyMeasurementAccumulator) void {
        for (self.measurements.items) |measurement| self.allocator.free(measurement.target);
        self.measurements.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const FamilyTuningRecord = struct {
    key: FamilyTuningKey,
    target: []const u8,
    winner_median_ns: u64,
    runner_up_median_ns: u64,
    sample_count: u32,
};

pub const FamilyTuningTable = struct {
    records: []const FamilyTuningRecord = &.{},

    pub fn find(self: FamilyTuningTable, key: FamilyTuningKey) ?FamilyTuningRecord {
        for (self.records) |record| {
            if (record.key.eql(key)) return record;
        }
        return null;
    }
};

pub const OwnedFamilyTuningRecords = struct {
    allocator: std.mem.Allocator,
    records: []FamilyTuningRecord = &.{},

    pub fn table(self: *const OwnedFamilyTuningRecords) FamilyTuningTable {
        return .{ .records = self.records };
    }

    pub fn deinit(self: *OwnedFamilyTuningRecords) void {
        for (self.records) |record| self.allocator.free(record.target);
        if (self.records.len != 0) self.allocator.free(self.records);
        self.* = undefined;
    }
};

/// A caller hands this reader to a kernel family so its schedule choice follows measurements taken
/// on the same device. The reader holds one device fingerprint and a table of measured records. The
/// device fingerprint covers the backend kind, device family, vendor and device ids, and the device
/// name, and leaves out the driver version. A family keeps the schedule it would choose with no
/// table when it finds no record with an exact key.
pub const FamilyTuningReader = struct {
    device_fingerprint: u64,
    table: FamilyTuningTable,

    pub fn init(caps: gpu.BackendCapabilities, table: FamilyTuningTable) FamilyTuningReader {
        return .{ .device_fingerprint = deviceFingerprint(caps), .table = table };
    }
};

/// A caller uses this function to turn benchmark measurements into tuning records that change code
/// generation only when the evidence is clear. The function groups measurements by key and emits
/// one record per group, naming the fastest candidate by median time and keeping the runner-up
/// time. The function emits nothing for a group with one candidate and nothing for a group whose
/// runner-up is within `margin_percent` of the winner, so a single or near-tied measurement cannot
/// change generated code. The call returns `error.InvalidArtifact` when any measurement has a
/// median of zero. The returned records and their target strings are allocated with
/// `result_allocator` and owned by the caller.
pub fn selectFamilyWinners(
    result_allocator: std.mem.Allocator,
    measurements: []const FamilyCandidateMeasurement,
    margin_percent: u32,
) gpu.BackendError!OwnedFamilyTuningRecords {
    var records = std.ArrayListUnmanaged(FamilyTuningRecord).empty;
    errdefer {
        for (records.items) |record| result_allocator.free(record.target);
        records.deinit(result_allocator);
    }

    for (measurements, 0..) |measurement, index| {
        if (measurement.median_ns == 0) return error.InvalidArtifact;
        var seen_before = false;
        for (measurements[0..index]) |previous| {
            if (previous.key.eql(measurement.key)) {
                seen_before = true;
                break;
            }
        }
        if (seen_before) continue;

        var winner = measurement;
        var runner_up_ns: u64 = 0;
        var group_count: usize = 1;
        for (measurements[index + 1 ..]) |candidate| {
            if (!candidate.key.eql(measurement.key)) continue;
            group_count += 1;
            if (candidate.median_ns < winner.median_ns) {
                runner_up_ns = winner.median_ns;
                winner = candidate;
            } else if (runner_up_ns == 0 or candidate.median_ns < runner_up_ns) {
                runner_up_ns = candidate.median_ns;
            }
        }
        if (group_count < 2) continue;
        const margin_floor = winner.median_ns + winner.median_ns * margin_percent / 100;
        if (runner_up_ns < margin_floor) continue;

        const target = result_allocator.dupe(u8, winner.target) catch return error.OutOfMemory;
        errdefer result_allocator.free(target);
        records.append(result_allocator, .{
            .key = winner.key,
            .target = target,
            .winner_median_ns = winner.median_ns,
            .runner_up_median_ns = runner_up_ns,
            .sample_count = winner.sample_count,
        }) catch return error.OutOfMemory;
    }

    return .{
        .allocator = result_allocator,
        .records = records.toOwnedSlice(result_allocator) catch return error.OutOfMemory,
    };
}

pub fn encodeFamilyTuningArtifact(
    result_allocator: std.mem.Allocator,
    records: []const FamilyTuningRecord,
) gpu.BackendError![]u8 {
    if (records.len > std.math.maxInt(u32)) return error.InvalidArtifact;
    var writer = artifact.wire.ByteWriter{};
    errdefer writer.deinit(result_allocator);

    try writer.writeU32(result_allocator, family_tuning_artifact_magic);
    try writer.writeU32(result_allocator, family_tuning_artifact_version);
    try writer.writeU32(result_allocator, @intCast(records.len));
    for (records) |record| {
        if (record.target.len == 0) return error.InvalidArtifact;
        if (record.key.extent_count > family_tuning_max_extents) return error.InvalidArtifact;
        try writer.writeU64(result_allocator, record.key.device_fingerprint);
        try writer.writeU64(result_allocator, record.key.family_fingerprint);
        try writer.writeU64(result_allocator, record.key.operation_fingerprint);
        try writer.writeEnum(result_allocator, gpu_abi.DType, record.key.dtype);
        try writer.writeU32(result_allocator, record.key.family_version);
        try writer.writeU32(result_allocator, record.key.extent_count);
        for (record.key.extentSlice()) |extent| {
            try writer.writeU64(result_allocator, extent);
        }
        try writer.writeLengthPrefixedBytes(result_allocator, record.target);
        try writer.writeU64(result_allocator, record.winner_median_ns);
        try writer.writeU64(result_allocator, record.runner_up_median_ns);
        try writer.writeU32(result_allocator, record.sample_count);
    }

    return writer.toOwnedSlice(result_allocator) catch return error.OutOfMemory;
}

pub fn decodeFamilyTuningArtifact(
    result_allocator: std.mem.Allocator,
    bytes: []const u8,
) gpu.BackendError!OwnedFamilyTuningRecords {
    var reader = artifact.wire.ByteReader{ .bytes = bytes };
    if ((try reader.readU32()) != family_tuning_artifact_magic) return error.InvalidArtifact;
    if ((try reader.readU32()) != family_tuning_artifact_version) return error.InvalidArtifact;
    const record_count = try reader.readU32();

    var owned = OwnedFamilyTuningRecords{ .allocator = result_allocator };
    var records = std.ArrayListUnmanaged(FamilyTuningRecord).empty;
    errdefer {
        for (records.items) |record| result_allocator.free(record.target);
        records.deinit(result_allocator);
    }

    var index: u32 = 0;
    while (index < record_count) : (index += 1) {
        var key = FamilyTuningKey{
            .device_fingerprint = try reader.readU64(),
            .family_fingerprint = try reader.readU64(),
            .operation_fingerprint = try reader.readU64(),
            .dtype = try reader.readEnum(gpu_abi.DType),
            .family_version = try reader.readU32(),
        };
        key.extent_count = try reader.readU32();
        if (key.extent_count > family_tuning_max_extents) return error.InvalidArtifact;
        for (key.extents[0..key.extent_count]) |*extent| {
            extent.* = try reader.readU64();
        }
        const target_bytes = try reader.readLengthPrefixedBytes();
        if (target_bytes.len == 0) return error.InvalidArtifact;
        const target = result_allocator.dupe(u8, target_bytes) catch return error.OutOfMemory;
        errdefer result_allocator.free(target);
        const winner_median_ns = try reader.readU64();
        const runner_up_median_ns = try reader.readU64();
        const sample_count = try reader.readU32();
        records.append(result_allocator, .{
            .key = key,
            .target = target,
            .winner_median_ns = winner_median_ns,
            .runner_up_median_ns = runner_up_median_ns,
            .sample_count = sample_count,
        }) catch return error.OutOfMemory;
    }
    try reader.expectDone();

    owned.records = records.toOwnedSlice(result_allocator) catch return error.OutOfMemory;
    return owned;
}

pub fn artifactFingerprint(bytes: []const u8) choir.product.incremental.Fingerprint {
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes(product_name);
    builder.updateU32(family_tuning_artifact_version);
    builder.updateBytes(bytes);
    return builder.finish();
}

pub fn artifactProductStamp(bytes: []const u8) choir.product.incremental.ProductStamp {
    return choir.product.incremental.productStamp(product_name, artifactFingerprint(bytes));
}

const testing = std.testing;

fn testKey(device: u64, family: u64, extents: []const u64) FamilyTuningKey {
    return FamilyTuningKey.init(device, family, 77, .f32, 1, extents) orelse unreachable;
}

fn testCapabilities(device_id: u32) gpu.BackendCapabilities {
    return .{ .identity = .{
        .backend = .cuda,
        .family = .nvidia_cuda,
        .name = "test-cuda-device",
        .vendor_id = 0x10de,
        .device_id = device_id,
    } };
}

test "family tuning winner selection requires a margin over the runner up" {
    const allocator = testing.allocator;
    const key = testKey(11, 22, &.{ 64, 64 });
    const flappy_key = testKey(11, 33, &.{128});
    const lone_key = testKey(11, 44, &.{256});

    const measurements = [_]FamilyCandidateMeasurement{
        .{ .key = key, .target = "family_a_16", .median_ns = 1200, .sample_count = 30 },
        .{ .key = key, .target = "family_a_32", .median_ns = 1000, .sample_count = 30 },
        .{ .key = key, .target = "family_a_64", .median_ns = 1500, .sample_count = 30 },
        .{ .key = flappy_key, .target = "family_b_32", .median_ns = 1000, .sample_count = 30 },
        .{ .key = flappy_key, .target = "family_b_64", .median_ns = 1010, .sample_count = 30 },
        .{ .key = lone_key, .target = "family_c_32", .median_ns = 900, .sample_count = 30 },
    };

    var winners = try selectFamilyWinners(allocator, measurements[0..], family_tuning_default_margin_percent);
    defer winners.deinit();

    try testing.expectEqual(@as(usize, 1), winners.records.len);
    try testing.expectEqualStrings("family_a_32", winners.records[0].target);
    try testing.expectEqual(@as(u64, 1000), winners.records[0].winner_median_ns);
    try testing.expectEqual(@as(u64, 1200), winners.records[0].runner_up_median_ns);

    const table = winners.table();
    const found = table.find(key) orelse return error.TestExpectedTuningRecord;
    try testing.expectEqualStrings("family_a_32", found.target);
    try testing.expectEqual(@as(?FamilyTuningRecord, null), table.find(flappy_key));
    try testing.expectEqual(@as(?FamilyTuningRecord, null), table.find(lone_key));
}

test "family tuning artifact round-trips through the wire" {
    const allocator = testing.allocator;
    const records = [_]FamilyTuningRecord{
        .{
            .key = testKey(7, 99, &.{ 1024, 500, 1 }),
            .target = "accy.kernel.indexing.gather_family_512_f32",
            .winner_median_ns = 10350,
            .runner_up_median_ns = 10419,
            .sample_count = 30,
        },
        .{
            .key = testKey(7, 55, &.{4096}),
            .target = "accy.kernel.segmented.segment_sum_family_warp_512_f32",
            .winner_median_ns = 7905,
            .runner_up_median_ns = 16842,
            .sample_count = 30,
        },
    };

    const encoded = try encodeFamilyTuningArtifact(allocator, records[0..]);
    defer allocator.free(encoded);

    var decoded = try decodeFamilyTuningArtifact(allocator, encoded);
    defer decoded.deinit();

    try testing.expectEqual(records.len, decoded.records.len);
    for (records, decoded.records) |want, got| {
        try testing.expect(want.key.eql(got.key));
        try testing.expectEqualStrings(want.target, got.target);
        try testing.expectEqual(want.winner_median_ns, got.winner_median_ns);
        try testing.expectEqual(want.runner_up_median_ns, got.runner_up_median_ns);
        try testing.expectEqual(want.sample_count, got.sample_count);
    }
}

test "family tuning artifact rejects truncated and oversized payloads" {
    const allocator = testing.allocator;
    const records = [_]FamilyTuningRecord{.{
        .key = testKey(1, 2, &.{8}),
        .target = "accy.kernel.scan.prefix_sum_family_32_f32",
        .winner_median_ns = 100,
        .runner_up_median_ns = 200,
        .sample_count = 10,
    }};
    const encoded = try encodeFamilyTuningArtifact(allocator, records[0..]);
    defer allocator.free(encoded);

    try testing.expectError(error.InvalidArtifact, decodeFamilyTuningArtifact(allocator, encoded[0 .. encoded.len - 1]));

    var oversized_key = testKey(1, 2, &.{8});
    oversized_key.extent_count = family_tuning_max_extents + 1;
    const invalid = [_]FamilyTuningRecord{.{
        .key = oversized_key,
        .target = "x",
        .winner_median_ns = 1,
        .runner_up_median_ns = 2,
        .sample_count = 1,
    }};
    try testing.expectError(error.InvalidArtifact, encodeFamilyTuningArtifact(allocator, invalid[0..]));
}

test "family measurement accumulator owns targets and folds winners" {
    const allocator = testing.allocator;
    var accumulator = FamilyMeasurementAccumulator.init(allocator);
    defer accumulator.deinit();

    const key = testKey(11, 22, &.{ 64, 64 });
    var target_buffer: [10]u8 = undefined;
    @memcpy(target_buffer[0..], "family_a_8");
    try accumulator.append(key, target_buffer[0..], 1500, 30);
    @memcpy(target_buffer[0..], "XXXXXXXXXX");
    try accumulator.append(key, "family_a_32", 1000, 30);
    try accumulator.append(key, "family_a_64", 1200, 30);
    try testing.expectEqual(@as(usize, 3), accumulator.count());
    try testing.expectEqualStrings("family_a_8", accumulator.measurements.items[0].target);

    var winners = try accumulator.selectWinners(allocator, family_tuning_default_margin_percent);
    defer winners.deinit();
    try testing.expectEqual(@as(usize, 1), winners.records.len);
    try testing.expectEqualStrings("family_a_32", winners.records[0].target);
    try testing.expectEqual(@as(u64, 1000), winners.records[0].winner_median_ns);
    try testing.expectEqual(@as(u64, 1200), winners.records[0].runner_up_median_ns);

    try testing.expectError(error.InvalidArtifact, accumulator.append(key, "", 100, 1));
    try testing.expectError(error.InvalidArtifact, accumulator.append(key, "x", 0, 1));
    try testing.expectEqual(@as(usize, 3), accumulator.count());
}

test "family tuning artifact product identity tracks bytes" {
    const allocator = testing.allocator;
    const records = [_]FamilyTuningRecord{.{
        .key = testKey(1, 2, &.{8}),
        .target = "accy.kernel.scan.prefix_sum_family_32_f32",
        .winner_median_ns = 100,
        .runner_up_median_ns = 200,
        .sample_count = 10,
    }};
    const encoded = try encodeFamilyTuningArtifact(allocator, records[0..]);
    defer allocator.free(encoded);

    const fingerprint = artifactFingerprint(encoded);
    try testing.expectEqual(fingerprint, artifactFingerprint(encoded));

    const mutated = try allocator.dupe(u8, encoded);
    defer allocator.free(mutated);
    mutated[mutated.len - 1] +%= 1;
    try testing.expect(artifactFingerprint(mutated) != fingerprint);

    const stamp = artifactProductStamp(encoded);
    try testing.expectEqualStrings(product_name, stamp.name);
    try testing.expectEqual(fingerprint, stamp.fingerprint);
}

test "family tuning reader resolves winners by instance and device" {
    const caps = testCapabilities(0x2684);
    const device = deviceFingerprint(caps);

    const key = testKey(device, 64, &.{64});
    const records = [_]FamilyTuningRecord{.{
        .key = key,
        .target = "family_64",
        .winner_median_ns = 900,
        .runner_up_median_ns = 1500,
        .sample_count = 30,
    }};

    const reader = FamilyTuningReader.init(caps, .{ .records = records[0..] });
    try testing.expectEqual(device, reader.device_fingerprint);

    const hit = reader.table.find(key) orelse return error.TestExpectedTuningRecord;
    try testing.expectEqualStrings("family_64", hit.target);

    const other_extent = testKey(device, 64, &.{128});
    try testing.expectEqual(@as(?FamilyTuningRecord, null), reader.table.find(other_extent));

    const other_family = testKey(device, 65, &.{64});
    try testing.expectEqual(@as(?FamilyTuningRecord, null), reader.table.find(other_family));

    const other_device = FamilyTuningReader.init(testCapabilities(0x1b80), .{ .records = records[0..] });
    const other_device_key = testKey(other_device.device_fingerprint, 64, &.{64});
    try testing.expectEqual(@as(?FamilyTuningRecord, null), other_device.table.find(other_device_key));
}

pub const matrix_product_family_schedule_tuning_product_name =
    "accy.exec.matrix_product_family_schedule_tuning";
pub const matrix_product_family_schedule_tuning_record_version: u32 = 1;
pub const matrix_product_family_schedule_tuning_max_candidates: usize = 8;

pub const MatrixProductFamilyScheduleThreads = struct {
    x: u32,
    y: u32,

    pub fn lessThan(
        _: void,
        lhs: MatrixProductFamilyScheduleThreads,
        rhs: MatrixProductFamilyScheduleThreads,
    ) bool {
        return if (lhs.x != rhs.x) lhs.x < rhs.x else lhs.y < rhs.y;
    }

    pub fn eql(
        self: MatrixProductFamilyScheduleThreads,
        other: MatrixProductFamilyScheduleThreads,
    ) bool {
        return self.x == other.x and self.y == other.y;
    }
};

pub const MatrixProductFamilyScheduleTuningProblem = struct {
    format: gpu.ArtifactFormat,
    m: u64,
    n: u64,
    k: u64,
    dtype: gpu_abi.DType = .f32,
    accumulation_dtype: gpu_abi.DType = .f32,
    family_version: u32,
    candidates: []const MatrixProductFamilyScheduleThreads,
};

pub const MatrixProductFamilyScheduleTuningKey = struct {
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
    m: u64,
    n: u64,
    k: u64,
    dtype: gpu_abi.DType,
    accumulation_dtype: gpu_abi.DType,
    family_version: u32,
    candidate_count: u32,
    candidate_set_fingerprint: u64,

    pub fn init(
        device: gpu.DeviceIdentity,
        problem: MatrixProductFamilyScheduleTuningProblem,
    ) gpu.BackendError!MatrixProductFamilyScheduleTuningKey {
        if (problem.m == 0 or problem.n == 0 or problem.k == 0) return error.InvalidArtifact;
        if (problem.family_version == 0) return error.InvalidArtifact;
        const candidate_set_fingerprint = try matrixProductFamilyScheduleCandidateSetFingerprint(
            problem.candidates,
        );
        return .{
            .backend = device.backend,
            .family = device.family,
            .format = problem.format,
            .vendor_id = device.vendor_id orelse 0,
            .has_vendor_id = device.vendor_id != null,
            .device_id = device.device_id orelse 0,
            .has_device_id = device.device_id != null,
            .name_fingerprint = matrixScheduleBytesFingerprint(
                matrix_product_family_schedule_tuning_product_name ++ ".device.name",
                device.name,
            ),
            .driver_version_fingerprint = if (device.driver_version) |version|
                matrixScheduleBytesFingerprint(
                    matrix_product_family_schedule_tuning_product_name ++ ".driver.version",
                    version,
                )
            else
                0,
            .has_driver_version = device.driver_version != null,
            .m = problem.m,
            .n = problem.n,
            .k = problem.k,
            .dtype = problem.dtype,
            .accumulation_dtype = problem.accumulation_dtype,
            .family_version = problem.family_version,
            .candidate_count = @intCast(problem.candidates.len),
            .candidate_set_fingerprint = candidate_set_fingerprint,
        };
    }

    pub fn eql(
        self: MatrixProductFamilyScheduleTuningKey,
        other: MatrixProductFamilyScheduleTuningKey,
    ) bool {
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
            self.m == other.m and
            self.n == other.n and
            self.k == other.k and
            self.dtype == other.dtype and
            self.accumulation_dtype == other.accumulation_dtype and
            self.family_version == other.family_version and
            self.candidate_count == other.candidate_count and
            self.candidate_set_fingerprint == other.candidate_set_fingerprint;
    }
};

pub const MatrixProductFamilyScheduleTuningSelection = struct {
    threads: MatrixProductFamilyScheduleThreads,
    winner_median_ns: u64,
    runner_up_median_ns: u64,
    sample_count: u32,
};

pub const MatrixProductFamilyScheduleTuningRecord = struct {
    version: u32 = matrix_product_family_schedule_tuning_record_version,
    key: MatrixProductFamilyScheduleTuningKey,
    selection: MatrixProductFamilyScheduleTuningSelection,
};

pub fn matrixProductFamilyScheduleCandidateSetFingerprint(
    candidates: []const MatrixProductFamilyScheduleThreads,
) gpu.BackendError!choir.product.incremental.Fingerprint {
    const set = try sortedMatrixProductFamilyScheduleCandidates(candidates);
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes(matrix_product_family_schedule_tuning_product_name);
    builder.updateU32(@intCast(set.count));
    for (set.slice()) |candidate| {
        builder.updateU32(candidate.x);
        builder.updateU32(candidate.y);
    }
    return builder.finish();
}

const MatrixProductFamilyScheduleCandidateSet = struct {
    const capacity = matrix_product_family_schedule_tuning_max_candidates;
    count: usize = 0,
    items: [capacity]MatrixProductFamilyScheduleThreads = @splat(.{ .x = 1, .y = 1 }),

    fn slice(
        self: *const MatrixProductFamilyScheduleCandidateSet,
    ) []const MatrixProductFamilyScheduleThreads {
        return self.items[0..self.count];
    }
};

fn sortedMatrixProductFamilyScheduleCandidates(
    candidates: []const MatrixProductFamilyScheduleThreads,
) gpu.BackendError!MatrixProductFamilyScheduleCandidateSet {
    if (candidates.len < 2) return error.InvalidArtifact;
    if (candidates.len > matrix_product_family_schedule_tuning_max_candidates) {
        return error.InvalidArtifact;
    }
    var set = MatrixProductFamilyScheduleCandidateSet{ .count = candidates.len };
    @memcpy(set.items[0..candidates.len], candidates);
    for (set.slice()) |candidate| {
        if (candidate.x == 0 or candidate.y == 0) return error.InvalidArtifact;
    }
    std.mem.sort(
        MatrixProductFamilyScheduleThreads,
        set.items[0..set.count],
        {},
        MatrixProductFamilyScheduleThreads.lessThan,
    );
    for (set.slice()[1..], 1..) |candidate, index| {
        if (candidate.eql(set.items[index - 1])) return error.InvalidArtifact;
    }
    return set;
}

fn matrixScheduleBytesFingerprint(domain: []const u8, bytes: []const u8) u64 {
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes(domain);
    builder.updateBytes(bytes);
    return builder.finish();
}

test "matrix product family schedule candidate set fingerprint canonicalizes candidates" {
    const candidates = [_]MatrixProductFamilyScheduleThreads{
        .{ .x = 17, .y = 9 },
        .{ .x = 16, .y = 16 },
        .{ .x = 8, .y = 8 },
    };
    const reordered = [_]MatrixProductFamilyScheduleThreads{
        candidates[2],
        candidates[0],
        candidates[1],
    };
    const changed = [_]MatrixProductFamilyScheduleThreads{
        candidates[0],
        candidates[1],
        .{ .x = 4, .y = 4 },
    };

    const fingerprint = try matrixProductFamilyScheduleCandidateSetFingerprint(candidates[0..]);
    try testing.expectEqual(
        fingerprint,
        try matrixProductFamilyScheduleCandidateSetFingerprint(reordered[0..]),
    );
    const changed_fingerprint = try matrixProductFamilyScheduleCandidateSetFingerprint(&changed);
    try testing.expect(fingerprint != changed_fingerprint);
}

test "matrix product family schedule candidate set rejects invalid candidates" {
    const candidates = [_]MatrixProductFamilyScheduleThreads{
        .{ .x = 17, .y = 9 },
        .{ .x = 16, .y = 16 },
        .{ .x = 8, .y = 8 },
    };
    const single = [_]MatrixProductFamilyScheduleThreads{candidates[0]};
    try testing.expectError(
        error.InvalidArtifact,
        matrixProductFamilyScheduleCandidateSetFingerprint(&single),
    );

    const duplicate = [_]MatrixProductFamilyScheduleThreads{
        candidates[0],
        candidates[1],
        candidates[0],
    };
    try testing.expectError(
        error.InvalidArtifact,
        matrixProductFamilyScheduleCandidateSetFingerprint(&duplicate),
    );

    const zero = [_]MatrixProductFamilyScheduleThreads{
        candidates[0],
        .{ .x = 0, .y = 16 },
    };
    try testing.expectError(
        error.InvalidArtifact,
        matrixProductFamilyScheduleCandidateSetFingerprint(&zero),
    );

    const too_many = [_]MatrixProductFamilyScheduleThreads{
        .{ .x = 1, .y = 1 },
        .{ .x = 2, .y = 1 },
        .{ .x = 3, .y = 1 },
        .{ .x = 4, .y = 1 },
        .{ .x = 5, .y = 1 },
        .{ .x = 6, .y = 1 },
        .{ .x = 7, .y = 1 },
        .{ .x = 8, .y = 1 },
        .{ .x = 9, .y = 1 },
    };
    try testing.expectError(
        error.InvalidArtifact,
        matrixProductFamilyScheduleCandidateSetFingerprint(&too_many),
    );
}
