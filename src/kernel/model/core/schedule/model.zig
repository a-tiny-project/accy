const std = @import("std");
const alloc_phase = @import("alloc_phase");
const choir = @import("choir");
const testing = std.testing;

const Allocator = std.mem.Allocator;

pub const ScheduleError = error{
    UnknownAxis,
    InvalidFactor,
    ExtentNotDivisible,
    BindTargetAlreadyUsed,
    MissingBindingExtent,
    LaunchDimensionOverflow,
    UnsupportedVersion,
    InvalidReplay,
    CapacityOverflow,
    AxisCapacityExceeded,
    StepCapacityExceeded,
    NameCapacityExceeded,
    AxisIdCapacityExceeded,
    ScheduleSealed,
    ScheduleNotEmpty,
    SnapshotNotReady,
} || Allocator.Error;

pub const snapshot_version: u32 = 1;

pub const Launch = struct {
    grid: [3]u32 = .{ 1, 1, 1 },
    block: [3]u32 = .{ 1, 1, 1 },

    pub fn oneDim(extent: usize) Launch {
        return .{ .grid = .{ @intCast(extent), 1, 1 } };
    }
};

pub const AxisId = enum(u32) {
    _,

    pub fn index(self: AxisId) u32 {
        return @backingInt(self);
    }

    fn fromIndex(raw_index: usize) AxisId {
        return @fromBackingInt(@intCast(raw_index));
    }
};

pub const BindTarget = enum {
    block_x,
    block_y,
    block_z,
    thread_x,
    thread_y,
    thread_z,

    fn dim(self: BindTarget) usize {
        return switch (self) {
            .block_x, .thread_x => 0,
            .block_y, .thread_y => 1,
            .block_z, .thread_z => 2,
        };
    }

    fn isGrid(self: BindTarget) bool {
        return switch (self) {
            .block_x, .block_y, .block_z => true,
            .thread_x, .thread_y, .thread_z => false,
        };
    }
};

pub const Axis = struct {
    id: AxisId,
    name: []const u8,
    extent: ?u64,
    bind: ?BindTarget = null,
    vector_width: ?u32 = null,
    unroll_factor: ?u32 = null,
};

pub const Split = struct {
    outer: AxisId,
    inner: AxisId,
};

pub const AxisStep = struct {
    id: AxisId,
    name: []const u8,
    extent: ?u64,
};

pub const Step = union(enum) {
    axis: AxisStep,
    split: struct {
        source: AxisId,
        outer: AxisId,
        inner: AxisId,
        factor: u64,
    },
    tile: struct {
        source: AxisId,
        outer: AxisId,
        inner: AxisId,
        factor: u64,
    },
    bind: struct {
        axis: AxisId,
        target: BindTarget,
    },
    vectorize: struct {
        axis: AxisId,
        width: u32,
    },
    unroll: struct {
        axis: AxisId,
        factor: u32,
    },
};

/// A caller holds this record to save a kernel's schedule, the loop structure of one kernel, as
/// axes and the steps applied to them, or to replay it onto another kernel. The record holds a
/// format version, the schedule's axes, its steps in order, and the limits that bound a replay. The
/// record borrows its slices, either from the schedule snapshot that produced it or from a record
/// decoded on its own. Replaying it onto a schedule fails with `error.ScheduleNotEmpty` when that
/// schedule already has steps, `error.UnsupportedVersion` for another format version, and
/// `error.InvalidReplay` when an axis or step mismatches. Saved kernel programs embed this record.
pub const Record = struct {
    version: u32,
    axes: []const Axis,
    steps: []const Step,
    replay_limits: Schedule.Limits,
};

