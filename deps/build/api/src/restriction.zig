const std = @import("std");

pub const Restriction = enum(u6) {
    storage_after_seal,
    no_boundary_wait_on_steady_path,
    recursion,
    indirect_calls,
    loops,
    fifo_within_priorities,
    ceiling_locking,
    detect_blocking,
    no_abort_statements,
    no_dynamic_attachment,
    no_dynamic_cpu_assignment,
    no_dynamic_priorities,
    no_implicit_heap_allocations,
    no_local_protected_objects,
    no_local_timing_events,
    no_protected_type_allocators,
    no_relative_delay,
    no_requeue_statements,
    no_select_statements,
    no_specific_termination_handlers,
    no_task_allocators,
    no_task_hierarchy,
    no_task_termination,
    simple_barriers,
    max_entry_queue_length_one,
    max_protected_entries_one,
    max_task_entries_zero,
    no_dependence_asynchronous_task_control,
    no_dependence_calendar,
    no_dependence_execution_time_group_budgets,
    no_dependence_execution_time_timers,
    no_dependence_synchronous_barriers,
    no_dependence_task_attributes,
    no_dependence_dispatching_domains,
};

pub const StandardProfile = enum(u1) {
    baseline,
    ravenscar_2022,

    pub fn humanLabel(profile: StandardProfile) []const u8 {
        return switch (profile) {
            .baseline => "Tiny baseline",
            .ravenscar_2022 => "Ravenscar 2022",
        };
    }

    pub fn restrictions(profile: StandardProfile) RestrictionSet {
        return switch (profile) {
            .baseline => .baseline(),
            .ravenscar_2022 => .ravenscar2022(),
        };
    }
};

pub const baseline_restriction_count: usize = 5;
pub const ravenscar_2022_restriction_count: usize = 29;
pub const restriction_count: usize = baseline_restriction_count +
    ravenscar_2022_restriction_count;

