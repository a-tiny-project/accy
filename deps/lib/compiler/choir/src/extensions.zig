const std = @import("std");
const ir = @import("core/root.zig");
const rewrite = ir.rewrite;
const core_dialects = @import("core/root.zig").dialects;
const passes = @import("passes/root.zig");
const backends = @import("backends/root.zig");
const translation_mod = backends.translation;

const Allocator = std.mem.Allocator;

pub const RegisterError = Allocator.Error || ir.Context.Error || error{
    DialectLoadCycle,
};

pub const DialectRegistration = struct {
    name: []const u8,
    load: core_dialects.DialectLoaderFn,
    is_backend: bool = false,
};

pub const DialectExtensionRegistration = struct {
    dialect_name: []const u8,
    extend: core_dialects.DialectExtensionFn,
};

pub const PassRegistration = passes.PassRegistration;

pub const ConfigureConversionTargetFn = *const fn (*passes.ConversionTarget) anyerror!void;
pub const PopulateRewritePatternsFn = *const fn (*rewrite.RewritePatternSet) anyerror!void;
pub const ConfigureTypeConverterFn = *const fn (*rewrite.TypeConverter) anyerror!void;

pub const ConversionRegistration = struct {
    name: []const u8,
    configure_target: ?ConfigureConversionTargetFn = null,
    populate_patterns: ?PopulateRewritePatternsFn = null,
    configure_type_converter: ?ConfigureTypeConverterFn = null,
};

pub const BackendTranslationRegistration = translation_mod.Registration;

pub const TestUtilityContext = struct {
    allocator: Allocator,
    ir_ctx: *ir.Context,
    registry: *ExtensionRegistry,
};

pub const InstallTestUtilityFn = *const fn (*TestUtilityContext) anyerror!void;

pub const TestUtilityRegistration = struct {
    name: []const u8,
    install: InstallTestUtilityFn,
};

pub const PackageExtension = struct {
    name: []const u8,
    dialects: []const DialectRegistration = &.{},
    dialect_extensions: []const DialectExtensionRegistration = &.{},
    passes: []const PassRegistration = &.{},
    pipelines: []const passes.PipelineRegistration = &.{},
    conversions: []const ConversionRegistration = &.{},
    instrumentations: []const passes.PassInstrumentation = &.{},
    backend_translations: []const BackendTranslationRegistration = &.{},
    test_utilities: []const TestUtilityRegistration = &.{},

    pub fn registerContext(self: PackageExtension, ctx: *ir.Context) anyerror!void {
        for (self.dialects) |dialect| {
            try ctx.registerDialectLoader(dialect.name, dialect.load);
            if (dialect.is_backend) {
                try ctx.registerBackendDialect(dialect.name);
            }
        }

        for (self.dialect_extensions) |extension| {
            try ctx.addDialectExtension(extension.dialect_name, extension.extend);
        }
    }
};

pub const choir_optimization_package_extension = PackageExtension{
    .name = "choir-optimization",
    .passes = &passes.optimization_pass_registrations,
    .pipelines = &passes.optimization_pipeline_registrations,
};

