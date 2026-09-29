pub const ValueType = enum(u8) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
};

pub const Section = enum(u8) {
    type = 1,
    import = 2,
    function = 3,
    memory = 5,
    export_ = 7,
    code = 10,
};

pub const ExternalKind = enum(u8) {
    function = 0,
    memory = 2,
};

pub const empty_block_type: u8 = 0x40;
