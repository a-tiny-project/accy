const std = @import("std");
const gpu = @import("gpu");
const choir = @import("choir");
const accy_root = @import("../root.zig");

const ir = choir.ir;

pub const backend_kind_attr_name = "accy.backend.kind";
pub const artifact_format_attr_name = "accy.backend.artifact_format";
pub const math_tier_attr_name = "accy.backend.math_tier";
pub const dtype_bits_attr_name = "accy.backend.dtype_bits";
pub const feature_bits_attr_name = "accy.backend.feature_bits";
pub const generated_scan_schedule_attr_name = "accy.backend.scan_schedule";

pub const GeneratedScanSchedule = struct {
    threads: u32,
    items: u32,

    pub fn eql(self: GeneratedScanSchedule, other: GeneratedScanSchedule) bool {
        return self.threads == other.threads and self.items == other.items;
    }
};

pub const GeneratedScanScheduleDecision = struct {
    total: ?u64 = null,
    schedule: GeneratedScanSchedule,
};

pub fn setGeneratedScanSchedules(
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    module: *ir.Operation,
    decisions: []const GeneratedScanScheduleDecision,
) !void {
    const encoded = try encodeGeneratedScanSchedules(allocator, decisions);
    defer allocator.free(encoded);
    try module.setAttr(generated_scan_schedule_attr_name, try ctx.getStringAttr(encoded));
}

/// The recipe calls this function to record caller decisions for one generated kernel, such as its
/// thread count, optionally tied to a problem size, as a request's scan schedule choices in the
/// same bytes the module stores. The recipe encodes a stage's options into its stage record. The
/// function writes the choices as comma-separated entries: `threads`x`items` or
/// `total`=`threads`x`items` when a choice is tied to a total length. The bytes match the module
/// attribute the same choices are stored in, and the caller owns them. The call returns
/// `error.InvalidArtifact` for an empty list.
pub fn encodeGeneratedScanSchedules(
    allocator: std.mem.Allocator,
    decisions: []const GeneratedScanScheduleDecision,
) ![]u8 {
    if (decisions.len == 0) return error.InvalidArtifact;
    var text = std.ArrayListUnmanaged(u8).empty;
    errdefer text.deinit(allocator);
    for (decisions, 0..) |decision, index| {
        if (index != 0) try text.append(allocator, ',');
        var entry_buffer: [64]u8 = undefined;
        const entry = if (decision.total) |total|
            try std.fmt.bufPrint(&entry_buffer, "{d}={d}x{d}", .{ total, decision.schedule.threads, decision.schedule.items })
        else
            try std.fmt.bufPrint(&entry_buffer, "{d}x{d}", .{ decision.schedule.threads, decision.schedule.items });
        try text.appendSlice(allocator, entry);
    }
    return text.toOwnedSlice(allocator);
}

pub fn readGeneratedScanSchedules(module: *const ir.Operation) ?[]const u8 {
    const attr = module.getAttrAs(ir.Attribute.StringAttr, generated_scan_schedule_attr_name) orelse return null;
    return attr.getValue();
}

pub fn resolveGeneratedScanSchedule(
    encoded: []const u8,
    total: u64,
) error{InvalidArtifact}!?GeneratedScanSchedule {
    var fallback: ?GeneratedScanSchedule = null;
    var entries = std.mem.splitScalar(u8, encoded, ',');
    while (entries.next()) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=')) |split_index| {
            const entry_total = std.fmt.parseInt(u64, entry[0..split_index], 10) catch return error.InvalidArtifact;
            const schedule = try parseGeneratedScanSchedule(entry[split_index + 1 ..]);
            if (entry_total == total) return schedule;
        } else {
            fallback = try parseGeneratedScanSchedule(entry);
        }
    }
    return fallback;
}

