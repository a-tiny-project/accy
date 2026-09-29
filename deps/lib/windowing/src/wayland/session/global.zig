const std = @import("std");

pub const Kind = enum {
    compositor,
    shm,
    seat,
    output,
    data_device_manager,
    xdg_wm_base,
    viewporter,
    fractional_scale_manager,
    decoration_manager,
    cursor_shape_manager,
    presentation,
    linux_dmabuf,
    syncobj_manager,
    unknown,
};

pub fn classify(name: []const u8) Kind {
    const names = std.StaticStringMap(Kind).initComptime(.{
        .{ "wl_compositor", .compositor },
        .{ "wl_shm", .shm },
        .{ "wl_seat", .seat },
        .{ "wl_output", .output },
        .{ "wl_data_device_manager", .data_device_manager },
        .{ "xdg_wm_base", .xdg_wm_base },
        .{ "wp_viewporter", .viewporter },
        .{ "wp_fractional_scale_manager_v1", .fractional_scale_manager },
        .{ "zxdg_decoration_manager_v1", .decoration_manager },
        .{ "wp_cursor_shape_manager_v1", .cursor_shape_manager },
        .{ "wp_presentation", .presentation },
        .{ "zwp_linux_dmabuf_v1", .linux_dmabuf },
        .{ "wp_linux_drm_syncobj_manager_v1", .syncobj_manager },
    });
    return names.get(name) orelse .unknown;
}
