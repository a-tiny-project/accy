const std = @import("std");
const emitter = @import("root.zig");

test "spirv emitter declaration coverage" {
    std.testing.refAllDecls(emitter.codegen);
    std.testing.refAllDecls(emitter.catalog);
    std.testing.refAllDecls(emitter.dialect);
    std.testing.refAllDecls(emitter.emit);
    std.testing.refAllDecls(emitter.gpu);
    std.testing.refAllDecls(emitter.module);
    std.testing.refAllDecls(emitter.memory);
    std.testing.refAllDecls(emitter.plan);
    std.testing.refAllDecls(emitter.scalar);
    std.testing.refAllDecls(emitter.spec);
    std.testing.refAllDecls(emitter.stage);
    std.testing.refAllDecls(emitter.validation);
    std.testing.refAllDecls(emitter.ops);
    std.testing.refAllDecls(emitter);
}

const abi = @import("gpu_abi");
const choir = @import("../../../../root.zig");
const fixture = @import("../../fixture/root.zig");
const registration = @import("../../registration.zig");

fn emitFixture(source: []const u8, entry_name: []const u8, limits: abi.Limits) !emitter.plan.Emission {
    const allocator = std.testing.allocator;
    var ctx = try choir.ir.Context.init(allocator, choir.ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try registration.prepareCompilationDialects(&ctx);
    const module = try fixture.lower(&ctx, source, .spirv);
    defer module.erase();
    return emitter.plan.emitPlanWords(allocator, module, entry_name, limits, .{});
}

fn emitScalars(limits: abi.Limits) !emitter.plan.Emission {
    return emitFixture(fixture.scalars, "test_scalars", limits);
}

test "spirv emitter returns the push-constant layout it emitted" {
    const emission = try emitScalars(.{});
    defer std.testing.allocator.free(emission.words);
    const layout = emission.push_constants;
    try std.testing.expectEqual(@as(u8, 3), layout.count);
    try std.testing.expectEqual(@as(u32, 0), layout.member(0).offset);
    try std.testing.expectEqual(@as(u32, 8), layout.member(1).offset);
    try std.testing.expectEqual(@as(u32, 8), layout.member(1).byte_size);
    try std.testing.expectEqual(@as(u32, 16), layout.member(2).offset);
    try std.testing.expectEqual(@as(u8, 20), layout.byte_size);
}

test "spirv emitter refuses a push-constant block over the target limit" {
    try std.testing.expectError(
        error.CapabilityMismatch,
        emitScalars(.{ .push_constant_bytes = 16 }),
    );
}

test "spirv emitter writes subgroup group operations as literal operands" {
    const emission = try emitFixture(fixture.subgroup, "test_subgroup", .{});
    defer std.testing.allocator.free(emission.words);
    const words = emission.words;
    var reduce_count: u32 = 0;
    var scan_count: u32 = 0;
    var index: usize = 5;
    while (index < words.len) {
        const word_count = words[index] >> 16;
        try std.testing.expect(word_count > 0);
        if (@as(u16, @truncate(words[index])) == emitter.ops.SpirvOp.GroupNonUniformFAdd) {
            try std.testing.expectEqual(@as(u32, 6), word_count);
            switch (words[index + 4]) {
                0 => reduce_count += 1,
                2 => scan_count += 1,
                else => return error.TestUnexpectedResult,
            }
        }
        index += word_count;
    }
    try std.testing.expectEqual(@as(usize, words.len), index);
    try std.testing.expectEqual(@as(u32, 1), reduce_count);
    try std.testing.expectEqual(@as(u32, 1), scan_count);
}

const stages = fixture.stages;
const spec = emitter.spec;
const SpirvOp = emitter.ops.SpirvOp;

/// Opcode counts and entry-point facts read back from emitted words.
const Census = struct {
    opcodes: [512]u32 = @splat(0),
    models: [2]u32 = undefined,
    entries: u32 = 0,
    decorations: [64]u32 = @splat(0),
    builtins: [64]u32 = @splat(0),
    modes: [32]u32 = @splat(0),
    /// Declared capabilities, in declaration order.
    capabilities: [16]u32 = undefined,
    capability_count: u32 = 0,

    fn of(words: []const u32) !Census {
        var census: Census = .{};
        var index: usize = 5;
        while (index < words.len) {
            const count = words[index] >> 16;
            const opcode: u16 = @truncate(words[index]);
            try std.testing.expect(count > 0 and index + count <= words.len);
            census.opcodes[opcode] += 1;
            switch (opcode) {
                SpirvOp.EntryPoint => {
                    census.models[census.entries] = words[index + 1];
                    census.entries += 1;
                },
                SpirvOp.ExecutionMode => census.modes[words[index + 2]] += 1,
                SpirvOp.Capability => {
                    try std.testing.expect(census.capability_count < census.capabilities.len);
                    census.capabilities[census.capability_count] = words[index + 1];
                    census.capability_count += 1;
                },
                SpirvOp.Decorate => {
                    census.decorations[words[index + 2]] += 1;
                    if (words[index + 2] == spec.Decoration.BuiltIn) {
                        census.builtins[words[index + 3]] += 1;
                    }
                },
                else => {},
            }
            index += count;
        }
        try std.testing.expectEqual(words.len, index);
        return census;
    }

    fn declares(census: *const Census, capability: u32) bool {
        return std.mem.indexOfScalar(u32, census.capabilities[0..census.capability_count], capability) != null;
    }
};

fn emitStageCase(case: stages.Case) ![]u32 {
    const allocator = std.testing.allocator;
    var ctx = try choir.ir.Context.init(allocator, choir.ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try registration.prepareCompilationDialects(&ctx);
    const module = try fixture.lower(&ctx, case.source, .spirv);
    defer module.erase();
    return stages.emitSpirv(allocator, module);
}

test "spirv stage local array has a Function variable before ordinary instructions" {
    const words = try emitStageCase(stages.alloca_case);
    defer std.testing.allocator.free(words);
    const classes = try variableClasses(words);
    const census = try Census.of(words);
    try std.testing.expectEqual(@as(u32, 2), classes[spec.StorageClass.Function]);
    try std.testing.expect(census.opcodes[SpirvOp.Store] >= 5);
    try std.testing.expectEqual(@as(u32, 10), census.opcodes[SpirvOp.AccessChain]);

    var after_label = false;
    var found = false;
    var index: usize = 5;
    while (index < words.len) {
        const count = words[index] >> 16;
        const opcode: u16 = @truncate(words[index]);
        if (opcode == SpirvOp.Label) {
            after_label = true;
        } else if (after_label and opcode == SpirvOp.Variable and words[index + 3] == spec.StorageClass.Function) {
            found = true;
            break;
        } else if (after_label and opcode != SpirvOp.FunctionEnd and opcode != SpirvOp.Function) {
            after_label = false;
        }
        index += count;
    }
    try std.testing.expect(found);
}

test "spirv stage refuses dynamic function-local array" {
    const source = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        stages.alloca_case.source,
        "%16 = memref.alloca() : !memref<4,arith.f32,local>",
        "%16 = memref.alloca(%12) : !memref<?,arith.f32,local>",
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectError(error.UnsupportedStageMemory, emitStageSource(source));
}

test "spirv emitter writes one vertex and one fragment entry per stage module" {
    for (stages.cases) |case| {
        const words = try emitStageCase(case);
        defer std.testing.allocator.free(words);
        const census = try Census.of(words);
        try std.testing.expectEqual(@as(u32, 2), census.entries);
        try std.testing.expectEqual(spec.ExecutionModel.Vertex, census.models[0]);
        try std.testing.expectEqual(spec.ExecutionModel.Fragment, census.models[1]);
        try std.testing.expectEqual(@as(u32, 1), census.modes[spec.ExecutionMode.OriginUpperLeft]);
        try std.testing.expectEqual(@as(u32, 0), census.modes[spec.ExecutionMode.LocalSize]);
        try std.testing.expectEqual(@as(u32, 0), census.opcodes[SpirvOp.SpecConstant]);
        const textured = std.mem.count(u8, case.source, "gpu.sampled_texture") > 0;
        const sampled_images: u32 = if (textured) 1 else 0;
        try std.testing.expectEqual(sampled_images, census.opcodes[SpirvOp.TypeSampledImage]);
        try std.testing.expectEqual(@as(u32, 1), census.builtins[emitter.gpu.SpvBuiltIn.Position]);
    }
}

test "spirv stage interfaces carry locations, builtins, flat integers and bindings" {
    const words = try emitStageCase(stages.cases[1]);
    defer std.testing.allocator.free(words);
    const census = try Census.of(words);
    const builtin = emitter.gpu.SpvBuiltIn;
    const stage_builtins = .{
        builtin.VertexIndex,
        builtin.InstanceIndex,
        builtin.FragCoord,
        builtin.FrontFacing,
    };
    inline for (stage_builtins) |kind| {
        try std.testing.expectEqual(@as(u32, 1), census.builtins[kind]);
    }
    try std.testing.expectEqual(@as(u32, 6), census.decorations[spec.Decoration.Location]);
    try std.testing.expectEqual(@as(u32, 2), census.decorations[spec.Decoration.Flat]);
    try std.testing.expectEqual(@as(u32, 1), census.decorations[spec.Decoration.Binding]);
    try std.testing.expectEqual(@as(u32, 1), census.opcodes[SpirvOp.ImageSampleExplicitLod]);
    inline for (.{ SpirvOp.DPdxFine, SpirvOp.DPdyFine, SpirvOp.FwidthFine }) |opcode| {
        try std.testing.expectEqual(@as(u32, 1), census.opcodes[opcode]);
    }
    try std.testing.expect(census.declares(spec.Capability.DerivativeControl));
}

test "spirv stage modules share one texture variable per group and binding" {
    const words = try emitStageCase(stages.cases[0]);
    defer std.testing.allocator.free(words);
    const census = try Census.of(words);
    try std.testing.expectEqual(@as(u32, 1), census.decorations[spec.Decoration.DescriptorSet]);
    try std.testing.expectEqual(@as(u32, 1), census.opcodes[SpirvOp.ImageSampleImplicitLod]);
    try std.testing.expectEqual(@as(u32, 8), census.decorations[spec.Decoration.Location]);
    try std.testing.expectEqual(@as(u32, 0), census.decorations[spec.Decoration.Flat]);
    try std.testing.expect(!census.declares(spec.Capability.DerivativeControl));
}

/// The storage class of every OpVariable in `words`, counted.
fn variableClasses(words: []const u32) ![16]u32 {
    var classes: [16]u32 = @splat(0);
    var index: usize = 5;
    while (index < words.len) {
        const count = words[index] >> 16;
        try std.testing.expect(count > 0);
        if (@as(u16, @truncate(words[index])) == SpirvOp.Variable) classes[words[index + 3]] += 1;
        index += count;
    }
    return classes;
}

test "spirv block reads share one push-constant and one uniform block per module" {
    const words = try emitStageCase(stages.cases[2]);
    defer std.testing.allocator.free(words);
    const census = try Census.of(words);
    const classes = try variableClasses(words);
    try std.testing.expectEqual(@as(u32, 1), classes[spec.StorageClass.PushConstant]);
    try std.testing.expectEqual(@as(u32, 1), classes[spec.StorageClass.Uniform]);
    try std.testing.expectEqual(@as(u32, 2), census.decorations[spec.Decoration.Block]);
    try std.testing.expectEqual(@as(u32, 2), census.decorations[spec.Decoration.ArrayStride]);
    try std.testing.expectEqual(@as(u32, 1), census.decorations[spec.Decoration.DescriptorSet]);
    try std.testing.expectEqual(@as(u32, 1), census.decorations[spec.Decoration.Binding]);
    try std.testing.expectEqual(@as(u32, 12), census.opcodes[SpirvOp.AccessChain]);
    try std.testing.expectEqual(@as(u32, 12), census.opcodes[SpirvOp.Bitcast]);
}

fn emitStageSource(source: []const u8) ![]u32 {
    const allocator = std.testing.allocator;
    var ctx = try choir.ir.Context.init(allocator, choir.ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try registration.prepareCompilationDialects(&ctx);
    const module = try fixture.lower(&ctx, source, .spirv);
    defer module.erase();
    return stages.emitSpirv(allocator, module);
}

/// `case`'s source with its one `needle` replaced. The caller owns it.
fn variant(case: stages.Case, needle: []const u8, replacement: []const u8) ![]u8 {
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, case.source, needle));
    return std.mem.replaceOwned(u8, std.testing.allocator, case.source, needle, replacement);
}

test "spirv stage calls emit each reachable helper once and refuse recursion" {
    const calls = stages.calls_case;
    const words = try emitStageSource(calls.source);
    defer std.testing.allocator.free(words);
    const census = try Census.of(words);
    try std.testing.expectEqual(@as(u32, 6), census.opcodes[SpirvOp.Function]);
    try std.testing.expectEqual(@as(u32, 6), census.opcodes[SpirvOp.FunctionCall]);
    const recursive = try variant(calls, "%9 = func.call(%8) {callee = @invert}", "%9 = func.call(%8) {callee = @nested_invert}");
    defer std.testing.allocator.free(recursive);
    try std.testing.expectError(error.UnsupportedOperation, emitStageSource(recursive));
}

test "gpu dialect refuses a derivative inside a non-stage helper" {
    const source = try variant(stages.calls_case, "%9 = func.call(%8) {callee = @invert}", "%9 = gpu.dpdx(%8)");
    defer std.testing.allocator.free(source);
    var ctx = try choir.ir.Context.init(std.testing.allocator, choir.ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try registration.prepareCompilationDialects(&ctx);
    const module = try choir.ir.parse.operation(&ctx, source);
    defer module.erase();
    try std.testing.expectError(error.DerivativeOutsideFragmentStage, choir.ir.verifyOperation(module, .{}));
}

test "spirv stage emission rejects ops outside their stage and split interface slots" {
    const indexed = stages.cases[1];
    const textured = stages.cases[0];
    const implicit_in_vertex = try variant(
        indexed,
        "gpu.sample_lod(%4, %2, %3, %5)",
        "gpu.sample(%4, %2, %3)",
    );
    defer std.testing.allocator.free(implicit_in_vertex);
    try std.testing.expectError(error.UnsupportedOperation, emitStageSource(implicit_in_vertex));
    const kernel = try variant(
        textured,
        "stage = #attr<gpu.stage>(\"vertex\")",
        "kernel = #attr<func.kernel>",
    );
    defer std.testing.allocator.free(kernel);
    try std.testing.expectError(error.UnsupportedOperation, emitStageSource(kernel));
    const split_slot = try variant(
        textured,
        "%12, %13, %14, %15 = gpu.stage_input() {location = 1:i64}",
        "%12, %13, %14, %15 = gpu.stage_input() {location = 0:i64}",
    );
    defer std.testing.allocator.free(split_slot);
    try std.testing.expectError(error.UnsupportedType, emitStageSource(split_slot));
}

test "spirv block reads refuse members std140 cannot place" {
    const pushed = stages.cases[2];
    const cases = .{
        .{ "{offset = 8:i64} : !arith.f32", "{offset = 10:i64} : !arith.f32" },
        .{
            "%7, %8 = gpu.push_constant() {offset = 0:i64}",
            "%7, %8 = gpu.push_constant() {offset = 4:i64}",
        },
        .{
            "{binding = 1:i64, group = 0:i64, offset = 16:i64}",
            "{binding = 1:i64, group = 0:i64, offset = 20:i64}",
        },
        .{
            "%7, %8 = gpu.push_constant() {offset = 0:i64}",
            "%7, %8 = gpu.push_constant() {offset = 128:i64}",
        },
    };
    inline for (cases) |case| {
        const source = try variant(pushed, case[0], case[1]);
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.UnsupportedOperation, emitStageSource(source));
    }
}

test "spirv dialect modules write vertex and fragment entry points" {
    const allocator = std.testing.allocator;
    var ctx = try choir.ir.Context.init(allocator, choir.ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const module = try stages.buildDialectModule(&ctx);
    defer module.erase();
    const words = try stages.emitSpirv(allocator, module);
    defer allocator.free(words);
    const census = try Census.of(words);
    try std.testing.expectEqual(@as(u32, 2), census.entries);
    try std.testing.expectEqual(spec.ExecutionModel.Vertex, census.models[0]);
    try std.testing.expectEqual(spec.ExecutionModel.Fragment, census.models[1]);
    try std.testing.expectEqual(@as(u32, 1), census.modes[spec.ExecutionMode.OriginUpperLeft]);
    try std.testing.expectEqual(@as(u32, 0), census.modes[spec.ExecutionMode.LocalSize]);
    try std.testing.expectEqual(@as(u32, 1), census.opcodes[SpirvOp.TypeFunction]);
}

test "spirv emitter truncates a signed remainder through SDiv and an unsigned one with UMod" {
    const emission = try emitFixture(fixture.remainder, "test_remainder", .{});
    defer std.testing.allocator.free(emission.words);
    const census = try Census.of(emission.words);
    try std.testing.expectEqual(@as(u32, 1), census.opcodes[SpirvOp.SDiv]);
    try std.testing.expectEqual(@as(u32, 1), census.opcodes[SpirvOp.IMul]);
    try std.testing.expectEqual(@as(u32, 1), census.opcodes[SpirvOp.ISub]);
    try std.testing.expectEqual(@as(u32, 2), census.opcodes[SpirvOp.UMod]);
    try std.testing.expectEqual(@as(u32, 0), census.opcodes[SpirvOp.SRem]);
    try std.testing.expectEqual(@as(u32, 0), census.opcodes[SpirvOp.SMod]);
}

fn emitKernel(kernel: stages.Kernel) ![]u32 {
    const allocator = std.testing.allocator;
    var ctx = try choir.ir.Context.init(allocator, choir.ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try registration.prepareCompilationDialects(&ctx);
    const module = try fixture.lower(&ctx, kernel.source, .spirv);
    defer module.erase();
    return stages.emitSpirv(allocator, module);
}

/// The storage class of the variable `id` names, or null when no OpVariable
/// defines it.
fn storageClassOf(words: []const u32, id: u32) !?u32 {
    var index: usize = 5;
    while (index < words.len) {
        const count = words[index] >> 16;
        try std.testing.expect(count > 0 and index + count <= words.len);
        if (@as(u16, @truncate(words[index])) == SpirvOp.Variable and words[index + 2] == id) {
            return words[index + 3];
        }
        index += count;
    }
    return null;
}

/// Expects every entry point's interface to name Input and Output variables
/// alone, and returns how many ids the interfaces list in all.
fn expectInputOutputInterfaces(words: []const u32) !u32 {
    var listed: u32 = 0;
    var index: usize = 5;
    while (index < words.len) {
        const count = words[index] >> 16;
        const end = index + count;
        try std.testing.expect(count > 0 and end <= words.len);
        if (@as(u16, @truncate(words[index])) == SpirvOp.EntryPoint) {
            // The execution model and function id precede the name, whose last
            // word holds its terminating zero byte, so its top byte is zero.
            var operand = index + 3;
            while (words[operand] >> 24 != 0) {
                operand += 1;
                try std.testing.expect(operand < end);
            }
            for (words[operand + 1 .. end]) |id| {
                const class = (try storageClassOf(words, id)) orelse
                    return error.TestUnexpectedResult;
                const Class = spec.StorageClass;
                try std.testing.expect(class == Class.Input or class == Class.Output);
                listed += 1;
            }
        }
        index = end;
    }
    return listed;
}

fn declaresExtension(words: []const u32, name: []const u8) !bool {
    var index: usize = 5;
    while (index < words.len) {
        const count = words[index] >> 16;
        try std.testing.expect(count > 0 and index + count <= words.len);
        if (@as(u16, @truncate(words[index])) == SpirvOp.Extension) {
            const bytes = std.mem.sliceAsBytes(words[index + 1 .. index + count]);
            const length = std.mem.indexOfScalar(u8, bytes, 0) orelse
                return error.TestUnexpectedResult;
            if (std.mem.eql(u8, bytes[0..length], name)) return true;
        }
        index += count;
    }
    return false;
}

test "spirv kernels list only Input and Output variables in their entry points" {
    for (stages.kernels) |kernel| {
        const words = try emitKernel(kernel);
        defer std.testing.allocator.free(words);
        const listed = try expectInputOutputInterfaces(words);
        const classes = try variableClasses(words);
        try std.testing.expect(classes[spec.StorageClass.StorageBuffer] > 0);
        const extension = "SPV_KHR_storage_buffer_storage_class";
        try std.testing.expect(try declaresExtension(words, extension));
        if (std.mem.eql(u8, kernel.name, "scalars")) {
            try std.testing.expectEqual(@as(u32, 1), classes[spec.StorageClass.PushConstant]);
            try std.testing.expectEqual(@as(u32, 1), listed);
        }
    }
}

test "spirv subgroup opcodes carry the numbers SPIR-V assigns them" {
    // Each literal is the opcode the SPIR-V assembler writes for the
    // instruction's name, so a constant that drifts from it fails here.
    const expected = [_]struct { u16, u16 }{
        .{ SpirvOp.GroupNonUniformAll, 334 },
        .{ SpirvOp.GroupNonUniformAny, 335 },
        .{ SpirvOp.GroupNonUniformBallot, 339 },
        .{ SpirvOp.GroupNonUniformShuffle, 345 },
        .{ SpirvOp.GroupNonUniformShuffleXor, 346 },
        .{ SpirvOp.GroupNonUniformShuffleUp, 347 },
        .{ SpirvOp.GroupNonUniformShuffleDown, 348 },
        .{ SpirvOp.GroupNonUniformIAdd, 349 },
        .{ SpirvOp.GroupNonUniformFAdd, 350 },
        .{ SpirvOp.GroupNonUniformSMin, 353 },
        .{ SpirvOp.GroupNonUniformUMin, 354 },
        .{ SpirvOp.GroupNonUniformFMin, 355 },
        .{ SpirvOp.GroupNonUniformSMax, 356 },
        .{ SpirvOp.GroupNonUniformUMax, 357 },
        .{ SpirvOp.GroupNonUniformFMax, 358 },
        .{ SpirvOp.GroupNonUniformBitwiseAnd, 359 },
        .{ SpirvOp.GroupNonUniformBitwiseOr, 360 },
        .{ SpirvOp.GroupNonUniformBitwiseXor, 361 },
        .{ SpirvOp.GroupNonUniformLogicalAnd, 362 },
        .{ SpirvOp.GroupNonUniformLogicalOr, 363 },
        .{ SpirvOp.GroupNonUniformLogicalXor, 364 },
    };
    for (expected) |pair| try std.testing.expectEqual(pair[1], pair[0]);
}
