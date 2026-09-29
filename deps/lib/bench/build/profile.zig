const std = @import("std");
const builtin = @import("builtin");
const build_api = @import("build_api");

pub fn profileBuildOptions(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const module_options = build_api.ModuleOptions{
        .target = target,
        .optimize = optimize,
    };
    const generate = b.addSystemCommand(&.{
        "sh",
        "-c",
        profile_options_script,
        "bench-profile-options",
        @tagName(optimize),
        target.result.zigTriple(b.allocator) catch @panic("OOM"),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.cpu.arch),
    });
    generate.setName("generate benchmark profile build options");
    generate.setCwd(b.path("."));
    generate.has_side_effects = true;
    return b.createModule(module_options.createOptionsWithRoot(
        generate.captureStdOut(.{
            .basename = "profile_build_options.zig",
            .trim_whitespace = .none,
        }),
        &.{},
    ));
}

const profile_options_script =
    \\git_sha=$(git rev-parse --short=12 HEAD 2>/dev/null) || git_sha=unknown
    \\git_dirty=false
    \\if [ -n "$(git status --short --untracked-files=all 2>/dev/null)" ]; then
    \\    git_dirty=true
    \\fi
    \\printf 'pub const git_sha = "%s";\n' "$git_sha"
    \\printf 'pub const git_dirty = %s;\n' "$git_dirty"
    \\printf 'pub const optimize = "%s";\n' "$1"
    \\printf 'pub const target = "%s";\n' "$2"
    \\printf 'pub const host_os = "%s";\n' "$3"
    \\printf 'pub const host_arch = "%s";\n' "$4"
;
