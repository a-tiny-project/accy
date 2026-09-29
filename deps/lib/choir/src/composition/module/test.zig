const fixture = @import("../fixture/root.zig");
const std = @import("std");
const subject = @import("root.zig");
const serialization = @import("serialization/test.zig");
const verification = @import("verification/test.zig");

const CallSiteSpec = subject.CallSiteSpec;
const TargetChoiceSpec = subject.TargetChoiceSpec;
const CompositionVariantSpec = subject.CompositionVariantSpec;
const CompositionModule = subject.CompositionModule;

test {
    std.testing.refAllDecls(subject);
    _ = serialization;
    _ = verification;
}

test "composition module verifies artifacts and retains a diagnostic path" {
    const records = try fixture.Records.init(std.testing.allocator);
    defer records.deinit();
    const choir = @import("../../root.zig");
    const composition_root = @import("../root.zig");
    const abi = composition_root.abi;
    const product = choir.product;
    const source = composition_root.source;

    var partitioned = try source.PartitionedModule.init(std.testing.allocator, "hybrid.score");
    defer partitioned.deinit();
    try partitioned.addBoundary(.{ .id = .{ .value = 1 }, .name = "x", .element_type = .f32, .dimensions = &.{8}, .byte_size = 32, .access = .read_write, .ownership = .borrowed, .alias = .disjoint, .provenance = .{ .path = "score.chic", .symbol = "x", .line = 4 } });
    try partitioned.addBoundary(.{ .id = .{ .value = 2 }, .name = "y", .element_type = .f32, .dimensions = &.{8}, .byte_size = 32, .access = .write, .ownership = .produced, .alias = .disjoint, .provenance = .{ .path = "score.chic", .symbol = "y", .line = 6 } });
    try partitioned.addPartition(.{ .id = .{ .value = 10 }, .name = "score/host", .pipeline = .choir, .outputs = &.{.{ .value = 1 }}, .product = .{ .producer = "composition-fixture", .source = "10", .stage = "hybrid.input", .variant = "default" }, .effect = .none, .provenance = .{ .path = "score.chic", .symbol = "score", .line = 4 } });
    try partitioned.addPartition(.{ .id = .{ .value = 11 }, .name = "score/affine", .pipeline = .accy, .inputs = &.{.{ .value = 1 }}, .outputs = &.{.{ .value = 2 }}, .product = .{ .producer = "composition-fixture", .source = "11", .stage = "hybrid.input", .variant = "default" }, .effect = .none, .provenance = .{ .path = "score.chic", .symbol = "affine8", .line = 6 } });
    try partitioned.addCallSite(.{ .id = .{ .value = 30 }, .name = "score/affine", .caller = .{ .value = 10 }, .callee = .{ .value = 11 }, .inputs = &.{.{ .value = 1 }}, .outputs = &.{.{ .value = 2 }}, .provenance = .{ .path = "score.chic", .symbol = "affine8", .line = 6 } });

    var host_artifact = try choir.backends.artifact.objectFileArtifact(
        std.testing.allocator,
        .{ .architecture = .x86_64 },
        .{ .name = "sysv", .pointer_width_bits = 64, .endianness = .little },
        "score",
        &.{ 0, 0, 0, 0 },
        &.{.{ .offset = 0, .symbol = abi.invoke_symbol, .kind = .call }},
    );
    defer host_artifact.deinit();
    var accy_artifact = try choir.backends.artifact.objectFileArtifact(
        std.testing.allocator,
        .{ .architecture = .x86_64 },
        .{ .name = "sysv", .pointer_width_bits = 64, .endianness = .little },
        "affine8",
        &.{ 1, 2, 3, 4 },
        &.{},
    );
    defer accy_artifact.deinit();

    var module = try CompositionModule.init(std.testing.allocator, &partitioned);
    defer module.deinit();
    try std.testing.expectError(error.ProductIdentityMismatch, module.addFragment(.{
        .id = .{ .value = 20 },
        .partition = .{ .value = 10 },
        .pipeline = .choir,
        .pipeline_input = try records.key("hybrid.input", "99", "110"),

        .artifacts = &.{host_artifact},
        .exports = &.{.{ .name = "score", .symbol = "score", .abi_version = abi.version }},
        .imports = &.{.{ .name = "invoke", .symbol = abi.invoke_symbol, .abi_version = abi.version, .kind = .runtime }},
        .provenance = .{ .path = "score.chic", .symbol = "score", .line = 4 },
    }));
    try module.addFragment(.{
        .id = .{ .value = 20 },
        .partition = .{ .value = 10 },
        .pipeline = .choir,
        .pipeline_input = try records.key("hybrid.input", "10", "110"),

        .artifacts = &.{host_artifact},
        .exports = &.{.{ .name = "score", .symbol = "score", .abi_version = abi.version }},
        .imports = &.{.{ .name = "invoke", .symbol = abi.invoke_symbol, .abi_version = abi.version, .kind = .runtime }},
        .provenance = .{ .path = "score.chic", .symbol = "score", .line = 4 },
    });
    try module.addFragment(.{
        .id = .{ .value = 21 },
        .partition = .{ .value = 11 },
        .pipeline = .accy,
        .pipeline_input = try records.key("hybrid.input", "11", "111"),

        .artifacts = &.{accy_artifact},
        .exports = &.{.{ .name = "affine", .symbol = "affine8", .abi_version = abi.version }},
        .provenance = .{ .path = "score.chic", .symbol = "affine8", .line = 6 },
    });
    const call_spec = CallSiteSpec{
        .id = .{ .value = 30 },
        .name = "score/affine",
        .caller = .{ .value = 20 },
        .caller_export = "score",
        .runtime_import = "invoke",
        .callee = .{ .value = 21 },
        .callee_export = "affine",
        .inputs = &.{.{ .value = 1 }},
        .outputs = &.{.{ .value = 2 }},
        .abi_version = abi.version,
        .provenance = .{ .path = "score.chic", .symbol = "affine8", .line = 6 },
    };
    const variant_spec = CompositionVariantSpec{
        .id = .{ .value = 1 },
        .choice = .{
            .target = product.productRef("composition-fixture", "1", "hybrid.target", "default"),
            .policy = product.productRef("composition-fixture", "1", "hybrid.policy", "default"),
        },
        .fragments = &.{ .{ .value = 20 }, .{ .value = 21 } },
        .call_sites = &.{call_spec},
    };
    const runtime_symbol = module.fragments.items[0].imports[0].symbol;
    module.fragments.items[0].imports[0].symbol = "wrong_invoke";
    defer module.fragments.items[0].imports[0].symbol = runtime_symbol;
    try std.testing.expectError(error.RuntimeSymbolMismatch, module.addVariant(variant_spec));
    module.fragments.items[0].imports[0].symbol = runtime_symbol;
    try module.addVariant(variant_spec);
    try module.verify();
    module.fragments.items[1].pipeline_input.ref.source = "99";
    try std.testing.expectError(error.ProductIdentityMismatch, module.verify());
    module.fragments.items[1].pipeline_input.ref.source = "11";
    try module.verify();

    const path = try module.diagnosticPath(.{ .value = 1 }, .{ .value = 30 });
    try std.testing.expectEqualStrings("score/affine", path.partition.name);
    try std.testing.expectEqual(source.Pipeline.accy, path.fragment.pipeline);
    try std.testing.expectEqualStrings("hybrid.input", path.pipeline_input.ref.stage);
    try std.testing.expectEqualStrings("affine8", path.fragment_export.symbol);
    try std.testing.expectEqual(choir.backends.artifact.ArtifactKind.object_file, path.artifact.metadata.kind);

    const resources = try std.testing.allocator.alloc(choir.bytecode.Resource, module.bytecodeResourceCount());
    defer std.testing.allocator.free(resources);
    const written = try module.writeBytecodeResources(resources);
    try std.testing.expectEqual(@as(usize, 2), written.len);
}

