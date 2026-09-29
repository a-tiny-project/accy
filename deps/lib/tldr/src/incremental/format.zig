const std = @import("std");
const builtin = @import("builtin");
const incremental = @import("root.zig");
const parallel = @import("../root.zig").parallel;

const Allocator = std.mem.Allocator;
const ContributionKind = incremental.ContributionKind;
const ContributionRecord = incremental.ContributionRecord;
const DiscardReason = incremental.DiscardReason;
const DiscardedContributionRecord = incremental.DiscardedContributionRecord;
const ArchiveMemberRecord = incremental.ArchiveMemberRecord;
const GotEntryRecord = incremental.GotEntryRecord;
const MergePieceRecord = incremental.MergePieceRecord;
const ExternalTargetRecord = incremental.ExternalTargetRecord;
const InputRecord = incremental.InputRecord;
const Manifest = incremental.Manifest;
const SectionRecord = incremental.SectionRecord;
const StringSpan = incremental.StringSpan;

const manifest_binary_magic = [_]u8{ 'T', 'L', 'D', 'R', 'I', 'M', 'F', 10 };

const file_endianness: u8 = switch (builtin.cpu.arch.endian()) {
    .little => 0,
    .big => 1,
};

const LinkMapTotals = struct {
    retained_size: u64 = 0,
    retained_reserve: u64 = 0,
    discarded_size: u64 = 0,
};

const BinaryReader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn take(self: *BinaryReader, len: usize) ![]const u8 {
        if (self.index > self.bytes.len or len > self.bytes.len - self.index) return error.InvalidManifestBinary;
        const result = self.bytes[self.index..][0..len];
        self.index += len;
        return result;
    }

    fn readU8(self: *BinaryReader) !u8 {
        return (try self.take(1))[0];
    }

    fn readU16(self: *BinaryReader) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }

    fn readU32(self: *BinaryReader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn readU64(self: *BinaryReader) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }

    fn finish(self: BinaryReader) !void {
        if (self.index != self.bytes.len) return error.InvalidManifestBinary;
    }
};

const LinkMapContributionSummary = struct {
    count: usize = 0,
    size: u64 = 0,
    reserved_size: u64 = 0,
};

const LinkMapDiscardSummary = struct {
    count: usize = 0,
    size: u64 = 0,
};

const link_map_discard_reasons = [_]DiscardReason{
    .discarded,
    .identical_code_folded,
};

pub fn textAlloc(manifest: Manifest, allocator: Allocator) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeText(manifest, &out.writer);
    return try out.toOwnedSlice();
}

pub fn binaryAlloc(manifest: Manifest, allocator: Allocator) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeBinary(manifest, &out.writer);
    return try out.toOwnedSlice();
}

pub fn manifestFromBinary(allocator: Allocator, bytes: []u8) !Manifest {
    const walked = try walkBinary(bytes);

    const manifest: Manifest = .{
        .target = .{
            .object_format = try enumFromByte(@TypeOf(Manifest.empty().target.object_format), walked.header.object_format),
            .architecture = try enumFromByte(@TypeOf(Manifest.empty().target.architecture), walked.header.architecture),
            .endianness = try enumFromByte(@TypeOf(Manifest.empty().target.endianness), walked.header.endianness),
            .pointer_width_bits = walked.header.pointer_width_bits,
        },
        .output_kind = try enumFromByte(@TypeOf(Manifest.empty().output_kind), walked.header.output_kind),
        .entry_symbol_id = walked.header.entry_symbol_id,
        .image_base = walked.header.image_base,
        .page_size = walked.header.page_size,
        .gc_sections = try boolFromByte(walked.header.gc_sections),
        .icf = try enumFromByte(@TypeOf(Manifest.empty().icf), walked.header.icf),
        .strip_debug = try boolFromByte(walked.header.strip_debug),
        .build_id = try enumFromByte(@TypeOf(Manifest.empty().build_id), walked.header.build_id),
        .input_hashes_recorded = try boolFromByte(walked.header.input_hashes_recorded),
        .inputs_read_at_ns = @bitCast(walked.header.inputs_read_at_ns),
        .strings = .{
            .spans = walked.spans,
            .blob = walked.blob,
        },
        .inputs = recordSlice(InputRecord, bytes, walked.sections[0]),
        .sections = recordSlice(SectionRecord, bytes, walked.sections[1]),
        .contributions = recordSlice(ContributionRecord, bytes, walked.sections[2]),
        .discarded_contributions = recordSlice(DiscardedContributionRecord, bytes, walked.sections[3]),
        .external_targets = recordSlice(ExternalTargetRecord, bytes, walked.sections[4]),
        .archive_members = recordSlice(ArchiveMemberRecord, bytes, walked.sections[5]),
        .got_entries = recordSlice(GotEntryRecord, bytes, walked.sections[6]),
        .merge_pieces = recordSlice(MergePieceRecord, bytes, walked.sections[7]),
    };

    const string_count = std.math.cast(u32, walked.spans.len) orelse return error.InvalidManifestBinary;
    if (string_count != 0 and manifest.entry_symbol_id >= string_count) return error.InvalidManifestBinary;
    for (walked.spans) |span| {
        if (span.offset > walked.blob.len or span.len > walked.blob.len - span.offset) {
            return error.InvalidManifestBinary;
        }
    }

    try validateRecords(allocator, bytes, walked.sections, string_count);
    return manifest;
}

