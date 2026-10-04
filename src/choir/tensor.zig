const std = @import("std");
const choir = @import("choir");
const contract = @import("contract.zig");
const semantic = @import("semantic.zig");

const ir = choir.ir;
const passes = choir.passes;

pub const product_name = "accy.tensor_opt";

pub const TensorModule = @import("root.zig").publication.Module(.tensor);

pub const TensorJob = struct {
    allocator: std.mem.Allocator,
    contract_module: *contract.ContractJob,
    choir_module: *ir.Operation,
    analysis_cache: passes.AnalysisCache,
    observed_fingerprint: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        contract_module: *contract.ContractJob,
        analysis_cache: passes.AnalysisCache,
    ) !*TensorJob {
        const module = try allocator.create(TensorJob);
        errdefer allocator.destroy(module);
        module.* = .{
            .allocator = allocator,
            .contract_module = contract_module,
            .choir_module = contract_module.choir_module,
            .analysis_cache = analysis_cache,
            .observed_fingerprint = 0,
        };
        try module.verify();
        module.observed_fingerprint = try choir.operationFingerprint(
            allocator,
            module.choir_module,
        );
        return module;
    }

    pub fn context(self: *TensorJob) *ir.Context {
        return self.contract_module.context();
    }

    pub fn deinit(self: *TensorJob) void {
        self.analysis_cache.deinit();
        self.contract_module.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn verify(self: *TensorJob) !void {
        try self.contract_module.verify();
        try contract.verifyAllowedDialects(self.choir_module);
    }

    pub fn fingerprint(self: *const TensorJob) u64 {
        return self.observed_fingerprint;
    }

    pub fn passContext(self: *TensorJob) passes.PassContext {
        return passes.PassContext.init(
            self.choir_module,
            self.context(),
            self.allocator,
            &self.analysis_cache,
        );
    }
};
