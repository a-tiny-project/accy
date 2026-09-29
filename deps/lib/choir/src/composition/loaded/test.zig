const fixture = @import("../fixture/root.zig");
const std = @import("std");
const sys = @import("sys");
const loaded = @import("root.zig");

const LifecycleEvent = loaded.LifecycleEvent;
const LifecycleObserver = loaded.LifecycleObserver;
const FragmentVTable = loaded.FragmentVTable;
const MaterializedFragment = loaded.MaterializedFragment;
const FragmentMaterializer = loaded.FragmentMaterializer;
const LoadedComposition = loaded.LoadedComposition;
const invoke = loaded.invoke;

test {
    std.testing.refAllDecls(loaded);
}

const TestTrace = struct {
    materialized: [8]u64 = undefined,
    materialized_count: usize = 0,
    destroyed: [8]u64 = undefined,
    destroyed_count: usize = 0,
    lookup_count: usize = 0,
    last_lookup_was_declared_symbol: bool = false,
    alias_deinit_count: usize = 0,
    module_address: usize = 0,
    last_invoked_callee: u64 = 0,
};

const TestRuntimeState = struct {
    trace: *TestTrace,
    id: u64,
    entry_symbol: []const u8,
    entry_address: ?usize,
};

const TestMaterializerContext = struct {
    trace: *TestTrace,
    expected_id: u64,
    entry_symbol: []const u8,
    entry_address: ?usize = null,
    fail: bool = false,
    shared_state: ?*TestRuntimeState = null,
    vtable: *const FragmentVTable = &test_vtable,
};

const ConcurrentObserver = struct {
    active: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    overlap: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    invocation_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    fragment_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    composition_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn observer(self: *ConcurrentObserver) LifecycleObserver {
        return .{ .ptr = self, .record_fn = record };
    }

    fn record(ptr: *anyopaque, event: LifecycleEvent) void {
        const self: *ConcurrentObserver = @ptrCast(@alignCast(ptr));
        const previous = self.active.fetchAdd(1, .acq_rel);
        if (previous != 0) self.overlap.store(true, .release);
        var spin: usize = 0;
        while (spin < 4096) : (spin += 1) std.atomic.spinLoopHint();
        switch (event) {
            .invocation_destroyed => _ = self.invocation_count.fetchAdd(1, .monotonic),
            .fragment_destroyed => _ = self.fragment_count.fetchAdd(1, .monotonic),
            .composition_destroyed => _ = self.composition_count.fetchAdd(1, .monotonic),
        }
        _ = self.active.fetchSub(1, .acq_rel);
    }
};

const BlockingInvocationObserver = struct {
    entered: sys.thread.Semaphore = .{},
    allow_exit: sys.thread.Semaphore = .{},

    fn observer(self: *BlockingInvocationObserver) LifecycleObserver {
        return .{ .ptr = self, .record_fn = record };
    }

    fn record(ptr: *anyopaque, event: LifecycleEvent) void {
        const self: *BlockingInvocationObserver = @ptrCast(@alignCast(ptr));
        switch (event) {
            .invocation_destroyed => {
                self.entered.post();
                self.allow_exit.wait();
            },
            .fragment_destroyed, .composition_destroyed => {},
        }
    }
};

const test_vtable = FragmentVTable{
    .invoke = testInvoke,
    .lookup_export = testLookupExport,
    .deinit = testDeinit,
};

const alias_vtable = FragmentVTable{
    .deinit = testAliasDeinit,
};

fn testMaterialize(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    module: *const @import("../root.zig").module.CompositionModule,
    durable_fragment: *const @import("../root.zig").module.Fragment,
) anyerror!MaterializedFragment {
    const context: *TestMaterializerContext = @ptrCast(@alignCast(ptr));
    if (durable_fragment.id.value != context.expected_id) return error.WrongFragment;
    if (module.fragment(durable_fragment.id) != durable_fragment) return error.WrongFragment;
    if (module.source_module.partition(durable_fragment.partition) == null) return error.WrongFragment;
    if (context.trace.module_address == 0) context.trace.module_address = @intFromPtr(module);
    if (context.trace.module_address != @intFromPtr(module)) return error.WrongModule;
    context.trace.materialized[context.trace.materialized_count] = durable_fragment.id.value;
    context.trace.materialized_count += 1;
    if (context.fail) return error.MaterializationFailed;
    const state = context.shared_state orelse try allocator.create(TestRuntimeState);
    if (context.shared_state == null) {
        state.* = .{
            .trace = context.trace,
            .id = durable_fragment.id.value,
            .entry_symbol = context.entry_symbol,
            .entry_address = context.entry_address,
        };
    }
    return .{ .state = state, .vtable = context.vtable };
}

