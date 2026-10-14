const std = @import("std");
const build_api = @import("../root.zig");

pub const Options = struct {
    repository_root: ?std.Build.LazyPath = null,
    fallback_version: []const u8,
    minimum_source_prefix_bytes: usize,
    unavailable_message: []const u8,
    optimize: std.builtin.OptimizeMode,
    pretty_mod: *std.Build.Module,
};

pub const Modules = struct {
    model: *std.Build.Module,
    revision: *std.Build.Module,
    revision_file: std.Build.LazyPath,
    source_base: *std.Build.Module,
    source_prefix: *std.Build.Module,
    version: *std.Build.Module,
    version_file: std.Build.LazyPath,
};

pub const RevisionOptions = struct {
    repository_root: ?std.Build.LazyPath = null,
    unavailable_message: []const u8,
    optimize: std.builtin.OptimizeMode,
    pretty_mod: *std.Build.Module,
};

pub const RevisionModules = struct {
    revision: *std.Build.Module,
    revision_file: std.Build.LazyPath,
};

pub fn addRevision(b: *std.Build, options: RevisionOptions) RevisionModules {
    const policy = build_api.ModuleOptions.host(b, options.optimize, "");
    const producer = addProducer(b, policy, options.pretty_mod, "tiny-repository-revision");
    const run = b.addRunArtifact(producer);
    run.setName("resolve repository revision");
    run.setCwd(options.repository_root orelse b.path("."));
    run.addArg(options.unavailable_message);
    const revision = run.addOutputFileArg("repository-revision.zig");
    const revision_file = run.addOutputFileArg("repository-revision.txt");
    run.has_side_effects = true;
    return .{
        .revision = generatedModule(b, policy, revision),
        .revision_file = revision_file,
    };
}

pub const StatusOptions = struct {
    repository_root: ?std.Build.LazyPath = null,
    step_name: []const u8,
    paths: []const []const u8,
    optimize: std.builtin.OptimizeMode,
    pretty_mod: *std.Build.Module,
};

pub const StatusModules = struct {
    clean: *std.Build.Module,
    clean_file: std.Build.LazyPath,
};

pub fn add(b: *std.Build, options: Options) Modules {
    const policy = build_api.ModuleOptions.host(b, options.optimize, "");
    const model_mod = provenanceModel(b, policy);
    const producer = addProducerWithModel(
        b,
        policy,
        options.pretty_mod,
        "tiny-repository-provenance",
        model_mod,
    );
    const run = b.addRunArtifact(producer);
    run.setName("resolve repository provenance");
    run.setCwd(options.repository_root orelse b.path("."));
    run.addArg(options.fallback_version);
    run.addArg(b.fmt("{d}", .{options.minimum_source_prefix_bytes}));
    run.addArg(options.unavailable_message);
    const revision = run.addOutputFileArg("repository-revision.zig");
    const revision_file = run.addOutputFileArg("repository-revision.txt");
    const source_base = run.addOutputFileArg("repository-source-base.zig");
    const source_prefix = run.addOutputFileArg("repository-source-prefix.zig");
    const version = run.addOutputFileArg("repository-version.zig");
    const version_file = run.addOutputFileArg("repository-version.txt");
    run.has_side_effects = true;
    return .{
        .model = model_mod,
        .revision = generatedModule(b, policy, revision),
        .revision_file = revision_file,
        .source_base = generatedModule(b, policy, source_base),
        .source_prefix = generatedModule(b, policy, source_prefix),
        .version = generatedModule(b, policy, version),
        .version_file = version_file,
    };
}

fn provenanceModel(b: *std.Build, policy: build_api.ModuleOptions) *std.Build.Module {
    const dependency = b.dependency("build_api", .{});
    return b.createModule(policy.createOptionsWithRoot(
        dependency.path("src/provenance/model/root.zig"),
        &.{},
    ));
}

fn addProducer(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    pretty: *std.Build.Module,
    name: []const u8,
) *std.Build.Step.Compile {
    return addProducerWithModel(b, policy, pretty, name, provenanceModel(b, policy));
}

fn addProducerWithModel(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    pretty: *std.Build.Module,
    name: []const u8,
    model_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const dependency = b.dependency("build_api", .{});
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(policy.createOptionsWithRoot(
            dependency.path("src/provenance/main.zig"),
            &.{
                .{ .name = "pretty", .module = pretty },
                .{ .name = "provenance_model", .module = model_mod },
            },
        )),
        .use_llvm = build_api.hostToolBackend(b),
    });
}

pub fn addStatus(b: *std.Build, options: StatusOptions) StatusModules {
    const policy = build_api.ModuleOptions.host(b, options.optimize, "");
    std.debug.assert(options.paths.len > 0);
    const producer = b.addExecutable(.{
        .name = "tiny-repository-status",
        .root_module = b.createModule(policy.createOptionsWithRoot(
            b.dependency("build_api", .{}).path("src/provenance/status.zig"),
            &.{.{ .name = "pretty", .module = options.pretty_mod }},
        )),
        .use_llvm = build_api.hostToolBackend(b),
    });
    const run = b.addRunArtifact(producer);
    run.setName(options.step_name);
    run.setCwd(options.repository_root orelse b.path("."));
    const clean = run.addOutputFileArg("repository-clean.zig");
    const clean_file = run.addOutputFileArg("repository-clean.txt");
    run.addArgs(options.paths);
    run.has_side_effects = true;
    return .{
        .clean = generatedModule(b, policy, clean),
        .clean_file = clean_file,
    };
}

fn generatedModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    source: std.Build.LazyPath,
) *std.Build.Module {
    var create_options = options.createOptionsWithRoot(source, &.{});
    create_options.target = null;
    create_options.optimize = null;
    return b.createModule(create_options);
}
