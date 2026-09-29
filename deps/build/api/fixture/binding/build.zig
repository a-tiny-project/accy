const std = @import("std");
const build_api = @import("build_api");

/// The compiler binding fixtures, built as their own root package. The driver
/// launches this build with an exact invocation record, and the binding tests
/// read the installed path modules.
pub fn build(b: *std.Build) void {
    build_api.package(b, graph);
}

fn graph(b: *std.Build) void {
    const install = b.getInstallStep();
    const binding = b.addOptions();
    addBinding(b, install, binding);
    addLinked(b, install, binding);
    const exposure = b.addOptions();
    addExposure(b, install, exposure);
    install.dependOn(&b.addInstallFile(binding.getOutput(), "binding.zig").step);
    install.dependOn(&b.addInstallFile(exposure.getOutput(), "exposure.zig").step);
}

fn fixture(b: *std.Build, name: []const u8, index: u8) *std.Build.Step.Compile {
    const settings = b.addOptions();
    settings.addOption(u8, "value", index);
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = b.graph.host,
            .optimize = .debug,
            .link_libc = index == 2,
            .imports = &.{.{ .name = "settings", .module = settings.createModule() }},
        }),
        .use_llvm = false,
    });
}

fn addBinding(b: *std.Build, step: *std.Build.Step, options: *std.Build.Step.Options) void {
    for ([_][]const u8{ "first", "second", "native" }, 0..) |name, index| {
        const compile = fixture(b, b.fmt("compiler-binding-{s}", .{name}), @intCast(index));
        const exported = build_api.exportCompilerBinding(b, compile);
        const run = b.addRunArtifact(compile);
        run.step.dependOn(&exported.step.step);
        run.expectExitCode(@intCast(index));
        step.dependOn(&run.step);
        options.addOptionPath(b.fmt("{s}_record", .{name}), exported.directory.path(b, "record.json"));
        options.addOptionPath(b.fmt("{s}_binary", .{name}), compile.getEmittedBin());
    }
}

fn addLinked(b: *std.Build, step: *std.Build.Step, options: *std.Build.Step.Options) void {
    const files = b.addWriteFiles();
    const parent_source = files.add("parent.zig", "extern fn firstValue() callconv(.c) u32;\nextern fn secondValue() callconv(.c) u32;\n" ++
        "extern fn mp_setjmp(*[256]u8) callconv(.c) usize;\n" ++
        "pub fn main() !void { var context: [256]u8 align(16) = undefined; if (mp_setjmp(&context) != 0) return error.AssemblyFixtureValue; if (firstValue() + secondValue() != 40) return error.LinkedFixtureValue; }\n");
    const root = b.createModule(.{ .root_source_file = parent_source, .target = b.graph.host, .optimize = .debug });
    const parent = b.addExecutable(.{ .name = "binding-linked-parent", .root_module = root, .use_llvm = false });
    for ([_][]const u8{ "first", "second" }, [_]u32{ 17, 23 }) |name, value| {
        const settings = b.addOptions();
        settings.addOption(u32, "value", value);
        const source = files.add(b.fmt("{s}.zig", .{name}), b.fmt("const settings = @import(\"settings\");\nexport fn {s}Value() callconv(.c) u32 {{ return settings.value; }}\n", .{name}));
        const module_value = b.createModule(.{ .root_source_file = source, .target = b.graph.host, .optimize = .fast, .imports = &.{.{ .name = "settings", .module = settings.createModule() }} });
        const object = b.addObject(.{ .name = "binding-linked-object", .root_module = module_value, .use_llvm = true });
        root.addObject(object);
    }
    const assembly_path = b.path(switch (b.graph.host.result.cpu.arch) {
        .x86_64 => "../../../../lib/mprompt/src/asm/longjmp_amd64.S",
        .aarch64 => "../../../../lib/mprompt/src/asm/longjmp_arm64.S",
        else => @panic("binding assembly fixture requires Linux x86_64 or aarch64"),
    });
    if (b.graph.host.result.os.tag != .linux) @panic("binding assembly fixture requires Linux");
    root.addAssemblyFile(assembly_path);
    options.addOptionPath("linked_assembly", assembly_path);
    const selected = build_api.exposeCompilerBinding(b, parent, .{ .aggregate = .fixture, .ordinal = 3 });
    const run = b.addRunArtifact(parent);
    run.expectExitCode(0);
    run.step.dependOn(&selected.step.step);
    step.dependOn(&run.step);
    options.addOptionPath("linked_record", build_api.exportCompilerBinding(b, parent).directory.path(b, "record.json"));
    options.addOptionPath("linked_binary", parent.getEmittedBin());
    options.addOptionPath("linked_locator", selected.locator);
}

fn addExposure(b: *std.Build, step: *std.Build.Step, options: *std.Build.Step.Options) void {
    for ([_][]const u8{ "first", "second", "native" }, 0..) |name, index| {
        const compile = fixture(b, "binding-exposure-fixture", @intCast(index));
        const exported = build_api.exportCompilerBinding(b, compile);
        const selected = build_api.exposeCompilerBinding(b, compile, .{ .aggregate = .fixture, .ordinal = @intCast(index) });
        const run = b.addRunArtifact(compile);
        run.expectExitCode(@intCast(index));
        run.step.dependOn(&selected.step.step);
        step.dependOn(&run.step);
        if (index == 0) options.addOptionPath("exposure_binary", selected.step.argv.items[0].lazy_path.lazy_path);
        options.addOptionPath(b.fmt("{s}_record", .{name}), exported.directory.path(b, "record.json"));
        options.addOptionPath(b.fmt("{s}_locator", .{name}), selected.locator);
        options.addOptionPath(b.fmt("{s}_installed_record", .{name}), selected.record);
        options.step.dependOn(&selected.step.step);
        if (index == 0) {
            const mirror = build_api.exposeCompilerBinding(b, compile, .{ .aggregate = .fixture, .ordinal = 0, .role = "mirror" });
            run.step.dependOn(&mirror.step.step);
            options.addOptionPath("mirror_locator", mirror.locator);
        }
    }
}