fn testLookupExport(ptr: *anyopaque, symbol: []const u8) ?usize {
    const state: *TestRuntimeState = @ptrCast(@alignCast(ptr));
    state.trace.lookup_count += 1;
    state.trace.last_lookup_was_declared_symbol = std.mem.eql(u8, symbol, state.entry_symbol);
    if (!state.trace.last_lookup_was_declared_symbol) return null;
    return state.entry_address;
}

fn testInvoke(
    ptr: *anyopaque,
    call_site: *const @import("../root.zig").module.CallSite,
    _: *@import("../root.zig").abi.Context,
    _: *@import("../root.zig").abi.Frame,
) @import("../root.zig").abi.Status {
    const state: *TestRuntimeState = @ptrCast(@alignCast(ptr));
    state.trace.last_invoked_callee = call_site.callee.value;
    return .ok;
}

fn testDeinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const state: *TestRuntimeState = @ptrCast(@alignCast(ptr));
    state.trace.destroyed[state.trace.destroyed_count] = state.id;
    state.trace.destroyed_count += 1;
    allocator.destroy(state);
}

fn testAliasDeinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const state: *TestRuntimeState = @ptrCast(@alignCast(ptr));
    state.trace.alias_deinit_count += 1;
    allocator.destroy(state);
}

fn testEntry(_: i64, _: i64) callconv(.c) i64 {
    return @backingInt(@import("../root.zig").abi.Status.ok);
}

fn testModule(allocator: std.mem.Allocator, fragment_count: usize) !@import("../root.zig").module.CompositionModule {
    const records = try fixture.Records.init(allocator);
    defer records.deinit();
    const choir = @import("../../root.zig");
    const composition_root = @import("../root.zig");
    const model = composition_root.module;
    const source = composition_root.source;

    var partitioned = try source.PartitionedModule.init(allocator, "loader");
    defer partitioned.deinit();
    try partitioned.addPartition(.{ .id = .{ .value = 10 }, .name = "host", .pipeline = .choir, .product = .{ .producer = "composition-fixture", .source = "1", .stage = "loader.input", .variant = "default" }, .effect = .none, .provenance = .{ .path = "loader", .symbol = "host" } });
    try partitioned.addPartition(.{ .id = .{ .value = 20 }, .name = "callee", .pipeline = .accy, .product = .{ .producer = "composition-fixture", .source = "2", .stage = "loader.input", .variant = "default" }, .effect = .none, .provenance = .{ .path = "loader", .symbol = "callee" } });
    try partitioned.addCallSite(.{ .id = .{ .value = 30 }, .name = "call", .caller = .{ .value = 10 }, .callee = .{ .value = 20 }, .inputs = &.{}, .outputs = &.{}, .provenance = .{ .path = "loader", .symbol = "call" } });

    var host_artifact = try choir.backends.artifact.objectFileArtifact(allocator, .{ .architecture = .x86_64 }, .{}, "host_symbol", &.{1}, &.{.{ .offset = 0, .symbol = composition_root.abi.invoke_symbol, .kind = .call }});
    defer host_artifact.deinit();
    var callee_artifact = try choir.backends.artifact.objectFileArtifact(allocator, .{ .architecture = .x86_64 }, .{}, "callee_symbol", &.{2}, &.{});
    defer callee_artifact.deinit();

    var module = try model.CompositionModule.init(allocator, &partitioned);
    errdefer module.deinit();
    if (fragment_count >= 1) try module.addFragment(.{
        .id = .{ .value = 1 },
        .partition = .{ .value = 10 },
        .pipeline = .choir,
        .pipeline_input = try records.key("loader.input", "1", "1"),

        .artifacts = &.{host_artifact},
        .exports = &.{.{ .name = "host", .symbol = "host_symbol", .abi_version = composition_root.abi.version }},
        .imports = &.{.{ .name = "invoke", .symbol = composition_root.abi.invoke_symbol, .abi_version = composition_root.abi.version, .kind = .runtime }},
        .provenance = .{ .path = "loader", .symbol = "host" },
    });
    if (fragment_count >= 2) try module.addFragment(.{
        .id = .{ .value = 2 },
        .partition = .{ .value = 20 },
        .pipeline = .accy,
        .pipeline_input = try records.key("loader.input", "2", "2"),

        .artifacts = &.{callee_artifact},
        .exports = &.{.{ .name = "callee", .symbol = "callee_symbol", .abi_version = composition_root.abi.version }},
        .provenance = .{ .path = "loader", .symbol = "callee" },
    });
    if (fragment_count >= 2) try module.addVariant(.{
        .id = .{ .value = 1 },
        .choice = .{
            .target = choir.product.productRef("composition-fixture", "1", "loader.target", "default"),
            .policy = choir.product.productRef("composition-fixture", "1", "loader.policy", "default"),
        },
        .fragments = &.{ .{ .value = 1 }, .{ .value = 2 } },
        .call_sites = &.{.{
            .id = .{ .value = 30 },
            .name = "call",
            .caller = .{ .value = 1 },
            .caller_export = "host",
            .runtime_import = "invoke",
            .callee = .{ .value = 2 },
            .callee_export = "callee",
            .inputs = &.{},
            .outputs = &.{},
            .abi_version = composition_root.abi.version,
            .provenance = .{ .path = "loader", .symbol = "call" },
        }},
    });
    return module;
}

