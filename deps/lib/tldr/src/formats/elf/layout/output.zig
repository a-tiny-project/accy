const root = @import("../../../root.zig");
const elf = @import("../root.zig");

const model = root.model;
const OutputSection = elf.layout.OutputSection;
const output_section_count = elf.output_section.output_section_count;
const ehdr_size = elf.format.ehdr_size;
const phdr_size = elf.format.phdr_size;
const alignForward = elf.format.alignForward;
const alignForwardU64 = elf.format.alignForwardU64;
const reserveSize = elf.layout.reserveSize;

pub fn countLive(output_sections: []const OutputSection) usize {
    var count: usize = 0;
    for (output_sections) |section| {
        if (section.logicalSize() != 0) count += 1;
    }
    return count;
}

pub fn assign(
    output_sections: *[output_section_count]OutputSection,
    options: model.LinkOptions,
    program_header_count: usize,
) model.Error!void {
    var file_offset = ehdr_size + program_header_count * phdr_size;
    var address_cursor = options.image_base;
    var section_index: u16 = 1;
    var previous_alloc_was_tls = false;
    for (output_sections) |*section| {
        const logical_size = section.logicalSize();
        if (logical_size == 0) continue;
        file_offset = alignForward(file_offset, @intCast(@max(section.alignment, 1)));
        section.file_offset = @intCast(file_offset);
        section.address = if (section.kind.isAllocated())
            if (section.kind.isTls() and previous_alloc_was_tls)
                address_cursor
            else
                loadAddressForFileOffset(address_cursor, section.file_offset, options.page_size)
        else
            0;
        section.reserved_size = reserveSize(logical_size, section.alignment, options);
        section.section_index = section_index;
        section_index += 1;
        if (section.kind.isAllocated()) {
            address_cursor = section.address + section.reserved_size;
            previous_alloc_was_tls = section.kind.isTls();
        }
        file_offset += @intCast(section.fileLoadSize());
    }
}

fn loadAddressForFileOffset(address_cursor: u64, file_offset: u64, page_size: u64) u64 {
    if (page_size <= 1) return address_cursor + file_offset;
    return alignForwardU64(address_cursor, page_size) + file_offset % page_size;
}