const binary_header_scalar_bytes = 1 + 1 + 1 + 2 + 1 + 4 + 8 + 8 + 1 + 1 + 1 + 1 + 1 + 8;
const header_read_at_patch_offset = binary_header_scalar_bytes - 8;

const BinaryHeader = struct {
    object_format: u8,
    architecture: u8,
    endianness: u8,
    pointer_width_bits: u16,
    output_kind: u8,
    entry_symbol_id: u32,
    image_base: u64,
    page_size: u64,
    gc_sections: u8,
    icf: u8,
    strip_debug: u8,
    build_id: u8,
    input_hashes_recorded: u8,
    inputs_read_at_ns: u64,
};

const WalkedBinary = struct {
    header_offset: usize,
    header: BinaryHeader,
    spans: []const StringSpan,
    blob: []const u8,
    sections: [record_section_count]RecordSectionLayout,
};

fn walkBinary(bytes: []const u8) !WalkedBinary {
    var reader: BinaryReader = .{ .bytes = bytes };
    const magic = try reader.take(manifest_binary_magic.len);
    if (!std.mem.eql(u8, magic, &manifest_binary_magic)) return error.UnsupportedManifestProtocol;
    const protocol_len = std.math.cast(usize, try reader.readU32()) orelse return error.InvalidManifestBinary;
    const protocol = try reader.take(protocol_len);
    if (!std.mem.eql(u8, protocol, incremental.manifest_binary_protocol)) return error.UnsupportedManifestProtocol;
    if (try reader.readU8() != file_endianness) return error.UnsupportedManifestProtocol;

    const header_offset = reader.index;
    const header = BinaryHeader{
        .object_format = try reader.readU8(),
        .architecture = try reader.readU8(),
        .endianness = try reader.readU8(),
        .pointer_width_bits = try reader.readU16(),
        .output_kind = try reader.readU8(),
        .entry_symbol_id = try reader.readU32(),
        .image_base = try reader.readU64(),
        .page_size = try reader.readU64(),
        .gc_sections = try reader.readU8(),
        .icf = try reader.readU8(),
        .strip_debug = try reader.readU8(),
        .build_id = try reader.readU8(),
        .input_hashes_recorded = try reader.readU8(),
        .inputs_read_at_ns = try reader.readU64(),
    };

    const string_count = std.math.cast(usize, try reader.readU32()) orelse return error.InvalidManifestBinary;
    const spans_bytes = try reader.take(string_count * @sizeOf(StringSpan));
    const spans = std.mem.bytesAsSlice(StringSpan, spans_bytes);
    const blob_len = std.math.cast(usize, try reader.readU32()) orelse return error.InvalidManifestBinary;
    const blob = try reader.take(blob_len);

    var sections: [record_section_count]RecordSectionLayout = undefined;
    for (&sections, 0..) |*section, section_index| {
        const count = std.math.cast(usize, try reader.readU32()) orelse return error.InvalidManifestBinary;
        const span = std.math.mul(usize, count, record_binary_sizes[section_index]) catch return error.InvalidManifestBinary;
        section.* = .{ .count = count, .offset = reader.index };
        _ = try reader.take(span);
    }
    try reader.finish();

    return .{
        .header_offset = header_offset,
        .header = header,
        .spans = spans,
        .blob = blob,
        .sections = sections,
    };
}