fn materializer(context: *TestMaterializerContext) FragmentMaterializer {
    return .{
        .id = .{ .value = context.expected_id },
        .context = context,
        .materialize = testMaterialize,
    };
}

fn testChoice() @import("../root.zig").TargetChoiceSpec {
    const choir = @import("../../root.zig");
    return .{
        .target = choir.product.productRef("composition-fixture", "1", "loader.target", "default"),
        .policy = choir.product.productRef("composition-fixture", "1", "loader.policy", "default"),
    };
}

fn alternateChoice() @import("../root.zig").TargetChoiceSpec {
    const choir = @import("../../root.zig");
    return .{
        .target = choir.product.productRef("composition-fixture", "2", "loader.target", "default"),
        .policy = choir.product.productRef("composition-fixture", "1", "loader.policy", "default"),
    };
}

fn twoVariantModule(allocator: std.mem.Allocator) !@import("../root.zig").module.CompositionModule {
    const records = try fixture.Records.init(allocator);
    defer records.deinit();
    const composition_root = @import("../root.zig");
    var module = try testModule(allocator, 2);
    errdefer module.deinit();
    const host = module.fragments.items[0];
    const callee = module.fragments.items[1];
    try module.addFragment(.{
        .id = .{ .value = 3 },
        .partition = host.partition,
        .pipeline = host.pipeline,
        .pipeline_input = host.pipeline_input,

        .artifacts = host.artifacts,
        .exports = &.{.{ .name = "host", .symbol = "host_symbol", .abi_version = composition_root.abi.version }},
        .imports = &.{.{ .name = "invoke", .symbol = composition_root.abi.invoke_symbol, .abi_version = composition_root.abi.version, .kind = .runtime }},
        .provenance = .{ .path = "loader", .symbol = "host" },
    });
    try module.addFragment(.{
        .id = .{ .value = 4 },
        .partition = callee.partition,
        .pipeline = callee.pipeline,
        .pipeline_input = callee.pipeline_input,

        .artifacts = callee.artifacts,
        .exports = &.{.{ .name = "callee", .symbol = "callee_symbol", .abi_version = composition_root.abi.version }},
        .provenance = .{ .path = "loader", .symbol = "callee" },
    });
    try module.addVariant(.{
        .id = .{ .value = 2 },
        .choice = alternateChoice(),
        .fragments = &.{ .{ .value = 3 }, .{ .value = 4 } },
        .call_sites = &.{.{
            .id = .{ .value = 30 },
            .name = "call",
            .caller = .{ .value = 3 },
            .caller_export = "host",
            .runtime_import = "invoke",
            .callee = .{ .value = 4 },
            .callee_export = "callee",
            .inputs = &.{},
            .outputs = &.{},
            .abi_version = composition_root.abi.version,
            .provenance = .{ .path = "loader", .symbol = "call" },
        }},
    });
    try module.verify();
    return module;
}

