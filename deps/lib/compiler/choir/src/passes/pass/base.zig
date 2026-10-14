const std = @import("std");
const subject = @import("root.zig");

const DependentDialects = subject.DependentDialects;
const PassContext = subject.PassContext;
const PassMutationScope = subject.PassMutationScope;
const PassRerunPolicy = subject.PassRerunPolicy;
const PassResult = subject.PassResult;
const PassStateConcurrency = subject.PassStateConcurrency;

pub const Pass = struct {
    work_contract: ?subject.work.Contract = null,

    name: []const u8,

    description: []const u8,

    run_fn: ?*const fn (*PassContext) PassResult = null,

    state: ?*anyopaque = null,

    run_with_state_fn: ?*const fn (?*anyopaque, *PassContext) PassResult = null,

    state_concurrency: PassStateConcurrency = .exclusive,

    rerun_policy: PassRerunPolicy = .always,

    /// Makes an independent copy of `state` for a parallel match. The pass manager calls it
    /// before dispatch for each lane, and again from a lane before every match after that lane's
    /// first. Calls never overlap: the callback has exclusive access to the original state for
    /// its duration, though it may run on any lane's thread. Runs on the clones it returns may
    /// overlap one another.
    state_clone_fn: ?*const fn (?*anyopaque, std.mem.Allocator) anyerror!?*anyopaque = null,

    state_deinit_fn: ?*const fn (?*anyopaque, std.mem.Allocator) void = null,

    mutation_scope: PassMutationScope = .whole_module,

    dependent_dialects: DependentDialects = &.{},

    textual_options: ?[]const u8 = null,

    owns_textual_options: bool = false,

    pub fn run(self: Pass, ctx: *PassContext) PassResult {
        if (self.run_with_state_fn) |run_with_state| {
            return run_with_state(self.state, ctx);
        }
        if (self.run_fn) |run_pass| {
            return run_pass(ctx);
        }
        return .failure;
    }

    pub fn readOnly(self: Pass) bool {
        return self.mutation_scope == .read_only;
    }

    pub fn isolatedMutation(self: Pass) bool {
        return self.mutation_scope == .isolated;
    }

    pub fn wholeModuleMutation(self: Pass) bool {
        return self.mutation_scope == .whole_module;
    }

    pub fn parallelStateSafe(self: Pass) bool {
        if (self.state == null) return true;
        if (self.state_concurrency == .shared) return true;
        return self.state_clone_fn != null;
    }

    pub fn validRerunContract(self: Pass) bool {
        return switch (self.rerun_policy) {
            .always => true,
            .skip_if_unchanged => self.state == null and
                self.run_with_state_fn == null and
                self.run_fn != null,
        };
    }

    pub fn sameRerunIdentity(self: Pass, previous: Pass) bool {
        if (self.rerun_policy != .skip_if_unchanged) return false;
        if (previous.rerun_policy != .skip_if_unchanged) return false;
        if (!self.validRerunContract() or !previous.validRerunContract()) return false;
        if (self.run_fn != previous.run_fn) return false;
        return std.mem.eql(
            u8,
            self.textual_options orelse "",
            previous.textual_options orelse "",
        );
    }

    pub fn cloneForParallelTarget(self: Pass, allocator: std.mem.Allocator) anyerror!Pass {
        var cloned = self;
        cloned.owns_textual_options = false;
        if (self.state) |_| {
            if (self.state_clone_fn) |clone_fn| {
                cloned.state = try clone_fn(self.state, allocator);
                return cloned;
            }
            if (self.state_concurrency == .shared) {
                cloned.state_deinit_fn = null;
                return cloned;
            }
            return error.PassStateNotParallel;
        }
        cloned.state_deinit_fn = null;
        return cloned;
    }

    pub fn deinit(self: *Pass, allocator: std.mem.Allocator) void {
        if (self.state_deinit_fn) |deinit_fn| deinit_fn(self.state, allocator);
        if (self.owns_textual_options) {
            if (self.textual_options) |text| allocator.free(text);
        }
        self.* = undefined;
    }
};
