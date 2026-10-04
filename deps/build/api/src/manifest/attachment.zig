const std = @import("std");
const manifest = @import("root.zig");
const invocation = @import("../invocation/root.zig");

const maximum_compilers = 4096;
const unavailable_source =
    "pub const qualified = false;\n" ++
    "pub const refusal = \"UnrecordedCompilerBuild\";\n" ++
    "pub const bytes: []const u8 = &.{};\n";

pub const Inputs = struct {
    manifest: manifest.Manifest,
    invocation: std.Build.LazyPath,
    compilation: std.Build.LazyPath,
};

/// Install the derived-input marker before any caller caches the module graph.
/// The root lifecycle fills it after all compiler and module owners have run.
pub fn attach(b: *std.Build, module: *std.Build.Module) void {
    std.debug.assert(!module.import_table.contains(manifest.graph.import_name));
    const marker = b.createModule(.{});
    registerMarker(b, marker);
    module.addImport(manifest.graph.import_name, marker);
}

fn registerMarker(b: *std.Build, marker: *std.Build.Module) void {
    const source = b.addWriteFiles().add("compiler.zig", unavailable_source);
    marker.root_source_file = source;
    b.modules.put(b.graph.arena, b.fmt("tiny-derived-compiler-marker/v1/{d}", .{@backingInt(source.generated.index)}), marker) catch @panic("OOM");
}

/// The registered Module pointer identifies the derived marker, rather than
/// its import name, pathname, or bytes. Every isolated copy is registered before
/// any snapshot; derived source publication happens after all captures.
pub fn isMarker(module: *std.Build.Module) bool {
    const source = module.root_source_file orelse return false;
    if (source != .generated) return false;
    const graph = module.owner.graph;
    const owner = graph.generated_files.items[@backingInt(source.generated.index)].owner;
    const key = owner.fmt("tiny-derived-compiler-marker/v1/{d}", .{@backingInt(source.generated.index)});
    return (owner.modules.get(key) orelse return false) == module;
}

pub fn finalize(b: *std.Build) !void {
    if (!b.isRoot()) return;
    const compilers = collectCompilers(b) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return;
    };
    var selected_count: usize = 0;
    for (compilers) |compile| {
        if (manifest.binding.registration.find(compile) != null) selected_count += 1;
    }
    if (selected_count > manifest.binding.model.maximum_bindings) return error.CompilerBindingCountExceeded;
    const record = try invocation.configuration.observe(b) orelse {
        for (compilers) |compile| manifest.binding.registration.refuse(compile, "UnrecordedCompilerBuild");
        return;
    };
    const generator = manifest.Generator.init(b);
    const toolchain = generator.toolchain();
    const Pending = struct {
        compile: *std.Build.Step.Compile,
        markers: []const *std.Build.Module,
        inputs: ?Inputs = null,
        refusal: ?[]const u8 = null,
    };
    var pending: std.ArrayList(Pending) = .empty;
    for (compilers) |compile| {
        const markers = isolate(b, compile, manifest.binding.registration.find(compile) != null) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            manifest.binding.registration.refuse(compile, @errorName(err));
            continue;
        };
        if (markers.len == 0) continue;
        try pending.append(b.graph.arena, .{ .compile = compile, .markers = markers });
    }
    for (pending.items) |*item| {
        item.inputs = qualify(b, generator, toolchain, record, item.compile, item.markers) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            item.refusal = @errorName(err);
            continue;
        };
    }
    for (pending.items) |item| {
        if (item.inputs) |inputs| {
            for (item.markers) |marker| marker.root_source_file = inputs.manifest.source;
            manifest.binding.registration.qualify(item.compile, inputs);
        } else {
            const reason = item.refusal.?;
            manifest.binding.registration.refuse(item.compile, reason);
            const text = try std.fmt.allocPrint(b.graph.arena, "pub const qualified = false;\npub const refusal = \"{s}\";\n" ++
                "pub const bytes: []const u8 = &.{{}};\n", .{reason});
            const source = b.addWriteFiles().add("compiler.zig", text);
            for (item.markers) |marker| marker.root_source_file = source;
        }
    }
}

