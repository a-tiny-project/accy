const std = @import("std");
const pretty_json = @import("pretty").json;
const sys = @import("sys");
const roots_mod = @import("roots.zig");

const Allocator = std.mem.Allocator;
const schema = "tiny.memtrace.causal-budget/v1";
const max_budget_bytes: usize = 64 * 1024;
const max_report_line_bytes: usize = 256 * 1024;

pub const Format = enum {
    text,
    jsonl,
};

pub const Outcome = struct {
    passed: bool,
    checks: u32,
    failures: u32,
};

const Values = struct {
    roots: u128 = 0,
    root_requested_bytes: u128 = 0,
    backing_requested_bytes: u128 = 0,
    high_water_live_bytes: u128 = 0,
};

const Limits = struct {
    roots: ?u128 = null,
    root_requested_bytes: ?u128 = null,
    backing_requested_bytes: ?u128 = null,
    high_water_live_bytes: ?u128 = null,
};

const SourceRule = struct {
    name: []const u8,
    site_function_contains: ?[]const u8,
    caller_function_contains: ?[]const u8,
    caller_owner_function_contains: ?[]const u8,
    min_source_groups: u32,
    max_source_groups: u32,
    limits: Limits,
};

const Budget = struct {
    name: []const u8,
    totals: Limits,
    sources: []const SourceRule,
};

const SourceResult = struct {
    values: Values = .{},
    matched_groups: u32 = 0,
};

const Evaluation = struct {
    allocator: Allocator,
    budget: Budget,
    totals: ?Values = null,
    source_results: []SourceResult,
    summary_status_complete: bool = false,
    sources_complete: bool = false,

    fn init(allocator: Allocator, budget: Budget) !Evaluation {
        const results = try allocator.alloc(SourceResult, budget.sources.len);
        @memset(results, .{});
        return .{
            .allocator = allocator,
            .budget = budget,
            .source_results = results,
        };
    }

    fn ingest(self: *Evaluation, line: []const u8) !void {
        const row = try parseReportRow(struct { kind: []const u8 }, self.allocator, line);
        defer row.deinit();
        if (std.mem.eql(u8, row.value.kind, "causal_root_summary")) {
            if (self.totals != null) return error.DuplicateCausalRootSummary;
            const summary = try parseReportRow(
                roots_mod.SummaryRecord,
                self.allocator,
                line,
            );
            defer summary.deinit();
            self.summary_status_complete = std.mem.eql(
                u8,
                summary.value.status,
                "process_memory_operation_complete",
            );
            self.sources_complete = summary.value.source_groups ==
                summary.value.displayed_sources;
            self.totals = recordValues(summary.value);
            return;
        }
        if (!std.mem.eql(u8, row.value.kind, "causal_root_source")) return;
        const source = try parseReportRow(
            roots_mod.SourceRecord,
            self.allocator,
            line,
        );
        defer source.deinit();
        const site = source.value.site_function orelse
            return error.InvalidCausalBudget;
        const caller = source.value.caller_function;
        const caller_owner = source.value.caller_owner_function;
        const actual = recordValues(source.value);
        for (self.budget.sources, self.source_results) |rule, *result| {
            if (rule.site_function_contains) |expected| {
                if (!std.mem.containsAtLeast(
                    u8,
                    site,
                    1,
                    expected,
                )) {
                    continue;
                }
            }
            if (rule.caller_function_contains) |expected| {
                const actual_caller = caller orelse continue;
                if (!std.mem.containsAtLeast(
                    u8,
                    actual_caller,
                    1,
                    expected,
                )) {
                    continue;
                }
            }
            if (rule.caller_owner_function_contains) |expected| {
                const actual_owner = caller_owner orelse continue;
                if (!std.mem.containsAtLeast(
                    u8,
                    actual_owner,
                    1,
                    expected,
                )) {
                    continue;
                }
            }
            result.matched_groups = try std.math.add(
                u32,
                result.matched_groups,
                1,
            );
            try addValues(&result.values, actual);
        }
    }

    fn assess(
        self: *const Evaluation,
        writer: *std.Io.Writer,
        format: Format,
        report_path: []const u8,
    ) !Outcome {
        const totals = self.totals orelse
            return error.MissingCausalRootSummary;
        if (!self.sources_complete) return error.TruncatedCausalRootSources;
        var outcome = Outcome{
            .passed = self.summary_status_complete,
            .checks = 1,
            .failures = @intFromBool(!self.summary_status_complete),
        };
        try writeStatusCheck(
            writer,
            format,
            "capture",
            "complete",
            @intFromBool(self.summary_status_complete),
            1,
            self.summary_status_complete,
        );
        try assessLimits(
            writer,
            format,
            "total",
            totals,
            self.budget.totals,
            &outcome,
        );
        for (
            self.budget.sources,
            self.source_results,
        ) |rule, result| {
            const matched = result.matched_groups >= rule.min_source_groups and
                result.matched_groups <= rule.max_source_groups;
            outcome.checks = try std.math.add(u32, outcome.checks, 1);
            if (!matched) {
                outcome.passed = false;
                outcome.failures = try std.math.add(
                    u32,
                    outcome.failures,
                    1,
                );
            }
            try writeRangeCheck(
                writer,
                format,
                rule.name,
                "matched_source_groups",
                result.matched_groups,
                rule.min_source_groups,
                rule.max_source_groups,
                matched,
            );
            try assessLimits(
                writer,
                format,
                rule.name,
                result.values,
                rule.limits,
                &outcome,
            );
        }
        try writeOutcome(
            writer,
            format,
            self.budget.name,
            report_path,
            outcome,
        );
        return outcome;
    }
};

