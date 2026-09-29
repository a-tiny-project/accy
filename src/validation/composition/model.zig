const std = @import("std");
const choir = @import("choir");
const namespace = @import("root.zig");

const Allocator = std.mem.Allocator;
const composition = choir.composition;
const Artifact = choir.backends.artifact.Artifact;
const source = namespace.source;

pub const Products = struct {
    choice: composition.TargetChoiceSpec,
    host_artifact: *const Artifact,
    host_plan: *const composition.FragmentPlan,
    accy_artifacts: []const Artifact,
    accy_plan: *const composition.FragmentPlan,
};

pub fn buildComposition(
    allocator: Allocator,
    program: *const source.Program,
    products: Products,
) !composition.CompositionModule {
    var module = try composition.CompositionModule.init(allocator, &program.partitioned);
    errdefer module.deinit();
    try module.addFragment(.{
        .id = products.host_plan.id,
        .partition = products.host_plan.input.partition,
        .pipeline = products.host_plan.input.pipeline,
        .pipeline_input = products.host_plan.input.product,
        .artifacts = &.{products.host_artifact.*},
        .exports = &.{.{
            .name = "entry",
            .symbol = products.host_plan.export_symbol,
            .abi_version = products.host_plan.abi_version,
        }},
        .imports = &.{.{
            .name = "invoke",
            .symbol = composition.abi.invoke_symbol,
            .abi_version = composition.abi.version,
            .kind = .runtime,
        }},
        .provenance = .{
            .path = source.source_path,
            .symbol = source.host_symbol,
            .line = 1,
            .column = 1,
        },
    });
    try module.addFragment(.{
        .id = products.accy_plan.id,
        .partition = products.accy_plan.input.partition,
        .pipeline = products.accy_plan.input.pipeline,
        .pipeline_input = products.accy_plan.input.product,
        .artifacts = products.accy_artifacts,
        .exports = &.{.{
            .name = source.accy_export_name,
            .symbol = products.accy_plan.export_symbol,
            .abi_version = products.accy_plan.abi_version,
        }},
        .provenance = .{
            .path = source.source_path,
            .symbol = program.add.symbol,
            .line = 2,
            .column = 5,
        },
    });
    try module.addVariant(.{
        .id = source.composition_variant,
        .choice = products.choice,
        .fragments = &.{ products.host_plan.id, products.accy_plan.id },
        .call_sites = &.{.{
            .id = program.add.call_site,
            .name = "hybrid/add",
            .caller = products.host_plan.id,
            .caller_export = "entry",
            .runtime_import = "invoke",
            .callee = products.accy_plan.id,
            .callee_export = source.accy_export_name,
            .inputs = &.{ program.add.lhs, program.add.rhs },
            .outputs = &.{program.add.output},
            .abi_version = composition.abi.version,
            .provenance = .{
                .path = source.source_path,
                .symbol = program.add.symbol,
                .line = 2,
                .column = 5,
            },
        }},
    });
    try module.verify();
    return module;
}