pub const RestrictionSet = packed struct(u34) {
    storage_after_seal: bool = false,
    no_boundary_wait_on_steady_path: bool = false,
    recursion: bool = false,
    indirect_calls: bool = false,
    loops: bool = false,
    fifo_within_priorities: bool = false,
    ceiling_locking: bool = false,
    detect_blocking: bool = false,
    no_abort_statements: bool = false,
    no_dynamic_attachment: bool = false,
    no_dynamic_cpu_assignment: bool = false,
    no_dynamic_priorities: bool = false,
    no_implicit_heap_allocations: bool = false,
    no_local_protected_objects: bool = false,
    no_local_timing_events: bool = false,
    no_protected_type_allocators: bool = false,
    no_relative_delay: bool = false,
    no_requeue_statements: bool = false,
    no_select_statements: bool = false,
    no_specific_termination_handlers: bool = false,
    no_task_allocators: bool = false,
    no_task_hierarchy: bool = false,
    no_task_termination: bool = false,
    simple_barriers: bool = false,
    max_entry_queue_length_one: bool = false,
    max_protected_entries_one: bool = false,
    max_task_entries_zero: bool = false,
    no_dependence_asynchronous_task_control: bool = false,
    no_dependence_calendar: bool = false,
    no_dependence_execution_time_group_budgets: bool = false,
    no_dependence_execution_time_timers: bool = false,
    no_dependence_synchronous_barriers: bool = false,
    no_dependence_task_attributes: bool = false,
    no_dependence_dispatching_domains: bool = false,

    pub fn contains(set: RestrictionSet, restriction: Restriction) bool {
        return set.bits() & restrictionBit(restriction) != 0;
    }

    pub fn isEmpty(set: RestrictionSet) bool {
        return set.bits() == 0;
    }

    pub fn insert(set: *RestrictionSet, restriction: Restriction) void {
        set.* = @bitCast(set.bits() | restrictionBit(restriction));
    }

    pub fn join(lhs: RestrictionSet, rhs: RestrictionSet) RestrictionSet {
        return @bitCast(lhs.bits() | rhs.bits());
    }

    pub fn includes(set: RestrictionSet, required: RestrictionSet) bool {
        return set.bits() & required.bits() == required.bits();
    }

    pub fn standardProfile(set: RestrictionSet) ?StandardProfile {
        if (set.includes(ravenscar2022())) return .ravenscar_2022;
        if (set.includes(baseline())) return .baseline;
        return null;
    }

    pub fn baseline() RestrictionSet {
        return .{
            .storage_after_seal = true,
            .no_boundary_wait_on_steady_path = true,
            .recursion = true,
            .indirect_calls = true,
            .loops = true,
        };
    }

    pub fn ravenscar2022() RestrictionSet {
        return .{
            .fifo_within_priorities = true,
            .ceiling_locking = true,
            .detect_blocking = true,
            .no_abort_statements = true,
            .no_dynamic_attachment = true,
            .no_dynamic_cpu_assignment = true,
            .no_dynamic_priorities = true,
            .no_implicit_heap_allocations = true,
            .no_local_protected_objects = true,
            .no_local_timing_events = true,
            .no_protected_type_allocators = true,
            .no_relative_delay = true,
            .no_requeue_statements = true,
            .no_select_statements = true,
            .no_specific_termination_handlers = true,
            .no_task_allocators = true,
            .no_task_hierarchy = true,
            .no_task_termination = true,
            .simple_barriers = true,
            .max_entry_queue_length_one = true,
            .max_protected_entries_one = true,
            .max_task_entries_zero = true,
            .no_dependence_asynchronous_task_control = true,
            .no_dependence_calendar = true,
            .no_dependence_execution_time_group_budgets = true,
            .no_dependence_execution_time_timers = true,
            .no_dependence_synchronous_barriers = true,
            .no_dependence_task_attributes = true,
            .no_dependence_dispatching_domains = true,
        };
    }

    pub fn bits(set: RestrictionSet) u34 {
        return @bitCast(set);
    }

    pub fn fromBits(value: u34) RestrictionSet {
        return @bitCast(value);
    }

    fn restrictionBit(restriction: Restriction) u34 {
        return @as(u34, 1) << @backingInt(restriction);
    }
};

test "baseline and Ravenscar have exact disjoint membership" {
    const baseline = RestrictionSet.baseline();
    const ravenscar = RestrictionSet.ravenscar2022();
    try std.testing.expectEqual(
        @as(usize, baseline_restriction_count),
        @popCount(baseline.bits()),
    );
    try std.testing.expectEqual(
        @as(usize, ravenscar_2022_restriction_count),
        @popCount(ravenscar.bits()),
    );
    try std.testing.expectEqual(@as(u34, 0), baseline.bits() & ravenscar.bits());
    try std.testing.expectEqual(StandardProfile.baseline, baseline.standardProfile().?);
    try std.testing.expectEqual(
        StandardProfile.ravenscar_2022,
        ravenscar.standardProfile().?,
    );
}

test "restriction joins obey exact laws and monotonicity" {
    const empty: RestrictionSet = .{};
    const first = RestrictionSet{ .storage_after_seal = true, .recursion = true };
    const second = RestrictionSet{ .indirect_calls = true, .loops = true };
    const third = RestrictionSet{ .storage_after_seal = true, .loops = true };
    try std.testing.expectEqual(first.bits(), first.join(empty).bits());
    try std.testing.expectEqual(first.bits(), empty.join(first).bits());
    try std.testing.expectEqual(first.bits(), first.join(first).bits());
    try std.testing.expectEqual(first.join(second).bits(), second.join(first).bits());
    try std.testing.expectEqual(
        first.join(second).join(third).bits(),
        first.join(second.join(third)).bits(),
    );
    const larger = first.join(second);
    try std.testing.expect(larger.includes(first));
    try std.testing.expect(larger.join(third).includes(first.join(third)));
}
