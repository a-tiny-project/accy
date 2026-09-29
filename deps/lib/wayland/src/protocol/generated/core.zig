const protocol = @import("../root.zig");

const schema = protocol.schema;

pub const wl_display = struct {
    pub const requests = struct {
        pub const sync: schema.Message = .{
            .name = "sync",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "callback", .kind = .new_id, .interface = "wl_callback", .enumeration = null, .nullable = false },
            },
        };
        pub const get_registry: schema.Message = .{
            .name = "get_registry",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "registry", .kind = .new_id, .interface = "wl_registry", .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ sync, get_registry };
    };
    pub const events = struct {
        pub const @"error": schema.Message = .{
            .name = "error",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ous",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "object_id", .kind = .object, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "code", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "message", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const delete_id: schema.Message = .{
            .name = "delete_id",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "id", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ @"error", delete_id };
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "invalid_object", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_method", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "no_memory", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "implementation", .value = 3, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_display",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_registry = struct {
    pub const requests = struct {
        pub const bind: schema.Message = .{
            .name = "bind",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "usun",
            .descriptor_count = 0,
            .minimum_payload_size = 20,
            .arguments = &.{
                .{ .name = "name", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "id", .kind = .new_id, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{bind};
    };
    pub const events = struct {
        pub const global: schema.Message = .{
            .name = "global",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "usu",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "name", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "interface", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "version", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const global_remove: schema.Message = .{
            .name = "global_remove",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "name", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ global, global_remove };
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_registry",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_callback = struct {
    pub const requests = struct {
        pub const all = [_]schema.Message{};
    };
    pub const events = struct {
        pub const done: schema.Message = .{
            .name = "done",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = true,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "callback_data", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{done};
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_callback",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_compositor = struct {
    pub const requests = struct {
        pub const create_surface: schema.Message = .{
            .name = "create_surface",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wl_surface", .enumeration = null, .nullable = false },
            },
        };
        pub const create_region: schema.Message = .{
            .name = "create_region",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wl_region", .enumeration = null, .nullable = false },
            },
        };
        pub const release: schema.Message = .{
            .name = "release",
            .opcode = 2,
            .since = 7,
            .deprecated_since = null,
            .destructor = true,
            .signature = "7",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ create_surface, create_region, release };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_compositor",
        .version = 7,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_shm_pool = struct {
    pub const requests = struct {
        pub const create_buffer: schema.Message = .{
            .name = "create_buffer",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "niiiiu",
            .descriptor_count = 0,
            .minimum_payload_size = 24,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wl_buffer", .enumeration = null, .nullable = false },
                .{ .name = "offset", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "stride", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "format", .kind = .uint, .interface = null, .enumeration = "wl_shm.format", .nullable = false },
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
        pub const resize: schema.Message = .{
            .name = "resize",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "i",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "size", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ create_buffer, destroy, resize };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_shm_pool",
        .version = 2,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_shm = struct {
    pub const requests = struct {
        pub const create_pool: schema.Message = .{
            .name = "create_pool",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "nhi",
            .descriptor_count = 1,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wl_shm_pool", .enumeration = null, .nullable = false },
                .{ .name = "fd", .kind = .fd, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "size", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const release: schema.Message = .{
            .name = "release",
            .opcode = 1,
            .since = 2,
            .deprecated_since = null,
            .destructor = true,
            .signature = "2",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ create_pool, release };
    };
    pub const events = struct {
        pub const format: schema.Message = .{
            .name = "format",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "format", .kind = .uint, .interface = null, .enumeration = "format", .nullable = false },
            },
        };
        pub const all = [_]schema.Message{format};
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "invalid_format", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_stride", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_fd", .value = 2, .since = 1, .deprecated_since = null },
            },
        };
        pub const format: schema.Enumeration = .{
            .name = "format",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "argb8888", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "xrgb8888", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "c8", .value = 538982467, .since = 1, .deprecated_since = null },
                .{ .name = "rgb332", .value = 943867730, .since = 1, .deprecated_since = null },
                .{ .name = "bgr233", .value = 944916290, .since = 1, .deprecated_since = null },
                .{ .name = "xrgb4444", .value = 842093144, .since = 1, .deprecated_since = null },
                .{ .name = "xbgr4444", .value = 842089048, .since = 1, .deprecated_since = null },
                .{ .name = "rgbx4444", .value = 842094674, .since = 1, .deprecated_since = null },
                .{ .name = "bgrx4444", .value = 842094658, .since = 1, .deprecated_since = null },
                .{ .name = "argb4444", .value = 842093121, .since = 1, .deprecated_since = null },
                .{ .name = "abgr4444", .value = 842089025, .since = 1, .deprecated_since = null },
                .{ .name = "rgba4444", .value = 842088786, .since = 1, .deprecated_since = null },
                .{ .name = "bgra4444", .value = 842088770, .since = 1, .deprecated_since = null },
                .{ .name = "xrgb1555", .value = 892424792, .since = 1, .deprecated_since = null },
                .{ .name = "xbgr1555", .value = 892420696, .since = 1, .deprecated_since = null },
                .{ .name = "rgbx5551", .value = 892426322, .since = 1, .deprecated_since = null },
                .{ .name = "bgrx5551", .value = 892426306, .since = 1, .deprecated_since = null },
                .{ .name = "argb1555", .value = 892424769, .since = 1, .deprecated_since = null },
                .{ .name = "abgr1555", .value = 892420673, .since = 1, .deprecated_since = null },
                .{ .name = "rgba5551", .value = 892420434, .since = 1, .deprecated_since = null },
                .{ .name = "bgra5551", .value = 892420418, .since = 1, .deprecated_since = null },
                .{ .name = "rgb565", .value = 909199186, .since = 1, .deprecated_since = null },
                .{ .name = "bgr565", .value = 909199170, .since = 1, .deprecated_since = null },
                .{ .name = "rgb888", .value = 875710290, .since = 1, .deprecated_since = null },
                .{ .name = "bgr888", .value = 875710274, .since = 1, .deprecated_since = null },
                .{ .name = "xbgr8888", .value = 875709016, .since = 1, .deprecated_since = null },
                .{ .name = "rgbx8888", .value = 875714642, .since = 1, .deprecated_since = null },
                .{ .name = "bgrx8888", .value = 875714626, .since = 1, .deprecated_since = null },
                .{ .name = "abgr8888", .value = 875708993, .since = 1, .deprecated_since = null },
                .{ .name = "rgba8888", .value = 875708754, .since = 1, .deprecated_since = null },
                .{ .name = "bgra8888", .value = 875708738, .since = 1, .deprecated_since = null },
                .{ .name = "xrgb2101010", .value = 808669784, .since = 1, .deprecated_since = null },
                .{ .name = "xbgr2101010", .value = 808665688, .since = 1, .deprecated_since = null },
                .{ .name = "rgbx1010102", .value = 808671314, .since = 1, .deprecated_since = null },
                .{ .name = "bgrx1010102", .value = 808671298, .since = 1, .deprecated_since = null },
                .{ .name = "argb2101010", .value = 808669761, .since = 1, .deprecated_since = null },
                .{ .name = "abgr2101010", .value = 808665665, .since = 1, .deprecated_since = null },
                .{ .name = "rgba1010102", .value = 808665426, .since = 1, .deprecated_since = null },
                .{ .name = "bgra1010102", .value = 808665410, .since = 1, .deprecated_since = null },
                .{ .name = "yuyv", .value = 1448695129, .since = 1, .deprecated_since = null },
                .{ .name = "yvyu", .value = 1431918169, .since = 1, .deprecated_since = null },
                .{ .name = "uyvy", .value = 1498831189, .since = 1, .deprecated_since = null },
                .{ .name = "vyuy", .value = 1498765654, .since = 1, .deprecated_since = null },
                .{ .name = "ayuv", .value = 1448433985, .since = 1, .deprecated_since = null },
                .{ .name = "nv12", .value = 842094158, .since = 1, .deprecated_since = null },
                .{ .name = "nv21", .value = 825382478, .since = 1, .deprecated_since = null },
                .{ .name = "nv16", .value = 909203022, .since = 1, .deprecated_since = null },
                .{ .name = "nv61", .value = 825644622, .since = 1, .deprecated_since = null },
                .{ .name = "yuv410", .value = 961959257, .since = 1, .deprecated_since = null },
                .{ .name = "yvu410", .value = 961893977, .since = 1, .deprecated_since = null },
                .{ .name = "yuv411", .value = 825316697, .since = 1, .deprecated_since = null },
                .{ .name = "yvu411", .value = 825316953, .since = 1, .deprecated_since = null },
                .{ .name = "yuv420", .value = 842093913, .since = 1, .deprecated_since = null },
                .{ .name = "yvu420", .value = 842094169, .since = 1, .deprecated_since = null },
                .{ .name = "yuv422", .value = 909202777, .since = 1, .deprecated_since = null },
                .{ .name = "yvu422", .value = 909203033, .since = 1, .deprecated_since = null },
                .{ .name = "yuv444", .value = 875713881, .since = 1, .deprecated_since = null },
                .{ .name = "yvu444", .value = 875714137, .since = 1, .deprecated_since = null },
                .{ .name = "r8", .value = 538982482, .since = 1, .deprecated_since = null },
                .{ .name = "r16", .value = 540422482, .since = 1, .deprecated_since = null },
                .{ .name = "rg88", .value = 943212370, .since = 1, .deprecated_since = null },
                .{ .name = "gr88", .value = 943215175, .since = 1, .deprecated_since = null },
                .{ .name = "rg1616", .value = 842221394, .since = 1, .deprecated_since = null },
                .{ .name = "gr1616", .value = 842224199, .since = 1, .deprecated_since = null },
                .{ .name = "xrgb16161616f", .value = 1211388504, .since = 1, .deprecated_since = null },
                .{ .name = "xbgr16161616f", .value = 1211384408, .since = 1, .deprecated_since = null },
                .{ .name = "argb16161616f", .value = 1211388481, .since = 1, .deprecated_since = null },
                .{ .name = "abgr16161616f", .value = 1211384385, .since = 1, .deprecated_since = null },
                .{ .name = "xyuv8888", .value = 1448434008, .since = 1, .deprecated_since = null },
                .{ .name = "vuy888", .value = 875713878, .since = 1, .deprecated_since = null },
                .{ .name = "vuy101010", .value = 808670550, .since = 1, .deprecated_since = null },
                .{ .name = "y210", .value = 808530521, .since = 1, .deprecated_since = null },
                .{ .name = "y212", .value = 842084953, .since = 1, .deprecated_since = null },
                .{ .name = "y216", .value = 909193817, .since = 1, .deprecated_since = null },
                .{ .name = "y410", .value = 808531033, .since = 1, .deprecated_since = null },
                .{ .name = "y412", .value = 842085465, .since = 1, .deprecated_since = null },
                .{ .name = "y416", .value = 909194329, .since = 1, .deprecated_since = null },
                .{ .name = "xvyu2101010", .value = 808670808, .since = 1, .deprecated_since = null },
                .{ .name = "xvyu12_16161616", .value = 909334104, .since = 1, .deprecated_since = null },
                .{ .name = "xvyu16161616", .value = 942954072, .since = 1, .deprecated_since = null },
                .{ .name = "y0l0", .value = 810299481, .since = 1, .deprecated_since = null },
                .{ .name = "x0l0", .value = 810299480, .since = 1, .deprecated_since = null },
                .{ .name = "y0l2", .value = 843853913, .since = 1, .deprecated_since = null },
                .{ .name = "x0l2", .value = 843853912, .since = 1, .deprecated_since = null },
                .{ .name = "yuv420_8bit", .value = 942691673, .since = 1, .deprecated_since = null },
                .{ .name = "yuv420_10bit", .value = 808539481, .since = 1, .deprecated_since = null },
                .{ .name = "xrgb8888_a8", .value = 943805016, .since = 1, .deprecated_since = null },
                .{ .name = "xbgr8888_a8", .value = 943800920, .since = 1, .deprecated_since = null },
                .{ .name = "rgbx8888_a8", .value = 943806546, .since = 1, .deprecated_since = null },
                .{ .name = "bgrx8888_a8", .value = 943806530, .since = 1, .deprecated_since = null },
                .{ .name = "rgb888_a8", .value = 943798354, .since = 1, .deprecated_since = null },
                .{ .name = "bgr888_a8", .value = 943798338, .since = 1, .deprecated_since = null },
                .{ .name = "rgb565_a8", .value = 943797586, .since = 1, .deprecated_since = null },
                .{ .name = "bgr565_a8", .value = 943797570, .since = 1, .deprecated_since = null },
                .{ .name = "nv24", .value = 875714126, .since = 1, .deprecated_since = null },
                .{ .name = "nv42", .value = 842290766, .since = 1, .deprecated_since = null },
                .{ .name = "p210", .value = 808530512, .since = 1, .deprecated_since = null },
                .{ .name = "p010", .value = 808530000, .since = 1, .deprecated_since = null },
                .{ .name = "p012", .value = 842084432, .since = 1, .deprecated_since = null },
                .{ .name = "p016", .value = 909193296, .since = 1, .deprecated_since = null },
                .{ .name = "axbxgxrx106106106106", .value = 808534593, .since = 1, .deprecated_since = null },
                .{ .name = "nv15", .value = 892425806, .since = 1, .deprecated_since = null },
                .{ .name = "q410", .value = 808531025, .since = 1, .deprecated_since = null },
                .{ .name = "q401", .value = 825242705, .since = 1, .deprecated_since = null },
                .{ .name = "xrgb16161616", .value = 942953048, .since = 1, .deprecated_since = null },
                .{ .name = "xbgr16161616", .value = 942948952, .since = 1, .deprecated_since = null },
                .{ .name = "argb16161616", .value = 942953025, .since = 1, .deprecated_since = null },
                .{ .name = "abgr16161616", .value = 942948929, .since = 1, .deprecated_since = null },
                .{ .name = "c1", .value = 538980675, .since = 1, .deprecated_since = null },
                .{ .name = "c2", .value = 538980931, .since = 1, .deprecated_since = null },
                .{ .name = "c4", .value = 538981443, .since = 1, .deprecated_since = null },
                .{ .name = "d1", .value = 538980676, .since = 1, .deprecated_since = null },
                .{ .name = "d2", .value = 538980932, .since = 1, .deprecated_since = null },
                .{ .name = "d4", .value = 538981444, .since = 1, .deprecated_since = null },
                .{ .name = "d8", .value = 538982468, .since = 1, .deprecated_since = null },
                .{ .name = "r1", .value = 538980690, .since = 1, .deprecated_since = null },
                .{ .name = "r2", .value = 538980946, .since = 1, .deprecated_since = null },
                .{ .name = "r4", .value = 538981458, .since = 1, .deprecated_since = null },
                .{ .name = "r10", .value = 540029266, .since = 1, .deprecated_since = null },
                .{ .name = "r12", .value = 540160338, .since = 1, .deprecated_since = null },
                .{ .name = "avuy8888", .value = 1498764865, .since = 1, .deprecated_since = null },
                .{ .name = "xvuy8888", .value = 1498764888, .since = 1, .deprecated_since = null },
                .{ .name = "p030", .value = 808661072, .since = 1, .deprecated_since = null },
                .{ .name = "rgb161616", .value = 942950226, .since = 1, .deprecated_since = null },
                .{ .name = "bgr161616", .value = 942950210, .since = 1, .deprecated_since = null },
                .{ .name = "r16f", .value = 1210064978, .since = 1, .deprecated_since = null },
                .{ .name = "gr1616f", .value = 1210077767, .since = 1, .deprecated_since = null },
                .{ .name = "bgr161616f", .value = 1213351746, .since = 1, .deprecated_since = null },
                .{ .name = "r32f", .value = 1176510546, .since = 1, .deprecated_since = null },
                .{ .name = "gr3232f", .value = 1176523335, .since = 1, .deprecated_since = null },
                .{ .name = "bgr323232f", .value = 1179797314, .since = 1, .deprecated_since = null },
                .{ .name = "abgr32323232f", .value = 1178092097, .since = 1, .deprecated_since = null },
                .{ .name = "nv20", .value = 808605262, .since = 1, .deprecated_since = null },
                .{ .name = "nv30", .value = 808670798, .since = 1, .deprecated_since = null },
                .{ .name = "s010", .value = 808530003, .since = 1, .deprecated_since = null },
                .{ .name = "s210", .value = 808530515, .since = 1, .deprecated_since = null },
                .{ .name = "s410", .value = 808531027, .since = 1, .deprecated_since = null },
                .{ .name = "s012", .value = 842084435, .since = 1, .deprecated_since = null },
                .{ .name = "s212", .value = 842084947, .since = 1, .deprecated_since = null },
                .{ .name = "s412", .value = 842085459, .since = 1, .deprecated_since = null },
                .{ .name = "s016", .value = 909193299, .since = 1, .deprecated_since = null },
                .{ .name = "s216", .value = 909193811, .since = 1, .deprecated_since = null },
                .{ .name = "s416", .value = 909194323, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{ @"error", format };
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_shm",
        .version = 2,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_buffer = struct {
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
        pub const release: schema.Message = .{
            .name = "release",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{release};
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_buffer",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_data_offer = struct {
    pub const requests = struct {
        pub const accept: schema.Message = .{
            .name = "accept",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u?s",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "mime_type", .kind = .string, .interface = null, .enumeration = null, .nullable = true },
            },
        };
        pub const receive: schema.Message = .{
            .name = "receive",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "sh",
            .descriptor_count = 1,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "mime_type", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "fd", .kind = .fd, .interface = null, .enumeration = null, .nullable = false },
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
        pub const finish: schema.Message = .{
            .name = "finish",
            .opcode = 3,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const set_actions: schema.Message = .{
            .name = "set_actions",
            .opcode = 4,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3uu",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "dnd_actions", .kind = .uint, .interface = null, .enumeration = "wl_data_device_manager.dnd_action", .nullable = false },
                .{ .name = "preferred_action", .kind = .uint, .interface = null, .enumeration = "wl_data_device_manager.dnd_action", .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ accept, receive, destroy, finish, set_actions };
    };
    pub const events = struct {
        pub const offer: schema.Message = .{
            .name = "offer",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "s",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "mime_type", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const source_actions: schema.Message = .{
            .name = "source_actions",
            .opcode = 1,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "source_actions", .kind = .uint, .interface = null, .enumeration = "wl_data_device_manager.dnd_action", .nullable = false },
            },
        };
        pub const action: schema.Message = .{
            .name = "action",
            .opcode = 2,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "dnd_action", .kind = .uint, .interface = null, .enumeration = "wl_data_device_manager.dnd_action", .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ offer, source_actions, action };
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "invalid_finish", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_action_mask", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_action", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_offer", .value = 3, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_data_offer",
        .version = 4,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_data_source = struct {
    pub const requests = struct {
        pub const offer: schema.Message = .{
            .name = "offer",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "s",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "mime_type", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
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
        pub const set_actions: schema.Message = .{
            .name = "set_actions",
            .opcode = 2,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "dnd_actions", .kind = .uint, .interface = null, .enumeration = "wl_data_device_manager.dnd_action", .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ offer, destroy, set_actions };
    };
    pub const events = struct {
        pub const target: schema.Message = .{
            .name = "target",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "?s",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "mime_type", .kind = .string, .interface = null, .enumeration = null, .nullable = true },
            },
        };
        pub const send: schema.Message = .{
            .name = "send",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "sh",
            .descriptor_count = 1,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "mime_type", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "fd", .kind = .fd, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const cancelled: schema.Message = .{
            .name = "cancelled",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const dnd_drop_performed: schema.Message = .{
            .name = "dnd_drop_performed",
            .opcode = 3,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const dnd_finished: schema.Message = .{
            .name = "dnd_finished",
            .opcode = 4,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const action: schema.Message = .{
            .name = "action",
            .opcode = 5,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "dnd_action", .kind = .uint, .interface = null, .enumeration = "wl_data_device_manager.dnd_action", .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ target, send, cancelled, dnd_drop_performed, dnd_finished, action };
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "invalid_action_mask", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_source", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_data_source",
        .version = 4,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_data_device = struct {
    pub const requests = struct {
        pub const start_drag: schema.Message = .{
            .name = "start_drag",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "?oo?ou",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "source", .kind = .object, .interface = "wl_data_source", .enumeration = null, .nullable = true },
                .{ .name = "origin", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
                .{ .name = "icon", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = true },
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const set_selection: schema.Message = .{
            .name = "set_selection",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "?ou",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "source", .kind = .object, .interface = "wl_data_source", .enumeration = null, .nullable = true },
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const release: schema.Message = .{
            .name = "release",
            .opcode = 2,
            .since = 2,
            .deprecated_since = null,
            .destructor = true,
            .signature = "2",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ start_drag, set_selection, release };
    };
    pub const events = struct {
        pub const data_offer: schema.Message = .{
            .name = "data_offer",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wl_data_offer", .enumeration = null, .nullable = false },
            },
        };
        pub const enter: schema.Message = .{
            .name = "enter",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uoff?o",
            .descriptor_count = 0,
            .minimum_payload_size = 20,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
                .{ .name = "x", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "id", .kind = .object, .interface = "wl_data_offer", .enumeration = null, .nullable = true },
            },
        };
        pub const leave: schema.Message = .{
            .name = "leave",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const motion: schema.Message = .{
            .name = "motion",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uff",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "time", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "x", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const drop: schema.Message = .{
            .name = "drop",
            .opcode = 4,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const selection: schema.Message = .{
            .name = "selection",
            .opcode = 5,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "?o",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "id", .kind = .object, .interface = "wl_data_offer", .enumeration = null, .nullable = true },
            },
        };
        pub const all = [_]schema.Message{ data_offer, enter, leave, motion, drop, selection };
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "role", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "used_source", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_data_device",
        .version = 4,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_data_device_manager = struct {
    pub const requests = struct {
        pub const create_data_source: schema.Message = .{
            .name = "create_data_source",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wl_data_source", .enumeration = null, .nullable = false },
            },
        };
        pub const get_data_device: schema.Message = .{
            .name = "get_data_device",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "no",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wl_data_device", .enumeration = null, .nullable = false },
                .{ .name = "seat", .kind = .object, .interface = "wl_seat", .enumeration = null, .nullable = false },
            },
        };
        pub const release: schema.Message = .{
            .name = "release",
            .opcode = 2,
            .since = 4,
            .deprecated_since = null,
            .destructor = true,
            .signature = "4",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ create_data_source, get_data_device, release };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const dnd_action: schema.Enumeration = .{
            .name = "dnd_action",
            .since = 3,
            .bitfield = true,
            .entries = &.{
                .{ .name = "none", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "copy", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "move", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "ask", .value = 4, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{dnd_action};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_data_device_manager",
        .version = 4,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_shell = struct {
    pub const requests = struct {
        pub const get_shell_surface: schema.Message = .{
            .name = "get_shell_surface",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "no",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wl_shell_surface", .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{get_shell_surface};
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
                .{ .name = "role", .value = 0, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_shell",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_shell_surface = struct {
    pub const requests = struct {
        pub const pong: schema.Message = .{
            .name = "pong",
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
        pub const move: schema.Message = .{
            .name = "move",
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
        pub const resize: schema.Message = .{
            .name = "resize",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ouu",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "seat", .kind = .object, .interface = "wl_seat", .enumeration = null, .nullable = false },
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "edges", .kind = .uint, .interface = null, .enumeration = "resize", .nullable = false },
            },
        };
        pub const set_toplevel: schema.Message = .{
            .name = "set_toplevel",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const set_transient: schema.Message = .{
            .name = "set_transient",
            .opcode = 4,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "oiiu",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "parent", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "flags", .kind = .uint, .interface = null, .enumeration = "transient", .nullable = false },
            },
        };
        pub const set_fullscreen: schema.Message = .{
            .name = "set_fullscreen",
            .opcode = 5,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uu?o",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "method", .kind = .uint, .interface = null, .enumeration = "fullscreen_method", .nullable = false },
                .{ .name = "framerate", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "output", .kind = .object, .interface = "wl_output", .enumeration = null, .nullable = true },
            },
        };
        pub const set_popup: schema.Message = .{
            .name = "set_popup",
            .opcode = 6,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "ouoiiu",
            .descriptor_count = 0,
            .minimum_payload_size = 24,
            .arguments = &.{
                .{ .name = "seat", .kind = .object, .interface = "wl_seat", .enumeration = null, .nullable = false },
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "parent", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "flags", .kind = .uint, .interface = null, .enumeration = "transient", .nullable = false },
            },
        };
        pub const set_maximized: schema.Message = .{
            .name = "set_maximized",
            .opcode = 7,
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
        pub const set_title: schema.Message = .{
            .name = "set_title",
            .opcode = 8,
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
        pub const set_class: schema.Message = .{
            .name = "set_class",
            .opcode = 9,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "s",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "class_", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ pong, move, resize, set_toplevel, set_transient, set_fullscreen, set_popup, set_maximized, set_title, set_class };
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
        pub const configure: schema.Message = .{
            .name = "configure",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uii",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "edges", .kind = .uint, .interface = null, .enumeration = "resize", .nullable = false },
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const popup_done: schema.Message = .{
            .name = "popup_done",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ ping, configure, popup_done };
    };
    pub const enumerations = struct {
        pub const resize: schema.Enumeration = .{
            .name = "resize",
            .since = 1,
            .bitfield = true,
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
        pub const transient: schema.Enumeration = .{
            .name = "transient",
            .since = 1,
            .bitfield = true,
            .entries = &.{
                .{ .name = "inactive", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const fullscreen_method: schema.Enumeration = .{
            .name = "fullscreen_method",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "default", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "scale", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "driver", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "fill", .value = 3, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{ resize, transient, fullscreen_method };
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_shell_surface",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_surface = struct {
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
        pub const attach: schema.Message = .{
            .name = "attach",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "?oii",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "buffer", .kind = .object, .interface = "wl_buffer", .enumeration = null, .nullable = true },
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const damage: schema.Message = .{
            .name = "damage",
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
        pub const frame: schema.Message = .{
            .name = "frame",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "callback", .kind = .new_id, .interface = "wl_callback", .enumeration = null, .nullable = false },
            },
        };
        pub const set_opaque_region: schema.Message = .{
            .name = "set_opaque_region",
            .opcode = 4,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "?o",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "region", .kind = .object, .interface = "wl_region", .enumeration = null, .nullable = true },
            },
        };
        pub const set_input_region: schema.Message = .{
            .name = "set_input_region",
            .opcode = 5,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "?o",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "region", .kind = .object, .interface = "wl_region", .enumeration = null, .nullable = true },
            },
        };
        pub const commit: schema.Message = .{
            .name = "commit",
            .opcode = 6,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const set_buffer_transform: schema.Message = .{
            .name = "set_buffer_transform",
            .opcode = 7,
            .since = 2,
            .deprecated_since = null,
            .destructor = false,
            .signature = "2i",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "transform", .kind = .int, .interface = null, .enumeration = "wl_output.transform", .nullable = false },
            },
        };
        pub const set_buffer_scale: schema.Message = .{
            .name = "set_buffer_scale",
            .opcode = 8,
            .since = 3,
            .deprecated_since = null,
            .destructor = false,
            .signature = "3i",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "scale", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const damage_buffer: schema.Message = .{
            .name = "damage_buffer",
            .opcode = 9,
            .since = 4,
            .deprecated_since = null,
            .destructor = false,
            .signature = "4iiii",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const offset: schema.Message = .{
            .name = "offset",
            .opcode = 10,
            .since = 5,
            .deprecated_since = null,
            .destructor = false,
            .signature = "5ii",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const get_release: schema.Message = .{
            .name = "get_release",
            .opcode = 11,
            .since = 7,
            .deprecated_since = null,
            .destructor = false,
            .signature = "7n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "callback", .kind = .new_id, .interface = "wl_callback", .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, attach, damage, frame, set_opaque_region, set_input_region, commit, set_buffer_transform, set_buffer_scale, damage_buffer, offset, get_release };
    };
    pub const events = struct {
        pub const enter: schema.Message = .{
            .name = "enter",
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
        pub const leave: schema.Message = .{
            .name = "leave",
            .opcode = 1,
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
        pub const preferred_buffer_scale: schema.Message = .{
            .name = "preferred_buffer_scale",
            .opcode = 2,
            .since = 6,
            .deprecated_since = null,
            .destructor = false,
            .signature = "6i",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "factor", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const preferred_buffer_transform: schema.Message = .{
            .name = "preferred_buffer_transform",
            .opcode = 3,
            .since = 6,
            .deprecated_since = null,
            .destructor = false,
            .signature = "6u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "transform", .kind = .uint, .interface = null, .enumeration = "wl_output.transform", .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ enter, leave, preferred_buffer_scale, preferred_buffer_transform };
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "invalid_scale", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_transform", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_size", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "invalid_offset", .value = 3, .since = 1, .deprecated_since = null },
                .{ .name = "defunct_role_object", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "no_buffer", .value = 5, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_surface",
        .version = 7,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_seat = struct {
    pub const requests = struct {
        pub const get_pointer: schema.Message = .{
            .name = "get_pointer",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wl_pointer", .enumeration = null, .nullable = false },
            },
        };
        pub const get_keyboard: schema.Message = .{
            .name = "get_keyboard",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wl_keyboard", .enumeration = null, .nullable = false },
            },
        };
        pub const get_touch: schema.Message = .{
            .name = "get_touch",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "n",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wl_touch", .enumeration = null, .nullable = false },
            },
        };
        pub const release: schema.Message = .{
            .name = "release",
            .opcode = 3,
            .since = 5,
            .deprecated_since = null,
            .destructor = true,
            .signature = "5",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ get_pointer, get_keyboard, get_touch, release };
    };
    pub const events = struct {
        pub const capabilities: schema.Message = .{
            .name = "capabilities",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "capabilities", .kind = .uint, .interface = null, .enumeration = "capability", .nullable = false },
            },
        };
        pub const name: schema.Message = .{
            .name = "name",
            .opcode = 1,
            .since = 2,
            .deprecated_since = null,
            .destructor = false,
            .signature = "2s",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "name", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ capabilities, name };
    };
    pub const enumerations = struct {
        pub const capability: schema.Enumeration = .{
            .name = "capability",
            .since = 1,
            .bitfield = true,
            .entries = &.{
                .{ .name = "pointer", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "keyboard", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "touch", .value = 4, .since = 1, .deprecated_since = null },
            },
        };
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "missing_capability", .value = 0, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{ capability, @"error" };
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_seat",
        .version = 10,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_pointer = struct {
    pub const requests = struct {
        pub const set_cursor: schema.Message = .{
            .name = "set_cursor",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "u?oii",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = true },
                .{ .name = "hotspot_x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "hotspot_y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const release: schema.Message = .{
            .name = "release",
            .opcode = 1,
            .since = 3,
            .deprecated_since = null,
            .destructor = true,
            .signature = "3",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ set_cursor, release };
    };
    pub const events = struct {
        pub const enter: schema.Message = .{
            .name = "enter",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uoff",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
                .{ .name = "surface_x", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "surface_y", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const leave: schema.Message = .{
            .name = "leave",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uo",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
            },
        };
        pub const motion: schema.Message = .{
            .name = "motion",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uff",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "time", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "surface_x", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "surface_y", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const button: schema.Message = .{
            .name = "button",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uuuu",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "time", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "button", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "state", .kind = .uint, .interface = null, .enumeration = "button_state", .nullable = false },
            },
        };
        pub const axis: schema.Message = .{
            .name = "axis",
            .opcode = 4,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uuf",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "time", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "axis", .kind = .uint, .interface = null, .enumeration = "axis", .nullable = false },
                .{ .name = "value", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const frame: schema.Message = .{
            .name = "frame",
            .opcode = 5,
            .since = 5,
            .deprecated_since = null,
            .destructor = false,
            .signature = "5",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const axis_source: schema.Message = .{
            .name = "axis_source",
            .opcode = 6,
            .since = 5,
            .deprecated_since = null,
            .destructor = false,
            .signature = "5u",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "axis_source", .kind = .uint, .interface = null, .enumeration = "axis_source", .nullable = false },
            },
        };
        pub const axis_stop: schema.Message = .{
            .name = "axis_stop",
            .opcode = 7,
            .since = 5,
            .deprecated_since = null,
            .destructor = false,
            .signature = "5uu",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "time", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "axis", .kind = .uint, .interface = null, .enumeration = "axis", .nullable = false },
            },
        };
        pub const axis_discrete: schema.Message = .{
            .name = "axis_discrete",
            .opcode = 8,
            .since = 5,
            .deprecated_since = 8,
            .destructor = false,
            .signature = "5ui",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "axis", .kind = .uint, .interface = null, .enumeration = "axis", .nullable = false },
                .{ .name = "discrete", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const axis_value120: schema.Message = .{
            .name = "axis_value120",
            .opcode = 9,
            .since = 8,
            .deprecated_since = null,
            .destructor = false,
            .signature = "8ui",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "axis", .kind = .uint, .interface = null, .enumeration = "axis", .nullable = false },
                .{ .name = "value120", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const axis_relative_direction: schema.Message = .{
            .name = "axis_relative_direction",
            .opcode = 10,
            .since = 9,
            .deprecated_since = null,
            .destructor = false,
            .signature = "9uu",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "axis", .kind = .uint, .interface = null, .enumeration = "axis", .nullable = false },
                .{ .name = "direction", .kind = .uint, .interface = null, .enumeration = "axis_relative_direction", .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ enter, leave, motion, button, axis, frame, axis_source, axis_stop, axis_discrete, axis_value120, axis_relative_direction };
    };
    pub const enumerations = struct {
        pub const @"error": schema.Enumeration = .{
            .name = "error",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "role", .value = 0, .since = 1, .deprecated_since = null },
            },
        };
        pub const button_state: schema.Enumeration = .{
            .name = "button_state",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "released", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "pressed", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const axis: schema.Enumeration = .{
            .name = "axis",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "vertical_scroll", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "horizontal_scroll", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const axis_source: schema.Enumeration = .{
            .name = "axis_source",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "wheel", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "finger", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "continuous", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "wheel_tilt", .value = 3, .since = 6, .deprecated_since = null },
            },
        };
        pub const axis_relative_direction: schema.Enumeration = .{
            .name = "axis_relative_direction",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "identical", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "inverted", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{ @"error", button_state, axis, axis_source, axis_relative_direction };
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_pointer",
        .version = 10,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_keyboard = struct {
    pub const requests = struct {
        pub const release: schema.Message = .{
            .name = "release",
            .opcode = 0,
            .since = 3,
            .deprecated_since = null,
            .destructor = true,
            .signature = "3",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{release};
    };
    pub const events = struct {
        pub const keymap: schema.Message = .{
            .name = "keymap",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uhu",
            .descriptor_count = 1,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "format", .kind = .uint, .interface = null, .enumeration = "keymap_format", .nullable = false },
                .{ .name = "fd", .kind = .fd, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "size", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const enter: schema.Message = .{
            .name = "enter",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uoa",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
                .{ .name = "keys", .kind = .array, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const leave: schema.Message = .{
            .name = "leave",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uo",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
            },
        };
        pub const key: schema.Message = .{
            .name = "key",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uuuu",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "time", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "key", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "state", .kind = .uint, .interface = null, .enumeration = "key_state", .nullable = false },
            },
        };
        pub const modifiers: schema.Message = .{
            .name = "modifiers",
            .opcode = 4,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uuuuu",
            .descriptor_count = 0,
            .minimum_payload_size = 20,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "mods_depressed", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "mods_latched", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "mods_locked", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "group", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const repeat_info: schema.Message = .{
            .name = "repeat_info",
            .opcode = 5,
            .since = 4,
            .deprecated_since = null,
            .destructor = false,
            .signature = "4ii",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "rate", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "delay", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ keymap, enter, leave, key, modifiers, repeat_info };
    };
    pub const enumerations = struct {
        pub const keymap_format: schema.Enumeration = .{
            .name = "keymap_format",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "no_keymap", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "xkb_v1", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const key_state: schema.Enumeration = .{
            .name = "key_state",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "released", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "pressed", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "repeated", .value = 2, .since = 10, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{ keymap_format, key_state };
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_keyboard",
        .version = 10,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_touch = struct {
    pub const requests = struct {
        pub const release: schema.Message = .{
            .name = "release",
            .opcode = 0,
            .since = 3,
            .deprecated_since = null,
            .destructor = true,
            .signature = "3",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{release};
    };
    pub const events = struct {
        pub const down: schema.Message = .{
            .name = "down",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uuoiff",
            .descriptor_count = 0,
            .minimum_payload_size = 24,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "time", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
                .{ .name = "id", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "x", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const up: schema.Message = .{
            .name = "up",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uui",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "serial", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "time", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "id", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const motion: schema.Message = .{
            .name = "motion",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uiff",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "time", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "id", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "x", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const frame: schema.Message = .{
            .name = "frame",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const cancel: schema.Message = .{
            .name = "cancel",
            .opcode = 4,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const shape: schema.Message = .{
            .name = "shape",
            .opcode = 5,
            .since = 6,
            .deprecated_since = null,
            .destructor = false,
            .signature = "6iff",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "id", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "major", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "minor", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const orientation: schema.Message = .{
            .name = "orientation",
            .opcode = 6,
            .since = 6,
            .deprecated_since = null,
            .destructor = false,
            .signature = "6if",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "id", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "orientation", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ down, up, motion, frame, cancel, shape, orientation };
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_touch",
        .version = 10,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_output = struct {
    pub const requests = struct {
        pub const release: schema.Message = .{
            .name = "release",
            .opcode = 0,
            .since = 3,
            .deprecated_since = null,
            .destructor = true,
            .signature = "3",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{release};
    };
    pub const events = struct {
        pub const geometry: schema.Message = .{
            .name = "geometry",
            .opcode = 0,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "iiiiissi",
            .descriptor_count = 0,
            .minimum_payload_size = 40,
            .arguments = &.{
                .{ .name = "x", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "y", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "physical_width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "physical_height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "subpixel", .kind = .int, .interface = null, .enumeration = "subpixel", .nullable = false },
                .{ .name = "make", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "model", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "transform", .kind = .int, .interface = null, .enumeration = "transform", .nullable = false },
            },
        };
        pub const mode: schema.Message = .{
            .name = "mode",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "uiii",
            .descriptor_count = 0,
            .minimum_payload_size = 16,
            .arguments = &.{
                .{ .name = "flags", .kind = .uint, .interface = null, .enumeration = "mode", .nullable = false },
                .{ .name = "width", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "height", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
                .{ .name = "refresh", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const done: schema.Message = .{
            .name = "done",
            .opcode = 2,
            .since = 2,
            .deprecated_since = null,
            .destructor = false,
            .signature = "2",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const scale: schema.Message = .{
            .name = "scale",
            .opcode = 3,
            .since = 2,
            .deprecated_since = null,
            .destructor = false,
            .signature = "2i",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "factor", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const name: schema.Message = .{
            .name = "name",
            .opcode = 4,
            .since = 4,
            .deprecated_since = null,
            .destructor = false,
            .signature = "4s",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "name", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const description: schema.Message = .{
            .name = "description",
            .opcode = 5,
            .since = 4,
            .deprecated_since = null,
            .destructor = false,
            .signature = "4s",
            .descriptor_count = 0,
            .minimum_payload_size = 8,
            .arguments = &.{
                .{ .name = "description", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ geometry, mode, done, scale, name, description };
    };
    pub const enumerations = struct {
        pub const subpixel: schema.Enumeration = .{
            .name = "subpixel",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "unknown", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "none", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "horizontal_rgb", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "horizontal_bgr", .value = 3, .since = 1, .deprecated_since = null },
                .{ .name = "vertical_rgb", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "vertical_bgr", .value = 5, .since = 1, .deprecated_since = null },
            },
        };
        pub const transform: schema.Enumeration = .{
            .name = "transform",
            .since = 1,
            .bitfield = false,
            .entries = &.{
                .{ .name = "normal", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "90", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "180", .value = 2, .since = 1, .deprecated_since = null },
                .{ .name = "270", .value = 3, .since = 1, .deprecated_since = null },
                .{ .name = "flipped", .value = 4, .since = 1, .deprecated_since = null },
                .{ .name = "flipped_90", .value = 5, .since = 1, .deprecated_since = null },
                .{ .name = "flipped_180", .value = 6, .since = 1, .deprecated_since = null },
                .{ .name = "flipped_270", .value = 7, .since = 1, .deprecated_since = null },
            },
        };
        pub const mode: schema.Enumeration = .{
            .name = "mode",
            .since = 1,
            .bitfield = true,
            .entries = &.{
                .{ .name = "current", .value = 1, .since = 1, .deprecated_since = null },
                .{ .name = "preferred", .value = 2, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{ subpixel, transform, mode };
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_output",
        .version = 4,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_region = struct {
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
        pub const subtract: schema.Message = .{
            .name = "subtract",
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
        pub const all = [_]schema.Message{ destroy, add, subtract };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_region",
        .version = 7,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_subcompositor = struct {
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
        pub const get_subsurface: schema.Message = .{
            .name = "get_subsurface",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "noo",
            .descriptor_count = 0,
            .minimum_payload_size = 12,
            .arguments = &.{
                .{ .name = "id", .kind = .new_id, .interface = "wl_subsurface", .enumeration = null, .nullable = false },
                .{ .name = "surface", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
                .{ .name = "parent", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, get_subsurface };
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
                .{ .name = "bad_surface", .value = 0, .since = 1, .deprecated_since = null },
                .{ .name = "bad_parent", .value = 1, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_subcompositor",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_subsurface = struct {
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
        pub const set_position: schema.Message = .{
            .name = "set_position",
            .opcode = 1,
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
        pub const place_above: schema.Message = .{
            .name = "place_above",
            .opcode = 2,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "o",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "sibling", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
            },
        };
        pub const place_below: schema.Message = .{
            .name = "place_below",
            .opcode = 3,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "o",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "sibling", .kind = .object, .interface = "wl_surface", .enumeration = null, .nullable = false },
            },
        };
        pub const set_sync: schema.Message = .{
            .name = "set_sync",
            .opcode = 4,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const set_desync: schema.Message = .{
            .name = "set_desync",
            .opcode = 5,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "",
            .descriptor_count = 0,
            .minimum_payload_size = 0,
            .arguments = &.{},
        };
        pub const all = [_]schema.Message{ destroy, set_position, place_above, place_below, set_sync, set_desync };
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
                .{ .name = "bad_surface", .value = 0, .since = 1, .deprecated_since = null },
            },
        };
        pub const all = [_]schema.Enumeration{@"error"};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_subsurface",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const wl_fixes = struct {
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
        pub const destroy_registry: schema.Message = .{
            .name = "destroy_registry",
            .opcode = 1,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "o",
            .descriptor_count = 0,
            .minimum_payload_size = 4,
            .arguments = &.{
                .{ .name = "registry", .kind = .object, .interface = "wl_registry", .enumeration = null, .nullable = false },
            },
        };
        pub const all = [_]schema.Message{ destroy, destroy_registry };
    };
    pub const events = struct {
        pub const all = [_]schema.Message{};
    };
    pub const enumerations = struct {
        pub const all = [_]schema.Enumeration{};
    };
    pub const metadata: schema.Interface = .{
        .name = "wl_fixes",
        .version = 1,
        .requests = &requests.all,
        .events = &events.all,
        .enumerations = &enumerations.all,
    };
};

pub const interfaces = [_]schema.Interface{ wl_display.metadata, wl_registry.metadata, wl_callback.metadata, wl_compositor.metadata, wl_shm_pool.metadata, wl_shm.metadata, wl_buffer.metadata, wl_data_offer.metadata, wl_data_source.metadata, wl_data_device.metadata, wl_data_device_manager.metadata, wl_shell.metadata, wl_shell_surface.metadata, wl_surface.metadata, wl_seat.metadata, wl_pointer.metadata, wl_keyboard.metadata, wl_touch.metadata, wl_output.metadata, wl_region.metadata, wl_subcompositor.metadata, wl_subsurface.metadata, wl_fixes.metadata };
