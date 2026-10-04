const std = @import("std");
const choir = @import("choir");

const core = @import("../model/core/root.zig");
const model = @import("../model/program/root.zig");
const plan = @import("../model/plan/root.zig");
const oracle = @import("../oracle/root.zig");

const Cpu = struct {
    machine: ?oracle.Machine = null,
    verified: bool = false,

    fn deinit(self: *Cpu) void {
        if (self.machine) |*machine| machine.deinit();
        self.* = undefined;
    }

    fn run(
        self: *Cpu,
        program: *model.Program,
        allocator: std.mem.Allocator,
        args: []const oracle.Argument,
        launch_value: core.schedule.Launch,
    ) !void {
        const machine = try self.ensureMachine(allocator);
        if (!self.verified) {
            try program.verify();
            self.verified = true;
        }
        try machine.run(program.storage.kernel.func().op, args, launch_value);
    }

    fn runWithDiagnostic(
        self: *Cpu,
        program: *model.Program,
        allocator: std.mem.Allocator,
        args: []const oracle.Argument,
        diagnostic: *oracle.ExecutionDiagnostic,
    ) !void {
        diagnostic.len = 0;
        const machine = try self.ensureMachine(allocator);
        if (!self.verified) {
            try program.verifyWithDiagnostic(diagnostic);
            self.verified = true;
        }
        try machine.runWithDiagnostic(
            program.storage.kernel.func().op,
            args,
            try program.launch(),
            diagnostic,
        );
    }

    fn ensureMachine(self: *Cpu, allocator: std.mem.Allocator) !*oracle.Machine {
        if (self.machine) |*machine| {
            const same_ptr = machine.allocator.ptr == allocator.ptr;
            const same_vtable = machine.allocator.vtable == allocator.vtable;
            if (same_ptr and same_vtable) return machine;
            machine.deinit();
            self.machine = null;
            self.verified = false;
        }
        self.machine = oracle.Machine.init(allocator);
        return &self.machine.?;
    }
};

pub const Executor = struct {
    program: *model.Program,
    cpu: Cpu = .{},

    pub fn init(program: *model.Program) Executor {
        return .{ .program = program };
    }

    pub fn deinit(self: *Executor) void {
        self.cpu.deinit();
        self.* = undefined;
    }

    pub fn runCpu(
        self: *Executor,
        allocator: std.mem.Allocator,
        args: []const oracle.Argument,
    ) !void {
        try self.runCpuWithLaunch(allocator, args, try self.program.launch());
    }

    pub fn runCpuWithLaunch(
        self: *Executor,
        allocator: std.mem.Allocator,
        args: []const oracle.Argument,
        launch_value: core.schedule.Launch,
    ) !void {
        try self.cpu.run(self.program, allocator, args, launch_value);
    }

    pub fn runCpuWithDiagnostic(
        self: *Executor,
        allocator: std.mem.Allocator,
        args: []const oracle.Argument,
        diagnostic: *oracle.ExecutionDiagnostic,
    ) !void {
        try self.cpu.runWithDiagnostic(self.program, allocator, args, diagnostic);
    }
};

pub const Program = struct {
    capacity: model.Capacity,
    model_program: model.Program,
    cpu: Cpu = .{},

    const Self = @This();

    pub fn init(
        kernel: core.builder.Kernel,
        schedule: core.schedule.Schedule,
        capacity: model.Capacity,
    ) Self {
        return .{
            .capacity = capacity,
            .model_program = model.Program.init(kernel, schedule, capacity),
        };
    }

    pub fn deinit(self: *Self) void {
        self.cpu.deinit();
        self.model_program.deinit();
        self.* = undefined;
    }

    pub fn verify(self: *Self) !void {
        try self.model_program.verify();
    }

    pub fn verifyWithDiagnostic(
        self: *Self,
        diagnostic: *core.builder.VerificationDiagnostic,
    ) !void {
        try self.model_program.verifyWithDiagnostic(diagnostic);
    }

    pub fn launch(self: *const Self) core.schedule.ScheduleError!core.schedule.Launch {
        return self.model_program.launch();
    }

    pub fn scheduleSnapshot(
        self: *const Self,
        allocator: std.mem.Allocator,
    ) core.schedule.ScheduleError!core.schedule.Snapshot {
        return self.model_program.scheduleSnapshot(allocator);
    }

    pub fn createPlan(
        self: *Self,
        allocator: std.mem.Allocator,
        options: plan.Options,
    ) plan.Error!plan.Plan {
        return self.model_program.createPlan(allocator, options);
    }

    pub fn kernelModule(self: *const Self) *choir.ir.Operation {
        return self.model_program.kernelModule();
    }

    pub fn params(self: *const Self) []const core.builder.Param {
        return self.model_program.params();
    }

    pub fn createCheckedPlan(
        self: *Self,
        allocator: std.mem.Allocator,
        options: plan.Options,
    ) !plan.Plan {
        return self.model_program.createCheckedPlan(allocator, options);
    }

    pub fn checkPlan(
        self: *Self,
        allocator: std.mem.Allocator,
        authored_plan: *const plan.Plan,
    ) !void {
        try self.model_program.checkPlan(allocator, authored_plan);
    }

    pub fn runCpu(self: *Self, allocator: std.mem.Allocator, args: []const oracle.Argument) !void {
        try self.runCpuWithLaunch(allocator, args, try self.launch());
    }

    pub fn runCpuWithLaunch(
        self: *Self,
        allocator: std.mem.Allocator,
        args: []const oracle.Argument,
        launch_value: core.schedule.Launch,
    ) !void {
        try self.cpu.run(&self.model_program, allocator, args, launch_value);
    }

    pub fn runCpuWithDiagnostic(
        self: *Self,
        allocator: std.mem.Allocator,
        args: []const oracle.Argument,
        diagnostic: *oracle.ExecutionDiagnostic,
    ) !void {
        try self.cpu.runWithDiagnostic(&self.model_program, allocator, args, diagnostic);
    }

    pub fn bodyFingerprint(self: *const Self, allocator: std.mem.Allocator) !u64 {
        return self.model_program.bodyFingerprint(allocator);
    }

    pub fn scheduleFingerprint(self: *const Self) u64 {
        return self.model_program.scheduleFingerprint();
    }

    pub fn fingerprint(
        self: *const Self,
        allocator: std.mem.Allocator,
    ) !choir.product.incremental.Fingerprint {
        return self.model_program.fingerprint(allocator);
    }

    pub fn productStamp(
        self: *const Self,
        allocator: std.mem.Allocator,
    ) !choir.product.incremental.ProductStamp {
        return self.model_program.productStamp(allocator);
    }
};

