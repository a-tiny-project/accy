const std = @import("std");
const build_api = @import("build_api");
const sys_build = @import("sys");

const missing_oracle_message =
    "xkb conformance requires -Dxkbcommon-lib-dir=<directory> or " ++
    "XKBCOMMON_LIB_DIR pointing to pinned libxkbcommon 1.13.2 " ++
    "(xkbcommon-1.13.2, d1442aaa6b635551182e83c3b55037f4c118c962); " ++
    "host pkg-config fallback is forbidden";

pub fn add(
    b: *std.Build,
    options: build_api.ModuleOptions,
    xkb: *std.Build.Module,
    test_filters: []const []const u8,
) void {
    const oracle_lib_dir = if (b.option(
        []const u8,
        "xkbcommon-lib-dir",
        "Directory containing pinned libxkbcommon 1.13.2",
    )) |directory|
        b.graph.cwdRelativePath(directory)
    else
        environmentLibraryDirectory(b);
    const conformance_step = b.step("conformance", "Run XKB libxkbcommon differential conformance");
    const conformance_module = b.createModule(options.createOptions(
        b,
        "src/conformance/test.zig",
        &.{.{ .name = "xkb", .module = xkb }},
    ));
    sys_build.linkLibc(conformance_module);
    conformance_module.addLibraryPath(oracle_lib_dir);
    conformance_module.addRPath(oracle_lib_dir);
    conformance_module.linkSystemLibrary("xkbcommon", .{ .use_pkg_config = .no });
    const conformance_tests = b.addTest(.{
        .root_module = conformance_module,
        .filters = test_filters,
    });
    const run_conformance_tests = b.addRunArtifact(conformance_tests);
    conformance_step.dependOn(&run_conformance_tests.step);
}

fn environmentLibraryDirectory(b: *std.Build) std.Build.LazyPath {
    const resolve = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -eu
        \\if [ "${XKBCOMMON_LIB_DIR+x}" != x ]; then
        \\    printf '%s\n' "$1" >&2
        \\    exit 1
        \\fi
        \\case "$XKBCOMMON_LIB_DIR" in
        \\    /*) directory=$XKBCOMMON_LIB_DIR ;;
        \\    *) directory=$PWD/$XKBCOMMON_LIB_DIR ;;
        \\esac
        \\rm -f "$2"
        \\ln -s "$directory" "$2"
        ,
        "tiny-xkbcommon-lib-dir",
        missing_oracle_message,
    });
    resolve.setCwd(b.path("."));
    const directory = resolve.addOutputFileArg2(
        "tiny-xkbcommon-lib-dir",
        .{ .make_absolute = true },
    );
    resolve.setName("resolve XKBCOMMON_LIB_DIR");
    resolve.has_side_effects = true;
    return directory;
}
