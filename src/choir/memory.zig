const std = @import("std");
const choir = @import("choir");
const contract = @import("contract.zig");
const dispatch = @import("dispatch.zig");
const semantic = @import("semantic.zig");
const tensor = @import("tensor.zig");

const ir = choir.ir;
const passes = choir.passes;

pub const product_name = "accy.memory";

pub const MemoryModule = @import("root.zig").publication.Module(.memory);

pub const MemoryJob = struct {
    allocator: std.mem.Allocator,
    dispatch_module: *dispatch.DispatchJob,
    choir_module: *ir.Operation,
    observed_fingerprint: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        dispatch_module: *dispatch.DispatchJob,
    ) !*MemoryJob {
        const module = try allocator.create(MemoryJob);
        errdefer allocator.destroy(module);
        module.* = .{
            .allocator = allocator,
            .dispatch_module = dispatch_module,
            .choir_module = dispatch_module.choir_module,
            .observed_fingerprint = 0,
        };
        try module.verify();
        module.observed_fingerprint = try choir.operationFingerprint(allocator, module.choir_module);
        return module;
    }

    pub fn context(self: *MemoryJob) *ir.Context {
        return self.dispatch_module.context();
    }

    pub fn deinit(self: *MemoryJob) void {
        self.dispatch_module.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn verify(self: *MemoryJob) !void {
        try self.dispatch_module.verify();
    }

    pub fn fingerprint(self: *const MemoryJob) u64 {
        return self.observed_fingerprint;
    }

    pub fn passContext(self: *MemoryJob) passes.PassContext {
        return self.dispatch_module.passContext();
    }
};

test "memory module owns dispatch product" {
    const allocator = std.testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();

    const ty = try builder.tensor(.f32, &.{4});
    var function = try builder.beginFunction("memory_add", &.{ ty, ty }, &.{ty});
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

    var memory_module = try MemoryJob.init(allocator, dispatch_module);
    dispatch_owned = false;
    defer memory_module.deinit();

    try std.testing.expectEqualStrings(product_name, "accy.memory");
    try memory_module.verify();
    try std.testing.expectEqual(try choir.operationFingerprint(allocator, memory_module.choir_module), memory_module.fingerprint());
}
