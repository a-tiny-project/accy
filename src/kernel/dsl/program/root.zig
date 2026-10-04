const std = @import("std");
const kernel = @import("../../root.zig");
const kernel_compile = @import("../../compile/root.zig");
const executable = @import("../../../executable/root.zig");
const execute = @import("execute.zig");
const parameter = @import("../../program/root.zig").parameter;

pub fn Program(comptime definition: anytype) type {
    return Source(definition);
}

pub fn Family(comptime definition: anytype) type {
    return struct {
        pub const name = definition.name;
        pub const parameters = definition.parameters;
        pub const Layout: type = parameter.Standard(parameters);
        pub const Instance: type = definition.Instance;
        pub const Limits: type = kernel.Limits;

        pub fn arg(comptime name_value: anytype) usize {
            return Layout.index(name_value);
        }

        pub fn schema() []const kernel.Param {
            return parameter.schema(parameters);
        }

        pub fn build(
            allocator: std.mem.Allocator,
            limits: Limits,
            instance: Instance,
        ) !kernel.Graph {
            return execute.buildInstanceSource(definition, instance, allocator, limits);
        }

        pub fn buildNamed(
            allocator: std.mem.Allocator,
            limits: Limits,
            graph_name: []const u8,
            instance: Instance,
        ) !kernel.Graph {
            return execute.buildNamedInstanceSource(
                definition,
                graph_name,
                instance,
                allocator,
                limits,
            );
        }

        pub fn interpret(
            allocator: std.mem.Allocator,
            limits: Limits,
            instance: Instance,
            initial: anytype,
        ) !execute.result(@TypeOf(initial)) {
            return execute.interpretInstanceSource(
                definition,
                instance,
                allocator,
                limits,
                initial,
            );
        }

        pub fn launch(
            allocator: std.mem.Allocator,
            limits: Limits,
            instance: Instance,
        ) !kernel.Launch {
            var graph = try build(allocator, limits, instance);
            defer graph.deinit();
            return graph.launch();
        }

        pub fn scheduleSnapshot(
            allocator: std.mem.Allocator,
            limits: Limits,
            instance: Instance,
        ) !kernel.ScheduleSnapshot {
            var graph = try build(allocator, limits, instance);
            defer graph.deinit();
            return graph.scheduleSnapshot(allocator);
        }

        pub fn createPlan(
            allocator: std.mem.Allocator,
            limits: Limits,
            instance: Instance,
            options: kernel.PlanOptions,
        ) !kernel.Plan {
            var graph = try build(allocator, limits, instance);
            defer graph.deinit();
            return graph.createPlan(allocator, options);
        }

        pub fn createCheckedPlan(
            allocator: std.mem.Allocator,
            limits: Limits,
            instance: Instance,
            options: kernel.PlanOptions,
        ) !kernel.Plan {
            var graph = try build(allocator, limits, instance);
            defer graph.deinit();
            return graph.createCheckedPlan(allocator, options);
        }

        pub fn compileFragment(
            allocator: std.mem.Allocator,
            limits: Limits,
            instance: Instance,
            handle: kernel.BackendHandle,
            options: executable.FragmentCompilerOptions,
        ) !*executable.CompiledFragment {
            var graph = try build(allocator, limits, instance);
            defer graph.deinit();
            return kernel_compile.compileFragment(allocator, handle, &graph, options);
        }

        pub fn createKernelArtifact(
            allocator: std.mem.Allocator,
            limits: Limits,
            instance: Instance,
            handle: kernel.BackendHandle,
            options: executable.KernelCompilerOptions,
        ) !kernel.KernelArtifact {
            var graph = try build(allocator, limits, instance);
            defer graph.deinit();
            return kernel_compile.createArtifact(allocator, handle, &graph, options);
        }

        pub fn createKernelCallArtifact(
            allocator: std.mem.Allocator,
            limits: Limits,
            instance: Instance,
            handle: kernel.BackendHandle,
            options: kernel.KernelCallArtifactOptions,
        ) !kernel.OwnedKernelCallArtifact {
            var graph = try build(allocator, limits, instance);
            defer graph.deinit();
            return kernel.createKernelCallArtifact(allocator, handle, &graph, options);
        }

        pub fn runCpu(
            allocator: std.mem.Allocator,
            limits: Limits,
            instance: Instance,
            args: []const kernel.Argument,
        ) !void {
            var graph = try build(allocator, limits, instance);
            defer graph.deinit();
            try graph.runCpu(allocator, args);
        }

        pub fn runCpuWithDiagnostic(
            allocator: std.mem.Allocator,
            limits: Limits,
            instance: Instance,
            args: []const kernel.Argument,
            diagnostic: *kernel.ExecutionDiagnostic,
        ) !void {
            var graph = try build(allocator, limits, instance);
            defer graph.deinit();
            try graph.runCpuWithDiagnostic(allocator, args, diagnostic);
        }

        pub fn verify(allocator: std.mem.Allocator, limits: Limits, instance: Instance) !void {
            var graph = try build(allocator, limits, instance);
            defer graph.deinit();
            try graph.verify();
        }
    };
}

