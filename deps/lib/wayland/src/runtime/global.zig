const std = @import("std");
const wayland = @import("../root.zig");

pub const default_retained_global_count: usize = 256;
pub const default_interface_name_byte_count_per_global: usize = 128;

pub const Global = struct {
    registry_id: u32,
    name: u32,
    interface: []const u8,
    version: u32,
};

const Entry = struct {
    registry_id: u32,
    name: u32,
    interface_len: usize,
    version: u32,
};

pub const Slot = ?Entry;

pub const Limits = struct {
    retained_global_count: usize = default_retained_global_count,
    interface_name_byte_count_per_global: usize =
        default_interface_name_byte_count_per_global,
};

pub const CapacityError = error{CapacityOverflow};

pub const Capacity = struct {
    retained_global_count: usize,
    interface_name_byte_count_per_global: usize,
    retained_global_bytes: usize,
    interface_name_bytes: usize,
    total_requested_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        const retained_global_bytes = std.math.mul(
            usize,
            limits.retained_global_count,
            @sizeOf(Slot),
        ) catch return error.CapacityOverflow;
        const interface_name_bytes = std.math.mul(
            usize,
            limits.retained_global_count,
            limits.interface_name_byte_count_per_global,
        ) catch return error.CapacityOverflow;
        const total_requested_bytes = std.math.add(
            usize,
            retained_global_bytes,
            interface_name_bytes,
        ) catch return error.CapacityOverflow;
        return .{
            .retained_global_count = limits.retained_global_count,
            .interface_name_byte_count_per_global = limits.interface_name_byte_count_per_global,
            .retained_global_bytes = retained_global_bytes,
            .interface_name_bytes = interface_name_bytes,
            .total_requested_bytes = total_requested_bytes,
        };
    }
};

pub const StorageError = error{
    GlobalCapacityExceeded,
    GlobalInterfaceNameCapacityExceeded,
};

pub const ModelError = error{
    DuplicateGlobal,
    InvalidVersion,
    UnknownGlobal,
};

pub const Error = StorageError || ModelError;

pub const Status = struct {
    global_capacity_rejection_count: u64 = 0,
    global_interface_name_capacity_rejection_count: u64 = 0,
};

pub const Admission = struct {
    slot_index: usize,
    registry_id: u32,
    name: u32,
    interface_len: usize,
    version: u32,
};

pub const default_capacity = Capacity.derive(.{}) catch unreachable;

