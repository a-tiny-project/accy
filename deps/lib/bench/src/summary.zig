const std = @import("std");
const pretty_json = @import("pretty").json;

const jsonl_mod = @import("jsonl.zig");
const stats_mod = @import("stats/root.zig");

pub const Unit = jsonl_mod.Unit;

pub const Record = struct {
    benchmark: []const u8,
    summary: []const u8,
    name: []const u8,
    samples: u64,
    stats: stats_mod.SampleStats,
    units: []const Unit,
};

pub const PassIrMeans = struct {
    before: f64,
    after: f64,
    delta: f64,
};

pub const PassMemoryMeans = struct {
    alloc_count: f64,
    free_count: f64,
    alloc_bytes: f64,
};

pub const PassRecord = struct {
    benchmark: []const u8,
    name: []const u8,
    samples: u64,
    pass_ir_sizes: bool,
    stats: stats_mod.SampleStats,
    units: []const Unit,
    ir: PassIrMeans,
    memory: PassMemoryMeans,
};

pub fn passIrMeans(totals: anytype, index: usize, sample_count: u32) PassIrMeans {
    return .{
        .before = totals.meanBefore(index, sample_count),
        .after = totals.meanAfter(index, sample_count),
        .delta = totals.meanDelta(index, sample_count),
    };
}

pub fn passMemoryMeans(totals: anytype, index: usize, sample_count: u32) PassMemoryMeans {
    return .{
        .alloc_count = totals.meanAllocCount(index, sample_count),
        .free_count = totals.meanFreeCount(index, sample_count),
        .alloc_bytes = totals.meanAllocBytes(index, sample_count),
    };
}

pub fn writeTiming(writer: *std.Io.Writer, record: Record, identity: anytype) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try writeHeader(object, record.benchmark, record.summary, record.name);
    try identity.writeBeforeSamples(object);
    try object.field("samples", record.samples);
    try identity.writeAfterSamples(object);
    try writeTimingStats(object, record.stats, record.units);
    try object.endLine();
}

pub fn writeMemory(writer: *std.Io.Writer, record: Record, identity: anytype) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try writeHeader(object, record.benchmark, "memory", record.name);
    try identity.writeBeforeSamples(object);
    try object.field("samples", record.samples);
    try identity.writeAfterSamples(object);
    try writeMemoryStats(object, record.stats, record.units);
    try object.endLine();
}

pub fn writePass(writer: *std.Io.Writer, record: PassRecord, identity: anytype) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try writeHeader(object, record.benchmark, "pass", record.name);
    try identity.writeBeforeSamples(object);
    try object.field("samples", record.samples);
    try identity.writeAfterSamples(object);
    try object.field("pass_ir_sizes", record.pass_ir_sizes);
    try object.field("min_ns", record.stats.min_ns);
    try object.field("median_ns", record.stats.median_ns);
    try object.field("mean_ns", record.stats.mean_ns);
    try jsonl_mod.writePerUnitFields(object, "mean_ns", record.stats.mean_ns, record.units);
    try object.field("mean_pass_choir_ops_before", record.ir.before);
    try object.field("mean_pass_choir_ops_after", record.ir.after);
    try object.field("mean_pass_choir_op_delta", record.ir.delta);
    try object.field("mean_alloc_count", record.memory.alloc_count);
    try object.field("mean_free_count", record.memory.free_count);
    try object.field("mean_alloc_bytes", record.memory.alloc_bytes);
    try jsonl_mod.writePerUnitFields(
        object,
        "mean_alloc_bytes",
        record.memory.alloc_bytes,
        record.units,
    );
    try writePassRates(object, record);
    try writeTimingTail(object, record.stats);
    try object.endLine();
}

