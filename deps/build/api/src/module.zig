const std = @import("std");
const target = @import("target.zig");

pub const ModuleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    source_root: []const u8 = "",
    strip: ?bool = null,
    unwind_tables: ?std.builtin.UnwindTables = null,
    sanitize_thread: ?bool = null,
    red_zone: ?bool = null,
    error_tracing: ?bool = null,

    pub fn host(
        b: *std.Build,
        optimize: std.builtin.OptimizeMode,
        source_root: []const u8,
    ) ModuleOptions {
        return .{
            .target = b.graph.host,
            .optimize = optimize,
            .source_root = source_root,
            .strip = false,
        };
    }

    pub fn eql(left: ModuleOptions, right: ModuleOptions) bool {
        return target.eql(left.target, right.target) and
            left.optimize == right.optimize and
            std.mem.eql(u8, left.source_root, right.source_root) and
            (left.strip orelse false) == (right.strip orelse false) and
            left.unwind_tables == right.unwind_tables and
            (left.sanitize_thread orelse false) ==
                (right.sanitize_thread orelse false) and
            (left.red_zone orelse true) ==
                (right.red_zone orelse true) and
            left.error_tracing == right.error_tracing;
    }

    pub fn createOptions(
        options: ModuleOptions,
        b: *std.Build,
        sub_path: ?[]const u8,
        imports: []const std.Build.Module.Import,
    ) std.Build.Module.CreateOptions {
        return options.createOptionsWithRoot(
            if (sub_path) |path| sourcePath(b, options.source_root, path) else null,
            imports,
        );
    }

    pub fn createOptionsWithRoot(
        options: ModuleOptions,
        root_source_file: ?std.Build.LazyPath,
        imports: []const std.Build.Module.Import,
    ) std.Build.Module.CreateOptions {
        return .{
            .root_source_file = root_source_file,
            .target = options.target,
            .optimize = options.optimize,
            .strip = options.strip,
            .unwind_tables = options.unwind_tables,
            .sanitize_thread = options.sanitize_thread,
            .red_zone = options.red_zone,
            .error_tracing = options.error_tracing,
            .imports = imports,
        };
    }
};

pub fn sourcePath(
    b: *std.Build,
    source_root: []const u8,
    sub_path: []const u8,
) std.Build.LazyPath {
    return b.path(sourceRelativePath(b, source_root, sub_path));
}

pub fn sourceRelativePath(
    b: *std.Build,
    source_root: []const u8,
    sub_path: []const u8,
) []const u8 {
    if (source_root.len == 0) return sub_path;
    return b.pathJoin(&.{ source_root, sub_path });
}

pub fn registerModule(
    b: *std.Build,
    name: []const u8,
    module: *std.Build.Module,
) void {
    const entry = b.modules.getOrPutValue(
        b.graph.arena,
        b.dupe(name),
        module,
    ) catch @panic("OOM");
    if (entry.found_existing and entry.value_ptr.* != module) {
        std.debug.panic("module name '{s}' has multiple owners", .{name});
    }
}

pub fn requireImport(
    module: *std.Build.Module,
    name: []const u8,
    expected: *std.Build.Module,
) void {
    const actual = module.import_table.get(name) orelse
        std.debug.panic("module is missing required import '{s}'", .{name});
    if (actual != expected) {
        std.debug.panic(
            "module import '{s}' has duplicate owners: actual={s} ({d} options), expected={s} ({d} options)",
            .{
                name,
                actual.owner.dep_prefix,
                actual.owner.user_input_options.count(),
                expected.owner.dep_prefix,
                expected.owner.user_input_options.count(),
            },
        );
    }
}
