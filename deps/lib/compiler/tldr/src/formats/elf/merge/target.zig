const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const order = @import("order.zig");
const record = @import("record.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const OutputSection = elf.layout.OutputSection;
const SectionContribution = elf.layout.SectionContribution;
const output_section_count = elf.output_section.output_section_count;
const alignForwardU64 = elf.format.alignForwardU64;
const contributionReserveSize = elf.layout.contributionReserveSize;
const Record = record.Record;

pub fn assign(
    allocator: Allocator,
    output_sections: *[output_section_count]OutputSection,
    records: []Record,
    options: model.LinkOptions,
) model.Error!void {
    try order.records(allocator, records, options.max_link_jobs);

    var head: ?*const Record = null;
    for (records) |*current| {
        if (head) |store| {
            if (!record.sameStorageGroup(store.*, current.*)) {
                head = null;
            } else if (tailIntraOffset(current.*, store.*)) |intra_offset| {
                if (!current.external_start or intra_offset == 0) {
                    current.piece.contribution = store.piece.contribution;
                    current.piece.output_intra_offset = intra_offset;
                    continue;
                }
            }
        }

        var output = &output_sections[current.output_index];
        const aligned_offset = alignForwardU64(output.file_size, current.alignment);
        const size: u64 = @intCast(current.bytes.len);
        const reserved_size = contributionReserveSize(size, current.alignment, options);
        const contribution = SectionContribution.init(
            current.output_index,
            aligned_offset,
            size,
            reserved_size,
            current.alignment,
        );
        current.piece.contribution = contribution;
        current.piece.output_intra_offset = 0;
        output.file_size = aligned_offset + reserved_size;
        output.memory_size = output.file_size;
        head = current;
    }
}

fn tailIntraOffset(current: Record, store: Record) ?u64 {
    if (current.bytes.len > store.bytes.len) return null;
    const intra_offset = store.bytes.len - current.bytes.len;
    if (!std.mem.eql(u8, current.bytes, store.bytes[intra_offset..])) return null;
    return @intCast(intra_offset);
}