pub fn checkFromPaths(
    allocator: Allocator,
    report_path: []const u8,
    budget_path: []const u8,
    writer: *std.Io.Writer,
    format: Format,
) !Outcome {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const budget_bytes = try sys.fs.readFileAlloc(
        arena,
        budget_path,
        max_budget_bytes,
    );
    const budget = try parseBudget(arena, budget_bytes);
    var evaluation = try Evaluation.init(arena, budget);
    try ingestPath(&evaluation, report_path);
    return try evaluation.assess(writer, format, report_path);
}

fn ingestPath(evaluation: *Evaluation, path: []const u8) !void {
    var file = try sys.fs.cwd().openFile(sys.fs.debugIo(), path, .{});
    defer file.close(sys.fs.debugIo());
    var buffer: [max_report_line_bytes]u8 = undefined;
    var reader = file.reader(sys.fs.debugIo(), &buffer);
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        const actual = line orelse break;
        const trimmed = std.mem.trim(u8, actual, " \t\r");
        if (trimmed.len != 0) try evaluation.ingest(trimmed);
    }
}

/// A causal budget as its author writes it. Every limit is optional, and a
/// source matches exactly one group unless it says otherwise.
const BudgetRecord = struct {
    schema: []const u8,
    name: []const u8,
    totals: LimitsRecord,
    sources: []const SourceRuleRecord,
};

const LimitsRecord = struct {
    max_roots: ?u128 = null,
    max_root_requested_bytes: ?u128 = null,
    max_backing_requested_bytes: ?u128 = null,
    max_high_water_live_bytes: ?u128 = null,
};

const SourceRuleRecord = struct {
    name: []const u8,
    site_function_contains: ?[]const u8 = null,
    caller_function_contains: ?[]const u8 = null,
    caller_owner_function_contains: ?[]const u8 = null,
    min_source_groups: u32 = 1,
    max_source_groups: u32 = 1,
    max_roots: ?u128 = null,
    max_root_requested_bytes: ?u128 = null,
    max_backing_requested_bytes: ?u128 = null,
    max_high_water_live_bytes: ?u128 = null,
};

