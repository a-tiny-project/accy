const std = @import("std");
const manifest = @import("../root.zig");
const binding = @import("root.zig");
const build = @import("../../root.zig");

const prefix = "tiny.compiled-binding/v1/";

pub const Export = struct {
    step: *std.Build.Step.Run,
    directory: std.Build.LazyPath,
};

/// Opt in exactly this Compile. The caller connects the returned step to its
/// existing execution consumer, which already uses this same emitted binary.
/// The package's ordinary finalization supplies the qualified owner inputs.
pub fn add(b: *std.Build, compile: *std.Build.Step.Compile) Export {
    std.debug.assert(b.graph == compile.step.owner.graph);
    if (find(compile)) |existing| return existing;
    const owner = compile.step.owner;
    if (owner.named_lazy_paths.count() > binding.model.maximum_registry_paths) {
        @panic("CompilerBindingRegistryTooLarge");
    }
    var count: usize = 0;
    for (owner.named_lazy_paths.keys()) |name| {
        if (std.mem.startsWith(u8, name, prefix)) count += 1;
    }
    if (count == binding.model.maximum_bindings) @panic("CompilerBindingCountExceeded");
    const options = build.ModuleOptions.host(b, .fast, "");
    const executable = b.addExecutable(.{
        .name = "tiny-compiled-binding",
        .root_module = b.createModule(options.createOptionsWithRoot(source(b, false), &.{})),
        .use_llvm = build.hostToolBackend(b),
    });
    const run = b.addRunArtifact(executable);
    const directory = run.addOutputDirectoryArg2("compiled-binding", .{ .make_absolute = true });
    run.addFileArg2(compile.getEmittedBin(), .{ .make_absolute = true });
    owner.addNamedLazyPath(key(compile), directory);
    return .{ .step = run, .directory = directory };
}

/// Keep the embedded helper's module root above both owned namespaces, just
/// as in the build API. Tests exercise these exact helper/model source bytes.
pub fn source(b: *std.Build, tests: bool) std.Build.LazyPath {
    const files = b.addWriteFiles();
    _ = files.add("binding/emit.zig", @embedFile("emit.zig"));
    _ = files.add("binding/model.zig", @embedFile("model.zig"));
    _ = files.add("binding/root.zig", "pub const model = @import(\"model.zig\");\n");
    _ = files.add("root.zig", "pub const model = @import(\"model.zig\");\n");
    _ = files.add("model.zig", @embedFile("../model.zig"));
    if (tests) {
        _ = files.add("binding/test.zig", @embedFile("test.zig"));
        return files.add("test.zig", "test { _ = @import(\"binding/test.zig\"); }\n");
    }
    return files.add("main.zig", "pub const main = @import(\"binding/emit.zig\").main;\n");
}

pub fn find(compile: *std.Build.Step.Compile) ?Export {
    if (compile.generated_bin == .none) return null;
    const owner = compile.step.owner;
    const directory = owner.named_lazy_paths.get(key(compile)) orelse return null;
    const step = owner.graph.generated_files.items[@backingInt(directory.generated.index)];
    return .{ .step = step.cast(std.Build.Step.Run).?, .directory = directory };
}

/// The native generated-file index identifies the Compile within this graph.
/// This administrative key is never an input identity or emitted cache path.
fn key(compile: *std.Build.Step.Compile) []const u8 {
    const binary = compile.getEmittedBin();
    return compile.step.owner.fmt(prefix ++ "{d}", .{@backingInt(binary.generated.index)});
}

pub fn qualify(compile: *std.Build.Step.Compile, inputs: manifest.attachment.Inputs) void {
    const selected = find(compile) orelse return;
    header(selected.step, compile, "qualified");
    selected.step.addFileArg2(inputs.manifest.bytes, .{ .make_absolute = true });
    selected.step.addFileArg2(inputs.invocation, .{ .make_absolute = true });
    selected.step.addFileArg2(inputs.compilation, .{ .make_absolute = true });
}

pub fn refuse(compile: *std.Build.Step.Compile, reason: []const u8) void {
    const selected = find(compile) orelse return;
    header(selected.step, compile, reason);
}

fn header(run: *std.Build.Step.Run, compile: *std.Build.Step.Compile, state: []const u8) void {
    std.debug.assert(run.argv.items.len == 3);
    run.addArgs(&.{ compile.name, @tagName(compile.kind), state });
}
