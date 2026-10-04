const std = @import("std");
const manifest = @import("root.zig");
const invocation = @import("../invocation/root.zig");

/// The actual selected Zig library already belongs to toolchain/lib.
/// Retain its selection in the invocation without duplicating its 20k rows.
pub fn capture(inputs: *manifest.paths.Inputs, record: invocation.Record) !void {
    if (record.maker.sysroot) |path| try directory(inputs, path, "invocation/sysroot");
    if (record.maker.libc_file) |path| try libc(inputs, path, "invocation/libc");
    for (record.maker.search_prefixes, 0..) |path, index| {
        try directory(inputs, path, inputs.build.fmt("invocation/search/{d}", .{index}));
    }
    if (record.maker.libc_runtimes_directory) |path| {
        try directory(inputs, path, "invocation/libc-runtimes");
    }
    var native_paths = false;
    for (record.environment) |entry| {
        const value = entry.value orelse continue;
        if (std.mem.eql(u8, entry.name, "ZIG_LIBC")) {
            try libc(inputs, value, "environment/libc");
        } else if (std.mem.startsWith(u8, entry.name, "NIX_")) {
            native_paths = true;
        } else if (std.mem.eql(u8, entry.name, "HOMEBREW_PREFIX")) {
            try directory(inputs, value, "environment/homebrew");
        } else if (std.mem.eql(u8, entry.name, "C_INCLUDE_PATH") or
            std.mem.eql(u8, entry.name, "CPLUS_INCLUDE_PATH") or
            std.mem.eql(u8, entry.name, "LIBRARY_PATH"))
        {
            var paths = std.mem.splitScalar(u8, value, ':');
            var index: u32 = 0;
            while (paths.next()) |path| : (index += 1) {
                if (path.len == 0) continue;
                if (index == invocation.record.maximum_paths) {
                    return error.CompilerInputCountExceeded;
                }
                const name = inputs.build.fmt("environment/{s}/{d}", .{ entry.name, index });
                try directory(inputs, path, name);
            }
        } else if (std.mem.startsWith(u8, entry.name, "TINY_STARDUST_") and value.len != 0) {
            return error.UnqualifiedCompilerObserver;
        }
    }
    if (native_paths) try nixPaths(inputs);
}

/// Native discovery must be qualified by its owner before it can authorize a
/// sealed product. An explicit libc description contributes its entire paths.
fn libc(inputs: *manifest.paths.Inputs, path: []const u8, name: []const u8) !void {
    const b = inputs.build;
    const absolute = try std.fs.path.resolve(b.graph.arena, &.{path});
    const lazy = std.Build.LazyPath{ .cwd_relative = absolute };
    b.dependOnFileContents(lazy);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        absolute,
        b.graph.arena,
        .limited(64 * 1024),
    );
    try inputs.file(lazy, b.pathJoin(&.{ name, "description" }));
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    // The compiler still reads `gcc_dir` as an alias of `cc_dir`.
    const fields = [_][]const u8{
        "include_dir",      "sys_include_dir", "crt_dir",        "msvc_lib_dir",
        "kernel32_lib_dir", "cc_dir",          "darwin_sdk_dir", "gcc_dir",
    };
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const pair = std.mem.cutScalar(u8, line, '=') orelse
            return error.UnqualifiedLibcDescription;
        var found = false;
        for (fields) |field| if (std.mem.eql(u8, pair[0], field)) {
            found = true;
            if (pair[1].len != 0) try directory(inputs, pair[1], b.pathJoin(&.{ name, field }));
            break;
        };
        if (!found) return error.UnqualifiedLibcDescription;
    }
}

fn directory(inputs: *manifest.paths.Inputs, path: []const u8, name: []const u8) !void {
    const b = inputs.build;
    const absolute = try std.fs.path.resolve(b.graph.arena, &.{path});
    try inputs.directory(.{ .cwd_relative = absolute }, name);
}

fn nixPaths(inputs: *manifest.paths.Inputs) !void {
    const b = inputs.build;
    const paths = try std.zig.system.NativePaths.detect(
        b.graph.arena,
        b.graph.io,
        &b.graph.host.result,
        &b.graph.environ_map,
    );
    if (paths.warnings.items.len != 0) return error.UnqualifiedCompilerNativePaths;
    inline for (.{ "include_dirs", "lib_dirs", "framework_dirs" }) |field| {
        const items = @field(paths, field).items;
        if (items.len > invocation.record.maximum_paths) return error.CompilerInputCountExceeded;
        for (items, 0..) |path, index| {
            try directory(inputs, path, b.fmt("environment/nix/{s}/{d}", .{ field, index }));
        }
    }
}
