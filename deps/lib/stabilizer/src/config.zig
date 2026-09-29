pub const default_seed: u64 = 0x57ab_1e12_2013;
pub const default_shuffle_slots: usize = 256;
pub const default_region_size: usize = 0x2000000;
pub const code_alignment: usize = 32;
pub const stack_alignment: usize = 16;
pub const rerandomize_interval_ms: u64 = 500;
pub const max_stack_pad_unit: u8 = 255;

pub const Config = struct {
    seed: u64 = default_seed,
    heap: HeapConfig = .{},
    stack: StackConfig = .{},
    code: CodeConfig = .{},
};

pub const HeapConfig = struct {
    enabled: bool = true,
    pointer_validation: bool = true,
    shuffle_slots: usize = default_shuffle_slots,
    min_class_size: usize = 16,
    max_shuffled_size: usize = 64 * 1024,
};

pub const StackConfig = struct {
    enabled: bool = true,
    entries: usize = 256,
    alignment: usize = stack_alignment,
};

pub const CodeConfig = struct {
    enabled: bool = true,
    shuffle_slots: usize = default_shuffle_slots,
    alignment: usize = code_alignment,
    interval_ms: u64 = rerandomize_interval_ms,
};

pub const Reference = struct {
    pub const data_shuffle: usize = 256;
    pub const data_size: usize = 0x2000000;
    pub const code_shuffle: usize = 256;
    pub const code_size: usize = 0x2000000;
    pub const code_align: usize = 32;
    pub const stack_align: usize = 16;
    pub const interval_ms: u64 = 500;
};
