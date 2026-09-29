const protocol = @import("../root.zig");

const schema = protocol.schema;

pub const xdg_wm_base = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const create_positioner: schema.Message = .{
            .name = "create_positioner",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "xdg_positioner", .enumeration = null, .nullable = false },
            },
        };
        pub const get_xdg_surface: schema.Message = .{
            .name = "get_xdg_surface",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "no",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "xdg_surface", .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
            },
        };
        pub const pong: schema.Message = .{
            .name = "pong",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, create_positioner, get_xdg_surface, pong };
    };
    pub const events = struct {
        pub const ping: schema.Message = .{
            .name = "ping",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ping};
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "role", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "defunct_surfaces", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "not_the_topmost_popup", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_popup_parent", .value = 3, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_surface_state", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_positioner", .value = 5, .since = 1, .deprecated_since = null },
                .{ .name = "unresponsive", .value = 6, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "xdg_wm_base",
        .version = 7,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const xdg_positioner = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const set_size: schema.Message = .{
            .name = "set_size",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ii",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const set_anchor_rect: schema.Message = .{
            .name = "set_anchor_rect",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "iiii",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const set_anchor: schema.Message = .{
            .name = "set_anchor",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "anchor", .kind = .uint, .interface = null, .enumeration = "anchor", .nullable = false },
            },
        };
        pub const set_gravity: schema.Message = .{
            .name = "set_gravity",
            .opcode = 4,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "gravity", .kind = .uint, .interface = null, .enumeration = "gravity", .nullable = false },
            },
        };
        pub const set_constraint_adjustment: schema.Message = .{
            .name = "set_constraint_adjustment",
            .opcode = 5,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "constraint_adjustment", .kind = .uint, .interface = null, .enumeration = "constraint_adjustment", .nullable = false },
            },
        };
        pub const set_offset: schema.Message = .{
            .name = "set_offset",
            .opcode = 6,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ii",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const set_reactive: schema.Message = .{
            .name = "set_reactive",
            .opcode = 7,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const set_parent_size: schema.Message = .{
            .name = "set_parent_size",
            .opcode = 8,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3ii",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "parent_width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "parent_height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const set_parent_configure: schema.Message = .{
            .name = "set_parent_configure",
            .opcode = 9,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, set_size, set_anchor_rect, set_anchor, set_gravity, set_constraint_adjustment, set_offset, set_reactive, set_parent_size, set_parent_configure };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "invalid_input", .value = 0, .since = 1, .deprecated_since = null },
            },
        };
        pub const anchor: schema.Enumeration = .{
            .name = "anchor",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "none", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "top", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "bottom", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "left", .value = 3, .since = 1, .deprecated_since = null },
                .{ .name = "right", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "top_left", .value = 5, .since = 1, .deprecated_since = null },
                .{ .name = "bottom_left", .value = 6, .since = 1, .deprecated_since = null },
                .{ .name = "top_right", .value = 7, .since = 1, .deprecated_since = null },
                .{ .name = "bottom_right", .value = 8, .since = 1, .deprecated_since = null },
            },
        };
        pub const gravity: schema.Enumeration = .{
            .name = "gravity",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "none", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "top", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "bottom", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "left", .value = 3, .since = 1, .deprecated_since = null },
                .{ .name = "right", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "top_left", .value = 5, .since = 1, .deprecated_since = null },
                .{ .name = "bottom_left", .value = 6, .since = 1, .deprecated_since = null },
                .{ .name = "top_right", .value = 7, .since = 1, .deprecated_since = null },
                .{ .name = "bottom_right", .value = 8, .since = 1, .deprecated_since = null },
            },
        };
        pub const constraint_adjustment: schema.Enumeration = .{
            .name = "constraint_adjustment",
            .since = 1,
            .bitfield = true,
            .entries = &.{
                .{ .name = "none", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "slide_x", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "slide_y", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "flip_x", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "flip_y", .value = 8, .since = 1, .deprecated_since = null },
                .{ .name = "resize_x", .value = 16, .since = 1, .deprecated_since = null },
                .{ .name = "resize_y", .value = 32, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{ @"error", anchor, gravity, constraint_adjustment };
    };
    pub const metadata: schema.Interface = .{
        .name = "xdg_positioner",
        .version = 7,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const xdg_surface = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const get_toplevel: schema.Message = .{
            .name = "get_toplevel",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "xdg_toplevel", .enumeration = null, .nullable = false },
            },
        };
        pub const get_popup: schema.Message = .{
            .name = "get_popup",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n?oo",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "xdg_popup", .enumeration = null, .nullable = false },
                .{ .name = "parent", .kind = .object, .interface = "xdg_surface", .enumeration = null, .nullable = true },
                .{ .name = "positioner", .kind = .object, .interface = "xdg_positioner", .enumeration = null, .nullable = false },
            },
        };
        pub const set_window_geometry: schema.Message = .{
            .name = "set_window_geometry",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "iiii",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const ack_configure: schema.Message = .{
            .name = "ack_configure",
            .opcode = 4,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, get_toplevel, get_popup, set_window_geometry, ack_configure };
    };
    pub const events = struct {
        pub const configure: schema.Message = .{
            .name = "configure",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{configure};
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "not_constructed", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "already_constructed", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "unconfigured_buffer", .value = 3, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_serial", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_size", .value = 5, .since = 1, .deprecated_since = null },
                .{ .name = "defunct_role_object", .value = 6, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "xdg_surface",
        .version = 7,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const xdg_toplevel = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const set_parent: schema.Message = .{
            .name = "set_parent",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "?o",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "parent", .kind = .object, .interface = "xdg_toplevel", .enumeration = null, .nullable = true },
            },
        };
        pub const set_title: schema.Message = .{
            .name = "set_title",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "s",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "title", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const set_app_id: schema.Message = .{
            .name = "set_app_id",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "s",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "app_id", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const show_window_menu: schema.Message = .{
            .name = "show_window_menu",
            .opcode = 4,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ouii",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "seat", .kind = .object, .interface = "wl_seat", .enumeration = null, .nullable = false },
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const move: schema.Message = .{
            .name = "move",
            .opcode = 5,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ou",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "seat", .kind = .object, .interface = "wl_seat", .enumeration = null, .nullable = false },
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const resize: schema.Message = .{
            .name = "resize",
            .opcode = 6,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ouu",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "seat", .kind = .object, .interface = "wl_seat", .enumeration = null, .nullable = false },
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "edges", .kind = .uint, .interface = null, .enumeration = "resize_edge", .nullable = false },
            },
        };
        pub const set_max_size: schema.Message = .{
            .name = "set_max_size",
            .opcode = 7,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ii",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const set_min_size: schema.Message = .{
            .name = "set_min_size",
            .opcode = 8,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ii",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const set_maximized: schema.Message = .{
            .name = "set_maximized",
            .opcode = 9,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const unset_maximized: schema.Message = .{
            .name = "unset_maximized",
            .opcode = 10,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const set_fullscreen: schema.Message = .{
            .name = "set_fullscreen",
            .opcode = 11,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "?o",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "output", .kind = .object, .interface = "wl_output", .enumeration = null, .nullable = true },
            },
        };
        pub const unset_fullscreen: schema.Message = .{
            .name = "unset_fullscreen",
            .opcode = 12,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const set_minimized: schema.Message = .{
            .name = "set_minimized",
            .opcode = 13,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ destroy, set_parent, set_title, set_app_id, show_window_menu, move, resize, set_max_size, set_min_size, set_maximized, unset_maximized, set_fullscreen, unset_fullscreen, set_minimized };
    };
    pub const events = struct {
        pub const configure: schema.Message = .{
            .name = "configure",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "iia",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "states", .kind = .array, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const close: schema.Message = .{
            .name = "close",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const configure_bounds: schema.Message = .{
            .name = "configure_bounds",
            .opcode = 2,
            .since = 4,
            .deprecated_since = null,
            .destructor = false,
            .signature = "4ii",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const wm_capabilities: schema.Message = .{
            .name = "wm_capabilities",
            .opcode = 3,
            .since = 5,
            .deprecated_since = null,
            .destructor = false,
            .signature = "5a",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "capabilities", .kind = .array, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ configure, close, configure_bounds, wm_capabilities };
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "invalid_resize_edge", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_parent", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_size", .value = 2, .since = 1, .deprecated_since = null },
            },
        };
        pub const resize_edge: schema.Enumeration = .{
            .name = "resize_edge",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "none", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "top", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "bottom", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "left", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "top_left", .value = 5, .since = 1, .deprecated_since = null },
                .{ .name = "bottom_left", .value = 6, .since = 1, .deprecated_since = null },
                .{ .name = "right", .value = 8, .since = 1, .deprecated_since = null },
                .{ .name = "top_right", .value = 9, .since = 1, .deprecated_since = null },
                .{ .name = "bottom_right", .value = 10, .since = 1, .deprecated_since = null },
            },
        };
        pub const state: schema.Enumeration = .{
            .name = "state",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "maximized", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "fullscreen", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "resizing", .value = 3, .since = 1, .deprecated_since = null },
                .{ .name = "activated", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "tiled_left", .value = 5, .since = 2, .deprecated_since = null },
                .{ .name = "tiled_right", .value = 6, .since = 2, .deprecated_since = null },
                .{ .name = "tiled_top", .value = 7, .since = 2, .deprecated_since = null },
                .{ .name = "tiled_bottom", .value = 8, .since = 2, .deprecated_since = null },
                .{ .name = "suspended", .value = 9, .since = 6, .deprecated_since = null },
                .{ .name = "constrained_left", .value = 10, .since = 7, .deprecated_since = null },
                .{ .name = "constrained_right", .value = 11, .since = 7, .deprecated_since = null },
                .{ .name = "constrained_top", .value = 12, .since = 7, .deprecated_since = null },
                .{ .name = "constrained_bottom", .value = 13, .since = 7, .deprecated_since = null },
            },
        };
        pub const wm_capabilities: schema.Enumeration = .{
            .name = "wm_capabilities",
            .since = 5,
            .bitfield = false,
            .entries = &.{
                .{ .name = "window_menu", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "maximize", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "fullscreen", .value = 3, .since = 1, .deprecated_since = null },
                .{ .name = "minimize", .value = 4, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{ @"error", resize_edge, state, wm_capabilities };
    };
    pub const metadata: schema.Interface = .{
        .name = "xdg_toplevel",
        .version = 7,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const xdg_popup = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const grab: schema.Message = .{
            .name = "grab",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ou",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "seat", .kind = .object, .interface = "wl_seat", .enumeration = null, .nullable = false },
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const reposition: schema.Message = .{
            .name = "reposition",
            .opcode = 2,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3ou",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "positioner", .kind = .object, .interface = "xdg_positioner", .enumeration = null, .nullable = false },
                .{ .name = "token", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, grab, reposition };
    };
    pub const events = struct {
        pub const configure: schema.Message = .{
            .name = "configure",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "iiii",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const popup_done: schema.Message = .{
            .name = "popup_done",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const repositioned: schema.Message = .{
            .name = "repositioned",
            .opcode = 2,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "token", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ configure, popup_done, repositioned };
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "invalid_grab", .value = 0, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "xdg_popup",
        .version = 7,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wp_viewporter = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const get_viewport: schema.Message = .{
            .name = "get_viewport",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "no",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wp_viewport", .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, get_viewport };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "viewport_exists", .value = 0, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wp_viewporter",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wp_viewport = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const set_source: schema.Message = .{
            .name = "set_source",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ffff",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "x", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "width", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const set_destination: schema.Message = .{
            .name = "set_destination",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ii",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, set_source, set_destination };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "bad_value", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "bad_size", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "out_of_buffer", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "no_surface", .value = 3, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wp_viewport",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wp_fractional_scale_manager_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const get_fractional_scale: schema.Message = .{
            .name = "get_fractional_scale",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "no",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wp_fractional_scale_v1", .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, get_fractional_scale };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "fractional_scale_exists", .value = 0, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wp_fractional_scale_manager_v1",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wp_fractional_scale_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{destroy};
    };
    pub const events = struct {
        pub const preferred_scale: schema.Message = .{
            .name = "preferred_scale",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "scale", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{preferred_scale};
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "wp_fractional_scale_v1",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const zxdg_decoration_manager_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const get_toplevel_decoration: schema.Message = .{
            .name = "get_toplevel_decoration",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "no",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "zxdg_toplevel_decoration_v1", .enumeration = null, .nullable = false },
                .{ .name = "toplevel", .kind = .object, .interface = "xdg_toplevel", .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, get_toplevel_decoration };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "zxdg_decoration_manager_v1",
        .version = 2,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const zxdg_toplevel_decoration_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const set_mode: schema.Message = .{
            .name = "set_mode",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "mode", .kind = .uint, .interface = null, .enumeration = "mode", .nullable = false },
            },
        };
        pub const unset_mode: schema.Message = .{
            .name = "unset_mode",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ destroy, set_mode, unset_mode };
    };
    pub const events = struct {
        pub const configure: schema.Message = .{
            .name = "configure",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "mode", .kind = .uint, .interface = null, .enumeration = "mode", .nullable = false },
            },
        };
        pub const all = [_]schema.Message{configure};
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "unconfigured_buffer", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "already_constructed", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "orphaned", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_mode", .value = 3, .since = 1, .deprecated_since = null },
            },
        };
        pub const mode: schema.Enumeration = .{
            .name = "mode",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "client_side", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "server_side", .value = 2, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{ @"error", mode };
    };
    pub const metadata: schema.Interface = .{
        .name = "zxdg_toplevel_decoration_v1",
        .version = 2,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wp_cursor_shape_manager_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const get_pointer: schema.Message = .{
            .name = "get_pointer",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "no",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "cursor_shape_device", .kind = .new_id, .interface = "wp_cursor_shape_device_v1", .enumeration = null, .nullable = false },
                .{ .name = "pointer", .kind = .object, .interface = "wl_pointer", .enumeration = null, .nullable = false },
            },
        };
        pub const get_tablet_tool_v2: schema.Message = .{
            .name = "get_tablet_tool_v2",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "no",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "cursor_shape_device", .kind = .new_id, .interface = "wp_cursor_shape_device_v1", .enumeration = null, .nullable = false },
                .{ .name = "tablet_tool", .kind = .object, .interface = "zwp_tablet_tool_v2", .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, get_pointer, get_tablet_tool_v2 };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "wp_cursor_shape_manager_v1",
        .version = 2,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wp_cursor_shape_device_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const set_shape: schema.Message = .{
            .name = "set_shape",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uu",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "shape", .kind = .uint, .interface = null, .enumeration = "shape", .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, set_shape };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const shape: schema.Enumeration = .{
            .name = "shape",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "default", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "context_menu", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "help", .value = 3, .since = 1, .deprecated_since = null },
                .{ .name = "pointer", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "progress", .value = 5, .since = 1, .deprecated_since = null },
                .{ .name = "wait", .value = 6, .since = 1, .deprecated_since = null },
                .{ .name = "cell", .value = 7, .since = 1, .deprecated_since = null },
                .{ .name = "crosshair", .value = 8, .since = 1, .deprecated_since = null },
                .{ .name = "text", .value = 9, .since = 1, .deprecated_since = null },
                .{ .name = "vertical_text", .value = 10, .since = 1, .deprecated_since = null },
                .{ .name = "alias", .value = 11, .since = 1, .deprecated_since = null },
                .{ .name = "copy", .value = 12, .since = 1, .deprecated_since = null },
                .{ .name = "move", .value = 13, .since = 1, .deprecated_since = null },
                .{ .name = "no_drop", .value = 14, .since = 1, .deprecated_since = null },
                .{ .name = "not_allowed", .value = 15, .since = 1, .deprecated_since = null },
                .{ .name = "grab", .value = 16, .since = 1, .deprecated_since = null },
                .{ .name = "grabbing", .value = 17, .since = 1, .deprecated_since = null },
                .{ .name = "e_resize", .value = 18, .since = 1, .deprecated_since = null },
                .{ .name = "n_resize", .value = 19, .since = 1, .deprecated_since = null },
                .{ .name = "ne_resize", .value = 20, .since = 1, .deprecated_since = null },
                .{ .name = "nw_resize", .value = 21, .since = 1, .deprecated_since = null },
                .{ .name = "s_resize", .value = 22, .since = 1, .deprecated_since = null },
                .{ .name = "se_resize", .value = 23, .since = 1, .deprecated_since = null },
                .{ .name = "sw_resize", .value = 24, .since = 1, .deprecated_since = null },
                .{ .name = "w_resize", .value = 25, .since = 1, .deprecated_since = null },
                .{ .name = "ew_resize", .value = 26, .since = 1, .deprecated_since = null },
                .{ .name = "ns_resize", .value = 27, .since = 1, .deprecated_since = null },
                .{ .name = "nesw_resize", .value = 28, .since = 1, .deprecated_since = null },
                .{ .name = "nwse_resize", .value = 29, .since = 1, .deprecated_since = null },
                .{ .name = "col_resize", .value = 30, .since = 1, .deprecated_since = null },
                .{ .name = "row_resize", .value = 31, .since = 1, .deprecated_since = null },
                .{ .name = "all_scroll", .value = 32, .since = 1, .deprecated_since = null },
                .{ .name = "zoom_in", .value = 33, .since = 1, .deprecated_since = null },
                .{ .name = "zoom_out", .value = 34, .since = 1, .deprecated_since = null },
                .{ .name = "dnd_ask", .value = 35, .since = 2, .deprecated_since = null },
                .{ .name = "all_resize", .value = 36, .since = 2, .deprecated_since = null },
            },
        };
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "invalid_shape", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{ shape, @"error" };
    };
    pub const metadata: schema.Interface = .{
        .name = "wp_cursor_shape_device_v1",
        .version = 2,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wp_presentation = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const feedback: schema.Message = .{
            .name = "feedback",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "on",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
                .{ .name = "callback", .kind = .new_id, .interface = "wp_presentation_feedback", .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, feedback };
    };
    pub const events = struct {
        pub const clock_id: schema.Message = .{
            .name = "clock_id",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "clk_id", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{clock_id};
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "invalid_timestamp", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_flag", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wp_presentation",
        .version = 2,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wp_presentation_feedback = struct {
    pub const requests = struct {
        pub const all = [_]schema.Message{};
    };
    pub const events = struct {
        pub const sync_output: schema.Message = .{
            .name = "sync_output",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "o",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "output", .kind = .object, .interface = "wl_output", .enumeration = null, .nullable = false },
            },
        };
        pub const presented: schema.Message = .{
            .name = "presented",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "uuuuuuu",
            .descriptor_count = 0,
            .minimum_payload_size = 28,
            .arguments = &.{
                .{ .name = "tv_sec_hi", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "tv_sec_lo", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "tv_nsec", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "refresh", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "seq_hi", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "seq_lo", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "flags", .kind = .uint, .interface = null, .enumeration = "kind", .nullable = false },
            },
        };
        pub const discarded: schema.Message = .{
            .name = "discarded",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ sync_output, presented, discarded };
    };
    pub const enumerations = struct {
        pub const kind: schema.Enumeration = .{
            .name = "kind",
            .since = 1,
            .bitfield = true,
            .entries = &.{
                .{ .name = "vsync", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "hw_clock", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "hw_completion", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "zero_copy", .value = 8, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{kind};
    };
    pub const metadata: schema.Interface = .{
        .name = "wp_presentation_feedback",
        .version = 2,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const ext_image_capture_source_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{destroy};
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "ext_image_capture_source_v1",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const ext_output_image_capture_source_manager_v1 = struct {
    pub const requests = struct {
        pub const create_source: schema.Message = .{
            .name = "create_source",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "no",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "source", .kind = .new_id, .interface = "ext_image_capture_source_v1", .enumeration = null, .nullable = false },
                .{ .name = "output", .kind = .object, .interface = "wl_output", .enumeration = null, .nullable = false },
            },
        };
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ create_source, destroy };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "ext_output_image_capture_source_manager_v1",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const ext_foreign_toplevel_image_capture_source_manager_v1 = struct {
    pub const requests = struct {
        pub const create_source: schema.Message = .{
            .name = "create_source",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "no",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "source", .kind = .new_id, .interface = "ext_image_capture_source_v1", .enumeration = null, .nullable = false },
                .{ .name = "toplevel_handle", .kind = .object, .interface = "ext_foreign_toplevel_handle_v1", .enumeration = null, .nullable = false },
            },
        };
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ create_source, destroy };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "ext_foreign_toplevel_image_capture_source_manager_v1",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const ext_image_copy_capture_manager_v1 = struct {
    pub const requests = struct {
        pub const create_session: schema.Message = .{
            .name = "create_session",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "nou",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "session", .kind = .new_id, .interface = "ext_image_copy_capture_session_v1", .enumeration = null, .nullable = false },
                .{ .name = "source", .kind = .object, .interface = "ext_image_capture_source_v1", .enumeration = null, .nullable = false },
                .{ .name = "options", .kind = .uint, .interface = null, .enumeration = "options", .nullable = false },
            },
        };
        pub const create_pointer_cursor_session: schema.Message = .{
            .name = "create_pointer_cursor_session",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "noo",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "session", .kind = .new_id, .interface = "ext_image_copy_capture_cursor_session_v1", .enumeration = null, .nullable = false },
                .{ .name = "source", .kind = .object, .interface = "ext_image_capture_source_v1", .enumeration = null, .nullable = false },
                .{ .name = "pointer", .kind = .object, .interface = "wl_pointer", .enumeration = null, .nullable = false },
            },
        };
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ create_session, create_pointer_cursor_session, destroy };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "invalid_option", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const options: schema.Enumeration = .{
            .name = "options",
            .since = 1,
            .bitfield = true,
            .entries = &.{
                .{ .name = "paint_cursors", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{ @"error", options };
    };
    pub const metadata: schema.Interface = .{
        .name = "ext_image_copy_capture_manager_v1",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const ext_image_copy_capture_session_v1 = struct {
    pub const requests = struct {
        pub const create_frame: schema.Message = .{
            .name = "create_frame",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "frame", .kind = .new_id, .interface = "ext_image_copy_capture_frame_v1", .enumeration = null, .nullable = false },
            },
        };
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ create_frame, destroy };
    };
    pub const events = struct {
        pub const buffer_size: schema.Message = .{
            .name = "buffer_size",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uu",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "width", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const shm_format: schema.Message = .{
            .name = "shm_format",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "format", .kind = .uint, .interface = null, .enumeration = "wl_shm.format", .nullable = false },
            },
        };
        pub const dmabuf_device: schema.Message = .{
            .name = "dmabuf_device",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "a",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "device", .kind = .array, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const dmabuf_format: schema.Message = .{
            .name = "dmabuf_format",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ua",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "format", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "modifiers", .kind = .array, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const done: schema.Message = .{
            .name = "done",
            .opcode = 4,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const stopped: schema.Message = .{
            .name = "stopped",
            .opcode = 5,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ buffer_size, shm_format, dmabuf_device, dmabuf_format, done, stopped };
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "duplicate_frame", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "ext_image_copy_capture_session_v1",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const ext_image_copy_capture_frame_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const attach_buffer: schema.Message = .{
            .name = "attach_buffer",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "o",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "buffer", .kind = .object, .interface = "wl_buffer", .enumeration = null, .nullable = false },
            },
        };
        pub const damage_buffer: schema.Message = .{
            .name = "damage_buffer",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "iiii",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const capture: schema.Message = .{
            .name = "capture",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ destroy, attach_buffer, damage_buffer, capture };
    };
    pub const events = struct {
        pub const transform: schema.Message = .{
            .name = "transform",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "transform", .kind = .uint, .interface = null, .enumeration = "wl_output.transform", .nullable = false },
            },
        };
        pub const damage: schema.Message = .{
            .name = "damage",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "iiii",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const presentation_time: schema.Message = .{
            .name = "presentation_time",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uuu",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "tv_sec_hi", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "tv_sec_lo", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "tv_nsec", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const ready: schema.Message = .{
            .name = "ready",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const failed: schema.Message = .{
            .name = "failed",
            .opcode = 4,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "reason", .kind = .uint, .interface = null, .enumeration = "failure_reason", .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ transform, damage, presentation_time, ready, failed };
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "no_buffer", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_buffer_damage", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "already_captured", .value = 3, .since = 1, .deprecated_since = null },
            },
        };
        pub const failure_reason: schema.Enumeration = .{
            .name = "failure_reason",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "unknown", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "buffer_constraints", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "stopped", .value = 2, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{ @"error", failure_reason };
    };
    pub const metadata: schema.Interface = .{
        .name = "ext_image_copy_capture_frame_v1",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const ext_image_copy_capture_cursor_session_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const get_capture_session: schema.Message = .{
            .name = "get_capture_session",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "session", .kind = .new_id, .interface = "ext_image_copy_capture_session_v1", .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, get_capture_session };
    };
    pub const events = struct {
        pub const enter: schema.Message = .{
            .name = "enter",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const leave: schema.Message = .{
            .name = "leave",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const position: schema.Message = .{
            .name = "position",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ii",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const hotspot: schema.Message = .{
            .name = "hotspot",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ii",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ enter, leave, position, hotspot };
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "duplicate_session", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "ext_image_copy_capture_cursor_session_v1",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const zwp_linux_dmabuf_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const create_params: schema.Message = .{
            .name = "create_params",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "params_id", .kind = .new_id, .interface = "zwp_linux_buffer_params_v1", .enumeration = null, .nullable = false },
            },
        };
        pub const get_default_feedback: schema.Message = .{
            .name = "get_default_feedback",
            .opcode = 2,
            .since = 4,
            .deprecated_since = null,
            .destructor = false,
            .signature = "4n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "zwp_linux_dmabuf_feedback_v1", .enumeration = null, .nullable = false },
            },
        };
        pub const get_surface_feedback: schema.Message = .{
            .name = "get_surface_feedback",
            .opcode = 3,
            .since = 4,
            .deprecated_since = null,
            .destructor = false,
            .signature = "4no",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "zwp_linux_dmabuf_feedback_v1", .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, create_params, get_default_feedback, get_surface_feedback };
    };
    pub const events = struct {
        pub const format: schema.Message = .{
            .name = "format",
            .opcode = 0,
            .since = 1,
            .deprecated_since = 4,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "format", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const modifier: schema.Message = .{
            .name = "modifier",
            .opcode = 1,
            .since = 3,
            .deprecated_since = 4,
            .destructor = false,
            .signature = "3uuu",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "format", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "modifier_hi", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "modifier_lo", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ format, modifier };
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "zwp_linux_dmabuf_v1",
        .version = 6,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const zwp_linux_buffer_params_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const add: schema.Message = .{
            .name = "add",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "huuuuu",
            .descriptor_count = 1,
            .minimum_payload_size = 20,
            .arguments = &.{
                .{ .name = "fd", .kind = .fd, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "plane_idx", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "offset", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "stride", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "modifier_hi", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "modifier_lo", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const create: schema.Message = .{
            .name = "create",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "iiuu",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "format", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "flags", .kind = .uint, .interface = null, .enumeration = "flags", .nullable = false },
            },
        };
        pub const create_immed: schema.Message = .{
            .name = "create_immed",
            .opcode = 3,
            .since = 2,
            .deprecated_since = null,
            .destructor = false,
            .signature = "2niiuu",
            .descriptor_count = 0,
            .minimum_payload_size = 20,
            .arguments = &.{
                .{ .name = "buffer_id", .kind = .new_id, .interface = "wl_buffer", .enumeration = null, .nullable = false },
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "format", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "flags", .kind = .uint, .interface = null, .enumeration = "flags", .nullable = false },
            },
        };
        pub const set_sampling_device: schema.Message = .{
            .name = "set_sampling_device",
            .opcode = 4,
            .since = 6,
            .deprecated_since = null,
            .destructor = false,
            .signature = "6a",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "device", .kind = .array, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, add, create, create_immed, set_sampling_device };
    };
    pub const events = struct {
        pub const created: schema.Message = .{
            .name = "created",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "buffer", .kind = .new_id, .interface = "wl_buffer", .enumeration = null, .nullable = false },
            },
        };
        pub const failed: schema.Message = .{
            .name = "failed",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ created, failed };
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "already_used", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "plane_idx", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "plane_set", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "incomplete", .value = 3, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_format", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_dimensions", .value = 5, .since = 1, .deprecated_since = null },
                .{ .name = "out_of_bounds", .value = 6, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_wl_buffer", .value = 7, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_dev_t_size", .value = 8, .since = 1, .deprecated_since = null },
            },
        };
        pub const flags: schema.Enumeration = .{
            .name = "flags",
            .since = 1,
            .bitfield = true,
            .entries = &.{
                .{ .name = "y_invert", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "interlaced", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "bottom_first", .value = 4, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{ @"error", flags };
    };
    pub const metadata: schema.Interface = .{
        .name = "zwp_linux_buffer_params_v1",
        .version = 6,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const zwp_linux_dmabuf_feedback_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{destroy};
    };
    pub const events = struct {
        pub const done: schema.Message = .{
            .name = "done",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const format_table: schema.Message = .{
            .name = "format_table",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "hu",
            .descriptor_count = 1,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "fd", .kind = .fd, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "size", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const main_device: schema.Message = .{
            .name = "main_device",
            .opcode = 2,
            .since = 1,
            .deprecated_since = 6,
            .destructor = false,
            .signature = "a",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "device", .kind = .array, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const tranche_done: schema.Message = .{
            .name = "tranche_done",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const tranche_target_device: schema.Message = .{
            .name = "tranche_target_device",
            .opcode = 4,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "a",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "device", .kind = .array, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const tranche_formats: schema.Message = .{
            .name = "tranche_formats",
            .opcode = 5,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "a",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "indices", .kind = .array, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const tranche_flags: schema.Message = .{
            .name = "tranche_flags",
            .opcode = 6,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "flags", .kind = .uint, .interface = null, .enumeration = "tranche_flags", .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ done, format_table, main_device, tranche_done, tranche_target_device, tranche_formats, tranche_flags };
    };
    pub const enumerations = struct {
        pub const tranche_flags: schema.Enumeration = .{
            .name = "tranche_flags",
            .since = 1,
            .bitfield = true,
            .entries = &.{
                .{ .name = "scanout", .value = 1, .since = 4, .deprecated_since = null },
                .{ .name = "sampling", .value = 2, .since = 6, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{tranche_flags};
    };
    pub const metadata: schema.Interface = .{
        .name = "zwp_linux_dmabuf_feedback_v1",
        .version = 6,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wp_linux_drm_syncobj_manager_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const get_surface: schema.Message = .{
            .name = "get_surface",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "no",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wp_linux_drm_syncobj_surface_v1", .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
            },
        };
        pub const import_timeline: schema.Message = .{
            .name = "import_timeline",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "nh",
            .descriptor_count = 1,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wp_linux_drm_syncobj_timeline_v1", .enumeration = null, .nullable = false },
                .{ .name = "fd", .kind = .fd, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, get_surface, import_timeline };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "surface_exists", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_timeline", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wp_linux_drm_syncobj_manager_v1",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wp_linux_drm_syncobj_timeline_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{destroy};
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "wp_linux_drm_syncobj_timeline_v1",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wp_linux_drm_syncobj_surface_v1 = struct {
    pub const requests = struct {
        pub const destroy: schema.Message = .{
            .name = "destroy",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const set_acquire_point: schema.Message = .{
            .name = "set_acquire_point",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ouu",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "timeline", .kind = .object, .interface = "wp_linux_drm_syncobj_timeline_v1", .enumeration = null, .nullable = false },
                .{ .name = "point_hi", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "point_lo", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const set_release_point: schema.Message = .{
            .name = "set_release_point",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ouu",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "timeline", .kind = .object, .interface = "wp_linux_drm_syncobj_timeline_v1", .enumeration = null, .nullable = false },
                .{ .name = "point_hi", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "point_lo", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, set_acquire_point, set_release_point };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "no_surface", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "unsupported_buffer", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "no_buffer", .value = 3, .since = 1, .deprecated_since = null },
                .{ .name = "no_acquire_point", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "no_release_point", .value = 5, .since = 1, .deprecated_since = null },
                .{ .name = "conflicting_points", .value = 6, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wp_linux_drm_syncobj_surface_v1",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const interfaces = [_]schema.Interface{ xdg_wm_base.metadata, xdg_positioner.metadata, xdg_surface.metadata, xdg_toplevel.metadata, xdg_popup.metadata, wp_viewporter.metadata, wp_viewport.metadata, wp_fractional_scale_manager_v1.metadata, wp_fractional_scale_v1.metadata, zxdg_decoration_manager_v1.metadata, zxdg_toplevel_decoration_v1.metadata, wp_cursor_shape_manager_v1.metadata, wp_cursor_shape_device_v1.metadata, wp_presentation.metadata, wp_presentation_feedback.metadata, ext_image_capture_source_v1.metadata, ext_output_image_capture_source_manager_v1.metadata, ext_foreign_toplevel_image_capture_source_manager_v1.metadata, ext_image_copy_capture_manager_v1.metadata, ext_image_copy_capture_session_v1.metadata, ext_image_copy_capture_frame_v1.metadata, ext_image_copy_capture_cursor_session_v1.metadata, zwp_linux_dmabuf_v1.metadata, zwp_linux_buffer_params_v1.metadata, zwp_linux_dmabuf_feedback_v1.metadata, wp_linux_drm_syncobj_manager_v1.metadata, wp_linux_drm_syncobj_timeline_v1.metadata, wp_linux_drm_syncobj_surface_v1.metadata };
