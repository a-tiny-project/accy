const std = @import("std");
const contract = @import("contract.zig");
const Context = @import("context.zig").Context;

const Access = contract.Access;
const Status = contract.Status;

/// One invocation-scoped byte resource with explicit access.
/// The pointed-to bytes remain owned by the invocation caller.
pub const Resource = extern struct {
    context_cookie: u64,
    invocation_id: u64,
    handle: u64,
    byte_size: u64,
    access: u32,
    reserved: u32 = 0,

    pub fn init(
        context_cookie: u64,
        invocation_id: u64,
        buffer: []u8,
        access_value: Access,
    ) Resource {
        return .{
            .context_cookie = context_cookie,
            .invocation_id = invocation_id,
            .handle = @intFromPtr(buffer.ptr),
            .byte_size = buffer.len,
            .access = @backingInt(access_value),
        };
    }

    pub fn validate(self: Resource, frame: *const Frame) Status {
        if (self.context_cookie != frame.context_cookie or self.invocation_id != frame.invocation_id) return .invalid_resource;
        if (self.handle == 0 or self.byte_size == 0) return .invalid_resource;
        if (self.accessValue() == null) return .invalid_resource;
        return .ok;
    }

    pub fn accessValue(self: Resource) ?Access {
        return contract.decodeAccess(self.access);
    }

    pub fn bytes(self: Resource) StatusOrBytes {
        const length = std.math.cast(usize, self.byte_size) orelse return .{ .status = .invalid_resource };
        if (self.handle == 0 or length == 0) return .{ .status = .invalid_resource };
        const pointer: [*]u8 = @ptrFromInt(self.handle);
        return .{ .value = pointer[0..length] };
    }
};

/// Versioned invocation header and borrowed resource table.
/// Callers retain frame storage until synchronous return.
pub const Frame = extern struct {
    version: u32,
    byte_size: u32,
    invocation_id: u64,
    context_cookie: u64,
    resources_address: u64,
    resource_count: u32,
    status: u32,

    pub fn init(
        context_cookie: u64,
        invocation_id: u64,
        resource_values: []Resource,
    ) Frame {
        std.debug.assert(resource_values.len <= contract.max_resources);
        return .{
            .version = contract.version,
            .byte_size = @sizeOf(Frame),
            .invocation_id = invocation_id,
            .context_cookie = context_cookie,
            .resources_address = if (resource_values.len == 0) 0 else @intFromPtr(resource_values.ptr),
            .resource_count = @intCast(resource_values.len),
            .status = @backingInt(Status.ok),
        };
    }

    pub fn validate(self: *const Frame, context: *const Context) Status {
        if (self.version != contract.version or self.byte_size < @sizeOf(Frame)) return .incompatible_frame;
        if (self.context_cookie != context.owner_cookie or self.invocation_id == 0) return .incompatible_frame;
        if (self.resource_count > contract.max_resources) return .incompatible_frame;
        if (self.resource_count != 0 and self.resources_address == 0) return .incompatible_frame;
        return .ok;
    }

    pub fn resources(self: *const Frame, context: *const Context) StatusOrResources {
        const frame_status = self.validate(context);
        if (frame_status != .ok) return .{ .status = frame_status };
        if (self.resource_count == 0) return .{ .value = &.{} };
        const count = std.math.cast(usize, self.resource_count) orelse return .{ .status = .incompatible_frame };
        const pointer: [*]Resource = @ptrFromInt(self.resources_address);
        const values = pointer[0..count];
        for (values) |resource| {
            const resource_status = resource.validate(self);
            if (resource_status != .ok) return .{ .status = resource_status };
        }
        return .{ .value = values };
    }

    pub fn setStatus(self: *Frame, value: Status) void {
        self.status = @backingInt(value);
    }

    pub fn setStatusIfCompatible(self: *Frame, value: Status) void {
        if (self.version == contract.version and self.byte_size >= @sizeOf(Frame)) self.setStatus(value);
    }

    pub fn statusValue(self: Frame) Status {
        return contract.decodeStatus(self.status);
    }
};

pub const StatusOrResources = union(enum) {
    status: Status,
    value: []Resource,
};

pub const StatusOrBytes = union(enum) {
    status: Status,
    value: []u8,
};
