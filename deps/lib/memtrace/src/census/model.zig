pub const Entry = struct {
    label: []const u8,
    items: usize = 0,
    bytes: usize = 0,
};

pub const SummaryOptions = struct {
    top: usize = 24,
    min_bytes: usize = 0,
};

pub const Slot = struct {
    entry: Entry = .{ .label = &.{} },
    hash: u64 = 0,
    occupied: bool = false,
};