pub const Set = struct {
    session_allocator: std.mem.Allocator,
    slots: []Slot,
    interface_names: []u8,
    interface_name_byte_count_per_global: usize,
    count: usize = 0,
    capacity_rejection_count: u64 = 0,
    interface_name_capacity_rejection_count: u64 = 0,

    pub fn init(
        session_allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!Set {
        const slots = try session_allocator.alloc(Slot, capacity.retained_global_count);
        errdefer if (slots.len != 0) session_allocator.free(slots);
        @memset(slots, null);
        return .{
            .session_allocator = session_allocator,
            .slots = slots,
            .interface_names = try session_allocator.alloc(
                u8,
                capacity.interface_name_bytes,
            ),
            .interface_name_byte_count_per_global = capacity.interface_name_byte_count_per_global,
        };
    }

    pub fn deinit(self: *Set) void {
        self.assertValid();
        if (self.interface_names.len != 0) self.session_allocator.free(self.interface_names);
        if (self.slots.len != 0) self.session_allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn prepareAdd(
        self: *Set,
        registry_id: u32,
        name: u32,
        interface: []const u8,
        version: u32,
    ) Error!Admission {
        self.assertValid();
        if (version == 0) return error.InvalidVersion;
        var available_slot: ?usize = null;
        for (self.slots, 0..) |slot, slot_index| {
            const entry = slot orelse {
                if (available_slot == null) available_slot = slot_index;
                continue;
            };
            if (entry.registry_id == registry_id and entry.name == name) {
                return error.DuplicateGlobal;
            }
        }
        if (interface.len > self.interface_name_byte_count_per_global) {
            self.interface_name_capacity_rejection_count +|= 1;
            return error.GlobalInterfaceNameCapacityExceeded;
        }
        const slot_index = available_slot orelse {
            self.capacity_rejection_count +|= 1;
            return error.GlobalCapacityExceeded;
        };
        return .{
            .slot_index = slot_index,
            .registry_id = registry_id,
            .name = name,
            .interface_len = interface.len,
            .version = version,
        };
    }

    pub fn commitAdd(
        self: *Set,
        admission: Admission,
        interface: []const u8,
    ) Global {
        self.assertValid();
        std.debug.assert(admission.slot_index < self.slots.len);
        std.debug.assert(self.slots[admission.slot_index] == null);
        std.debug.assert(interface.len == admission.interface_len);
        std.debug.assert(interface.len <= self.interface_name_byte_count_per_global);
        std.debug.assert(admission.version != 0);
        const storage = self.interfaceStorage(admission.slot_index);
        @memcpy(storage[0..interface.len], interface);
        self.slots[admission.slot_index] = .{
            .registry_id = admission.registry_id,
            .name = admission.name,
            .interface_len = interface.len,
            .version = admission.version,
        };
        self.count += 1;
        self.assertValid();
        return self.globalAt(admission.slot_index);
    }

    pub fn add(
        self: *Set,
        registry_id: u32,
        name: u32,
        interface: []const u8,
        version: u32,
    ) Error!Global {
        return self.commitAdd(
            try self.prepareAdd(registry_id, name, interface, version),
            interface,
        );
    }

    pub fn get(self: *const Set, registry_id: u32, name: u32) ?Global {
        self.assertValid();
        for (self.slots, 0..) |slot, slot_index| {
            const entry = slot orelse continue;
            if (entry.registry_id == registry_id and entry.name == name) {
                return self.globalAt(slot_index);
            }
        }
        return null;
    }

    pub fn require(self: *const Set, registry_id: u32, name: u32) ModelError!Global {
        return self.get(registry_id, name) orelse error.UnknownGlobal;
    }

    pub fn remove(self: *Set, registry_id: u32, name: u32) ModelError!void {
        self.assertValid();
        for (self.slots) |*slot| {
            const entry = slot.* orelse continue;
            if (entry.registry_id != registry_id or entry.name != name) continue;
            slot.* = null;
            std.debug.assert(self.count != 0);
            self.count -= 1;
            self.assertValid();
            return;
        }
        return error.UnknownGlobal;
    }

    pub fn status(self: *const Set) Status {
        self.assertValid();
        const name_rejections = self.interface_name_capacity_rejection_count;
        return .{
            .global_capacity_rejection_count = self.capacity_rejection_count,
            .global_interface_name_capacity_rejection_count = name_rejections,
        };
    }

    fn globalAt(self: *const Set, slot_index: usize) Global {
        const entry = self.slots[slot_index].?;
        const storage = self.interfaceStorage(slot_index);
        return .{
            .registry_id = entry.registry_id,
            .name = entry.name,
            .interface = storage[0..entry.interface_len],
            .version = entry.version,
        };
    }

    fn interfaceStorage(self: *const Set, slot_index: usize) []u8 {
        const offset = slot_index * self.interface_name_byte_count_per_global;
        const end = offset + self.interface_name_byte_count_per_global;
        std.debug.assert(end <= self.interface_names.len);
        return self.interface_names[offset..end];
    }

    fn assertValid(self: *const Set) void {
        std.debug.assert(self.count <= self.slots.len);
        std.debug.assert(
            self.interface_names.len ==
                self.slots.len * self.interface_name_byte_count_per_global,
        );
        var count: usize = 0;
        for (self.slots, 0..) |slot, slot_index| {
            const entry = slot orelse continue;
            count += 1;
            std.debug.assert(entry.interface_len <= self.interface_name_byte_count_per_global);
            for (self.slots[slot_index + 1 ..]) |other_slot| {
                const other = other_slot orelse continue;
                if (entry.registry_id == other.registry_id) {
                    std.debug.assert(entry.name != other.name);
                }
            }
        }
        std.debug.assert(count == self.count);
    }
};

test "global capacity derives exact entry and stable name regions" {
    try std.testing.expectEqual(
        @as(usize, 256),
        default_capacity.retained_global_count,
    );
    try std.testing.expectEqual(
        @as(usize, 128),
        default_capacity.interface_name_byte_count_per_global,
    );
    const capacity = try Capacity.derive(.{
        .retained_global_count = 3,
        .interface_name_byte_count_per_global = 5,
    });
    try std.testing.expectEqual(@as(usize, 3), capacity.retained_global_count);
    try std.testing.expectEqual(@as(usize, 5), capacity.interface_name_byte_count_per_global);
    try std.testing.expectEqual(3 * @sizeOf(Slot), capacity.retained_global_bytes);
    try std.testing.expectEqual(@as(usize, 15), capacity.interface_name_bytes);
    try std.testing.expectEqual(
        capacity.retained_global_bytes + capacity.interface_name_bytes,
        capacity.total_requested_bytes,
    );
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .retained_global_count = std.math.maxInt(usize),
        .interface_name_byte_count_per_global = 2,
    }));
}