fn parseBudget(allocator: Allocator, bytes: []const u8) !Budget {
    const record = std.json.parseFromSliceLeaky(BudgetRecord, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| return budgetFault(allocator, bytes, err);
    if (!std.mem.eql(u8, record.schema, schema)) {
        return error.UnsupportedCausalBudgetSchema;
    }
    const sources = try allocator.alloc(SourceRule, record.sources.len);
    for (record.sources, sources) |row, *source| {
        source.* = .{
            .name = row.name,
            .site_function_contains = row.site_function_contains,
            .caller_function_contains = row.caller_function_contains,
            .caller_owner_function_contains = row.caller_owner_function_contains,
            .min_source_groups = row.min_source_groups,
            .max_source_groups = row.max_source_groups,
            .limits = recordLimits(row),
        };
        inline for (.{
            source.site_function_contains,
            source.caller_function_contains,
            source.caller_owner_function_contains,
        }) |selector| {
            if (selector) |text| {
                if (text.len == 0) return error.InvalidCausalBudget;
            }
        }
        if (source.name.len == 0 or !hasSourceSelector(source.*)) {
            return error.InvalidCausalBudget;
        }
        if (source.min_source_groups > source.max_source_groups) {
            return error.InvalidCausalBudget;
        }
    }
    return .{
        .name = record.name,
        .totals = recordLimits(record.totals),
        .sources = sources,
    };
}

/// Names the fault of a budget that did not parse. A malformed document
/// keeps its JSON error. A readable schema other than this reader's outranks
/// every field fault, as today. Any other fault is an invalid budget.
fn budgetFault(allocator: Allocator, bytes: []const u8, err: anyerror) error{
    OutOfMemory,
    SyntaxError,
    UnexpectedEndOfInput,
    DuplicateField,
    UnsupportedCausalBudgetSchema,
    InvalidCausalBudget,
} {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.SyntaxError,
        error.UnexpectedEndOfInput => return error.UnexpectedEndOfInput,
        error.DuplicateField => return error.DuplicateField,
        else => {},
    }
    const header = std.json.parseFromSliceLeaky(
        struct { schema: []const u8 },
        allocator,
        bytes,
        .{ .ignore_unknown_fields = true },
    ) catch |header_err| switch (header_err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCausalBudget,
    };
    if (!std.mem.eql(u8, header.schema, schema)) {
        return error.UnsupportedCausalBudgetSchema;
    }
    return error.InvalidCausalBudget;
}

/// Parses one report line into `Row`. A malformed line keeps its JSON error,
/// and a line that does not fit the row is an invalid report for the budget.
fn parseReportRow(
    comptime Row: type,
    allocator: Allocator,
    line: []const u8,
) error{
    OutOfMemory,
    SyntaxError,
    UnexpectedEndOfInput,
    DuplicateField,
    InvalidCausalBudget,
}!std.json.Parsed(Row) {
    return std.json.parseFromSlice(Row, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.SyntaxError,
        error.UnexpectedEndOfInput => return error.UnexpectedEndOfInput,
        error.DuplicateField => return error.DuplicateField,
        else => return error.InvalidCausalBudget,
    };
}

fn hasSourceSelector(source: SourceRule) bool {
    return source.site_function_contains != null or
        source.caller_function_contains != null or
        source.caller_owner_function_contains != null;
}

fn recordLimits(record: anytype) Limits {
    return .{
        .roots = record.max_roots,
        .root_requested_bytes = record.max_root_requested_bytes,
        .backing_requested_bytes = record.max_backing_requested_bytes,
        .high_water_live_bytes = record.max_high_water_live_bytes,
    };
}

fn recordValues(record: anytype) Values {
    return .{
        .roots = record.roots,
        .root_requested_bytes = record.root_requested_bytes,
        .backing_requested_bytes = record.backing_requested_bytes,
        .high_water_live_bytes = record.high_water_live_bytes,
    };
}

fn addValues(target: *Values, next: Values) !void {
    target.roots = try std.math.add(u128, target.roots, next.roots);
    target.root_requested_bytes = try std.math.add(
        u128,
        target.root_requested_bytes,
        next.root_requested_bytes,
    );
    target.backing_requested_bytes = try std.math.add(
        u128,
        target.backing_requested_bytes,
        next.backing_requested_bytes,
    );
    target.high_water_live_bytes = try std.math.add(
        u128,
        target.high_water_live_bytes,
        next.high_water_live_bytes,
    );
}

