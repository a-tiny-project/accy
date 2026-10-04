const std = @import("std");
const composition = @import("../root.zig");
const loaded = @import("root.zig");

const abi = composition.abi;
const model = composition.module;
const source = composition.source;

pub fn invoke(context_optional: ?*abi.Context, call_site_id: u64, frame_optional: ?*abi.Frame) callconv(.c) i64 {
    const context = context_optional orelse {
        if (frame_optional) |frame| frame.setStatusIfCompatible(.incompatible_context);
        return statusCode(.incompatible_context);
    };
    const frame = frame_optional orelse return statusCode(.incompatible_frame);
    const context_status = context.validate();
    if (context_status != .ok) {
        frame.setStatusIfCompatible(context_status);
        return statusCode(context_status);
    }
    const owner: *loaded.LoadedComposition = @ptrFromInt(context.owner_address);
    if (owner.context.owner_cookie != context.owner_cookie or owner.context.owner_address != context.owner_address) {
        frame.setStatusIfCompatible(.incompatible_context);
        return statusCode(.incompatible_context);
    }
    const status = dispatch(owner, call_site_id, frame);
    frame.setStatusIfCompatible(status);
    return statusCode(status);
}

pub fn dispatch(owner: *loaded.LoadedComposition, call_site_id: u64, frame: *abi.Frame) abi.Status {
    if (owner.invocations.isClosing()) return .composition_closing;
    const frame_status = frame.validate(&owner.context);
    if (frame_status != .ok) return frame_status;
    const selected_variant = owner.module.variant(owner.selected_variant) orelse return .unknown_call_site;
    const call_site = selected_variant.callSite(.{ .value = call_site_id }) orelse return .unknown_call_site;
    const resources_status = validateResources(owner, call_site, frame);
    if (resources_status != .ok) return resources_status;
    const fragment_value = owner.loadedFragment(call_site.callee) orelse return .missing_fragment;
    const invoke_fn = fragment_value.vtable.invoke orelse return .missing_fragment;
    return invoke_fn(fragment_value.state, call_site, &owner.context, frame);
}

fn validateResources(owner: *const loaded.LoadedComposition, call_site: *const model.CallSite, frame: *const abi.Frame) abi.Status {
    const resolved = frame.resources(&owner.context);
    const resources = switch (resolved) {
        .status => |status| return status,
        .value => |values| values,
    };
    const expected_count = std.math.add(usize, call_site.inputs.len, call_site.outputs.len) catch return .invalid_resource;
    if (resources.len != expected_count or expected_count > abi.max_resources) return .invalid_resource;
    for (call_site.inputs, 0..) |boundary_id, index| {
        const boundary = owner.module.source_module.boundary(boundary_id) orelse return .invalid_resource;
        if (!resourceMatches(resources[index], boundary)) return .invalid_resource;
    }
    for (call_site.outputs, 0..) |boundary_id, index| {
        const boundary = owner.module.source_module.boundary(boundary_id) orelse return .invalid_resource;
        if (!resourceMatches(resources[call_site.inputs.len + index], boundary)) return .invalid_resource;
    }
    return .ok;
}

fn statusCode(status: abi.Status) i64 {
    return @intCast(@backingInt(status));
}

fn resourceMatches(resource: abi.Resource, boundary: *const source.Boundary) bool {
    const access = resource.accessValue() orelse return false;
    return resource.byte_size == boundary.byte_size and access == boundary.access;
}
