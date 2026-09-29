const std = @import("std");
const builtin = @import("builtin");
const backend = @import("backend.zig");
const module = @import("module.zig");

pub const Lifetime = enum {
    one_shot,
    persistent,
};

pub const WatchResponse = enum {
    rebuild,
    restart,
};

pub const StateLifetime = enum {
    process_local,
    cache_persistent,
};

pub const CompilerIncrementalPolicy = enum {
    inherit,
    one_shot,
};

pub const selected_step_option = "iteration-step";
pub const receipt_directory_option = "iteration-receipt-dir";
pub const receipt_token_option = "iteration-receipt-token";
pub const external_marker_option = "iteration-marker-exe";
pub const request_file_option = "iteration-request-file";

pub const Observation = struct {
    selected_step: []const u8,
    receipt_directory: []const u8,
    receipt_token: []const u8,
    marker: std.Build.LazyPath,
    request_file: ?[]const u8,
};

pub const MarkerExecutable = union(enum) {
    artifact: *std.Build.Step.Compile,
    external: []const u8,
};

pub const Audit = struct {
    zig_version: []const u8,
    native_elf_linker_state: StateLifetime,
    assembly_file_edit: WatchResponse,
    build_graph_edit: WatchResponse,
    /// Pinned Zig exits before the K0 root `emit_digest` under `-fincremental`.
    k0_root_compiler_incremental: CompilerIncrementalPolicy,
    /// Pinned Maker retains old argv paths when generated native inputs change.
    generated_native_inputs_compiler_incremental: CompilerIncrementalPolicy,
    /// Generated Zig module paths also remain stale in a resident compiler argv.
    generated_module_inputs_compiler_incremental: CompilerIncrementalPolicy,
};

pub const audit = Audit{
    .zig_version = "0.17.0-dev.1465+8b2d0ce21",
    .native_elf_linker_state = .process_local,
    .assembly_file_edit = .restart,
    .build_graph_edit = .restart,
    .k0_root_compiler_incremental = .one_shot,
    .generated_native_inputs_compiler_incremental = .one_shot,
    .generated_module_inputs_compiler_incremental = .one_shot,
};

const one_shot_arguments = [_][]const u8{
    "build",
    "-fno-incremental",
};
const one_shot_compiler_arguments = [_][]const u8{
    "-fno-incremental",
};
const persistent_arguments = [_][]const u8{
    "build",
    "-fincremental",
    "--watch",
};
const live_compiler_arguments = [_][]const u8{
    "-fincremental",
};

pub fn configure(b: *std.Build) *std.Build.Step.Compile {
    const marker = addMarker(b);
    const run = b.addSystemCommand(&.{b.graph.zig_exe});
    run.addArgs(buildArguments(.persistent));
    run.addPrefixedFileArg(
        b.fmt("-D{s}=", .{external_marker_option}),
        marker.getEmittedBin(),
    );
    run.setName("watch build with incremental compilation");
    run.setCwd(b.path("."));
    run.stdio = .inherit;
    run.has_side_effects = true;
    run.addPassthruArgs();
    const step = b.step(
        "watch",
        "Watch a graph-owned step; delegated root steps expose <step>-watch",
    );
    step.dependOn(&run.step);
    return marker;
}

pub fn addMarker(b: *std.Build) *std.Build.Step.Compile {
    const source = b.addWriteFiles().add(
        "tiny-build-iteration-marker.zig",
        @embedFile("marker.zig"),
    );
    const module_options = module.ModuleOptions.host(b, .debug, "");
    return b.addExecutable(.{
        .name = "tiny-build-iteration-marker",
        .root_module = b.createModule(
            module_options.createOptionsWithRoot(source, &.{}),
        ),
        .use_llvm = backend.hostTool(b),
    });
}