fn assessLimits(
    writer: *std.Io.Writer,
    format: Format,
    scope: []const u8,
    actual: Values,
    limits: Limits,
    outcome: *Outcome,
) !void {
    try assessLimit(
        writer,
        format,
        scope,
        "roots",
        actual.roots,
        limits.roots,
        outcome,
    );
    try assessLimit(
        writer,
        format,
        scope,
        "root_requested_bytes",
        actual.root_requested_bytes,
        limits.root_requested_bytes,
        outcome,
    );
    try assessLimit(
        writer,
        format,
        scope,
        "backing_requested_bytes",
        actual.backing_requested_bytes,
        limits.backing_requested_bytes,
        outcome,
    );
    try assessLimit(
        writer,
        format,
        scope,
        "high_water_live_bytes",
        actual.high_water_live_bytes,
        limits.high_water_live_bytes,
        outcome,
    );
}

fn assessLimit(
    writer: *std.Io.Writer,
    format: Format,
    scope: []const u8,
    metric: []const u8,
    actual: u128,
    maybe_maximum: ?u128,
    outcome: *Outcome,
) !void {
    const maximum = maybe_maximum orelse return;
    const passed = actual <= maximum;
    outcome.checks = try std.math.add(u32, outcome.checks, 1);
    if (!passed) {
        outcome.passed = false;
        outcome.failures = try std.math.add(u32, outcome.failures, 1);
    }
    try writeStatusCheck(
        writer,
        format,
        scope,
        metric,
        actual,
        maximum,
        passed,
    );
}

fn writeRangeCheck(
    writer: *std.Io.Writer,
    format: Format,
    scope: []const u8,
    metric: []const u8,
    actual: u128,
    minimum: u128,
    maximum: u128,
    passed: bool,
) !void {
    switch (format) {
        .text => try writer.print(
            "causal_budget_check scope={s} metric={s} actual={d} min={d} " ++
                "max={d} status={s}\n",
            .{
                scope,
                metric,
                actual,
                minimum,
                maximum,
                if (passed) "pass" else "fail",
            },
        ),
        .jsonl => {
            var stream = pretty_json.Writer.init(writer, .minified);
            const row = try stream.object();
            try row.field("kind", "causal_budget_check");
            try row.field("scope", scope);
            try row.field("metric", metric);
            try row.field("actual", actual);
            try row.field("min", minimum);
            try row.field("max", maximum);
            try row.field("status", if (passed) "pass" else "fail");
            try row.endLine();
        },
    }
}

fn writeStatusCheck(
    writer: *std.Io.Writer,
    format: Format,
    scope: []const u8,
    metric: []const u8,
    actual: u128,
    maximum: u128,
    passed: bool,
) !void {
    switch (format) {
        .text => try writer.print(
            "causal_budget_check scope={s} metric={s} actual={d} max={d} " ++
                "status={s}\n",
            .{
                scope,
                metric,
                actual,
                maximum,
                if (passed) "pass" else "fail",
            },
        ),
        .jsonl => {
            var stream = pretty_json.Writer.init(writer, .minified);
            const row = try stream.object();
            try row.field("kind", "causal_budget_check");
            try row.field("scope", scope);
            try row.field("metric", metric);
            try row.field("actual", actual);
            try row.field("max", maximum);
            try row.field("status", if (passed) "pass" else "fail");
            try row.endLine();
        },
    }
}

fn writeOutcome(
    writer: *std.Io.Writer,
    format: Format,
    name: []const u8,
    report_path: []const u8,
    outcome: Outcome,
) !void {
    switch (format) {
        .text => try writer.print(
            "causal_budget name={s} report={s} checks={d} failures={d} " ++
                "status={s}\n",
            .{
                name,
                report_path,
                outcome.checks,
                outcome.failures,
                if (outcome.passed) "pass" else "fail",
            },
        ),
        .jsonl => {
            var stream = pretty_json.Writer.init(writer, .minified);
            const row = try stream.object();
            try row.field("kind", "causal_budget");
            try row.field("name", name);
            try row.field("report", report_path);
            try row.field("checks", outcome.checks);
            try row.field("failures", outcome.failures);
            try row.field("status", if (outcome.passed) "pass" else "fail");
            try row.endLine();
        },
    }
}