test "default global names cover every generated interface with headroom" {
    var maximum_name_len: usize = 0;
    for (wayland.protocol.interfaces) |interface| {
        maximum_name_len = @max(maximum_name_len, interface.name.len);
    }
    try std.testing.expect(
        maximum_name_len * 2 <= default_interface_name_byte_count_per_global,
    );
}

test "global storage acquires both regions before use" {
    const capacity = try Capacity.derive(.{
        .retained_global_count = 3,
        .interface_name_byte_count_per_global = 5,
    });
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        try std.testing.expectError(error.OutOfMemory, Set.init(failing.allocator(), capacity));
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 2,
    });
    var set = try Set.init(failing.allocator(), capacity);
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 2), failing.allocations);
}

test "globals are scoped to the registry that announced them" {
    var set = try Set.init(std.testing.allocator, default_capacity);
    defer set.deinit();

    const first = try set.add(2, 7, "wl_seat", 9);
    _ = try set.add(3, 7, "wl_output", 4);
    try std.testing.expectEqualStrings("wl_seat", first.interface);
    try std.testing.expectEqualStrings("wl_output", (try set.require(3, 7)).interface);
    try std.testing.expectError(error.DuplicateGlobal, set.add(2, 7, "wl_seat", 9));
    try set.remove(2, 7);
    try std.testing.expectError(error.UnknownGlobal, set.require(2, 7));
    try std.testing.expectError(error.UnknownGlobal, set.remove(2, 7));
}

test "unrelated removal and slot reuse preserve global name views" {
    const capacity = try Capacity.derive(.{
        .retained_global_count = 2,
        .interface_name_byte_count_per_global = 8,
    });
    var set = try Set.init(std.testing.allocator, capacity);
    defer set.deinit();
    const first = try set.add(2, 7, "wl_seat", 9);
    _ = try set.add(2, 8, "wl_shm", 1);
    const first_name_pointer = first.interface.ptr;

    try set.remove(2, 8);
    _ = try set.add(2, 9, "wl_touch", 1);
    try std.testing.expectEqual(first_name_pointer, (try set.require(2, 7)).interface.ptr);
    try std.testing.expectEqualStrings("wl_seat", first.interface);
}

test "global max plus one preserves storage and saturates status" {
    const capacity = try Capacity.derive(.{
        .retained_global_count = 1,
        .interface_name_byte_count_per_global = 3,
    });
    var set = try Set.init(std.testing.allocator, capacity);
    defer set.deinit();
    const slots = set.slots.ptr;
    const names = set.interface_names.ptr;

    _ = try set.add(2, 7, "abc", 1);
    try std.testing.expectError(error.GlobalCapacityExceeded, set.add(2, 8, "a", 1));
    try set.remove(2, 7);
    try std.testing.expectError(
        error.GlobalInterfaceNameCapacityExceeded,
        set.add(2, 8, "abcd", 1),
    );
    try std.testing.expectEqual(slots, set.slots.ptr);
    try std.testing.expectEqual(names, set.interface_names.ptr);
    try std.testing.expectEqual(@as(u64, 1), set.status().global_capacity_rejection_count);
    try std.testing.expectEqual(
        @as(u64, 1),
        set.status().global_interface_name_capacity_rejection_count,
    );

    set.capacity_rejection_count = std.math.maxInt(u64);
    set.interface_name_capacity_rejection_count = std.math.maxInt(u64);
    _ = try set.add(2, 7, "abc", 1);
    try std.testing.expectError(error.GlobalCapacityExceeded, set.add(2, 8, "a", 1));
    try set.remove(2, 7);
    try std.testing.expectError(
        error.GlobalInterfaceNameCapacityExceeded,
        set.add(2, 8, "abcd", 1),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        set.status().global_capacity_rejection_count,
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        set.status().global_interface_name_capacity_rejection_count,
    );
}

test "global admission does not mutate retained state" {
    const capacity = try Capacity.derive(.{
        .retained_global_count = 1,
        .interface_name_byte_count_per_global = 8,
    });
    var set = try Set.init(std.testing.allocator, capacity);
    defer set.deinit();

    const admission = try set.prepareAdd(2, 7, "wl_seat", 9);
    try std.testing.expect(set.get(2, 7) == null);
    _ = set.commitAdd(admission, "wl_seat");
    try std.testing.expectEqualStrings("wl_seat", (try set.require(2, 7)).interface);
}
