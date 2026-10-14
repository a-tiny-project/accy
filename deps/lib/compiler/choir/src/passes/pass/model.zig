const std = @import("std");
const ir = @import("../../core/root.zig");

pub const PassMutationScope = enum {
    read_only,
    isolated,
    whole_module,
};

pub const PassStateConcurrency = enum {
    exclusive,
    shared,
};

pub const PassRerunPolicy = enum {
    always,
    skip_if_unchanged,
};

pub const DependentDialects = []const []const u8;

pub fn dialectDependencies(comptime names: DependentDialects) DependentDialects {
    comptime {
        for (names, 0..) |name, index| {
            if (name.len == 0) @compileError("dependent dialect name cannot be empty");
            for (names[0..index]) |prior| {
                if (std.mem.eql(u8, name, prior)) @compileError("duplicate dependent dialect name");
            }
        }
    }
    return names;
}

pub const PassManagerRunOptions = ir.ThreadingOptions;

pub const PassManagerFixedPointResult = struct {
    result: PassResult = .success,
    iterations: usize = 0,
    changed: bool = false,
};

pub const AnalysisId = u64;

pub fn analysisId(comptime name: []const u8) AnalysisId {
    return ir.interfaceId(name);
}

pub const PassManagerStats = struct {
    pass_runs: u64 = 0,
    passes_skipped: u64 = 0,
    pass_failures: u64 = 0,
    verifier_failures: u64 = 0,
    passes_modified: u64 = 0,
    analysis_hits: u64 = 0,
    analysis_misses: u64 = 0,
    analyses_invalidated: u64 = 0,

    pub fn reset(self: *PassManagerStats) void {
        self.* = .{};
    }
};

pub const PassVerifierFailure = struct {
    pass_name: []const u8,
    target_op_name: []const u8,
    err: anyerror,
};

pub const PassFailureKind = enum {
    pass,
    verifier,
    target,
    exhausted,
};

pub const PassFailureReproducer = struct {
    pipeline: []const u8,
    ir: []const u8,
    max_threads: usize,
    worker_count: usize,
    verifier_enabled: bool,
    failure_kind: ?PassFailureKind = null,
    pass_name: ?[]const u8 = null,
    target_op_name: ?[]const u8 = null,
    target_symbol_name: ?[]const u8 = null,
    verifier_error: ?anyerror = null,
    verifier_error_name: ?[]const u8 = null,

    pub fn deinit(self: *PassFailureReproducer, allocator: std.mem.Allocator) void {
        allocator.free(self.pipeline);
        allocator.free(self.ir);
        if (self.pass_name) |name| allocator.free(name);
        if (self.target_op_name) |name| allocator.free(name);
        if (self.target_symbol_name) |name| allocator.free(name);
        if (self.verifier_error_name) |name| allocator.free(name);
        self.* = undefined;
    }
};

pub const PassResult = enum {
    success,
    failure,
};