test "causal budget keeps limits above the signed range" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const budget = try parseBudget(arena_state.allocator(),
        \\{"schema":"tiny.memtrace.causal-budget/v1","name":"wide",
        \\"totals":{"max_root_requested_bytes":1180591620717411303424},
        \\"sources":[{"name":"s","site_function_contains":"alloc",
        \\"max_high_water_live_bytes":18446744073709551616}]}
    );
    try std.testing.expectEqual(@as(?u128, 1 << 70), budget.totals.root_requested_bytes);
    try std.testing.expectEqual(@as(?u128, 1 << 64), budget.sources[0].limits.high_water_live_bytes);
}

test "causal budget enforces totals and one exact source group" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const budget = try parseBudget(arena,
        \\{
        \\  "schema":"tiny.memtrace.causal-budget/v1",
        \\  "name":"fixture",
        \\  "totals":{"max_roots":4,"max_high_water_live_bytes":64},
        \\  "sources":[{
        \\    "name":"tree",
        \\    "site_function_contains":"Tree.create",
        \\    "caller_function_contains":"compile",
        \\    "caller_owner_function_contains":"compileDecodedOnce",
        \\    "max_roots":2,
        \\    "max_root_requested_bytes":32,
        \\    "max_backing_requested_bytes":48,
        \\    "max_high_water_live_bytes":16
        \\  }]
        \\}
    );
    var evaluation = try Evaluation.init(arena, budget);
    try evaluation.ingest(
        \\{"kind":"causal_root_summary","status":"process_memory_operation_complete","roots":4,"root_requested_bytes":64,"backing_requested_bytes":48,"high_water_live_bytes":64,"source_groups":1,"displayed_sources":1}
    );
    try evaluation.ingest(
        \\{"kind":"causal_root_source","roots":2,"root_requested_bytes":32,"backing_requested_bytes":48,"high_water_live_bytes":16,"site_function":"Tree.create","caller_function":"Compiler.compile","caller_owner_function":"Compiler.compileDecodedOnce"}
    );
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const outcome = try evaluation.assess(
        &output.writer,
        .jsonl,
        "fixture.jsonl",
    );
    try std.testing.expect(outcome.passed);
    try std.testing.expectEqual(@as(u32, 0), outcome.failures);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "\"status\":\"pass\"",
    ) != null);
}

test "causal budget rejects a duplicated source match" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const budget = try parseBudget(arena,
        \\{"schema":"tiny.memtrace.causal-budget/v1","name":"fixture","totals":{},"sources":[{"name":"source","site_function_contains":"alloc"}]}
    );
    var evaluation = try Evaluation.init(arena, budget);
    try evaluation.ingest(
        \\{"kind":"causal_root_summary","status":"process_memory_operation_complete","roots":1,"root_requested_bytes":1,"backing_requested_bytes":1,"high_water_live_bytes":1,"source_groups":2,"displayed_sources":2}
    );
    const source =
        \\{"kind":"causal_root_source","roots":1,"root_requested_bytes":1,"backing_requested_bytes":1,"high_water_live_bytes":1,"site_function":"alloc"}
    ;
    try evaluation.ingest(source);
    try evaluation.ingest(source);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const outcome = try evaluation.assess(
        &output.writer,
        .text,
        "fixture.jsonl",
    );
    try std.testing.expect(!outcome.passed);
    try std.testing.expectEqual(@as(u32, 1), outcome.failures);
}

test "causal budget aggregates a bounded source group family" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const budget = try parseBudget(arena,
        \\{
        \\  "schema":"tiny.memtrace.causal-budget/v1",
        \\  "name":"fixture",
        \\  "totals":{},
        \\  "sources":[{
        \\    "name":"located",
        \\    "site_function_contains":"LocatedCloner",
        \\    "min_source_groups":2,
        \\    "max_source_groups":3,
        \\    "max_roots":5,
        \\    "max_high_water_live_bytes":48
        \\  }]
        \\}
    );
    var evaluation = try Evaluation.init(arena, budget);
    try evaluation.ingest(
        \\{"kind":"causal_root_summary","status":"process_memory_operation_complete","roots":5,"root_requested_bytes":80,"backing_requested_bytes":64,"high_water_live_bytes":48,"source_groups":2,"displayed_sources":2}
    );
    try evaluation.ingest(
        \\{"kind":"causal_root_source","roots":2,"root_requested_bytes":32,"backing_requested_bytes":16,"high_water_live_bytes":16,"site_function":"LocatedCloner.cloneExpr"}
    );
    try evaluation.ingest(
        \\{"kind":"causal_root_source","roots":3,"root_requested_bytes":48,"backing_requested_bytes":48,"high_water_live_bytes":32,"site_function":"LocatedCloner.cloneSite"}
    );
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const outcome = try evaluation.assess(
        &output.writer,
        .jsonl,
        "fixture.jsonl",
    );
    try std.testing.expect(outcome.passed);
    try std.testing.expectEqual(@as(u32, 0), outcome.failures);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "\"actual\":2,\"min\":2,\"max\":3",
    ) != null);
}

