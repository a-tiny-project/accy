const std = @import("std");
const gpu = @import("gpu");
const choir = @import("choir");
const gpu_abi = @import("gpu_abi");
const accy_root = @import("../root.zig");

const gpu_codegen = choir.backends.gpu;
const cpu = gpu_codegen.cpu;
const spirv = gpu_codegen.spirv;
const nvptx = gpu_codegen.nvptx;
const metal = gpu_codegen.metal;
const webgpu = gpu_codegen.webgpu;
const lowering = gpu_codegen.lowering;

const ir = choir.ir;
const passes = choir.passes;

pub const native_cpu_artifacts_supported = @hasDecl(choir.backends.x86_64, "backend");

pub const CompileOptions = accy_root.choir.record.target.CompileOptions;

pub fn compileOptionsForArtifactFormat(format: gpu.ArtifactFormat, element_count: u64) CompileOptions {
    return .{ .cpu_vector_width = automaticCpuVectorWidth(format, element_count) };
}

fn automaticCpuVectorWidth(format: gpu.ArtifactFormat, element_count: u64) ?u32 {
    const width: u32 = 4;
    if (!gpu.artifactFormatIsNativeCpu(format)) return null;
    if (element_count < width) return null;
    return width;
}

/// One compiled kernel entry: the payload a backend loads, and the
/// push-constant layout its emitter produced (empty outside SPIR-V).
pub const Compilation = struct {
    payload: gpu.CompilePayload,
    push_constants: gpu_abi.PushConstants = .{},
};

/// Vulkan emission leaves float modes unset because this call precedes device selection.
pub fn compileKernelForArtifactFormat(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    entry_name: []const u8,
    module: *ir.Operation,
    options: CompileOptions,
) gpu.BackendError!Compilation {
    const compile_module = switch (format) {
        .cuda_ptx, .vulkan_spirv, .metal_msl, .webgpu_wgsl, .cpu_machine_code, .cpu_object, .webassembly_module => module.clone() catch |err| return compileModuleCloneError(err),
        else => return error.UnsupportedArtifactFormat,
    };
    defer compile_module.erase();

    const payload: gpu.CompilePayload = switch (format) {
        .cuda_ptx => payload: {
            try lowerKernelJobForArtifactFormat(allocator, compile_module, format);
            break :payload .{ .text = try nvptx.ptx.emitPtx(allocator, entry_name, compile_module) };
        },
        .vulkan_spirv => {
            try lowerKernelJobForArtifactFormat(allocator, compile_module, format);
            const emission = try spirv.emitter.emitPlanWords(allocator, compile_module, entry_name, .{}, .{});
            return .{
                .payload = .{ .words_u32 = emission.words },
                .push_constants = emission.push_constants,
            };
        },
        .metal_msl => .{ .text = try metal.msl.emitMsl(allocator, entry_name, compile_module) },
        .webgpu_wgsl => .{ .text = try webgpu.wgsl.emitWgsl(allocator, entry_name, compile_module) },
        .cpu_machine_code => try compileKernelJobToCpuMachineCode(allocator, entry_name, compile_module, options),
        .cpu_object => try compileKernelJobToCpuObject(allocator, entry_name, compile_module, options),
        .webassembly_module => try compileKernelJobToWebAssemblyModule(allocator, entry_name, compile_module),
        else => unreachable,
    };
    return .{ .payload = payload };
}

fn compileKernelJobToCpuMachineCode(
    allocator: std.mem.Allocator,
    entry_name: []const u8,
    module: *ir.Operation,
    options: CompileOptions,
) gpu.BackendError!gpu.CompilePayload {
    if (comptime !native_cpu_artifacts_supported) return error.UnsupportedOperation;

    const host_module = try cpu.lowerKernelToHostLoop(allocator, module, .{
        .entry_name = entry_name,
        .vector_width = options.cpu_vector_width,
    });
    defer host_module.erase();

    var x64_backend = choir.backends.x86_64.backend.Backend.init(
        allocator,
        host_module.getContext(),
        .standard,
    ) catch |err| return cpuCompileError(err);
    defer x64_backend.deinit();

    var machine_code = x64_backend.compileFunctionToMachineCodeWithRelocations(host_module, entry_name) catch |err| return cpuCompileError(err);
    defer machine_code.deinit(allocator);
    if (machine_code.relocations.len != 0) return error.UnsupportedOperation;
    if (machine_code.data_symbols.len != 0) return error.UnsupportedOperation;
    if (machine_code.data_relocations.len != 0) return error.UnsupportedOperation;
    return .{ .bytes = allocator.dupe(u8, machine_code.code) catch return error.OutOfMemory };
}

