pub const Align = enum { left, right };

pub const Column = struct {
    header: []const u8,
    max_width: usize = 40,
    alignment: Align = .left,
};
