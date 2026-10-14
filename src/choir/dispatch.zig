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
        module.observed_fingerprint = try choir.operationFingerprint(
            allocator,
            module.choir_module,
        );
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
