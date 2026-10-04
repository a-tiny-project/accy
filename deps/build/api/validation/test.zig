const std = @import("std");
const validation = @import("root.zig");

test {
    _ = @import("model.zig");
    _ = @import("verify.zig");
    _ = @import("plan.zig");
    _ = @import("catalog.zig");
    _ = @import("infrastructure.zig");
    _ = @import("manifest.zig");
    _ = @import("roots.zig");
    _ = @import("source.zig");
}

const expected_suite: validation.Suite = .{
    .id = "fixture-tests",
    .backend = "native",
    .selection_artifact = "fixture.selection.json",
    .result_artifact = "fixture.result.json",
};
const declaration: validation.Recipe = .{
    .id = "fixture.test",
    .owner = "fixture",
    .directory = "fixture",
    .step = "test",
    .class = "ordinary",
    .test_cwd = "/tmp",
    .declaration = "fixture/build/recipes.zig",
    .declaration_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    .framework_sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    .argv = &.{ "build", "test" },
    .runtime = &.{"zig"},
    .environment = &.{},
    .suites = &.{expected_suite},
};

const Fixture = struct {
    names: [3][]const u8 = .{ "test.test_0", "test.alpha", "test.beta" },
    rows: [3]validation.Row = .{
        .{ .name = "test.test_0", .status = .ok, .leaked = false },
        .{ .name = "test.alpha", .status = .ok, .leaked = false },
        .{ .name = "test.beta", .status = .ok, .leaked = false },
    },
    recipe_hash: [64]u8 = undefined,
    selection_hash: [64]u8 = undefined,
    result_hash: [64]u8 = undefined,

    fn evidence(self: *Fixture) validation.Evidence {
        self.recipe_hash = validation.recipeDigest(declaration);
        const binding: validation.Binding = .{
            .recipe_id = declaration.id,
            .recipe_sha256 = &self.recipe_hash,
            .suite_id = expected_suite.id,
            .class = declaration.class,
            .token = "execution-a",
            .backend = "native",
            .compiler_backend = "stage2_x86_64",
            .zig_version = "pinned-zig",
            .target = validation.host_target,
            .optimize = "Debug",
        };
        var value: validation.Evidence = .{
            .selection = .{
                .binding = binding,
                .selected_test_count = 3,
                .selected_behavioral_test_count = 2,
                .selection_sha256 = "",
                .tests = &self.names,
            },
            .result = .{
                .binding = binding,
                .selection_sha256 = "",
                .result_sha256 = "",
                .completed_test_count = 3,
                .completed_behavioral_test_count = 2,
                .passed_behavioral_test_count = 2,
                .skipped_test_count = 0,
                .failed_test_count = 0,
                .leaked_test_count = 0,
                .tests = &self.rows,
            },
        };
        self.seal(&value);
        return value;
    }

    fn seal(self: *Fixture, value: *validation.Evidence) void {
        self.selection_hash = validation.selectionDigest(
            value.selection.binding,
            value.selection.tests,
        );
        self.result_hash = validation.resultDigest(
            value.result.binding,
            &self.selection_hash,
            value.result.tests,
        );
        value.selection.selection_sha256 = &self.selection_hash;
        value.result.selection_sha256 = &self.selection_hash;
        value.result.result_sha256 = &self.result_hash;
    }
};

fn verify(value: validation.Evidence) !validation.Summary {
    return validation.verifyRecipe(declaration, "execution-a", "pinned-zig", &.{value});
}

test "validation receipts prove selected completed behavioral tests" {
    var fixture: Fixture = .{};
    const summary = try verify(fixture.evidence());
    try std.testing.expectEqual(@as(u32, 1), summary.qualifying_suites);
    try std.testing.expectEqual(@as(u32, 2), summary.selected);
    try std.testing.expectEqual(@as(u32, 2), summary.completed);
    try std.testing.expectEqual(@as(u32, 2), summary.passed);
    try std.testing.expectEqual(@as(u32, 0), summary.leaked);
}

test "validation retains legitimate failure and leak counts" {
    var fixture: Fixture = .{};
    var value = fixture.evidence();
    fixture.rows[1].status = .fail;
    fixture.rows[2].status = .leak;
    fixture.rows[2].leaked = true;
    value.result.passed_behavioral_test_count = 0;
    value.result.failed_test_count = 1;
    value.result.leaked_test_count = 1;
    fixture.seal(&value);
    const summary = try verify(value);
    try std.testing.expectEqual(@as(u32, 0), summary.qualifying_suites);
    try std.testing.expectEqual(@as(u32, 2), summary.completed);
    try std.testing.expectEqual(@as(u32, 1), summary.failed);
    try std.testing.expectEqual(@as(u32, 1), summary.leaked);
}