fn parseGeneratedScanSchedule(text: []const u8) error{InvalidArtifact}!GeneratedScanSchedule {
    const split_index = std.mem.indexOfScalar(u8, text, 'x') orelse return error.InvalidArtifact;
    const threads = std.fmt.parseInt(u32, text[0..split_index], 10) catch return error.InvalidArtifact;
    const items = std.fmt.parseInt(u32, text[split_index + 1 ..], 10) catch return error.InvalidArtifact;
    if (threads == 0 or items == 0) return error.InvalidArtifact;
    return .{ .threads = threads, .items = items };
}

pub const generated_row_pipeline_schedule_attr_name = "accy.backend.row_pipeline_schedule";

pub const GeneratedRowPipelineSchedule = struct {
    threads: u32,

    pub fn eql(self: GeneratedRowPipelineSchedule, other: GeneratedRowPipelineSchedule) bool {
        return self.threads == other.threads;
    }
};

pub const GeneratedRowPipelineShape = struct {
    rows: u64,
    cols: u64,
};

pub const GeneratedRowPipelineScheduleDecision = struct {
    shape: ?GeneratedRowPipelineShape = null,
    schedule: GeneratedRowPipelineSchedule,
};

pub fn setGeneratedRowPipelineSchedules(
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    module: *ir.Operation,
    decisions: []const GeneratedRowPipelineScheduleDecision,
) !void {
    const encoded = try encodeGeneratedRowPipelineSchedules(allocator, decisions);
    defer allocator.free(encoded);
    try module.setAttr(generated_row_pipeline_schedule_attr_name, try ctx.getStringAttr(encoded));
}

/// The recipe calls this function to record a request's row schedule choices in the same bytes the
/// module stores. The function writes the choices as comma-separated entries: `threads` or
/// `rows`x`cols`=`threads` when a choice is tied to a row shape. The bytes match the module
/// attribute the same choices are stored in, and the caller owns them. The call returns
/// `error.InvalidArtifact` for an empty list.
pub fn encodeGeneratedRowPipelineSchedules(
    allocator: std.mem.Allocator,
    decisions: []const GeneratedRowPipelineScheduleDecision,
) ![]u8 {
    if (decisions.len == 0) return error.InvalidArtifact;
    var text = std.ArrayListUnmanaged(u8).empty;
    errdefer text.deinit(allocator);
    for (decisions, 0..) |decision, index| {
        if (index != 0) try text.append(allocator, ',');
        var entry_buffer: [96]u8 = undefined;
        const entry = if (decision.shape) |shape|
            try std.fmt.bufPrint(&entry_buffer, "{d}x{d}={d}", .{ shape.rows, shape.cols, decision.schedule.threads })
        else
            try std.fmt.bufPrint(&entry_buffer, "{d}", .{decision.schedule.threads});
        try text.appendSlice(allocator, entry);
    }
    return text.toOwnedSlice(allocator);
}

pub fn readGeneratedRowPipelineSchedules(module: *const ir.Operation) ?[]const u8 {
    const attr = module.getAttrAs(ir.Attribute.StringAttr, generated_row_pipeline_schedule_attr_name) orelse return null;
    return attr.getValue();
}

pub fn resolveGeneratedRowPipelineSchedule(
    encoded: []const u8,
    rows: u64,
    cols: u64,
) error{InvalidArtifact}!?GeneratedRowPipelineSchedule {
    var fallback: ?GeneratedRowPipelineSchedule = null;
    var entries = std.mem.splitScalar(u8, encoded, ',');
    while (entries.next()) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=')) |split_index| {
            const shape_text = entry[0..split_index];
            const shape_split = std.mem.indexOfScalar(u8, shape_text, 'x') orelse return error.InvalidArtifact;
            const entry_rows = std.fmt.parseInt(u64, shape_text[0..shape_split], 10) catch return error.InvalidArtifact;
            const entry_cols = std.fmt.parseInt(u64, shape_text[shape_split + 1 ..], 10) catch return error.InvalidArtifact;
            const schedule = try parseGeneratedRowPipelineSchedule(entry[split_index + 1 ..]);
            if (entry_rows == rows and entry_cols == cols) return schedule;
        } else {
            fallback = try parseGeneratedRowPipelineSchedule(entry);
        }
    }
    return fallback;
}