fn compileKernelJobToCpuObject(
    allocator: std.mem.Allocator,
    entry_name: []const u8,
    module: *ir.Operation,
    options: CompileOptions,
) gpu.BackendError!gpu.CompilePayload {
    if (comptime !native_cpu_artifacts_supported) return error.UnsupportedOperation;

    const host_module = try cpu.lowerKernelToHostLoop(allocator, module, .{
        .entry_name = entry_name,
        .vector_width = options.cpu_vector_width,
    });
    defer host_module.erase();

    var x64_backend = choir.backends.x86_64.backend.Backend.init(
        allocator,
        host_module.getContext(),
        .standard,
    ) catch |err| return cpuCompileError(err);
    defer x64_backend.deinit();

    var object_artifact = x64_backend.compileModuleToObjectFile(host_module, entry_name) catch |err| return cpuCompileError(err);
    defer object_artifact.deinit();

    if (object_artifact.payload.buffers.items.len != 1) return error.InvalidArtifact;
    if (object_artifact.payload.buffers.items[0].format != .object_file) return error.InvalidArtifact;
    return .{ .bytes = allocator.dupe(u8, object_artifact.payload.buffers.items[0].bytes) catch return error.OutOfMemory };
}

fn compileKernelJobToWebAssemblyModule(
    allocator: std.mem.Allocator,
    entry_name: []const u8,
    module: *ir.Operation,
) gpu.BackendError!gpu.CompilePayload {
    const host_module = try cpu.lowerKernelToHostLoop(allocator, module, .{ .entry_name = entry_name });
    defer host_module.erase();

    var wasm_backend = try choir.backends.wasm.Backend.init(allocator, host_module.getContext());
    defer wasm_backend.deinit();

    var wasm_artifact = wasm_backend.compileModuleToArtifact(host_module, .{ .entry = entry_name }) catch |err| return wasmCompileError(err);
    defer wasm_artifact.deinit();

    if (wasm_artifact.payload.buffers.items.len != 1) return error.InvalidArtifact;
    if (wasm_artifact.payload.buffers.items[0].format != .webassembly_module) return error.InvalidArtifact;
    return .{ .bytes = allocator.dupe(u8, wasm_artifact.payload.buffers.items[0].bytes) catch return error.OutOfMemory };
}

fn cpuCompileError(err: anyerror) gpu.BackendError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedArchitecture => error.UnsupportedOperation,
        else => error.CompilationFailed,
    };
}

fn wasmCompileError(err: anyerror) gpu.BackendError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedArchitecture => error.UnsupportedOperation,
        else => error.CompilationFailed,
    };
}

fn compileModuleCloneError(err: anyerror) gpu.BackendError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CompilationFailed,
    };
}

fn lowerKernelJobForArtifactFormat(
    allocator: std.mem.Allocator,
    module: *ir.Operation,
    format: gpu.ArtifactFormat,
) gpu.BackendError!void {
    switch (format) {
        .cuda_ptx => try lowerKernelJobToTarget(allocator, module, .nvptx),
        .vulkan_spirv => try lowerKernelJobToTarget(allocator, module, .spirv),
        else => {},
    }
}

fn lowerKernelJobToTarget(
    allocator: std.mem.Allocator,
    module: *ir.Operation,
    target_lowering: lowering.TargetLowering,
) gpu.BackendError!void {
    const ctx = module.getContext();
    if (!ctx.isFrozen()) {
        gpu_codegen.registerTargetDialects(ctx) catch |err| return targetRegistrationError(err);
    }

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    pm.enableVerifier();
    lowering.addTargetLoweringPipeline(&pm, target_lowering) catch |err| return targetRegistrationError(err);
    if (pm.run(module, ctx) == .failure) {
        emitPassFailure(module, &pm);
        return error.CompilationFailed;
    }
}

