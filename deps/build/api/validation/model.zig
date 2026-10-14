const std = @import("std");
const builtin = @import("builtin");

pub const recipe_schema = "tiny.build.validation-recipe/v1";
pub const selection_schema = "tiny.build.test-selection/v1";
pub const result_schema = "tiny.build.test-result/v1";
pub const max_tests = 16 * 1024;
/// A recipe may cover several independent test processes, including shards.
pub const max_suites = 16;
/// Each process reports its selected tests and its test results separately.
pub const artifacts_per_suite = 2;
pub const max_suite_artifacts = max_suites * artifacts_per_suite;
pub const max_artifact_bytes = 4 * 1024 * 1024;
pub const host_target = @tagName(builtin.cpu.arch) ++ "-" ++
    @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi);

pub const Environment = struct {
    name: []const u8,
    value: []const u8,
};

pub const Source = struct {
    path: []const u8,
    sha256: []const u8,
};

pub const Suite = struct {
    id: []const u8,
    backend: []const u8,
    selection_artifact: []const u8,
    result_artifact: []const u8,
};

pub const Placement = enum { local, site };

/// A packaged recipe's canonical JSON fits this bound, so a check's input,
/// which carries the whole recipe in a small envelope, fits the check
/// executor's 8 KiB input bound.
pub const recipe_bytes_max = 7 * 1024;
/// A product tree's canonical JSON, escaping included, fits this bound.
pub const product_tree_bytes_max = 2048;

/// A path its recipe's prepare step copies from the captured source under
/// `/workspace` into the check's `/output`.
pub const Mapping = struct {
    from: []const u8,
    to: []const u8,
};

/// A tree a passing sealed check leaves for later checks of byte-identical
/// inputs, mounted in the check's private `/tmp` at `mount`. `inputs` are the
/// repository paths whose captured bytes key the tree, `staging` the copies
/// the recipe's prepare step makes of them, `environment` the producer
/// variables that join the check's environment, and `policy` the ordered
/// producer words the recipe's commands are generated from. The check's argv
/// carries a per-attempt token, so these words, not argv, key the tree.
pub const ProductTree = struct {
    mount: []const u8,
    inputs: []const []const u8,
    staging: []const Mapping,
    environment: []const Environment = &.{},
    policy: []const []const u8 = &.{},
    policy_version: u32,
};

pub const Runner = enum { normalized, standard };

/// A recipe's measured claim. Its sealed check reserves memory_mib and cpu in
/// place of the undeclared default, and memory_mib is the check's tree
/// ceiling. peak_mib is the tree peak that evidence measured.
pub const Claim = struct {
    memory_mib: u32,
    cpu: u16,
    peak_mib: u32,
    evidence: []const u8,
};

pub const Recipe = struct {
    schema: []const u8 = recipe_schema,
    id: []const u8,
    owner: []const u8,
    directory: []const u8,
    step: []const u8,
    class: []const u8,
    placement: Placement = .local,
    runner: Runner = .normalized,
    claim: ?Claim = null,
    optimize: []const u8 = "Debug",
    target: []const u8 = "host",
    selection: []const u8 = "all",
    source: []const u8 = "worktree",
    test_cwd: []const u8,
    declaration: []const u8,
    declaration_sha256: []const u8,
    framework_sha256: []const u8,
    argv: []const []const u8,
    runtime: []const []const u8,
    environment: []const Environment,
    suites: []const Suite,
    product_tree: ?ProductTree = null,

    /// Default placement, runner, an undeclared claim and an undeclared
    /// product tree retain historical canonical recipe bytes.
    pub fn jsonStringify(self: Recipe, writer: anytype) !void {
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(Recipe)) |field| {
            if (comptime std.mem.eql(u8, field, "placement")) {
                if (self.placement != .local) {
                    try writer.objectField(field);
                    try writer.write(self.placement);
                }
            } else if (comptime std.mem.eql(u8, field, "runner")) {
                if (self.runner != .normalized) {
                    try writer.objectField(field);
                    try writer.write(self.runner);
                }
            } else if (comptime std.mem.eql(u8, field, "claim")) {
                if (self.claim) |claim| {
                    try writer.objectField(field);
                    try writer.write(claim);
                }
            } else if (comptime std.mem.eql(u8, field, "product_tree")) {
                if (self.product_tree) |tree| {
                    try writer.objectField(field);
                    try writer.write(tree);
                }
            } else {
                try writer.objectField(field);
                try writer.write(@field(self, field));
            }
        }
        try writer.endObject();
    }
};

pub const Binding = struct {
    recipe_id: []const u8,
    recipe_sha256: []const u8,
    suite_id: []const u8,
    class: []const u8,
    token: []const u8,
    backend: []const u8,
    compiler_backend: []const u8,
    zig_version: []const u8,
    target: []const u8,
    optimize: []const u8,
};

pub const Selection = struct {
    schema: []const u8 = selection_schema,
    binding: Binding,
    selected_test_count: u32,
    selected_behavioral_test_count: u32,
    selection_sha256: []const u8,
    tests: []const []const u8,
};

pub const Status = enum { ok, skip, fail, leak, fail_leak };

pub const Row = struct {
    name: []const u8,
    status: Status,
    leaked: bool,
};

pub const Result = struct {
    schema: []const u8 = result_schema,
    binding: Binding,
    selection_sha256: []const u8,
    result_sha256: []const u8,
    completed_test_count: u32,
    completed_behavioral_test_count: u32,
    passed_behavioral_test_count: u32,
    skipped_test_count: u32,
    failed_test_count: u32,
    leaked_test_count: u32,
    tests: []const Row,
};

pub const Summary = struct {
    suites: u32 = 0,
    qualifying_suites: u32 = 0,
    selected: u32 = 0,
    completed: u32 = 0,
    passed: u32 = 0,
    skipped: u32 = 0,
    failed: u32 = 0,
    leaked: u32 = 0,
};

pub const Evidence = struct {
    selection: Selection,
    result: Result,
};

/// Conservatively excludes the compiler's unnamed discovery naming pattern.
pub fn behavioral(name: []const u8) bool {
    const start = if (std.mem.lastIndexOfScalar(u8, name, '.')) |index| index + 1 else 0;
    const final = name[start..];
    if (!std.mem.startsWith(u8, final, "test_") or final.len == "test_".len) return true;
    for (final["test_".len..]) |byte| if (!std.ascii.isDigit(byte)) return true;
    return false;
}

const legacy_recipe_json =
    "{\"schema\":\"tiny.build.validation-recipe/v1\",\"id\":\"core.test\"," ++
    "\"owner\":\"lib/core\",\"directory\":\"lib/core\",\"step\":\"test\"," ++
    "\"class\":\"ordinary\",\"optimize\":\"Debug\",\"target\":\"host\"," ++
    "\"selection\":\"all\",\"source\":\"worktree\",\"test_cwd\":\"/tmp\"," ++
    "\"declaration\":\"lib/core/build/validation.zon\"," ++
    "\"declaration_sha256\":\"declaration\",\"framework_sha256\":\"framework\"," ++
    "\"argv\":[\"build\",\"test\"],\"runtime\":[\"zig\"],\"environment\":[]," ++
    "\"suites\":[{\"id\":\"core\",\"backend\":\"native\"," ++
    "\"selection_artifact\":\"core.selection.json\"," ++
    "\"result_artifact\":\"core.result.json\"}]}";