pub const Snapshot = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: Capacity,
    storage: [*]u8,
    version: u32,
    axes_storage: []Axis,
    axes_len: usize,
    steps_storage: []Step,
    steps_len: usize,
    names_storage: []u8,
    names_len: usize,
    replay_limits: Schedule.Limits,
    captured: bool,

    pub const Limits = struct {
        axes: usize,
        steps: usize,
        name_bytes: usize,

        pub const standard: Limits = .{
            .axes = 64,
            .steps = 256,
            .name_bytes = 16 * 1024,
        };

        pub const testing: Limits = .{
            .axes = 256,
            .steps = 1024,
            .name_bytes = 64 * 1024,
        };
    };

    pub const Capacity = struct {
        axes: usize,
        steps: usize,
        name_bytes: usize,
        axes_offset: usize,
        steps_offset: usize,
        names_offset: usize,
        storage_bytes: usize,
        storage_alignment: std.mem.Alignment,

        pub fn derive(limits: Limits) error{CapacityOverflow}!Capacity {
            var cursor: usize = 0;
            var alignment: usize = 1;
            const axes_offset = try placeSlice(Axis, limits.axes, &cursor, &alignment);
            const steps_offset = try placeSlice(Step, limits.steps, &cursor, &alignment);
            const names_offset = try placeSlice(u8, limits.name_bytes, &cursor, &alignment);
            if (cursor == 0) cursor = 1;
            return .{
                .axes = limits.axes,
                .steps = limits.steps,
                .name_bytes = limits.name_bytes,
                .axes_offset = axes_offset,
                .steps_offset = steps_offset,
                .names_offset = names_offset,
                .storage_bytes = cursor,
                .storage_alignment = .fromByteUnits(alignment),
            };
        }

        pub fn asLimits(self: Capacity) Limits {
            return .{
                .axes = self.axes,
                .steps = self.steps,
                .name_bytes = self.name_bytes,
            };
        }
    };

    pub const Exhaustion = error{
        AxisCapacityExceeded,
        StepCapacityExceeded,
        NameCapacityExceeded,
    };

    pub const Usage = struct {
        axes: usize,
        steps: usize,
        name_bytes: usize,
    };

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "accy.kernel_schedule_snapshot",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "replayable_axis_records_and_owned_axis_names",
                        .lifetime = .steady,
                        .detail = "replayable axis records and owned axis names",
                    },
                    .{
                        .id = "replayable_schedule_steps_and_owned_axis_step_names",
                        .lifetime = .steady,
                        .detail = "replayable schedule steps and owned axis-step names",
                    },
                },
                .excluded = &.{
                    "source Schedule storage borrowed only during capture",
                    "caller allocator implementation state and replay Schedule storage",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "axes", "axes"),
                    alloc_phase.capacity.bindInput(Limits, "steps", "steps"),
                    alloc_phase.capacity.bindInput(Limits, "name_bytes", "name_bytes"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(Axis, "axis"),
                    alloc_phase.capacity.bindType(Step, "step"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .input = 1 },
                    .{ .scale = .{ .node = 2, .coefficient = .{ .size_of_concrete_type = 1 } } },
                    .{ .input = 2 },
                    .{ .constant = 0 },
                    .{ .alignment = .{ .node = 5, .alignment = .{ .literal = 16 } } },
                    .{ .add = .{ .left = 6, .right = 1 } },
                    .{ .alignment = .{ .node = 7, .alignment = .{ .literal = 16 } } },
                    .{ .add = .{ .left = 8, .right = 3 } },
                    .{ .alignment = .{ .node = 9, .alignment = .{ .literal = 1 } } },
                    .{ .add = .{ .left = 10, .right = 4 } },
                    .{ .alignment = .{ .node = 11, .alignment = .{ .literal = 16 } } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 12,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "capture preflights all record and name dimensions before copying any " ++
                    "source state",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "capture and immutable queries use only the single preacquired " ++
                        "snapshot region",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "snapshot capture and queries cross no foreign or " ++
                        "operating-system boundary",
                },
            },
            .obligations = &.{
                .{ .key = "accy_kernel_schedule_snapshot_capacity", .role = .capacity_model },
                .{ .key = "accy_kernel_schedule_snapshot_boundary", .role = .overload },
                .{
                    .key = "accy_kernel_schedule_snapshot_lifetime_transitive_risk",
                    .role = .transitive_risk,
                },
                .{
                    .key = "accy_kernel_schedule_snapshot_lifetime_foreign_risk",
                    .role = .foreign_risk,
                },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    pub fn init(allocator: Allocator, limits: Limits) ScheduleError!Snapshot {
        const capacity = try Capacity.derive(limits);
        const storage = allocator.rawAlloc(
            capacity.storage_bytes,
            capacity.storage_alignment,
            @returnAddress(),
        ) orelse return error.OutOfMemory;
        return .{
            .phase = .initialization,
            .capacity = capacity,
            .storage = storage,
            .version = snapshot_version,
            .axes_storage = typedSlice(Axis, storage, capacity.axes_offset, capacity.axes),
            .axes_len = 0,
            .steps_storage = typedSlice(Step, storage, capacity.steps_offset, capacity.steps),
            .steps_len = 0,
            .names_storage = typedSlice(u8, storage, capacity.names_offset, capacity.name_bytes),
            .names_len = 0,
            .replay_limits = .{
                .axes = 0,
                .steps = 0,
                .name_bytes = 0,
                .axis_ids = 0,
            },
            .captured = false,
        };
    }

    pub fn capture(self: *Snapshot, schedule: *const Schedule) ScheduleError!void {
        if (self.phase != .initialization or self.captured) return error.SnapshotNotReady;
        const required = try schedule.snapshotLimits();
        if (required.axes > self.capacity.axes) return error.AxisCapacityExceeded;
        if (required.steps > self.capacity.steps) return error.StepCapacityExceeded;
        if (required.name_bytes > self.capacity.name_bytes) return error.NameCapacityExceeded;

        for (schedule.allAxes(), 0..) |source, index| {
            self.axes_storage[index] = source;
            self.axes_storage[index].name = self.writeName(source.name);
        }
        for (schedule.allSteps(), 0..) |source, index| {
            self.steps_storage[index] = source;
            if (source == .axis) {
                self.steps_storage[index].axis.name = self.writeName(source.axis.name);
            }
        }
        self.axes_len = required.axes;
        self.steps_len = required.steps;
        self.replay_limits = schedule.requiredReplayLimits();
        self.captured = true;
    }

    pub fn activate(self: *Snapshot) void {
        std.debug.assert(self.phase == .initialization);
        std.debug.assert(self.captured);
        self.phase = .steady;
    }

    pub fn deinit(self: *Snapshot, allocator: Allocator) void {
        std.debug.assert(self.phase != .teardown);
        const storage = self.storage;
        const capacity = self.capacity;
        self.phase = .teardown;
        self.* = undefined;
        allocator.rawFree(
            storage[0..capacity.storage_bytes],
            capacity.storage_alignment,
            @returnAddress(),
        );
    }

    pub fn capacityUsage(self: *const Snapshot) Usage {
        return .{
            .axes = self.axes_len,
            .steps = self.steps_len,
            .name_bytes = self.names_len,
        };
    }

    pub fn allAxes(self: *const Snapshot) []const Axis {
        return self.axes_storage[0..self.axes_len];
    }

    pub fn allSteps(self: *const Snapshot) []const Step {
        return self.steps_storage[0..self.steps_len];
    }

    pub fn launch(self: *const Snapshot) ScheduleError!Launch {
        if (!self.captured) return error.SnapshotNotReady;
        return launchFromAxes(self.allAxes());
    }

    pub fn fingerprint(self: *const Snapshot) u64 {
        return fingerprintSchedule(self.version, self.allAxes(), self.allSteps());
    }

    pub fn requiredReplayLimits(self: *const Snapshot) ScheduleError!Schedule.Limits {
        if (!self.captured) return error.SnapshotNotReady;
        if (self.version != snapshot_version) return error.UnsupportedVersion;
        return self.replay_limits;
    }

    pub fn requiredReplayCapacity(self: *const Snapshot) ScheduleError!Schedule.Capacity {
        return Schedule.Capacity.derive(try self.requiredReplayLimits());
    }

    pub fn record(self: *const Snapshot) ScheduleError!Record {
        return .{
            .version = self.version,
            .axes = self.allAxes(),
            .steps = self.allSteps(),
            .replay_limits = try self.requiredReplayLimits(),
        };
    }

    fn writeName(self: *Snapshot, name: []const u8) []const u8 {
        const start = self.names_len;
        const end = start + name.len;
        @memcpy(self.names_storage[start..end], name);
        self.names_len = end;
        return self.names_storage[start..end];
    }
};

