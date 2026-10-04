const std = @import("std");
const tensor = @import("../../root.zig");
const autodiff = tensor.autodiff;
const batch = tensor.batch;
const body = @import("../root.zig").body;
const execute = @import("execute.zig");
const gradient = tensor.gradient;
const interpret_mod = tensor.interpret;
const lower_mod = tensor.lower;
const output = @import("../root.zig").output;
const parameter = @import("../root.zig").parameter;
const program_mod = tensor.program;
const trace = tensor.trace;
const transform = tensor.transform;

const Derivation = enum {
    rewrite,
    jvp,
    jvp_with,
    grad,
    grad_with,
    vmap,
    vmap_with,
};

pub fn Program(comptime definition: anytype) type {
    return Source(definition);
}

fn Source(comptime definition: anytype) type {
    return struct {
        pub const name = definition.name;
        pub const parameters = definition.parameters;
        pub const Layout: type = parameter.Standard(parameters);
        pub const Outputs: type = output.Source(definition.body);
        const Methods: type = Surface(@This());

        pub fn build(allocator: std.mem.Allocator) !program_mod.Program {
            var builder = try trace.Builder.init(allocator, definition.name);
            errdefer builder.deinit();

            const args = try body.buildInputs(&builder, definition.parameters);
            const outputs = try body.call(definition, &builder, args);
            return try builder.finish(outputs);
        }

        pub const wrt = Methods.wrt;
        pub const inAxes = Methods.inAxes;
        pub const out = Methods.out;
        pub const analyze = Methods.analyze;
        pub const rewrite = Methods.rewrite;
        pub const jvp = Methods.jvp;
        pub const jvpWith = Methods.jvpWith;
        pub const grad = Methods.grad;
        pub const gradWith = Methods.gradWith;
        pub const vmap = Methods.vmap;
        pub const vmapWith = Methods.vmapWith;
        pub const interpret = Methods.interpret;
        pub const lower = Methods.lower;
        pub const prepare = Methods.prepare;
        pub const prepareWith = Methods.prepareWith;
        pub const prepareFragment = Methods.prepareFragment;
        pub const createArtifactJob = Methods.createArtifactJob;
        pub const compileFragment = Methods.compileFragment;
        pub const verify = Methods.verify;
    };
}

fn Derived(
    comptime SourceProgram: type,
    comptime derivation: Derivation,
    comptime options: anytype,
) type {
    return struct {
        pub const name = SourceProgram.name;
        pub const parameters = SourceProgram.parameters;
        pub const Layout: type = DerivedLayout(SourceProgram, derivation, options);
        pub const Outputs: type = DerivedOutputs(SourceProgram, derivation, options);
        const Methods: type = Surface(@This());

        pub fn build(allocator: std.mem.Allocator) !program_mod.Program {
            var source = try SourceProgram.build(allocator);
            defer source.deinit();
            if (comptime derivation == .rewrite) {
                return transform.apply(allocator, &source, options);
            }
            if (comptime derivation == .jvp) return autodiff.jvp(allocator, &source, options);
            if (comptime derivation == .jvp_with) {
                return autodiff.jvpWith(allocator, &source, options.jvp, options.hooks);
            }
            if (comptime derivation == .grad) return gradient.grad(allocator, &source, options);
            if (comptime derivation == .grad_with) {
                return gradient.gradWith(allocator, &source, options.grad, options.hooks);
            }
            if (comptime derivation == .vmap) return batch.vmap(allocator, &source, options);
            if (comptime derivation == .vmap_with) {
                return batch.vmapWith(allocator, &source, options.vmap, options.hooks);
            }
            unreachable;
        }

        pub const wrt = Methods.wrt;
        pub const inAxes = Methods.inAxes;
        pub const out = Methods.out;
        pub const analyze = Methods.analyze;
        pub const rewrite = Methods.rewrite;
        pub const jvp = Methods.jvp;
        pub const jvpWith = Methods.jvpWith;
        pub const grad = Methods.grad;
        pub const gradWith = Methods.gradWith;
        pub const vmap = Methods.vmap;
        pub const vmapWith = Methods.vmapWith;
        pub const lower = Methods.lower;
        pub const prepare = Methods.prepare;
        pub const prepareWith = Methods.prepareWith;
        pub const prepareFragment = Methods.prepareFragment;
        pub const createArtifactJob = Methods.createArtifactJob;
        pub const compileFragment = Methods.compileFragment;
        pub const verify = Methods.verify;

        pub fn interpret(
            allocator: std.mem.Allocator,
            initial: anytype,
        ) !interpret_mod.result(@TypeOf(initial)) {
            if (comptime derivation == .rewrite) {
                return execute.rewriteProgram(SourceProgram, options, allocator, initial);
            }
            if (comptime derivation == .jvp) {
                return execute.jvpProgram(SourceProgram, options, allocator, initial);
            }
            if (comptime derivation == .jvp_with) return execute.jvpWithProgram(
                SourceProgram,
                options.jvp,
                options.hooks,
                allocator,
                initial,
            );
            if (comptime derivation == .grad) {
                return execute.gradProgram(SourceProgram, options, allocator, initial);
            }
            if (comptime derivation == .grad_with) return execute.gradWithProgram(
                SourceProgram,
                options.grad,
                options.hooks,
                allocator,
                initial,
            );
            if (comptime derivation == .vmap) {
                return execute.vmapProgram(SourceProgram, options, allocator, initial);
            }
            if (comptime derivation == .vmap_with) return execute.vmapWithProgram(
                SourceProgram,
                options.vmap,
                options.hooks,
                allocator,
                initial,
            );
            return execute.program(@This(), allocator, initial);
        }
    };
}