fn qualify(
    b: *std.Build,
    generator: manifest.Generator,
    toolchain: manifest.Manifest,
    record: invocation.Record,
    compile: *std.Build.Step.Compile,
    markers: []const *std.Build.Module,
) !Inputs {
    var inputs = manifest.paths.Inputs{ .build = b };
    const invocation_bytes = try std.json.Stringify.valueAlloc(b.graph.arena, record, .{});
    const invocation_path = b.addWriteFiles().add("invocation.json", invocation_bytes);
    try inputs.file(invocation_path, "invocation.json");
    try manifest.foreign.capture(&inputs, record);
    const snapshot = try manifest.graph.capture(b, compile, markers);
    if (snapshot.native_discovery) return error.UnqualifiedCompilerNativeDiscovery;
    const prefix = "compilations/0";
    for (snapshot.files) |file| {
        var scoped = file;
        scoped.identity.path = b.pathJoin(&.{ prefix, file.identity.path });
        try manifest.source.append(b, &inputs.files, scoped);
    }
    manifest.source.sort(inputs.files.items);
    const captured = generator.captureCompilation(inputs.files.items, toolchain, snapshot.bytes);
    return .{ .manifest = captured, .invocation = invocation_path, .compilation = captured.compilation.? };
}

/// The compiler owns its derived marker. Module aliases remain shared within
/// that compiler, while unrelated artifacts receive independent module graphs.
pub fn isolate(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    require_marker: bool,
) ![]const *std.Build.Module {
    const allocator = b.graph.arena;
    var modules: std.AutoArrayHashMapUnmanaged(*std.Build.Module, *std.Build.Module) = .empty;
    try modules.put(allocator, compile.root_module, undefined);
    var has_marker = false;
    var cursor: usize = 0;
    while (cursor < modules.count()) : (cursor += 1) {
        const module = modules.keys()[cursor];
        if (module.import_table.count() > manifest.graph.maximum_imports) {
            return error.CompilerImportCountExceeded;
        }
        for (module.import_table.values()) |imported| {
            has_marker = has_marker or isMarker(imported);
            if (modules.contains(imported)) continue;
            if (modules.count() == manifest.graph.maximum_modules) {
                return error.CompilerModuleCountExceeded;
            }
            try modules.put(allocator, imported, undefined);
        }
    }
    if (!has_marker and !require_marker) return &.{};
    if (!has_marker and compile.root_module.import_table.contains(manifest.graph.import_name)) return error.CompilerBindingMarkerNameConflict;
    for (modules.keys(), modules.values()) |original, *replacement| {
        const copied = try allocator.create(std.Build.Module);
        copied.* = original.*;
        copied.import_table = .empty;
        copied.cached_graph = .{ .modules = &.{}, .names = &.{} };
        if (isMarker(original)) registerMarker(b, copied);
        replacement.* = copied;
    }
    var markers: std.ArrayList(*std.Build.Module) = .empty;
    for (modules.keys(), modules.values()) |original, copied| {
        for (original.import_table.keys(), original.import_table.values()) |name, imported| {
            const replacement = modules.get(imported).?;
            copied.addImport(name, replacement);
            if (isMarker(imported)) {
                const present = for (markers.items) |marker| {
                    if (marker == replacement) break true;
                } else false;
                if (!present) try markers.append(allocator, replacement);
            }
        }
    }
    compile.root_module = modules.get(compile.root_module).?;
    if (!has_marker) {
        attach(b, compile.root_module);
        try markers.append(allocator, compile.root_module.import_table.get(manifest.graph.import_name).?);
    }
    return markers.items;
}

fn collectCompilers(b: *std.Build) ![]*std.Build.Step.Compile {
    var pending: std.ArrayList(*std.Build.Step) = .empty;
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    var result: std.ArrayList(*std.Build.Step.Compile) = .empty;
    for (b.top_level_steps.values()) |top| try pending.append(b.graph.arena, &top.step);
    while (pending.pop()) |step| {
        const entry = try seen.getOrPut(b.graph.arena, step);
        if (entry.found_existing) continue;
        if (step.cast(std.Build.Step.Compile)) |compile| {
            if (result.items.len == maximum_compilers) return error.CompilerCountExceeded;
            try result.append(b.graph.arena, compile);
            const modules = compile.root_module.getGraph().modules;
            if (modules.len > manifest.graph.maximum_modules) return error.CompilerModuleCountExceeded;
            for (modules) |module| {
                if (module.link_objects.items.len > manifest.linked.maximum_references) return error.CompilerReferenceCountExceeded;
                for (module.link_objects.items) |object| {
                    if (object == .other_step) try pending.append(b.graph.arena, &object.other_step.step);
                }
            }
        }
        try pending.appendSlice(b.graph.arena, step.dependencies.items);
    }
    std.mem.sort(*std.Build.Step.Compile, result.items, {}, struct {
        fn less(_: void, a: *std.Build.Step.Compile, c: *std.Build.Step.Compile) bool {
            return std.mem.lessThan(u8, a.step.name, c.step.name);
        }
    }.less);
    return result.toOwnedSlice(b.graph.arena);
}