pub const Schedule = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: Capacity,
    storage: [*]u8,
    axes_storage: []Axis,
    axes_len: usize,
    steps_storage: []Step,
    steps_len: usize,
    names_storage: []u8,
    names_len: usize,
    next_axis_id: usize,

    pub const Limits = struct {
        axes: usize,
        steps: usize,
        name_bytes: usize,
        axis_ids: usize,

        pub const standard: Limits = .{
            .axes = 64,
            .steps = 256,
            .name_bytes = 16 * 1024,
            .axis_ids = 512,
        };

        pub const testing: Limits = .{
            .axes = 256,
            .steps = 1024,
            .name_bytes = 64 * 1024,
            .axis_ids = 2048,
        };
    };

    pub const Capacity = struct {
        axes: usize,
        steps: usize,
        name_bytes: usize,
        axis_ids: usize,
        axes_offset: usize,
        steps_offset: usize,
        names_offset: usize,
        storage_bytes: usize,
        storage_alignment: std.mem.Alignment,

        pub fn derive(limits: Limits) error{CapacityOverflow}!Capacity {
            if (limits.axis_ids > std.math.maxInt(u32)) return error.CapacityOverflow;
            var cursor: usize = 0;
            var alignment: usize = 1;
            const axes_offset = try placeSlice(Axis, limits.axes, &cursor, &alignment);
            const steps_offset = try placeSlice(Step, limits.steps, &cursor, &alignment);
            const names_offset = try placeSlice(u8, limits.name_bytes, &cursor, &alignment);
            if (cursor == 0) cursor = 1;
            return .{
                .axes = limits.axes,
                .steps = limits.steps,
                .name_bytes = limits.name_bytes,
                .axis_ids = limits.axis_ids,
                .axes_offset = axes_offset,
                .steps_offset = steps_offset,
                .names_offset = names_offset,
                .storage_bytes = cursor,
                .storage_alignment = .fromByteUnits(alignment),
            };
        }

        pub fn asLimits(self: Capacity) Limits {
            return .{
                .axes = self.axes,
                .steps = self.steps,
                .name_bytes = self.name_bytes,
                .axis_ids = self.axis_ids,
            };
        }
    };

    pub const Exhaustion = error{
        AxisCapacityExceeded,
        StepCapacityExceeded,
        NameCapacityExceeded,
        AxisIdCapacityExceeded,
    };

    pub const Usage = struct {
        axes: usize,
        steps: usize,
        name_bytes: usize,
        axis_ids: usize,
    };

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "accy.kernel_schedule",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "bounded_mutable_axis_records",
                        .lifetime = .steady,
                        .detail = "bounded mutable axis records",
                    },
                    .{
                        .id = "bounded_replayable_schedule_steps",
                        .lifetime = .steady,
                        .detail = "bounded replayable schedule steps",
                    },
                    .{
                        .id = "live_duplicated_and_generated_axis_names",
                        .lifetime = .steady,
                        .detail = "live duplicated and generated axis names",
                    },
                },
                .excluded = &.{
                    "caller allocator implementation state",
                    "independently acquired snapshots and replay result Schedules",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "axes", "axes"),
                    alloc_phase.capacity.bindInput(Limits, "steps", "steps"),
                    alloc_phase.capacity.bindInput(Limits, "axis_ids", "axis_ids"),
                    alloc_phase.capacity.bindInput(Limits, "name_bytes", "name_bytes"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(Axis, "axis"),
                    alloc_phase.capacity.bindType(Step, "step"),
                    alloc_phase.capacity.bindType(AxisId, "axisid"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .input = 1 },
                    .{ .scale = .{ .node = 2, .coefficient = .{ .size_of_concrete_type = 1 } } },
                    .{ .input = 2 },
                    .{ .scale = .{ .node = 4, .coefficient = .{ .size_of_concrete_type = 2 } } },
                    .{ .input = 3 },
                    .{ .constant = 0 },
                    .{ .alignment = .{ .node = 7, .alignment = .{ .literal = 16 } } },
                    .{ .add = .{ .left = 8, .right = 1 } },
                    .{ .alignment = .{ .node = 9, .alignment = .{ .literal = 16 } } },
                    .{ .add = .{ .left = 10, .right = 3 } },
                    .{ .alignment = .{ .node = 11, .alignment = .{ .literal = 16 } } },
                    .{ .add = .{ .left = 12, .right = 5 } },
                    .{ .alignment = .{ .node = 13, .alignment = .{ .literal = 1 } } },
                    .{ .add = .{ .left = 14, .right = 6 } },
                    .{ .alignment = .{ .node = 15, .alignment = .{ .literal = 16 } } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 16,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "every mutation preflights axes, steps, name bytes, and issued IDs " ++
                    "before publishing state",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "all construction methods write only into the single preacquired " ++
                        "Schedule region",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "Schedule construction and queries cross no foreign or " ++
                        "operating-system boundary",
                },
            },
            .obligations = &.{
                .{ .key = "accy_kernel_schedule_capacity", .role = .capacity_model },
                .{ .key = "accy_kernel_schedule_single_acquisition", .role = .transitive_risk },
                .{ .key = "accy_kernel_schedule_boundary_overload", .role = .overload },
                .{ .key = "accy_kernel_schedule_boundary_foreign_risk", .role = .foreign_risk },
                .{ .key = "accy_kernel_schedule_replay_boundary", .role = .overload },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    pub fn init(allocator: Allocator, limits: Limits) ScheduleError!Schedule {
        const capacity = try Capacity.derive(limits);
        const storage = allocator.rawAlloc(
            capacity.storage_bytes,
            capacity.storage_alignment,
            @returnAddress(),
        ) orelse return error.OutOfMemory;
        return .{
            .phase = .initialization,
            .capacity = capacity,
            .storage = storage,
            .axes_storage = typedSlice(Axis, storage, capacity.axes_offset, capacity.axes),
            .axes_len = 0,
            .steps_storage = typedSlice(Step, storage, capacity.steps_offset, capacity.steps),
            .steps_len = 0,
            .names_storage = typedSlice(u8, storage, capacity.names_offset, capacity.name_bytes),
            .names_len = 0,
            .next_axis_id = 0,
        };
    }

    pub fn activate(self: *Schedule) void {
        std.debug.assert(self.phase == .initialization);
        self.phase = .steady;
    }

    pub fn deinit(self: *Schedule, allocator: Allocator) void {
        std.debug.assert(self.phase != .teardown);
        const storage = self.storage;
        const capacity = self.capacity;
        self.phase = .teardown;
        self.* = undefined;
        allocator.rawFree(
            storage[0..capacity.storage_bytes],
            capacity.storage_alignment,
            @returnAddress(),
        );
    }

    pub fn capacityUsage(self: *const Schedule) Usage {
        return .{
            .axes = self.axes_len,
            .steps = self.steps_len,
            .name_bytes = self.names_len,
            .axis_ids = self.next_axis_id,
        };
    }

    pub fn addAxis(self: *Schedule, name: []const u8, extent: ?u64) ScheduleError!AxisId {
        try self.requireBuilding();
        const name_bytes = std.math.mul(usize, name.len, 2) catch return error.CapacityOverflow;
        try self.requireGrowth(1, 1, name_bytes, 1);
        const owned_name = self.writeName(name);
        const step_name = self.writeName(name);
        const id = self.allocAxisId();
        self.axes_storage[self.axes_len] = .{
            .id = id,
            .name = owned_name,
            .extent = extent,
        };
        self.axes_len += 1;
        self.steps_storage[self.steps_len] = .{ .axis = .{
            .id = id,
            .name = step_name,
            .extent = extent,
        } };
        self.steps_len += 1;
        return id;
    }

    pub fn split(self: *Schedule, axis_id: AxisId, factor: u64) ScheduleError!Split {
        if (factor == 0) return error.InvalidFactor;
        try self.requireBuilding();
        const index = try self.axisIndex(axis_id);
        const source = self.axes_storage[index];
        const extent = source.extent orelse return error.MissingBindingExtent;
        if (extent % factor != 0) return error.ExtentNotDivisible;
        return self.replaceAxis(index, source, factor, .split, "_outer", "_inner", extent / factor);
    }

    pub fn tile(self: *Schedule, axis_id: AxisId, factor: u64) ScheduleError!Split {
        if (factor == 0) return error.InvalidFactor;
        try self.requireBuilding();
        const index = try self.axisIndex(axis_id);
        const source = self.axes_storage[index];
        const extent = source.extent orelse return error.MissingBindingExtent;
        const outer_extent = (extent / factor) + @intFromBool(extent % factor != 0);
        return self.replaceAxis(index, source, factor, .tile, "_tile", "_lane", outer_extent);
    }

    pub fn bind(self: *Schedule, axis_id: AxisId, target: BindTarget) ScheduleError!void {
        try self.requireBuilding();
        const index = try self.axisIndex(axis_id);
        for (self.allAxes(), 0..) |existing, existing_index| {
            if (existing_index == index) continue;
            if (existing.bind) |bound| if (bound == target) return error.BindTargetAlreadyUsed;
        }
        try self.requireGrowth(0, 1, 0, 0);
        self.axes_storage[index].bind = target;
        self.steps_storage[self.steps_len] = .{ .bind = .{
            .axis = axis_id,
            .target = target,
        } };
        self.steps_len += 1;
    }

    pub fn vectorize(self: *Schedule, axis_id: AxisId, width: u32) ScheduleError!void {
        if (width == 0) return error.InvalidFactor;
        try self.requireBuilding();
        const index = try self.axisIndex(axis_id);
        if (self.axes_storage[index].extent) |extent| {
            if (extent % width != 0) return error.ExtentNotDivisible;
        }
        try self.requireGrowth(0, 1, 0, 0);
        self.axes_storage[index].vector_width = width;
        self.steps_storage[self.steps_len] = .{ .vectorize = .{
            .axis = axis_id,
            .width = width,
        } };
        self.steps_len += 1;
    }

    pub fn unroll(self: *Schedule, axis_id: AxisId, factor: u32) ScheduleError!void {
        if (factor == 0) return error.InvalidFactor;
        try self.requireBuilding();
        const index = try self.axisIndex(axis_id);
        try self.requireGrowth(0, 1, 0, 0);
        self.axes_storage[index].unroll_factor = factor;
        self.steps_storage[self.steps_len] = .{ .unroll = .{
            .axis = axis_id,
            .factor = factor,
        } };
        self.steps_len += 1;
    }

    pub fn replay(self: *Schedule, source: Record) ScheduleError!void {
        try self.requireBuilding();
        if (self.axes_len != 0 or self.steps_len != 0 or
            self.names_len != 0 or self.next_axis_id != 0)
        {
            return error.ScheduleNotEmpty;
        }
        if (source.version != snapshot_version) return error.UnsupportedVersion;
        try self.requireLimits(source.replay_limits);
        errdefer self.reset();

        for (source.steps) |step| {
            switch (step) {
                .axis => |axis| {
                    const id = try self.addAxis(axis.name, axis.extent);
                    if (id != axis.id) return error.InvalidReplay;
                },
                .split => |split_value| {
                    const result = try self.split(split_value.source, split_value.factor);
                    if (result.outer != split_value.outer or result.inner != split_value.inner) {
                        return error.InvalidReplay;
                    }
                },
                .tile => |tile_value| {
                    const result = try self.tile(tile_value.source, tile_value.factor);
                    if (result.outer != tile_value.outer or result.inner != tile_value.inner) {
                        return error.InvalidReplay;
                    }
                },
                .bind => |bind_value| try self.bind(bind_value.axis, bind_value.target),
                .vectorize => |vectorize_value| try self.vectorize(
                    vectorize_value.axis,
                    vectorize_value.width,
                ),
                .unroll => |unroll_value| try self.unroll(unroll_value.axis, unroll_value.factor),
            }
        }
        if (!axesEqual(self.allAxes(), source.axes)) return error.InvalidReplay;
        if (!stepsEqual(self.allSteps(), source.steps)) return error.InvalidReplay;
        if (!std.meta.eql(self.requiredReplayLimits(), source.replay_limits)) {
            return error.InvalidReplay;
        }
    }

    pub fn getAxis(self: *const Schedule, id: AxisId) ScheduleError!Axis {
        return self.axes_storage[try self.axisIndex(id)];
    }

    pub fn allAxes(self: *const Schedule) []const Axis {
        return self.axes_storage[0..self.axes_len];
    }

    pub fn allSteps(self: *const Schedule) []const Step {
        return self.steps_storage[0..self.steps_len];
    }

    pub fn launch(self: *const Schedule) ScheduleError!Launch {
        return launchFromAxes(self.allAxes());
    }

    pub fn fingerprint(self: *const Schedule) u64 {
        return fingerprintSchedule(snapshot_version, self.allAxes(), self.allSteps());
    }

    pub fn snapshotLimits(self: *const Schedule) ScheduleError!Snapshot.Limits {
        var name_bytes: usize = 0;
        for (self.allAxes()) |axis_entry| {
            name_bytes = std.math.add(
                usize,
                name_bytes,
                axis_entry.name.len,
            ) catch return error.CapacityOverflow;
        }
        for (self.allSteps()) |step| {
            if (step == .axis) {
                name_bytes = std.math.add(
                    usize,
                    name_bytes,
                    step.axis.name.len,
                ) catch return error.CapacityOverflow;
            }
        }
        return .{
            .axes = self.axes_len,
            .steps = self.steps_len,
            .name_bytes = name_bytes,
        };
    }

    pub fn requiredReplayLimits(self: *const Schedule) Limits {
        return .{
            .axes = self.axes_len,
            .steps = self.steps_len,
            .name_bytes = self.names_len,
            .axis_ids = self.next_axis_id,
        };
    }

    fn replaceAxis(
        self: *Schedule,
        index: usize,
        source: Axis,
        factor: u64,
        step_tag: enum { split, tile },
        outer_suffix: []const u8,
        inner_suffix: []const u8,
        outer_extent: u64,
    ) ScheduleError!Split {
        const outer_bytes = std.math.add(
            usize,
            source.name.len,
            outer_suffix.len,
        ) catch return error.CapacityOverflow;
        const inner_bytes = std.math.add(
            usize,
            source.name.len,
            inner_suffix.len,
        ) catch return error.CapacityOverflow;
        const replacement_bytes = std.math.add(
            usize,
            outer_bytes,
            inner_bytes,
        ) catch return error.CapacityOverflow;
        const name_growth = std.math.sub(
            usize,
            replacement_bytes,
            source.name.len,
        ) catch unreachable;
        try self.requireGrowth(1, 1, name_growth, 2);

        const generated_names = self.replaceName(source, outer_suffix, inner_suffix, name_growth);
        const outer_id = self.allocAxisId();
        const inner_id = self.allocAxisId();

        if (index + 1 < self.axes_len) {
            std.mem.copyBackwards(
                Axis,
                self.axes_storage[index + 2 .. self.axes_len + 1],
                self.axes_storage[index + 1 .. self.axes_len],
            );
        }
        self.axes_storage[index] = .{
            .id = outer_id,
            .name = generated_names.outer,
            .extent = outer_extent,
        };
        self.axes_storage[index + 1] = .{
            .id = inner_id,
            .name = generated_names.inner,
            .extent = factor,
        };
        self.axes_len += 1;

        self.steps_storage[self.steps_len] = switch (step_tag) {
            .split => .{ .split = .{
                .source = source.id,
                .outer = outer_id,
                .inner = inner_id,
                .factor = factor,
            } },
            .tile => .{ .tile = .{
                .source = source.id,
                .outer = outer_id,
                .inner = inner_id,
                .factor = factor,
            } },
        };
        self.steps_len += 1;
        return .{ .outer = outer_id, .inner = inner_id };
    }

    fn replaceName(
        self: *Schedule,
        source: Axis,
        outer_suffix: []const u8,
        inner_suffix: []const u8,
        growth: usize,
    ) struct { outer: []const u8, inner: []const u8 } {
        const names_start = @intFromPtr(self.names_storage.ptr);
        const source_start = @intFromPtr(source.name.ptr) - names_start;
        const source_end = source_start + source.name.len;
        const old_names_len = self.names_len;
        const new_names_len = old_names_len + growth;

        std.mem.copyBackwards(
            u8,
            self.names_storage[source_end + growth .. new_names_len],
            self.names_storage[source_end..old_names_len],
        );
        self.shiftNamesAfter(source.id, source_end, growth);

        const outer_end = source_end;
        const outer_suffix_end = outer_end + outer_suffix.len;
        @memcpy(self.names_storage[outer_end..outer_suffix_end], outer_suffix);
        const inner_end = outer_suffix_end + source.name.len;
        @memcpy(
            self.names_storage[outer_suffix_end..inner_end],
            self.names_storage[source_start..outer_end],
        );
        const inner_suffix_end = inner_end + inner_suffix.len;
        @memcpy(self.names_storage[inner_end..inner_suffix_end], inner_suffix);
        std.debug.assert(inner_suffix_end == source_end + growth);
        self.names_len = new_names_len;
        return .{
            .outer = self.names_storage[source_start..outer_suffix_end],
            .inner = self.names_storage[outer_suffix_end..inner_suffix_end],
        };
    }

    fn shiftNamesAfter(
        self: *Schedule,
        replaced_axis: AxisId,
        source_end: usize,
        growth: usize,
    ) void {
        const names_start = @intFromPtr(self.names_storage.ptr);
        for (self.axes_storage[0..self.axes_len]) |*axis_entry| {
            if (axis_entry.id == replaced_axis) continue;
            self.shiftName(&axis_entry.name, names_start, source_end, growth);
        }
        for (self.steps_storage[0..self.steps_len]) |*step| {
            if (step.* == .axis) self.shiftName(&step.axis.name, names_start, source_end, growth);
        }
    }

    fn shiftName(
        self: *Schedule,
        name: *[]const u8,
        names_start: usize,
        source_end: usize,
        growth: usize,
    ) void {
        const offset = @intFromPtr(name.ptr) - names_start;
        if (offset < source_end) return;
        name.* = self.names_storage[offset + growth .. offset + growth + name.len];
    }

    fn requireBuilding(self: *const Schedule) ScheduleError!void {
        if (self.phase != .initialization) return error.ScheduleSealed;
    }

    fn requireLimits(self: *const Schedule, limits: Limits) ScheduleError!void {
        if (limits.axes > self.capacity.axes) return error.AxisCapacityExceeded;
        if (limits.steps > self.capacity.steps) return error.StepCapacityExceeded;
        if (limits.name_bytes > self.capacity.name_bytes) return error.NameCapacityExceeded;
        if (limits.axis_ids > self.capacity.axis_ids) return error.AxisIdCapacityExceeded;
    }

    fn requireGrowth(
        self: *const Schedule,
        axes: usize,
        steps: usize,
        name_bytes: usize,
        axis_ids: usize,
    ) ScheduleError!void {
        const axes_after = std.math.add(
            usize,
            self.axes_len,
            axes,
        ) catch return error.CapacityOverflow;
        const steps_after = std.math.add(
            usize,
            self.steps_len,
            steps,
        ) catch return error.CapacityOverflow;
        const names_after = std.math.add(
            usize,
            self.names_len,
            name_bytes,
        ) catch return error.CapacityOverflow;
        const ids_after = std.math.add(
            usize,
            self.next_axis_id,
            axis_ids,
        ) catch return error.CapacityOverflow;
        if (axes_after > self.capacity.axes) return error.AxisCapacityExceeded;
        if (steps_after > self.capacity.steps) return error.StepCapacityExceeded;
        if (names_after > self.capacity.name_bytes) return error.NameCapacityExceeded;
        if (ids_after > self.capacity.axis_ids) return error.AxisIdCapacityExceeded;
    }

    fn writeName(self: *Schedule, name: []const u8) []const u8 {
        const start = self.names_len;
        const end = start + name.len;
        @memcpy(self.names_storage[start..end], name);
        self.names_len = end;
        return self.names_storage[start..end];
    }

    fn allocAxisId(self: *Schedule) AxisId {
        const id = AxisId.fromIndex(self.next_axis_id);
        self.next_axis_id += 1;
        return id;
    }

    fn axisIndex(self: *const Schedule, id: AxisId) ScheduleError!usize {
        for (self.allAxes(), 0..) |axis_entry, index| {
            if (axis_entry.id == id) return index;
        }
        return error.UnknownAxis;
    }

    fn reset(self: *Schedule) void {
        self.axes_len = 0;
        self.steps_len = 0;
        self.names_len = 0;
        self.next_axis_id = 0;
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorRejectingOwnerShape(Schedule);
}

comptime {
    alloc_phase.capacity.requireAllocatorRejectingOwnerShape(Snapshot);
}

pub fn createSnapshot(
    allocator: Allocator,
    limits: Snapshot.Limits,
    schedule: *const Schedule,
) ScheduleError!Snapshot {
    var snapshot = try Snapshot.init(allocator, limits);
    errdefer snapshot.deinit(allocator);
    try snapshot.capture(schedule);
    snapshot.activate();
    return snapshot;
}

pub fn replaySnapshot(
    allocator: Allocator,
    limits: Schedule.Limits,
    snapshot: *const Snapshot,
) ScheduleError!Schedule {
    const required = try snapshot.requiredReplayLimits();
    try requireAvailableReplayLimits(limits, required);
    var schedule = try Schedule.init(allocator, limits);
    errdefer schedule.deinit(allocator);
    try schedule.replay(try snapshot.record());
    schedule.activate();
    return schedule;
}

fn requireAvailableReplayLimits(
    available: Schedule.Limits,
    required: Schedule.Limits,
) ScheduleError!void {
    if (required.axes > available.axes) return error.AxisCapacityExceeded;
    if (required.steps > available.steps) return error.StepCapacityExceeded;
    if (required.name_bytes > available.name_bytes) return error.NameCapacityExceeded;
    if (required.axis_ids > available.axis_ids) return error.AxisIdCapacityExceeded;
}

fn launchFromAxes(axes: []const Axis) ScheduleError!Launch {
    var grid: [3]u32 = .{ 1, 1, 1 };
    var block: [3]u32 = .{ 1, 1, 1 };
    for (axes) |axis_entry| {
        const target = axis_entry.bind orelse continue;
        const extent = try launchAxisExtent(axis_entry);
        const converted = std.math.cast(u32, extent) orelse return error.LaunchDimensionOverflow;
        if (target.isGrid()) {
            grid[target.dim()] = converted;
        } else {
            block[target.dim()] = converted;
        }
    }
    return .{ .grid = grid, .block = block };
}

fn launchAxisExtent(axis_entry: Axis) ScheduleError!u64 {
    const extent = axis_entry.extent orelse return error.MissingBindingExtent;
    const width = axis_entry.vector_width orelse return extent;
    if (extent % width != 0) return error.ExtentNotDivisible;
    return extent / width;
}

fn fingerprintSchedule(version: u32, axes: []const Axis, steps: []const Step) u64 {
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes("accy.kernel.schedule");
    builder.updateU32(version);
    builder.updateUsize(axes.len);
    for (axes) |axis_entry| fingerprintAxis(&builder, axis_entry);
    builder.updateUsize(steps.len);
    for (steps) |step| fingerprintStep(&builder, step);
    return builder.finish();
}

fn fingerprintAxis(builder: *choir.product.incremental.FingerprintBuilder, axis_entry: Axis) void {
    fingerprintAxisId(builder, axis_entry.id);
    builder.updateBytes(axis_entry.name);
    builder.updateOptionalU64(axis_entry.extent);
    builder.updateOptionalEnumTag(axis_entry.bind);
    builder.updateOptionalU32(axis_entry.vector_width);
    builder.updateOptionalU32(axis_entry.unroll_factor);
}

fn fingerprintStep(builder: *choir.product.incremental.FingerprintBuilder, step: Step) void {
    builder.updateEnumTag(std.meta.activeTag(step));
    switch (step) {
        .axis => |axis| {
            fingerprintAxisId(builder, axis.id);
            builder.updateBytes(axis.name);
            builder.updateOptionalU64(axis.extent);
        },
        .split => |split_value| {
            fingerprintAxisId(builder, split_value.source);
            fingerprintAxisId(builder, split_value.outer);
            fingerprintAxisId(builder, split_value.inner);
            builder.updateU64(split_value.factor);
        },
        .tile => |tile_value| {
            fingerprintAxisId(builder, tile_value.source);
            fingerprintAxisId(builder, tile_value.outer);
            fingerprintAxisId(builder, tile_value.inner);
            builder.updateU64(tile_value.factor);
        },
        .bind => |bind_value| {
            fingerprintAxisId(builder, bind_value.axis);
            builder.updateEnumTag(bind_value.target);
        },
        .vectorize => |vectorize_value| {
            fingerprintAxisId(builder, vectorize_value.axis);
            builder.updateU32(vectorize_value.width);
        },
        .unroll => |unroll_value| {
            fingerprintAxisId(builder, unroll_value.axis);
            builder.updateU32(unroll_value.factor);
        },
    }
}

fn fingerprintAxisId(builder: *choir.product.incremental.FingerprintBuilder, id: AxisId) void {
    builder.updateU32(id.index());
}

fn axesEqual(lhs: []const Axis, rhs: []const Axis) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!axisEqual(left, right)) return false;
    }
    return true;
}

