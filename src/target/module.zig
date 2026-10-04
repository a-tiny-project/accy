const std = @import("std");
const choir = @import("choir");
const accy_choir = @import("../choir/root.zig");
const kernelization = @import("../preparation/kernelization/model/root.zig");
const contract = accy_choir.contract;
const dispatch = accy_choir.dispatch;
const kernel_product = accy_choir.gpu;
const memory = accy_choir.memory;
const semantic = accy_choir.semantic;
const tensor = accy_choir.tensor;

const ir = choir.ir;
const passes = choir.passes;

pub const product_name = "accy.target";

pub const TargetModule = accy_choir.publication.Module(.target);

pub const TargetJob = struct {
    allocator: std.mem.Allocator,
    kernel_module: *kernel_product.KernelJob,
    choir_module: *ir.Operation,
    analysis_cache: passes.AnalysisCache,
    kernelization_product: *const kernelization.KernelizationAnalysis,
    observed_fingerprint: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        kernel_module: *kernel_product.KernelJob,
        choir_module: *ir.Operation,
        analysis_cache: passes.AnalysisCache,
        kernelization_product: *const kernelization.KernelizationAnalysis,
    ) !*TargetJob {
        const target_module = try allocator.create(TargetJob);
        errdefer allocator.destroy(target_module);
        target_module.* = .{
            .allocator = allocator,
            .kernel_module = kernel_module,
            .choir_module = choir_module,
            .analysis_cache = analysis_cache,
            .kernelization_product = kernelization_product,
            .observed_fingerprint = 0,
        };
        try target_module.verify();
        target_module.observed_fingerprint = try choir.operationFingerprint(
            allocator,
            target_module.choir_module,
        );
        return target_module;
    }

    pub fn context(self: *TargetJob) *ir.Context {
        return self.kernel_module.context();
    }

    pub fn deinit(self: *TargetJob) void {
        self.analysis_cache.deinit();
        if (self.choir_module != self.kernel_module.choir_module) self.choir_module.erase();
        self.kernel_module.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn verify(self: *TargetJob) !void {
        try self.kernel_module.verify();
        try ir.verifyOperation(self.choir_module, ir.verify.default_options);
    }

    pub fn fingerprint(self: *const TargetJob) u64 {
        return self.observed_fingerprint;
    }

    pub fn kernelizationProduct(self: *const TargetJob) *const kernelization.KernelizationAnalysis {
        return self.kernelization_product;
    }

    pub fn passContext(self: *TargetJob) passes.PassContext {
        return passes.PassContext.init(
            self.choir_module,
            self.context(),
            self.allocator,
            &self.analysis_cache,
        );
    }
};

test "target module owns kernel product" {
    const allocator = std.testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();

    const ty = try builder.tensor(.f32, &.{4});
    var function = try builder.beginFunction("target_add", &.{ ty, ty }, &.{ty});
    const sum = try function.add(function.parameter(0), function.parameter(1));
    try function.return_(&.{sum});
    try function.finish();

    const semantic_module = try builder.finish();
    var contract_module = try contract.ContractJob.init(allocator, semantic_module);
    var contract_owned = true;
    errdefer if (contract_owned) contract_module.deinit();

    var analysis_cache = passes.AnalysisCache.init(allocator, null);
    var cache_owned = true;
    errdefer if (cache_owned) analysis_cache.deinit();

    var tensor_module = try tensor.TensorJob.init(allocator, contract_module, analysis_cache);
    contract_owned = false;
    cache_owned = false;
    var tensor_owned = true;
    errdefer if (tensor_owned) tensor_module.deinit();

    var dispatch_module = try dispatch.DispatchJob.init(allocator, tensor_module);
    tensor_owned = false;
    var dispatch_owned = true;
    errdefer if (dispatch_owned) dispatch_module.deinit();

    var memory_module = try memory.MemoryJob.init(allocator, dispatch_module);
    dispatch_owned = false;
    var memory_owned = true;
    errdefer if (memory_owned) memory_module.deinit();

    var kernel_module = try kernel_product.KernelJob.init(allocator, memory_module);
    memory_owned = false;
    var kernel_owned = true;
    errdefer if (kernel_owned) kernel_module.deinit();

    var kernelization_product = try kernelization.KernelizationAnalysis.init(
        allocator,
        kernel_module.choir_module.context.capacity.asLimits(),
    );
    defer kernelization_product.deinit();

    const target_choir_module = try kernel_module.choir_module.clone();
    var target_choir_module_owned = true;
    errdefer if (target_choir_module_owned) target_choir_module.erase();

    var target_analysis_cache = passes.AnalysisCache.init(allocator, null);
    var target_cache_owned = true;
    errdefer if (target_cache_owned) target_analysis_cache.deinit();

    var target_module = try TargetJob.init(
        allocator,
        kernel_module,
        target_choir_module,
        target_analysis_cache,
        &kernelization_product,
    );
    kernel_owned = false;
    target_choir_module_owned = false;
    target_cache_owned = false;
    defer target_module.deinit();

    try std.testing.expectEqualStrings(product_name, "accy.target");
    try target_module.verify();
    try std.testing.expect(target_module.choir_module != target_module.kernel_module.choir_module);
    try std.testing.expectEqual(
        try choir.operationFingerprint(allocator, target_module.choir_module),
        target_module.fingerprint(),
    );
    try std.testing.expectEqual(
        target_module.kernel_module.fingerprint(),
        try choir.operationFingerprint(allocator, target_module.kernel_module.choir_module),
    );
    try std.testing.expectEqual(@as(usize, 0), target_module.kernelizationProduct().kernelCount());
}
