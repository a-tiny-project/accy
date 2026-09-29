const std = @import("std");
const pretty_json = @import("pretty").json;

pub const schema = "choir.versus/v2";

pub const Unit = enum {
    ns,
    count,
    bytes,

    pub fn name(self: Unit) []const u8 {
        return @tagName(self);
    }
};

pub const Metric = enum {
    kernel_ns,
    compile_ns,
    compile_ir_ns,
    compile_pass_ns,
    compile_jit_ns,
    compile_alloc_count,
    compile_alloc_bytes,
    compile_ir_ops,
    compile_ir_blocks,
    compile_ir_values,
    compile_pass_count,
    code_bytes,
    inst_count,

    pub fn name(self: Metric) []const u8 {
        return switch (self) {
            .kernel_ns => "kernel_ns",
            .compile_ns => "compile_ns",
            .compile_ir_ns => "compile_ir_ns",
            .compile_pass_ns => "compile_pass_ns",
            .compile_jit_ns => "compile_jit_ns",
            .compile_alloc_count => "compile_alloc_count",
            .compile_alloc_bytes => "compile_alloc_bytes",
            .compile_ir_ops => "compile_ir_ops",
            .compile_ir_blocks => "compile_ir_blocks",
            .compile_ir_values => "compile_ir_values",
            .compile_pass_count => "compile_pass_count",
            .code_bytes => "code_bytes",
            .inst_count => "inst_count",
        };
    }

    pub fn unit(self: Metric) Unit {
        return switch (self) {
            .kernel_ns,
            .compile_ns,
            .compile_ir_ns,
            .compile_pass_ns,
            .compile_jit_ns,
            => .ns,
            .compile_alloc_bytes,
            .code_bytes,
            => .bytes,
            .compile_alloc_count,
            .compile_ir_ops,
            .compile_ir_blocks,
            .compile_ir_values,
            .compile_pass_count,
            .inst_count,
            => .count,
        };
    }

    pub fn valueField(self: Metric) ?[]const u8 {
        return switch (self) {
            .compile_ir_ns => "compile_ir_ns",
            .compile_pass_ns => "compile_pass_ns",
            .compile_jit_ns => "compile_jit_ns",
            .compile_alloc_count => "compile_alloc_count",
            .compile_alloc_bytes => "compile_alloc_bytes",
            .compile_ir_ops => "compile_ir_ops",
            .compile_ir_blocks => "compile_ir_blocks",
            .compile_ir_values => "compile_ir_values",
            .compile_pass_count => "compile_pass_count",
            .code_bytes => "code_bytes",
            .inst_count => "inst_count",
            .kernel_ns,
            .compile_ns,
            => null,
        };
    }

    pub fn p10Field(self: Metric) ?[]const u8 {
        return switch (self) {
            .compile_ir_ns => "compile_ir_p10_ns",
            .compile_pass_ns => "compile_pass_p10_ns",
            .compile_jit_ns => "compile_jit_p10_ns",
            .compile_alloc_count => "compile_alloc_count_p10",
            .compile_alloc_bytes => "compile_alloc_bytes_p10",
            else => null,
        };
    }

    pub fn p90Field(self: Metric) ?[]const u8 {
        return switch (self) {
            .compile_ir_ns => "compile_ir_p90_ns",
            .compile_pass_ns => "compile_pass_p90_ns",
            .compile_jit_ns => "compile_jit_p90_ns",
            .compile_alloc_count => "compile_alloc_count_p90",
            .compile_alloc_bytes => "compile_alloc_bytes_p90",
            else => null,
        };
    }

    pub fn parse(text: []const u8) ?Metric {
        inline for (std.meta.tags(Metric)) |value| {
            if (std.mem.eql(u8, text, value.name())) return value;
        }
        return null;
    }
};

