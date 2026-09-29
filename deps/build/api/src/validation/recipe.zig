const std = @import("std");
const build_api = @import("../root.zig");
const model = @import("../../validation/root.zig");

pub const Configuration = struct {
    recipe: model.Recipe,
    directory: []const u8,
    token: []const u8,
};

/// Reuse the suite root when it owns the protocol to avoid duplicate module ownership.
pub const Protocol = struct {
    module: *std.Build.Module,
    namespace: []const u8 = "",
};

pub const CatalogAlias = struct {
    owner: []const u8,
    directory: []const u8,
    step: []const u8,
    recipe: []const u8,
};

pub fn configure(b: *std.Build, recipes: []const model.Recipe) ?Configuration {
    const id = b.option([]const u8, "validation-recipe", "Package validation declaration");
    const directory = b.option([]const u8, "validation-dir", "Bound validation output directory");
    const token = b.option([]const u8, "validation-token", "Fresh validation execution identity");
    if (id == null and directory == null and token == null) return null;
    if (id == null or directory == null or token == null) @panic("incomplete validation request");
    if (!std.fs.path.isAbsolute(directory.?)) @panic("validation directory must be absolute");
    if (token.?.len == 0 or token.?.len > 128) @panic("invalid validation token");
    for (token.?) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') {
            @panic("invalid validation token");
        }
    }
    for (recipes) |recipe| {
        if (std.mem.eql(u8, recipe.id, id.?)) {
            return .{ .recipe = recipe, .directory = directory.?, .token = token.? };
        }
    }
    @panic("unknown package validation recipe");
}

pub fn bind(
    b: *std.Build,
    original: *std.Build.Module,
    configuration: Configuration,
    suite: model.Suite,
    protocol: Protocol,
) *std.Build.Module {
    const module = b.allocator.create(std.Build.Module) catch @panic("OOM");
    module.init(b, .{ .existing = original });
    module.import_table = original.import_table.clone(b.allocator) catch @panic("OOM");
    module.addImport("validation", if (protocol.module == original) module else protocol.module);
    const options = b.addOptions();
    options.addOption([]const u8, "model_namespace", protocol.namespace);
    options.addOption([]const u8, "recipe_id", configuration.recipe.id);
    options.addOption([]const u8, "recipe_sha256", &model.recipeDigest(configuration.recipe));
    options.addOption([]const u8, "class", configuration.recipe.class);
    options.addOption([]const u8, "suite_id", suite.id);
    options.addOption([]const u8, "backend", suite.backend);
    options.addOption([]const u8, "token", configuration.token);
    options.addOption([]const u8, "directory", configuration.directory);
    options.addOption([]const u8, "selection_artifact", suite.selection_artifact);
    options.addOption([]const u8, "result_artifact", suite.result_artifact);
    module.addOptions("validation_binding", options);
    return module;
}

/// Bound suites consume no input; do not inherit a closed launcher descriptor.
pub fn run(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    configuration: ?Configuration,
) *std.Build.Step.Run {
    const step = b.addRunArtifact(artifact);
    if (configuration) |bound| {
        step.has_side_effects = true;
        step.expectExitCode(0);
        step.setStdIn(.{ .bytes = "" });
        step.setEnvironmentVariable("TINY_TIMING_RUNNER_REPORT", "0");
        step.setCwd(b.graph.cwdRelativePath(bound.recipe.test_cwd));
    }
    return step;
}

pub fn catalog(
    b: *std.Build,
    module_options: build_api.ModuleOptions,
    recipes: []const model.Recipe,
    inputs: []const model.Source,
    roots: []const []const u8,
    owners: []const model.plan.Owner,
    validation: *std.Build.Module,
) *std.Build.Module {
    var output: std.Io.Writer.Allocating = .init(b.allocator);
    output.writer.writeAll(
        "const validation = @import(\"validation\");\n" ++
            "pub const values = [_]validation.Recipe{\n",
    ) catch @panic("OOM");
    for (recipes) |recipe| writeRecipe(&output.writer, recipe) catch @panic("OOM");
    output.writer.writeAll("};\n") catch @panic("OOM");
    writeOwners(&output.writer, owners) catch @panic("OOM");
    output.writer.writeAll("pub const source_roots = [_][]const u8{\n") catch @panic("OOM");
    for (roots) |path| {
        output.writer.print("\"{f}\",\n", .{std.zig.fmtString(path)}) catch @panic("OOM");
    }
    output.writer.writeAll("};\n") catch @panic("OOM");
    output.writer.writeAll("pub const sources = [_]validation.Source{\n") catch @panic("OOM");
    for (inputs) |input| {
        output.writer.writeAll(".{") catch @panic("OOM");
        writeField(&output.writer, "path", input.path) catch @panic("OOM");
        writeField(&output.writer, "sha256", input.sha256) catch @panic("OOM");
        output.writer.writeAll("},\n") catch @panic("OOM");
    }
    output.writer.writeAll("};\n") catch @panic("OOM");
    return b.createModule(module_options.createOptionsWithRoot(
        b.addWriteFiles().add("validation-recipes.zig", output.written()),
        &.{.{ .name = "validation", .module = validation }},
    ));
}