fn Analysis(comptime ProgramType: type, comptime analysis_initial: anytype) type {
    return struct {
        pub const Program: type = ProgramType;
        pub const name = ProgramType.name;
        pub const parameters = ProgramType.parameters;
        pub const Layout: type = ProgramType.Layout;
        pub const Outputs: type = ProgramType.Outputs;

        pub fn wrt(comptime names: anytype) *const [parameter.nameCount(names)]usize {
            return ProgramType.Layout.indices(names);
        }

        pub fn inAxes(comptime axes: anytype) *const [ProgramType.Layout.count]batch.Axis {
            return ProgramType.Layout.axes(axes);
        }

        pub fn out(comptime spec: anytype) usize {
            return ProgramType.Outputs.index(spec);
        }

        pub fn interpret(
            allocator: std.mem.Allocator,
        ) !interpret_mod.result(@TypeOf(analysis_initial)) {
            return execute.program(ProgramType, allocator, analysis_initial);
        }

        pub fn rewrite(comptime make_transform: anytype) type {
            return AnalysisRewrite(ProgramType, analysis_initial, make_transform);
        }

        pub fn jvpWith(comptime options: autodiff.JvpOptions, comptime make_hooks: anytype) type {
            return AnalysisDerived(
                ProgramType,
                .jvp_with,
                .{ .jvp = options },
                analysis_initial,
                make_hooks,
            );
        }

        pub fn gradWith(comptime options: gradient.Options, comptime make_hooks: anytype) type {
            return AnalysisDerived(
                ProgramType,
                .grad_with,
                .{ .grad = options },
                analysis_initial,
                make_hooks,
            );
        }

        pub fn vmapWith(comptime options: batch.Options, comptime make_hooks: anytype) type {
            return AnalysisDerived(
                ProgramType,
                .vmap_with,
                .{ .vmap = options },
                analysis_initial,
                make_hooks,
            );
        }
    };
}

