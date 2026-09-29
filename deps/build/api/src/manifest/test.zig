const std = @import("std");
const model = @import("model.zig");
const fixture = @import("compiled_inputs_fixture");

test {
    std.testing.refAllDecls(model);
    std.testing.refAllDecls(@import("assembly.zig"));
    std.testing.refAllDecls(@import("emit.zig"));
}

test "compiler manifest generator records sources options and the entire pinned toolchain" {
    const allocator = std.testing.allocator;
    const entries = try model.decode(allocator, fixture.bytes);
    defer allocator.free(entries);
    try std.testing.expectEqual(fixture.input_count, entries.len);
    var total: u64 = 0;
    var executable = false;
    var library_files: u32 = 0;
    var source = false;
    var options = false;
    for (entries) |entry| {
        total += entry.byte_length;
        if (std.mem.eql(u8, entry.path, "toolchain/zig")) {
            try std.testing.expect(entry.byte_length > 0);
            try std.testing.expect(entry.pinned_source.len > 0);
            executable = true;
        } else if (std.mem.startsWith(u8, entry.path, "toolchain/lib/")) {
            try std.testing.expect(entry.pinned_source.len > 0);
            library_files += 1;
        } else if (std.mem.eql(u8, entry.path, "fixture/source/value.txt")) {
            const expected = try model.entry("fixture/source/value.txt", "", "source directory\n");
            try std.testing.expectEqual(expected.byte_length, entry.byte_length);
            try std.testing.expectEqualSlices(u8, &expected.sha256, &entry.sha256);
            source = true;
        } else if (std.mem.eql(u8, entry.path, "fixture/options.zig")) {
            const expected = try model.entry(
                "fixture/options.zig",
                "",
                "pub const enabled: bool = false;\n",
            );
            try std.testing.expectEqual(expected.byte_length, entry.byte_length);
            try std.testing.expectEqualSlices(u8, &expected.sha256, &entry.sha256);
            options = true;
        } else return error.UnexpectedCompilerInput;
    }
    try std.testing.expect(executable);
    try std.testing.expect(library_files > 1);
    try std.testing.expect(source);
    try std.testing.expect(options);
    try std.testing.expectEqual(fixture.foreign_bytes, total);
}

test "compiler manifest graph captures import edges generated settings and compiler options" {
    const compiled = @import("compiled_graph_fixture");
    const record = @import("compiled_graph_record");
    const allocator = std.testing.allocator;
    const entries = try model.decode(allocator, compiled.bytes);
    defer allocator.free(entries);
    var settings = false;
    var source = false;
    var generated = false;
    var graph = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, "modules/2/source/options.zig")) {
            const expected = try model.entry(entry.path, "", "pub const enabled: bool = false;\n");
            try std.testing.expectEqualSlices(u8, &expected.sha256, &entry.sha256);
            settings = true;
        } else if (std.mem.eql(u8, entry.path, "modules/0/source/main.zig")) {
            try std.testing.expect(entry.byte_length > 0);
            source = true;
        } else if (std.mem.eql(u8, entry.path, "modules/1/source/value.txt")) {
            const expected = try model.entry(entry.path, "", "generated compiler input\n");
            try std.testing.expectEqualSlices(u8, &expected.sha256, &entry.sha256);
            generated = true;
        } else if (std.mem.eql(u8, entry.path, "compilation.json")) {
            const expected = try model.entry(entry.path, "", record.graph);
            try std.testing.expectEqualSlices(u8, &expected.sha256, &entry.sha256);
            graph = true;
        }
    }
    try std.testing.expect(settings);
    try std.testing.expect(source);
    try std.testing.expect(graph);
    try std.testing.expect(generated);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, record.graph, .{});
    defer parsed.deinit();
    const modules = parsed.value.object.get("modules").?.array.items;
    try std.testing.expectEqual(3, modules.len);
    try std.testing.expectEqualStrings("debug", modules[0].object.get("optimize").?.string);
    const imports = modules[0].object.get("imports").?.array.items;
    try std.testing.expectEqualStrings("constants", imports[0].object.get("name").?.string);
    try std.testing.expectEqual(1, imports[0].object.get("module").?.integer);
    try std.testing.expectEqualStrings("settings", imports[1].object.get("name").?.string);
    try std.testing.expectEqual(2, imports[1].object.get("module").?.integer);
    const compile = parsed.value.object.get("compiles").?.array.items[0].object.get("compile").?.object;
    try std.testing.expect(!compile.get("use_llvm").?.bool);
}