fn parseGeneratedRowPipelineSchedule(text: []const u8) error{InvalidArtifact}!GeneratedRowPipelineSchedule {
    const threads = std.fmt.parseInt(u32, text, 10) catch return error.InvalidArtifact;
    if (threads == 0) return error.InvalidArtifact;
    return .{ .threads = threads };
}

pub const BackendTargetProfile = accy_root.choir.record.target.BackendTargetProfile;

pub fn setBackendTargetProfile(
    ctx: *ir.Context,
    module: *ir.Operation,
    profile: BackendTargetProfile,
) !void {
    try module.setAttr(backend_kind_attr_name, try ctx.getStringAttr(@tagName(profile.backend_kind)));
    try module.setAttr(artifact_format_attr_name, try ctx.getStringAttr(@tagName(profile.artifact_format)));
    try module.setAttr(math_tier_attr_name, try ctx.getStringAttr(@tagName(profile.math_tier)));
    try module.setAttr(dtype_bits_attr_name, try ctx.getIntegerAttr(@bitCast(profile.dtype_bits), 64, false));
    try module.setAttr(feature_bits_attr_name, try ctx.getIntegerAttr(@bitCast(profile.feature_bits), 64, false));
}

pub fn readBackendTargetProfile(module: *const ir.Operation) ?BackendTargetProfile {
    const backend_kind = readEnumAttr(gpu.BackendKind, module, backend_kind_attr_name) orelse return null;
    const artifact_format = readEnumAttr(gpu.ArtifactFormat, module, artifact_format_attr_name) orelse return null;
    const math_tier = readEnumAttr(gpu.BackendMathTier, module, math_tier_attr_name) orelse return null;
    const dtype_bits = readU64Attr(module, dtype_bits_attr_name) orelse return null;
    const feature_bits = readU64Attr(module, feature_bits_attr_name) orelse return null;
    return .{
        .backend_kind = backend_kind,
        .artifact_format = artifact_format,
        .math_tier = math_tier,
        .dtype_bits = dtype_bits,
        .feature_bits = feature_bits,
    };
}

fn readEnumAttr(comptime E: type, module: *const ir.Operation, attr_name: []const u8) ?E {
    const string_attr = module.getAttrAs(ir.Attribute.StringAttr, attr_name) orelse return null;
    return std.meta.stringToEnum(E, string_attr.getValue());
}

fn readU64Attr(module: *const ir.Operation, attr_name: []const u8) ?u64 {
    const int_attr = module.getAttrAs(ir.Attribute.IntegerAttr, attr_name) orelse return null;
    return int_attr.getUnsignedValue();
}

const testing = std.testing;

test "backend target profile round trips through prepared module attrs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module = try choir.dialects.builtin.BuiltinDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const profile = try BackendTargetProfile.init(.{
        .identity = .{
            .backend = .vulkan,
            .family = .vulkan,
        },
        .dtypes = gpu.DTypeSet.init(&.{ .i32, .f32 }),
        .features = .{ .atomic_i32 = true },
        .artifact_formats = gpu.ArtifactFormatSet.init(&.{.vulkan_spirv}),
    }, .vulkan, .vulkan_spirv);

    try setBackendTargetProfile(&ctx, module.op, profile);
    const read = readBackendTargetProfile(module.op) orelse return error.MissingTargetProfile;

    try testing.expectEqual(profile.backend_kind, read.backend_kind);
    try testing.expectEqual(profile.artifact_format, read.artifact_format);
    try testing.expectEqual(profile.math_tier, read.math_tier);
    try testing.expectEqual(profile.dtype_bits, read.dtype_bits);
    try testing.expectEqual(profile.feature_bits, read.feature_bits);
    try testing.expect(read.supportsDType(.f32));
    try testing.expect(!read.supportsDType(.f64));
}

