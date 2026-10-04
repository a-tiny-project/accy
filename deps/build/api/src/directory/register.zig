const std = @import("std");
const build = @import("../root.zig");
const emit = @import("emit.zig");

pub const Input = struct {
    name: []const u8,
    directory: std.Build.LazyPath,
};

pub fn addOptions(b: *std.Build, inputs: []const Input) std.Build.LazyPath {
    std.debug.assert(inputs.len > 0);
    std.debug.assert(inputs.len <= emit.maximum_inputs);
    const source = b.addWriteFiles().add("directory-options.zig", @embedFile("emit.zig"));
    const options = build.ModuleOptions.host(b, .debug, "");
    const executable = b.addExecutable(.{
        .name = "tiny-directory-options",
        .root_module = b.createModule(options.createOptionsWithRoot(source, &.{})),
        .use_llvm = build.hostToolBackend(b),
    });
    const run = b.addRunArtifact(executable);
    const output = run.addOutputFileArg2("directories.zig", .{ .make_absolute = true });
    for (inputs) |input| {
        std.debug.assert(input.name.len > 0);
        std.debug.assert(input.name.len <= emit.maximum_name_bytes);
        run.addArg(input.name);
        run.addDirectoryArg2(input.directory, .{ .make_absolute = true });
    }
    return output;
}
