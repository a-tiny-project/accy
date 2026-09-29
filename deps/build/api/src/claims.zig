const std = @import("std");
const module = @import("module.zig");
const parallel = @import("parallel.zig");

const minimum_test_resource_step_rss: usize = 1024 * 1024 * 1024;
const max_default_test_resource_slots: u32 = 12;

pub const TestResourceMode = enum {
    auto,
    off,
};

pub const ChildResources = struct {
    jobs: u32,
    aggregate_rss: usize,
};

pub const TestResourcePolicy = struct {
    mode: TestResourceMode,
    slots: u32,
    child_build_jobs: u32,
    cpu_count: u32,
    delegated_memory_bytes: usize,
    step_rss_claim: usize,
    compile_rss_claim: usize,

    pub fn init(
        b: *std.Build,
        mode: TestResourceMode,
        requested_slots: u32,
        requested_child_build_jobs: u32,
    ) TestResourcePolicy {
        if (requested_slots == 0) @panic("test-resource-slots must be greater than zero");
        if (requested_child_build_jobs == 0) @panic("child-build-jobs must be greater than zero");
        const fallback_memory =
            @as(u64, minimum_test_resource_step_rss) * @as(u64, requested_slots);
        const detected = parallel.hostCapacity(b, fallback_memory);
        return initWithCapacity(
            mode,
            requested_slots,
            requested_child_build_jobs,
            detected.cpu_count,
            detected.memory_bytes,
            detected.tree_bytes,
        );
    }

    pub fn enabled(self: TestResourcePolicy) bool {
        return self.mode == .auto;
    }

    pub fn childJobs(self: TestResourcePolicy, max_jobs: u32) u32 {
        if (max_jobs == 0) @panic("maximum child build jobs must be greater than zero");
        return @min(self.slots, self.child_build_jobs, max_jobs);
    }

    pub fn childResources(
        self: TestResourcePolicy,
        max_jobs: u32,
        job_rss_claim: ?usize,
    ) ChildResources {
        if (max_jobs == 0) @panic("maximum child build jobs must be greater than zero");
        const rss_claim = job_rss_claim orelse return .{
            .jobs = self.childJobs(max_jobs),
            .aggregate_rss = self.step_rss_claim,
        };
        if (rss_claim == 0) @panic("child RSS claim must be greater than zero");
        const memory_jobs: u32 = @intCast(@max(
            1,
            @min(
                self.delegated_memory_bytes / rss_claim,
                std.math.maxInt(u32),
            ),
        ));
        const jobs = @min(
            self.child_build_jobs,
            max_jobs,
            self.cpu_count,
            memory_jobs,
        );
        const aggregate_rss = std.math.mul(
            usize,
            @as(usize, jobs),
            rss_claim,
        ) catch std.math.maxInt(usize);
        return .{
            .jobs = jobs,
            .aggregate_rss = aggregate_rss,
        };
    }

    fn initWithCapacity(
        mode: TestResourceMode,
        requested_slots: u32,
        requested_child_build_jobs: u32,
        cpu_count: usize,
        memory_bytes: u64,
        tree_bytes: ?u64,
    ) TestResourcePolicy {
        std.debug.assert(requested_slots > 0);
        std.debug.assert(requested_child_build_jobs > 0);
        const bounded_memory: usize = @intCast(@min(
            memory_bytes,
            std.math.maxInt(usize),
        ));
        const bounded_cpu: u32 = @intCast(@min(
            @max(1, cpu_count),
            std.math.maxInt(u32),
        ));
        const lane = laneBudget(tree_bytes);
        const slots = laneSlots(lane, requested_slots, bounded_cpu);
        std.debug.assert(slots > 0);
        std.debug.assert(slots <= requested_slots);
        const step_rss_claim = testResourceStepRssClaim(
            slots,
            lane orelse bounded_memory,
            if (lane == null) minimum_test_resource_step_rss else laneStepClaim(),
        );
        const compile_rss_claim = @min(step_rss_claim, compileStepClaim());
        std.debug.assert(compile_rss_claim > 0);
        std.debug.assert(compile_rss_claim <= step_rss_claim);
        return .{
            .mode = mode,
            .slots = slots,
            .child_build_jobs = requested_child_build_jobs,
            .cpu_count = bounded_cpu,
            .delegated_memory_bytes = lane orelse delegatedHostMemory(bounded_memory),
            .step_rss_claim = step_rss_claim,
            .compile_rss_claim = compile_rss_claim,
        };
    }
};

