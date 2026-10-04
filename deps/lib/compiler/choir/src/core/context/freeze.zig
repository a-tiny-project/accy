const std = @import("std");

pub const Policy = struct {
    frozen: bool,

    pub fn init() Policy {
        return .{ .frozen = false };
    }

    pub fn freeze(self: *Policy) void {
        self.frozen = true;
    }

    pub fn isFrozen(self: *const Policy) bool {
        return self.frozen;
    }
};

pub fn requireMutable(ctx: anytype) @TypeOf(ctx.*).Error!void {
    if (ctx.freeze_policy.isFrozen()) return error.ContextFrozen;
    try requireSingleThreadedMutation(ctx);
}

pub fn requireSingleThreadedMutation(ctx: anytype) @TypeOf(ctx.*).Error!void {
    if (ctx.isMultithreadedExecution()) return error.ContextMutationDuringMultithreadedExecution;
}

pub fn freeze(ctx: anytype) void {
    ctx.freeze_policy.freeze();
}

pub fn isFrozen(ctx: anytype) bool {
    return ctx.freeze_policy.isFrozen();
}

const FakeContext = struct {
    freeze_policy: Policy = Policy.init(),
    multithreaded: bool = false,

    pub const Error = error{
        ContextFrozen,
        ContextMutationDuringMultithreadedExecution,
    };

    fn isMultithreadedExecution(self: *const @This()) bool {
        return self.multithreaded;
    }
};

test "Policy transitions to frozen" {
    var policy = Policy.init();

    try std.testing.expect(!policy.isFrozen());
    policy.freeze();
    try std.testing.expect(policy.isFrozen());
}

test "requireMutable accepts mutable single-threaded context" {
    var ctx = FakeContext{};

    try requireMutable(&ctx);
}

test "requireMutable rejects frozen context" {
    var ctx = FakeContext{};
    freeze(&ctx);

    try std.testing.expectError(error.ContextFrozen, requireMutable(&ctx));
}

test "requireSingleThreadedMutation rejects active execution" {
    var ctx = FakeContext{ .multithreaded = true };

    try std.testing.expectError(
        error.ContextMutationDuringMultithreadedExecution,
        requireSingleThreadedMutation(&ctx),
    );
}

test "freeze and isFrozen use context policy" {
    var ctx = FakeContext{};

    try std.testing.expect(!isFrozen(&ctx));
    freeze(&ctx);
    try std.testing.expect(isFrozen(&ctx));
}