const surface = model.Surface(Program, .{
    .registrations = &choir.backends.gpu.dialect_registrations,
    .preload = &.{"scf"},
});

pub const Index1D = surface.Index1D;
pub const VectorIndex1D = surface.VectorIndex1D;
pub const DomainAxis = surface.DomainAxis;
pub const Domain2D = surface.Domain2D;
pub const Domain3D = surface.Domain3D;
pub const Index2D = surface.Index2D;
pub const Index3D = surface.Index3D;
pub const Vec2 = surface.Vec2;
pub const Vec3 = surface.Vec3;
pub const TypedValue = surface.TypedValue;
pub const TypedVec2 = surface.TypedVec2;
pub const TypedVec3 = surface.TypedVec3;
pub const domainAxis = surface.domainAxis;
pub const BufferView = surface.BufferView;
pub const Builder = surface.Builder;
pub const Limits = surface.Limits;
pub const Capacity = surface.Capacity;
pub const Guard = surface.Guard;
pub const define = surface.define;
pub const defineWithDiagnostic = surface.defineWithDiagnostic;

fn buildCopyProgram(
    allocator: std.mem.Allocator,
    name: []const u8,
    extent: u64,
) !Program {
    var builder = try Builder.init(allocator, Limits.testing, name, &.{
        core.builder.dynamicBuffer(.i32),
        core.builder.dynamicBuffer(.i32),
    });
    errdefer builder.deinit();

    const axis = try builder.axis("i", extent);
    try builder.bind(axis, .thread_x);
    const src = builder.argument(0);
    const dst = builder.argument(1);
    const index = try builder.globalId(.x);
    const value = try builder.load(src, index);
    try builder.store(value, dst, index);
    try builder.return_();
    return builder.finish();
}

test "Program steady oracle runs make no allocator calls" {
    var program = try buildCopyProgram(std.testing.allocator, "machine_retained_copy", 4);
    defer program.deinit();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var input = [_]i32{ 3, -1, 7, 12 };
    var output = [_]i32{ 0, 0, 0, 0 };
    try program.runCpu(failing.allocator(), &.{
        oracle.argumentBuffer(i32, input[0..]),
        oracle.argumentBuffer(i32, output[0..]),
    });
    try std.testing.expectEqualSlices(i32, input[0..], output[0..]);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    for (0..8) |_| {
        @memset(output[0..], 0);
        try program.runCpu(failing.allocator(), &.{
            oracle.argumentBuffer(i32, input[0..]),
            oracle.argumentBuffer(i32, output[0..]),
        });
        try std.testing.expectEqualSlices(i32, input[0..], output[0..]);
    }
    try std.testing.expect(!failing.has_induced_failure);
}

test "Program reacquires the machine when the run allocator changes" {
    var program = try buildCopyProgram(std.testing.allocator, "machine_epoch_copy", 4);
    defer program.deinit();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var input = [_]i32{ 5, 6, 7, 8 };
    var output = [_]i32{ 0, 0, 0, 0 };
    try program.runCpu(failing.allocator(), &.{
        oracle.argumentBuffer(i32, input[0..]),
        oracle.argumentBuffer(i32, output[0..]),
    });
    try std.testing.expectEqualSlices(i32, input[0..], output[0..]);

    @memset(output[0..], 0);
    try program.runCpu(std.testing.allocator, &.{
        oracle.argumentBuffer(i32, input[0..]),
        oracle.argumentBuffer(i32, output[0..]),
    });
    try std.testing.expectEqualSlices(i32, input[0..], output[0..]);
}