test "composition module enforces exact partition fragment coverage" {
    const records = try fixture.Records.init(std.testing.allocator);
    defer records.deinit();
    const composition_root = @import("../root.zig");
    var incomplete = try testModule(std.testing.allocator, 2);
    defer incomplete.deinit();
    {
        const complete_fragments = incomplete.variants.items[0].fragments;
        defer incomplete.variants.items[0].fragments = complete_fragments;
        incomplete.variants.items[0].fragments = complete_fragments[0..1];
        try std.testing.expectError(error.MissingPartitionFragment, incomplete.verify());
    }

    var duplicate = try testModule(std.testing.allocator, 2);
    defer duplicate.deinit();
    const first = duplicate.fragments.items[0];
    try duplicate.addFragment(.{
        .id = .{ .value = 3 },
        .partition = first.partition,
        .pipeline = first.pipeline,
        .pipeline_input = first.pipeline_input,

        .artifacts = first.artifacts,
        .exports = &.{.{ .name = "duplicate", .symbol = "host_symbol", .abi_version = composition_root.abi.version }},
        .provenance = .{ .path = "loader", .symbol = "duplicate" },
    });
    const selected_call = duplicate.variants.items[0].call_sites[0];
    try std.testing.expectError(error.DuplicatePartitionFragment, duplicate.addVariant(.{
        .id = .{ .value = 2 },
        .choice = .{
            .target = @import("../../root.zig").product.productRef("composition-fixture", "2", "loader.target", "default"),
            .policy = @import("../../root.zig").product.productRef("composition-fixture", "1", "loader.policy", "default"),
        },
        .fragments = &.{ .{ .value = 1 }, .{ .value = 3 } },
        .call_sites = &.{.{
            .id = selected_call.id,
            .name = selected_call.name,
            .caller = selected_call.caller,
            .caller_export = selected_call.caller_export,
            .runtime_import = selected_call.runtime_import,
            .callee = selected_call.callee,
            .callee_export = selected_call.callee_export,
            .inputs = selected_call.inputs,
            .outputs = selected_call.outputs,
            .abi_version = selected_call.abi_version,
            .provenance = .{
                .path = selected_call.provenance.path,
                .symbol = selected_call.provenance.symbol,
                .line = selected_call.provenance.line,
                .column = selected_call.provenance.column,
            },
        }},
    }));
    {
        const selected_fragments = duplicate.variants.items[0].fragments;
        defer duplicate.variants.items[0].fragments = selected_fragments;
        duplicate.variants.items[0].fragments = &.{ selected_fragments[0], .{ .value = 3 } };
        try std.testing.expectError(error.DuplicatePartitionFragment, duplicate.verify());
    }
}