pub const Row = struct {
    system: []const u8,
    workload: []const u8,
    metric: Metric,
    samples: u32,
    median_ns: u64,
    p10_ns: u64,
    p90_ns: u64,
    flops: u64,
    moved_bytes: u64,
    instructions: u64 = 0,
    cycles: u64 = 0,
    code_bytes: u64 = 0,
    inst_count: u64 = 0,
    mca_rthroughput: f64 = 0,
    compile_ir_ns: u64 = 0,
    compile_ir_p10_ns: u64 = 0,
    compile_ir_p90_ns: u64 = 0,
    compile_pass_ns: u64 = 0,
    compile_pass_p10_ns: u64 = 0,
    compile_pass_p90_ns: u64 = 0,
    compile_jit_ns: u64 = 0,
    compile_jit_p10_ns: u64 = 0,
    compile_jit_p90_ns: u64 = 0,
    compile_alloc_count: u64 = 0,
    compile_alloc_count_p10: u64 = 0,
    compile_alloc_count_p90: u64 = 0,
    compile_alloc_bytes: u64 = 0,
    compile_alloc_bytes_p10: u64 = 0,
    compile_alloc_bytes_p90: u64 = 0,
    compile_ir_ops: u64 = 0,
    compile_ir_blocks: u64 = 0,
    compile_ir_values: u64 = 0,
    compile_pass_count: u64 = 0,
    note: ?[]const u8 = null,
};

pub fn writeRow(writer: *std.Io.Writer, row: Row) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("system", row.system);
    try object.field("workload", row.workload);
    try object.field("metric", row.metric.name());
    try object.field("unit", row.metric.unit().name());
    try object.field("samples", row.samples);
    try object.field("median_ns", row.median_ns);
    try object.field("p10_ns", row.p10_ns);
    try object.field("p90_ns", row.p90_ns);
    try object.field("flops", row.flops);
    try object.field("moved_bytes", row.moved_bytes);
    try object.field("instructions", row.instructions);
    try object.field("cycles", row.cycles);
    try object.field("code_bytes", row.code_bytes);
    try object.field("inst_count", row.inst_count);
    try writeCompileFields(object, row);
    if (row.mca_rthroughput > 0) {
        try object.print("mca_rthroughput", "{d:.2}", .{row.mca_rthroughput});
    }
    if (row.note) |note| try object.field("note", note);
    try object.endLine();
}

pub fn writeMeta(writer: *std.Io.Writer, system: []const u8, host: []const u8, detail: []const u8) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("system", system);
    try object.field("meta", true);
    try object.field("host", host);
    try object.field("detail", detail);
    try object.endLine();
}

pub const CompileTrace = struct {
    system: []const u8,
    workload: []const u8,
    sample: usize,
    total_ns: u64,
    pass_ordinal: u64,
    pass_name: []const u8,
    pass_ns: u64,
    modified: bool,
    op_count_before: u64 = 0,
    op_count_after: u64 = 0,
    op_count_delta: i128 = 0,
    alloc_count: u64 = 0,
    free_count: u64 = 0,
    alloc_bytes: u64 = 0,
};

pub fn writeCompileTrace(writer: *std.Io.Writer, trace: CompileTrace) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("event", "compile_trace");
    try object.field("system", trace.system);
    try object.field("workload", trace.workload);
    try object.field("sample", trace.sample);
    try object.field("total_ns", trace.total_ns);
    try object.field("pass_ordinal", trace.pass_ordinal);
    try object.field("pass_name", trace.pass_name);
    try object.field("pass_ns", trace.pass_ns);
    try object.field("modified", trace.modified);
    try object.field("op_count_before", trace.op_count_before);
    try object.field("op_count_after", trace.op_count_after);
    try object.field("op_count_delta", trace.op_count_delta);
    try object.field("alloc_count", trace.alloc_count);
    try object.field("free_count", trace.free_count);
    try object.field("alloc_bytes", trace.alloc_bytes);
    try object.endLine();
}

pub fn writeProfilingMetrics(writer: *std.Io.Writer, row: Row) !void {
    if (row.metric.unit() == .ns) {
        try writeProfilingTiming(writer, row, row.metric, row.median_ns, row.p10_ns, row.p90_ns);
    }
    if (row.metric != .compile_ns) return;

    inline for (std.meta.tags(Metric)) |metric| {
        if (metric.valueField()) |value_field| {
            const value = valueFromRow(row, value_field);
            if (value != 0) {
                switch (metric.unit()) {
                    .ns => try writeProfilingTiming(
                        writer,
                        row,
                        metric,
                        value,
                        if (metric.p10Field()) |p10_field| valueFromRow(row, p10_field) else value,
                        if (metric.p90Field()) |p90_field| valueFromRow(row, p90_field) else value,
                    ),
                    .bytes, .count => {
                        if (metric == .compile_alloc_bytes or metric == .compile_alloc_count) {
                            try writeProfilingMemory(writer, row, metric, value);
                        }
                    },
                }
            }
        }
    }
}