pub const ExtensionRegistry = struct {
    allocator: Allocator,
    packages: std.ArrayListUnmanaged([]const u8) = .empty,
    passes: std.ArrayListUnmanaged(PassRegistration) = .empty,
    pipelines: std.ArrayListUnmanaged(passes.PipelineRegistration) = .empty,
    conversions: std.ArrayListUnmanaged(ConversionRegistration) = .empty,
    instrumentations: std.ArrayListUnmanaged(passes.PassInstrumentation) = .empty,
    backend_translations: std.ArrayListUnmanaged(BackendTranslationRegistration) = .empty,
    test_utilities: std.ArrayListUnmanaged(TestUtilityRegistration) = .empty,

    pub fn init(allocator: Allocator) ExtensionRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ExtensionRegistry) void {
        self.packages.deinit(self.allocator);
        self.passes.deinit(self.allocator);
        self.pipelines.deinit(self.allocator);
        self.conversions.deinit(self.allocator);
        self.instrumentations.deinit(self.allocator);
        self.backend_translations.deinit(self.allocator);
        self.test_utilities.deinit(self.allocator);
    }

    pub fn registerPackage(self: *ExtensionRegistry, ctx: *ir.Context, extension: PackageExtension) anyerror!void {
        try self.reserve(extension);
        try extension.registerContext(ctx);

        self.packages.appendAssumeCapacity(extension.name);
        appendSliceAssumeCapacity(PassRegistration, &self.passes, extension.passes);
        appendSliceAssumeCapacity(passes.PipelineRegistration, &self.pipelines, extension.pipelines);
        appendSliceAssumeCapacity(ConversionRegistration, &self.conversions, extension.conversions);
        appendSliceAssumeCapacity(passes.PassInstrumentation, &self.instrumentations, extension.instrumentations);
        appendSliceAssumeCapacity(BackendTranslationRegistration, &self.backend_translations, extension.backend_translations);
        appendSliceAssumeCapacity(TestUtilityRegistration, &self.test_utilities, extension.test_utilities);
    }

    pub fn addPassesTo(self: *ExtensionRegistry, manager: *passes.PassManager) anyerror!void {
        for (self.passes.items) |registration| {
            if (registration.target_op_name) |target| {
                const nested = try manager.nest(target);
                try nested.addPass(registration.pass);
            } else {
                try manager.addPass(registration.pass);
            }
        }
    }

    pub fn registerPassEntriesTo(self: *ExtensionRegistry, pass_registry: *passes.PassRegistry) anyerror!void {
        for (self.passes.items) |registration| {
            try pass_registry.registerPass(registration);
        }
        for (self.pipelines.items) |registration| {
            try pass_registry.registerPipeline(registration);
        }
    }

    pub fn registerPipelinesTo(self: *ExtensionRegistry, pipeline_registry: *passes.PipelineRegistry) anyerror!void {
        for (self.pipelines.items) |registration| {
            try pipeline_registry.registerPipeline(registration);
        }
    }

    pub fn addPipelineTo(
        self: *ExtensionRegistry,
        name: []const u8,
        manager: *passes.PassManager,
    ) anyerror!void {
        const registration = self.lookupPipeline(name) orelse return error.UnknownPipeline;
        try registration.addTo(&manager.root);
    }

    pub fn addInstrumentationsTo(self: *ExtensionRegistry, manager: *passes.PassManager) anyerror!void {
        for (self.instrumentations.items) |instrumentation| {
            try manager.addInstrumentation(instrumentation);
        }
    }

    pub fn configureConversion(
        self: *ExtensionRegistry,
        target: *passes.ConversionTarget,
        patterns: *rewrite.RewritePatternSet,
        type_converter: ?*rewrite.TypeConverter,
    ) anyerror!void {
        for (self.conversions.items) |registration| {
            if (registration.configure_target) |configure| {
                try configure(target);
            }
            if (registration.populate_patterns) |populate| {
                try populate(patterns);
            }
            if (type_converter) |converter| {
                if (registration.configure_type_converter) |configure| {
                    try configure(converter);
                }
            }
        }
    }

    pub fn registerBackendTranslationsTo(self: *ExtensionRegistry, registry: *translation_mod.Registry) anyerror!void {
        try registry.registerAll(self.backend_translations.items);
    }

    pub fn installTestUtilities(self: *ExtensionRegistry, context: *TestUtilityContext) anyerror!void {
        for (self.test_utilities.items) |registration| {
            try registration.install(context);
        }
    }

    fn lookupPipeline(self: *const ExtensionRegistry, name: []const u8) ?passes.PipelineRegistration {
        for (self.pipelines.items) |registration| {
            if (std.mem.eql(u8, registration.name, name)) return registration;
        }
        return null;
    }

    fn reserve(self: *ExtensionRegistry, extension: PackageExtension) Allocator.Error!void {
        try self.packages.ensureTotalCapacity(self.allocator, self.packages.items.len + 1);
        try self.passes.ensureTotalCapacity(self.allocator, self.passes.items.len + extension.passes.len);
        try self.pipelines.ensureTotalCapacity(self.allocator, self.pipelines.items.len + extension.pipelines.len);
        try self.conversions.ensureTotalCapacity(self.allocator, self.conversions.items.len + extension.conversions.len);
        try self.instrumentations.ensureTotalCapacity(self.allocator, self.instrumentations.items.len + extension.instrumentations.len);
        try self.backend_translations.ensureTotalCapacity(self.allocator, self.backend_translations.items.len + extension.backend_translations.len);
        try self.test_utilities.ensureTotalCapacity(self.allocator, self.test_utilities.items.len + extension.test_utilities.len);
    }
};

fn appendSliceAssumeCapacity(comptime T: type, list: *std.ArrayListUnmanaged(T), items: []const T) void {
    for (items) |item| {
        list.appendAssumeCapacity(item);
    }
}

const fake_dialect_name = "external_fake";
const fake_op_name = "external_fake.op";

var fake_pass_runs: usize = 0;
var fake_pipeline_pass_runs: usize = 0;
var fake_before_pass_runs: usize = 0;
var fake_verify_runs: usize = 0;
var fake_test_utilities_installed: usize = 0;
var fake_translation_runs: usize = 0;