fn recordSlice(comptime Record: type, bytes: []u8, layout: RecordSectionLayout) []Record {
    if (layout.count == 0) return &.{};
    return std.mem.bytesAsSlice(Record, bytes[layout.offset..][0 .. layout.count * @sizeOf(Record)]);
}

fn enumFromByte(comptime Enum: type, byte: u8) !Enum {
    inline for (std.meta.tags(Enum)) |value| {
        if (@backingInt(value) == byte) return value;
    }
    return error.InvalidManifestBinary;
}

fn boolFromByte(byte: u8) !bool {
    return switch (byte) {
        0 => false,
        1 => true,
        else => error.InvalidManifestBinary,
    };
}

const record_section_count = 8;

pub const record_binary_sizes = [record_section_count]usize{
    @sizeOf(InputRecord),
    @sizeOf(SectionRecord),
    @sizeOf(ContributionRecord),
    @sizeOf(DiscardedContributionRecord),
    @sizeOf(ExternalTargetRecord),
    @sizeOf(ArchiveMemberRecord),
    @sizeOf(GotEntryRecord),
    @sizeOf(MergePieceRecord),
};

const record_chunk_len = 65536;

const RecordSectionLayout = struct {
    count: usize,
    offset: usize,
};

const ValidateTask = struct {
    section: usize,
    start: usize,
    len: usize,
};

const ValidateFailure = struct {
    section: usize = std.math.maxInt(usize),
    start: usize = 0,
    err: ?anyerror = null,

    fn found(self: ValidateFailure) bool {
        return self.err != null;
    }

    fn before(self: ValidateFailure, other: ValidateFailure) bool {
        if (self.section != other.section) return self.section < other.section;
        return self.start < other.start;
    }
};

const ValidateFailures = parallel.FailureSlots(ValidateFailure);

const ValidateContext = struct {
    bytes: []const u8,
    sections: [record_section_count]RecordSectionLayout,
    string_count: u32,
    tasks: []const ValidateTask = &.{},
    failures: ?*ValidateFailures = null,
};

fn validateRecords(
    allocator: Allocator,
    bytes: []const u8,
    sections: [record_section_count]RecordSectionLayout,
    string_count: u32,
) !void {
    var context = ValidateContext{
        .bytes = bytes,
        .sections = sections,
        .string_count = string_count,
    };

    var total_records: usize = 0;
    for (sections) |section| total_records += section.count;

    if (total_records < record_chunk_len or !parallel.overlapAvailable()) {
        for (sections, 0..) |section, section_index| {
            try validateRecordRange(&context, section_index, 0, section.count);
        }
        return;
    }

    var tasks = std.ArrayListUnmanaged(ValidateTask).empty;
    defer tasks.deinit(allocator);
    for (sections, 0..) |section, section_index| {
        var start: usize = 0;
        while (start < section.count) {
            const len = @min(record_chunk_len, section.count - start);
            try tasks.append(allocator, .{ .section = section_index, .start = start, .len = len });
            start += len;
        }
    }
    if (tasks.items.len == 0) return;

    const workers = parallel.chooseWorkers(tasks.items.len, 0);
    var failures = try ValidateFailures.init(allocator, workers, .{});
    defer failures.deinit(allocator);
    context.tasks = tasks.items;
    context.failures = &failures;
    parallel.forItems(tasks.items.len, workers, &context, validateTaskItem);
    if (failures.earliest(ValidateFailure.found, ValidateFailure.before)) |failure| {
        return failure.err.?;
    }
}

fn validateTaskItem(context: *ValidateContext, worker: usize, task_index: usize) void {
    const task = context.tasks[task_index];
    validateRecordRange(context, task.section, task.start, task.len) catch |err| {
        const failures = context.failures.?;
        const current = failures.items[worker];
        const failure = ValidateFailure{ .section = task.section, .start = task.start, .err = err };
        if (!current.found() or ValidateFailure.before(failure, current)) {
            failures.record(worker, failure);
        }
    };
}

