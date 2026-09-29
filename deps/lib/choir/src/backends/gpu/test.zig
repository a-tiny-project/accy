const std = @import("std");
const choir = @import("../../root.zig");
const backends_gpu = @import("root.zig");
const gpu = @import("../../dialects/gpu/root.zig");
const spirv = backends_gpu.spirv;
const nvptx = backends_gpu.nvptx;
const lowering = backends_gpu.lowering;
const gpu_registration = backends_gpu.registration;

const GpuDialect = gpu.GpuDialect;
const SpirvDialect = spirv.SpirvDialect;
const NvptxDialect = nvptx.NvptxDialect;
const package_extension = gpu_registration.package_extension;
const dialect_registrations = gpu_registration.dialect_registrations;
const pass_registrations = lowering.pass_registrations;
const pipeline_registrations = lowering.pipeline_registrations;
const gpu_to_spirv_pipeline_name = lowering.gpu_to_spirv_pipeline_name;
const gpu_to_nvptx_pipeline_name = lowering.gpu_to_nvptx_pipeline_name;
const target_lowering_pipeline_count = lowering.target_lowering_pipeline_count;
const addTargetLoweringPipeline = lowering.addTargetLoweringPipeline;
const addGpuToNvptxPipeline = lowering.addGpuToNvptxPipeline;

test {
    _ = @import("features.zig");
    _ = @import("subgroup.zig");
    _ = @import("cpu/test.zig");
    _ = @import("metal/test.zig");
    _ = @import("nvptx/test.zig");
    _ = @import("spirv/test.zig");
    _ = @import("webgpu/test.zig");
}

fn expectSingleTargetLoweringPass(
    pm: *const choir.passes.PassManager,
    pass_name: []const u8,
) !void {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 1), pm.root.pipeline.items.len);
    switch (pm.root.pipeline.items[0]) {
        .pass => |pass| try testing.expectEqualStrings(pass_name, pass.name),
        .nested => try testing.expect(false),
    }
}

test "gpu package registers accelerator dialects and target lowering entries" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try choir.ir.Context.init(allocator, choir.ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    try ctx.requireRegistered();

    try testing.expectError(error.UnknownDialect, ctx.getOrLoadDialect("gpu"));

    var extension_registry = choir.extensions.ExtensionRegistry.init(allocator);
    defer extension_registry.deinit();
    try extension_registry.registerPackage(&ctx, package_extension);

    inline for (dialect_registrations) |registration| {
        _ = try ctx.getOrLoadDialect(registration.name);
    }

    try testing.expect(ctx.lookupOperation(GpuDialect.ThreadIdxOp.operation_name) != null);
    try testing.expect(ctx.lookupType(gpu.type_names.tma_desc) != null);
    try testing.expect(ctx.lookupOperation(SpirvDialect.ModuleOp.operation_name) != null);
    try testing.expect(ctx.lookupOperation(NvptxDialect.ThreadIdxOp.operation_name) != null);
    try testing.expect(!ctx.isBackendDialect("gpu"));
    try testing.expect(ctx.isBackendDialect("spirv"));
    try testing.expect(ctx.isBackendDialect("nvptx"));

    var pass_registry = choir.passes.PassRegistry.init(allocator);
    defer pass_registry.deinit();
    try extension_registry.registerPassEntriesTo(&pass_registry);

    inline for (pass_registrations) |registration| {
        try testing.expect(pass_registry.lookupPass(registration.name) != null);
    }
    inline for (pipeline_registrations) |registration| {
        try testing.expect(pass_registry.lookupPipeline(registration.name) != null);
    }
}

