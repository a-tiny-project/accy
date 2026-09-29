const std = @import("std");
const choir = @import("choir");
const executable = @import("../../root.zig");
const composition = @import("../root.zig");
const cpu = @import("root.zig");

const Allocator = std.mem.Allocator;
const ChoirComposition = choir.composition;

pub fn materializeCpuObject(
    compilation: *cpu.CpuObjectCompilation,
    allocator: Allocator,
    module: *const ChoirComposition.CompositionModule,
    fragment: *const ChoirComposition.Fragment,
) !ChoirComposition.MaterializedFragment {
    try verifyDurableFragment(compilation, module, fragment);
    const compiled_fragment = compilation.compiled_fragment orelse return error.AlreadyMaterialized;
    const state = try allocator.create(cpu.runtime.State);
    state.* = cpu.runtime.State.init(allocator, fragment.id);
    var state_owned = true;
    errdefer if (state_owned) {
        state.deinitUnloaded();
        allocator.destroy(state);
    };

    const runtime_input_sizes = try retainByteSizes(allocator, compilation.metadata.input_boundaries);
    var input_sizes_owned = true;
    errdefer if (input_sizes_owned) allocator.free(runtime_input_sizes);
    const runtime_output_sizes = try retainByteSizes(allocator, compilation.metadata.output_boundaries);
    var output_sizes_owned = true;
    errdefer if (output_sizes_owned) allocator.free(runtime_output_sizes);

    compilation.compiled_fragment = null;
    const load_options = executable.FragmentCompilerOptions{
        .artifact_format = .cpu_object,
        .launch_tuning_artifact = compilation.launch_tuning_artifact,
    };
    const loaded_fragment = try executable.loadFragment(
        allocator,
        state.handle(),
        compiled_fragment,
        load_options,
    );
    var loaded_owned = true;
    errdefer if (loaded_owned) loaded_fragment.deinit();

    state.install(loaded_fragment, runtime_input_sizes, runtime_output_sizes);
    state_owned = false;
    loaded_owned = false;
    input_sizes_owned = false;
    output_sizes_owned = false;

    return .{
        .state = state,
        .vtable = &cpu.runtime.vtable,
    };
}

fn verifyDurableFragment(
    compilation: *const cpu.CpuObjectCompilation,
    module: *const ChoirComposition.CompositionModule,
    fragment: *const ChoirComposition.Fragment,
) !void {
    if (fragment.id.value != compilation.fragment_id.value or fragment.pipeline != .accy) return error.FragmentMismatch;
    if (!fragment.pipeline_input.eql(compilation.input_product)) return error.ProductMismatch;
    if (!artifactsEqual(fragment.artifacts, compilation.metadata.artifacts)) return error.ArtifactMismatch;
    const partition = module.source_module.partition(fragment.partition) orelse return error.FragmentMismatch;
    if (partition.pipeline != .accy) return error.FragmentMismatch;
    if (partition.inputs.len != compilation.metadata.input_boundaries.len or partition.outputs.len != compilation.metadata.output_boundaries.len) {
        return error.BoundaryMismatch;
    }
    for (partition.inputs, compilation.metadata.input_boundaries) |boundary_id, metadata| {
        const boundary = module.source_module.boundary(boundary_id) orelse return error.BoundaryMismatch;
        if (!boundaryMatches(boundary, metadata)) return error.BoundaryMismatch;
    }
    for (partition.outputs, compilation.metadata.output_boundaries) |boundary_id, metadata| {
        const boundary = module.source_module.boundary(boundary_id) orelse return error.BoundaryMismatch;
        if (!boundaryMatches(boundary, metadata)) return error.BoundaryMismatch;
    }
    const entry_symbol = compilation.metadata.entrySymbol() orelse return error.ArtifactMismatch;
    for (fragment.exports) |export_value| {
        if (std.mem.eql(u8, export_value.symbol, entry_symbol) and export_value.abi_version == ChoirComposition.abi.version) return;
    }
    return error.ArtifactMismatch;
}

fn boundaryMatches(boundary: *const ChoirComposition.Boundary, metadata: composition.BoundaryMetadata) bool {
    const byte_size = std.math.cast(u64, metadata.byte_size) orelse return false;
    return boundary.byte_size == byte_size and
        boundary.element_type == metadata.element_type and
        std.mem.eql(u64, boundary.dimensions, metadata.dimensions);
}

fn retainByteSizes(allocator: Allocator, boundaries: []const composition.BoundaryMetadata) Allocator.Error![]usize {
    const byte_sizes = try allocator.alloc(usize, boundaries.len);
    for (boundaries, byte_sizes) |boundary, *byte_size| byte_size.* = boundary.byte_size;
    return byte_sizes;
}

fn artifactsEqual(actual: []const choir.backends.artifact.Artifact, expected: []const choir.backends.artifact.Artifact) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |actual_artifact, expected_artifact| {
        if (!actual_artifact.eql(expected_artifact)) return false;
    }
    return true;
}