const FieldCheck = struct {
    offset: usize,
    kind: enum { string_id, boolean, contribution_kind, discard_reason },
};

const section_field_checks = [record_section_count][]const FieldCheck{
    &.{
        .{ .offset = @offsetOf(InputRecord, "name_id"), .kind = .string_id },
        .{ .offset = @offsetOf(InputRecord, "identity_recorded"), .kind = .boolean },
    },
    &.{
        .{ .offset = @offsetOf(SectionRecord, "name_id"), .kind = .string_id },
    },
    &.{
        .{ .offset = @offsetOf(ContributionRecord, "input_name_id"), .kind = .string_id },
        .{ .offset = @offsetOf(ContributionRecord, "name_id"), .kind = .string_id },
        .{ .offset = @offsetOf(ContributionRecord, "output_section_name_id"), .kind = .string_id },
        .{ .offset = @offsetOf(ContributionRecord, "kind"), .kind = .contribution_kind },
    },
    &.{
        .{ .offset = @offsetOf(DiscardedContributionRecord, "input_name_id"), .kind = .string_id },
        .{ .offset = @offsetOf(DiscardedContributionRecord, "name_id"), .kind = .string_id },
        .{ .offset = @offsetOf(DiscardedContributionRecord, "reason"), .kind = .discard_reason },
    },
    &.{
        .{ .offset = @offsetOf(ExternalTargetRecord, "name_id"), .kind = .string_id },
        .{ .offset = @offsetOf(ExternalTargetRecord, "address_signed"), .kind = .boolean },
    },
    &.{
        .{ .offset = @offsetOf(ArchiveMemberRecord, "name_id"), .kind = .string_id },
        .{ .offset = @offsetOf(ArchiveMemberRecord, "selected"), .kind = .boolean },
    },
    &.{
        .{ .offset = @offsetOf(GotEntryRecord, "input_name_id"), .kind = .string_id },
        .{ .offset = @offsetOf(GotEntryRecord, "name_id"), .kind = .string_id },
    },
    &.{
        .{ .offset = @offsetOf(MergePieceRecord, "input_name_id"), .kind = .string_id },
    },
};

fn validateRecordRange(context: *ValidateContext, section_index: usize, start: usize, len: usize) !void {
    const layout = context.sections[section_index];
    const record_size = record_binary_sizes[section_index];
    const checks = section_field_checks[section_index];
    var index = start;
    while (index < start + len) : (index += 1) {
        const record_bytes = context.bytes[layout.offset + index * record_size ..][0..record_size];
        for (checks) |check| {
            switch (check.kind) {
                .string_id => {
                    const id = std.mem.readInt(u32, record_bytes[check.offset..][0..4], .little);
                    if (id >= context.string_count) return error.InvalidManifestBinary;
                },
                .boolean => _ = try boolFromByte(record_bytes[check.offset]),
                .contribution_kind => _ = try enumFromByte(ContributionKind, record_bytes[check.offset]),
                .discard_reason => _ = try enumFromByte(DiscardReason, record_bytes[check.offset]),
            }
        }
    }
}

pub const ManifestBinaryLayout = struct {
    header_offset: usize,
    sections: [record_section_count]RecordSectionLayout,
};

pub fn recordSectionLayouts(bytes: []const u8) !ManifestBinaryLayout {
    const walked = try walkBinary(bytes);
    return .{ .header_offset = walked.header_offset, .sections = walked.sections };
}

pub const manifest_field_patch_capacity = 40;

pub const ManifestFieldPatch = struct {
    offset: usize,
    len: usize,
    bytes: [manifest_field_patch_capacity]u8,

    pub fn slice(self: *const ManifestFieldPatch) []const u8 {
        return self.bytes[0..self.len];
    }
};

