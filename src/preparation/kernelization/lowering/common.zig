const std = @import("std");
const gpu = @import("gpu");
const alloc_fixed = @import("alloc_fixed");
const choir = @import("choir");
const accy_choir = @import("../../../choir/root.zig");

pub const ir = choir.ir;
pub const LoweringError = gpu.BackendError || error{ WorkExhausted, WorkOverflow };
pub const dialect_mod = accy_choir.dialect;
pub const kernel_root = @import("../../../kernel/model/root.zig");
pub const bufferization = @import("../../bufferization/root.zig");
pub const fusion = @import("../../fusion/root.zig");
const kernelization_model = @import("../model/root.zig");
pub const schedule_planning = @import("../../schedule/root.zig");
pub const shape_analysis = @import("../../shape/root.zig");

pub const i64_attr_list_stack_capacity: usize = 8;

pub fn dialectAttrPayload(
    op: *ir.Operation,
    attr_name: []const u8,
    expected_dialect_attr_name: []const u8,
) gpu.BackendError![]const u8 {
    const attr = op.getAttr(attr_name) orelse return error.InvalidArtifact;
    if (!std.mem.eql(u8, attr.abstract.name, expected_dialect_attr_name)) {
        return error.InvalidArtifact;
    }
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return error.InvalidArtifact;
    return dialect_attr.payload;
}

pub fn readIntegerAttr(op: *const ir.Operation, attr_name: []const u8) gpu.BackendError!i64 {
    const attr = op.getAttr(attr_name) orelse return error.InvalidArtifact;
    if (!std.mem.eql(u8, attr.abstract.name, "builtin.integer")) return error.InvalidArtifact;
    const int_attr = attr.cast(ir.Attribute.IntegerAttr) orelse return error.InvalidArtifact;
    return int_attr.getValue();
}

pub fn readI64ListAttrBounded(
    op: *ir.Operation,
    attr_name: []const u8,
    expected_dialect_attr_name: []const u8,
    buffer: []i64,
) gpu.BackendError![]const i64 {
    const payload = try dialectAttrPayload(op, attr_name, expected_dialect_attr_name);
    if (payload.len % @sizeOf(i64) != 0) return error.InvalidArtifact;
    if (payload.len / @sizeOf(i64) > buffer.len) return error.CapabilityMismatch;
    const values = buffer[0 .. payload.len / @sizeOf(i64)];
    for (values, 0..) |*value, index| {
        const start = index * @sizeOf(i64);
        @memcpy(std.mem.asBytes(value), payload[start..][0..@sizeOf(i64)]);
    }
    return values;
}