/// Returns the bytes a lane grants concurrent steps, or null outside a lane.
fn laneBudget(tree_bytes: ?u64) ?usize {
    const tree = tree_bytes orelse return null;
    if (tree == 0) return null;
    const budget = parallel.treeBudgetBytes(tree);
    std.debug.assert(budget > 0);
    return @intCast(@min(budget, std.math.maxInt(usize)));
}

/// Returns the conservative per-step claim declared for one Zig test step.
fn laneStepClaim() usize {
    const claim = parallel.testStepMemoryBytes();
    std.debug.assert(claim > 0);
    return @intCast(@min(claim, std.math.maxInt(usize)));
}

/// Returns the declared claim for one compile step that states no claim.
fn compileStepClaim() usize {
    const claim = parallel.compileStepMemoryBytes();
    std.debug.assert(claim > 0);
    return @intCast(@min(claim, std.math.maxInt(usize)));
}

/// Caps concurrent test steps at what the lane budget holds at that claim.
/// Outside a lane the requested slot count already reflects host capacity.
fn laneSlots(lane: ?usize, requested_slots: u32, cpu_count: u32) u32 {
    std.debug.assert(requested_slots > 0);
    std.debug.assert(cpu_count > 0);
    const budget = lane orelse return requested_slots;
    const fitting: u32 = @intCast(@min(
        @max(1, budget / laneStepClaim()),
        std.math.maxInt(u32),
    ));
    return @min(requested_slots, cpu_count, fitting);
}

fn delegatedHostMemory(bounded_memory: usize) usize {
    const memory_reserve: usize = @intCast(@min(
        parallel.ordinaryMemoryReserve(),
        std.math.maxInt(usize),
    ));
    return bounded_memory -| memory_reserve;
}

pub fn defaultTestResourceSlots(b: *std.Build) u32 {
    return parallel.processCount(b, max_default_test_resource_slots);
}

pub fn defaultChildBuildJobs() u32 {
    return max_default_test_resource_slots;
}

fn testResourceStepRssClaim(slots: u32, memory_bytes: usize, floor: usize) usize {
    std.debug.assert(slots > 0);
    std.debug.assert(floor > 0);
    const total_memory = @max(1, memory_bytes);
    const divisor: usize = @intCast(slots);
    const divided = std.math.divCeil(usize, total_memory, divisor) catch total_memory;
    const claim = @min(total_memory, @max(floor, divided));
    std.debug.assert(claim > 0);
    std.debug.assert(claim <= total_memory);
    return claim;
}

pub fn applyTestCompileResourcePolicy(
    test_resource_policy: TestResourcePolicy,
    compile: *std.Build.Step.Compile,
) void {
    if (!test_resource_policy.enabled()) return;
    compile.step.max_rss = @max(compile.step.max_rss, test_resource_policy.step_rss_claim);
}

pub fn applyTestRunResourcePolicy(
    test_resource_policy: TestResourcePolicy,
    run: *std.Build.Step.Run,
) void {
    applyTestRunResourceClaim(
        test_resource_policy,
        run,
        test_resource_policy.step_rss_claim,
    );
}

pub fn applyTestRunResourceClaim(
    test_resource_policy: TestResourcePolicy,
    run: *std.Build.Step.Run,
    rss_claim: usize,
) void {
    if (!test_resource_policy.enabled()) return;
    run.step.max_rss = @max(run.step.max_rss, rss_claim);
}

