const std = @import("std");
const manifest = @import("root.zig");

pub const maximum_modules = manifest.model.maximum_modules;
pub const maximum_imports = 512;
pub const maximum_graph_bytes = manifest.model.maximum_graph_bytes;
pub const import_name = "__tiny_compiled_inputs_v1";

pub const Snapshot = struct {
    bytes: []const u8,
    files: []const manifest.File,
    native_discovery: bool,
};

/// One configure's working state, shared by every unit it captures.
pub const Workspace = struct {
    walks: manifest.source.Walks,
    /// Each capture writes its graph here and returns a copy of the used part.
    graph: []u8,
    /// A capture runs inside a qualification, so each owns its descriptors.
    capture_runs: []manifest.source.Run,
    qualify_runs: []manifest.source.Run,
    /// Holds one unit's files while `source.merge` reorders them. Every merge
    /// copies its result back before it returns, so no file list aliases it.
    merge_files: []manifest.File,
    captured: manifest.source.Merged = .{},
    qualified: manifest.source.Merged = .{},

    pub fn init(arena: std.mem.Allocator, limits: manifest.source.Limits) !Workspace {
        std.debug.assert(limits.runs <= manifest.source.maximum_runs);
        return .{
            .walks = try .init(arena, limits),
            .graph = try arena.alloc(u8, maximum_graph_bytes),
            .capture_runs = try arena.alloc(manifest.source.Run, limits.runs),
            .qualify_runs = try arena.alloc(manifest.source.Run, limits.runs),
            .merge_files = try arena.alloc(manifest.File, manifest.model.maximum_entries),
        };
    }
};

const Capture = struct {
    inputs: manifest.paths.Inputs,
    plan: manifest.linked.Plan,
    native_discovery: bool = false,

    fn module(self: *Capture, json: *std.json.Stringify, value: *std.Build.Module, id: u32) !void {
        const b = self.inputs.build;
        const prefix = b.fmt("modules/{d}", .{id});
        if (value.link_libc == true or value.link_libcpp == true) self.native_discovery = true;
        try json.beginObject();
        try json.objectField("id");
        try json.write(id);
        try manifest.options.moduleValues(json, value);
        try json.objectField("root_source_file");
        if (value.root_source_file) |path| {
            const name = try self.inputs.module(path, b.pathJoin(&.{ prefix, "source" }));
            try json.write(.{ .input = name, .origin = try manifest.paths.origin(b, path) });
        } else try json.write(null);
        try self.imports(json, value);
        try manifest.native.module(json, &self.inputs, value, prefix, &self.plan);
        try json.endObject();
    }

    fn imports(self: *Capture, json: *std.json.Stringify, value: *std.Build.Module) !void {
        const names = value.import_table.keys();
        if (names.len > maximum_imports) return error.CompilerImportCountExceeded;
        const sorted = try self.inputs.build.graph.arena.dupe([]const u8, names);
        std.mem.sort([]const u8, sorted, {}, less);
        try json.objectField("imports");
        try json.beginArray();
        for (sorted) |name| {
            const imported = value.import_table.get(name).?;
            if (self.plan.derived(imported)) {
                try json.write(.{ .name = name, .derived = "compiled-input-manifest/v1" });
            } else try json.write(.{ .name = name, .module = self.plan.module_ids.get(imported).? });
        }
        try json.endArray();
    }
};

pub fn capture(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    excluded: []const *std.Build.Module,
    workspace: *Workspace,
) !Snapshot {
    return captureInner(b, compile, excluded, workspace) catch |err| switch (err) {
        error.WriteFailed => error.CompilerGraphTooLarge,
        else => err,
    };
}

fn captureInner(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    excluded: []const *std.Build.Module,
    workspace: *Workspace,
) !Snapshot {
    const plan = try manifest.linked.Plan.init(b, compile, excluded);
    var context = Capture{ .inputs = .{
        .build = b,
        .walks = &workspace.walks,
        .runs = .{ .storage = workspace.capture_runs },
        .references = plan.references,
    }, .plan = plan };
    std.debug.assert(workspace.graph.len == maximum_graph_bytes);
    var output = std.Io.Writer.fixed(workspace.graph);
    var json = std.json.Stringify{ .writer = &output };
    try json.beginObject();
    try json.objectField("schema");
    try json.write("tiny.compilation/v2");
    try json.objectField("root");
    try json.write(@as(u32, 0));
    try json.objectField("compiles");
    try json.beginArray();
    for (plan.compiles.items, 0..) |node, id| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(id);
        try json.objectField("root_module");
        try json.write(plan.module_ids.get(node.root_module).?);
        try json.objectField("compile");
        try json.beginObject();
        try manifest.options.compileValues(&json, node);
        try manifest.native.compile(&json, &context.inputs, node, b.fmt("compiles/{d}", .{id}));
        try json.endObject();
        try json.objectField("output");
        if (id == 0) {
            try json.write(null);
        } else {
            const name = b.fmt("compiles/{d}/output", .{id});
            try context.inputs.file(node.getEmittedBin(), name);
            try json.write(.{ .file = .{ .input = name, .origin = "generated" }, .path = @as(?[]const u8, null) });
        }
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("modules");
    try json.beginArray();
    for (plan.modules.items, 0..) |value, id| try context.module(&json, value, @intCast(id));
    try json.endArray();
    try json.endObject();
    manifest.source.merge(context.inputs.files.items, context.inputs.runs.items(), workspace.merge_files, &workspace.captured);
    // The next capture overwrites the workspace, so the snapshot owns a copy.
    const bytes = try b.graph.arena.dupe(u8, output.buffered());
    std.debug.assert(bytes.len == 0 or bytes.ptr != workspace.graph.ptr);
    return .{ .bytes = bytes, .files = context.inputs.files.items, .native_discovery = context.native_discovery };
}

fn less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
