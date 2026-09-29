const std = @import("std");
const build_api = @import("build_api");
const conformance = @import("conformance.zig");
const deps = @import("deps.zig");
const generate = @import("generate.zig");
const product = @import("product.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const configuration = deps.configure(b);
    const module_options = build_api.ModuleOptions{
        .target = configuration.target,
        .optimize = configuration.optimize,
    };
    const alloc_phase = deps.allocPhase(b, module_options);
    const xkb = product.addProduct(
        b,
        module_options,
        alloc_phase,
    );
    const xkb_tests = product.createTestModule(b, module_options, alloc_phase);
    b.installArtifact(xkb.library);
    const generated_check = generate.add(b);
    tests.add(
        b,
        module_options,
        configuration,
        xkb_tests,
        xkb.module,
        generated_check,
    );
    conformance.add(b, module_options, xkb.module, configuration.test_filters);
}
