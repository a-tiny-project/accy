const std = @import("std");
const manifest = @import("root.zig");

const maximum_references = manifest.linked.maximum_references;

pub fn module(
    json: *std.json.Stringify,
    inputs: *manifest.paths.Inputs,
    value: *const std.Build.Module,
    prefix: []const u8,
    plan: *const manifest.linked.Plan,
) !void {
    try json.objectField("include_dirs");
    try json.beginArray();
    if (value.include_dirs.items.len > maximum_references) return error.CompilerInputCountExceeded;
    for (value.include_dirs.items, 0..) |item, index| {
        const name = inputs.build.fmt("{s}/include/{d}", .{ prefix, index });
        try json.beginObject();
        try json.objectField(@tagName(item));
        switch (item) {
            .path,
            .path_system,
            .path_after,
            .framework_path,
            .framework_path_system,
            .embed_path,
            => |path| try directory(json, inputs, path, name),
            .config_header_step => |step| try file(json, inputs, step.getOutputFile(), name),
            .other_step => |child| {
                const id = plan.compile_ids.get(child) orelse return error.UnqualifiedCompilerIncludeTree;
                if (child.installed_headers.items.len != 0) return error.UnqualifiedCompilerIncludeTree;
                try inputs.reference();
                try json.write(.{ .compile = id, .headers = "empty" });
            },
        }
        try json.endObject();
    }
    try json.endArray();
    try directories(json, inputs, "lib_paths", value.lib_paths.items, prefix);
    try rpaths(json, inputs, value.rpaths.items, prefix);
    try frameworks(json, value);
    try objects(json, inputs, value, prefix, plan);
}

pub fn compile(
    json: *std.json.Stringify,
    inputs: *manifest.paths.Inputs,
    value: *const std.Build.Step.Compile,
    prefix: []const u8,
) !void {
    inline for (.{
        "linker_script",           "version_script", "zig_lib_dir",  "win32_manifest",
        "win32_module_definition", "libc_file",      "entitlements",
    }) |field| {
        try json.objectField(field);
        if (@field(value, field)) |path| {
            const name = inputs.build.fmt("{s}/{s}", .{ prefix, field });
            if (comptime std.mem.eql(u8, field, "zig_lib_dir")) {
                try directory(json, inputs, path, name);
            } else try file(json, inputs, path, name);
        } else try json.write(null);
    }
    try json.objectField("test_runner");
    if (value.test_runner) |runner| {
        try json.beginObject();
        try json.objectField("mode");
        try json.write(runner.mode);
        try json.objectField("path");
        try file(json, inputs, runner.path, inputs.build.fmt("{s}/test_runner.zig", .{prefix}));
        try json.endObject();
    } else try json.write(null);
    try json.objectField("installed_headers");
    try json.beginArray();
    if (value.installed_headers.items.len > maximum_references) {
        return error.CompilerInputCountExceeded;
    }
    for (value.installed_headers.items, 0..) |header, index| {
        const name = inputs.build.fmt("{s}/headers/{d}", .{ prefix, index });
        try json.beginObject();
        try json.objectField(@tagName(header));
        switch (header) {
            .file => |item| {
                try file(json, inputs, item.source, name);
                try json.objectField("destination");
                try json.write(item.dest_rel_path);
            },
            .directory => |item| {
                try directory(json, inputs, item.source, name);
                try json.objectField("destination");
                try json.write(item.dest_rel_path);
                try json.objectField("options");
                try json.write(item.options);
            },
        }
        try json.endObject();
    }
    try json.endArray();
}

fn file(
    json: *std.json.Stringify,
    inputs: *manifest.paths.Inputs,
    path: std.Build.LazyPath,
    name: []const u8,
) !void {
    try inputs.file(path, name);
    try json.write(.{ .input = name, .origin = try manifest.paths.origin(inputs.build, path) });
}

fn directory(
    json: *std.json.Stringify,
    inputs: *manifest.paths.Inputs,
    path: std.Build.LazyPath,
    name: []const u8,
) !void {
    try inputs.directory(path, name);
    try json.write(.{ .input = name, .origin = try manifest.paths.origin(inputs.build, path) });
}

fn directories(
    json: *std.json.Stringify,
    inputs: *manifest.paths.Inputs,
    field: []const u8,
    paths: []const std.Build.LazyPath,
    prefix: []const u8,
) !void {
    if (paths.len > maximum_references) return error.CompilerInputCountExceeded;
    try json.objectField(field);
    try json.beginArray();
    for (paths, 0..) |path, index| {
        const name = inputs.build.fmt("{s}/{s}/{d}", .{ prefix, field, index });
        try directory(json, inputs, path, name);
    }
    try json.endArray();
}

fn rpaths(
    json: *std.json.Stringify,
    inputs: *manifest.paths.Inputs,
    paths: []const std.Build.Module.RPath,
    prefix: []const u8,
) !void {
    if (paths.len > maximum_references) return error.CompilerInputCountExceeded;
    try json.objectField("rpaths");
    try json.beginArray();
    for (paths, 0..) |path, index| {
        try json.beginObject();
        try json.objectField(@tagName(path));
        switch (path) {
            .special => |value| try json.write(value),
            .lazy_path => |value| {
                const name = inputs.build.fmt("{s}/rpath/{d}", .{ prefix, index });
                try directory(json, inputs, value, name);
            },
        }
        try json.endObject();
    }
    try json.endArray();
}

fn frameworks(
    json: *std.json.Stringify,
    value: *const std.Build.Module,
) !void {
    try json.objectField("frameworks");
    try json.beginArray();
    if (value.frameworks.count() != 0) return error.UnqualifiedCompilerFramework;
    try json.endArray();
}

fn objects(
    json: *std.json.Stringify,
    inputs: *manifest.paths.Inputs,
    module_value: *const std.Build.Module,
    prefix: []const u8,
    plan: *const manifest.linked.Plan,
) !void {
    const values = module_value.link_objects.items;
    if (values.len > maximum_references) return error.CompilerInputCountExceeded;
    try json.objectField("link_objects");
    try json.beginArray();
    for (values, 0..) |object, index| {
        const name = inputs.build.fmt("{s}/link/{d}", .{ prefix, index });
        try json.beginObject();
        try json.objectField(@tagName(object));
        switch (object) {
            .static_path => |path| try file(json, inputs, path, name),
            .assembly_file => |path| {
                const target = module_value.resolved_target orelse return error.UnqualifiedCompilerAssemblyTarget;
                if (target.result.os.tag != .linux or (target.result.cpu.arch != .x86_64 and target.result.cpu.arch != .aarch64)) return error.UnqualifiedCompilerAssemblyTarget;
                const source = inputs.build.fmt("{s}/source", .{name});
                try inputs.assembly(path, source, target.result.cpu.arch);
                try json.write(.{ .file = .{ .input = source, .origin = try manifest.paths.origin(inputs.build, path) }, .policy = "linux-standalone-assembly/v1" });
            },
            .other_step => |child| try json.write(.{ .compile = plan.compile_ids.get(child).? }),
            .system_lib => return error.UnqualifiedCompilerSystemLibrary,
            .c_source_file, .c_source_files => return error.UnqualifiedCompilerCInputs,
            .win32_resource_file => return error.UnqualifiedCompilerResource,
        }
        try json.endObject();
    }
    try json.endArray();
}