test "target choices select distinct complete composition variants" {
    const records = try fixture.Records.init(std.testing.allocator);
    defer records.deinit();
    const choir = @import("../../root.zig");
    const composition_root = @import("../root.zig");
    const abi = composition_root.abi;
    const product = choir.product;
    const source = composition_root.source;

    var partitioned = try source.PartitionedModule.init(std.testing.allocator, "variants");
    defer partitioned.deinit();
    try partitioned.addPartition(.{
        .id = .{ .value = 1 },
        .name = "host",
        .pipeline = .choir,
        .product = product.productRef("composition-fixture", "1", "variants.host.input", "default"),
        .effect = .none,
        .provenance = .{ .path = "variants.chic", .symbol = "host" },
    });
    try partitioned.addPartition(.{
        .id = .{ .value = 2 },
        .name = "kernel",
        .pipeline = .accy,
        .product = product.productRef("composition-fixture", "2", "variants.kernel.input", "default"),
        .effect = .none,
        .provenance = .{ .path = "variants.chic", .symbol = "kernel" },
    });
    try partitioned.addCallSite(.{
        .id = .{ .value = 30 },
        .name = "host/kernel",
        .caller = .{ .value = 1 },
        .callee = .{ .value = 2 },
        .inputs = &.{},
        .outputs = &.{},
        .provenance = .{ .path = "variants.chic", .symbol = "kernel" },
    });

    var host_x86 = try choir.backends.artifact.objectFileArtifact(
        std.testing.allocator,
        .{ .architecture = .x86_64 },
        .{},
        "host_x86",
        &.{1},
        &.{.{ .offset = 0, .symbol = abi.invoke_symbol, .kind = .call }},
    );
    defer host_x86.deinit();
    var kernel_x86 = try choir.backends.artifact.objectFileArtifact(
        std.testing.allocator,
        .{ .architecture = .x86_64 },
        .{},
        "kernel_x86",
        &.{2},
        &.{},
    );
    defer kernel_x86.deinit();
    var host_arm = try choir.backends.artifact.objectFileArtifact(
        std.testing.allocator,
        .{ .architecture = .aarch64 },
        .{},
        "host_arm",
        &.{3},
        &.{.{ .offset = 0, .symbol = abi.invoke_symbol, .kind = .call }},
    );
    defer host_arm.deinit();
    var kernel_arm = try choir.backends.artifact.objectFileArtifact(
        std.testing.allocator,
        .{ .architecture = .aarch64 },
        .{},
        "kernel_arm",
        &.{4},
        &.{},
    );
    defer kernel_arm.deinit();

    var module = try CompositionModule.init(std.testing.allocator, &partitioned);
    defer module.deinit();
    try module.addFragment(.{
        .id = .{ .value = 10 },
        .partition = .{ .value = 1 },
        .pipeline = .choir,
        .pipeline_input = try records.key("variants.host.input", "1", "101"),

        .artifacts = &.{host_x86},
        .exports = &.{.{ .name = "host", .symbol = "host_x86", .abi_version = abi.version }},
        .imports = &.{.{ .name = "invoke", .symbol = abi.invoke_symbol, .abi_version = abi.version, .kind = .runtime }},
        .provenance = .{ .path = "variants.chic", .symbol = "host" },
    });
    try module.addFragment(.{
        .id = .{ .value = 11 },
        .partition = .{ .value = 1 },
        .pipeline = .choir,
        .pipeline_input = try records.key("variants.host.input", "1", "101"),

        .artifacts = &.{host_arm},
        .exports = &.{.{ .name = "host", .symbol = "host_arm", .abi_version = abi.version }},
        .imports = &.{.{ .name = "invoke", .symbol = abi.invoke_symbol, .abi_version = abi.version, .kind = .runtime }},
        .provenance = .{ .path = "variants.chic", .symbol = "host" },
    });
    try module.addFragment(.{
        .id = .{ .value = 20 },
        .partition = .{ .value = 2 },
        .pipeline = .accy,
        .pipeline_input = try records.key("variants.kernel.input", "2", "201"),

        .artifacts = &.{kernel_x86},
        .exports = &.{.{ .name = "kernel", .symbol = "kernel_x86", .abi_version = abi.version }},
        .provenance = .{ .path = "variants.chic", .symbol = "kernel" },
    });
    try module.addFragment(.{
        .id = .{ .value = 21 },
        .partition = .{ .value = 2 },
        .pipeline = .accy,
        .pipeline_input = try records.key("variants.kernel.input", "2", "201"),

        .artifacts = &.{kernel_arm},
        .exports = &.{.{ .name = "kernel", .symbol = "kernel_arm", .abi_version = abi.version }},
        .provenance = .{ .path = "variants.chic", .symbol = "kernel" },
    });

    const x86_choice = TargetChoiceSpec{
        .target = product.productRef("composition-fixture", "x86_64", "variants.target", "default"),
        .policy = product.productRef("composition-fixture", "prefer-native", "variants.policy", "default"),
    };
    const arm_choice = TargetChoiceSpec{
        .target = product.productRef("composition-fixture", "aarch64", "variants.target", "default"),
        .policy = x86_choice.policy,
    };
    const x86_call = CallSiteSpec{
        .id = .{ .value = 30 },
        .name = "host/kernel",
        .caller = .{ .value = 10 },
        .caller_export = "host",
        .runtime_import = "invoke",
        .callee = .{ .value = 20 },
        .callee_export = "kernel",
        .inputs = &.{},
        .outputs = &.{},
        .abi_version = abi.version,
        .provenance = .{ .path = "variants.chic", .symbol = "kernel" },
    };
    const arm_call = CallSiteSpec{
        .id = .{ .value = 30 },
        .name = "host/kernel",
        .caller = .{ .value = 11 },
        .caller_export = "host",
        .runtime_import = "invoke",
        .callee = .{ .value = 21 },
        .callee_export = "kernel",
        .inputs = &.{},
        .outputs = &.{},
        .abi_version = abi.version,
        .provenance = .{ .path = "variants.chic", .symbol = "kernel" },
    };
    const x86_variant = CompositionVariantSpec{
        .id = .{ .value = 100 },
        .choice = x86_choice,
        .fragments = &.{ .{ .value = 10 }, .{ .value = 20 } },
        .call_sites = &.{x86_call},
    };
    try module.addVariant(x86_variant);
    try std.testing.expectError(error.UnreferencedFragment, module.verify());
    try std.testing.expectError(error.DuplicateCompositionVariant, module.addVariant(.{
        .id = x86_variant.id,
        .choice = arm_choice,
        .fragments = &.{ .{ .value = 11 }, .{ .value = 21 } },
        .call_sites = &.{arm_call},
    }));
    try std.testing.expectError(error.DuplicateTargetChoice, module.addVariant(.{
        .id = .{ .value = 101 },
        .choice = x86_choice,
        .fragments = &.{ .{ .value = 10 }, .{ .value = 20 } },
        .call_sites = &.{x86_call},
    }));
    try std.testing.expectError(error.MissingPartitionFragment, module.addVariant(.{
        .id = .{ .value = 101 },
        .choice = arm_choice,
        .fragments = &.{.{ .value = 11 }},
        .call_sites = &.{arm_call},
    }));
    try std.testing.expectError(error.DuplicatePartitionFragment, module.addVariant(.{
        .id = .{ .value = 101 },
        .choice = arm_choice,
        .fragments = &.{ .{ .value = 10 }, .{ .value = 11 } },
        .call_sites = &.{arm_call},
    }));
    try std.testing.expectError(error.FragmentOutsideVariant, module.addVariant(.{
        .id = .{ .value = 101 },
        .choice = arm_choice,
        .fragments = &.{ .{ .value = 10 }, .{ .value = 20 } },
        .call_sites = &.{arm_call},
    }));
    try std.testing.expectError(error.EmptyTargetIdentity, module.addVariant(.{
        .id = .{ .value = 101 },
        .choice = .{ .target = product.productRef("composition-fixture", "1", "", "default"), .policy = arm_choice.policy },
        .fragments = &.{ .{ .value = 11 }, .{ .value = 21 } },
        .call_sites = &.{arm_call},
    }));
    try std.testing.expectError(error.EmptyPolicyIdentity, module.addVariant(.{
        .id = .{ .value = 101 },
        .choice = .{ .target = arm_choice.target, .policy = product.productRef("composition-fixture", "1", "", "default") },
        .fragments = &.{ .{ .value = 11 }, .{ .value = 21 } },
        .call_sites = &.{arm_call},
    }));

    try module.addVariant(.{
        .id = .{ .value = 101 },
        .choice = arm_choice,
        .fragments = &.{ .{ .value = 11 }, .{ .value = 21 } },
        .call_sites = &.{arm_call},
    });
    try module.verify();
    try std.testing.expect(module.fragments.items[0].pipeline_input.eql(module.fragments.items[1].pipeline_input));
    try std.testing.expect(module.fragments.items[2].pipeline_input.eql(module.fragments.items[3].pipeline_input));
    const selected_x86 = module.selectVariant(x86_choice) orelse return error.TestExpectedResult;
    const selected_arm = module.selectVariant(arm_choice) orelse return error.TestExpectedResult;
    try std.testing.expectEqualSlices(
        source.FragmentId,
        &.{ .{ .value = 10 }, .{ .value = 20 } },
        selected_x86.fragments,
    );
    try std.testing.expectEqualSlices(
        source.FragmentId,
        &.{ .{ .value = 11 }, .{ .value = 21 } },
        selected_arm.fragments,
    );
    try std.testing.expect(module.selectVariant(.{
        .target = x86_choice.target,
        .policy = product.productRef("composition-fixture", "prefer-portable", "variants.policy", "default"),
    }) == null);

    {
        const compatible_input = module.fragments.items[1].pipeline_input;
        defer module.fragments.items[1].pipeline_input = compatible_input;
        module.fragments.items[1].pipeline_input = try records.key("variants.host.input", "1", "changed");
        try std.testing.expectError(error.ConflictingProductKey, module.verify());
    }
    try module.verify();
}

