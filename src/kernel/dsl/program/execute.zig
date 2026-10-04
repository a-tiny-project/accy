const std = @import("std");
const kernel = @import("../../root.zig");
const kernel_compile = @import("../../compile/root.zig");
const executable = @import("../../../executable/root.zig");
const body = @import("../root.zig").body;
const parameter = @import("../../program/root.zig").parameter;

pub fn buildSource(
    comptime definition: anytype,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
) !kernel.Graph {
    return interpretSource(definition, allocator, limits, kernel.interpret.graph());
}

pub fn interpretSource(
    comptime definition: anytype,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
    initial: anytype,
) !result(@TypeOf(initial)) {
    var builder = try kernel.Builder.init(
        allocator,
        limits,
        definition.name,
        parameter.schema(definition.parameters),
    );
    errdefer builder.deinit();

    const initial_spec = kernel.interpret.asSpec(initial);
    var state = initial_spec.attach(&builder);
    try body.call(definition, &state);
    try state.return_();
    return state.finish();
}

pub fn buildInstanceSource(
    comptime definition: anytype,
    instance: anytype,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
) !kernel.Graph {
    return interpretInstanceSource(
        definition,
        instance,
        allocator,
        limits,
        kernel.interpret.graph(),
    );
}

pub fn buildNamedInstanceSource(
    comptime definition: anytype,
    name: []const u8,
    instance: anytype,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
) !kernel.Graph {
    return interpretNamedInstanceSource(
        definition,
        name,
        instance,
        allocator,
        limits,
        kernel.interpret.graph(),
    );
}

pub fn interpretInstanceSource(
    comptime definition: anytype,
    instance: anytype,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
    initial: anytype,
) !result(@TypeOf(initial)) {
    return interpretNamedInstanceSource(
        definition,
        definition.name,
        instance,
        allocator,
        limits,
        initial,
    );
}

pub fn interpretNamedInstanceSource(
    comptime definition: anytype,
    name: []const u8,
    instance: anytype,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
    initial: anytype,
) !result(@TypeOf(initial)) {
    var builder = try kernel.Builder.init(
        allocator,
        limits,
        name,
        parameter.schema(definition.parameters),
    );
    errdefer builder.deinit();

    const initial_spec = kernel.interpret.asSpec(initial);
    var state = initial_spec.attach(&builder);
    try body.callInstance(definition, instance, &state);
    try state.return_();
    return state.finish();
}

pub fn buildDerived(
    comptime SourceProgram: type,
    comptime transform_spec: anytype,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
) !kernel.Graph {
    return SourceProgram.interpret(allocator, limits, transform_spec);
}

pub fn interpretDerived(
    comptime SourceProgram: type,
    comptime transform_spec: anytype,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
    initial: anytype,
) !stackedResult(@TypeOf(transform_spec), @TypeOf(initial)) {
    return SourceProgram.interpret(allocator, limits, kernel.interpret.stack(
        .{ transform_spec, kernel.interpret.asSpec(initial) },
    ));
}

pub fn buildAnalysisTransform(
    comptime ProgramType: type,
    comptime analysis_impl: anytype,
    comptime make_transform: anytype,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
) !kernel.Graph {
    var analysis = try ProgramType.interpret(allocator, limits, analysis_impl);
    defer kernel.interpret.deinitIfPresent(&analysis);
    return ProgramType.interpret(allocator, limits, make_transform(&analysis));
}

pub fn interpretAnalysisTransform(
    comptime ProgramType: type,
    comptime analysis_impl: anytype,
    comptime make_transform: anytype,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
    initial: anytype,
) !stackedResult(TransformSpec(analysis_impl, make_transform), @TypeOf(initial)) {
    var analysis = try ProgramType.interpret(allocator, limits, analysis_impl);
    defer kernel.interpret.deinitIfPresent(&analysis);
    return ProgramType.interpret(allocator, limits, kernel.interpret.stack(
        .{ kernel.interpret.asSpec(make_transform(&analysis)), kernel.interpret.asSpec(initial) },
    ));
}

pub fn launch(
    comptime ProgramType: type,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
) !kernel.Launch {
    var graph = try ProgramType.build(allocator, limits);
    defer graph.deinit();
    return graph.launch();
}

pub fn scheduleSnapshot(
    comptime ProgramType: type,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
) !kernel.ScheduleSnapshot {
    var graph = try ProgramType.build(allocator, limits);
    defer graph.deinit();
    return graph.scheduleSnapshot(allocator);
}

pub fn createPlan(
    comptime ProgramType: type,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
    options: kernel.PlanOptions,
) !kernel.Plan {
    var graph = try ProgramType.build(allocator, limits);
    defer graph.deinit();
    return graph.createPlan(allocator, options);
}

pub fn createCheckedPlan(
    comptime ProgramType: type,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
    options: kernel.PlanOptions,
) !kernel.Plan {
    var graph = try ProgramType.build(allocator, limits);
    defer graph.deinit();
    return graph.createCheckedPlan(allocator, options);
}

pub fn compileFragment(
    comptime ProgramType: type,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
    handle: kernel.BackendHandle,
    options: executable.FragmentCompilerOptions,
) !*executable.CompiledFragment {
    var graph = try ProgramType.build(allocator, limits);
    defer graph.deinit();
    return kernel_compile.compileFragment(allocator, handle, &graph, options);
}

pub fn createKernelArtifact(
    comptime ProgramType: type,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
    handle: kernel.BackendHandle,
    options: executable.KernelCompilerOptions,
) !kernel.KernelArtifact {
    var graph = try ProgramType.build(allocator, limits);
    defer graph.deinit();
    return kernel_compile.createArtifact(allocator, handle, &graph, options);
}

pub fn createKernelCallArtifact(
    comptime ProgramType: type,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
    handle: kernel.BackendHandle,
    options: kernel.KernelCallArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    var graph = try ProgramType.build(allocator, limits);
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, options);
}

pub fn runCpu(
    comptime ProgramType: type,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
    args: []const kernel.Argument,
) !void {
    var graph = try ProgramType.build(allocator, limits);
    defer graph.deinit();
    try graph.runCpu(allocator, args);
}

pub fn runCpuWithDiagnostic(
    comptime ProgramType: type,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
    args: []const kernel.Argument,
    diagnostic: *kernel.ExecutionDiagnostic,
) !void {
    var graph = try ProgramType.build(allocator, limits);
    defer graph.deinit();
    try graph.runCpuWithDiagnostic(allocator, args, diagnostic);
}

pub fn verify(
    comptime ProgramType: type,
    allocator: std.mem.Allocator,
    limits: kernel.Limits,
) !void {
    var graph = try ProgramType.build(allocator, limits);
    defer graph.deinit();
    try graph.verify();
}

pub fn AnalysisResult(comptime analysis_impl: anytype) type {
    return kernel.interpret.Result(kernel.interpret.InterpretSpec(@TypeOf(analysis_impl)));
}

pub fn TransformSpec(comptime analysis_impl: anytype, comptime make_transform: anytype) type {
    return kernel.interpret.InterpretSpec(
        @TypeOf(make_transform(@as(*const AnalysisResult(analysis_impl), undefined))),
    );
}

pub fn result(comptime Initial: type) type {
    return kernel.interpret.Result(kernel.interpret.InterpretSpec(Initial));
}

pub fn stackedResult(comptime Transform: type, comptime Initial: type) type {
    return kernel.interpret.Result(@TypeOf(kernel.interpret.stack(
        .{ @as(Transform, undefined), @as(kernel.interpret.InterpretSpec(Initial), undefined) },
    )));
}
