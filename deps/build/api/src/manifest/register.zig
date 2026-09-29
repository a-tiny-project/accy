const std = @import("std");
const build = @import("../root.zig");
const model = @import("model.zig");

pub const File = struct {
    identity: model.Input,
    path: std.Build.LazyPath,
};

pub const Manifest = struct {
    source: std.Build.LazyPath,
    bytes: std.Build.LazyPath,
    step: *std.Build.Step.Run,
    compilation: ?std.Build.LazyPath = null,
};

pub const Generator = struct {
    build: *std.Build,
    executable: *std.Build.Step.Compile,

    pub fn init(b: *std.Build) Generator {
        const files = b.addWriteFiles();
        const source = files.add("emit.zig", @embedFile("emit.zig"));
        _ = files.add("model.zig", @embedFile("model.zig"));
        _ = files.add("assembly.zig", @embedFile("assembly.zig"));
        const options = build.ModuleOptions.host(b, .fast, "");
        return .{
            .build = b,
            .executable = b.addExecutable(.{
                .name = "tiny-compiled-input-manifest",
                .root_module = b.createModule(options.createOptionsWithRoot(source, &.{})),
                .use_llvm = build.hostToolBackend(b),
            }),
        };
    }

    pub fn toolchain(self: Generator) Manifest {
        return self.capture(&.{
            .{
                .identity = .{ .path = "toolchain/zig", .pinned = true },
                .path = .zig_exe,
            },
            .{
                .identity = .{ .path = "toolchain/lib", .pinned = true, .directory = true },
                .path = .zig_lib,
            },
        }, null);
    }

    pub fn capture(self: Generator, files: []const File, inherited: ?Manifest) Manifest {
        return self.captureInner(files, inherited, null);
    }

    pub fn captureCompilation(self: Generator, files: []const File, inherited: Manifest, template: []const u8) Manifest {
        return self.captureInner(files, inherited, template);
    }

    fn captureInner(self: Generator, files: []const File, inherited: ?Manifest, template: ?[]const u8) Manifest {
        const b = self.build;
        std.debug.assert(files.len <= model.maximum_entries);
        const inputs = b.graph.alloc(model.Input, files.len);
        for (inputs, files) |*input, file| input.* = file.identity;
        const request = std.json.Stringify.valueAlloc(b.graph.arena, model.Request{
            .inputs = inputs,
            .inherited = inherited != null,
            .compilation = template != null,
        }, .{}) catch @panic("OOM");
        const run = b.addRunArtifact(self.executable);
        const output = run.addOutputDirectoryArg2("compiled-inputs", .{ .make_absolute = true });
        run.addFileArg2(b.addWriteFiles().add("manifest-request.json", request), .{
            .make_absolute = true,
        });
        if (inherited) |base| run.addFileArg2(base.bytes, .{ .make_absolute = true });
        if (template) |bytes| run.addFileArg2(b.addWriteFiles().add("compilation-template.json", bytes), .{ .make_absolute = true });
        for (files) |file| {
            if (file.identity.directory) {
                std.debug.assert(file.identity.pinned != file.identity.generated);
                run.addDirectoryArg2(file.path, .{ .make_absolute = true });
            } else {
                run.addFileArg2(file.path, .{ .make_absolute = true });
            }
        }
        return .{
            .source = output.path(b, "root.zig"),
            .bytes = output.path(b, "manifest.bin"),
            .step = run,
            .compilation = if (template != null) output.path(b, "compilation.json") else null,
        };
    }
};