/// Raises max_rss on test compiles and test runs owned by this builder.
/// Unclaimed test steps bypass Maker's budget and can exceed the lane ceiling.
/// Steps owned by another builder keep their claims. Larger claims stay.
/// When the policy mode is off, it changes nothing.
pub fn applyTestGraphResourcePolicy(
    test_resource_policy: TestResourcePolicy,
    b: *std.Build,
) void {
    claimOwnedSteps(test_resource_policy, b, claimTestStep);
}

/// Claims memory for every step reachable from this builder's top-level steps
/// that states no claim, whichever builder owns it. Maker charges only
/// claimed steps against its budget, so an unclaimed step runs beside a
/// lane-sized claim and can push the tree past its ceiling. A compile claims
/// `compile_rss_claim`. A test run claims `step_rss_claim`. Every declared
/// claim stays, larger or smaller, so a dependency's own policy still rules
/// its steps. Other runs keep their claims. Call it once the graph is
/// complete. When the policy mode is off, it changes nothing.
pub fn applyExecutedGraphResourcePolicy(
    test_resource_policy: TestResourcePolicy,
    b: *std.Build,
) void {
    claimSteps(test_resource_policy, b, .any, claimUnclaimedStep);
}

const Ownership = enum { own, any };

fn claimOwnedSteps(
    test_resource_policy: TestResourcePolicy,
    b: *std.Build,
    comptime claim: fn (TestResourcePolicy, *std.Build.Step) void,
) void {
    claimSteps(test_resource_policy, b, .own, claim);
}

fn claimSteps(
    test_resource_policy: TestResourcePolicy,
    b: *std.Build,
    comptime ownership: Ownership,
    comptime claim: fn (TestResourcePolicy, *std.Build.Step) void,
) void {
    if (!test_resource_policy.enabled()) return;
    var visited: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    var pending: std.ArrayListUnmanaged(*std.Build.Step) = .empty;
    for (b.top_level_steps.values()) |top_level| {
        pending.append(b.graph.arena, &top_level.step) catch @panic("OOM");
    }
    pending.appendSlice(b.graph.arena, &.{
        &b.install_tls.step,
        &b.uninstall_tls.step,
    }) catch @panic("OOM");
    while (pending.pop()) |step| {
        const entry = visited.getOrPut(b.graph.arena, step) catch @panic("OOM");
        if (entry.found_existing) continue;
        if (ownership == .any or step.owner == b) claim(test_resource_policy, step);
        pending.appendSlice(b.graph.arena, step.dependencies.items) catch @panic("OOM");
    }
}

fn claimUnclaimedStep(test_resource_policy: TestResourcePolicy, step: *std.Build.Step) void {
    if (step.max_rss != 0) return;
    if (step.cast(std.Build.Step.Compile) != null) {
        step.max_rss = test_resource_policy.compile_rss_claim;
        return;
    }
    const run = step.cast(std.Build.Step.Run) orelse return;
    const producer = run.producer orelse return;
    if (producer.kind != .@"test") return;
    step.max_rss = test_resource_policy.step_rss_claim;
}

fn claimTestStep(test_resource_policy: TestResourcePolicy, step: *std.Build.Step) void {
    if (step.cast(std.Build.Step.Compile)) |compile| {
        if (compile.kind != .@"test") return;
        applyTestCompileResourcePolicy(test_resource_policy, compile);
        return;
    }
    const run = step.cast(std.Build.Step.Run) orelse return;
    const producer = run.producer orelse return;
    if (producer.kind != .@"test") return;
    applyTestRunResourcePolicy(test_resource_policy, run);
}

test "child build jobs honor step resource and user caps" {
    const policy = TestResourcePolicy.initWithCapacity(
        .auto,
        5,
        12,
        16,
        30 * 1024 * 1024 * 1024,
        null,
    );
    try std.testing.expectEqual(@as(u32, 1), policy.childJobs(1));
    try std.testing.expectEqual(@as(u32, 4), policy.childJobs(4));
    try std.testing.expectEqual(@as(u32, 5), policy.childJobs(8));
    const user_limited = TestResourcePolicy.initWithCapacity(
        .auto,
        5,
        2,
        16,
        30 * 1024 * 1024 * 1024,
        null,
    );
    try std.testing.expectEqual(@as(u32, 2), user_limited.childJobs(8));
}