test "composition loader validates then materializes in supplied order" {
    const composition_root = @import("../root.zig");
    var module = try testModule(std.testing.allocator, 2);
    var module_owned = true;
    defer if (module_owned) module.deinit();
    var trace = TestTrace{};
    var host = TestMaterializerContext{
        .trace = &trace,
        .expected_id = 1,
        .entry_symbol = "host_symbol",
        .entry_address = @intFromPtr(&testEntry),
    };
    var callee = TestMaterializerContext{
        .trace = &trace,
        .expected_id = 2,
        .entry_symbol = "callee_symbol",
    };
    const materializers = [_]FragmentMaterializer{ materializer(&callee), materializer(&host) };
    module_owned = false;
    const owner = try LoadedComposition.initOwned(std.testing.allocator, module, testChoice(), &materializers, null);
    var owner_owned = true;
    defer if (owner_owned) owner.deinit();

    try std.testing.expectEqualSlices(u64, &.{ 2, 1 }, trace.materialized[0..trace.materialized_count]);
    try std.testing.expectEqual(@intFromPtr(&owner.module), trace.module_address);
    try std.testing.expectEqual(@as(u64, 2), owner.fragments[0].id.value);
    try std.testing.expectEqual(@as(u64, 1), owner.fragments[1].id.value);
    try std.testing.expectEqual(@intFromPtr(&testEntry), try owner.entryAddress(.{ .value = 1 }, "host"));
    try std.testing.expect(trace.last_lookup_was_declared_symbol);
    try std.testing.expectError(error.FragmentOutsideVariant, owner.entryAddress(.{ .value = 99 }, "host"));
    try std.testing.expectError(error.UndeclaredExport, owner.entryAddress(.{ .value = 1 }, "missing"));
    try std.testing.expectError(error.MissingEntry, owner.entryAddress(.{ .value = 2 }, "callee"));

    const entry = try composition_root.Entry.init(owner, .{ .value = 1 }, "host");
    const invocation = try composition_root.Invocation.init(std.testing.allocator, owner, &.{});
    try std.testing.expectEqual(composition_root.abi.Status.ok, entry.invoke(invocation));
    invocation.deinit();

    var no_resources: [0]composition_root.abi.Resource = .{};
    var frame = composition_root.abi.Frame.init(owner.context.owner_cookie, 91, &no_resources);
    frame.byte_size = @sizeOf(composition_root.abi.Frame) - 1;
    frame.status = 0xfeed;
    try std.testing.expectEqual(@backingInt(composition_root.abi.Status.incompatible_frame), invoke(owner.contextPointer(), 99, &frame));
    try std.testing.expectEqual(@as(u32, 0xfeed), frame.status);
    frame.byte_size = @sizeOf(composition_root.abi.Frame);
    try std.testing.expectEqual(@backingInt(composition_root.abi.Status.ok), invoke(owner.contextPointer(), 30, &frame));

    owner.deinit();
    owner_owned = false;
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, trace.destroyed[0..trace.destroyed_count]);
}

test "composition loader selects one complete target variant" {
    const composition_root = @import("../root.zig");

    const missing_target = try testModule(std.testing.allocator, 2);
    var missing_trace = TestTrace{};
    var missing_host = TestMaterializerContext{
        .trace = &missing_trace,
        .expected_id = 1,
        .entry_symbol = "host_symbol",
    };
    var missing_callee = TestMaterializerContext{
        .trace = &missing_trace,
        .expected_id = 2,
        .entry_symbol = "callee_symbol",
    };
    try std.testing.expectError(
        error.MissingTargetVariant,
        LoadedComposition.initOwned(
            std.testing.allocator,
            missing_target,
            alternateChoice(),
            &.{ materializer(&missing_host), materializer(&missing_callee) },
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), missing_trace.materialized_count);

    const wrong_materializers = try twoVariantModule(std.testing.allocator);
    try std.testing.expectError(
        error.MissingFragmentMaterializer,
        LoadedComposition.initOwned(
            std.testing.allocator,
            wrong_materializers,
            alternateChoice(),
            &.{ materializer(&missing_host), materializer(&missing_callee) },
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), missing_trace.materialized_count);

    const module = try twoVariantModule(std.testing.allocator);
    var trace = TestTrace{};
    var host = TestMaterializerContext{
        .trace = &trace,
        .expected_id = 3,
        .entry_symbol = "host_symbol",
        .entry_address = @intFromPtr(&testEntry),
    };
    var callee = TestMaterializerContext{
        .trace = &trace,
        .expected_id = 4,
        .entry_symbol = "callee_symbol",
    };
    const owner = try LoadedComposition.initOwned(
        std.testing.allocator,
        module,
        alternateChoice(),
        &.{ materializer(&callee), materializer(&host) },
        null,
    );
    defer owner.deinit();
    try std.testing.expectEqual(@as(u64, 2), owner.selected_variant.value);
    try std.testing.expectEqualSlices(u64, &.{ 4, 3 }, trace.materialized[0..trace.materialized_count]);
    try std.testing.expect(owner.loadedFragment(.{ .value = 1 }) == null);
    try std.testing.expect(owner.loadedFragment(.{ .value = 2 }) == null);
    try std.testing.expect(owner.loadedFragment(.{ .value = 3 }) != null);
    try std.testing.expect(owner.loadedFragment(.{ .value = 4 }) != null);
    try std.testing.expectError(error.FragmentOutsideVariant, owner.entryAddress(.{ .value = 1 }, "host"));
    try std.testing.expectEqual(@intFromPtr(&testEntry), try owner.entryAddress(.{ .value = 3 }, "host"));

    var no_resources: [0]composition_root.abi.Resource = .{};
    var frame = composition_root.abi.Frame.init(owner.context.owner_cookie, 1, &no_resources);
    try std.testing.expectEqual(
        @backingInt(composition_root.abi.Status.ok),
        invoke(owner.contextPointer(), 30, &frame),
    );
    try std.testing.expectEqual(@as(u64, 4), trace.last_invoked_callee);
}

