const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const record = @import("record.zig");
const start = @import("start.zig");
const target = @import("target.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const parallel = root.parallel;
const ObjectFile = elf.parser.ObjectFile;
const OutputSection = elf.layout.OutputSection;
const MergePieceLayout = elf.layout.MergePieceLayout;
const MergeSectionLayout = elf.layout.MergeSectionLayout;
const SectionHeader = elf.format.SectionHeader;
const output_section_count = elf.output_section.output_section_count;
const sectionBytes = elf.format.sectionBytes;
const outputIndexForAlloc = elf.output_section.indexForAllocated;
const Record = record.Record;

const parallel_scan_threshold = 2 * 1024 * 1024;
const scan_bytes_per_worker = 256 * 1024;

pub const String = struct {
    records: std.ArrayListUnmanaged(Record) = .empty,
    pending: std.ArrayListUnmanaged(Pending) = .empty,

    const Pending = struct {
        bytes: []const u8,
        external_starts: []const u64,
        layout_slot: *MergeSectionLayout,
        alignment: u64,
        section_type: u32,
        output_index: u8,
        base: usize = 0,
        count: usize = 0,
        pieces: []MergePieceLayout = &.{},
    };

    const ScanContext = struct {
        pending: []Pending,
        records: []Record,
    };

    pub fn deinit(self: *String, allocator: Allocator) void {
        self.records.deinit(allocator);
        self.pending.deinit(allocator);
    }

    pub fn register(
        self: *String,
        allocator: Allocator,
        object: ObjectFile,
        section: SectionHeader,
        section_index: usize,
        external_starts: []const u64,
        output_sections: *[output_section_count]OutputSection,
        layout_slot: *MergeSectionLayout,
    ) model.Error!void {
        if (object.relocationsForSection(section_index).len != 0) return error.UnsupportedRelocation;

        const bytes = try sectionBytes(object.bytes, section);
        if (bytes.len == 0) return;
        if (bytes[bytes.len - 1] != 0) return error.InvalidObject;

        const output_index = outputIndexForAlloc(section);
        var output = &output_sections[output_index];
        const alignment = @max(section.alignment, 1);
        output.alignment = @max(output.alignment, alignment);

        const starts = if (external_starts.len != 0)
            try allocator.dupe(u64, external_starts)
        else
            external_starts;
        try self.pending.append(allocator, .{
            .bytes = bytes,
            .external_starts = starts,
            .layout_slot = layout_slot,
            .alignment = alignment,
            .section_type = section.section_type,
            .output_index = @intCast(output_index),
        });
    }

    pub fn finish(
        self: *String,
        allocator: Allocator,
        output_sections: *[output_section_count]OutputSection,
        options: model.LinkOptions,
    ) model.Error!void {
        try self.materialize(allocator, options);
        try target.assign(allocator, output_sections, self.records.items, options);
    }

    fn materialize(self: *String, allocator: Allocator, options: model.LinkOptions) model.Error!void {
        if (self.pending.items.len == 0) return;
        const pending = self.pending.items;

        var total_bytes: usize = 0;
        for (pending) |entry| total_bytes += entry.bytes.len;
        const requested_workers = if (options.max_link_jobs != 0)
            options.max_link_jobs
        else
            total_bytes / scan_bytes_per_worker;
        const workers = if (total_bytes >= parallel_scan_threshold)
            parallel.chooseWorkers(pending.len, requested_workers)
        else
            1;

        var count_context = ScanContext{ .pending = pending, .records = &.{} };
        if (workers <= 1) {
            for (pending, 0..) |_, index| countPending(&count_context, 0, index);
        } else {
            parallel.forItems(pending.len, workers, &count_context, countPending);
        }

        var total: usize = 0;
        for (pending) |*entry| {
            entry.base = total;
            total += entry.count;
            entry.pieces = try allocator.alloc(MergePieceLayout, entry.count);
            entry.layout_slot.* = .{ .pieces = entry.pieces };
        }
        if (std.math.cast(u32, total) == null) return error.InvalidObject;
        try self.records.resize(allocator, total);

        var fill_context = ScanContext{ .pending = pending, .records = self.records.items };
        if (workers <= 1) {
            for (pending, 0..) |_, index| fillPending(&fill_context, 0, index);
        } else {
            parallel.forItems(pending.len, workers, &fill_context, fillPending);
        }
    }

    fn countPending(context: *ScanContext, worker: usize, index: usize) void {
        _ = worker;
        context.pending[index].count = start.count(context.pending[index].bytes);
    }

    fn fillPending(context: *ScanContext, worker: usize, index: usize) void {
        _ = worker;
        const entry = context.pending[index];
        const records = context.records[entry.base..][0..entry.count];
        const bytes = entry.bytes;
        var input_offset: usize = 0;
        var piece_index: usize = 0;
        var external_start_index: usize = 0;
        for (bytes, 0..) |byte, byte_index| {
            if (byte != 0) continue;
            const end = byte_index + 1;
            const string_bytes = bytes[input_offset..end];
            entry.pieces[piece_index] = .{
                .input_offset = @intCast(input_offset),
                .size = @intCast(string_bytes.len),
            };
            records[piece_index] = .{
                .ordinal = @intCast(entry.base + piece_index),
                .section_type = entry.section_type,
                .output_index = entry.output_index,
                .alignment = entry.alignment,
                .reverse_prefix = record.reversePrefix(string_bytes),
                .bytes = string_bytes,
                .piece = &entry.pieces[piece_index],
                .external_start = start.has(entry.external_starts, &external_start_index, input_offset),
            };
            piece_index += 1;
            input_offset = end;
        }
    }
};