test "composition module survives every allocation failure" {
    const choir = @import("../../root.zig");
    const composition_root = @import("../root.zig");
    const abi = composition_root.abi;
    const product = choir.product;
    const source = composition_root.source;
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const records = try fixture.Records.init(allocator);
            defer records.deinit();
            var partitioned = try source.PartitionedModule.init(allocator, "allocation");
            defer partitioned.deinit();
            try partitioned.addBoundary(.{ .id = .{ .value = 1 }, .name = "input", .element_type = .u8, .dimensions = &.{8}, .byte_size = 8, .access = .read, .ownership = .borrowed, .alias = .disjoint, .provenance = .{ .path = "allocation", .symbol = "input" } });
            try partitioned.addBoundary(.{ .id = .{ .value = 2 }, .name = "output", .element_type = .u8, .dimensions = &.{8}, .byte_size = 8, .access = .write, .ownership = .produced, .alias = .disjoint, .provenance = .{ .path = "allocation", .symbol = "output" } });
            try partitioned.addPartition(.{ .id = .{ .value = 1 }, .name = "caller", .pipeline = .choir, .product = .{ .producer = "composition-fixture", .source = "1", .stage = "allocation.input", .variant = "default" }, .effect = .none, .provenance = .{ .path = "allocation", .symbol = "caller" } });
            try partitioned.addPartition(.{ .id = .{ .value = 2 }, .name = "callee", .pipeline = .accy, .inputs = &.{.{ .value = 1 }}, .outputs = &.{.{ .value = 2 }}, .product = .{ .producer = "composition-fixture", .source = "2", .stage = "allocation.input", .variant = "default" }, .effect = .none, .provenance = .{ .path = "allocation", .symbol = "callee" } });
            try partitioned.addCallSite(.{ .id = .{ .value = 1 }, .name = "call", .caller = .{ .value = 1 }, .callee = .{ .value = 2 }, .inputs = &.{.{ .value = 1 }}, .outputs = &.{.{ .value = 2 }}, .provenance = .{ .path = "allocation", .symbol = "call" } });

            var host_artifact = try choir.backends.artifact.objectFileArtifact(allocator, .{ .architecture = .x86_64 }, .{}, "caller", &.{1}, &.{.{ .offset = 0, .symbol = abi.invoke_symbol, .kind = .call }});
            defer host_artifact.deinit();
            var callee_artifact = try choir.backends.artifact.objectFileArtifact(allocator, .{ .architecture = .x86_64 }, .{}, "callee", &.{2}, &.{});
            defer callee_artifact.deinit();

            var module = try CompositionModule.init(allocator, &partitioned);
            defer module.deinit();
            try module.addFragment(.{ .id = .{ .value = 1 }, .partition = .{ .value = 1 }, .pipeline = .choir, .pipeline_input = try records.key("allocation.input", "1", "1"), .artifacts = &.{host_artifact}, .exports = &.{.{ .name = "caller", .symbol = "caller", .abi_version = abi.version }}, .imports = &.{.{ .name = "invoke", .symbol = abi.invoke_symbol, .abi_version = abi.version, .kind = .runtime }}, .provenance = .{ .path = "allocation", .symbol = "caller" } });
            try module.addFragment(.{ .id = .{ .value = 2 }, .partition = .{ .value = 2 }, .pipeline = .accy, .pipeline_input = try records.key("allocation.input", "2", "2"), .artifacts = &.{callee_artifact}, .exports = &.{.{ .name = "callee", .symbol = "callee", .abi_version = abi.version }}, .provenance = .{ .path = "allocation", .symbol = "callee" } });
            try module.addVariant(.{
                .id = .{ .value = 1 },
                .choice = .{
                    .target = product.productRef("composition-fixture", "1", "allocation.target", "default"),
                    .policy = product.productRef("composition-fixture", "1", "allocation.policy", "default"),
                },
                .fragments = &.{ .{ .value = 1 }, .{ .value = 2 } },
                .call_sites = &.{.{ .id = .{ .value = 1 }, .name = "call", .caller = .{ .value = 1 }, .caller_export = "caller", .runtime_import = "invoke", .callee = .{ .value = 2 }, .callee_export = "callee", .inputs = &.{.{ .value = 1 }}, .outputs = &.{.{ .value = 2 }}, .abi_version = abi.version, .provenance = .{ .path = "allocation", .symbol = "call" } }},
            });
            try module.verify();
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}