fn axisEqual(lhs: Axis, rhs: Axis) bool {
    return lhs.id == rhs.id and
        std.mem.eql(u8, lhs.name, rhs.name) and
        lhs.extent == rhs.extent and
        lhs.bind == rhs.bind and
        lhs.vector_width == rhs.vector_width and
        lhs.unroll_factor == rhs.unroll_factor;
}

fn stepsEqual(lhs: []const Step, rhs: []const Step) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!stepEqual(left, right)) return false;
    }
    return true;
}

fn stepEqual(lhs: Step, rhs: Step) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .axis => |left| axisStepEqual(left, rhs.axis),
        .split => |left| std.meta.eql(left, rhs.split),
        .tile => |left| std.meta.eql(left, rhs.tile),
        .bind => |left| std.meta.eql(left, rhs.bind),
        .vectorize => |left| std.meta.eql(left, rhs.vectorize),
        .unroll => |left| std.meta.eql(left, rhs.unroll),
    };
}

fn axisStepEqual(lhs: AxisStep, rhs: AxisStep) bool {
    return lhs.id == rhs.id and
        std.mem.eql(u8, lhs.name, rhs.name) and
        lhs.extent == rhs.extent;
}

fn placeSlice(
    comptime T: type,
    count: usize,
    cursor: *usize,
    allocation_alignment: *usize,
) error{CapacityOverflow}!usize {
    const bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.CapacityOverflow;
    return placeBytes(bytes, @alignOf(T), cursor, allocation_alignment);
}

