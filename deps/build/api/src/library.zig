const std = @import("std");

pub const LibrarySpec = struct {
    name: []const u8,
    root_module: *std.Build.Module,
};

pub fn addStaticLibrary(
    b: *std.Build,
    spec: LibrarySpec,
) *std.Build.Step.Compile {
    const library = b.addLibrary(.{
        .linkage = .static,
        .name = spec.name,
        .root_module = spec.root_module,
    });
    b.installArtifact(library);
    return library;
}
