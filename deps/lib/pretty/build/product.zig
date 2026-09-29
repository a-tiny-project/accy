const std = @import("std");
const build_api = @import("build_api");

pub const Inputs = struct {
    pretty_core: *std.Build.Module,
    sys: *std.Build.Module,
};

pub const Product = struct {
    pretty: *std.Build.Module,
    pretty_usage: *std.Build.Module,
};

pub fn addProduct(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
) Product {
    const pretty = inputs.pretty_core;
    build_api.registerModule(b, "pretty", pretty);
    const library = b.addLibrary(.{
        .linkage = .static,
        .name = "pretty",
        .root_module = pretty,
    });
    b.installArtifact(library);
    const pretty_usage = b.addModule(
        "pretty_usage",
        options.createOptions(b, "src/usage/root.zig", &.{
            .{ .name = "pretty", .module = pretty },
            .{ .name = "sys", .module = inputs.sys },
        }),
    );
    return .{ .pretty = pretty, .pretty_usage = pretty_usage };
}
