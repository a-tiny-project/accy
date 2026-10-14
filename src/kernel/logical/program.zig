const std = @import("std");
const executable = @import("../../executable/root.zig");
const kernel = @import("../root.zig");
const kernel_compile = @import("../compile/root.zig");
const logical_builder = @import("../model/logical/root.zig");
const parameter = @import("../program/root.zig").parameter;
const schedule_mod = logical_builder.schedule;

pub fn Program(comptime definition: anytype) type {
    return struct {
        const Default: type = Scheduled(definition, schedule_mod.default());

        pub const name = definition.name;
        pub const parameters = definition.parameters;
        pub const Layout: type = Default.Layout;
        pub const Limits: type = Default.Limits;

        pub fn withSchedule(comptime schedule: anytype) type {
            return Scheduled(definition, schedule);
        }

        pub const arg = Default.arg;
        pub const schema = Default.schema;
        pub const build = Default.build;
        pub const interpret = Default.interpret;
        pub const analyze = Default.analyze;
        pub const transform = Default.transform;
        pub const launch = Default.launch;
        pub const scheduleSnapshot = Default.scheduleSnapshot;
        pub const createPlan = Default.createPlan;
        pub const createCheckedPlan = Default.createCheckedPlan;
        pub const compileFragment = Default.compileFragment;
        pub const createKernelArtifact = Default.createKernelArtifact;
        pub const createKernelCallArtifact = Default.createKernelCallArtifact;
        pub const runCpu = Default.runCpu;
        pub const runCpuWithDiagnostic = Default.runCpuWithDiagnostic;
        pub const verify = Default.verify;
    };
}

fn Scheduled(comptime definition: anytype, comptime schedule: anytype) type {
    return struct {
        const Self = @This();
        const ProgramSource: type = kernel.Program(ScheduledDefinition(definition, schedule));

        pub const name = definition.name;
        pub const parameters = definition.parameters;
        pub const Layout: type = ProgramSource.Layout;
        pub const Limits: type = ProgramSource.Limits;
        pub const schedule_policy = schedule;

        pub fn withSchedule(comptime next_schedule: anytype) type {
            return Scheduled(definition, next_schedule);
        }

        pub const arg = ProgramSource.arg;
        pub const schema = ProgramSource.schema;
        pub const build = ProgramSource.build;
        pub const interpret = ProgramSource.interpret;
        pub fn analyze(comptime analysis_impl: anytype) type {
            return Analysis(Self, analysis_impl);
        }

        pub fn transform(comptime impl: anytype) type {
            return Derived(Self, kernel.interpret.asSpec(impl));
        }

        pub const launch = ProgramSource.launch;
        pub const scheduleSnapshot = ProgramSource.scheduleSnapshot;
        pub const createPlan = ProgramSource.createPlan;
        pub const createCheckedPlan = ProgramSource.createCheckedPlan;
        pub const compileFragment = ProgramSource.compileFragment;
        pub const createKernelArtifact = ProgramSource.createKernelArtifact;
        pub const createKernelCallArtifact = ProgramSource.createKernelCallArtifact;
        pub const runCpu = ProgramSource.runCpu;
        pub const runCpuWithDiagnostic = ProgramSource.runCpuWithDiagnostic;
        pub const verify = ProgramSource.verify;
    };
}