pub fn finalize(
    b: *std.Build,
    local_marker: *std.Build.Step.Compile,
) void {
    const marker_path = scalarOption(
        b,
        external_marker_option,
        "Executable for an external iteration completion marker",
    );
    const selected_step = scalarOption(
        b,
        selected_step_option,
        "Top-level step observed by the machine iteration completion marker",
    );
    const receipt_directory = scalarOption(
        b,
        receipt_directory_option,
        "Directory for machine iteration completion markers",
    );
    const receipt_token = scalarOption(
        b,
        receipt_token_option,
        "Token shared by one machine iteration observation lane",
    );
    const request_file = scalarOption(
        b,
        request_file_option,
        "Await request file that invalidates one observed generation",
    );
    if (b.top_level_steps.contains("iteration-observe")) return;
    if (marker_path == null and selected_step == null and
        receipt_directory == null and receipt_token == null and
        request_file == null)
    {
        return;
    }
    const selected_name = selected_step orelse
        @panic("iteration observation requires a selected step");
    const directory = receipt_directory orelse
        @panic("iteration observation requires a receipt directory");
    const token = receipt_token orelse
        @panic("iteration observation requires a receipt token");
    if (request_file) |path| {
        if (!std.fs.path.isAbsolute(path)) {
            @panic("iteration request file must be absolute");
        }
    }
    if (marker_path) |path| {
        if (path.len == 0) @panic("external iteration marker path is empty");
    }
    if (std.mem.eql(u8, selected_name, "iteration-observe") or
        std.mem.eql(u8, selected_name, "watch"))
    {
        @panic("iteration observer cannot observe itself or the root watcher");
    }
    const selected = b.top_level_steps.get(selected_name) orelse
        std.debug.panic("unknown iteration step '{s}'", .{selected_name});
    const marker_step = addObservation(
        b,
        if (marker_path) |path|
            .{ .external = path }
        else
            .{ .artifact = local_marker },
        &selected.step,
        directory,
        token,
        selected_name,
        request_file,
    );
    const step = b.step(
        "iteration-observe",
        "Run one selected step and write a machine completion marker",
    );
    step.dependOn(marker_step);
}

pub fn addObservation(
    b: *std.Build,
    executable: MarkerExecutable,
    selected: *std.Build.Step,
    receipt_directory: []const u8,
    receipt_token: []const u8,
    selected_step: []const u8,
    request_file: ?[]const u8,
) *std.Build.Step {
    std.debug.assert(std.fs.path.isAbsolute(receipt_directory));
    std.debug.assert(receipt_token.len != 0);
    std.debug.assert(selected_step.len != 0);
    if (request_file) |path| std.debug.assert(std.fs.path.isAbsolute(path));

    if (request_file == null) {
        const complete = addMarkerCommand(b, executable);
        complete.setName("write machine iteration completion marker");
        complete.addArgs(&.{
            "complete",
            receipt_directory,
            receipt_token,
            selected_step,
        });
        complete.step.dependOn(selected);
        return &complete.step;
    }

    const trigger = addMarkerProcess(b, executable);
    trigger.setName("snapshot iteration await request");
    trigger.addArg("trigger");
    trigger.addFileArg2(
        b.graph.cwdRelativePath(request_file.?),
        .{ .make_absolute = true },
    );
    const request_snapshot = trigger.addOutputFileArg2(
        "iteration-request",
        .{ .make_absolute = true },
    );

    const begin = addMarkerCommand(b, executable);
    begin.setName("capture requested machine iteration generation");
    begin.addArgs(&.{
        "begin",
        receipt_directory,
        receipt_token,
        selected_step,
    });
    begin.addFileArg2(request_snapshot, .{ .make_absolute = true });
    selected.dependOn(&begin.step);

    const finish = addMarkerCommand(b, executable);
    finish.setName("write machine iteration completion marker");
    finish.addArgs(&.{
        "finish",
        receipt_directory,
        receipt_token,
        selected_step,
    });
    finish.step.dependOn(selected);
    return &finish.step;
}

fn addMarkerCommand(
    b: *std.Build,
    executable: MarkerExecutable,
) *std.Build.Step.Run {
    const run = addMarkerProcess(b, executable);
    run.has_side_effects = true;
    return run;
}

fn addMarkerProcess(
    b: *std.Build,
    executable: MarkerExecutable,
) *std.Build.Step.Run {
    const run = switch (executable) {
        .artifact => |artifact| b.addRunArtifact(artifact),
        .external => |path| b.addSystemCommand(&.{path}),
    };
    run.setCwd(b.path("."));
    return run;
}

fn scalarOption(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
) ?[]const u8 {
    if (!b.available_options_map.contains(name)) {
        return b.option([]const u8, name, description);
    }
    const option = b.user_input_options.get(name) orelse return null;
    return switch (option.value) {
        .scalar => |value| value,
        else => std.debug.panic("iteration option '-D{s}' must be a string", .{name}),
    };
}

pub fn appendObservation(
    b: *std.Build,
    run: *std.Build.Step.Run,
    observation: Observation,
) void {
    std.debug.assert(observation.selected_step.len != 0);
    std.debug.assert(std.fs.path.isAbsolute(observation.receipt_directory));
    std.debug.assert(observation.receipt_token.len != 0);
    run.addArg(b.fmt(
        "-D{s}={s}",
        .{ selected_step_option, observation.selected_step },
    ));
    run.addArg(b.fmt(
        "-D{s}={s}",
        .{ receipt_directory_option, observation.receipt_directory },
    ));
    run.addArg(b.fmt(
        "-D{s}={s}",
        .{ receipt_token_option, observation.receipt_token },
    ));
    run.addPrefixedFileArg(
        b.fmt("-D{s}=", .{external_marker_option}),
        observation.marker,
    );
    if (observation.request_file) |path| {
        run.addArg(b.fmt("-D{s}={s}", .{ request_file_option, path }));
    }
}