test "target lowering pipelines materialize from textual Choir registry" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try choir.ir.Context.init(allocator, choir.ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var extension_registry = choir.extensions.ExtensionRegistry.init(allocator);
    defer extension_registry.deinit();
    try extension_registry.registerPackage(&ctx, package_extension);

    var pass_registry = choir.passes.PassRegistry.init(allocator);
    defer pass_registry.deinit();
    try extension_registry.registerPassEntriesTo(&pass_registry);

    var pm = choir.passes.PassManager.init(allocator);
    defer pm.deinit();
    try choir.passes.parsePassPipeline(
        &pass_registry,
        gpu_to_spirv_pipeline_name ++ "," ++ gpu_to_nvptx_pipeline_name,
        &pm,
    );
    try testing.expectEqual(@as(usize, target_lowering_pipeline_count), pm.root.pipeline.items.len);

    const text = try choir.passes.formatPassManagerPipelineAlloc(allocator, &pm);
    defer allocator.free(text);
    const expected = spirv.gpu_to_spirv_pass_name ++ "," ++ nvptx.gpu_to_nvptx_pass_name;
    try testing.expectEqualStrings(expected, text);
}

test "target lowering pipelines preload produced accelerator dialects" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try choir.ir.Context.init(allocator, choir.ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    try ctx.requireRegistered();

    try choir.dialects.registerChoirDialect(&ctx);
    var extension_registry = choir.extensions.ExtensionRegistry.init(allocator);
    defer extension_registry.deinit();
    try extension_registry.registerPackage(&ctx, package_extension);

    _ = try ctx.getOrLoadDialect("builtin");
    const location = choir.ir.Location.getUnknown();
    const builtin_module = try choir.dialects.BuiltinDialect.ModuleOp.create(&ctx, location);

    try testing.expect(!ctx.isDialectLoaded("spirv"));
    var spirv_pm = choir.passes.PassManager.init(allocator);
    defer spirv_pm.deinit();
    try addTargetLoweringPipeline(&spirv_pm, .spirv);
    try expectSingleTargetLoweringPass(&spirv_pm, spirv.gpu_to_spirv_pass_name);
    try testing.expectEqual(choir.passes.PassResult.success, spirv_pm.run(builtin_module.op, &ctx));
    try testing.expect(ctx.isDialectLoaded("spirv"));

    try testing.expect(!ctx.isDialectLoaded("nvptx"));
    var nvptx_pm = choir.passes.PassManager.init(allocator);
    defer nvptx_pm.deinit();
    try addGpuToNvptxPipeline(&nvptx_pm);
    try expectSingleTargetLoweringPass(&nvptx_pm, nvptx.gpu_to_nvptx_pass_name);
    try testing.expectEqual(choir.passes.PassResult.success, nvptx_pm.run(builtin_module.op, &ctx));
    try testing.expect(ctx.isDialectLoaded("nvptx"));
}

test "gpu backends declaration coverage" {
    std.testing.refAllDecls(backends_gpu);
}

const stages = @import("fixture/stages.zig");
const calls = @import("calls.zig");

