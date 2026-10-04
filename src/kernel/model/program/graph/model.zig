const std = @import("std");
const choir = @import("choir");

const core = @import("../../core/root.zig");
const plan = @import("../../plan/root.zig");

const builder = core.builder;
const schedule_mod = core.schedule;

const ir = choir.ir;

pub const product_name = "accy.kernel_program";

pub const Limits = core.Limits;

pub const Capacity = struct {
    context_ownership: ContextOwnership,
    body: builder.Builder.Capacity,
    schedule: schedule_mod.Schedule.Capacity,
    snapshot: schedule_mod.Snapshot.Capacity,
    construction_bytes: usize,
    maximum_overlap_bytes: usize,

    pub const ContextOwnership = enum { owned, borrowed };

    pub fn derive(limits: Limits) error{CapacityOverflow}!Capacity {
        return deriveWithContextOwnership(limits, .owned);
    }

    pub fn deriveBorrowing(limits: Limits) error{CapacityOverflow}!Capacity {
        return deriveWithContextOwnership(limits, .borrowed);
    }

    fn deriveWithContextOwnership(
        limits: Limits,
        context_ownership: ContextOwnership,
    ) error{CapacityOverflow}!Capacity {
        const body = try builder.Builder.Capacity.derive(limits.raw());
        const schedule = try schedule_mod.Schedule.Capacity.derive(limits.schedule);
        const snapshot = try schedule_mod.Snapshot.Capacity.derive(limits.snapshot);
        const body_acquired_bytes = switch (context_ownership) {
            .owned => body.owned_acquired_bytes,
            .borrowed => body.borrowed_acquired_bytes,
        };
        const construction_bytes = std.math.add(
            usize,
            body_acquired_bytes,
            schedule.storage_bytes,
        ) catch return error.CapacityOverflow;
        var maximum_overlap_bytes = std.math.add(
            usize,
            construction_bytes,
            snapshot.storage_bytes,
        ) catch return error.CapacityOverflow;
        maximum_overlap_bytes = std.math.add(
            usize,
            maximum_overlap_bytes,
            schedule.storage_bytes,
        ) catch return error.CapacityOverflow;
        return .{
            .context_ownership = context_ownership,
            .body = body,
            .schedule = schedule,
            .snapshot = snapshot,
            .construction_bytes = construction_bytes,
            .maximum_overlap_bytes = maximum_overlap_bytes,
        };
    }
};

const Storage = struct {
    kernel: builder.Kernel,
    schedule: schedule_mod.Schedule,
};