pub fn buildArguments(lifetime: Lifetime) []const []const u8 {
    return switch (lifetime) {
        .one_shot => &one_shot_arguments,
        .persistent => &persistent_arguments,
    };
}

pub fn liveCompilerArguments() []const []const u8 {
    return &live_compiler_arguments;
}

pub fn compilerIncrementalArguments(
    policy: CompilerIncrementalPolicy,
) []const []const u8 {
    return switch (policy) {
        .inherit => &.{},
        .one_shot => &one_shot_compiler_arguments,
    };
}

pub fn applyCompilerIncrementalPolicy(
    compile: *std.Build.Step.Compile,
    policy: CompilerIncrementalPolicy,
) void {
    compile.incremental = compilerIncremental(policy);
}

pub fn applyGeneratedInputPolicy(compile: *std.Build.Step.Compile) void {
    if (compile.incremental == false) return;
    const policy = audit.generated_native_inputs_compiler_incremental;
    for ([_]?std.Build.LazyPath{
        compile.linker_script,
        compile.version_script,
        compile.libc_file,
        compile.win32_manifest,
        compile.win32_module_definition,
        compile.entitlements,
    }) |path| {
        if (path) |input| {
            if (input == .generated) {
                applyCompilerIncrementalPolicy(compile, policy);
                return;
            }
        }
    }
    for (compile.root_module.getGraph().modules) |imported| {
        if (imported.root_source_file) |path| {
            if (path == .generated) {
                applyCompilerIncrementalPolicy(
                    compile,
                    audit.generated_module_inputs_compiler_incremental,
                );
                return;
            }
        }
        if (hasGeneratedNativeInput(imported)) {
            applyCompilerIncrementalPolicy(compile, policy);
            return;
        }
    }
}

fn hasGeneratedNativeInput(imported: *const std.Build.Module) bool {
    for (imported.link_objects.items) |object| {
        const generated = switch (object) {
            .static_path, .assembly_file => |path| path == .generated,
            .other_step => true,
            .system_lib => false,
            .c_source_file => |source| source.file == .generated,
            .c_source_files => |sources| sources.root == .generated,
            .win32_resource_file => |source| generatedResource(source),
        };
        if (generated) return true;
    }
    for (imported.include_dirs.items) |include| {
        const generated = switch (include) {
            .path,
            .path_system,
            .path_after,
            .framework_path,
            .framework_path_system,
            => |path| path == .generated,
            .other_step, .config_header_step => true,
            .embed_path => false,
        };
        if (generated) return true;
    }
    for (imported.lib_paths.items) |path| {
        if (path == .generated) return true;
    }
    for (imported.rpaths.items) |rpath| {
        if (rpath == .lazy_path and rpath.lazy_path == .generated) return true;
    }
    return false;
}

fn generatedResource(source: *const std.Build.Module.RcSourceFile) bool {
    if (source.file == .generated) return true;
    for (source.include_paths) |path| {
        if (path == .generated) return true;
    }
    return false;
}

fn compilerIncremental(policy: CompilerIncrementalPolicy) ?bool {
    return switch (policy) {
        .inherit => null,
        .one_shot => false,
    };
}

test "one-shot builds retain artifact caching" {
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "build", "-fno-incremental" },
        buildArguments(.one_shot),
    );
}

test "persistent builds keep the incremental compiler alive" {
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "build", "-fincremental", "--watch" },
        buildArguments(.persistent),
    );
}

test "live compiler captures enable incremental analysis" {
    try std.testing.expectEqualSlices(
        []const u8,
        &.{"-fincremental"},
        liveCompilerArguments(),
    );
}

test "one-shot compiler calls disable incremental state" {
    try std.testing.expectEqualSlices(
        []const u8,
        &.{"-fno-incremental"},
        compilerIncrementalArguments(.one_shot),
    );
    try std.testing.expectEqual(@as(usize, 0), compilerIncrementalArguments(
        .inherit,
    ).len);
}

test "native ELF linker state remains process-local" {
    try std.testing.expectEqual(
        StateLifetime.process_local,
        audit.native_elf_linker_state,
    );
}

test "pinned compiler keeps K0 root compilation one-shot" {
    try std.testing.expectEqual(
        CompilerIncrementalPolicy.one_shot,
        audit.k0_root_compiler_incremental,
    );
    try std.testing.expectEqual(
        false,
        compilerIncremental(audit.k0_root_compiler_incremental).?,
    );
}

test "toolchain changes require the iteration limitation audit" {
    try std.testing.expectEqualStrings(
        audit.zig_version,
        builtin.zig_version_string,
    );
}
