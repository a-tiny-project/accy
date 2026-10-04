const std = @import("std");
const composition = @import("root.zig");
const abi = composition.abi;
const loaded = composition.loaded;

const Allocator = std.mem.Allocator;

pub const ResourceSpec = struct {
    bytes: []u8,
    access: composition.Access,
};

pub const State = enum {
    prepared,
    running,
    completed,
    failed,
};

/// One call's owned ABI resources and state, bound to a live `LoadedComposition`.
/// Resource byte slices remain caller-owned and must outlive invocation completion.
pub const Invocation = struct {
    allocator: Allocator,
    owner: *loaded.LoadedComposition,
    resources: []abi.Resource,
    frame: abi.Frame,
    state: State = .prepared,

    pub fn init(
        allocator: Allocator,
        owner: *loaded.LoadedComposition,
        specs: []const ResourceSpec,
    ) (Allocator.Error || error{ CompositionClosing, InvalidResource, TooManyResources })!*Invocation {
        if (specs.len > abi.max_resources) return error.TooManyResources;
        for (specs) |spec| {
            if (spec.bytes.len == 0) return error.InvalidResource;
        }
        const invocation_id = owner.reserveInvocation() orelse return error.CompositionClosing;
        errdefer owner.releaseInvocation(invocation_id);

        const resources = try allocator.alloc(abi.Resource, specs.len);
        errdefer allocator.free(resources);
        for (specs, 0..) |spec, index| {
            resources[index] = abi.Resource.init(owner.contextPointer().owner_cookie, invocation_id, spec.bytes, spec.access);
        }

        const invocation = try allocator.create(Invocation);
        invocation.* = .{
            .allocator = allocator,
            .owner = owner,
            .resources = resources,
            .frame = abi.Frame.init(owner.contextPointer().owner_cookie, invocation_id, resources),
        };
        return invocation;
    }

    pub fn deinit(self: *Invocation) void {
        if (self.state == .running) @panic("invocation destroyed while running");
        const allocator = self.allocator;
        const owner = self.owner;
        const invocation_id = self.frame.invocation_id;
        allocator.free(self.resources);
        self.* = undefined;
        allocator.destroy(self);
        owner.releaseInvocation(invocation_id);
    }

    pub fn id(self: *const Invocation) u64 {
        return self.frame.invocation_id;
    }

    pub fn framePointer(self: *Invocation) *abi.Frame {
        return &self.frame;
    }

    pub fn status(self: *const Invocation) abi.Status {
        return self.frame.statusValue();
    }
};

/// A context-bound wrapper around one process-local raw fragment address.
/// `address` is public for callers that supply the composition's ABI context
/// and frame directly; `invoke` additionally requires a prepared invocation
/// owned by the same loaded composition.
pub const Entry = struct {
    owner: *loaded.LoadedComposition,
    address: usize,

    pub fn init(
        owner: *loaded.LoadedComposition,
        fragment_id: composition.FragmentId,
        export_name: []const u8,
    ) loaded.EntryError!Entry {
        return .{
            .owner = owner,
            .address = try owner.entryAddress(fragment_id, export_name),
        };
    }

    pub fn invoke(self: Entry, invocation: *Invocation) abi.Status {
        if (invocation.owner != self.owner or invocation.state != .prepared) {
            invocation.frame.setStatus(.invalid_resource);
            invocation.state = .failed;
            return .invalid_resource;
        }
        invocation.state = .running;
        const function: *const fn (i64, i64) callconv(.c) i64 = @ptrFromInt(self.address);
        const raw_status = function(
            @bitCast(@as(u64, @intFromPtr(self.owner.contextPointer()))),
            @bitCast(@as(u64, @intFromPtr(invocation.framePointer()))),
        );
        const status = abi.decodeStatus(raw_status);
        invocation.frame.setStatus(status);
        invocation.state = if (status == .ok) .completed else .failed;
        return status;
    }
};