fn placeBytes(
    bytes: usize,
    alignment: usize,
    cursor: *usize,
    allocation_alignment: *usize,
) error{CapacityOverflow}!usize {
    const mask = std.math.sub(usize, alignment, 1) catch unreachable;
    const padded = std.math.add(usize, cursor.*, mask) catch return error.CapacityOverflow;
    const offset = padded & ~mask;
    cursor.* = std.math.add(usize, offset, bytes) catch return error.CapacityOverflow;
    allocation_alignment.* = @max(allocation_alignment.*, alignment);
    return offset;
}

fn typedSlice(
    comptime T: type,
    storage: [*]u8,
    offset: usize,
    count: usize,
) []T {
    const pointer: [*]T = @ptrCast(@alignCast(storage + offset));
    return pointer[0..count];
}

fn initTestingSchedule() !Schedule {
    return Schedule.init(testing.allocator, Schedule.Limits.testing);
}

test "Schedule capacity follows an independent aligned byte model" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Schedule, "accy_kernel_schedule_capacity"),
        );
    }

    const limits = Schedule.Limits{
        .axes = 3,
        .steps = 5,
        .name_bytes = 7,
        .axis_ids = 9,
    };
    const capacity = try Schedule.Capacity.derive(limits);
    var expected: usize = 0;
    expected = std.mem.alignForward(usize, expected, @alignOf(Axis)) + 3 * @sizeOf(Axis);
    expected = std.mem.alignForward(usize, expected, @alignOf(Step)) + 5 * @sizeOf(Step);
    expected = std.mem.alignForward(usize, expected, @alignOf(u8)) + 7;
    try testing.expectEqual(expected, capacity.storage_bytes);
    try testing.expectEqual(@as(usize, 9), capacity.axis_ids);

    var overflow = limits;
    overflow.axes = std.math.maxInt(usize);
    try testing.expectError(error.CapacityOverflow, Schedule.Capacity.derive(overflow));
}