test "profiled child admission resolves CPU memory registry and user caps" {
    const gibibyte: usize = 1024 * 1024 * 1024;
    const rss_claim = 2 * gibibyte;
    const cpu_limited = TestResourcePolicy.initWithCapacity(
        .auto,
        5,
        12,
        4,
        64 * gibibyte,
        null,
    );
    try expectChildResources(cpu_limited.childResources(16, rss_claim), 4, 8 * gibibyte);
    try expectChildResources(cpu_limited.childResources(2, rss_claim), 2, 4 * gibibyte);

    const memory_limited = TestResourcePolicy.initWithCapacity(
        .auto,
        5,
        12,
        16,
        10 * gibibyte,
        null,
    );
    try expectChildResources(memory_limited.childResources(16, rss_claim), 3, 6 * gibibyte);

    const user_limited = TestResourcePolicy.initWithCapacity(
        .auto,
        5,
        2,
        16,
        64 * gibibyte,
        null,
    );
    try expectChildResources(user_limited.childResources(16, rss_claim), 2, 4 * gibibyte);
}

test "unprofiled child admission preserves slots and the ordinary step claim" {
    const gibibyte: usize = 1024 * 1024 * 1024;
    const policy = TestResourcePolicy.initWithCapacity(.auto, 5, 12, 16, 30 * gibibyte, null);
    const resources = policy.childResources(8, null);
    try std.testing.expectEqual(@as(u32, 5), resources.jobs);
    try std.testing.expectEqual(policy.step_rss_claim, resources.aggregate_rss);
}

test "one oversized child retains its full RSS claim" {
    const gibibyte: usize = 1024 * 1024 * 1024;
    const policy = TestResourcePolicy.initWithCapacity(.auto, 5, 12, 8, 20 * gibibyte, null);
    try expectChildResources(
        policy.childResources(4, 24 * gibibyte),
        1,
        24 * gibibyte,
    );
}

test "the recorded lane ceiling admits one concurrent test step" {
    const mebibyte: usize = 1024 * 1024;
    const lane = TestResourcePolicy.initWithCapacity(
        .auto,
        12,
        12,
        16,
        31_228 * mebibyte,
        5120 * mebibyte,
    );
    const budget: usize = (5120 - 256) * mebibyte;
    try std.testing.expectEqual(@as(u32, 1), lane.slots);
    try std.testing.expectEqual(budget, lane.delegated_memory_bytes);
    try std.testing.expectEqual(budget, lane.step_rss_claim);
    try std.testing.expectEqual(@as(usize, 1), budget / lane.step_rss_claim);
}

test "host capacity keeps its own step claim when no lane bounds the build" {
    const mebibyte: usize = 1024 * 1024;
    const total: usize = 31_228 * mebibyte;
    const host = TestResourcePolicy.initWithCapacity(.auto, 12, 12, 16, total, null);
    try std.testing.expectEqual(@as(u32, 12), host.slots);
    try std.testing.expectEqual(
        std.math.divCeil(usize, total, 12) catch unreachable,
        host.step_rss_claim,
    );
    try std.testing.expectEqual(
        total - parallel.ordinaryMemoryReserve(),
        host.delegated_memory_bytes,
    );
}

test "the declared ordinary lane admits one claimed step, so a nested build never overlaps" {
    const mebibyte: u64 = 1024 * 1024;
    const declared = @as(u64, parallel.ordinaryMemoryClaimMib()) * mebibyte;
    const lane = TestResourcePolicy.initWithCapacity(
        .auto,
        12,
        12,
        16,
        31_228 * mebibyte,
        declared,
    );
    try std.testing.expectEqual(@as(u32, 1), lane.slots);
    try std.testing.expectEqual(
        @as(usize, 1),
        lane.delegated_memory_bytes / lane.step_rss_claim,
    );
}