fn AnalysisRewrite(
    comptime ProgramType: type,
    comptime analysis_initial: anytype,
    comptime make_transform: anytype,
) type {
    return struct {
        pub const name = ProgramType.name;
        pub const parameters = ProgramType.parameters;
        pub const Layout: type = ProgramType.Layout;
        pub const Outputs: type = ProgramType.Outputs;
        const Methods: type = Surface(@This());

        pub fn build(allocator: std.mem.Allocator) !program_mod.Program {
            var source = try ProgramType.build(allocator);
            defer source.deinit();

            var analysis = try interpret_mod.run(allocator, &source, analysis_initial);
            defer execute.deinitIfPresent(&analysis);
            return transform.apply(allocator, &source, make_transform(&analysis));
        }

        pub const wrt = Methods.wrt;
        pub const inAxes = Methods.inAxes;
        pub const out = Methods.out;
        pub const analyze = Methods.analyze;
        pub const rewrite = Methods.rewrite;
        pub const jvp = Methods.jvp;
        pub const jvpWith = Methods.jvpWith;
        pub const grad = Methods.grad;
        pub const gradWith = Methods.gradWith;
        pub const vmap = Methods.vmap;
        pub const vmapWith = Methods.vmapWith;
        pub const lower = Methods.lower;
        pub const prepare = Methods.prepare;
        pub const prepareWith = Methods.prepareWith;
        pub const prepareFragment = Methods.prepareFragment;
        pub const createArtifactJob = Methods.createArtifactJob;
        pub const compileFragment = Methods.compileFragment;
        pub const verify = Methods.verify;

        pub fn interpret(
            allocator: std.mem.Allocator,
            initial: anytype,
        ) !interpret_mod.result(@TypeOf(initial)) {
            return execute.analysisRewriteProgram(
                ProgramType,
                analysis_initial,
                make_transform,
                allocator,
                initial,
            );
        }
    };
}

fn AnalysisDerived(
    comptime ProgramType: type,
    comptime derivation: Derivation,
    comptime options: anytype,
    comptime analysis_initial: anytype,
    comptime make_hooks: anytype,
) type {
    return struct {
        pub const name = ProgramType.name;
        pub const parameters = ProgramType.parameters;
        pub const Layout: type = DerivedLayout(ProgramType, derivation, options);
        pub const Outputs: type = DerivedOutputs(ProgramType, derivation, options);
        const Methods: type = Surface(@This());

        pub fn build(allocator: std.mem.Allocator) !program_mod.Program {
            var source = try ProgramType.build(allocator);
            defer source.deinit();

            var analysis = try interpret_mod.run(allocator, &source, analysis_initial);
            defer execute.deinitIfPresent(&analysis);

            const hooks = make_hooks(&analysis);
            if (comptime derivation == .jvp_with) {
                return autodiff.jvpWith(allocator, &source, options.jvp, hooks);
            }
            if (comptime derivation == .grad_with) {
                return gradient.gradWith(allocator, &source, options.grad, hooks);
            }
            if (comptime derivation == .vmap_with) {
                return batch.vmapWith(allocator, &source, options.vmap, hooks);
            }
            unreachable;
        }

        pub const wrt = Methods.wrt;
        pub const inAxes = Methods.inAxes;
        pub const out = Methods.out;
        pub const analyze = Methods.analyze;
        pub const rewrite = Methods.rewrite;
        pub const jvp = Methods.jvp;
        pub const jvpWith = Methods.jvpWith;
        pub const grad = Methods.grad;
        pub const gradWith = Methods.gradWith;
        pub const vmap = Methods.vmap;
        pub const vmapWith = Methods.vmapWith;
        pub const lower = Methods.lower;
        pub const prepare = Methods.prepare;
        pub const prepareWith = Methods.prepareWith;
        pub const prepareFragment = Methods.prepareFragment;
        pub const createArtifactJob = Methods.createArtifactJob;
        pub const compileFragment = Methods.compileFragment;
        pub const verify = Methods.verify;

        pub fn interpret(
            allocator: std.mem.Allocator,
            initial: anytype,
        ) !interpret_mod.result(@TypeOf(initial)) {
            var source = try ProgramType.build(allocator);
            defer source.deinit();

            var analysis = try interpret_mod.run(allocator, &source, analysis_initial);
            defer execute.deinitIfPresent(&analysis);

            const hooks = make_hooks(&analysis);
            if (comptime derivation == .jvp_with) {
                return execute.jvpSource(allocator, &source, options.jvp, hooks, initial);
            }
            if (comptime derivation == .grad_with) {
                return execute.gradSource(allocator, &source, options.grad, hooks, initial);
            }
            if (comptime derivation == .vmap_with) {
                return execute.vmapSource(allocator, &source, options.vmap, hooks, initial);
            }
            return execute.program(@This(), allocator, initial);
        }
    };
}