/// Builds a void helper chain. The direct vertex entry calls h0; the fragment
/// entry optionally reaches h0 through z1 and z2. Both entries are otherwise
/// valid stages, so the same source can exercise all three emitters.
fn callDepthSource(allocator: std.mem.Allocator, helpers: usize, indirect: bool, indirect_first: bool) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("builtin.module() {\n  ^bb0:\n");
    for (0..helpers) |index| {
        try out.writer.print(
            "    func.func() {{input_count = 0:i64, input_types = [], input_types_text = \"\", sym_name = #attr<func.sym_name>(\"h{d}\")}} {{\n      ^bb0:\n",
            .{index},
        );
        if (index + 1 < helpers) try out.writer.print("        func.call() {{callee = @h{d}}}\n", .{index + 1});
        try out.writer.writeAll("        func.return()\n    }\n");
    }
    if (indirect) {
        try out.writer.writeAll(
            "    func.func() {input_count = 0:i64, input_types = [], input_types_text = \"\", sym_name = #attr<func.sym_name>(\"z1\")} {\n" ++
                "      ^bb0:\n        func.call() {callee = @z2}\n        func.return()\n    }\n" ++
                "    func.func() {input_count = 0:i64, input_types = [], input_types_text = \"\", sym_name = #attr<func.sym_name>(\"z2\")} {\n" ++
                "      ^bb0:\n        func.call() {callee = @h0}\n        func.return()\n    }\n",
        );
    }
    if (indirect_first) try writeDepthFragment(&out.writer, indirect);
    try out.writer.writeAll(
        "    func.func() {input_count = 0:i64, input_types = [], input_types_text = \"\", stage = #attr<gpu.stage>(\"vertex\"), sym_name = #attr<func.sym_name>(\"depth_vertex\")} {\n" ++
            "      ^bb0:\n" ++
            "        %0, %1, %2 = gpu.stage_input() {location = 0:i64} : !arith.f32, !arith.f32, !arith.f32\n" ++
            "        %3, %4, %5, %6 = gpu.stage_input() {location = 2:i64} : !arith.f32, !arith.f32, !arith.f32, !arith.f32\n" ++
            "        %7 = arith.constant() properties(1:f64) : !arith.f32\n" ++
            "        func.call() {callee = @h0}\n" ++
            "        gpu.position(%0, %1, %2, %7)\n" ++
            "        gpu.stage_output(%3, %4, %5, %6) {location = 0:i64}\n" ++
            "        func.return()\n    }\n",
    );
    if (!indirect_first) try writeDepthFragment(&out.writer, indirect);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn writeDepthFragment(writer: *std.Io.Writer, indirect: bool) !void {
    try writer.writeAll(
        "    func.func() {input_count = 0:i64, input_types = [], input_types_text = \"\", stage = #attr<gpu.stage>(\"fragment\"), sym_name = #attr<func.sym_name>(\"depth_fragment\")} {\n" ++
            "      ^bb0:\n" ++
            "        %8, %9, %10, %11 = gpu.stage_input() {location = 0:i64} : !arith.f32, !arith.f32, !arith.f32, !arith.f32\n",
    );
    if (indirect) try writer.writeAll("        func.call() {callee = @z1}\n");
    try writer.writeAll("        gpu.stage_output(%8, %9, %10, %11) {location = 0:i64}\n        func.return()\n    }\n");
}

test "shared helper depth is independent of stage entry order" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |indirect_first| {
        const source = try callDepthSource(allocator, 63, true, indirect_first);
        defer allocator.free(source);
        try expectCallDepthRefused(source);
    }
}

fn depthCase(source: []const u8) stages.Case {
    return .{
        .name = "call-depth",
        .source = source,
        .vertex = "depth_vertex",
        .fragment = "depth_fragment",
    };
}

fn expectCallDepthRefused(source: []const u8) !void {
    const allocator = std.testing.allocator;
    {
        var session: stages.Session = undefined;
        try session.init(allocator, .testing, source, true);
        defer session.deinit(allocator);
        try std.testing.expectError(error.CallChainTooDeep, stages.emitSpirv(allocator, session.module));
    }
    var session: stages.Session = undefined;
    try session.init(allocator, .testing, source, false);
    defer session.deinit(allocator);
    try std.testing.expectError(error.CallChainTooDeep, stages.emitMsl(allocator, session.module, depthCase(source)));
    var refusal: backends_gpu.cpu.StageRefusal = .{};
    try std.testing.expectError(error.CallChainTooDeep, backends_gpu.cpu.lowerStagesToHost(allocator, session.module, &refusal));
    try std.testing.expectEqualStrings(choir.dialects.func.FuncDialect.CallOp.operation_name, refusal.operation);
}