fn Derived(comptime ProgramType: type, comptime transform_spec: anytype) type {
    return struct {
        const Self = @This();
        const Runtime: type = RuntimeSurface(Self);

        pub const name = ProgramType.name;
        pub const parameters = ProgramType.parameters;
        pub const Layout: type = ProgramType.Layout;
        pub const schedule_policy = ProgramType.schedule_policy;
        pub const spec = transform_spec;
        pub const Limits: type = kernel.Limits;

        pub fn withSchedule(comptime next_schedule: anytype) type {
            return Derived(ProgramType.withSchedule(next_schedule), transform_spec);
        }

        pub fn transform(comptime impl: anytype) type {
            return Derived(ProgramType, kernel.interpret.stack(
                .{ transform_spec, kernel.interpret.asSpec(impl) },
            ));
        }

        pub fn analyze(comptime analysis_impl: anytype) type {
            return Analysis(Self, analysis_impl);
        }

        pub fn arg(comptime name_value: anytype) usize {
            return Layout.index(name_value);
        }

        pub fn schema() []const kernel.Param {
            return ProgramType.schema();
        }

        pub fn build(allocator: std.mem.Allocator, limits: Limits) !kernel.Graph {
            return ProgramType.interpret(allocator, limits, transform_spec);
        }

        pub fn interpret(
            allocator: std.mem.Allocator,
            limits: Limits,
            initial: anytype,
        ) !InterpretResult(ProgramType, StackedSpec(@TypeOf(transform_spec), @TypeOf(initial))) {
            return ProgramType.interpret(allocator, limits, kernel.interpret.stack(
                .{ transform_spec, kernel.interpret.asSpec(initial) },
            ));
        }

        pub const launch = Runtime.launch;
        pub const scheduleSnapshot = Runtime.scheduleSnapshot;
        pub const createPlan = Runtime.createPlan;
        pub const createCheckedPlan = Runtime.createCheckedPlan;
        pub const compileFragment = Runtime.compileFragment;
        pub const createKernelArtifact = Runtime.createKernelArtifact;
        pub const createKernelCallArtifact = Runtime.createKernelCallArtifact;
        pub const runCpu = Runtime.runCpu;
        pub const runCpuWithDiagnostic = Runtime.runCpuWithDiagnostic;
        pub const verify = Runtime.verify;
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
        ) !InterpretResult(ProgramType, @TypeOf(analysis_impl)) {
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
        const Self = @This();
        const Runtime: type = RuntimeSurface(Self);
        const TransformSpec: type = AnalysisTransformSpec(
            ProgramType,
            analysis_impl,
            make_transform,
        );

        pub const name = ProgramType.name;
        pub const parameters = ProgramType.parameters;
        pub const Layout: type = ProgramType.Layout;
        pub const schedule_policy = ProgramType.schedule_policy;
        pub const Limits: type = kernel.Limits;

        pub fn withSchedule(comptime next_schedule: anytype) type {
            return AnalysisTransform(
                ProgramType.withSchedule(next_schedule),
                analysis_impl,
                make_transform,
            );
        }

        pub fn transform(comptime impl: anytype) type {
            return Derived(Self, kernel.interpret.asSpec(impl));
        }

        pub fn analyze(comptime next_analysis_impl: anytype) type {
            return Analysis(Self, next_analysis_impl);
        }

        pub fn arg(comptime name_value: anytype) usize {
            return Layout.index(name_value);
        }

        pub fn schema() []const kernel.Param {
            return ProgramType.schema();
        }

        pub fn build(allocator: std.mem.Allocator, limits: Limits) !kernel.Graph {
            var analysis = try ProgramType.interpret(allocator, limits, analysis_impl);
            defer kernel.interpret.deinitIfPresent(&analysis);
            return ProgramType.interpret(allocator, limits, make_transform(&analysis));
        }

        pub fn interpret(
            allocator: std.mem.Allocator,
            limits: Limits,
            initial: anytype,
        ) !InterpretResult(ProgramType, StackedSpec(TransformSpec, @TypeOf(initial))) {
            var analysis = try ProgramType.interpret(allocator, limits, analysis_impl);
            defer kernel.interpret.deinitIfPresent(&analysis);
            return ProgramType.interpret(allocator, limits, kernel.interpret.stack(.{
                kernel.interpret.asSpec(make_transform(&analysis)),
                kernel.interpret.asSpec(initial),
            }));
        }

        pub const launch = Runtime.launch;
        pub const scheduleSnapshot = Runtime.scheduleSnapshot;
        pub const createPlan = Runtime.createPlan;
        pub const createCheckedPlan = Runtime.createCheckedPlan;
        pub const compileFragment = Runtime.compileFragment;
        pub const createKernelArtifact = Runtime.createKernelArtifact;
        pub const createKernelCallArtifact = Runtime.createKernelCallArtifact;
        pub const runCpu = Runtime.runCpu;
        pub const runCpuWithDiagnostic = Runtime.runCpuWithDiagnostic;
        pub const verify = Runtime.verify;
    };
}

