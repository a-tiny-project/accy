const std = @import("std");

/// Accelerator features a kernel requires or a device provides.
pub const Features = struct {
    atomic_i32: bool = false,
    atomic_u32: bool = false,
    atomic_index: bool = false,
    atomic_f32_add_device: bool = false,
    atomic_f32_add_shared: bool = false,
    unsupported_atomic: bool = false,
    async_copy: bool = false,
    tensor_cores: bool = false,
    cooperative_matrix: bool = false,
    dynamic_shared_memory: bool = false,
    indirect_launch: bool = false,

    pub fn containsAll(self: Features, required: Features) bool {
        if (required.atomic_i32 and !self.atomic_i32) return false;
        if (required.atomic_u32 and !self.atomic_u32) return false;
        if (required.atomic_index and !self.atomic_index) return false;
        if (required.atomic_f32_add_device and !self.atomic_f32_add_device) return false;
        if (required.atomic_f32_add_shared and !self.atomic_f32_add_shared) return false;
        if (required.unsupported_atomic) return false;
        if (required.async_copy and !self.async_copy) return false;
        if (required.tensor_cores and !self.tensor_cores) return false;
        if (required.cooperative_matrix and !self.cooperative_matrix) return false;
        if (required.dynamic_shared_memory and !self.dynamic_shared_memory) return false;
        if (required.indirect_launch and !self.indirect_launch) return false;
        return true;
    }
};

/// Subgroup operations and size bounds a kernel requires.
pub const SubgroupRequirements = struct {
    supported: bool = false,
    size_min: u32 = 0,
    size_max: u32 = 0,
    shuffle: bool = false,
    ballot: bool = false,
    vote: bool = false,
    arithmetic: bool = false,
    scan: bool = false,

    pub fn merge(self: SubgroupRequirements, other: SubgroupRequirements) SubgroupRequirements {
        return .{
            .supported = self.supported or other.supported,
            .size_min = @max(self.size_min, other.size_min),
            .size_max = if (self.size_max == 0)
                other.size_max
            else if (other.size_max == 0)
                self.size_max
            else
                @min(self.size_max, other.size_max),
            .shuffle = self.shuffle or other.shuffle,
            .ballot = self.ballot or other.ballot,
            .vote = self.vote or other.vote,
            .arithmetic = self.arithmetic or other.arithmetic,
            .scan = self.scan or other.scan,
        };
    }
};

test "features contain every required flag and reject unsupported atomics" {
    const device = Features{ .atomic_i32 = true, .dynamic_shared_memory = true };
    try std.testing.expect(device.containsAll(.{ .atomic_i32 = true }));
    try std.testing.expect(!device.containsAll(.{ .atomic_u32 = true }));
    try std.testing.expect(!device.containsAll(.{ .unsupported_atomic = true }));
}

test "subgroup requirements merge to the tighter size bounds" {
    const merged = (SubgroupRequirements{ .supported = true, .size_min = 16, .size_max = 64 })
        .merge(.{ .shuffle = true, .size_min = 32, .size_max = 32 });
    try std.testing.expect(merged.supported and merged.shuffle);
    try std.testing.expectEqual(@as(u32, 32), merged.size_min);
    try std.testing.expectEqual(@as(u32, 32), merged.size_max);
}
