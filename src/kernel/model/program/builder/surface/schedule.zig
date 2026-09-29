const schedule_mod = @import("../../../core/root.zig").schedule;

pub const AxisId = schedule_mod.AxisId;
pub const BindTarget = schedule_mod.BindTarget;
pub const ScheduleError = schedule_mod.ScheduleError;
pub const Split = schedule_mod.Split;

pub fn axis(owner: anytype, name: []const u8, extent: ?u64) ScheduleError!AxisId {
    return owner.schedule.addAxis(name, extent);
}

pub fn split(owner: anytype, axis_id: AxisId, factor: u64) ScheduleError!Split {
    return owner.schedule.split(axis_id, factor);
}

pub fn tile(owner: anytype, axis_id: AxisId, factor: u64) ScheduleError!Split {
    return owner.schedule.tile(axis_id, factor);
}

pub fn bind(owner: anytype, axis_id: AxisId, target: BindTarget) ScheduleError!void {
    try owner.schedule.bind(axis_id, target);
}

pub fn vectorize(owner: anytype, axis_id: AxisId, width: u32) ScheduleError!void {
    try owner.schedule.vectorize(axis_id, width);
}

pub fn unroll(owner: anytype, axis_id: AxisId, factor: u32) ScheduleError!void {
    try owner.schedule.unroll(axis_id, factor);
}
