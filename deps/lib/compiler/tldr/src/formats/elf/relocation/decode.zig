const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const relocation_counts_mod = @import("count.zig");
const relocation_model = @import("model.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const parallel = root.parallel;
const format = elf.format;
const rela_size = format.rela_size;
const native_endian = format.native_endian;
const parallel_relocation_threshold = format.parallel_relocation_threshold;
const relocations_per_worker = format.relocations_per_worker;
const SectionHeader = format.SectionHeader;
const Rela = format.Rela;
const sectionBytes = format.sectionBytes;
const readU64 = format.readU64;
const writeU64 = format.writeU64;
const RelocationRange = relocation_model.RelocationRange;
const ObjectParseOptions = relocation_model.ObjectParseOptions;
const RelocationCounts = relocation_model.RelocationCounts;
const ParsedRelocations = relocation_model.ParsedRelocations;
const countRelocationsBySection = relocation_counts_mod.countRelocationsBySection;
const relocationSectionSkipped = relocation_counts_mod.relocationSectionSkipped;
const relocationSectionAllNone = relocation_counts_mod.relocationSectionAllNone;

const RelocationDecodeJob = struct {
    rela_bytes: []const u8,
    rela_count: usize,
    output_base: usize,
    flat_start: usize,
};

const ParallelDecodeContext = struct {
    jobs: []const RelocationDecodeJob,
    relocations: []Rela,
};

fn decodeRelocationRange(job: RelocationDecodeJob, relocations: []Rela, lo: usize, hi: usize) void {
    if (native_endian == .little) {
        const out = relocations[job.output_base + lo ..][0 .. hi - lo];
        const bytes_start = lo * rela_size;
        const bytes_end = hi * rela_size;
        @memcpy(std.mem.sliceAsBytes(out), job.rela_bytes[bytes_start..bytes_end]);
        return;
    }

    var index = lo;
    while (index < hi) : (index += 1) {
        const raw = job.rela_bytes[index * rela_size ..][0..rela_size];
        relocations[job.output_base + index] = .{
            .offset = readU64(raw, 0),
            .info = readU64(raw, 8),
            .addend = @bitCast(readU64(raw, 16)),
        };
    }
}

fn decodeRelocationChunk(context: *ParallelDecodeContext, worker: usize, start: usize, end: usize) void {
    _ = worker;
    for (context.jobs) |job| {
        const job_end = job.flat_start + job.rela_count;
        if (job_end <= start) continue;
        if (job.flat_start >= end) break;
        const lo = if (start > job.flat_start) start - job.flat_start else 0;
        const hi = if (end < job_end) end - job.flat_start else job.rela_count;
        decodeRelocationRange(job, context.relocations, lo, hi);
    }
}

pub fn parseRelocationsBySection(
    allocator: Allocator,
    bytes: []const u8,
    sections: []const SectionHeader,
    section_names: []const u8,
    relocation_counts: RelocationCounts,
    parse_options: ObjectParseOptions,
) model.Error!ParsedRelocations {
    if (relocation_counts.counts.len == 0) {
        return .{
            .relocations = &.{},
            .owned = false,
            .ranges = &.{},
        };
    }

    const relocation_ranges = try allocator.alloc(RelocationRange, sections.len);
    errdefer allocator.free(relocation_ranges);
    var relocation_count: usize = 0;
    for (relocation_ranges, 0..) |*range, section_index| {
        const count = relocation_counts.counts[section_index];
        range.* = .{
            .start = relocation_count,
            .count = count,
        };
        if (count > std.math.maxInt(usize) - relocation_count) return error.InvalidObject;
        relocation_count += count;
    }
    if (relocation_count == 0) {
        return .{
            .relocations = &.{},
            .owned = false,
            .ranges = relocation_ranges,
        };
    }

    if (try borrowSingleRelocationSection(bytes, sections, section_names, relocation_count, parse_options)) |relocations| {
        return .{
            .relocations = relocations,
            .owned = false,
            .ranges = relocation_ranges,
        };
    }

    const relocations = try allocator.alloc(Rela, relocation_count);
    errdefer allocator.free(relocations);

    var jobs = std.ArrayListUnmanaged(RelocationDecodeJob).empty;
    defer jobs.deinit(allocator);
    var write_offsets: []usize = &.{};
    defer if (write_offsets.len != 0) allocator.free(write_offsets);
    if (relocation_counts.duplicate_targets) {
        write_offsets = try allocator.alloc(usize, sections.len);
        for (write_offsets, 0..) |*offset, section_index| {
            offset.* = relocation_ranges[section_index].start;
        }
    }

    var flat_total: usize = 0;
    for (sections) |section| {
        if (section.section_type != std.elf.SHT_RELA) continue;
        if (try relocationSectionSkipped(section, sections, section_names, parse_options)) continue;
        const rela_bytes = try sectionBytes(bytes, section);
        if (relocationSectionAllNone(rela_bytes)) continue;
        const rela_count = rela_bytes.len / rela_size;
        const output_base = if (relocation_counts.duplicate_targets) blk: {
            const base = write_offsets[section.info];
            write_offsets[section.info] += rela_count;
            break :blk base;
        } else relocation_ranges[section.info].start;
        try jobs.append(allocator, .{
            .rela_bytes = rela_bytes,
            .rela_count = rela_count,
            .output_base = output_base,
            .flat_start = flat_total,
        });
        flat_total += rela_count;
    }

    const workers = if (flat_total >= parallel_relocation_threshold)
        parallel.chooseWorkers(
            flat_total,
            parallel.grainWorkers(parse_options.worker_budget, flat_total, relocations_per_worker),
        )
    else
        1;

    if (workers <= 1) {
        for (jobs.items) |job| decodeRelocationRange(job, relocations, 0, job.rela_count);
    } else {
        var context = ParallelDecodeContext{ .jobs = jobs.items, .relocations = relocations };
        parallel.forChunks(flat_total, workers, &context, decodeRelocationChunk);
    }

    return .{
        .relocations = relocations,
        .owned = true,
        .ranges = relocation_ranges,
    };
}

fn borrowSingleRelocationSection(
    bytes: []const u8,
    sections: []const SectionHeader,
    section_names: []const u8,
    relocation_count: usize,
    parse_options: ObjectParseOptions,
) model.Error!?[]const Rela {
    if (native_endian != .little) return null;

    var found: ?SectionHeader = null;
    for (sections) |section| {
        if (section.section_type != std.elf.SHT_RELA) continue;
        if (try relocationSectionSkipped(section, sections, section_names, parse_options)) continue;
        if (section.size == 0) continue;
        const rela_bytes = try sectionBytes(bytes, section);
        if (relocationSectionAllNone(rela_bytes)) continue;
        if (found != null) return null;
        found = section;
    }
    const section = found orelse return null;
    if (section.size / rela_size != relocation_count) return null;

    const rela_bytes = try sectionBytes(bytes, section);
    if (!std.mem.isAligned(@intFromPtr(rela_bytes.ptr), @alignOf(Rela))) return null;
    return @alignCast(std.mem.bytesAsSlice(Rela, rela_bytes));
}
