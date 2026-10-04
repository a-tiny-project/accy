const std = @import("std");
const choir = @import("choir");
const contract = @import("contract.zig");
const dispatch = @import("dispatch.zig");
const memory = @import("memory.zig");
const semantic = @import("semantic.zig");
const tensor = @import("tensor.zig");

const ir = choir.ir;
const passes = choir.passes;

pub const product_name = "accy.kernel/gpu";

pub const KernelModule = @import("root.zig").publication.Module(.kernel);

pub const KernelJob = struct {
    allocator: std.mem.Allocator,
    memory_module: *memory.MemoryJob,
    choir_module: *ir.Operation,
    observed_fingerprint: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        memory_module: *memory.MemoryJob,
    ) !*KernelJob {
        const module = try allocator.create(KernelJob);
        errdefer allocator.destroy(module);
        module.* = .{
            .allocator = allocator,
            .memory_module = memory_module,
            .choir_module = memory_module.choir_module,
            .observed_fingerprint = 0,
        };
        try module.verify();
        module.observed_fingerprint = try choir.operationFingerprint(
            allocator,
            module.choir_module,
        );
        return module;
    }

    pub fn context(self: *KernelJob) *ir.Context {
        return self.memory_module.context();
    }

    pub fn deinit(self: *KernelJob) void {
        self.memory_module.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn verify(self: *KernelJob) !void {
        try self.memory_module.verify();
    }

    pub fn fingerprint(self: *const KernelJob) u64 {
        return self.observed_fingerprint;
    }

    pub fn passContext(self: *KernelJob) passes.PassContext {
        return self.memory_module.passContext();
    }
};

test "kernel module owns memory product" {
    const allocator = std.testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();

    const ty = try builder.tensor(.f32, &.{4});
    var function = try builder.beginFunction("kernel_add", &.{ ty, ty }, &.{ty});
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

    var kernel_module = try KernelJob.init(allocator, memory_module);
    memory_owned = false;
    defer kernel_module.deinit();

    try std.testing.expectEqualStrings(product_name, "accy.kernel/gpu");
    try kernel_module.verify();
    try std.testing.expectEqual(
        try choir.operationFingerprint(allocator, kernel_module.choir_module),
        kernel_module.fingerprint(),
    );
}
