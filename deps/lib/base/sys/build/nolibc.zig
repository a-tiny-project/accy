const std = @import("std");

pub const NoLibcArtifactPolicy = union(enum) {
    none,
    all,
    artifacts: []const *std.Build.Step.Compile,
};

pub const NoLibcNeededCheck = struct {
    target: std.Build.ResolvedTarget,
    step_name: []const u8,
    description: []const u8,
    label: []const u8,
    artifacts: []const *std.Build.Step.Compile,
    strict_undefined: NoLibcArtifactPolicy = .none,
};

/// Checks each artifact for a Linux target with the `nolibc-inspect` host
/// tool, which refuses one that needs libc, libm or the dynamic loader, or,
/// under `strict_undefined`, leaves a C runtime symbol undefined. Each
/// artifact's module graph must also not link libc or libm. Returns null for
/// other targets.
pub fn addNoLibcNeededCheck(b: *std.Build, options: NoLibcNeededCheck) ?*std.Build.Step {
    if (options.target.result.os.tag != .linux) return null;

    const step = b.step(options.step_name, options.description);
    const tool = inspector(b);
    for (options.artifacts) |artifact| {
        const run = std.Build.Step.Run.create(b, b.fmt("{s} {s}", .{
            options.label,
            artifact.out_filename,
        }));
        run.addFileArg(tool);
        run.addArg(options.label);
        run.addArg(checks(artifact, options));
        run.addArtifactArg(artifact);
        run.expectExitCode(0);
        step.dependOn(&run.step);
        inline for (.{ "c", "m" }) |library| {
            if (hasSystemLibraryDependency(b.allocator, artifact, library)) {
                const failure = b.addFail(b.fmt(
                    "[{s}] {s} transitively depends on lib{s}",
                    .{ options.label, artifact.out_filename, library },
                ));
                step.dependOn(&failure.step);
            }
        }
    }
    return step;
}

/// The inspector's checks for `artifact`: `u` when its policy selects
/// undefined symbols, or `-` for the needed libraries alone.
fn checks(artifact: *std.Build.Step.Compile, options: NoLibcNeededCheck) []const u8 {
    return switch (options.strict_undefined) {
        .none => "-",
        .all => "u",
        .artifacts => |artifacts| if (std.mem.indexOfScalar(
            *std.Build.Step.Compile,
            artifacts,
            artifact,
        ) != null) "u" else "-",
    };
}

const inspector_name = "sys_nolibc_inspect";

/// The host tool that inspects one artifact, built once per builder and
/// published as the builder's named lazy path `sys_nolibc_inspect`. Its
/// sources travel inside this file, so a caller builds it in its own graph
/// without instantiating the sys package again.
pub fn inspector(b: *std.Build) std.Build.LazyPath {
    if (b.named_lazy_paths.get(inspector_name)) |path| return path;
    const sources = b.addWriteFiles();
    _ = sources.add("main.zig", @embedFile("../tools/nolibc/main.zig"));
    _ = sources.add("root.zig", @embedFile("../tools/nolibc/root.zig"));
    _ = sources.add("policy.zig", @embedFile("../tools/nolibc/policy.zig"));
    const tool = b.addExecutable(.{
        .name = "nolibc-inspect",
        .root_module = b.createModule(.{
            .root_source_file = sources.getDirectory().path(b, "main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const path = tool.getEmittedBin();
    b.addNamedLazyPath(inspector_name, path);
    return path;
}

fn hasSystemLibraryDependency(
    allocator: std.mem.Allocator,
    artifact: *std.Build.Step.Compile,
    name: []const u8,
) bool {
    var compiles: std.AutoArrayHashMapUnmanaged(*std.Build.Step.Compile, void) = .empty;
    defer compiles.deinit(allocator);
    var modules: std.AutoArrayHashMapUnmanaged(*std.Build.Module, void) = .empty;
    defer modules.deinit(allocator);

    compiles.put(allocator, artifact, {}) catch @panic("OOM");
    var compile_index: usize = 0;
    var module_index: usize = 0;
    var links_libc = false;
    var links_libcpp = false;

    while (compile_index < compiles.count() or module_index < modules.count()) {
        while (compile_index < compiles.count()) : (compile_index += 1) {
            const compile = compiles.keys()[compile_index];
            modules.put(allocator, compile.root_module, {}) catch @panic("OOM");
        }
        while (module_index < modules.count()) : (module_index += 1) {
            const module = modules.keys()[module_index];
            links_libc = links_libc or (module.link_libc orelse false);
            links_libcpp = links_libcpp or (module.link_libcpp orelse false);
            for (module.import_table.values()) |import| {
                modules.put(allocator, import, {}) catch @panic("OOM");
            }
            for (module.link_objects.items) |object| switch (object) {
                .system_lib => |library| {
                    if (std.mem.eql(u8, library.name, name)) return true;
                },
                .other_step => |compile| {
                    compiles.put(allocator, compile, {}) catch @panic("OOM");
                },
                else => {},
            };
        }
    }

    const target = artifact.rootModuleTarget();
    if (std.zig.target.isLibCLibName(&target, name)) return links_libc;
    if (std.zig.target.isLibCxxLibName(&target, name)) return links_libcpp;
    return false;
}
