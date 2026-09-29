const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const product = @import("product.zig");

pub const Graph = struct {
    configuration: deps.Configuration,
    options: build_api.ModuleOptions,
    dependencies: deps.Runtime,
    pretty: product.Product,
};

pub fn add(b: *std.Build) Graph {
    const configuration = deps.configure(b);
    const module_options = build_api.ModuleOptions{
        .target = configuration.target,
        .optimize = configuration.optimize,
    };
    const dependencies = deps.resolve(b, configuration);
    const pretty = product.addProduct(b, module_options, .{
        .pretty_core = dependencies.pretty_core,
        .sys = dependencies.sys,
    });
    return .{
        .configuration = configuration,
        .options = module_options,
        .dependencies = dependencies,
        .pretty = pretty,
    };
}

pub fn build(b: *std.Build) void {
    _ = add(b);
}
