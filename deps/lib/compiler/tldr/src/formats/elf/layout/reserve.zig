pub fn size(section_size: u64, alignment: u64, options: anytype) u64 {
    if (options.incremental_mode == .off or section_size == 0) return alignForwardU64(section_size, alignment);
    const proportional = (section_size * options.incremental_reserve_percent + 99) / 100;
    const slack = @max(alignment, proportional);
    return alignForwardU64(section_size + slack, alignment);
}

pub fn contribution(section_size: u64, alignment: u64, options: anytype) u64 {
    if (options.incremental_mode == .off) return section_size;
    return size(section_size, alignment, options);
}

fn alignForwardU64(value: u64, alignment: u64) u64 {
    if (alignment == 0) return value;
    const mask = alignment - 1;
    return (value + mask) & ~mask;
}