pub const Program = struct {
    capacity: Capacity,
    storage: Storage,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.storage.schedule.deinit(self.storage.kernel.allocator);
        self.storage.kernel.deinit();
        self.* = undefined;
    }

    pub fn verify(self: *Self) !void {
        try self.storage.kernel.verify();
    }

    pub fn verifyWithDiagnostic(self: *Self, diagnostic: *builder.VerificationDiagnostic) !void {
        try self.storage.kernel.verifyWithDiagnostic(diagnostic);
    }

    pub fn launch(self: *const Self) schedule_mod.ScheduleError!schedule_mod.Launch {
        return self.storage.schedule.launch();
    }

    pub fn scheduleSnapshot(
        self: *const Self,
        allocator: std.mem.Allocator,
    ) schedule_mod.ScheduleError!schedule_mod.Snapshot {
        return schedule_mod.createSnapshot(
            allocator,
            self.capacity.snapshot.asLimits(),
            &self.storage.schedule,
        );
    }

    pub fn createPlan(
        self: *Self,
        allocator: std.mem.Allocator,
        options: plan.Options,
    ) plan.Error!plan.Plan {
        return plan.create(
            allocator,
            &self.storage.kernel,
            &self.storage.schedule,
            self.capacity.snapshot.asLimits(),
            options,
        );
    }

    pub fn kernelModule(self: *const Self) *ir.Operation {
        return self.storage.kernel.module();
    }

    pub fn params(self: *const Self) []const builder.Param {
        return self.storage.kernel.params();
    }

    pub fn createCheckedPlan(
        self: *Self,
        allocator: std.mem.Allocator,
        options: plan.Options,
    ) !plan.Plan {
        var out = try self.createPlan(allocator, options);
        errdefer out.deinit();
        try self.checkPlan(allocator, &out);
        return out;
    }

    pub fn checkPlan(self: *Self, allocator: std.mem.Allocator, out: *const plan.Plan) !void {
        if (out.version != plan.plan_version) return error.PlanVersionMismatch;
        if (out.schedule_version != schedule_mod.snapshot_version) {
            return error.ScheduleVersionMismatch;
        }
        if (out.body_fingerprint != try self.bodyFingerprint(allocator)) {
            return error.BodyFingerprintMismatch;
        }
        if (out.schedule_fingerprint != self.scheduleFingerprint()) {
            return error.ScheduleFingerprintMismatch;
        }
        if (out.schedule.fingerprint() != out.schedule_fingerprint) {
            return error.ScheduleFingerprintMismatch;
        }
        if (!builder.paramsEql(out.params, self.storage.kernel.params())) {
            return error.ParameterSchemaMismatch;
        }
        const argument_count = std.math.cast(u32, self.storage.kernel.params().len) orelse
            return error.ArgumentCountOverflow;
        if (out.argument_count != argument_count) return error.ParameterSchemaMismatch;
        const entry_name = self.storage.kernel.func().getName() orelse
            return error.MissingKernelName;
        if (!std.mem.eql(u8, out.entry_name, entry_name)) return error.EntryNameMismatch;

        var replayed = try schedule_mod.replaySnapshot(
            allocator,
            self.capacity.schedule.asLimits(),
            &out.schedule,
        );
        defer replayed.deinit(allocator);
        if (replayed.fingerprint() != out.schedule_fingerprint) return error.ScheduleReplayMismatch;

        const launch_value = try self.launch();
        if (!launchEqual(out.launch, launch_value)) return error.LaunchMismatch;
        if (!launchEqual(try out.schedule.launch(), launch_value)) return error.LaunchMismatch;
    }

    pub fn bodyFingerprint(self: *const Self, allocator: std.mem.Allocator) !u64 {
        return self.storage.kernel.fingerprint(allocator);
    }

    pub fn scheduleFingerprint(self: *const Self) u64 {
        return self.storage.schedule.fingerprint();
    }

    pub fn fingerprint(
        self: *const Self,
        allocator: std.mem.Allocator,
    ) !choir.product.incremental.Fingerprint {
        const entry_name = self.storage.kernel.func().getName() orelse
            return error.MissingKernelName;
        var fingerprint_builder = choir.product.incremental.FingerprintBuilder{};
        fingerprint_builder.updateBytes(product_name);
        fingerprint_builder.updateU32(plan.plan_version);
        fingerprint_builder.updateU32(schedule_mod.snapshot_version);
        fingerprint_builder.updateU64(try self.bodyFingerprint(allocator));
        fingerprint_builder.updateU64(self.scheduleFingerprint());
        fingerprint_builder.updateBytes(entry_name);
        updateParamsFingerprint(&fingerprint_builder, self.storage.kernel.params());
        return fingerprint_builder.finish();
    }

    pub fn productStamp(
        self: *const Self,
        allocator: std.mem.Allocator,
    ) !choir.product.incremental.ProductStamp {
        return choir.product.incremental.productStamp(
            product_name,
            try self.fingerprint(allocator),
        );
    }

    pub fn init(
        kernel: builder.Kernel,
        schedule: schedule_mod.Schedule,
        capacity: Capacity,
    ) Self {
        return .{
            .capacity = capacity,
            .storage = .{
                .kernel = kernel,
                .schedule = schedule,
            },
        };
    }
};

fn launchEqual(lhs: schedule_mod.Launch, rhs: schedule_mod.Launch) bool {
    return std.mem.eql(u32, &lhs.grid, &rhs.grid) and
        std.mem.eql(u32, &lhs.block, &rhs.block);
}

fn updateParamsFingerprint(
    fingerprint_builder: *choir.product.incremental.FingerprintBuilder,
    params: []const builder.Param,
) void {
    fingerprint_builder.updateUsize(params.len);
    for (params) |param| updateParamFingerprint(fingerprint_builder, param);
}

fn updateParamFingerprint(
    fingerprint_builder: *choir.product.incremental.FingerprintBuilder,
    param: builder.Param,
) void {
    fingerprint_builder.updateEnumTag(std.meta.activeTag(param));
    switch (param) {
        .scalar => |dtype| fingerprint_builder.updateEnumTag(dtype),
        .buffer => |buffer| {
            fingerprint_builder.updateEnumTag(buffer.dtype);
            fingerprint_builder.updateOptionalU64(buffer.size);
            fingerprint_builder.updateEnumTag(buffer.space);
        },
    }
}

fn buildCopyProgram(
    allocator: std.mem.Allocator,
    name: []const u8,
    extent: u64,
) !Program {
    const limits = Limits.testing;
    const capacity = try Capacity.derive(limits);
    var schedule = try schedule_mod.Schedule.init(allocator, limits.schedule);
    errdefer schedule.deinit(allocator);

    const i = try schedule.addAxis("i", extent);
    try schedule.bind(i, .thread_x);

    var b = try builder.Builder.init(allocator, limits.raw(), name, &.{
        builder.dynamicBuffer(.i32),
        builder.dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const src = b.argument(0);
    const dst = b.argument(1);
    const index = try b.globalId(.x);
    const value = try b.load(src, index);
    try b.store(value, dst, index);
    try b.return_();

    const kernel = try b.finish();
    schedule.activate();
    return Program.init(kernel, schedule, capacity);
}