test "no lane admits more claimed test memory than that lane holds" {
    const mebibyte: usize = 1024 * 1024;
    const declared = laneStepClaim();
    const lane_mib = [_]usize{ 1024, 2048, 5120, 6144, 8192, 20480, 65536 };
    for (lane_mib) |requested| {
        const policy = TestResourcePolicy.initWithCapacity(
            .auto,
            12,
            12,
            16,
            31_228 * mebibyte,
            requested * mebibyte,
        );
        const budget = policy.delegated_memory_bytes;
        const concurrent = budget / policy.step_rss_claim;
        try std.testing.expect(concurrent >= 1);
        try std.testing.expect(concurrent <= policy.slots);
        try std.testing.expect(concurrent * policy.step_rss_claim <= budget);
        try std.testing.expect(policy.step_rss_claim >= @min(budget, declared));
    }
}

test "a lane-sized test claim leaves no room for a compile claim" {
    const mebibyte: usize = 1024 * 1024;
    const lane_mib = [_]usize{ 1024, 2048, 5120, 6144, 8192, 10240, 20480, 65536 };
    for (lane_mib) |requested| {
        const policy = TestResourcePolicy.initWithCapacity(
            .auto,
            1,
            12,
            16,
            31_228 * mebibyte,
            requested * mebibyte,
        );
        const budget = policy.delegated_memory_bytes;
        try std.testing.expect(policy.compile_rss_claim > 0);
        try std.testing.expect(policy.compile_rss_claim <= budget);
        try std.testing.expect(policy.compile_rss_claim <= policy.step_rss_claim);
        try std.testing.expect(policy.step_rss_claim + policy.compile_rss_claim > budget);
    }
}

fn expectChildResources(
    actual: ChildResources,
    jobs: u32,
    aggregate_rss: usize,
) !void {
    try std.testing.expectEqual(jobs, actual.jobs);
    try std.testing.expectEqual(aggregate_rss, actual.aggregate_rss);
}

test "graph policy claims only the builder's own test compiles and test runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try testBuild(arena.allocator());
    const owned = sampleGraph(b);
    const other = try std.Build.create(b.graph, .cwd(), &.{});
    const foreign = sampleGraph(other);
    b.top_level_steps.get("sample").?.step.dependOn(&foreign.run_tests.step);
    const mebibyte: usize = 1024 * 1024;
    const lane = TestResourcePolicy.initWithCapacity(
        .auto,
        12,
        12,
        16,
        31_228 * mebibyte,
        5120 * mebibyte,
    );
    applyTestGraphResourcePolicy(lane, b);
    try std.testing.expectEqual(lane.step_rss_claim, owned.tests.step.max_rss);
    try std.testing.expectEqual(lane.step_rss_claim, owned.run_tests.step.max_rss);
    try std.testing.expectEqual(@as(usize, 0), owned.tool.step.max_rss);
    try std.testing.expectEqual(@as(usize, 0), owned.run_tool.step.max_rss);
    try std.testing.expectEqual(@as(usize, 0), foreign.tests.step.max_rss);
    try std.testing.expectEqual(@as(usize, 0), foreign.run_tests.step.max_rss);
}

test "graph policy keeps a larger declared claim and claims nothing when off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try testBuild(arena.allocator());
    const sample = sampleGraph(b);
    const gibibyte: usize = 1024 * 1024 * 1024;
    const off = TestResourcePolicy.initWithCapacity(.off, 12, 12, 16, 30 * gibibyte, null);
    applyTestGraphResourcePolicy(off, b);
    try std.testing.expectEqual(@as(usize, 0), sample.tests.step.max_rss);
    try std.testing.expectEqual(@as(usize, 0), sample.run_tests.step.max_rss);
    sample.run_tests.step.max_rss = 29 * gibibyte;
    const host = TestResourcePolicy.initWithCapacity(.auto, 12, 12, 16, 30 * gibibyte, null);
    applyTestGraphResourcePolicy(host, b);
    try std.testing.expectEqual(host.step_rss_claim, sample.tests.step.max_rss);
    try std.testing.expectEqual(29 * gibibyte, sample.run_tests.step.max_rss);
}

