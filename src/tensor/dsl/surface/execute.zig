const std = @import("std");
const tensor = @import("../../root.zig");
const autodiff = tensor.autodiff;
const batch = tensor.batch;
const gradient = tensor.gradient;
const interpret_mod = tensor.interpret;
const lower_mod = tensor.lower;
const program_mod = tensor.program;
const trace = tensor.trace;
const transform = tensor.transform;

pub fn lower(comptime SourceProgram: type, allocator: std.mem.Allocator) !*lower_mod.SemanticModule {
    return SourceProgram.interpret(allocator, lower_mod.module(allocator));
}

pub fn prepare(
    comptime SourceProgram: type,
    allocator: std.mem.Allocator,
) !lower_mod.BackendPreparedJob {
    return prepareWith(SourceProgram, allocator, .{});
}

pub fn prepareWith(
    comptime SourceProgram: type,
    allocator: std.mem.Allocator,
    options: lower_mod.BackendPreparationRunOptions,
) !lower_mod.BackendPreparedJob {
    var built = try SourceProgram.build(allocator);
    defer built.deinit();

    return lower_mod.prepareWith(allocator, &built, options);
}

pub fn prepareFragment(
    comptime SourceProgram: type,
    allocator: std.mem.Allocator,
    handle: lower_mod.BackendHandle,
    options: lower_mod.FragmentCompilerOptions,
) !lower_mod.BackendPreparedJob {
    var built = try SourceProgram.build(allocator);
    defer built.deinit();

    return lower_mod.prepareFragment(allocator, handle, &built, options);
}

pub fn createArtifactJob(
    comptime SourceProgram: type,
    allocator: std.mem.Allocator,
    handle: lower_mod.BackendHandle,
    options: lower_mod.FragmentCompilerOptions,
) !*lower_mod.ArtifactJob {
    var built = try SourceProgram.build(allocator);
    defer built.deinit();

    return lower_mod.createArtifactJob(allocator, handle, &built, options);
}

pub fn compileFragment(
    comptime SourceProgram: type,
    allocator: std.mem.Allocator,
    handle: lower_mod.BackendHandle,
    options: lower_mod.FragmentCompilerOptions,
) !*lower_mod.CompiledFragment {
    var built = try SourceProgram.build(allocator);
    defer built.deinit();

    return lower_mod.compileFragment(allocator, handle, &built, options);
}

pub fn verify(comptime SourceProgram: type, allocator: std.mem.Allocator) !void {
    const module = try lower(SourceProgram, allocator);
    defer module.deinit();

    try module.verify();
}

pub fn program(comptime SourceProgram: type, allocator: std.mem.Allocator, initial: anytype) !interpret_mod.result(@TypeOf(initial)) {
    var built = try SourceProgram.build(allocator);
    defer built.deinit();

    if (comptime @hasDecl(@TypeOf(initial), "attach")) {
        var builder = try trace.Builder.init(allocator, SourceProgram.name);
        errdefer builder.deinit();

        return interpret_mod.run(allocator, &built, initial.attach(interpret_mod.Graph{ .builder = &builder }));
    }

    return interpret_mod.run(allocator, &built, initial);
}

pub fn rewriteProgram(comptime SourceProgram: type, comptime pass: anytype, allocator: std.mem.Allocator, initial: anytype) !interpret_mod.result(@TypeOf(initial)) {
    var source = try SourceProgram.build(allocator);
    defer source.deinit();

    return rewriteSource(allocator, &source, pass, initial);
}

pub fn analysisRewriteProgram(
    comptime ProgramType: type,
    comptime analysis_initial: anytype,
    comptime make_transform: anytype,
    allocator: std.mem.Allocator,
    initial: anytype,
) !interpret_mod.result(@TypeOf(initial)) {
    var source = try ProgramType.build(allocator);
    defer source.deinit();

    var analysis = try interpret_mod.run(allocator, &source, analysis_initial);
    defer deinitIfPresent(&analysis);

    return rewriteSource(allocator, &source, make_transform(&analysis), initial);
}

fn rewriteSource(allocator: std.mem.Allocator, source: *const program_mod.Program, pass: anytype, initial: anytype) !interpret_mod.result(@TypeOf(initial)) {
    if (comptime @hasDecl(@TypeOf(initial), "attach")) {
        var builder = try trace.Builder.init(allocator, source.name);
        errdefer builder.deinit();

        const graph = interpret_mod.Graph{ .builder = &builder };
        return interpret_mod.run(allocator, source, transform.semantics(source, initial.attach(graph), pass));
    }

    var rewritten = try transform.apply(allocator, source, pass);
    defer rewritten.deinit();

    return interpret_mod.run(allocator, &rewritten, initial);
}

