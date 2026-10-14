const std = @import("std");
const invocation = @import("root.zig");

pub const Parsed = struct { maker: invocation.Maker, build_file: []const u8 };

pub fn parse(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    compiler: []const u8,
    directory: []const u8,
    args: []const []const u8,
) !Parsed {
    const prefix = std.fs.path.dirname(std.fs.path.dirname(compiler).?).?;
    var result = Parsed{
        .maker = .{ .zig_lib_directory = environment.get("ZIG_LIB_DIR") orelse
            try std.fs.path.join(allocator, &.{ prefix, "lib/zig" }) },
        .build_file = try std.fs.path.join(allocator, &.{ directory, "build.zig" }),
    };
    var search: std.ArrayList([]const u8) = .empty;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) break;
        if (!std.mem.startsWith(u8, arg, "-")) continue;
        if (try option(&result, arg)) continue;
        if (valueOption(arg)) {
            index += 1;
            if (index == args.len) return error.UnrecordedCompilerBuild;
            try value(&result, &search, allocator, arg, args[index]);
        } else if (!administrative(arg)) return error.UnrecordedCompilerBuild;
    }
    result.maker.search_prefixes = try search.toOwnedSlice(allocator);
    return result;
}

/// Scheduling options set how many steps Maker runs at once and how much
/// memory they may hold together. They change neither the graph nor any
/// compile's inputs, and admission chooses them from load, so the record
/// leaves them out wherever they stand: `-jN` and `--maxrss <bytes>`, both
/// before any `--`.
pub fn withoutScheduling(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var result: std.ArrayList([]const u8) = try .initCapacity(allocator, args.len);
    var index: usize = 0;
    var passthrough = false;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!passthrough and std.mem.eql(u8, arg, "--")) passthrough = true;
        if (!passthrough and index > 0) {
            if (std.mem.startsWith(u8, arg, "-j")) continue;
            if (std.mem.eql(u8, arg, "--maxrss")) {
                index += 1;
                continue;
            }
        }
        result.appendAssumeCapacity(arg);
    }
    return result.items;
}

fn option(result: *Parsed, arg: []const u8) !bool {
    if (std.mem.eql(u8, arg, "-fallow-so-scripts")) {
        result.maker.allow_so_scripts = true;
    } else if (std.mem.eql(u8, arg, "-fno-allow-so-scripts")) {
        result.maker.allow_so_scripts = false;
    } else if (std.mem.eql(u8, arg, "--build-id")) {
        result.maker.build_id = "fast";
    } else if (std.mem.cutPrefix(u8, arg, "--build-id=")) |text| {
        _ = try std.zig.BuildId.parse(text);
        if (std.mem.eql(u8, text, "uuid")) return error.UnrecordedCompilerBuild;
        result.maker.build_id = text;
    } else if (std.mem.eql(u8, arg, "--debug-rt")) {
        result.maker.debug_compiler_runtime_libs = "Debug";
    } else if (std.mem.cutPrefix(u8, arg, "--debug-rt=")) |text| {
        result.maker.debug_compiler_runtime_libs = text;
    } else if (std.mem.cutPrefix(u8, arg, "--zig-lib=")) |text| {
        result.maker.zig_lib_directory = text;
    } else if (std.mem.eql(u8, arg, "--cache-poison")) {
        result.maker.cache_poison = .poisoned;
    } else if (std.mem.cutPrefix(u8, arg, "--cache-poison=")) |text| {
        result.maker.cache_poison = std.meta.stringToEnum(std.Build.Graph.CachePoison, text) orelse
            return error.UnrecordedCompilerBuild;
    } else if (std.mem.eql(u8, arg, "-fincremental")) {
        result.maker.incremental = true;
    } else if (std.mem.eql(u8, arg, "-fno-incremental")) {
        result.maker.incremental = false;
    } else if (std.mem.eql(u8, arg, "-freference-trace")) {
        result.maker.reference_trace = 256;
    } else if (std.mem.cutPrefix(u8, arg, "-freference-trace=")) |text| {
        result.maker.reference_trace = try std.fmt.parseUnsigned(u32, text, 10);
    } else if (std.mem.eql(u8, arg, "-fno-reference-trace")) {
        result.maker.reference_trace = null;
    } else return false;
    return true;
}

fn valueOption(arg: []const u8) bool {
    const names = [_][]const u8{
        "--system",
        "--color",
        "--search-prefix",
        "--cache-dir",
        "--global-cache-dir",
        "--pkg-dir",
        "-p",
        "--prefix",
        "--build-file",
        "--prefix-lib-dir",
        "--prefix-exe-dir",
        "--prefix-include-dir",
        "--sysroot",
        "--test-timeout",
        "--libc",
        "--error-style",
        "--multiline-errors",
        "--summary",
        "--debounce",
        "--debug-target",
        "--debug-log",
        "--libc-runtimes",
        "--glibc-runtimes",
        "--error-limit",
    };
    for (names) |name| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}

fn value(
    result: *Parsed,
    search: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    arg: []const u8,
    text: []const u8,
) !void {
    if (std.mem.eql(u8, arg, "--build-file")) {
        result.build_file = text;
    } else if (std.mem.eql(u8, arg, "--sysroot")) {
        result.maker.sysroot = text;
    } else if (std.mem.eql(u8, arg, "--libc")) {
        result.maker.libc_file = text;
    } else if (std.mem.eql(u8, arg, "--search-prefix")) {
        if (search.items.len == invocation.record.maximum_paths) {
            return error.UnrecordedCompilerBuild;
        }
        try search.append(allocator, text);
    } else if (std.mem.eql(u8, arg, "--error-limit")) {
        result.maker.error_limit = try std.fmt.parseUnsigned(u32, text, 0);
    } else if (std.mem.eql(u8, arg, "--libc-runtimes") or
        std.mem.eql(u8, arg, "--glibc-runtimes"))
    {
        result.maker.libc_runtimes_directory = text;
    }
}

/// These arguments remain in the exact invocation. They affect graph selection,
/// diagnostics or execution; they do not hide additional compiler input paths.
fn administrative(arg: []const u8) bool {
    if (std.mem.cutPrefix(u8, arg, "--release=")) |mode| {
        return std.meta.stringToEnum(std.Build.ReleaseMode, mode) != null;
    }
    const prefixes = [_][]const u8{
        "-D",
        "--color=",
        "--seed=",
        "--fetch=",
        "--webui=",
        "--fuzz=",
    };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, arg, prefix)) return true;
    const names = [_][]const u8{
        "-h",
        "--help",
        "-l",
        "--list-steps",
        "--release",
        "--fetch",
        "--print-configuration",
        "--print-configuration-path",
        "--skip-oom-steps",
        "--verbose",
        "--webui",
        "--watch",
        "--time-report",
        "--fuzz",
        "--debug-compile-errors",
        "--debug-incremental",
        "--debug-pkg-config",
        "--verbose-air",
        "--verbose-cc",
        "--verbose-link",
        "--verbose-llvm-ir",
        "-fwine",
        "-fno-wine",
        "-fqemu",
        "-fno-qemu",
        "-fwasmtime",
        "-fno-wasmtime",
        "-frosetta",
        "-fno-rosetta",
        "-fdarling",
        "-fno-darling",
    };
    for (names) |name| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}