fn writePassRates(object: pretty_json.Object, record: PassRecord) !void {
    try object.field(
        "mean_alloc_bytes_per_pass_choir_op_before",
        stats_mod.valuePerFloatUnit(record.memory.alloc_bytes, record.ir.before),
    );
    try object.field(
        "mean_alloc_bytes_per_pass_choir_op_after",
        stats_mod.valuePerFloatUnit(record.memory.alloc_bytes, record.ir.after),
    );
    try object.field(
        "mean_ns_per_pass_choir_op_before",
        stats_mod.nsPerFloatUnit(record.stats.mean_ns, record.ir.before),
    );
    try object.field(
        "mean_ns_per_pass_choir_op_after",
        stats_mod.nsPerFloatUnit(record.stats.mean_ns, record.ir.after),
    );
}

fn writeHeader(
    object: pretty_json.Object,
    benchmark: []const u8,
    summary: []const u8,
    name: []const u8,
) !void {
    try object.field("kind", "summary");
    try object.field("benchmark", benchmark);
    try object.field("summary", summary);
    try object.field("name", name);
}

fn writeTimingStats(
    object: pretty_json.Object,
    sample_stats: stats_mod.SampleStats,
    units: []const Unit,
) !void {
    try object.field("min_ns", sample_stats.min_ns);
    try object.field("median_ns", sample_stats.median_ns);
    try object.field("mean_ns", sample_stats.mean_ns);
    try jsonl_mod.writePerUnitFields(object, "mean_ns", sample_stats.mean_ns, units);
    try writeTimingTail(object, sample_stats);
}

fn writeTimingTail(object: pretty_json.Object, sample_stats: stats_mod.SampleStats) !void {
    try object.field("p95_ns", sample_stats.p95_ns);
    try object.field("p99_ns", sample_stats.p99_ns);
    try object.field("max_ns", sample_stats.max_ns);
    try object.field("total_ns", sample_stats.total_ns);
}

fn writeMemoryStats(
    object: pretty_json.Object,
    sample_stats: stats_mod.SampleStats,
    units: []const Unit,
) !void {
    try object.field("min", sample_stats.min_ns);
    try object.field("median", sample_stats.median_ns);
    try object.field("mean", sample_stats.mean_ns);
    try jsonl_mod.writePerUnitFields(object, "mean", sample_stats.mean_ns, units);
    try object.field("p95", sample_stats.p95_ns);
    try object.field("p99", sample_stats.p99_ns);
    try object.field("max", sample_stats.max_ns);
    try object.field("total", sample_stats.total_ns);
}

const TestIdentity = struct {
    pub fn writeBeforeSamples(_: @This(), object: pretty_json.Object) !void {
        try object.field("workload", "demo");
    }

    pub fn writeAfterSamples(_: @This(), object: pretty_json.Object) !void {
        try object.field("source_ops", 4);
    }
};

test "timing summary writes stats and unit rates" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const units = [_]Unit{
        .{ .name = "source_op", .count = 4 },
        .{ .name = "final_choir_op", .count = 8 },
    };
    try writeTiming(&out.writer, .{
        .benchmark = "bench.demo",
        .summary = "phase",
        .name = "total",
        .samples = 2,
        .stats = sampleStats(),
        .units = &units,
    }, TestIdentity{});

    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"summary\":\"phase\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"workload\":\"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"mean_ns_per_source_op\":30") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"mean_ns_per_final_choir_op\":15") != null);
}

test "pass summary writes IR and allocation means" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const units = [_]Unit{.{ .name = "source_op", .count = 4 }};
    try writePass(&out.writer, .{
        .benchmark = "bench.demo",
        .name = "pass",
        .samples = 2,
        .pass_ir_sizes = true,
        .stats = sampleStats(),
        .units = &units,
        .ir = .{ .before = 2, .after = 4, .delta = 2 },
        .memory = .{ .alloc_count = 2, .free_count = 1, .alloc_bytes = 64 },
    }, TestIdentity{});

    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"pass_ir_sizes\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"mean_pass_choir_ops_before\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"mean_alloc_bytes_per_source_op\":16") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"mean_ns_per_pass_choir_op_after\":30") != null);
}

fn sampleStats() stats_mod.SampleStats {
    return .{
        .min_ns = 100,
        .max_ns = 140,
        .mean_ns = 120,
        .median_ns = 100,
        .p75_ns = 140,
        .p95_ns = 140,
        .p99_ns = 140,
        .total_ns = 240,
    };
}