fn resetFakeCounters() void {
    fake_pass_runs = 0;
    fake_pipeline_pass_runs = 0;
    fake_before_pass_runs = 0;
    fake_verify_runs = 0;
    fake_test_utilities_installed = 0;
    fake_translation_runs = 0;
}

test "Choir optimization package extension registers pass entries" {
    const allocator = std.testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var registry = ExtensionRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerPackage(&ctx, choir_optimization_package_extension);

    try std.testing.expectEqual(@as(usize, 1), registry.packages.items.len);
    try std.testing.expectEqual(@as(usize, passes.optimization_pass_registrations.len), registry.passes.items.len);
    try std.testing.expectEqual(@as(usize, passes.optimization_pipeline_registrations.len), registry.pipelines.items.len);

    var pass_registry = passes.PassRegistry.init(allocator);
    defer pass_registry.deinit();
    try registry.registerPassEntriesTo(&pass_registry);

    try std.testing.expect(pass_registry.lookupPass(passes.canonicalization_pass_name) != null);
    try std.testing.expect(pass_registry.lookupPass(passes.sparse_conditional_constant_propagation_pass_name) != null);
    try std.testing.expect(pass_registry.lookupPass(passes.common_subexpression_elimination_pass_name) != null);
    try std.testing.expect(pass_registry.lookupPass(passes.dead_store_elimination_pass_name) != null);
    try std.testing.expect(pass_registry.lookupPipeline(passes.default_optimization_pipeline_name) != null);

    var manager = passes.PassManager.init(allocator);
    defer manager.deinit();
    try passes.parsePassPipeline(&pass_registry, passes.default_optimization_pipeline_name, &manager);
    try std.testing.expectEqual(@as(usize, 11), manager.root.pipeline.items.len);
}

fn loadFakeDialect(ctx: *ir.Context) !void {
    _ = try ctx.registerOperation(fake_op_name, .{});
    _ = try ctx.registerType("external_fake.type");
}

fn verifyFakeOp(_: *const anyopaque) anyerror!void {
    fake_verify_runs += 1;
}

fn extendFakeDialect(ctx: *ir.Context) !void {
    try ctx.registerOperationInterfaceExternal(fake_op_name, ir.VerifyOpInterface.entryFor(verifyFakeOp));
}

fn runFakePass(ctx: *passes.PassContext) passes.PassResult {
    fake_pass_runs += 1;
    ctx.markModified();
    return .success;
}

fn runFakePipelinePass(ctx: *passes.PassContext) passes.PassResult {
    fake_pipeline_pass_runs += 1;
    ctx.preserveAllAnalyses();
    return .success;
}

fn buildFakePipeline(manager: *passes.OpPassManager) anyerror!void {
    try manager.addPass(.{
        .name = "external-fake-pipeline-pass",
        .description = "fake external package pipeline pass",
        .run_fn = runFakePipelinePass,
    });
}

fn beforeFakePass(_: ?*anyopaque, _: passes.PassInfo) void {
    fake_before_pass_runs += 1;
}

fn configureFakeTarget(target: *passes.ConversionTarget) anyerror!void {
    try target.addLegalDialect(fake_dialect_name);
}

fn rewriteFake(_: *ir.Operation, _: *rewrite.PatternRewriter) rewrite.PatternResult {
    return .success;
}

fn populateFakePatterns(patterns: *rewrite.RewritePatternSet) anyerror!void {
    try patterns.add(rewrite.RewritePattern.init(.{
        .name = "external-fake-rewrite",
        .root_op_name = fake_op_name,
        .benefit = 3,
        .products = .none,
    }, rewriteFake));
}

fn installFakeTestUtility(_: *TestUtilityContext) anyerror!void {
    fake_test_utilities_installed += 1;
}

const FakeBackendTranslation = struct {
    pub fn emitBytes(result_allocator: Allocator, request: translation_mod.Request) anyerror![]u8 {
        _ = request;
        fake_translation_runs += 1;
        return result_allocator.dupe(u8, "external-fake-bytes");
    }
};

const fake_backend_translation = translation_mod.registration(FakeBackendTranslation, .{
    .name = "external-fake-binary",
    .target_dialect_name = fake_dialect_name,
    .format_name = "fake-binary",
});

