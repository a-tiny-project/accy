pub const PartitionId = struct {
    value: u64,
};

pub const BoundaryId = struct {
    value: u64,
};

pub const FragmentId = struct {
    value: u64,
};

pub const CallSiteId = struct {
    value: u64,
};

pub const Pipeline = enum(u32) {
    choir = 1,
    accy = 2,
    foreign = 3,
};

pub const Access = enum(u32) {
    read = 1,
    write = 2,
    read_write = 3,
};

pub const Ownership = enum(u32) {
    borrowed = 1,
    transferred = 2,
    retained = 3,
    produced = 4,
};

pub fn boundaryIdsEqual(left: []const BoundaryId, right: []const BoundaryId) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_id, right_id| {
        if (left_id.value != right_id.value) return false;
    }
    return true;
}