pub fn constantPayloadForSlot(
    slot: bufferization.BufferSlot,
) gpu.BackendError![]const u8 {
    if (!slot.role.constant) return &.{};
    const producer = slot.producer orelse return error.InvalidArtifact;
    if (!isName(producer.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) {
        return error.InvalidArtifact;
    }
    const attr = producer.getAttr("payload") orelse return error.InvalidArtifact;
    if (!std.mem.eql(
        u8,
        attr.abstract.name,
        dialect_mod.AccyDialect.ConstantOp.payload_attr_name,
    )) {
        return error.InvalidArtifact;
    }
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return error.InvalidArtifact;
    if (slot.byte_size) |byte_size| {
        const expected = std.math.cast(usize, byte_size) orelse return error.InvalidArtifact;
        if (dialect_attr.payload.len != expected) return error.InvalidArtifact;
    }
    return dialect_attr.payload;
}

pub fn constantPayloadEqualsF32(payload: []const u8, expected: f32) bool {
    return payload.len == @sizeOf(f32) and std.mem.eql(u8, payload, std.mem.asBytes(&expected));
}

pub fn constantPayloadEqualsI32(payload: []const u8, expected: i32) bool {
    return payload.len == @sizeOf(i32) and std.mem.eql(u8, payload, std.mem.asBytes(&expected));
}

pub fn constantPayloadEqualsF16(payload: []const u8, expected: f16) bool {
    return payload.len == @sizeOf(f16) and std.mem.eql(u8, payload, std.mem.asBytes(&expected));
}

pub fn staticElementCountU32(slot: bufferization.BufferSlot) gpu.BackendError!u32 {
    const count = slot.element_count orelse return error.CapabilityMismatch;
    if (count == 0) return error.CapabilityMismatch;
    return std.math.cast(u32, count) orelse return error.CapabilityMismatch;
}

pub fn staticPositiveDimU32(dim: i64) gpu.BackendError!u32 {
    if (dim <= 0) return error.CapabilityMismatch;
    return std.math.cast(u32, dim) orelse return error.CapabilityMismatch;
}

pub fn bufferSlotById(
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    slot_id: usize,
) ?*const bufferization.BufferSlot {
    if (slot_id < buffer_plan.slots.items.len and buffer_plan.slots.items[slot_id].id == slot_id) {
        return &buffer_plan.slots.items[slot_id];
    }
    for (buffer_plan.slots.items) |*slot| {
        if (slot.id == slot_id) return slot;
    }
    return null;
}

pub fn externalInputIndex(
    outline: kernelization_model.KernelOutline,
    slot_id: usize,
) ?usize {
    for (outline.input_slot_ids, 0..) |input_slot_id, index| {
        if (input_slot_id == slot_id) return index;
    }
    return null;
}

pub fn mapKernelBuildError(err: anyerror) LoweringError {
    return switch (err) {
        error.WorkExhausted,
        error.ParameterCapacityExceeded,
        error.KernelNameCapacityExceeded,
        error.TemporaryValueCapacityExceeded,
        error.TemporaryTypeCapacityExceeded,
        error.ContextCapacityExceeded,
        error.AxisCapacityExceeded,
        error.StepCapacityExceeded,
        error.NameCapacityExceeded,
        error.AxisIdCapacityExceeded,
        error.NestingLimitExceeded,
        => error.WorkExhausted,
        error.WorkOverflow,
        error.CapacityOverflow,
        error.ValueCountOverflow,
        error.CountOverflow,
        => error.WorkOverflow,
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedDType => error.CapabilityMismatch,
        error.VerificationFailed => error.InvalidArtifact,
        else => error.InvalidArtifact,
    };
}

pub fn mapGeneratedKernelError(err: anyerror) LoweringError {
    return switch (err) {
        error.UnsupportedOperation => error.UnsupportedOperation,
        error.UnsupportedArtifactFormat => error.UnsupportedArtifactFormat,
        error.CapabilityMismatch => error.CapabilityMismatch,
        error.InvalidArtifact => error.InvalidArtifact,
        error.OutOfMemory => error.OutOfMemory,
        else => mapKernelBuildError(err),
    };
}

pub fn isName(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
}

pub fn optionalSplatConstantValue(
    inner: anytype,
    op: *ir.Operation,
) LoweringError!?kernel_root.Value {
    return splatConstantValue(inner, op) catch |err| switch (err) {
        error.UnsupportedOperation => null,
        else => return mapGeneratedKernelError(err),
    };
}

pub fn splatConstantValue(inner: anytype, op: *ir.Operation) !kernel_root.Value {
    const constant = dialect_mod.AccyDialect.ConstantOp{ .op = op };
    const payload = constant.getPayload() orelse return error.InvalidArtifact;
    const result = op.getResult(0) orelse return error.InvalidArtifact;
    var dtype_arena_buffer: [160]u8 = undefined;
    var dtype_arena = alloc_fixed.FixedBuffer.init(dtype_arena_buffer[0..]);
    const result_type = dialect_mod.decodeTensorType(
        dtype_arena.allocator(),
        result.type,
    ) catch return error.InvalidArtifact;
    switch (result_type.dtype) {
        .f32 => {
            if (payload.len < 4 or payload.len % 4 != 0) return error.UnsupportedOperation;
            var first: f32 = undefined;
            @memcpy(std.mem.asBytes(&first), payload[0..4]);
            var offset: usize = 4;
            while (offset < payload.len) : (offset += 4) {
                var value: f32 = undefined;
                @memcpy(std.mem.asBytes(&value), payload[offset..][0..4]);
                if (@as(u32, @bitCast(value)) != @as(u32, @bitCast(first))) {
                    return error.UnsupportedOperation;
                }
            }
            return inner.constantFloat(.f32, first);
        },
        .i32 => {
            if (payload.len < 4 or payload.len % 4 != 0) return error.UnsupportedOperation;
            var first: i32 = undefined;
            @memcpy(std.mem.asBytes(&first), payload[0..4]);
            var offset: usize = 4;
            while (offset < payload.len) : (offset += 4) {
                var value: i32 = undefined;
                @memcpy(std.mem.asBytes(&value), payload[offset..][0..4]);
                if (value != first) return error.UnsupportedOperation;
            }
            return inner.constantInt(.i32, first);
        },
        .i1 => {
            if (payload.len == 0) return error.UnsupportedOperation;
            const first = payload[0];
            for (payload[1..]) |value| {
                if (value != first) return error.UnsupportedOperation;
            }
            return inner.constantBool(first != 0);
        },
        else => return error.UnsupportedOperation,
    }
}
