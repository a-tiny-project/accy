const std = @import("std");

pub fn unit(
    b: *std.Build,
    alloc_phase: *std.Build.Module,
    capacity: *std.Build.Module,
    metadata: *std.Build.Module,
    native_capacity: *std.Build.Module,
    optimize: std.builtin.OptimizeMode,
    filters: []const []const u8,
) void {
    const parent = b.step("test", "Run phase allocator and capacity tests");
    runtime(b, parent, "alloc-phase-tests", alloc_phase, filters);
    runtime(b, parent, "capacity-tests", capacity, filters);
    runtime(b, parent, "capacity-metadata-tests", metadata, filters);
    negative(b, parent, native_capacity, optimize);
}

fn runtime(
    b: *std.Build,
    parent: *std.Build.Step,
    name: []const u8,
    module: *std.Build.Module,
    filters: []const []const u8,
) void {
    const artifact = b.addTest(.{
        .name = name,
        .root_module = module,
        .filters = filters,
    });
    parent.dependOn(&b.addRunArtifact(artifact).step);
}

fn negative(
    b: *std.Build,
    parent: *std.Build.Step,
    capacity: *std.Build.Module,
    optimize: std.builtin.OptimizeMode,
) void {
    const Case = struct {
        name: []const u8,
        path: []const u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{
            .name = "missing-storage",
            .path = "src/capacity/negative/missing.zig",
            .expected = "invalid owner shape: missing_storage",
        },
        .{
            .name = "invalid-alignment",
            .path = "src/capacity/negative/alignment.zig",
            .expected = "invalid owner shape: invalid_storage_alignment",
        },
        .{
            .name = "wrong-storage",
            .path = "src/capacity/negative/declaration.zig",
            .expected = "invalid owner shape: wrong_storage_declaration",
        },
        .{
            .name = "allocator-limits",
            .path = "src/capacity/negative/allocator.zig",
            .expected = "invalid owner shape: stored_allocator",
        },
        .{
            .name = "indirect-allocator",
            .path = "src/capacity/negative/indirect.zig",
            .expected = "invalid owner shape: stored_allocator",
        },
        .{
            .name = "comptime-storage",
            .path = "src/capacity/negative/storage.zig",
            .expected = "invalid owner shape: comptime_storage",
        },
        .{
            .name = "comptime-capacity",
            .path = "src/capacity/negative/capacity.zig",
            .expected = "invalid owner shape: comptime_storage_bytes",
        },
        .{
            .name = "infallible-derive",
            .path = "src/capacity/negative/infallible.zig",
            .expected = "invalid owner shape: wrong_capacity_derive",
        },
        .{
            .name = "anyerror-derive",
            .path = "src/capacity/negative/anyerror.zig",
            .expected = "invalid owner shape: wrong_capacity_derive",
        },
        .{
            .name = "anyerror-init",
            .path = "src/capacity/negative/init.zig",
            .expected = "invalid owner shape: wrong_init",
        },
        .{
            .name = "fallible-activate",
            .path = "src/capacity/negative/activate.zig",
            .expected = "invalid owner shape: wrong_activate",
        },
        .{
            .name = "wrong-deinit",
            .path = "src/capacity/negative/deinit.zig",
            .expected = "invalid owner shape: wrong_deinit",
        },
        .{
            .name = "steady-allocator",
            .path = "src/capacity/negative/steady.zig",
            .expected = "invalid owner shape: steady_allocator_parameter",
        },
        .{
            .name = "missing-claim",
            .path = "src/capacity/negative/claim.zig",
            .expected = "invalid owner shape: missing_claim_declaration",
        },
        .{
            .name = "missing-work",
            .path = "src/capacity/negative/work.zig",
            .expected = "invalid owner shape: missing_work_limits",
        },
        .{
            .name = "weak-overload",
            .path = "src/capacity/negative/overload.zig",
            .expected = "invalid claim declaration: overload_shape_incompatible",
        },
        .{
            .name = "typed-field-path",
            .path = "src/capacity/negative/field.zig",
            .expected = "invalid Limits field path: missing",
        },
        .{
            .name = "typed-obligation",
            .path = "src/capacity/negative/obligation.zig",
            .expected = "invalid claim declaration: premise_obligation_unknown",
        },
        .{
            .name = "typed-binding",
            .path = "src/capacity/negative/binding.zig",
            .expected = "invalid claim declaration: owner_binding_missing",
        },
        .{
            .name = "typed-fragment",
            .path = "src/capacity/negative/fragment.zig",
            .expected = "invalid claim declaration: capacity_node_outside_fragment",
        },
    };
    for (cases) |case| {
        const module = b.createModule(.{
            .root_source_file = b.path(case.path),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "capacity", .module = capacity }},
        });
        const artifact = b.addTest(.{
            .name = b.fmt("capacity-negative-{s}", .{case.name}),
            .root_module = module,
        });
        artifact.expect_errors = .{ .contains = case.expected };
        parent.dependOn(&artifact.step);
    }
}