const manifest = @import("root.zig");

fn bindingGraph(allocator: std.mem.Allocator) !*std.Build {
    const graph = try allocator.create(std.Build.Graph);
    graph.* = .{
        .io = std.testing.io,
        .arena = allocator,
        .zig_exe = "zig",
        .environ_map = .init(allocator),
        .host = .{ .query = .{}, .result = @import("builtin").target },
        .generated_files = .empty,
        .wip_configuration = .init(allocator),
    };
    return std.Build.create(graph, .cwd(), &.{});
}

fn bindingModule(b: *std.Build) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(u32, "value", 17);
    return b.createModule(.{ .root_source_file = options.getOutput(), .target = b.graph.host, .optimize = .debug });
}

fn bindingObject(b: *std.Build, name: []const u8) *std.Build.Step.Compile {
    const root = bindingModule(b);
    root.optimize = .fast;
    return b.addObject(.{ .name = name, .root_module = root, .use_llvm = true });
}

fn bindingRoot(b: *std.Build) *std.Build.Step.Compile {
    return b.addExecutable(.{ .name = "parent", .root_module = bindingModule(b), .use_llvm = false });
}

test "compiler binding linked DAG preserves slots shared producers distinct names and mixed options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try bindingGraph(arena.allocator());
    const root = bindingRoot(b);
    const first = bindingObject(b, "same");
    const second = bindingObject(b, "same");
    const leaf = bindingObject(b, "leaf");
    root.root_module.addObject(first);
    root.root_module.addObject(second);
    root.root_module.addObject(first);
    first.root_module.addObject(leaf);
    second.root_module.addObject(leaf);
    const snapshot = try manifest.graph.capture(b, root, &.{});
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), snapshot.bytes, .{});
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("tiny.compilation/v2", object.get("schema").?.string);
    const nodes = object.get("compiles").?.array.items;
    const modules = object.get("modules").?.array.items;
    try std.testing.expectEqual(4, nodes.len);
    try std.testing.expectEqual(4, modules.len);
    try std.testing.expect(nodes[0].object.get("output").? == .null);
    try std.testing.expectEqualStrings("debug", modules[0].object.get("optimize").?.string);
    try std.testing.expectEqualStrings("fast", modules[1].object.get("optimize").?.string);
    try std.testing.expect(!nodes[0].object.get("compile").?.object.get("use_llvm").?.bool);
    try std.testing.expect(nodes[1].object.get("compile").?.object.get("use_llvm").?.bool);
    const links = modules[0].object.get("link_objects").?.array.items;
    for ([_]i64{ 1, 2, 1 }, links) |id, link| try std.testing.expectEqual(id, link.object.get("other_step").?.object.get("compile").?.integer);
    try std.testing.expectEqualStrings("compiles/3/output", nodes[3].object.get("output").?.object.get("file").?.object.get("input").?.string);
    root.root_module.optimize = .safe;
    const changed = try manifest.graph.capture(b, root, &.{});
    try std.testing.expect(!std.mem.eql(u8, snapshot.bytes, changed.bytes));
    const sources = root.step.dependencies.items.len;
    leaf.root_module.addObject(first);
    try std.testing.expectError(error.CompilerLinkedCycle, manifest.graph.capture(b, root, &.{}));
    try std.testing.expectEqual(sources, root.step.dependencies.items.len);
}

test "compiler binding linked rejects foreign wrong kind and native acquisition in children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try bindingGraph(arena.allocator());
    const root = bindingRoot(b);
    const child = bindingObject(b, "child");
    root.root_module.addObject(child);
    child.root_module.link_libc = true;
    try std.testing.expect((try manifest.graph.capture(b, root, &.{})).native_discovery);
    child.root_module.link_libc = false;
    child.root_module.linkSystemLibrary("fixture_unqualified_library", .{});
    try std.testing.expectError(error.UnqualifiedCompilerSystemLibrary, manifest.graph.capture(b, root, &.{}));
    child.root_module.link_objects.clearRetainingCapacity();
    child.kind = .lib;
    try std.testing.expectError(error.UnqualifiedCompilerLinkedArtifact, manifest.graph.capture(b, root, &.{}));
    child.kind = .obj;
    child.use_llvm = null;
    try std.testing.expectError(error.UnqualifiedCompilerLinkedArtifact, manifest.graph.capture(b, root, &.{}));
    child.use_llvm = true;
    const other = try bindingGraph(arena.allocator());
    child.step.owner = other;
    try std.testing.expectError(error.ForeignCompilerLinkedArtifact, manifest.graph.capture(b, root, &.{}));
}