fn Source(comptime definition: anytype) type {
    return struct {
        pub const name = definition.name;
        pub const parameters = definition.parameters;
        pub const Layout: type = parameter.Standard(parameters);
        pub const Limits: type = kernel.Limits;
        const Methods: type = Surface(@This());

        pub fn arg(comptime name_value: anytype) usize {
            return Layout.index(name_value);
        }

        pub fn schema() []const kernel.Param {
            return parameter.schema(parameters);
        }

        pub fn build(allocator: std.mem.Allocator, limits: Limits) !kernel.Graph {
            return execute.buildSource(definition, allocator, limits);
        }

        pub fn interpret(
            allocator: std.mem.Allocator,
            limits: Limits,
            initial: anytype,
        ) !execute.result(@TypeOf(initial)) {
            return execute.interpretSource(definition, allocator, limits, initial);
        }

        pub const analyze = Methods.analyze;
        pub const transform = Methods.transform;
        pub const launch = Methods.launch;
        pub const scheduleSnapshot = Methods.scheduleSnapshot;
        pub const createPlan = Methods.createPlan;
        pub const createCheckedPlan = Methods.createCheckedPlan;
        pub const compileFragment = Methods.compileFragment;
        pub const createKernelArtifact = Methods.createKernelArtifact;
        pub const createKernelCallArtifact = Methods.createKernelCallArtifact;
        pub const runCpu = Methods.runCpu;
        pub const runCpuWithDiagnostic = Methods.runCpuWithDiagnostic;
        pub const verify = Methods.verify;
    };
}

fn Derived(comptime SourceProgram: type, comptime transform_spec: anytype) type {
    return struct {
        pub const name = SourceProgram.name;
        pub const parameters = SourceProgram.parameters;
        pub const Layout: type = SourceProgram.Layout;
        pub const Source: type = SourceProgram;
        pub const spec = transform_spec;
        pub const Limits: type = kernel.Limits;
        const Methods: type = Surface(@This());

        pub fn arg(comptime name_value: anytype) usize {
            return Layout.index(name_value);
        }

        pub fn schema() []const kernel.Param {
            return SourceProgram.schema();
        }

        pub fn build(allocator: std.mem.Allocator, limits: Limits) !kernel.Graph {
            return execute.buildDerived(SourceProgram, transform_spec, allocator, limits);
        }

        pub fn interpret(
            allocator: std.mem.Allocator,
            limits: Limits,
            initial: anytype,
        ) !execute.stackedResult(@TypeOf(transform_spec), @TypeOf(initial)) {
            return execute.interpretDerived(
                SourceProgram,
                transform_spec,
                allocator,
                limits,
                initial,
            );
        }

        pub const analyze = Methods.analyze;
        pub const transform = Methods.transform;
        pub const launch = Methods.launch;
        pub const scheduleSnapshot = Methods.scheduleSnapshot;
        pub const createPlan = Methods.createPlan;
        pub const createCheckedPlan = Methods.createCheckedPlan;
        pub const compileFragment = Methods.compileFragment;
        pub const createKernelArtifact = Methods.createKernelArtifact;
        pub const createKernelCallArtifact = Methods.createKernelCallArtifact;
        pub const runCpu = Methods.runCpu;
        pub const runCpuWithDiagnostic = Methods.runCpuWithDiagnostic;
        pub const verify = Methods.verify;
    };
}

fn Analysis(comptime ProgramType: type, comptime analysis_impl: anytype) type {
    return struct {
        pub const Program: type = ProgramType;
        pub const name = ProgramType.name;
        pub const parameters = ProgramType.parameters;
        pub const Layout: type = ProgramType.Layout;
        pub const Limits: type = kernel.Limits;

        pub fn arg(comptime name_value: anytype) usize {
            return Layout.index(name_value);
        }

        pub fn schema() []const kernel.Param {
            return ProgramType.schema();
        }

        pub fn interpret(
            allocator: std.mem.Allocator,
            limits: Limits,
        ) !execute.result(@TypeOf(analysis_impl)) {
            return ProgramType.interpret(allocator, limits, analysis_impl);
        }

        pub fn transform(comptime make_transform: anytype) type {
            return AnalysisTransform(ProgramType, analysis_impl, make_transform);
        }
    };
}

