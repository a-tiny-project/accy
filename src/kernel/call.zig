const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const gpu_codegen = choir.backends.gpu;
const artifact_product = @import("../artifact/root.zig");
const target = @import("../target/root.zig");
const kernel_model = @import("model/root.zig");
const builder = kernel_model.core.builder;
const plan_mod = kernel_model.plan;
const program_mod = @import("program/root.zig");

pub const product_name = "accy.kernel_call";

pub const Options = struct {
    target: []const u8,
    version: u32 = 1,
    format: ?gpu.ArtifactFormat = null,
    kernel_plan: plan_mod.Options = .{},
    element_count_argument: artifact_product.ElementCountArgument = .none,
    shape_family_fingerprint: ?u64 = null,
    shape_profile: ?artifact_product.KernelCallShapeProfile = null,
    launch: ?artifact_product.KernelCallLaunch = null,
    runtime_scalar_argument_count: u32 = 0,
    static_arguments: []const gpu_abi.ScalarArgument = &.{},
};

pub const OwnedArtifact = struct {
    allocator: std.mem.Allocator,
    artifacts: [1]artifact_product.KernelCallArtifact,

    pub fn entry(self: *const OwnedArtifact) artifact_product.KernelCallArtifact {
        return self.artifacts[0];
    }

    pub fn registry(self: *const OwnedArtifact) artifact_product.KernelCallRegistry {
        return .{ .entries = self.artifacts[0..] };
    }

    pub fn fingerprint(self: *const OwnedArtifact) u64 {
        const registry_value = self.registry();
        return artifact_product.kernelCallRegistryFingerprint(&registry_value);
    }

    pub fn productStamp(self: *const OwnedArtifact) choir.product.incremental.ProductStamp {
        return choir.product.incremental.productStamp(product_name, self.fingerprint());
    }

    pub fn deinit(self: *OwnedArtifact) void {
        const allocator = self.allocator;
        const artifact = &self.artifacts[0];
        allocator.free(@constCast(artifact.target));
        allocator.free(@constCast(artifact.entry_name));
        if (artifact.shape_profile) |profile| {
            artifact_product.deinitKernelCallShapeProfile(allocator, profile);
        }
        if (artifact.static_arguments.len != 0) {
            allocator.free(@constCast(artifact.static_arguments));
        }
        deinitCompilePayload(allocator, artifact.payload);
        self.* = undefined;
    }
};

pub fn createBackendArtifactFromEntry(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    entry: artifact_product.KernelCallArtifact,
    diagnostic_id: ?[]const u8,
) !gpu.KernelArtifact {
    const caps = try handle.queryCapabilities();
    const scalar_argument_count = try entry.scalarArgumentCount();
    var artifact = try gpu.KernelArtifact.init(allocator, .{
        .backend = handle.backendKind() orelse caps.identity.backend,
        .format = entry.format,
        .entry_name = entry.entry_name,
        .argument_count = entry.argument_count,
        .scalar_argument_count = scalar_argument_count,
        .diagnostic_id = diagnostic_id,
        .interface = .{
            .features = entry.required_features,
            .subgroup = entry.required_subgroup,
            .push_constants = entry.push_constants,
        },
    });
    errdefer artifact.deinit();
    switch (entry.payload) {
        .text => |text| artifact.setBorrowedText(text),
        .bytes => |bytes| artifact.setBorrowedBytes(bytes),
        .words_u32 => |words| artifact.setBorrowedWords(words),
        .none => return error.InvalidArtifact,
    }
    return artifact;
}

pub fn launchGeometryForEntry(
    entry: artifact_product.KernelCallArtifact,
    runtime_arguments: []const gpu_abi.ScalarArgument,
) gpu.BackendError!gpu_abi.LaunchGeometry {
    return switch (entry.launch) {
        .fixed => |geometry| geometry,
        .derived => |derived| try derived.geometry(runtime_arguments),
    };
}