test "generated scan schedule decisions round trip through module attrs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module = try choir.dialects.builtin.BuiltinDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    try setGeneratedScanSchedules(allocator, &ctx, module.op, &.{
        .{ .total = 16777216, .schedule = .{ .threads = 256, .items = 16 } },
        .{ .schedule = .{ .threads = 512, .items = 16 } },
    });

    const encoded = readGeneratedScanSchedules(module.op) orelse return error.MissingScanSchedules;
    try testing.expectEqualStrings("16777216=256x16,512x16", encoded);

    const exact = (try resolveGeneratedScanSchedule(encoded, 16777216)) orelse return error.MissingScanSchedule;
    try testing.expect(exact.eql(.{ .threads = 256, .items = 16 }));

    const wildcard = (try resolveGeneratedScanSchedule(encoded, 8192)) orelse return error.MissingScanSchedule;
    try testing.expect(wildcard.eql(.{ .threads = 512, .items = 16 }));
}

test "generated scan schedule resolution rejects malformed encodings" {
    try testing.expectError(error.InvalidArtifact, resolveGeneratedScanSchedule("", 4096));
    try testing.expectError(error.InvalidArtifact, resolveGeneratedScanSchedule("512", 4096));
    try testing.expectError(error.InvalidArtifact, resolveGeneratedScanSchedule("4096=0x16", 4096));
    try testing.expectError(error.InvalidArtifact, resolveGeneratedScanSchedule("abc=512x16", 4096));
    try testing.expectEqual(@as(?GeneratedScanSchedule, null), try resolveGeneratedScanSchedule("8192=512x16", 4096));
}

test "generated row pipeline schedule decisions round trip through module attrs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module = try choir.dialects.builtin.BuiltinDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    try setGeneratedRowPipelineSchedules(allocator, &ctx, module.op, &.{
        .{ .shape = .{ .rows = 4096, .cols = 4096 }, .schedule = .{ .threads = 512 } },
        .{ .schedule = .{ .threads = 128 } },
    });

    const encoded = readGeneratedRowPipelineSchedules(module.op) orelse return error.MissingRowPipelineSchedules;
    try testing.expectEqualStrings("4096x4096=512,128", encoded);

    const exact = (try resolveGeneratedRowPipelineSchedule(encoded, 4096, 4096)) orelse return error.MissingRowPipelineSchedule;
    try testing.expect(exact.eql(.{ .threads = 512 }));

    const wildcard = (try resolveGeneratedRowPipelineSchedule(encoded, 8, 2048)) orelse return error.MissingRowPipelineSchedule;
    try testing.expect(wildcard.eql(.{ .threads = 128 }));
}

test "generated row pipeline schedule resolution rejects malformed encodings" {
    try testing.expectError(error.InvalidArtifact, resolveGeneratedRowPipelineSchedule("", 4, 1024));
    try testing.expectError(error.InvalidArtifact, resolveGeneratedRowPipelineSchedule("4096=512", 4, 1024));
    try testing.expectError(error.InvalidArtifact, resolveGeneratedRowPipelineSchedule("4x1024=0", 4, 1024));
    try testing.expectEqual(@as(?GeneratedRowPipelineSchedule, null), try resolveGeneratedRowPipelineSchedule("8x2048=512", 4, 1024));
}

test "backend target profile gates tf32 tensor math on cuda tensor cores" {
    const caps = gpu.BackendCapabilities{
        .identity = .{
            .backend = .cuda,
            .family = .nvidia_cuda,
        },
        .dtypes = gpu.DTypeSet.init(&.{.f32}),
        .features = .{ .tensor_cores = true },
        .artifact_formats = gpu.ArtifactFormatSet.init(&.{.cuda_ptx}),
    };
    const profile = try BackendTargetProfile.initWithMathTier(caps, .cuda, .cuda_ptx, .tf32_tensor);
    try testing.expectEqual(gpu.BackendMathTier.tf32_tensor, profile.math_tier);
    try testing.expect(profile.isSupportedBy(caps));

    var no_tensor = caps;
    no_tensor.features.tensor_cores = false;
    try testing.expectError(error.CapabilityMismatch, BackendTargetProfile.initWithMathTier(no_tensor, .cuda, .cuda_ptx, .tf32_tensor));
}
