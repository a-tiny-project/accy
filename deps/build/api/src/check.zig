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