fn AnalysisTransform(
    comptime ProgramType: type,
    comptime analysis_impl: anytype,
    comptime make_transform: anytype,
) type {
    return struct {
        pub const name = ProgramType.name;
        pub const parameters = ProgramType.parameters;
        pub const Layout: type = ProgramType.Layout;
        pub const Source: type = ProgramType;
        pub const Limits: type = kernel.Limits;
        const Methods: type = Surface(@This());
        const TransformSpec: type = execute.TransformSpec(analysis_impl, make_transform);

        pub fn arg(comptime name_value: anytype) usize {
            return Layout.index(name_value);
        }

        pub fn schema() []const kernel.Param {
            return ProgramType.schema();
        }

        pub fn build(allocator: std.mem.Allocator, limits: Limits) !kernel.Graph {
            return execute.buildAnalysisTransform(
                ProgramType,
                analysis_impl,
                make_transform,
                allocator,
                limits,
            );
        }

        pub fn interpret(
            allocator: std.mem.Allocator,
            limits: Limits,
            initial: anytype,
        ) !execute.stackedResult(TransformSpec, @TypeOf(initial)) {
            return execute.interpretAnalysisTransform(
                ProgramType,
                analysis_impl,
                make_transform,
                allocator,
                limits,
                initial,
            );
        }

        pub const analyze = Methods.analyze;
        pub const transform = Methods.transform;
        pub const launch = Methods.launch;
        pub const scheduleSnapshot = Methods.scheduleSnapshot;
        pub const createPlan = Methods.createPlan;
        pub const createCheckedPlan = Methods.createCheckedPlan;
        pub const compileFragment = Methods.compileFragment;
        pub const createKernelArtifact = Methods.createKernelArtifact;
        pub const createKernelCallArtifact = Methods.createKernelCallArtifact;
        pub const runCpu = Methods.runCpu;
        pub const runCpuWithDiagnostic = Methods.runCpuWithDiagnostic;
        pub const verify = Methods.verify;
    };
}

fn Surface(comptime ProgramType: type) type {
    return struct {
        pub fn transform(comptime impl: anytype) type {
            const next_spec = kernel.interpret.asSpec(impl);
            if (comptime @hasDecl(ProgramType, "spec")) {
                return Derived(
                    ProgramType.Source,
                    kernel.interpret.stack(.{ ProgramType.spec, next_spec }),
                );
            }
            return Derived(ProgramType, next_spec);
        }

        pub fn analyze(comptime analysis_impl: anytype) type {
            return Analysis(ProgramType, analysis_impl);
        }

        pub fn launch(allocator: std.mem.Allocator, limits: kernel.Limits) !kernel.Launch {
            return execute.launch(ProgramType, allocator, limits);
        }

        pub fn scheduleSnapshot(
            allocator: std.mem.Allocator,
            limits: kernel.Limits,
        ) !kernel.ScheduleSnapshot {
            return execute.scheduleSnapshot(ProgramType, allocator, limits);
        }

        pub fn createPlan(
            allocator: std.mem.Allocator,
            limits: kernel.Limits,
            options: kernel.PlanOptions,
        ) !kernel.Plan {
            return execute.createPlan(ProgramType, allocator, limits, options);
        }

        pub fn createCheckedPlan(
            allocator: std.mem.Allocator,
            limits: kernel.Limits,
            options: kernel.PlanOptions,
        ) !kernel.Plan {
            return execute.createCheckedPlan(ProgramType, allocator, limits, options);
        }

        pub fn compileFragment(
            allocator: std.mem.Allocator,
            limits: kernel.Limits,
            handle: kernel.BackendHandle,
            options: executable.FragmentCompilerOptions,
        ) !*executable.CompiledFragment {
            return execute.compileFragment(ProgramType, allocator, limits, handle, options);
        }

        pub fn createKernelArtifact(
            allocator: std.mem.Allocator,
            limits: kernel.Limits,
            handle: kernel.BackendHandle,
            options: executable.KernelCompilerOptions,
        ) !kernel.KernelArtifact {
            return execute.createKernelArtifact(ProgramType, allocator, limits, handle, options);
        }

        pub fn createKernelCallArtifact(
            allocator: std.mem.Allocator,
            limits: kernel.Limits,
            handle: kernel.BackendHandle,
            options: kernel.KernelCallArtifactOptions,
        ) !kernel.OwnedKernelCallArtifact {
            return execute.createKernelCallArtifact(
                ProgramType,
                allocator,
                limits,
                handle,
                options,
            );
        }

        pub fn runCpu(
            allocator: std.mem.Allocator,
            limits: kernel.Limits,
            args: []const kernel.Argument,
        ) !void {
            try execute.runCpu(ProgramType, allocator, limits, args);
        }

        pub fn runCpuWithDiagnostic(
            allocator: std.mem.Allocator,
            limits: kernel.Limits,
            args: []const kernel.Argument,
            diagnostic: *kernel.ExecutionDiagnostic,
        ) !void {
            try execute.runCpuWithDiagnostic(ProgramType, allocator, limits, args, diagnostic);
        }

        pub fn verify(allocator: std.mem.Allocator, limits: kernel.Limits) !void {
            try execute.verify(ProgramType, allocator, limits);
        }
    };
}