pub fn jvpProgram(comptime SourceProgram: type, comptime options: autodiff.JvpOptions, allocator: std.mem.Allocator, initial: anytype) !interpret_mod.result(@TypeOf(initial)) {
    var source = try SourceProgram.build(allocator);
    defer source.deinit();

    return jvpSource(allocator, &source, options, .{}, initial);
}

pub fn jvpWithProgram(
    comptime SourceProgram: type,
    comptime options: autodiff.JvpOptions,
    comptime hooks: anytype,
    allocator: std.mem.Allocator,
    initial: anytype,
) !interpret_mod.result(@TypeOf(initial)) {
    var source = try SourceProgram.build(allocator);
    defer source.deinit();

    return jvpSource(allocator, &source, options, hooks, initial);
}

pub fn jvpSource(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: autodiff.JvpOptions,
    hooks: anytype,
    initial: anytype,
) !interpret_mod.result(@TypeOf(initial)) {
    if (comptime @hasDecl(@TypeOf(initial), "attach")) {
        try autodiff.validate(source, options);

        var builder = try trace.Builder.init(allocator, source.name);
        errdefer builder.deinit();

        const graph = interpret_mod.Graph{ .builder = &builder };
        const attached = initial.attach(graph);
        return interpret_mod.run(allocator, source, autodiff.jvpSemanticsWith(source, attached, options, hooks));
    }

    var owned = try autodiff.jvpWith(allocator, source, options, hooks);
    defer owned.deinit();

    return interpret_mod.run(allocator, &owned, initial);
}

pub fn gradProgram(comptime SourceProgram: type, comptime options: gradient.Options, allocator: std.mem.Allocator, initial: anytype) !interpret_mod.result(@TypeOf(initial)) {
    var source = try SourceProgram.build(allocator);
    defer source.deinit();

    return gradSource(allocator, &source, options, .{}, initial);
}

pub fn gradWithProgram(
    comptime SourceProgram: type,
    comptime options: gradient.Options,
    comptime hooks: anytype,
    allocator: std.mem.Allocator,
    initial: anytype,
) !interpret_mod.result(@TypeOf(initial)) {
    var source = try SourceProgram.build(allocator);
    defer source.deinit();

    return gradSource(allocator, &source, options, hooks, initial);
}

pub fn gradSource(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: gradient.Options,
    hooks: anytype,
    initial: anytype,
) !interpret_mod.result(@TypeOf(initial)) {
    return gradient.interpretWith(allocator, source, options, hooks, initial);
}

pub fn vmapProgram(comptime SourceProgram: type, comptime options: batch.Options, allocator: std.mem.Allocator, initial: anytype) !interpret_mod.result(@TypeOf(initial)) {
    var source = try SourceProgram.build(allocator);
    defer source.deinit();

    return vmapSource(allocator, &source, options, .{}, initial);
}

pub fn vmapWithProgram(
    comptime SourceProgram: type,
    comptime options: batch.Options,
    comptime hooks: anytype,
    allocator: std.mem.Allocator,
    initial: anytype,
) !interpret_mod.result(@TypeOf(initial)) {
    var source = try SourceProgram.build(allocator);
    defer source.deinit();

    return vmapSource(allocator, &source, options, hooks, initial);
}

pub fn vmapSource(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: batch.Options,
    hooks: anytype,
    initial: anytype,
) !interpret_mod.result(@TypeOf(initial)) {
    if (comptime @hasDecl(@TypeOf(initial), "attach")) {
        try batch.validate(source, options);

        var builder = try trace.Builder.init(allocator, source.name);
        errdefer builder.deinit();

        const graph = interpret_mod.Graph{ .builder = &builder };
        const attached = initial.attach(graph);
        return interpret_mod.run(allocator, source, batch.semanticsWith(attached, options, hooks));
    }

    var owned = try batch.vmapWith(allocator, source, options, hooks);
    defer owned.deinit();

    return interpret_mod.run(allocator, &owned, initial);
}

pub fn deinitIfPresent(value: anytype) void {
    const Value = @typeInfo(@TypeOf(value)).pointer.child;
    switch (@typeInfo(Value)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => if (comptime @hasDecl(Value, "deinit")) value.deinit(),
        else => {},
    }
}
