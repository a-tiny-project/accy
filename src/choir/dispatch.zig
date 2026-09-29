const std = @import("std");
const choir = @import("choir");
const contract = @import("contract.zig");
const semantic = @import("semantic.zig");
const tensor = @import("tensor.zig");

const ir = choir.ir;
const passes = choir.passes;

pub const product_name = "accy.dispatch";

pub const DispatchModule = @import("root.zig").publication.Module(.dispatch);

pub const DispatchJob = struct {
    allocator: std.mem.Allocator,
    tensor_module: *tensor.TensorJob,
    choir_module: *ir.Operation,
    observed_fingerprint: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        tensor_module: *tensor.TensorJob,
    ) !*DispatchJob {
        const module = try allocator.create(DispatchJob);
        errdefer allocator.destroy(module);
        module.* = .{
            .allocator = allocator,
            .tensor_module = tensor_module,
            .choir_module = tensor_module.choir_module,
            .observed_fingerprint = 0,
        };
        try module.verify();
        module.observed_fingerprint = try choir.operationFingerprint(allocator, module.choir_module);
        return module;
    }

    pub fn context(self: *DispatchJob) *ir.Context {
        return self.tensor_module.context();
    }

    pub fn deinit(self: *DispatchJob) void {
        self.tensor_module.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn verify(self: *DispatchJob) !void {
        try self.tensor_module.verify();
    }

    pub fn fingerprint(self: *const DispatchJob) u64 {
        return self.observed_fingerprint;
    }

    pub fn passContext(self: *DispatchJob) passes.PassContext {
        return self.tensor_module.passContext();
    }
};

test "dispatch module owns tensor product" {
    const allocator = std.testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();

    const ty = try builder.tensor(.f32, &.{4});
    var function = try builder.beginFunction("dispatch_add", &.{ ty, ty }, &.{ty});
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

    var dispatch_module = try DispatchJob.init(allocator, tensor_module);
    tensor_owned = false;
    defer dispatch_module.deinit();

    try std.testing.expectEqualStrings(product_name, "accy.dispatch");
    try dispatch_module.verify();
    try std.testing.expectEqual(try choir.operationFingerprint(allocator, dispatch_module.choir_module), dispatch_module.fingerprint());
}
