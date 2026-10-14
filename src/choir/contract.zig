const std = @import("std");
const choir = @import("choir");
const semantic = @import("semantic.zig");

const ir = choir.ir;

pub const product_name = "accy.contract";

pub const allowed_dialects = [_][]const u8{
    "builtin",
    "func",
    "accy",
};

pub const ContractError = error{
    UnregisteredOperation,
    UnsupportedDialect,
};

pub const ContractModule = @import("root.zig").publication.Module(.contract);

pub const ContractJob = struct {
    allocator: std.mem.Allocator,
    semantic_module: *semantic.SemanticModule,
    choir_module: *ir.Operation,
    observed_fingerprint: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        semantic_module: *semantic.SemanticModule,
    ) !*ContractJob {
        const module = try allocator.create(ContractJob);
        errdefer allocator.destroy(module);
        module.* = .{
            .allocator = allocator,
            .semantic_module = semantic_module,
            .choir_module = semantic_module.choir_module,
            .observed_fingerprint = 0,
        };
        try module.verify();
        module.observed_fingerprint = try choir.operationFingerprint(
            allocator,
            module.choir_module,
        );
        return module;
    }

    pub fn context(self: *ContractJob) *ir.Context {
        return self.semantic_module.context();
    }

    pub fn deinit(self: *ContractJob) void {
        self.semantic_module.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn verify(self: *ContractJob) !void {
        try self.semantic_module.verify();
        try verifyAllowedDialects(self.choir_module);
    }

    pub fn fingerprint(self: *const ContractJob) u64 {
        return self.observed_fingerprint;
    }
};

pub fn verifyAllowedDialects(module: *ir.Operation) !void {
    var verifier = AllowedDialectVerifier{};
    const result = try module.walk(
        .{ .order = .pre_order },
        &verifier,
        AllowedDialectVerifier.visit,
    );
    if (result.wasInterrupted()) return error.UnsupportedDialect;
}

const AllowedDialectVerifier = struct {
    fn visit(_: *AllowedDialectVerifier, op: *ir.Operation) !ir.WalkResult {
        _ = op.name.resolveRegisteredInfo(op.context) orelse return error.UnregisteredOperation;
        if (!isAllowedDialect(op.name.getDialectNamespace())) return error.UnsupportedDialect;
        return .advance;
    }
};

fn isAllowedDialect(name: []const u8) bool {
    inline for (allowed_dialects) |allowed| {
        if (std.mem.eql(u8, name, allowed)) return true;
    }
    return false;
}

fn bodyBlock(module: *ir.Operation) *ir.Block {
    return module.getRegion(0).?.getEntryBlock().?;
}