const input_scalar_patch_offset = @offsetOf(InputRecord, "size");
const input_scalar_patch_len = @offsetOf(InputRecord, "identity_recorded") + 1 - input_scalar_patch_offset;
const contribution_scalar_patch_offset = @offsetOf(ContributionRecord, "size");
const contribution_scalar_patch_len = @offsetOf(ContributionRecord, "file_size") + 8 - contribution_scalar_patch_offset;
const archive_member_scalar_patch_offset = @offsetOf(ArchiveMemberRecord, "hash");
const archive_member_scalar_patch_len = @offsetOf(ArchiveMemberRecord, "link_hash") + 8 - archive_member_scalar_patch_offset;

pub fn manifestScalarPatchesAlloc(
    allocator: Allocator,
    encoded: []const u8,
    manifest: Manifest,
    input_indexes: []const usize,
    contribution_indexes: []const usize,
    archive_member_indexes: []const usize,
) ![]ManifestFieldPatch {
    const layout = try recordSectionLayouts(encoded);
    const sections = layout.sections;
    const patches = try allocator.alloc(
        ManifestFieldPatch,
        1 + input_indexes.len + contribution_indexes.len + archive_member_indexes.len,
    );
    errdefer allocator.free(patches);
    var cursor: usize = 0;
    var read_at_patch = ManifestFieldPatch{
        .offset = layout.header_offset + header_read_at_patch_offset,
        .len = 8,
        .bytes = undefined,
    };
    std.mem.writeInt(u64, read_at_patch.bytes[0..8], @bitCast(manifest.inputs_read_at_ns), .little);
    patches[cursor] = read_at_patch;
    cursor += 1;
    for (input_indexes) |index| {
        if (index >= sections[0].count or index >= manifest.inputs.len) return error.InvalidManifestBinary;
        patches[cursor] = recordBytesPatch(
            InputRecord,
            &manifest.inputs[index],
            sections[0].offset + index * record_binary_sizes[0],
            input_scalar_patch_offset,
            input_scalar_patch_len,
        );
        cursor += 1;
    }
    for (contribution_indexes) |index| {
        if (index >= sections[2].count or index >= manifest.contributions.len) return error.InvalidManifestBinary;
        patches[cursor] = recordBytesPatch(
            ContributionRecord,
            &manifest.contributions[index],
            sections[2].offset + index * record_binary_sizes[2],
            contribution_scalar_patch_offset,
            contribution_scalar_patch_len,
        );
        cursor += 1;
    }
    for (archive_member_indexes) |index| {
        if (index >= sections[5].count or index >= manifest.archive_members.len) return error.InvalidManifestBinary;
        patches[cursor] = recordBytesPatch(
            ArchiveMemberRecord,
            &manifest.archive_members[index],
            sections[5].offset + index * record_binary_sizes[5],
            archive_member_scalar_patch_offset,
            archive_member_scalar_patch_len,
        );
        cursor += 1;
    }
    return patches;
}

fn recordBytesPatch(
    comptime Record: type,
    record: *const Record,
    record_offset: usize,
    field_offset: usize,
    len: usize,
) ManifestFieldPatch {
    var patch = ManifestFieldPatch{
        .offset = record_offset + field_offset,
        .len = len,
        .bytes = undefined,
    };
    const source = std.mem.asBytes(record)[field_offset..][0..len];
    @memcpy(patch.bytes[0..len], source);
    return patch;
}

