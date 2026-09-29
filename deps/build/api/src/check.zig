const std = @import("std");
const module = @import("module.zig");

const Original = struct {
    name: []const u8,
    step: *std.Build.Step,
};

pub fn registerTwins(b: *std.Build) void {
    var originals: std.ArrayListUnmanaged(Original) = .empty;
    var iterator = b.top_level_steps.iterator();
    while (iterator.next()) |entry| {
        originals.append(b.graph.arena, .{
            .name = entry.key_ptr.*,
            .step = &entry.value_ptr.*.step,
        }) catch @panic("OOM");
    }
    var projections: std.AutoHashMapUnmanaged(
        *std.Build.Step.Compile,
        *std.Build.Step.Compile,
    ) = .empty;
    for (originals.items) |original| {
        const name = b.fmt("{s}-check", .{original.name});
        if (b.top_level_steps.contains(name)) continue;
        var compiles: std.ArrayListUnmanaged(*std.Build.Step.Compile) = .empty;
        collectCompiles(b, original.step, &compiles);
        if (compiles.items.len == 0) continue;
        const twin = b.step(
            name,
            b.fmt(
                "Check {s} without emitting its products or running its effects",
                .{original.name},
            ),
        );
        for (compiles.items) |compile| {
            const entry = projections.getOrPut(b.graph.arena, compile) catch @panic("OOM");
            if (!entry.found_existing) entry.value_ptr.* = project(compile);
            twin.dependOn(&entry.value_ptr.*.step);
        }
    }
}

pub fn project(original: *const std.Build.Step.Compile) *std.Build.Step.Compile {
    const b = original.step.owner;
    const projected = b.graph.arena.create(std.Build.Step.Compile) catch @panic("OOM");
    projected.* = original.*;
    projected.step = .init(.{
        .tag = .compile,
        .name = b.fmt("check {s}", .{original.step.name}),
        .owner = b,
        .max_rss = original.step.max_rss,
    });
    projected.step.dependencies.appendSlice(
        b.graph.arena,
        original.step.dependencies.items,
    ) catch @panic("OOM");
    inline for (@typeInfo(std.Build.Step.Compile).@"struct".field_names) |name| {
        if (@FieldType(std.Build.Step.Compile, name) ==
            std.Build.Configuration.OptionalGeneratedFileIndex)
        {
            @field(projected, name) = .none;
        }
    }
    std.debug.assert(projected != original);
    std.debug.assert(projected.root_module == original.root_module);
    return projected;
}

fn collectCompiles(
    b: *std.Build,
    current: *std.Build.Step,
    compiles: *std.ArrayListUnmanaged(*std.Build.Step.Compile),
) void {
    var visited: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    var pending: std.ArrayListUnmanaged(*std.Build.Step) = .empty;
    pending.append(b.graph.arena, current) catch @panic("OOM");
    while (pending.pop()) |step| {
        const entry = visited.getOrPut(b.graph.arena, step) catch @panic("OOM");
        if (entry.found_existing) continue;
        if (step.cast(std.Build.Step.Compile)) |compile| {
            compiles.append(b.graph.arena, compile) catch @panic("OOM");
            continue;
        }
        pending.appendSlice(b.graph.arena, step.dependencies.items) catch @panic("OOM");
    }
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

fn testCompile(b: *std.Build) *std.Build.Step.Compile {
    const module_options = module.ModuleOptions{
        .target = b.graph.host,
        .optimize = .debug,
    };
    return b.addTest(.{
        .name = "sample",
        .root_module = b.createModule(module_options.createOptions(b, "sample.zig", &.{})),
        .filters = &.{"selected test"},
    });
}

fn testTwin(b: *std.Build, name: []const u8) !*std.Build.Step.Compile {
    const top = b.top_level_steps.get(name) orelse return error.CheckTwinMissing;
    try std.testing.expectEqual(@as(usize, 1), top.step.dependencies.items.len);
    return top.step.dependencies.items[0].cast(std.Build.Step.Compile) orelse
        error.CheckTwinDoesNotCompile;
}

test "check projection preserves semantic inputs and isolates output requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try testBuild(arena.allocator());
    const original = testCompile(b);
    original.entry = .disabled;
    original.rdynamic = true;
    original.use_llvm = true;
    original.expect_errors = .{ .contains = "expected rejection" };
    const prerequisite = b.step("input", "Prepare required input");
    original.step.dependOn(prerequisite);
    inline for (@typeInfo(std.Build.Step.Compile).@"struct".field_names) |name| {
        if (@FieldType(std.Build.Step.Compile, name) ==
            std.Build.Configuration.OptionalGeneratedFileIndex)
        {
            @field(original, name) = .init(b.graph.addGeneratedFile(&original.step));
        }
    }
    const projected = project(original);
    inline for (@typeInfo(std.Build.Step.Compile).@"struct".field_names) |name| {
        if (@FieldType(std.Build.Step.Compile, name) ==
            std.Build.Configuration.OptionalGeneratedFileIndex)
        {
            try std.testing.expect(@field(original, name) != .none);
            try std.testing.expect(@field(projected, name) == .none);
        } else if (!std.mem.eql(u8, name, "step")) {
            try std.testing.expect(std.meta.eql(@field(original, name), @field(projected, name)));
        }
    }
    try std.testing.expect(projected.step.dependencies.items.ptr !=
        original.step.dependencies.items.ptr);
    try std.testing.expectEqualSlices(
        *std.Build.Step,
        original.step.dependencies.items,
        projected.step.dependencies.items,
    );
    projected.step.dependOn(b.step("projection-only", "Prepare check-only input"));
    try std.testing.expectEqual(@as(usize, 1), original.step.dependencies.items.len);
}

test "check twins share projections and retain explicit and suffixed roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try testBuild(arena.allocator());
    const original = testCompile(b);
    const run = b.addRunArtifact(original);
    for ([_][]const u8{ "sample", "alias", "custom-check", "explicit" }) |name| {
        b.step(name, "Run selected tests").dependOn(&run.step);
    }
    const explicit = b.step("explicit-check", "User-owned check");
    registerTwins(b);
    const projected = try testTwin(b, "sample-check");
    try std.testing.expect(projected != original);
    try std.testing.expect(projected == try testTwin(b, "alias-check"));
    try std.testing.expect(projected == try testTwin(b, "custom-check-check"));
    try std.testing.expect(&b.top_level_steps.get("explicit-check").?.step == explicit);
    try std.testing.expect(original.generated_bin != .none);
    try std.testing.expect(projected.generated_bin == .none);
    try std.testing.expectEqual(@as(usize, 0), projected.step.dependencies.items.len);
}

test "check compile frontier retains required generators without extra projections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try testBuild(arena.allocator());
    const generator = testCompile(b);
    const produce = b.addRunArtifact(generator);
    const product = testCompile(b);
    product.step.dependOn(&produce.step);
    b.step("product", "Compile generated product").dependOn(&product.step);
    registerTwins(b);
    const projected = try testTwin(b, "product-check");
    try std.testing.expectEqual(@as(usize, 1), projected.step.dependencies.items.len);
    try std.testing.expect(projected.step.dependencies.items[0] == &produce.step);
    try std.testing.expect(generator.generated_bin != .none);
    try std.testing.expect(projected.generated_bin == .none);
}
