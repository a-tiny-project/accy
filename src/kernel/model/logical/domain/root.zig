pub const Axis = struct {
    name: []const u8,
    extent: u64,
};

pub const Domain2D = struct {
    x: Axis,
    y: Axis,
};

pub const Domain3D = struct {
    x: Axis,
    y: Axis,
    z: Axis,
};

pub fn axis(name: []const u8, extent: u64) Axis {
    return .{
        .name = name,
        .extent = extent,
    };
}