test "Schedule initialization retries after its one outer acquisition fails" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Schedule, "accy_kernel_schedule_single_acquisition"),
        );
    }

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        Schedule.init(failing.allocator(), Schedule.Limits.standard),
    );
    failing.fail_index = std.math.maxInt(usize);
    var schedule = try Schedule.init(failing.allocator(), Schedule.Limits.standard);
    schedule.deinit(failing.allocator());
}

test "Schedule records split bind and derives launch geometry" {
    var schedule = try initTestingSchedule();
    defer schedule.deinit(testing.allocator);

    const i = try schedule.addAxis("i", 1024);
    const split_i = try schedule.split(i, 256);
    try schedule.bind(split_i.outer, .block_x);
    try schedule.bind(split_i.inner, .thread_x);

    const launch = try schedule.launch();
    try testing.expectEqual(@as(u32, 4), launch.grid[0]);
    try testing.expectEqual(@as(u32, 256), launch.block[0]);
    try testing.expectEqual(@as(usize, 4), schedule.allSteps().len);
}

test "Schedule vectorization derives packet launch geometry" {
    var schedule = try initTestingSchedule();
    defer schedule.deinit(testing.allocator);

    const i = try schedule.addAxis("i", 32);
    const tiled_i = try schedule.tile(i, 16);
    try schedule.vectorize(tiled_i.inner, 4);
    try schedule.bind(tiled_i.outer, .block_x);
    try schedule.bind(tiled_i.inner, .thread_x);

    const launch = try schedule.launch();
    try testing.expectEqual(@as(u32, 2), launch.grid[0]);
    try testing.expectEqual(@as(u32, 4), launch.block[0]);
    try testing.expectEqual(@as(?u32, 4), schedule.allAxes()[1].vector_width);

    var snapshot = try createSnapshot(testing.allocator, Snapshot.Limits.testing, &schedule);
    defer snapshot.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 4), snapshot.allAxes()[1].vector_width);
    const snapshot_launch = try snapshot.launch();
    try testing.expectEqual(@as(u32, 2), snapshot_launch.grid[0]);
    try testing.expectEqual(@as(u32, 4), snapshot_launch.block[0]);
}

