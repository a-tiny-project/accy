const std = @import("std");
const model = @import("model.zig");
const digest = @import("digest.zig");
const equal = std.mem.eql;

pub fn suite(
    declaration: model.Recipe,
    expected: model.Suite,
    token: []const u8,
    zig_version: []const u8,
    evidence: model.Evidence,
) !model.Summary {
    const selected = evidence.selection;
    const result = evidence.result;
    if (!equal(u8, selected.schema, model.selection_schema) or
        !equal(u8, result.schema, model.result_schema)) return error.InvalidValidationSchema;
    try verifyBinding(declaration, expected, token, zig_version, selected.binding);
    inline for (comptime std.meta.fieldNames(model.Binding)) |field| {
        if (!equal(u8, @field(selected.binding, field), @field(result.binding, field))) {
            return error.ValidationBindingMismatch;
        }
    }
    if (selected.tests.len == 0 or selected.tests.len > model.max_tests) {
        return error.EmptyValidationSelection;
    }
    if (selected.tests.len != selected.selected_test_count or
        result.tests.len != selected.tests.len or
        result.completed_test_count != result.tests.len) return error.IncompleteValidationRun;
    try verifyDigests(selected, result);
    const summary = try counts(selected.tests, result.tests);
    if (summary.selected != selected.selected_behavioral_test_count or
        summary.completed != result.completed_behavioral_test_count or
        summary.passed != result.passed_behavioral_test_count or
        summary.skipped != result.skipped_test_count or
        summary.failed != result.failed_test_count or
        summary.leaked != result.leaked_test_count) return error.InvalidValidationCounts;
    return summary;
}

pub fn recipe(
    declaration: model.Recipe,
    token: []const u8,
    zig_version: []const u8,
    evidence: []const model.Evidence,
) !model.Summary {
    if (declaration.suites.len == 0 or declaration.suites.len > model.max_suites or
        evidence.len != declaration.suites.len) return error.IncompleteValidationSuites;
    var total: model.Summary = .{};
    for (declaration.suites, evidence) |expected, actual| {
        const summary = try suite(declaration, expected, token, zig_version, actual);
        inline for (comptime std.meta.fieldNames(model.Summary)) |field| {
            @field(total, field) += @field(summary, field);
        }
    }
    return total;
}

fn verifyBinding(
    declaration: model.Recipe,
    expected: model.Suite,
    token: []const u8,
    zig_version: []const u8,
    binding: model.Binding,
) !void {
    if (!equal(u8, binding.recipe_id, declaration.id) or
        !equal(u8, binding.recipe_sha256, &digest.recipe(declaration)) or
        !equal(u8, binding.suite_id, expected.id) or
        !equal(u8, binding.class, declaration.class) or
        !equal(u8, binding.token, token) or
        !equal(u8, binding.backend, expected.backend) or
        !equal(u8, binding.optimize, declaration.optimize) or
        !equal(u8, binding.zig_version, zig_version) or
        !equal(u8, binding.target, model.host_target))
    {
        return error.ValidationBindingMismatch;
    }
    const llvm = equal(u8, binding.compiler_backend, "stage2_llvm");
    if (llvm != equal(u8, expected.backend, "llvm")) return error.ValidationBackendMismatch;
    if (!llvm and !std.mem.startsWith(u8, binding.compiler_backend, "stage2_")) {
        return error.ValidationBackendMismatch;
    }
}

fn verifyDigests(selected: model.Selection, result: model.Result) !void {
    const selected_hash = digest.selection(selected.binding, selected.tests);
    const result_hash = digest.result(result.binding, result.selection_sha256, result.tests);
    if (!equal(u8, selected.selection_sha256, &selected_hash) or
        !equal(u8, result.selection_sha256, &selected_hash) or
        !equal(u8, result.result_sha256, &result_hash)) return error.ValidationDigestMismatch;
}

fn counts(names: []const []const u8, rows: []const model.Row) !model.Summary {
    try uniqueNames(names);
    var summary: model.Summary = .{ .suites = 1 };
    for (names, rows) |name, row| {
        if (!equal(u8, name, row.name)) return error.ValidationSelectionMismatch;
        const behavior = model.behavioral(name);
        if (behavior) summary.selected += 1;
        if (behavior and row.status != .skip) summary.completed += 1;
        if (row.status == .skip) summary.skipped += 1;
        if (row.status == .fail or row.status == .fail_leak) summary.failed += 1;
        if (row.leaked) summary.leaked += 1;
        if (row.leaked != (row.status == .leak or row.status == .fail_leak)) {
            return error.InvalidValidationLeakState;
        }
        if (behavior and row.status == .ok and !row.leaked) summary.passed += 1;
    }
    if (summary.selected > 0 and summary.completed > 0 and summary.passed > 0 and
        summary.failed == 0 and summary.leaked == 0) summary.qualifying_suites = 1;
    return summary;
}

fn uniqueNames(names: []const []const u8) !void {
    std.debug.assert(names.len <= model.max_tests);
    var order: [model.max_tests]u32 = undefined;
    for (order[0..names.len], 0..) |*index, i| index.* = @intCast(i);
    const Less = struct {
        fn than(values: []const []const u8, a: u32, b: u32) bool {
            return std.mem.lessThan(u8, values[a], values[b]);
        }
    };
    std.mem.sortUnstable(u32, order[0..names.len], names, Less.than);
    for (order[1..names.len], order[0 .. names.len - 1]) |a, b| {
        if (equal(u8, names[a], names[b])) return error.DuplicateValidationTest;
    }
}