test "causal budget selects a complete caller family without a site filter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const budget = try parseBudget(arena,
        \\{
        \\  "schema":"tiny.memtrace.causal-budget/v1",
        \\  "name":"fixture",
        \\  "totals":{},
        \\  "sources":[{
        \\    "name":"owned-authorship",
        \\    "caller_function_contains":"value.own.Cloner.cloneExpr",
        \\    "min_source_groups":2,
        \\    "max_source_groups":2,
        \\    "max_roots":5,
        \\    "max_high_water_live_bytes":48
        \\  }]
        \\}
    );
    var evaluation = try Evaluation.init(arena, budget);
    try evaluation.ingest(
        \\{"kind":"causal_root_summary","status":"process_memory_operation_complete","roots":6,"root_requested_bytes":96,"backing_requested_bytes":64,"high_water_live_bytes":64,"source_groups":3,"displayed_sources":3}
    );
    try evaluation.ingest(
        \\{"kind":"causal_root_source","roots":2,"root_requested_bytes":32,"backing_requested_bytes":16,"high_water_live_bytes":16,"site_function":"LocatedCloner.cloneExpr","caller_function":"value.own.Cloner.cloneExpr"}
    );
    try evaluation.ingest(
        \\{"kind":"causal_root_source","roots":3,"root_requested_bytes":48,"backing_requested_bytes":48,"high_water_live_bytes":32,"site_function":"LocatedCloner.cloneSite","caller_function":"value.own.Cloner.cloneExpr"}
    );
    try evaluation.ingest(
        \\{"kind":"causal_root_source","roots":1,"root_requested_bytes":16,"backing_requested_bytes":0,"high_water_live_bytes":16,"site_function":"LocatedCloner.cloneExpr","caller_function":"other.Cloner.cloneExpr"}
    );
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const outcome = try evaluation.assess(
        &output.writer,
        .jsonl,
        "fixture.jsonl",
    );
    try std.testing.expect(outcome.passed);
    try std.testing.expectEqual(@as(u32, 0), outcome.failures);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "\"actual\":2,\"min\":2,\"max\":2",
    ) != null);
}

test "causal budget rejects an inverted source group range" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(
        error.InvalidCausalBudget,
        parseBudget(arena,
            \\{
            \\  "schema":"tiny.memtrace.causal-budget/v1",
            \\  "name":"fixture",
            \\  "totals":{},
            \\  "sources":[{
            \\    "name":"located",
            \\    "site_function_contains":"LocatedCloner",
            \\    "min_source_groups":3,
            \\    "max_source_groups":2
            \\  }]
            \\}
        ),
    );
}

test "causal budget rejects a source rule without a selector" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(
        error.InvalidCausalBudget,
        parseBudget(arena,
            \\{
            \\  "schema":"tiny.memtrace.causal-budget/v1",
            \\  "name":"fixture",
            \\  "totals":{},
            \\  "sources":[{"name":"everything"}]
            \\}
        ),
    );
    try std.testing.expectError(
        error.InvalidCausalBudget,
        parseBudget(arena,
            \\{
            \\  "schema":"tiny.memtrace.causal-budget/v1",
            \\  "name":"fixture",
            \\  "totals":{},
            \\  "sources":[{
            \\    "name":"everything",
            \\    "caller_function_contains":""
            \\  }]
            \\}
        ),
    );
}
