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