fn markerOrder(allocator: std.mem.Allocator, reverse: bool) !manifest.graph.Snapshot {
    const b = try bindingGraph(allocator);
    const root = bindingRoot(b);
    const child = bindingObject(b, "child");
    const unmarked = bindingObject(b, "unmarked");
    root.root_module.addObject(child);
    child.root_module.addObject(unmarked);
    const original_unmarked = unmarked.root_module;
    manifest.attachment.attach(b, child.root_module);
    const order = if (reverse) [_]*std.Build.Step.Compile{ child, root } else [_]*std.Build.Step.Compile{ root, child };
    for (order) |compile| _ = try manifest.attachment.isolate(b, compile, compile == root);
    try std.testing.expect(unmarked.root_module == original_unmarked);
    try std.testing.expectEqual(0, unmarked.root_module.import_table.count());
    const snapshot = try manifest.graph.capture(b, root, &.{});
    try std.testing.expectEqual(3, (try manifest.linked.Plan.init(b, root, &.{})).modules.items.len);
    return snapshot;
}

test "compiler binding linked capture follows complete isolation independent of marker enumeration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try markerOrder(arena.allocator(), false);
    const b = try markerOrder(arena.allocator(), true);
    try std.testing.expectEqualSlices(u8, a.bytes, b.bytes);
    const owner = try bindingGraph(arena.allocator());
    const root = bindingRoot(owner);
    const ordinary = bindingModule(owner);
    root.root_module.addImport(manifest.graph.import_name, ordinary);
    const plan = try manifest.linked.Plan.init(owner, root, &.{});
    try std.testing.expectEqual(2, plan.modules.items.len);
    try std.testing.expect(!plan.derived(ordinary));
    const attached = bindingRoot(owner);
    manifest.attachment.attach(owner, attached.root_module);
    const actual_marker = attached.root_module.import_table.get(manifest.graph.import_name).?;
    const same_source = owner.createModule(.{ .root_source_file = actual_marker.root_source_file });
    try std.testing.expect(manifest.attachment.isMarker(actual_marker));
    try std.testing.expect(!manifest.attachment.isMarker(same_source));
    try std.testing.expectError(error.CompilerBindingMarkerNameConflict, manifest.attachment.isolate(owner, root, true));
}

test "compiler binding linked exact node depth module and repeated-reference bounds refuse next member" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try bindingGraph(arena.allocator());
    const root = bindingObject(b, "root");
    var tail = root;
    for (1..manifest.linked.maximum_compiles) |_| {
        const next = bindingObject(b, "same");
        tail.root_module.addObject(next);
        tail = next;
    }
    const exact = try manifest.linked.Plan.init(b, root, &.{});
    try std.testing.expectEqual(64, exact.compiles.items.len);
    tail.root_module.addObject(root);
    try std.testing.expectError(error.CompilerLinkedCycle, manifest.linked.Plan.init(b, root, &.{}));
    tail.root_module.link_objects.clearRetainingCapacity();
    tail.root_module.addObject(bindingObject(b, "next"));
    try std.testing.expectError(error.CompilerLinkedCountExceeded, manifest.linked.Plan.init(b, root, &.{}));
    const modules_root = bindingRoot(b);
    const modules_child = bindingObject(b, "module-child");
    modules_root.root_module.addObject(modules_child);
    var prior = modules_root.root_module;
    for (1..manifest.graph.maximum_modules / 2) |_| {
        const next = bindingModule(b);
        prior.addImport("next", next);
        prior = next;
    }
    prior = modules_child.root_module;
    for (1..manifest.graph.maximum_modules / 2) |_| {
        const next = bindingModule(b);
        prior.addImport("next", next);
        prior = next;
    }
    try std.testing.expectEqual(512, (try manifest.linked.Plan.init(b, modules_root, &.{})).modules.items.len);
    prior.addImport("next", bindingModule(b));
    try std.testing.expectError(error.CompilerModuleCountExceeded, manifest.linked.Plan.init(b, modules_root, &.{}));
    const references = bindingRoot(b);
    const shared = bindingObject(b, "shared");
    for (0..manifest.linked.maximum_references) |_| references.root_module.link_objects.append(b.allocator, .{ .other_step = shared }) catch @panic("OOM");
    try std.testing.expectEqual(4096, (try manifest.linked.Plan.init(b, references, &.{})).references);
    references.root_module.link_objects.append(b.allocator, .{ .other_step = shared }) catch @panic("OOM");
    try std.testing.expectError(error.CompilerReferenceCountExceeded, manifest.linked.Plan.init(b, references, &.{}));
}

