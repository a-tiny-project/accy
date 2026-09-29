const std = @import("std");
const protocol = @import("root.zig");

const core = protocol.core;
const desktop = protocol.desktop;
const extensions = protocol.extensions;
const interfaces = protocol.interfaces;
const source = protocol.source;

test "generated Wayland 1.25 core schema matches its pinned truth" {
    try std.testing.expectEqualStrings("1.25.0", source.version);
    try std.testing.expectEqualStrings(
        "08fb558d96742b41eab330c386f7b0c17d82169e69edad612ea89c17d6b1d53e",
        source.xml_sha256,
    );
    try std.testing.expectEqual(@as(usize, 23), core.interfaces.len);

    var request_count: usize = 0;
    var event_count: usize = 0;
    var argument_count: usize = 0;
    var enumeration_count: usize = 0;
    var entry_count: usize = 0;
    for (core.interfaces) |interface| {
        request_count += interface.requests.len;
        event_count += interface.events.len;
        enumeration_count += interface.enumerations.len;
        for (interface.requests) |message| argument_count += message.arguments.len;
        for (interface.events) |message| argument_count += message.arguments.len;
        for (interface.enumerations) |enumeration| entry_count += enumeration.entries.len;
    }
    try std.testing.expectEqual(@as(usize, 71), request_count);
    try std.testing.expectEqual(@as(usize, 61), event_count);
    try std.testing.expectEqual(@as(usize, 213), argument_count);
    try std.testing.expectEqual(@as(usize, 26), enumeration_count);
    try std.testing.expectEqual(@as(usize, 222), entry_count);
}

test "generated Wayland Protocols 1.49 desktop schema matches its pinned truth" {
    try std.testing.expectEqualStrings("1.49", extensions.version);
    try std.testing.expectEqual(@as(usize, 10), extensions.files.len);
    try std.testing.expectEqual(@as(usize, 28), desktop.interfaces.len);
    try std.testing.expectEqual(@as(usize, 51), interfaces.len);

    var request_count: usize = 0;
    var event_count: usize = 0;
    var argument_count: usize = 0;
    var enumeration_count: usize = 0;
    var entry_count: usize = 0;
    for (desktop.interfaces) |interface| {
        request_count += interface.requests.len;
        event_count += interface.events.len;
        enumeration_count += interface.enumerations.len;
        for (interface.requests) |message| argument_count += message.arguments.len;
        for (interface.events) |message| argument_count += message.arguments.len;
        for (interface.enumerations) |enumeration| entry_count += enumeration.entries.len;
    }
    try std.testing.expectEqual(@as(usize, 89), request_count);
    try std.testing.expectEqual(@as(usize, 41), event_count);
    try std.testing.expectEqual(@as(usize, 170), argument_count);
    try std.testing.expectEqual(@as(usize, 31), enumeration_count);
    try std.testing.expectEqual(@as(usize, 156), entry_count);
}

test "desktop signatures match the independent wayland-scanner fixture" {
    try std.testing.expectEqualStrings("no", desktop.xdg_wm_base.requests.get_xdg_surface.signature);
    try std.testing.expectEqualStrings("iia", desktop.xdg_toplevel.events.configure.signature);
    try std.testing.expectEqualStrings("no", desktop.wp_viewporter.requests.get_viewport.signature);
    try std.testing.expectEqualStrings("no", desktop.wp_fractional_scale_manager_v1.requests.get_fractional_scale.signature);
    try std.testing.expectEqualStrings("no", desktop.zxdg_decoration_manager_v1.requests.get_toplevel_decoration.signature);
    try std.testing.expectEqualStrings("no", desktop.wp_cursor_shape_manager_v1.requests.get_pointer.signature);
    try std.testing.expectEqualStrings("on", desktop.wp_presentation.requests.feedback.signature);
    try std.testing.expectEqualStrings("uuuuuuu", desktop.wp_presentation_feedback.events.presented.signature);
    try std.testing.expectEqualStrings("no", desktop.ext_output_image_capture_source_manager_v1.requests.create_source.signature);
    try std.testing.expectEqualStrings("nou", desktop.ext_image_copy_capture_manager_v1.requests.create_session.signature);
    try std.testing.expectEqualStrings("uuu", desktop.ext_image_copy_capture_frame_v1.events.presentation_time.signature);
    try std.testing.expectEqualStrings("ii", desktop.ext_image_copy_capture_cursor_session_v1.events.position.signature);
    try std.testing.expectEqualStrings("4no", desktop.zwp_linux_dmabuf_v1.requests.get_surface_feedback.signature);
    try std.testing.expectEqualStrings("huuuuu", desktop.zwp_linux_buffer_params_v1.requests.add.signature);
    try std.testing.expectEqualStrings("2niiuu", desktop.zwp_linux_buffer_params_v1.requests.create_immed.signature);
    try std.testing.expectEqualStrings("hu", desktop.zwp_linux_dmabuf_feedback_v1.events.format_table.signature);
    try std.testing.expectEqualStrings("nh", desktop.wp_linux_drm_syncobj_manager_v1.requests.import_timeline.signature);
    try std.testing.expectEqualStrings("ouu", desktop.wp_linux_drm_syncobj_surface_v1.requests.set_acquire_point.signature);
}

test "bootstrap signatures match the independent wayland-scanner fixture" {
    try std.testing.expectEqualStrings("n", core.wl_display.requests.sync.signature);
    try std.testing.expectEqualStrings("n", core.wl_display.requests.get_registry.signature);
    try std.testing.expectEqualStrings("ous", core.wl_display.events.@"error".signature);
    try std.testing.expectEqualStrings("u", core.wl_display.events.delete_id.signature);
    try std.testing.expectEqualStrings("usun", core.wl_registry.requests.bind.signature);
    try std.testing.expectEqualStrings("usu", core.wl_registry.events.global.signature);
    try std.testing.expectEqualStrings("u", core.wl_registry.events.global_remove.signature);
    try std.testing.expectEqualStrings("u", core.wl_callback.events.done.signature);
}

test "protocol namespace is complete" {
    std.testing.refAllDecls(protocol);
    _ = @import("bootstrap/test.zig");
    _ = @import("generated/test.zig");
    _ = @import("value/test.zig");
}