fn Surface(comptime ProgramType: type) type {
    return struct {
        pub fn wrt(comptime names: anytype) *const [parameter.nameCount(names)]usize {
            return ProgramType.Layout.indices(names);
        }

        pub fn inAxes(comptime axes: anytype) *const [ProgramType.Layout.count]batch.Axis {
            return ProgramType.Layout.axes(axes);
        }

        pub fn out(comptime spec: anytype) usize {
            return ProgramType.Outputs.index(spec);
        }

        pub fn rewrite(comptime pass: anytype) type {
            return Derived(ProgramType, .rewrite, pass);
        }

        pub fn analyze(comptime analysis_initial: anytype) type {
            return Analysis(ProgramType, analysis_initial);
        }

        pub fn jvp(comptime options: autodiff.JvpOptions) type {
            return Derived(ProgramType, .jvp, options);
        }

        pub fn jvpWith(comptime options: autodiff.JvpOptions, comptime hooks: anytype) type {
            return Derived(ProgramType, .jvp_with, .{ .jvp = options, .hooks = hooks });
        }

        pub fn grad(comptime options: gradient.Options) type {
            return Derived(ProgramType, .grad, options);
        }

        pub fn gradWith(comptime options: gradient.Options, comptime hooks: anytype) type {
            return Derived(ProgramType, .grad_with, .{ .grad = options, .hooks = hooks });
        }

        pub fn vmap(comptime options: batch.Options) type {
            return Derived(ProgramType, .vmap, options);
        }

        pub fn vmapWith(comptime options: batch.Options, comptime hooks: anytype) type {
            return Derived(ProgramType, .vmap_with, .{ .vmap = options, .hooks = hooks });
        }

        pub fn interpret(
            allocator: std.mem.Allocator,
            initial: anytype,
        ) !interpret_mod.result(@TypeOf(initial)) {
            return execute.program(ProgramType, allocator, initial);
        }

        pub fn lower(allocator: std.mem.Allocator) !*lower_mod.SemanticModule {
            return execute.lower(ProgramType, allocator);
        }

        pub fn prepare(allocator: std.mem.Allocator) !lower_mod.BackendPreparedJob {
            return execute.prepare(ProgramType, allocator);
        }

        pub fn prepareWith(
            allocator: std.mem.Allocator,
            options: lower_mod.BackendPreparationRunOptions,
        ) !lower_mod.BackendPreparedJob {
            return execute.prepareWith(ProgramType, allocator, options);
        }

        pub fn prepareFragment(
            allocator: std.mem.Allocator,
            handle: lower_mod.BackendHandle,
            options: lower_mod.FragmentCompilerOptions,
        ) !lower_mod.BackendPreparedJob {
            return execute.prepareFragment(ProgramType, allocator, handle, options);
        }

        pub fn createArtifactJob(
            allocator: std.mem.Allocator,
            handle: lower_mod.BackendHandle,
            options: lower_mod.FragmentCompilerOptions,
        ) !*lower_mod.ArtifactJob {
            return execute.createArtifactJob(ProgramType, allocator, handle, options);
        }

        pub fn compileFragment(
            allocator: std.mem.Allocator,
            handle: lower_mod.BackendHandle,
            options: lower_mod.FragmentCompilerOptions,
        ) !*lower_mod.CompiledFragment {
            return execute.compileFragment(ProgramType, allocator, handle, options);
        }

        pub fn verify(allocator: std.mem.Allocator) !void {
            try execute.verify(ProgramType, allocator);
        }
    };
}

fn DerivedLayout(
    comptime SourceProgram: type,
    comptime derivation: Derivation,
    comptime options: anytype,
) type {
    if (comptime derivation == .jvp) {
        return parameter.Jvp(SourceProgram.Layout, SourceProgram.parameters, options);
    }
    if (comptime derivation == .jvp_with) {
        return parameter.Jvp(SourceProgram.Layout, SourceProgram.parameters, options.jvp);
    }
    return SourceProgram.Layout;
}

fn DerivedOutputs(
    comptime SourceProgram: type,
    comptime derivation: Derivation,
    comptime options: anytype,
) type {
    return output.Derived(SourceProgram, derivation, options);
}