test "composition loader validates all materializers before callbacks" {
    const incomplete = try testModule(std.testing.allocator, 1);
    var trace = TestTrace{};
    var host = TestMaterializerContext{ .trace = &trace, .expected_id = 1, .entry_symbol = "host_symbol" };
    try std.testing.expectError(
        error.MissingCompositionVariant,
        LoadedComposition.initOwned(std.testing.allocator, incomplete, testChoice(), &.{materializer(&host)}, null),
    );
    try std.testing.expectEqual(@as(usize, 0), trace.materialized_count);

    const duplicate = try testModule(std.testing.allocator, 2);
    try std.testing.expectError(
        error.DuplicateFragmentMaterializer,
        LoadedComposition.initOwned(std.testing.allocator, duplicate, testChoice(), &.{ materializer(&host), materializer(&host) }, null),
    );
    try std.testing.expectEqual(@as(usize, 0), trace.materialized_count);

    const missing = try testModule(std.testing.allocator, 2);
    var unknown = TestMaterializerContext{ .trace = &trace, .expected_id = 99, .entry_symbol = "unknown" };
    try std.testing.expectError(
        error.MissingFragmentMaterializer,
        LoadedComposition.initOwned(std.testing.allocator, missing, testChoice(), &.{ materializer(&host), materializer(&unknown) }, null),
    );
    try std.testing.expectEqual(@as(usize, 0), trace.materialized_count);
}

test "composition loader reverses partial materialization failure" {
    const module = try testModule(std.testing.allocator, 2);
    var trace = TestTrace{};
    var host = TestMaterializerContext{ .trace = &trace, .expected_id = 1, .entry_symbol = "host_symbol" };
    var callee = TestMaterializerContext{ .trace = &trace, .expected_id = 2, .entry_symbol = "callee_symbol", .fail = true };
    try std.testing.expectError(
        error.MaterializationFailed,
        LoadedComposition.initOwned(std.testing.allocator, module, testChoice(), &.{ materializer(&host), materializer(&callee) }, null),
    );
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, trace.materialized[0..trace.materialized_count]);
    try std.testing.expectEqualSlices(u64, &.{1}, trace.destroyed[0..trace.destroyed_count]);
}

test "composition loader destroys aliased materialized state once" {
    const module = try testModule(std.testing.allocator, 2);
    var trace = TestTrace{};
    const shared = try std.testing.allocator.create(TestRuntimeState);
    shared.* = .{ .trace = &trace, .id = 7, .entry_symbol = "shared", .entry_address = null };
    var host = TestMaterializerContext{ .trace = &trace, .expected_id = 1, .entry_symbol = "host_symbol", .shared_state = shared };
    var callee = TestMaterializerContext{ .trace = &trace, .expected_id = 2, .entry_symbol = "callee_symbol", .shared_state = shared, .vtable = &alias_vtable };
    try std.testing.expectError(
        error.DuplicateLoadedState,
        LoadedComposition.initOwned(std.testing.allocator, module, testChoice(), &.{ materializer(&host), materializer(&callee) }, null),
    );
    try std.testing.expectEqualSlices(u64, &.{7}, trace.destroyed[0..trace.destroyed_count]);
    try std.testing.expectEqual(@as(usize, 0), trace.alias_deinit_count);
}