fn writeOwners(writer: *std.Io.Writer, owners: []const model.plan.Owner) !void {
    try writer.writeAll("pub const owners = [_]validation.plan.Owner{\n");
    for (owners) |owner| {
        try writer.writeAll(".{\n");
        try writeField(writer, "path", owner.path);
        try writeList(writer, "dependencies", owner.dependencies);
        try writeList(writer, "recipes", owner.recipes);
        if (owner.declarations.len != 0) try writeList(writer, "declarations", owner.declarations);
        try writer.writeAll("},\n");
    }
    try writer.writeAll("};\n");
}

fn writeList(writer: *std.Io.Writer, name: []const u8, values: []const []const u8) !void {
    try writer.print(".{s} = &.{{", .{name});
    for (values) |value| try writer.print("\"{f}\",", .{std.zig.fmtString(value)});
    try writer.writeAll("},\n");
}

pub fn catalogJson(
    b: *std.Build,
    module_options: build_api.ModuleOptions,
    recipes: []const model.Recipe,
    aliases: []const CatalogAlias,
) *std.Build.Module {
    var output: std.Io.Writer.Allocating = .init(b.allocator);
    output.writer.writeAll(
        "const Entry = struct { owner: []const u8, directory: []const u8, " ++
            "step: []const u8, json: []const u8 };\n" ++
            "pub const values = [_]Entry{\n",
    ) catch @panic("OOM");
    for (recipes) |recipe| {
        const json = std.json.Stringify.valueAlloc(
            b.allocator,
            recipe,
            .{},
        ) catch @panic("OOM");
        output.writer.writeAll(".{\n") catch @panic("OOM");
        writeField(&output.writer, "owner", recipe.owner) catch @panic("OOM");
        writeField(&output.writer, "directory", recipe.directory) catch @panic("OOM");
        writeField(&output.writer, "step", recipe.step) catch @panic("OOM");
        writeField(&output.writer, "json", json) catch @panic("OOM");
        output.writer.writeAll("},\n") catch @panic("OOM");
    }
    for (aliases, 0..) |alias, index| {
        for (recipes) |original| {
            if (std.mem.eql(u8, original.owner, alias.owner) and
                std.mem.eql(u8, original.directory, alias.directory) and
                std.mem.eql(u8, original.step, alias.step)) @panic("validation alias shadows a recipe");
        }
        for (aliases[0..index]) |prior| {
            if (std.mem.eql(u8, prior.owner, alias.owner) and
                std.mem.eql(u8, prior.directory, alias.directory) and
                std.mem.eql(u8, prior.step, alias.step)) @panic("duplicate validation alias");
        }
        const recipe = for (recipes) |candidate| {
            if (std.mem.eql(u8, candidate.id, alias.recipe)) break candidate;
        } else @panic("unknown validation alias recipe");
        const json = std.json.Stringify.valueAlloc(
            b.allocator,
            recipe,
            .{},
        ) catch @panic("OOM");
        output.writer.writeAll(".{\n") catch @panic("OOM");
        writeField(&output.writer, "owner", alias.owner) catch @panic("OOM");
        writeField(&output.writer, "directory", alias.directory) catch @panic("OOM");
        writeField(&output.writer, "step", alias.step) catch @panic("OOM");
        writeField(&output.writer, "json", json) catch @panic("OOM");
        output.writer.writeAll("},\n") catch @panic("OOM");
    }
    output.writer.writeAll("};\n") catch @panic("OOM");
    return b.createModule(module_options.createOptionsWithRoot(
        b.addWriteFiles().add("validation-catalog.zig", output.written()),
        &.{},
    ));
}

fn writeRecipe(writer: *std.Io.Writer, recipe: model.Recipe) !void {
    try writer.writeAll(".{\n");
    inline for (.{
        "schema",
        "id",
        "owner",
        "directory",
        "step",
        "class",
        "optimize",
        "target",
        "selection",
        "source",
        "test_cwd",
        "declaration",
        "declaration_sha256",
        "framework_sha256",
    }) |field| try writeField(writer, field, @field(recipe, field));
    inline for (.{ "argv", "runtime" }) |field| {
        try writer.print(".{s} = &.{{", .{field});
        for (@field(recipe, field)) |value| {
            try writer.print("\"{f}\",", .{std.zig.fmtString(value)});
        }
        try writer.writeAll("},\n");
    }
    try writer.writeAll(".environment = &.{\n");
    for (recipe.environment) |pair| {
        try writer.writeAll(".{");
        try writeField(writer, "name", pair.name);
        try writeField(writer, "value", pair.value);
        try writer.writeAll("},\n");
    }
    try writer.writeAll("},\n.suites = &.{\n");
    for (recipe.suites) |suite| {
        try writer.writeAll(".{");
        inline for (comptime std.meta.fieldNames(model.Suite)) |field| {
            try writeField(writer, field, @field(suite, field));
        }
        try writer.writeAll("},\n");
    }
    try writer.writeAll("},\n},\n");
}

fn writeField(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.print(".{s} = \"{f}\",\n", .{ name, std.zig.fmtString(value) });
}