test "validation discovery and skipped tests cannot qualify a suite" {
    var fixture: Fixture = .{};
    var value = fixture.evidence();
    fixture.rows[1].status = .skip;
    fixture.rows[2].status = .skip;
    value.result.completed_behavioral_test_count = 0;
    value.result.passed_behavioral_test_count = 0;
    value.result.skipped_test_count = 2;
    fixture.seal(&value);
    const summary = try verify(value);
    try std.testing.expectEqual(@as(u32, 0), summary.qualifying_suites);
    try std.testing.expectEqual(@as(u32, 0), summary.completed);
    try std.testing.expectEqual(@as(u32, 2), summary.skipped);
    value.selection.tests = value.selection.tests[0..1];
    value.selection.selected_test_count = 1;
    value.selection.selected_behavioral_test_count = 0;
    value.result.tests = value.result.tests[0..1];
    value.result.completed_test_count = 1;
    value.result.skipped_test_count = 0;
    fixture.seal(&value);
    try std.testing.expectEqual(@as(u32, 0), (try verify(value)).qualifying_suites);
}

test "validation rejects incomplete duplicate and mismatched selections" {
    var fixture: Fixture = .{};
    var value = fixture.evidence();
    value.result.tests = value.result.tests[0..2];
    try std.testing.expectError(error.IncompleteValidationRun, verify(value));
    value = fixture.evidence();
    fixture.rows[1].name = "test.counterfeit";
    fixture.seal(&value);
    try std.testing.expectError(error.ValidationSelectionMismatch, verify(value));
    fixture.rows[1].name = "test.beta";
    fixture.names[1] = "test.beta";
    fixture.seal(&value);
    try std.testing.expectError(error.DuplicateValidationTest, verify(value));
    value.selection.tests = &.{};
    try std.testing.expectError(error.EmptyValidationSelection, verify(value));
}

test "validation binds recipe invocation compiler class and backend" {
    var fixture: Fixture = .{};
    const original = fixture.evidence();
    inline for (.{
        "recipe_id",
        "recipe_sha256",
        "suite_id",
        "class",
        "token",
        "zig_version",
        "target",
        "optimize",
    }) |field| {
        var value = original;
        @field(value.selection.binding, field) = "different";
        fixture.seal(&value);
        try std.testing.expectError(error.ValidationBindingMismatch, verify(value));
    }
    var value = fixture.evidence();
    value.selection.binding.compiler_backend = "stage2_llvm";
    try std.testing.expectError(error.ValidationBackendMismatch, verify(value));
    try std.testing.expectError(
        error.IncompleteValidationSuites,
        validation.verifyRecipe(declaration, "execution-a", "pinned-zig", &.{}),
    );
}

test "validation counts derive from rows and result integrity includes outcomes" {
    var fixture: Fixture = .{};
    var value = fixture.evidence();
    value.result.passed_behavioral_test_count = 20;
    try std.testing.expectError(error.InvalidValidationCounts, verify(value));
    value = fixture.evidence();
    fixture.rows[1].status = .fail;
    try std.testing.expectError(error.ValidationDigestMismatch, verify(value));
}

test "validation recipe identity includes framework and list boundaries" {
    var changed = declaration;
    changed.framework_sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    try std.testing.expect(!std.mem.eql(
        u8,
        &validation.recipeDigest(declaration),
        &validation.recipeDigest(changed),
    ));
    var left = declaration;
    left.argv = &.{ "runtime", "a" };
    left.runtime = &.{};
    var right = declaration;
    right.argv = &.{};
    right.runtime = &.{ "a", "runtime" };
    try std.testing.expect(!std.mem.eql(
        u8,
        &validation.recipeDigest(left),
        &validation.recipeDigest(right),
    ));
    var command = declaration;
    command.runtime = &.{ "zig", "sh" };
    try std.testing.expect(!std.mem.eql(
        u8,
        &validation.recipeDigest(declaration),
        &validation.recipeDigest(command),
    ));
    var cache = declaration;
    cache.environment = &.{.{ .name = "ZIG_LOCAL_CACHE_DIR", .value = "/tmp/zig-child" }};
    try std.testing.expect(!std.mem.eql(
        u8,
        &validation.recipeDigest(declaration),
        &validation.recipeDigest(cache),
    ));
}