test "Schedule rejects duplicate bindings and non-divisible splits" {
    var schedule = try initTestingSchedule();
    defer schedule.deinit(testing.allocator);

    const i = try schedule.addAxis("i", 10);
    try testing.expectError(error.ExtentNotDivisible, schedule.split(i, 4));

    const j = try schedule.addAxis("j", 5);
    try schedule.bind(i, .block_x);
    try testing.expectError(error.BindTargetAlreadyUsed, schedule.bind(j, .block_x));
}

test "Schedule rejects invalid vectorization factors" {
    var schedule = try initTestingSchedule();
    defer schedule.deinit(testing.allocator);

    const i = try schedule.addAxis("i", 10);
    try testing.expectError(error.InvalidFactor, schedule.vectorize(i, 0));
    try testing.expectError(error.ExtentNotDivisible, schedule.vectorize(i, 4));
}

test "Schedule tiles non-divisible axes with ceil outer extent" {
    var schedule = try initTestingSchedule();
    defer schedule.deinit(testing.allocator);

    const i = try schedule.addAxis("i", 10);
    const tiled_i = try schedule.tile(i, 4);
    try schedule.bind(tiled_i.outer, .block_x);
    try schedule.bind(tiled_i.inner, .thread_x);

    const launch = try schedule.launch();
    try testing.expectEqual(@as(u32, 3), launch.grid[0]);
    try testing.expectEqual(@as(u32, 4), launch.block[0]);
    try testing.expectEqualStrings("i_tile", schedule.allAxes()[0].name);
    try testing.expectEqualStrings("i_lane", schedule.allAxes()[1].name);
}

test "Schedule split reclaims the replaced name and preserves shifted names" {
    const exact_limits = Schedule.Limits{
        .axes = 3,
        .steps = 3,
        .name_bytes = 17,
        .axis_ids = 4,
    };
    var schedule = try Schedule.init(testing.allocator, exact_limits);
    defer schedule.deinit(testing.allocator);
    const i = try schedule.addAxis("i", 8);
    const j = try schedule.addAxis("j", 4);
    _ = try schedule.split(i, 2);
    try testing.expectEqual(@as(usize, 17), schedule.capacityUsage().name_bytes);
    try testing.expectEqualStrings("j", (try schedule.getAxis(j)).name);
    try testing.expectEqualStrings("i", schedule.allSteps()[0].axis.name);
    try testing.expectEqualStrings("j", schedule.allSteps()[1].axis.name);

    var short_limits = exact_limits;
    short_limits.name_bytes -= 1;
    var rejected = try Schedule.init(testing.allocator, short_limits);
    defer rejected.deinit(testing.allocator);
    const rejected_i = try rejected.addAxis("i", 8);
    _ = try rejected.addAxis("j", 4);
    const before = rejected.fingerprint();
    try testing.expectError(error.NameCapacityExceeded, rejected.split(rejected_i, 2));
    try testing.expectEqual(before, rejected.fingerprint());
}

test "Schedule snapshot owns replayable schedule data" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(
                Snapshot,
                "accy_kernel_schedule_snapshot_lifetime_transitive_risk",
            ),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(
                Snapshot,
                "accy_kernel_schedule_snapshot_lifetime_foreign_risk",
            ),
        );
    }

    var snapshot: Snapshot = undefined;
    var schedule_fingerprint: u64 = 0;
    {
        var schedule = try initTestingSchedule();
        defer schedule.deinit(testing.allocator);

        const i = try schedule.addAxis("i", 32);
        const split_i = try schedule.split(i, 8);
        try schedule.bind(split_i.outer, .block_x);
        try schedule.bind(split_i.inner, .thread_x);

        snapshot = try createSnapshot(testing.allocator, Snapshot.Limits.testing, &schedule);
        schedule_fingerprint = schedule.fingerprint();
    }
    defer snapshot.deinit(testing.allocator);

    try testing.expectEqual(snapshot_version, snapshot.version);
    try testing.expectEqual(@as(usize, 2), snapshot.allAxes().len);
    try testing.expectEqualStrings("i_outer", snapshot.allAxes()[0].name);
    try testing.expectEqualStrings("i_inner", snapshot.allAxes()[1].name);
    try testing.expectEqual(@as(usize, 4), snapshot.allSteps().len);
    try testing.expectEqualStrings("i", snapshot.allSteps()[0].axis.name);

    const launch = try snapshot.launch();
    try testing.expectEqual(@as(u32, 4), launch.grid[0]);
    try testing.expectEqual(@as(u32, 8), launch.block[0]);
    try testing.expectEqual(schedule_fingerprint, snapshot.fingerprint());

    var replayed = try replaySnapshot(
        testing.allocator,
        try snapshot.requiredReplayLimits(),
        &snapshot,
    );
    defer replayed.deinit(testing.allocator);
    try testing.expectEqual(snapshot.fingerprint(), replayed.fingerprint());
    try testing.expectEqual(@as(usize, 2), replayed.allAxes().len);
    try testing.expectEqualStrings("i_outer", replayed.allAxes()[0].name);
    try testing.expectEqualStrings("i_inner", replayed.allAxes()[1].name);
    try testing.expectEqual(@as(usize, 4), replayed.allSteps().len);
}

test "Schedule fingerprint is stable and sensitive to replayable steps" {
    var first = try initTestingSchedule();
    defer first.deinit(testing.allocator);
    const first_i = try first.addAxis("i", 32);
    const first_split = try first.split(first_i, 8);
    try first.bind(first_split.outer, .block_x);
    try first.bind(first_split.inner, .thread_x);

    var second = try initTestingSchedule();
    defer second.deinit(testing.allocator);
    const second_i = try second.addAxis("i", 32);
    const second_split = try second.split(second_i, 8);
    try second.bind(second_split.outer, .block_x);
    try second.bind(second_split.inner, .thread_x);

    var changed = try initTestingSchedule();
    defer changed.deinit(testing.allocator);
    const changed_i = try changed.addAxis("i", 32);
    const changed_split = try changed.split(changed_i, 4);
    try changed.bind(changed_split.outer, .block_x);
    try changed.bind(changed_split.inner, .thread_x);

    try testing.expectEqual(first.fingerprint(), second.fingerprint());
    try testing.expect(first.fingerprint() != changed.fingerprint());
}