fn writeProfilingTiming(writer: *std.Io.Writer, row: Row, metric: Metric, median: u64, p10: u64, p90: u64) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", "tiny.profiling.metric/v1");
    try object.field("family", "timing");
    try object.field("metric", metric.name());
    try object.field("unit", "ns");
    try object.field("workload", row.workload);
    try object.field("system", row.system);
    try object.stringParts("name", &.{ row.system, "/", row.workload, "/", metric.name() });
    try object.field("sample_count", row.samples);
    try object.field("median_ns", median);
    try object.field("p10_ns", p10);
    try object.field("p90_ns", p90);
    try object.endLine();
}

fn writeProfilingMemory(writer: *std.Io.Writer, row: Row, metric: Metric, value: u64) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", "tiny.profiling.metric/v1");
    try object.field("family", "memory");
    try object.field("metric", metric.name());
    try object.field("unit", metric.unit().name());
    try object.field("workload", row.workload);
    try object.field("system", row.system);
    try object.stringParts("name", &.{ row.system, "/", row.workload, "/", metric.name() });
    try object.field("sample_count", row.samples);
    try object.field("value", value);
    try object.endLine();
}

fn writeCompileFields(object: pretty_json.Object, row: Row) !void {
    try object.field("compile_ir_ns", row.compile_ir_ns);
    try object.field("compile_ir_p10_ns", row.compile_ir_p10_ns);
    try object.field("compile_ir_p90_ns", row.compile_ir_p90_ns);
    try object.field("compile_pass_ns", row.compile_pass_ns);
    try object.field("compile_pass_p10_ns", row.compile_pass_p10_ns);
    try object.field("compile_pass_p90_ns", row.compile_pass_p90_ns);
    try object.field("compile_jit_ns", row.compile_jit_ns);
    try object.field("compile_jit_p10_ns", row.compile_jit_p10_ns);
    try object.field("compile_jit_p90_ns", row.compile_jit_p90_ns);
    try object.field("compile_alloc_count", row.compile_alloc_count);
    try object.field("compile_alloc_count_p10", row.compile_alloc_count_p10);
    try object.field("compile_alloc_count_p90", row.compile_alloc_count_p90);
    try object.field("compile_alloc_bytes", row.compile_alloc_bytes);
    try object.field("compile_alloc_bytes_p10", row.compile_alloc_bytes_p10);
    try object.field("compile_alloc_bytes_p90", row.compile_alloc_bytes_p90);
    try object.field("compile_ir_ops", row.compile_ir_ops);
    try object.field("compile_ir_blocks", row.compile_ir_blocks);
    try object.field("compile_ir_values", row.compile_ir_values);
    try object.field("compile_pass_count", row.compile_pass_count);
}

fn valueFromRow(row: Row, field: []const u8) u64 {
    if (std.mem.eql(u8, field, "compile_ir_ns")) return row.compile_ir_ns;
    if (std.mem.eql(u8, field, "compile_ir_p10_ns")) return row.compile_ir_p10_ns;
    if (std.mem.eql(u8, field, "compile_ir_p90_ns")) return row.compile_ir_p90_ns;
    if (std.mem.eql(u8, field, "compile_pass_ns")) return row.compile_pass_ns;
    if (std.mem.eql(u8, field, "compile_pass_p10_ns")) return row.compile_pass_p10_ns;
    if (std.mem.eql(u8, field, "compile_pass_p90_ns")) return row.compile_pass_p90_ns;
    if (std.mem.eql(u8, field, "compile_jit_ns")) return row.compile_jit_ns;
    if (std.mem.eql(u8, field, "compile_jit_p10_ns")) return row.compile_jit_p10_ns;
    if (std.mem.eql(u8, field, "compile_jit_p90_ns")) return row.compile_jit_p90_ns;
    if (std.mem.eql(u8, field, "compile_alloc_count")) return row.compile_alloc_count;
    if (std.mem.eql(u8, field, "compile_alloc_count_p10")) return row.compile_alloc_count_p10;
    if (std.mem.eql(u8, field, "compile_alloc_count_p90")) return row.compile_alloc_count_p90;
    if (std.mem.eql(u8, field, "compile_alloc_bytes")) return row.compile_alloc_bytes;
    if (std.mem.eql(u8, field, "compile_alloc_bytes_p10")) return row.compile_alloc_bytes_p10;
    if (std.mem.eql(u8, field, "compile_alloc_bytes_p90")) return row.compile_alloc_bytes_p90;
    if (std.mem.eql(u8, field, "compile_ir_ops")) return row.compile_ir_ops;
    if (std.mem.eql(u8, field, "compile_ir_blocks")) return row.compile_ir_blocks;
    if (std.mem.eql(u8, field, "compile_ir_values")) return row.compile_ir_values;
    if (std.mem.eql(u8, field, "compile_pass_count")) return row.compile_pass_count;
    if (std.mem.eql(u8, field, "code_bytes")) return row.code_bytes;
    if (std.mem.eql(u8, field, "inst_count")) return row.inst_count;
    return 0;
}