test "composition loader survives every allocation failure" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var module = try testModule(allocator, 2);
            var module_owned = true;
            defer if (module_owned) module.deinit();
            var trace = TestTrace{};
            var host = TestMaterializerContext{ .trace = &trace, .expected_id = 1, .entry_symbol = "host_symbol" };
            var callee = TestMaterializerContext{ .trace = &trace, .expected_id = 2, .entry_symbol = "callee_symbol" };
            module_owned = false;
            const owner = try LoadedComposition.initOwned(allocator, module, testChoice(), &.{ materializer(&host), materializer(&callee) }, null);
            defer owner.deinit();
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "composition lifecycle observer delivery is serialized" {
    if (!sys.thread.threadsSupported()) return error.SkipZigTest;
    const composition_root = @import("../root.zig");
    var module = try testModule(std.testing.allocator, 2);
    var module_owned = true;
    defer if (module_owned) module.deinit();
    var trace = TestTrace{};
    var host = TestMaterializerContext{ .trace = &trace, .expected_id = 1, .entry_symbol = "host_symbol" };
    var callee = TestMaterializerContext{ .trace = &trace, .expected_id = 2, .entry_symbol = "callee_symbol" };
    var observer = ConcurrentObserver{};
    module_owned = false;
    const owner = try LoadedComposition.initOwned(
        std.testing.allocator,
        module,
        testChoice(),
        &.{ materializer(&host), materializer(&callee) },
        observer.observer(),
    );
    var owner_owned = true;
    defer if (owner_owned) owner.deinit();

    const invocation_count = 8;
    var invocations: [invocation_count]*composition_root.Invocation = undefined;
    var created_count: usize = 0;
    errdefer {
        var index = created_count;
        while (index != 0) {
            index -= 1;
            invocations[index].deinit();
        }
    }
    while (created_count < invocations.len) : (created_count += 1) {
        invocations[created_count] = try composition_root.Invocation.init(std.testing.allocator, owner, &.{});
    }

    const Worker = struct {
        invocation: *composition_root.Invocation,

        fn run(self: *@This()) void {
            self.invocation.deinit();
        }
    };
    var workers: [invocation_count]Worker = undefined;
    var threads: [invocation_count]sys.thread.JoinHandle = undefined;
    var spawned_count: usize = 0;
    errdefer {
        for (threads[0..spawned_count]) |thread| thread.join();
        for (invocations[spawned_count..]) |invocation| invocation.deinit();
        created_count = 0;
    }
    while (spawned_count < threads.len) : (spawned_count += 1) {
        workers[spawned_count] = .{ .invocation = invocations[spawned_count] };
        threads[spawned_count] = try sys.thread.spawn(Worker.run, .{&workers[spawned_count]});
    }
    for (threads) |thread| thread.join();
    created_count = 0;

    try std.testing.expectEqual(@as(u64, 0), owner.activeInvocationCount());
    try std.testing.expectEqual(invocation_count, observer.invocation_count.load(.acquire));
    try std.testing.expect(!observer.overlap.load(.acquire));
    owner.deinit();
    owner_owned = false;
    try std.testing.expectEqual(@as(usize, 2), observer.fragment_count.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), observer.composition_count.load(.acquire));
    try std.testing.expect(!observer.overlap.load(.acquire));
}

test "composition invocation remains active through destruction observation" {
    if (!sys.thread.threadsSupported()) return error.SkipZigTest;
    const composition_root = @import("../root.zig");
    var module = try testModule(std.testing.allocator, 2);
    var module_owned = true;
    defer if (module_owned) module.deinit();
    var trace = TestTrace{};
    var host = TestMaterializerContext{ .trace = &trace, .expected_id = 1, .entry_symbol = "host_symbol" };
    var callee = TestMaterializerContext{ .trace = &trace, .expected_id = 2, .entry_symbol = "callee_symbol" };
    var observer = BlockingInvocationObserver{};
    module_owned = false;
    const owner = try LoadedComposition.initOwned(
        std.testing.allocator,
        module,
        testChoice(),
        &.{ materializer(&host), materializer(&callee) },
        observer.observer(),
    );
    var owner_owned = true;
    defer if (owner_owned) owner.deinit();

    const invocation = try composition_root.Invocation.init(std.testing.allocator, owner, &.{});
    var invocation_owned = true;
    defer if (invocation_owned) invocation.deinit();
    const Worker = struct {
        fn run(value: *composition_root.Invocation) void {
            value.deinit();
        }
    };
    const thread = try sys.thread.spawn(Worker.run, .{invocation});
    invocation_owned = false;
    var joined = false;
    defer if (!joined) {
        observer.allow_exit.post();
        thread.join();
    };

    observer.entered.wait();
    try std.testing.expectEqual(@as(u64, 1), owner.activeInvocationCount());
    observer.allow_exit.post();
    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(u64, 0), owner.activeInvocationCount());

    owner.deinit();
    owner_owned = false;
}