pub fn createArtifact(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    program: *program_mod.Program,
    options: Options,
) !OwnedArtifact {
    if (options.target.len == 0 or options.version == 0) return error.InvalidArtifact;

    var authored_plan = try program.createCheckedPlan(allocator, options.kernel_plan);
    defer authored_plan.deinit();

    const caps = try handle.queryCapabilities();
    const backend_kind = handle.backendKind() orelse caps.identity.backend;
    const format = options.format orelse
        artifact_product.defaultArtifactFormat(backend_kind) orelse {
        return error.UnsupportedOperation;
    };
    if (!caps.supportsArtifactFormat(format)) return error.UnsupportedArtifactFormat;
    const geometry = launchGeometry(&authored_plan);
    try caps.validateLaunchGeometry(geometry);

    const compilation = try target.compileKernelForArtifactFormat(
        allocator,
        format,
        authored_plan.entry_name,
        program.kernelModule(),
        compileOptions(format, geometry),
    );
    errdefer deinitCompilePayload(allocator, compilation.payload);

    const owned_target = try allocator.dupe(u8, options.target);
    errdefer allocator.free(owned_target);
    const owned_entry_name = try allocator.dupe(u8, authored_plan.entry_name);
    errdefer allocator.free(owned_entry_name);
    const static_arguments = try compileStaticArguments(
        allocator,
        format,
        geometry,
        options.static_arguments,
    );
    errdefer if (static_arguments.len != 0) allocator.free(static_arguments);

    const shape_family_fingerprint = options.shape_family_fingerprint orelse
        if (options.shape_profile) |profile| profile.fingerprint else null;
    if (options.shape_profile) |profile| {
        if (shape_family_fingerprint.? != profile.fingerprint) return error.InvalidArtifact;
        try profile.validate(options.runtime_scalar_argument_count);
    }
    const shape_profile = if (options.shape_profile) |profile|
        try artifact_product.duplicateKernelCallShapeProfile(allocator, profile)
    else
        null;
    errdefer if (shape_profile) |profile| artifact_product.deinitKernelCallShapeProfile(
        allocator,
        profile,
    );

    return .{
        .allocator = allocator,
        .artifacts = .{.{
            .target = owned_target,
            .version = options.version,
            .format = format,
            .entry_name = owned_entry_name,
            .argument_count = try compileArgumentCount(format, authored_plan.argument_count),
            .shape_family_fingerprint = shape_family_fingerprint,
            .shape_profile = shape_profile,
            .required_dtypes = requiredDTypesForParams(authored_plan.params),
            .required_features = gpu_codegen.featureRequirementsForModule(program.kernelModule()),
            .required_subgroup = gpu_codegen.subgroupRequirementsForModule(program.kernelModule()),
            .push_constants = compilation.push_constants,
            .payload = compilation.payload,
            .launch = options.launch orelse .{ .fixed = geometry },
            .element_count_argument = options.element_count_argument,
            .runtime_scalar_argument_count = options.runtime_scalar_argument_count,
            .static_arguments = static_arguments,
        }},
    };
}

fn compileOptions(
    format: gpu.ArtifactFormat,
    geometry: gpu_abi.LaunchGeometry,
) target.CompileOptions {
    const element_count = geometry.threadCount() catch return .{};
    return target.compileOptionsForArtifactFormat(format, element_count);
}

fn compileArgumentCount(format: gpu.ArtifactFormat, argument_count: u32) gpu.BackendError!u32 {
    if (!gpu.artifactFormatUsesHostLoopLaunch(format)) return argument_count;
    return gpu_abi.kernelArgumentCount(argument_count);
}

fn compileStaticArguments(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    geometry: gpu_abi.LaunchGeometry,
    static_arguments: []const gpu_abi.ScalarArgument,
) gpu.BackendError![]gpu_abi.ScalarArgument {
    if (!gpu.artifactFormatUsesHostLoopLaunch(format)) {
        return allocator.dupe(
            gpu_abi.ScalarArgument,
            static_arguments,
        ) catch return error.OutOfMemory;
    }
    if (static_arguments.len != 0) return error.InvalidArtifact;
    return gpu_abi.launchShapeArguments(
        allocator,
        geometry.threadCount() catch return error.InvalidArtifact,
        geometry,
    );
}

fn requiredDTypesForParams(params: []const builder.Param) gpu.DTypeSet {
    var dtypes: gpu.DTypeSet = .{};
    for (params) |param| {
        switch (param) {
            .scalar => |dtype| dtypes.insert(dtype),
            .buffer => |buffer| dtypes.insert(buffer.dtype),
        }
    }
    return dtypes;
}

fn launchGeometry(authored_plan: *const plan_mod.Plan) gpu_abi.LaunchGeometry {
    return .{
        .grid = authored_plan.launch.grid,
        .threadgroup = authored_plan.launch.block,
    };
}

fn deinitCompilePayload(allocator: std.mem.Allocator, payload: gpu.CompilePayload) void {
    switch (payload) {
        .bytes => |bytes| allocator.free(@constCast(bytes)),
        .words_u32 => |words| allocator.free(@constCast(words)),
        .text => |text| allocator.free(@constCast(text)),
        .none => {},
    }
}