test "executed graph policy claims every unclaimed compile and test run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try testBuild(arena.allocator());
    const owned = sampleGraph(b);
    const other = try std.Build.create(b.graph, .cwd(), &.{});
    const foreign = sampleGraph(other);
    b.top_level_steps.get("sample").?.step.dependOn(&foreign.run_tests.step);
    b.top_level_steps.get("sample").?.step.dependOn(&foreign.run_tool.step);
    const mebibyte: usize = 1024 * 1024;
    const lane = TestResourcePolicy.initWithCapacity(
        .auto,
        12,
        12,
        16,
        31_228 * mebibyte,
        10_240 * mebibyte,
    );
    applyTestGraphResourcePolicy(lane, b);
    foreign.tool.step.max_rss = 64 * mebibyte;
    applyExecutedGraphResourcePolicy(lane, b);
    try std.testing.expectEqual(lane.compile_rss_claim, owned.tool.step.max_rss);
    try std.testing.expectEqual(lane.step_rss_claim, owned.tests.step.max_rss);
    try std.testing.expectEqual(lane.step_rss_claim, owned.run_tests.step.max_rss);
    try std.testing.expectEqual(@as(usize, 0), owned.run_tool.step.max_rss);
    try std.testing.expectEqual(64 * mebibyte, foreign.tool.step.max_rss);
    try std.testing.expectEqual(lane.compile_rss_claim, foreign.tests.step.max_rss);
    try std.testing.expectEqual(lane.step_rss_claim, foreign.run_tests.step.max_rss);
    try std.testing.expectEqual(@as(usize, 0), foreign.run_tool.step.max_rss);
    const gibibyte: usize = 1024 * mebibyte;
    owned.tool.step.max_rss = 0;
    const off = TestResourcePolicy.initWithCapacity(.off, 12, 12, 16, 30 * gibibyte, null);
    applyExecutedGraphResourcePolicy(off, b);
    try std.testing.expectEqual(@as(usize, 0), owned.tool.step.max_rss);
}

const SampleGraph = struct {
    tests: *std.Build.Step.Compile,
    run_tests: *std.Build.Step.Run,
    tool: *std.Build.Step.Compile,
    run_tool: *std.Build.Step.Run,
};

fn sampleGraph(b: *std.Build) SampleGraph {
    const module_options = module.ModuleOptions{
        .target = b.graph.host,
        .optimize = .debug,
    };
    const tests = b.addTest(.{
        .name = "sample",
        .root_module = b.createModule(module_options.createOptions(b, "sample.zig", &.{})),
    });
    const tool = b.addExecutable(.{
        .name = "tool",
        .root_module = b.createModule(module_options.createOptions(b, "tool.zig", &.{})),
    });
    const run_tests = b.addRunArtifact(tests);
    const run_tool = b.addRunArtifact(tool);
    const step = b.step("sample", "Run the sample graph");
    step.dependOn(&run_tests.step);
    step.dependOn(&run_tool.step);
    return .{ .tests = tests, .run_tests = run_tests, .tool = tool, .run_tool = run_tool };
}

fn testBuild(allocator: std.mem.Allocator) !*std.Build {
    const graph = try allocator.create(std.Build.Graph);
    graph.* = .{
        .io = std.Options.debug_io,
        .arena = allocator,
        .zig_exe = "zig",
        .environ_map = .init(allocator),
        .host = .{ .query = .{}, .result = @import("builtin").target },
        .generated_files = .empty,
        .wip_configuration = .init(allocator),
    };
    return std.Build.create(graph, .cwd(), &.{});
}
