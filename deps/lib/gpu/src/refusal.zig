//! The check every backend without a render path passes: it names no render entry, and a pass
//! handed to it fails with a typed error instead of reporting a draw that never happened.

const std = @import("std");
const backend = @import("root.zig");

pub fn expectRenderRefused(handle: backend.BackendHandle) !void {
    const vtable = handle.vtable;
    try std.testing.expect(vtable.render == null);
    try std.testing.expect(vtable.record_render_bundle == null);
    try std.testing.expect(vtable.submit_render_bundle == null);
    try std.testing.expect(vtable.create_render_bindings == null);
    try std.testing.expect(vtable.read_texture == null);
    const texture = backend.TextureHandle{
        .id = 1,
        .backend = handle.kind.?,
        .extent = .{ .width = 4, .height = 4 },
        .format = .rgba8_unorm,
        .usage = .{ .color_attachment = true, .copy_src = true },
    };
    const pass = backend.RenderPass{
        .color = .{ .view = .{ .texture = texture, .format = .rgba8_unorm }, .load = .{ .clear = .{} } },
        .viewport = .{ .width = 4, .height = 4 },
        .scissor = .{ .width = 4, .height = 4 },
        .draws = &.{},
    };
    try expectTypedError(handle.render(.{ .pass = pass }));
    try expectTypedError(handle.recordRenderBundle(pass));
    var texels: [64]u8 = undefined;
    try expectTypedError(handle.readTexture(.{ .texture = texture, .bytes = &texels }));
}

fn expectTypedError(result: anytype) !void {
    if (result) |_| return error.TestUnexpectedResult else |err| switch (err) {
        error.CapabilityMismatch, error.UnsupportedOperation, error.InvalidTexture => {},
        else => return err,
    }
}