test "stage helper call depth 63 plans and depth 64 refuses on every backend" {
    const allocator = std.testing.allocator;
    const admitted = try callDepthSource(allocator, 64, false, false);
    defer allocator.free(admitted);
    {
        var session: stages.Session = undefined;
        try session.init(allocator, .testing, admitted, true);
        defer session.deinit(allocator);
        const words = try stages.emitSpirv(allocator, session.module);
        defer allocator.free(words);
        try std.testing.expect(words.len > 0);
    }
    var session: stages.Session = undefined;
    try session.init(allocator, .testing, admitted, false);
    defer session.deinit(allocator);
    var plan = try calls.Plan.init(allocator, session.module, null);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 64), plan.helpers.items.len);
    const msl = try stages.emitMsl(allocator, session.module, depthCase(admitted));
    defer allocator.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "h63(") != null);
    const host = try backends_gpu.cpu.lowerStagesToHost(allocator, session.module, null);
    defer host.erase();

    const refused = try callDepthSource(allocator, 65, false, false);
    defer allocator.free(refused);
    try expectCallDepthRefused(refused);
}

/// `case`'s source with its one `needle` replaced. The caller owns it.
fn stageVariant(case: stages.Case, needle: []const u8, replacement: []const u8) ![]u8 {
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, case.source, needle));
    return std.mem.replaceOwned(u8, std.testing.allocator, case.source, needle, replacement);
}

/// Runs SPIR-V, MSL and the CPU twin over `source` and expects each to refuse it as
/// `UnsupportedStageMemory`, the twin naming `operation`.
fn expectStageMemoryRefused(case: stages.Case, source: []const u8, operation: []const u8) !void {
    const allocator = std.testing.allocator;
    {
        var session: stages.Session = undefined;
        try session.init(allocator, .testing, source, true);
        defer session.deinit(allocator);
        try std.testing.expectError(error.UnsupportedStageMemory, stages.emitSpirv(allocator, session.module));
    }
    var session: stages.Session = undefined;
    try session.init(allocator, .testing, source, false);
    defer session.deinit(allocator);
    try std.testing.expectError(error.UnsupportedStageMemory, stages.emitMsl(allocator, session.module, case));
    var refusal: backends_gpu.cpu.StageRefusal = .{};
    try std.testing.expectError(error.UnsupportedStageMemory, backends_gpu.cpu.lowerStagesToHost(allocator, session.module, &refusal));
    try std.testing.expectEqualStrings(operation, refusal.operation);
}

fn expectHelperSignatureRefused(case: stages.Case, helper: []const u8) !void {
    const allocator = std.testing.allocator;
    {
        var session: stages.Session = undefined;
        try session.init(allocator, .testing, case.source, true);
        defer session.deinit(allocator);
        try std.testing.expectError(error.UnsupportedHelperSignature, stages.emitSpirv(allocator, session.module));
    }
    var session: stages.Session = undefined;
    try session.init(allocator, .testing, case.source, false);
    defer session.deinit(allocator);
    try std.testing.expectError(error.UnsupportedHelperSignature, stages.emitMsl(allocator, session.module, case));
    var refusal: backends_gpu.cpu.StageRefusal = .{};
    try std.testing.expectError(error.UnsupportedHelperSignature, backends_gpu.cpu.lowerStagesToHost(allocator, session.module, &refusal));
    try std.testing.expectEqualStrings(choir.dialects.func.FuncDialect.FuncOp.operation_name, refusal.operation);
    try std.testing.expectEqualStrings(helper, refusal.helper);
}

test "every stage backend names an unsupported helper memref result" {
    try expectHelperSignatureRefused(.{
        .name = "helper_result",
        .source = @embedFile("fixture/helper_result.txt"),
        .vertex = "helper_vertex",
        .fragment = "helper_fragment",
    }, "borrow");
}

test "every stage backend refuses repeated alloca operands" {
    try expectHelperSignatureRefused(.{
        .name = "helper_alias",
        .source = @embedFile("fixture/helper_alias.txt"),
        .vertex = "helper_vertex",
        .fragment = "helper_fragment",
    }, "read_material");
}