pub fn writeBinary(manifest: Manifest, writer: *std.Io.Writer) !void {
    try writer.writeAll(&manifest_binary_magic);
    try writeStringBinary(writer, incremental.manifest_binary_protocol);
    try writer.writeByte(file_endianness);

    try writeEnumBinary(writer, manifest.target.object_format);
    try writeEnumBinary(writer, manifest.target.architecture);
    try writeEnumBinary(writer, manifest.target.endianness);
    try writeU16Binary(writer, manifest.target.pointer_width_bits);
    try writeEnumBinary(writer, manifest.output_kind);
    try writeU32Binary(writer, manifest.entry_symbol_id);
    try writeU64Binary(writer, manifest.image_base);
    try writeU64Binary(writer, manifest.page_size);
    try writeBoolBinary(writer, manifest.gc_sections);
    try writeEnumBinary(writer, manifest.icf);
    try writeBoolBinary(writer, manifest.strip_debug);
    try writeEnumBinary(writer, manifest.build_id);
    try writeBoolBinary(writer, manifest.input_hashes_recorded);
    try writeU64Binary(writer, @bitCast(manifest.inputs_read_at_ns));

    const strings = &manifest.strings;
    try writeCountBinary(writer, strings.count());
    const tier0_blob_len = std.math.cast(u32, strings.blob.len) orelse return error.ManifestTooLarge;
    for (strings.spans) |span| {
        try writeU32Binary(writer, span.offset);
        try writeU32Binary(writer, span.len);
    }
    for (strings.appendix_spans.items) |span| {
        const shifted = std.math.add(u32, span.offset, tier0_blob_len) catch return error.ManifestTooLarge;
        try writeU32Binary(writer, shifted);
        try writeU32Binary(writer, span.len);
    }
    const total_blob = std.math.add(usize, strings.blob.len, strings.appendix.items.len) catch return error.ManifestTooLarge;
    try writeCountBinary(writer, total_blob);
    try writer.writeAll(strings.blob);
    try writer.writeAll(strings.appendix.items);

    try writeRecordSection(writer, manifest.inputs);
    try writeRecordSection(writer, manifest.sections);
    try writeRecordSection(writer, manifest.contributions);
    try writeRecordSection(writer, manifest.discarded_contributions);
    try writeRecordSection(writer, manifest.external_targets);
    try writeRecordSection(writer, manifest.archive_members);
    try writeRecordSection(writer, manifest.got_entries);
    try writeRecordSection(writer, manifest.merge_pieces);
}

fn writeRecordSection(writer: *std.Io.Writer, records: anytype) !void {
    try writeCountBinary(writer, records.len);
    if (records.len != 0) {
        try writer.writeAll(std.mem.sliceAsBytes(records));
    }
}

pub fn writeText(manifest: Manifest, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const totals = linkMapTotals(manifest);

    try writer.writeAll("tldr link map\n");
    try writer.print(
        "target: {s}/{s} {s} ptr={d}\n",
        .{
            @tagName(manifest.target.object_format),
            @tagName(manifest.target.architecture),
            @tagName(manifest.target.endianness),
            manifest.target.pointer_width_bits,
        },
    );
    try writer.print(
        "output: {s} entry={s} image_base=0x{x} page_size=0x{x}\n",
        .{ @tagName(manifest.output_kind), manifest.entrySymbol(), manifest.image_base, manifest.page_size },
    );
    try writer.print("options: gc_sections={} icf={s} strip_debug={} build_id={s}\n", .{ manifest.gc_sections, @tagName(manifest.icf), manifest.strip_debug, @tagName(manifest.build_id) });
    try writer.print(
        "summary: inputs={d} sections={d} retained={d} retained_size={d} retained_reserve={d} discarded={d} discarded_size={d} external_targets={d} archive_members={d} got_entries={d} merge_pieces={d}\n",
        .{
            manifest.inputs.len,
            manifest.sections.len,
            manifest.contributions.len,
            totals.retained_size,
            totals.retained_reserve,
            manifest.discarded_contributions.len,
            totals.discarded_size,
            manifest.external_targets.len,
            manifest.archive_members.len,
            manifest.got_entries.len,
            manifest.merge_pieces.len,
        },
    );
    if (manifest.contributions.len != 0) {
        try writer.writeAll("retained by output:\n");
        for (manifest.sections) |section| {
            const summary = outputContributionSummary(manifest, section.name_id);
            if (summary.count == 0) continue;
            try writer.print(
                "  {s} count={d} size={d} reserve={d}\n",
                .{ manifest.string(section.name_id), summary.count, summary.size, summary.reserved_size },
            );
        }
    }
    if (manifest.discarded_contributions.len != 0) {
        try writer.writeAll("discarded by reason:\n");
        for (link_map_discard_reasons) |reason| {
            const summary = discardedReasonSummary(manifest, reason);
            if (summary.count == 0) continue;
            try writer.print(
                "  {s} count={d} size={d}\n",
                .{ @tagName(reason), summary.count, summary.size },
            );
        }
    }

    try writer.print("inputs ({d}):\n", .{manifest.inputs.len});
    for (manifest.inputs) |input| {
        if (manifest.input_hashes_recorded) {
            try writer.print("  {s} size={d} hash=0x{x}\n", .{ manifest.string(input.name_id), input.size, input.hash });
        } else {
            try writer.print("  {s} size={d} hash=unrecorded\n", .{ manifest.string(input.name_id), input.size });
        }
    }

    try writer.print("sections ({d}):\n", .{manifest.sections.len});
    for (manifest.sections) |section| {
        try writer.print(
            "  {s} addr=0x{x} file=0x{x} size={d} reserve={d} align={d}\n",
            .{
                manifest.string(section.name_id),
                section.address,
                section.file_offset,
                section.size,
                section.reserved_size,
                section.alignment,
            },
        );
    }

    try writer.print("contributions ({d}):\n", .{manifest.contributions.len});
    for (manifest.contributions) |contribution| {
        try writer.print(
            "  {s} <- {s}:{s}#{d} kind={s} addr=0x{x} file=0x{x} size={d} file_size={d} reserve={d} align={d}\n",
            .{
                manifest.string(contribution.output_section_name_id),
                manifest.string(contribution.input_name_id),
                manifest.string(contribution.name_id),
                contribution.ordinal,
                @tagName(contribution.kind),
                contribution.address,
                contribution.file_offset,
                contribution.size,
                contribution.file_size,
                contribution.reserved_size,
                contribution.alignment,
            },
        );
    }

    try writer.print("discarded ({d}):\n", .{manifest.discarded_contributions.len});
    for (manifest.discarded_contributions) |contribution| {
        try writer.print(
            "  {s}:{s}#{d} reason={s} size={d} align={d}\n",
            .{
                manifest.string(contribution.input_name_id),
                manifest.string(contribution.name_id),
                contribution.ordinal,
                @tagName(contribution.reason),
                contribution.size,
                contribution.alignment,
            },
        );
    }
}