fn emitPassFailure(module: *ir.Operation, pm: *const passes.PassManager) void {
    const failure = pm.getLastFailureReproducer() orelse return;
    const metadata = [_]choir.diagnostics.Metadata{
        .{ .name = "pipeline", .value = failure.pipeline },
        .{ .name = "pass", .value = failure.pass_name orelse "dependency preparation" },
        .{ .name = "target", .value = failure.target_op_name orelse "builtin.module" },
        .{ .name = "ir", .value = failure.ir },
    };
    var diagnostic = module.getContext().emitDiagnostic(.{
        .severity = .err,
        .location = module.getLoc(),
        .operation = module,
        .message = "Accy target lowering failed",
        .error_name = failure.verifier_error_name,
        .metadata = &metadata,
    });
    defer diagnostic.deinit();
    _ = diagnostic.emit() catch {};
}

fn targetRegistrationError(err: anyerror) gpu.BackendError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CompilationFailed,
    };
}

fn deinitCompilePayload(allocator: std.mem.Allocator, payload: gpu.CompilePayload) void {
    switch (payload) {
        .bytes => |bytes| allocator.free(@constCast(bytes)),
        .words_u32 => |words| allocator.free(@constCast(words)),
        .text => |text| allocator.free(@constCast(text)),
        .none => {},
    }
}

test "target payload compilation rejects unsupported artifact formats" {
    try std.testing.expectError(
        error.UnsupportedArtifactFormat,
        compileKernelForArtifactFormat(
            std.testing.allocator,
            .external,
            "unsupported",
            undefined,
            .{},
        ),
    );
}

test "target payload compilation preserves source kernel module" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const kernel = accy_root.kernel;

    var builder_state = try kernel.Builder.init(allocator, kernel.Builder.Limits.testing, "target_payload_preserves_source_kernel_i32", &.{
        kernel.dynamicBuffer(.i32),
        kernel.dynamicBuffer(.i32),
    });
    errdefer builder_state.deinit();

    const src = builder_state.argument(0);
    const dst = builder_state.argument(1);
    const index = try builder_state.globalId(.x);
    const value = try builder_state.load(src, index);
    try builder_state.store(value, dst, index);
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    const before = try program.bodyFingerprint(allocator);
    const formats = [_]gpu.ArtifactFormat{
        .cuda_ptx,
        .vulkan_spirv,
        .metal_msl,
        .webgpu_wgsl,
        .webassembly_module,
        .cuda_ptx,
    };
    for (formats) |format| {
        const compiled = try compileKernelForArtifactFormat(
            allocator,
            format,
            "target_payload_preserves_source_kernel_i32",
            program.kernelModule(),
            .{},
        );
        defer deinitCompilePayload(allocator, compiled.payload);
        try testing.expect(program.kernelModule().getContext().isFrozen());
        try testing.expectEqual(before, try program.bodyFingerprint(allocator));
    }
}

test "target payload compilation emits webassembly module for host loop kernel" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const kernel = accy_root.kernel;

    var builder_state = try kernel.Builder.init(allocator, kernel.Builder.Limits.testing, "target_payload_wasm_copy_f32", &.{
        kernel.dynamicBuffer(.f32),
        kernel.dynamicBuffer(.f32),
    });
    errdefer builder_state.deinit();

    const axis = try builder_state.axis("i", 4);
    try builder_state.bind(axis, .thread_x);
    const src = builder_state.argument(0);
    const dst = builder_state.argument(1);
    const index = try builder_state.globalId(.x);
    const value = try builder_state.load(src, index);
    try builder_state.store(value, dst, index);
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    const before = try program.bodyFingerprint(allocator);
    const compiled = try compileKernelForArtifactFormat(
        allocator,
        .webassembly_module,
        "target_payload_wasm_copy_f32",
        program.kernelModule(),
        .{},
    );
    defer deinitCompilePayload(allocator, compiled.payload);
    try testing.expectEqual(before, try program.bodyFingerprint(allocator));

    const bytes = switch (compiled.payload) {
        .bytes => |payload| payload,
        else => return error.ExpectedWebAssemblyModuleBytes,
    };
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 }, bytes[0..8]);
}
