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
