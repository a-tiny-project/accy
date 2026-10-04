const std = @import("std");
const binding = @import("root.zig");
const build = @import("../../root.zig");

const prefix = "tiny.compiled-binding-exposure/v1/";
const helper_key = "tiny.compiled-binding-exposure-helper/v1";

pub const Exposure = struct {
    step: *std.Build.Step.Run,
    locator: std.Build.LazyPath,
    record: std.Build.LazyPath,
};

/// Register only explicit roles. Each consumer depends on this original Run;
/// its argv/environment and cache wrapper remain the consumer owner's policy.
pub fn add(b: *std.Build, compile: *std.Build.Step.Compile, selected: binding.model.Selection) Exposure {
    return checked(b, compile, selected) catch |err|
        std.debug.panic("compiler binding exposure: {s}", .{@errorName(err)});
}

pub fn checked(b: *std.Build, compile: *std.Build.Step.Compile, selected: binding.model.Selection) !Exposure {
    try selected.validate();
    std.debug.assert(compile.step.owner.graph == b.graph);
    const exported = binding.add(b, compile);
    const owner = registryOwner(b.graph);
    const source_record = exported.directory.path(b, "record.json");
    const key = owner.fmt(prefix ++ "{s}/{d}/{s}", .{ @tagName(selected.aggregate), selected.ordinal, selected.role });
    const sub_path = if (std.mem.eql(u8, selected.role, "primary"))
        owner.fmt("share/chic/compiled-bindings/{s}/{d}", .{ @tagName(selected.aggregate), selected.ordinal })
    else
        owner.fmt("share/chic/compiled-bindings/{s}/auxiliary/{d}/{s}", .{ @tagName(selected.aggregate), selected.ordinal, selected.role });
    const record_path = owner.graph.path(.install_prefix, owner.fmt("{s}/record.json", .{sub_path}));
    if (owner.named_lazy_paths.get(key)) |locator| {
        const run = owner.graph.generated_files.items[@backingInt(locator.generated.index)].cast(std.Build.Step.Run).?;
        const original = run.argv.items[1].lazy_path.lazy_path;
        if (original.generated.index != source_record.generated.index) return error.CompilerBindingSelectionConflict;
        return .{ .step = run, .locator = locator, .record = record_path };
    }
    if (owner.named_lazy_paths.count() >= binding.model.maximum_registry_paths) return error.CompilerBindingRegistryTooLarge;
    var count: usize = 0;
    for (owner.named_lazy_paths.keys()) |name| {
        if (std.mem.startsWith(u8, name, prefix)) count += 1;
    }
    if (count == binding.model.maximum_exposures) return error.CompilerBindingExposureCountExceeded;
    const name = owner.fmt("expose compiled binding {s}/{d}/{s}", .{ @tagName(selected.aggregate), selected.ordinal, selected.role });
    const run = std.Build.Step.Run.create(owner, name);
    run.setName(name);
    run.addFileArg2(helper(owner), .{ .make_absolute = true });
    run.addFileArg2(source_record, .{ .make_absolute = true });
    run.addDirectoryArg2(owner.graph.path(.install_prefix, sub_path), .{ .make_absolute = true });
    const locator = run.addOutputFileArg2("locator.json", .{ .make_absolute = true });
    run.addArgs(&.{ @tagName(selected.aggregate), owner.fmt("{d}", .{selected.ordinal}), selected.role, name });
    run.has_side_effects = true;
    owner.addNamedLazyPath(key, locator);
    return .{ .step = run, .locator = locator, .record = record_path };
}

/// Native generated-file indices are graph-wide and append-only. Registration
/// first creates its emitted/export paths; index zero then permanently anchors
/// one Build owner for the shared install-prefix registry and helper lifetime.
/// Every participating caller uses this same anchor, regardless of its package.
fn registryOwner(graph: *std.Build.Graph) *std.Build {
    std.debug.assert(graph.generated_files.items.len > 0);
    return graph.generated_files.items[0].owner;
}

fn helper(b: *std.Build) std.Build.LazyPath {
    if (b.named_lazy_paths.get(helper_key)) |existing| return existing;
    const options = build.ModuleOptions.host(b, .fast, "");
    const executable = b.addExecutable(.{
        .name = "tiny-expose-compiled-binding",
        .root_module = b.createModule(options.createOptionsWithRoot(source(b, false), &.{})),
        .use_llvm = build.hostToolBackend(b),
    });
    const binary = executable.getEmittedBin();
    b.addNamedLazyPath(helper_key, binary);
    return binary;
}

pub fn source(b: *std.Build, tests: bool) std.Build.LazyPath {
    return sourceMode(b, tests, false);
}

pub fn framingSource(b: *std.Build) std.Build.LazyPath {
    return sourceMode(b, false, true);
}

fn sourceMode(b: *std.Build, tests: bool, framing: bool) std.Build.LazyPath {
    const files = b.addWriteFiles();
    _ = files.add("binding/expose.zig", @embedFile("expose.zig"));
    _ = files.add("binding/transport.zig", @embedFile("transport.zig"));
    _ = files.add("binding/lifetime.zig", @embedFile("lifetime.zig"));
    _ = files.add("binding/framing.zig", @embedFile("framing.zig"));
    _ = files.add("binding/mode.zig", if (framing) "pub const framing = true;\n" else "pub const framing = false;\n");
    _ = files.add("binding/model.zig", @embedFile("model.zig"));
    _ = files.add("binding/root.zig", "pub const model = @import(\"model.zig\");\n");
    _ = files.add("root.zig", "pub const model = @import(\"model.zig\");\n");
    _ = files.add("model.zig", @embedFile("../model.zig"));
    if (tests) {
        _ = files.add("binding/exposuretest.zig", @embedFile("exposuretest.zig"));
        return files.add("test.zig", "test { _ = @import(\"binding/exposuretest.zig\"); _ = @import(\"binding/lifetime.zig\"); }\n");
    }
    return files.add("main.zig", "pub const main = @import(\"binding/expose.zig\").main;\n");
}
