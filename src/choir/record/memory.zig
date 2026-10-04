const std = @import("std");
const gpu_abi = @import("gpu_abi");
const reference = @import("root.zig").reference;

pub const LayoutKind = enum {
    scalar,
    row_major,
    dynamic_row_major,

    pub fn name(self: LayoutKind) []const u8 {
        return switch (self) {
            .scalar => "scalar",
            .row_major => "row_major",
            .dynamic_row_major => "dynamic_row_major",
        };
    }

    pub fn hasStaticStrides(self: LayoutKind) bool {
        return self == .scalar or self == .row_major;
    }
};

pub const OutputSource = union(enum) {
    kernel_written: usize,
    aliased: usize,
};

pub const BoundaryTransfer = enum {
    none,
    host_to_device,
    device_to_host,
    bidirectional,

    pub fn needsHostInput(self: BoundaryTransfer) bool {
        return self == .host_to_device or self == .bidirectional;
    }

    pub fn needsHostOutput(self: BoundaryTransfer) bool {
        return self == .device_to_host or self == .bidirectional;
    }
};

pub const MemoryAccess = enum {
    read_only,
    write_only,
    read_write,
};

pub const MemorySpace = enum {
    host,
    device_global,
    device_constant,
    device_shared,
    unified,

    pub fn name(self: MemorySpace) []const u8 {
        return switch (self) {
            .host => "host",
            .device_global => "device_global",
            .device_constant => "device_constant",
            .device_shared => "device_shared",
            .unified => "unified",
        };
    }
};

pub const BufferRole = struct {
    input: bool = false,
    output: bool = false,
    temporary: bool = false,
    constant: bool = false,

    pub fn isBoundary(self: BufferRole) bool {
        return self.input or self.output;
    }
};

pub const Slot = struct {
    id: usize,
    value: reference.Value,
    producer: ?reference.Operation,
    function: ?reference.Operation,
    role: BufferRole,
    dtype: gpu_abi.DType,
    dims: []const i64,
    element_count: ?u64,
    row_major_strides: ?[]const u64,
    byte_size: ?u64,
};

pub const Elision = struct {
    value: reference.Value,
    producer: reference.Operation,
    root: reference.Operation,
    cluster_index: usize,
};

pub const Buffers = struct {
    slots: []const Slot,
    elisions: []const Elision,
    input_slot_count: usize,
    output_slot_count: usize,
    temporary_slot_count: usize,
    constant_slot_count: usize,
    dynamic_slot_count: usize,
    total_static_bytes: u64,
};

pub const Assignment = struct {
    slot_id: usize,
    value: reference.Value,
    producer: ?reference.Operation,
    role: BufferRole,
    space: MemorySpace,
    access: MemoryAccess,
    transfer: BoundaryTransfer,
    byte_size: ?u64,
    output_source: ?OutputSource,
};

pub const Spaces = struct {
    assignments: []const Assignment,
    host_slot_count: usize,
    device_global_slot_count: usize,
    device_constant_slot_count: usize,
    device_shared_slot_count: usize,
    unified_slot_count: usize,
    host_input_transfer_count: usize,
    host_output_transfer_count: usize,
    dynamic_slot_count: usize,
    elided_value_count: usize,
    total_static_bytes: u64,
};

pub const Layout = struct {
    slot_id: usize,
    value: reference.Value,
    producer: ?reference.Operation,
    role: BufferRole,
    dtype: gpu_abi.DType,
    memory_space: MemorySpace,
    kind: LayoutKind,
    rank: usize,
    dims: []const i64,
    element_strides: ?[]const u64,
    minor_to_major: []const usize,
    element_count: ?u64,
    byte_size: ?u64,
    element_size: u64,
    alignment: u64,
    contiguous: bool,
    static_layout: bool,
};

pub const Layouts = struct {
    assignments: []const Layout,
    scalar_layout_count: usize,
    row_major_layout_count: usize,
    dynamic_row_major_layout_count: usize,
    host_slot_count: usize,
    device_global_slot_count: usize,
    device_constant_slot_count: usize,
    device_shared_slot_count: usize,
    unified_slot_count: usize,
    dynamic_slot_count: usize,
    elided_value_count: usize,
    total_static_bytes: u64,
};

pub const Binding = struct {
    value: reference.Value,
    slot_id: usize,

    pub fn lessThan(_: void, left: Binding, right: Binding) bool {
        const lhs = key(left.value);
        const rhs = key(right.value);
        return std.mem.lessThan(u32, &lhs, &rhs);
    }

    fn key(value: reference.Value) [5]u32 {
        return switch (value) {
            .result => |item| .{ item.operation.ordinal, 0, 0, 0, item.position },
            .argument => |item| .{
                item.operation.ordinal,
                1,
                item.region,
                item.block,
                item.position,
            },
        };
    }
};

pub const Record = struct {
    buffers: Buffers,
    bindings: []const Binding,
    spaces: Spaces,
    layouts: Layouts,
};