pub const Samples = struct {
    sorted: []u64,

    pub fn init(values: []u64) Samples {
        std.mem.sort(u64, values, {}, std.sort.asc(u64));
        return .{ .sorted = values };
    }

    pub fn median(self: Samples) u64 {
        return self.sorted[self.sorted.len / 2];
    }

    pub fn p10(self: Samples) u64 {
        return self.sorted[self.sorted.len / 10];
    }

    pub fn p90(self: Samples) u64 {
        return self.sorted[(self.sorted.len * 9) / 10];
    }
};

test "metric names round-trip" {
    inline for (std.meta.tags(Metric)) |value| {
        try std.testing.expectEqual(value, Metric.parse(value.name()).?);
    }
    try std.testing.expect(Metric.parse("bogus") == null);
}

test "samples report order statistics" {
    var values = [_]u64{ 5, 1, 9, 3, 7, 2, 8, 4, 6, 10 };
    const samples = Samples.init(values[0..]);
    try std.testing.expectEqual(@as(u64, 6), samples.median());
    try std.testing.expectEqual(@as(u64, 2), samples.p10());
    try std.testing.expectEqual(@as(u64, 10), samples.p90());
}

test "writeRow emits one parsable json line" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0..]);
    try writeRow(&writer, .{
        .system = "choir",
        .workload = "saxpy_f32_1m",
        .metric = .kernel_ns,
        .samples = 20,
        .median_ns = 100,
        .p10_ns = 90,
        .p90_ns = 110,
        .flops = 2097152,
        .moved_bytes = 12582912,
        .instructions = 5000,
        .cycles = 4000,
        .code_bytes = 96,
        .inst_count = 24,
        .compile_ir_ns = 10,
        .compile_ir_p10_ns = 9,
        .compile_ir_p90_ns = 11,
        .compile_pass_ns = 20,
        .compile_pass_p10_ns = 18,
        .compile_pass_p90_ns = 22,
        .compile_jit_ns = 70,
        .compile_jit_p10_ns = 66,
        .compile_jit_p90_ns = 77,
        .compile_alloc_count = 12,
        .compile_alloc_bytes = 4096,
        .compile_ir_ops = 30,
        .compile_ir_blocks = 7,
        .compile_ir_values = 36,
        .compile_pass_count = 11,
        .note = "pipeline=\"choir\"\ncleanup",
    });
    const written = writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, written, "}\n"));

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, written[0 .. written.len - 1], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("choir", parsed.value.object.get("system").?.string);
    try std.testing.expectEqual(@as(i64, 24), parsed.value.object.get("inst_count").?.integer);
    try std.testing.expectEqual(@as(i64, 10), parsed.value.object.get("compile_ir_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 4096), parsed.value.object.get("compile_alloc_bytes").?.integer);
    try std.testing.expectEqualStrings(
        "pipeline=\"choir\"\ncleanup",
        parsed.value.object.get("note").?.string,
    );
}

test "writeProfilingMetrics emits strict profile metric rows" {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0..]);
    try writeProfilingMetrics(&writer, .{
        .system = "choir",
        .workload = "compile_arith_1x32",
        .metric = .compile_ns,
        .samples = 5,
        .median_ns = 1000,
        .p10_ns = 900,
        .p90_ns = 1100,
        .flops = 0,
        .moved_bytes = 0,
        .compile_ir_ns = 100,
        .compile_ir_p10_ns = 90,
        .compile_ir_p90_ns = 110,
        .compile_pass_ns = 200,
        .compile_pass_p10_ns = 180,
        .compile_pass_p90_ns = 220,
        .compile_jit_ns = 700,
        .compile_jit_p10_ns = 690,
        .compile_jit_p90_ns = 710,
        .compile_alloc_count = 12,
        .compile_alloc_bytes = 4096,
    });
    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"schema\":\"tiny.profiling.metric/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"metric\":\"compile_ir_ns\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"family\":\"memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"metric\":\"compile_alloc_bytes\"") != null);
}
