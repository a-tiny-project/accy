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
        module.observed_fingerprint = try choir.operationFingerprint(
            allocator,
            module.choir_module,
        );
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