test "external package registers dialects passes conversions translations and test utilities" {
    resetFakeCounters();

    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try ctx.requireRegistered();

    var registry = ExtensionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const fake_pass = passes.Pass{
        .name = "external-fake-pass",
        .description = "fake external package pass",
        .run_fn = runFakePass,
    };

    const fake_extension = PackageExtension{
        .name = "external-fake-package",
        .dialects = &.{
            .{ .name = fake_dialect_name, .load = loadFakeDialect },
        },
        .dialect_extensions = &.{
            .{ .dialect_name = fake_dialect_name, .extend = extendFakeDialect },
        },
        .passes = &.{
            .{
                .name = "external-fake-pass",
                .description = "fake external package pass",
                .pass = fake_pass,
            },
        },
        .pipelines = &.{
            .{
                .name = "external-fake-pipeline",
                .description = "fake external package pipeline",
                .build = buildFakePipeline,
            },
        },
        .conversions = &.{
            .{
                .name = "external-fake-conversion",
                .configure_target = configureFakeTarget,
                .populate_patterns = populateFakePatterns,
            },
        },
        .instrumentations = &.{
            .{ .runBeforePass = beforeFakePass },
        },
        .backend_translations = &.{
            fake_backend_translation,
        },
        .test_utilities = &.{
            .{ .name = "external-fake-test-utility", .install = installFakeTestUtility },
        },
    };

    try registry.registerPackage(&ctx, fake_extension);
    try std.testing.expectEqual(@as(usize, 1), registry.packages.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.pipelines.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.backend_translations.items.len);
    try std.testing.expect(ctx.lookupOperation(fake_op_name) == null);

    _ = try ctx.getOrLoadDialect(fake_dialect_name);
    try std.testing.expect(ctx.lookupOperation(fake_op_name) != null);
    try std.testing.expect(ctx.lookupType("external_fake.type") != null);

    const op = try ctx.createOperation(ir.Operation.State.init(fake_op_name, .unknown));
    try ir.verifyOperation(op, ir.verify.default_options);
    try std.testing.expectEqual(@as(usize, 1), fake_verify_runs);

    var manager = passes.PassManager.init(std.testing.allocator);
    defer manager.deinit();
    try registry.addInstrumentationsTo(&manager);
    try registry.addPassesTo(&manager);

    try std.testing.expectEqual(passes.PassResult.success, manager.run(op, &ctx));
    try std.testing.expectEqual(@as(usize, 1), fake_before_pass_runs);
    try std.testing.expectEqual(@as(usize, 1), fake_pass_runs);

    var pipeline_registry = passes.PipelineRegistry.init(std.testing.allocator);
    defer pipeline_registry.deinit();
    try registry.registerPipelinesTo(&pipeline_registry);
    try std.testing.expect(pipeline_registry.lookup("external-fake-pipeline") != null);

    var pass_registry = passes.PassRegistry.init(std.testing.allocator);
    defer pass_registry.deinit();
    try registry.registerPassEntriesTo(&pass_registry);
    try std.testing.expect(pass_registry.lookupPass("external-fake-pass") != null);
    try std.testing.expect(pass_registry.lookupPipeline("external-fake-pipeline") != null);

    var pipeline_manager = passes.PassManager.init(std.testing.allocator);
    defer pipeline_manager.deinit();
    try registry.addPipelineTo("external-fake-pipeline", &pipeline_manager);
    try std.testing.expectEqual(passes.PassResult.success, pipeline_manager.run(op, &ctx));
    try std.testing.expectEqual(@as(usize, 1), fake_pipeline_pass_runs);

    var target = passes.ConversionTarget.init(std.testing.allocator);
    defer target.deinit();
    var patterns = rewrite.RewritePatternSet.init(std.testing.allocator);
    defer patterns.deinit();
    var type_converter = rewrite.TypeConverter.init(std.testing.allocator);
    defer type_converter.deinit();
    try registry.configureConversion(&target, &patterns, &type_converter);
    try std.testing.expect(target.isLegal(op));
    try std.testing.expectEqual(@as(usize, 1), patterns.patterns.items.len);

    var translation_registry = translation_mod.Registry.init(std.testing.allocator);
    defer translation_registry.deinit();
    try registry.registerBackendTranslationsTo(&translation_registry);
    try std.testing.expect(translation_registry.lookup("external-fake-binary") != null);

    const translated = try translation_registry.emitBytes(std.testing.allocator, fake_dialect_name, "fake-binary", .{ .module = op });
    defer std.testing.allocator.free(translated);
    try std.testing.expectEqualStrings("external-fake-bytes", translated);
    try std.testing.expectEqual(@as(usize, 1), fake_translation_runs);

    var utility_ctx = TestUtilityContext{
        .allocator = std.testing.allocator,
        .ir_ctx = &ctx,
        .registry = &registry,
    };
    try registry.installTestUtilities(&utility_ctx);
    try std.testing.expectEqual(@as(usize, 1), fake_test_utilities_installed);
}