test "every stage backend refuses a helper subview operand by signature name" {
    try expectHelperSignatureRefused(.{
        .name = "helper_subview",
        .source = @embedFile("fixture/helper_subview.txt"),
        .vertex = "helper_vertex",
        .fragment = "helper_fragment",
    }, "read_material");
}

test "stage helper local memref addresses reach both device emitters and the CPU twin" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { case: stages.Case, pointers: usize }{
        .{ .case = stages.calls_case, .pointers = 2 },
        .{ .case = .{
            .name = "helper_param",
            .source = @embedFile("fixture/helper_param.txt"),
            .vertex = "helper_vertex",
            .fragment = "helper_fragment",
        }, .pointers = 1 },
    };
    for (cases) |entry| {
        const case = entry.case;
        var session: stages.Session = undefined;
        try session.init(allocator, .testing, case.source, true);
        defer session.deinit(allocator);
        const words = try stages.emitSpirv(allocator, session.module);
        defer allocator.free(words);
        try std.testing.expect(words.len > 0);
        var parsed: stages.Session = undefined;
        try parsed.init(allocator, .testing, case.source, false);
        defer parsed.deinit(allocator);
        const msl = try stages.emitMsl(allocator, parsed.module, case);
        defer allocator.free(msl);
        try std.testing.expect(std.mem.count(u8, msl, "thread float*") >= entry.pointers);
        const host = try backends_gpu.cpu.lowerStagesToHost(allocator, parsed.module, null);
        defer host.erase();
    }
}

test "every stage backend refuses a helper that reads a global by one name" {
    const Memref = choir.dialects.MemrefDialect;
    const case = stages.calls_case;
    const source = try stageVariant(
        case,
        "%5 = memref.alloca() : !memref<1,arith.f32,local>",
        "%5 = memref.get_global() {sym_name = \"table\"} : !memref<1,arith.f32,device>",
    );
    defer std.testing.allocator.free(source);
    try expectStageMemoryRefused(case, source, Memref.GetGlobalOp.operation_name);
}

test "every stage backend refuses a stage that allocates shared memory by one name" {
    const Memref = choir.dialects.MemrefDialect;
    const case = stages.alloca_case;
    const source = try stageVariant(
        case,
        "%16 = memref.alloca() : !memref<4,arith.f32,local>",
        "%16 = memref.alloc() : !memref<4,arith.f32,shared>",
    );
    defer std.testing.allocator.free(source);
    try expectStageMemoryRefused(case, source, Memref.AllocOp.operation_name);
}

test "a kernel keeps shared memory and atomics through the call plan" {
    const allocator = std.testing.allocator;
    var session: stages.Session = undefined;
    try session.init(allocator, .testing, @embedFile("metal/fixture/shared.txt"), false);
    defer session.deinit(allocator);
    var plan = try calls.Plan.init(allocator, session.module, null);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 0), plan.helpers.items.len);
}

test "a stage module's push extent is the one the SPIR-V emitter declares" {
    const allocator = std.testing.allocator;
    const all = stages.cases ++ [_]stages.Case{ stages.alloca_case, stages.contraction_case, stages.gradient_case, stages.calls_case };
    var reads: u32 = 0;
    for (all) |case| {
        var session: stages.Session = undefined;
        try session.init(allocator, .testing, case.source, true);
        defer session.deinit(allocator);
        var codegen = spirv.emitter.SpirvCodegen.init(allocator);
        defer codegen.deinit();
        const words = try codegen.emitModuleWords(session.module);
        allocator.free(words);
        const extent = gpu.stage.pushExtent(session.module).?;
        try std.testing.expectEqual(codegen.push_extent, extent);
        if (std.mem.eql(u8, case.name, "pushed")) try std.testing.expectEqual(@as(u32, 16), extent);
        if (std.mem.eql(u8, case.name, "contraction")) try std.testing.expectEqual(@as(u32, 20), extent);
        if (extent != 0) reads += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), reads);
}
