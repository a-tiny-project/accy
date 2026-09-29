const std = @import("std");
const native = @import("wayland");

const core = native.protocol.core;

pub const Output = struct {
    global_name: u32,
    id: u32,
    integer_scale: u32 = 1,
    entered: bool = false,

    pub fn setEntered(self: *Output, value: bool) bool {
        if (self.entered == value) return false;
        self.entered = value;
        return true;
    }

    pub fn dispatch(self: *Output, event: *native.runtime.RoutedView) !bool {
        if (event.metadata.opcode != core.wl_output.events.scale.opcode) return false;
        var decoder = try event.borrowedDecoder();
        const raw = try decoder.signed();
        try decoder.finish();
        return self.applyScale(raw);
    }

    fn applyScale(self: *Output, raw: i32) bool {
        const value: u32 = if (raw > 0) @intCast(raw) else 1;
        if (self.integer_scale == value) return false;
        self.integer_scale = value;
        return true;
    }
};

test "output scale normalizes compositor values" {
    var output = Output{
        .global_name = 7,
        .id = 8,
    };
    try std.testing.expect(output.applyScale(2));
    try std.testing.expectEqual(@as(u32, 2), output.integer_scale);
    try std.testing.expect(!output.applyScale(2));
    try std.testing.expect(output.applyScale(0));
    try std.testing.expectEqual(@as(u32, 1), output.integer_scale);
    try std.testing.expect(output.setEntered(true));
    try std.testing.expect(!output.setEntered(true));
}
