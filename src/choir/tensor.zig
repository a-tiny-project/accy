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
        module.observed_fingerprint = try choir.operationFingerprint(allocator, module.choir_module);
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
        return passes.PassContext.init(self.choir_module, self.context(), self.allocator, &self.analysis_cache);
    }
};

test "tensor module owns contract product and analysis cache" {
    const allocator = std.testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();

    const ty = try builder.tensor(.f32, &.{4});
    var function = try builder.beginFunction("tensor_add", &.{ ty, ty }, &.{ty});
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

    var tensor_module = try TensorJob.init(allocator, contract_module, analysis_cache);
    contract_owned = false;
    cache_owned = false;
    defer tensor_module.deinit();

    try std.testing.expectEqualStrings(product_name, "accy.tensor_opt");
    try tensor_module.verify();
    try std.testing.expectEqual(try choir.operationFingerprint(allocator, tensor_module.choir_module), tensor_module.fingerprint());
}