test "compiler binding linked complete capture charges repeated native references and exact graph bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const b = try bindingGraph(allocator);
    const root = bindingRoot(b);
    for (1..manifest.linked.maximum_references) |_| root.root_module.addIncludePath(.zig_lib);
    const captured = try manifest.graph.capture(b, root, &.{});
    try std.testing.expectEqual(4096, captured.files.len);
    root.root_module.addIncludePath(.zig_lib);
    try std.testing.expectError(error.CompilerReferenceCountExceeded, manifest.graph.capture(b, root, &.{}));
    const sized = bindingRoot(b);
    sized.kind = .@"test";
    sized.filters = &.{""};
    const baseline = try manifest.graph.capture(b, sized, &.{});
    const filter = try allocator.alloc(u8, manifest.graph.maximum_graph_bytes - baseline.bytes.len + 1);
    @memset(filter, 'x');
    sized.filters = &.{filter[0 .. filter.len - 1]};
    const exact = try manifest.graph.capture(b, sized, &.{});
    try std.testing.expectEqual(manifest.graph.maximum_graph_bytes, exact.bytes.len);
    sized.filters = &.{filter};
    try std.testing.expectError(error.CompilerGraphTooLarge, manifest.graph.capture(b, sized, &.{}));
}

test "compiler binding linked assembly admission covers imported macros environment target and original origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try bindingGraph(arena.allocator());
    const parent = bindingRoot(b);
    parent.root_module.addAssemblyFile(b.path("standalone.S"));
    _ = try manifest.linked.Plan.init(b, parent, &.{});
    const imported = bindingModule(b);
    parent.root_module.addImport("imported", imported);
    imported.addCMacro("movq", ".include");
    try std.testing.expectError(error.UnqualifiedCompilerAssemblyMacros, manifest.linked.Plan.init(b, parent, &.{}));
    imported.c_macros.clearRetainingCapacity();
    for ([_][]const u8{ "NIX_CFLAGS_COMPILE", "NIX_CFLAGS_LINK", "NIX_LDFLAGS" }) |name| {
        try b.graph.environ_map.put(name, "-Dmovq=.include");
        try std.testing.expectError(error.UnqualifiedCompilerAssemblyEnvironment, manifest.linked.Plan.init(b, parent, &.{}));
        _ = b.graph.environ_map.swapRemove(name);
    }
    try b.graph.environ_map.put("NIX_CFLAGS_COMPILE", "-isystem /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-fixture/include");
    _ = try manifest.linked.Plan.init(b, parent, &.{});
    _ = b.graph.environ_map.swapRemove("NIX_CFLAGS_COMPILE");
    var target = b.graph.host;
    target.result.os.tag = .macos;
    parent.root_module.resolved_target = target;
    try std.testing.expectError(error.UnqualifiedCompilerAssemblyTarget, manifest.linked.Plan.init(b, parent, &.{}));
    parent.root_module.resolved_target = b.graph.host;
    var inputs = manifest.paths.Inputs{ .build = b };
    const generated = b.addWriteFiles().add("generated.S", "ret\n");
    try std.testing.expectError(error.UnqualifiedCompilerAssemblyOrigin, inputs.assembly(generated, "assembly", .x86_64));
    try std.testing.expectError(error.UnqualifiedCompilerAssemblyOrigin, inputs.assembly(.{ .cwd_relative = "/foreign/input.S" }, "assembly", .x86_64));
    try std.testing.expectEqual(0, inputs.files.items.len);
}