pub fn validate(
    allocator: std.mem.Allocator,
    value: Record,
    dispatch: @import("root.zig").dispatch.Record,
) !void {
    try validateBindings(allocator, value);
    try validateBufferCounts(value.buffers);
    try validateSpaceCounts(value.spaces, value.buffers.elisions.len);
    try validateLayoutCounts(value.layouts, value.buffers.elisions.len);
    const slots = value.buffers.slots.len;
    if (value.spaces.assignments.len != slots or value.layouts.assignments.len != slots) {
        return error.InvalidStageRecord;
    }
    for (value.buffers.slots, 0..) |slot, index| {
        if (slot.id != index) return error.InvalidStageRecord;
        if (slot.row_major_strides) |strides| {
            if (strides.len != slot.dims.len) return error.InvalidStageRecord;
        }
    }
    for (value.buffers.elisions) |elision| {
        if (elision.cluster_index >= dispatch.fusion.clusters.len) return error.InvalidStageRecord;
    }
    for (value.spaces.assignments, 0..) |assignment, index| {
        if (assignment.slot_id != index) return error.InvalidStageRecord;
        if (assignment.output_source) |source| switch (source) {
            .aliased => |slot| if (slot >= slots) return error.InvalidStageRecord,
            .kernel_written => |work| if (work >= dispatch.schedule.work_items.len) {
                return error.InvalidStageRecord;
            },
        };
    }
    for (value.layouts.assignments, 0..) |layout, index| {
        if (layout.slot_id != index or layout.rank != layout.dims.len or
            layout.minor_to_major.len != layout.rank) return error.InvalidStageRecord;
        if (layout.element_strides) |strides| {
            if (strides.len != layout.rank) return error.InvalidStageRecord;
        }
        for (layout.minor_to_major) |axis| {
            if (axis >= layout.rank) return error.InvalidStageRecord;
        }
    }
}

fn validateBindings(allocator: std.mem.Allocator, value: Record) !void {
    const primary = try allocator.alloc(bool, value.buffers.slots.len);
    defer allocator.free(primary);
    @memset(primary, false);
    for (value.bindings, 0..) |binding, index| {
        if (binding.slot_id >= primary.len) return error.InvalidStageRecord;
        if (index != 0 and !Binding.lessThan({}, value.bindings[index - 1], binding)) {
            return error.InvalidStageRecord;
        }
        if (std.meta.eql(binding.value, value.buffers.slots[binding.slot_id].value)) {
            primary[binding.slot_id] = true;
        }
    }
    for (primary) |present| if (!present) return error.InvalidStageRecord;
}

const SizeCounts = struct {
    dynamic: usize = 0,
    bytes: u64 = 0,

    fn add(self: *SizeCounts, bytes: ?u64) !void {
        if (bytes) |size| {
            self.bytes = std.math.add(u64, self.bytes, size) catch
                return error.InvalidStageRecord;
        } else self.dynamic += 1;
    }

    fn matches(self: SizeCounts, value: anytype) bool {
        return self.dynamic == value.dynamic_slot_count and self.bytes == value.total_static_bytes;
    }
};

const SpaceCounts = struct {
    values: [5]usize = @splat(0),

    fn add(self: *SpaceCounts, space: MemorySpace) void {
        const index: usize = switch (space) {
            .host => 0,
            .device_global => 1,
            .device_constant => 2,
            .device_shared => 3,
            .unified => 4,
        };
        self.values[index] += 1;
    }

    fn matches(self: SpaceCounts, value: anytype) bool {
        return std.mem.eql(usize, &self.values, &.{
            value.host_slot_count,
            value.device_global_slot_count,
            value.device_constant_slot_count,
            value.device_shared_slot_count,
            value.unified_slot_count,
        });
    }
};

fn validateBufferCounts(value: Buffers) !void {
    var roles: [4]usize = @splat(0);
    var sizes: SizeCounts = .{};
    for (value.slots) |slot| {
        if (slot.role.input) roles[0] += 1;
        if (slot.role.output) roles[1] += 1;
        if (slot.role.temporary) roles[2] += 1;
        if (slot.role.constant) roles[3] += 1;
        try sizes.add(slot.byte_size);
    }
    if (!sizes.matches(value) or !std.mem.eql(usize, &roles, &.{
        value.input_slot_count,
        value.output_slot_count,
        value.temporary_slot_count,
        value.constant_slot_count,
    })) return error.InvalidStageRecord;
}

fn validateSpaceCounts(value: Spaces, elisions: usize) !void {
    var spaces: SpaceCounts = .{};
    var sizes: SizeCounts = .{};
    var inputs: usize = 0;
    var outputs: usize = 0;
    for (value.assignments) |assignment| {
        spaces.add(assignment.space);
        try sizes.add(assignment.byte_size);
        if (assignment.transfer.needsHostInput()) inputs += 1;
        if (assignment.transfer.needsHostOutput()) outputs += 1;
    }
    if (!spaces.matches(value) or !sizes.matches(value) or
        inputs != value.host_input_transfer_count or outputs != value.host_output_transfer_count or
        elisions != value.elided_value_count) return error.InvalidStageRecord;
}

fn validateLayoutCounts(value: Layouts, elisions: usize) !void {
    var spaces: SpaceCounts = .{};
    var sizes: SizeCounts = .{};
    var kinds: [3]usize = @splat(0);
    for (value.assignments) |assignment| {
        spaces.add(assignment.memory_space);
        try sizes.add(assignment.byte_size);
        switch (assignment.kind) {
            .scalar => kinds[0] += 1,
            .row_major => kinds[1] += 1,
            .dynamic_row_major => kinds[2] += 1,
        }
    }
    if (!spaces.matches(value) or !sizes.matches(value) or elisions != value.elided_value_count or
        !std.mem.eql(usize, &kinds, &.{
            value.scalar_layout_count,
            value.row_major_layout_count,
            value.dynamic_row_major_layout_count,
        })) return error.InvalidStageRecord;
}
