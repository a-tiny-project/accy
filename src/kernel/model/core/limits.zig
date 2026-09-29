const choir = @import("choir");
const schedule = @import("schedule/root.zig");

pub const RawLimits = struct {
    context: choir.ir.Context.Limits,
    parameters: usize,
    kernel_name_bytes: usize,
    temporary_values: usize,
    temporary_types: usize,

    pub const standard: RawLimits = .{
        .context = choir.ir.Context.Limits.standard,
        .parameters = 64,
        .kernel_name_bytes = 512,
        .temporary_values = 64,
        .temporary_types = 64,
    };

    pub const testing: RawLimits = .{
        .context = choir.ir.Context.Limits.testing,
        .parameters = 256,
        .kernel_name_bytes = 2048,
        .temporary_values = 256,
        .temporary_types = 256,
    };

    pub const borrowed_standard: RawLimits = .{
        .context = borrowedContextLimits(false),
        .parameters = 64,
        .kernel_name_bytes = 512,
        .temporary_values = 64,
        .temporary_types = 64,
    };

    pub const borrowed_testing: RawLimits = .{
        .context = borrowedContextLimits(true),
        .parameters = 256,
        .kernel_name_bytes = 2048,
        .temporary_values = 256,
        .temporary_types = 256,
    };
};

pub const Limits = struct {
    context: choir.ir.Context.Limits,
    parameters: usize,
    kernel_name_bytes: usize,
    temporary_values: usize,
    temporary_types: usize,
    schedule: schedule.Schedule.Limits,
    snapshot: schedule.Snapshot.Limits,

    pub const standard: Limits = fromRaw(
        RawLimits.standard,
        schedule.Schedule.Limits.standard,
        schedule.Snapshot.Limits.standard,
    );

    pub const testing: Limits = fromRaw(
        RawLimits.testing,
        schedule.Schedule.Limits.testing,
        schedule.Snapshot.Limits.testing,
    );

    pub const borrowed_standard: Limits = fromRaw(
        RawLimits.borrowed_standard,
        schedule.Schedule.Limits.standard,
        schedule.Snapshot.Limits.standard,
    );

    pub const borrowed_testing: Limits = fromRaw(
        RawLimits.borrowed_testing,
        schedule.Schedule.Limits.testing,
        schedule.Snapshot.Limits.testing,
    );

    pub fn raw(self: Limits) RawLimits {
        return .{
            .context = self.context,
            .parameters = self.parameters,
            .kernel_name_bytes = self.kernel_name_bytes,
            .temporary_values = self.temporary_values,
            .temporary_types = self.temporary_types,
        };
    }

    fn fromRaw(
        raw_limits: RawLimits,
        schedule_limits: schedule.Schedule.Limits,
        snapshot_limits: schedule.Snapshot.Limits,
    ) Limits {
        return .{
            .context = raw_limits.context,
            .parameters = raw_limits.parameters,
            .kernel_name_bytes = raw_limits.kernel_name_bytes,
            .temporary_values = raw_limits.temporary_values,
            .temporary_types = raw_limits.temporary_types,
            .schedule = schedule_limits,
            .snapshot = snapshot_limits,
        };
    }
};

fn borrowedContextLimits(comptime testing_limits: bool) choir.ir.Context.Limits {
    const scale: usize = if (testing_limits) 4 else 1;
    return .{
        .maximum_alignment = .@"64",
        .configuration = .{
            .table_bytes = 16 * 1024 * scale,
            .name_bytes = 8 * 1024 * scale,
            .interface_bytes = 16 * 1024 * scale,
            .transaction_bytes = 8 * 1024 * scale,
        },
        .types = .{
            .table_bytes = 32 * 1024 * scale,
            .key_bytes = 32 * 1024 * scale,
            .payload_bytes = 32 * 1024 * scale,
        },
        .attributes = .{
            .table_bytes = 64 * 1024 * scale,
            .payload_bytes = 64 * 1024 * scale,
        },
        .operations = .{
            .storage_bytes = 512 * 1024 * scale,
            .nested_bytes = 512 * 1024 * scale,
        },
        .diagnostics = .{
            .handler_bytes = 4 * 1024 * scale,
            .payload_bytes = 16 * 1024 * scale,
        },
        .transient_bytes = 64 * 1024 * scale,
    };
}
