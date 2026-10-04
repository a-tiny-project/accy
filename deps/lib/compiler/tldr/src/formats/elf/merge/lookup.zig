const elf = @import("../root.zig");

const ObjectFile = elf.parser.ObjectFile;
const ObjectLayout = elf.layout.ObjectLayout;
const OutputSection = elf.layout.OutputSection;
const SectionContribution = elf.layout.SectionContribution;
const MergePieceLayout = elf.layout.MergePieceLayout;
const mergeSectionLayout = elf.layout.mergeSection;

pub const Piece = struct {
    contribution: SectionContribution,
    intra_offset: u64,
};

pub fn address(
    object_layout: ObjectLayout,
    object: ObjectFile,
    output_sections: []const OutputSection,
    section_index: usize,
    offset: u64,
) ?u64 {
    const entry = piece(object_layout, object, section_index, offset) orelse return null;
    const output = output_sections[entry.contribution.outputIndex()];
    return output.address + entry.contribution.offset + entry.intra_offset;
}

pub fn contribution(
    object_layout: ObjectLayout,
    object: ObjectFile,
    section_index: usize,
    offset: u64,
) ?SectionContribution {
    const entry = piece(object_layout, object, section_index, offset) orelse return null;
    return entry.contribution;
}

pub fn piece(
    object_layout: ObjectLayout,
    object: ObjectFile,
    section_index: usize,
    offset: u64,
) ?Piece {
    const merge_section = mergeSectionLayout(object_layout, section_index) orelse return null;
    const section = object.sections[section_index];
    if (offset >= section.size) return null;

    if (merge_section.fixed_piece_size != 0) {
        const piece_index: usize = @intCast(offset / merge_section.fixed_piece_size);
        if (piece_index >= merge_section.pieces.len) return null;
        const fixed_piece = merge_section.pieces[piece_index];
        return .{
            .contribution = fixed_piece.contribution,
            .intra_offset = fixed_piece.output_intra_offset + offset % merge_section.fixed_piece_size,
        };
    }

    const string_piece = stringPiece(merge_section.pieces, offset) orelse return null;
    return .{
        .contribution = string_piece.contribution,
        .intra_offset = string_piece.output_intra_offset + offset - string_piece.input_offset,
    };
}

fn stringPiece(pieces: []const MergePieceLayout, offset: u64) ?MergePieceLayout {
    var low: usize = 0;
    var high: usize = pieces.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const current = pieces[mid];
        if (offset < current.input_offset) {
            high = mid;
        } else if (offset >= current.input_offset + current.size) {
            low = mid + 1;
        } else {
            return current;
        }
    }
    return null;
}
