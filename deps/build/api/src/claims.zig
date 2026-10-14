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
    /// The bytes an admitted lane grants concurrent steps, Maker's --maxrss, or
    /// null for a build outside a lane.
    lane_budget: ?usize,
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

    /// Resources of a delegated child build whose lanes claim
    /// `lane_claim_bytes` in the requirements manifest. Inside a lane the
    /// child's max_rss is its claim clamped to the budget, so Maker's
    /// --maxrss bounds the claims of the children it runs at once. A parent
    /// claims at least its largest child, so the clamp withholds at most the
    /// 256 MiB tree reserve, which the parent's reservation still holds; the
    /// catalog refuses a larger gap. The child's jobs are then at most its
    /// share of the parent's CPU, max(1, cpu * max_rss / budget). Maker keeps
    /// the summed max_rss of running children within the budget, so their
    /// summed jobs stay within the parent's CPU, past the floor of one job
    /// each. Outside a lane this is childResources.
    pub fn delegatedChild(
        self: TestResourcePolicy,
        max_jobs: u32,
        job_rss_claim: ?usize,
        lane_claim_bytes: u64,
    ) ChildResources {
        std.debug.assert(lane_claim_bytes > 0);
        var resources = self.childResources(max_jobs, job_rss_claim);
        const budget = self.lane_budget orelse return resources;
        std.debug.assert(budget > 0);
        resources.aggregate_rss = @min(budget, @max(
            resources.aggregate_rss,
            @as(usize, @intCast(@min(lane_claim_bytes, std.math.maxInt(usize)))),
        ));
        resources.jobs = @min(
            resources.jobs,
            cpuShareJobs(self.cpu_count, resources.aggregate_rss, budget),
        );
        std.debug.assert(resources.jobs > 0);
        return resources;
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
            .lane_budget = lane,
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

/// Returns the jobs a step claiming `rss` of a `budget` may take of `cpu`:
/// its proportional share, at least one and at most all of it.
fn cpuShareJobs(cpu: u32, rss: usize, budget: usize) u32 {
    std.debug.assert(cpu > 0);
    std.debug.assert(budget > 0);
    if (rss >= budget) return cpu;
    const share = @as(u128, cpu) * @as(u128, rss) / @as(u128, budget);
    const jobs: u32 = @intCast(@max(1, share));
    std.debug.assert(jobs <= cpu);
    return jobs;
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

fn expectChildResources(
    actual: ChildResources,
    jobs: u32,
    aggregate_rss: usize,
) !void {
    try std.testing.expectEqual(jobs, actual.jobs);
    try std.testing.expectEqual(aggregate_rss, actual.aggregate_rss);
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