fn linkMapTotals(manifest: Manifest) LinkMapTotals {
    var totals: LinkMapTotals = .{};
    for (manifest.contributions) |contribution| {
        totals.retained_size += contribution.size;
        totals.retained_reserve += contribution.reserved_size;
    }
    for (manifest.discarded_contributions) |contribution| {
        totals.discarded_size += contribution.size;
    }
    return totals;
}

fn outputContributionSummary(manifest: Manifest, output_section_name_id: u32) LinkMapContributionSummary {
    var summary: LinkMapContributionSummary = .{};
    const output_section_name = manifest.string(output_section_name_id);
    for (manifest.contributions) |contribution| {
        if (contribution.output_section_name_id != output_section_name_id and
            !std.mem.eql(u8, manifest.string(contribution.output_section_name_id), output_section_name)) continue;
        summary.count += 1;
        summary.size += contribution.size;
        summary.reserved_size += contribution.reserved_size;
    }
    return summary;
}

fn discardedReasonSummary(manifest: Manifest, reason: DiscardReason) LinkMapDiscardSummary {
    var summary: LinkMapDiscardSummary = .{};
    for (manifest.discarded_contributions) |contribution| {
        if (contribution.reason != reason) continue;
        summary.count += 1;
        summary.size += contribution.size;
    }
    return summary;
}

fn writeBoolBinary(writer: *std.Io.Writer, value: bool) !void {
    try writer.writeByte(if (value) 1 else 0);
}

fn writeEnumBinary(writer: *std.Io.Writer, value: anytype) !void {
    const byte = std.math.cast(u8, @backingInt(value)) orelse return error.ManifestTooLarge;
    try writer.writeByte(byte);
}

fn writeCountBinary(writer: *std.Io.Writer, value: usize) !void {
    const count = std.math.cast(u32, value) orelse return error.ManifestTooLarge;
    try writeU32Binary(writer, count);
}

fn writeStringBinary(writer: *std.Io.Writer, value: []const u8) !void {
    try writeCountBinary(writer, value.len);
    try writer.writeAll(value);
}

fn writeU16Binary(writer: *std.Io.Writer, value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn writeU32Binary(writer: *std.Io.Writer, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn writeU64Binary(writer: *std.Io.Writer, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try writer.writeAll(&bytes);
}