test "Schedule replay rejects unsupported snapshot versions" {
    var schedule = try initTestingSchedule();
    defer schedule.deinit(testing.allocator);

    const i = try schedule.addAxis("i", 32);
    const split_i = try schedule.split(i, 8);
    try schedule.bind(split_i.outer, .block_x);
    try schedule.bind(split_i.inner, .thread_x);

    var snapshot = try createSnapshot(testing.allocator, Snapshot.Limits.testing, &schedule);
    defer snapshot.deinit(testing.allocator);
    snapshot.version += 1;

    try testing.expectError(error.UnsupportedVersion, snapshot.requiredReplayLimits());
    try testing.expectError(error.UnsupportedVersion, replaySnapshot(
        testing.allocator,
        Schedule.Limits.testing,
        &snapshot,
    ));
}

test "Schedule admits independent maxima and preserves its fingerprint at max plus one" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Schedule, "accy_kernel_schedule_boundary_overload"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Schedule, "accy_kernel_schedule_boundary_foreign_risk"),
        );
    }

    const cases = [_]struct {
        limits: Schedule.Limits,
        expected: ScheduleError,
    }{
        .{
            .limits = .{ .axes = 1, .steps = 2, .name_bytes = 4, .axis_ids = 2 },
            .expected = error.AxisCapacityExceeded,
        },
        .{
            .limits = .{ .axes = 2, .steps = 1, .name_bytes = 4, .axis_ids = 2 },
            .expected = error.StepCapacityExceeded,
        },
        .{
            .limits = .{ .axes = 2, .steps = 2, .name_bytes = 2, .axis_ids = 2 },
            .expected = error.NameCapacityExceeded,
        },
        .{
            .limits = .{ .axes = 2, .steps = 2, .name_bytes = 4, .axis_ids = 1 },
            .expected = error.AxisIdCapacityExceeded,
        },
    };

    for (cases) |case| {
        var schedule = try Schedule.init(testing.allocator, case.limits);
        defer schedule.deinit(testing.allocator);
        _ = try schedule.addAxis("i", 8);
        const before = schedule.fingerprint();
        try testing.expectError(case.expected, schedule.addAxis("j", 8));
        try testing.expectEqual(before, schedule.fingerprint());
    }
}

test "Snapshot capacity follows an independent aligned byte model" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Snapshot, "accy_kernel_schedule_snapshot_capacity"),
        );
    }

    const limits = Snapshot.Limits{ .axes = 3, .steps = 5, .name_bytes = 7 };
    const capacity = try Snapshot.Capacity.derive(limits);
    var expected: usize = 0;
    expected = std.mem.alignForward(usize, expected, @alignOf(Axis)) + 3 * @sizeOf(Axis);
    expected = std.mem.alignForward(usize, expected, @alignOf(Step)) + 5 * @sizeOf(Step);
    expected = std.mem.alignForward(usize, expected, @alignOf(u8)) + 7;
    try testing.expectEqual(expected, capacity.storage_bytes);
}

test "Snapshot admits exact capacity and rejects max plus one before mutation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Snapshot, "accy_kernel_schedule_snapshot_boundary"),
        );
    }

    var schedule = try initTestingSchedule();
    defer schedule.deinit(testing.allocator);
    const axis = try schedule.addAxis("i", 32);
    const split_axis = try schedule.split(axis, 8);
    try schedule.bind(split_axis.outer, .block_x);
    try schedule.bind(split_axis.inner, .thread_x);

    const exact = try schedule.snapshotLimits();
    var accepted = try createSnapshot(testing.allocator, exact, &schedule);
    accepted.deinit(testing.allocator);

    const cases = [_]struct {
        limits: Snapshot.Limits,
        expected: ScheduleError,
    }{
        .{ .limits = .{
            .axes = exact.axes - 1,
            .steps = exact.steps,
            .name_bytes = exact.name_bytes,
        }, .expected = error.AxisCapacityExceeded },
        .{ .limits = .{
            .axes = exact.axes,
            .steps = exact.steps - 1,
            .name_bytes = exact.name_bytes,
        }, .expected = error.StepCapacityExceeded },
        .{ .limits = .{
            .axes = exact.axes,
            .steps = exact.steps,
            .name_bytes = exact.name_bytes - 1,
        }, .expected = error.NameCapacityExceeded },
    };
    for (cases) |case| {
        var rejected = try Snapshot.init(testing.allocator, case.limits);
        defer rejected.deinit(testing.allocator);
        const before_usage = rejected.capacityUsage();
        const before_fingerprint = rejected.fingerprint();
        try testing.expectError(case.expected, rejected.capture(&schedule));
        try testing.expectEqualDeep(before_usage, rejected.capacityUsage());
        try testing.expectEqual(before_fingerprint, rejected.fingerprint());
        try testing.expect(!rejected.captured);
    }
}

test "Schedule replay admits exact capacity and rolls back max plus one" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Schedule, "accy_kernel_schedule_replay_boundary"),
        );
    }

    var source = try initTestingSchedule();
    defer source.deinit(testing.allocator);
    const axis = try source.addAxis("i", 32);
    const split_axis = try source.split(axis, 8);
    try source.bind(split_axis.outer, .block_x);
    try source.bind(split_axis.inner, .thread_x);

    var snapshot = try createSnapshot(testing.allocator, Snapshot.Limits.testing, &source);
    defer snapshot.deinit(testing.allocator);
    const exact = try snapshot.requiredReplayLimits();
    const exact_capacity = try snapshot.requiredReplayCapacity();
    try testing.expectEqualDeep(exact, exact_capacity.asLimits());
    var accepted = try replaySnapshot(testing.allocator, exact, &snapshot);
    defer accepted.deinit(testing.allocator);
    try testing.expectEqual(snapshot.fingerprint(), accepted.fingerprint());

    const cases = [_]struct {
        limits: Schedule.Limits,
        expected: ScheduleError,
    }{
        .{ .limits = .{
            .axes = exact.axes - 1,
            .steps = exact.steps,
            .name_bytes = exact.name_bytes,
            .axis_ids = exact.axis_ids,
        }, .expected = error.AxisCapacityExceeded },
        .{ .limits = .{
            .axes = exact.axes,
            .steps = exact.steps - 1,
            .name_bytes = exact.name_bytes,
            .axis_ids = exact.axis_ids,
        }, .expected = error.StepCapacityExceeded },
        .{ .limits = .{
            .axes = exact.axes,
            .steps = exact.steps,
            .name_bytes = exact.name_bytes - 1,
            .axis_ids = exact.axis_ids,
        }, .expected = error.NameCapacityExceeded },
        .{ .limits = .{
            .axes = exact.axes,
            .steps = exact.steps,
            .name_bytes = exact.name_bytes,
            .axis_ids = exact.axis_ids - 1,
        }, .expected = error.AxisIdCapacityExceeded },
    };
    for (cases) |case| {
        var rejected = try Schedule.init(testing.allocator, case.limits);
        defer rejected.deinit(testing.allocator);
        const before_usage = rejected.capacityUsage();
        const before_fingerprint = rejected.fingerprint();
        try testing.expectError(case.expected, rejected.replay(try snapshot.record()));
        try testing.expectEqualDeep(before_usage, rejected.capacityUsage());
        try testing.expectEqual(before_fingerprint, rejected.fingerprint());

        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        try testing.expectError(
            case.expected,
            replaySnapshot(failing.allocator(), case.limits, &snapshot),
        );
        try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    }
}