fn StackedSpec(comptime Transform: type, comptime Initial: type) type {
    return @TypeOf(kernel.interpret.stack(
        .{ @as(Transform, undefined), @as(kernel.interpret.InterpretSpec(Initial), undefined) },
    ));
}

fn InterpretResult(comptime ProgramType: type, comptime Initial: type) type {
    const Return = @TypeOf(ProgramType.interpret(
        @as(std.mem.Allocator, undefined),
        @as(kernel.Limits, undefined),
        @as(Initial, undefined),
    ));
    return @typeInfo(Return).error_union.payload;
}

fn AnalysisTransformSpec(
    comptime ProgramType: type,
    comptime analysis_impl: anytype,
    comptime make_transform: anytype,
) type {
    return kernel.interpret.InterpretSpec(@TypeOf(
        make_transform(@as(*const InterpretResult(ProgramType, @TypeOf(analysis_impl)), undefined)),
    ));
}

fn RuntimeSurface(comptime ProgramType: type) type {
    return struct {
        pub fn launch(allocator: std.mem.Allocator, limits: kernel.Limits) !kernel.Launch {
            var graph = try ProgramType.build(allocator, limits);
            defer graph.deinit();
            return graph.launch();
        }

        pub fn scheduleSnapshot(
            allocator: std.mem.Allocator,
            limits: kernel.Limits,
        ) !kernel.ScheduleSnapshot {
            var graph = try ProgramType.build(allocator, limits);
            defer graph.deinit();
            return graph.scheduleSnapshot(allocator);
        }

        pub fn createPlan(
            allocator: std.mem.Allocator,
            limits: kernel.Limits,
            options: kernel.PlanOptions,
        ) !kernel.Plan {
            var graph = try ProgramType.build(allocator, limits);
            defer graph.deinit();
            return graph.createPlan(allocator, options);
        }

        pub fn createCheckedPlan(
            allocator: std.mem.Allocator,
            limits: kernel.Limits,
            options: kernel.PlanOptions,
        ) !kernel.Plan {
            var graph = try ProgramType.build(allocator, limits);
            defer graph.deinit();
            return graph.createCheckedPlan(allocator, options);
        }

        pub fn compileFragment(
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
            allocator: std.mem.Allocator,
            limits: kernel.Limits,
            args: []const kernel.Argument,
        ) !void {
            var graph = try ProgramType.build(allocator, limits);
            defer graph.deinit();
            try graph.runCpu(allocator, args);
        }

        pub fn runCpuWithDiagnostic(
            allocator: std.mem.Allocator,
            limits: kernel.Limits,
            args: []const kernel.Argument,
            diagnostic: *kernel.ExecutionDiagnostic,
        ) !void {
            var graph = try ProgramType.build(allocator, limits);
            defer graph.deinit();
            try graph.runCpuWithDiagnostic(allocator, args, diagnostic);
        }

        pub fn verify(allocator: std.mem.Allocator, limits: kernel.Limits) !void {
            var graph = try ProgramType.build(allocator, limits);
            defer graph.deinit();
            try graph.verify();
        }
    };
}

fn ScheduledDefinition(comptime definition: anytype, comptime schedule: anytype) type {
    return struct {
        pub const name = definition.name;
        pub const parameters = definition.parameters;

        pub fn body(raw_builder: anytype, _: anytype) !void {
            var logical = logical_builder.wrap(raw_builder, schedule);
            try call(definition, &logical);
        }
    };
}

fn call(comptime definition: anytype, k: anytype) !void {
    if (comptime parameter.named(definition.parameters)) {
        try definition.body(
            k,
            parameter.Args(definition.parameters, PointerChild(@TypeOf(k))){ .builder = k },
        );
    } else {
        const count = comptime parameter.arity(definition.parameters);
        var args: [count]kernel.Value = undefined;
        inline for (0..count) |index_value| {
            args[index_value] = k.argument(index_value);
        }
        try definition.body(k, args[0..]);
    }
}

fn PointerChild(comptime Pointer: type) type {
    return switch (@typeInfo(Pointer)) {
        .pointer => |info| info.child,
        else => @compileError("logical kernel Program bodies receive builder pointers"),
    };
}
