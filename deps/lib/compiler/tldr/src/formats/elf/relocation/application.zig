const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const checked = @import("value.zig");
const kind = @import("kind.zig");
const relax = @import("relax.zig");
const relocation_target = @import("target.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const parallel = root.parallel;
const diagnostic = elf.diagnostic;
const elf_object = elf.object;
const format = elf.format;
const layout = elf.layout;
const program = elf.program;
const parser = elf.parser;
const output_section = elf.output_section;
const section_state = elf.section_state;
const got_table = elf.got_table;
const parallel_relocation_threshold = format.parallel_relocation_threshold;
const relocations_per_worker = format.relocations_per_worker;
const OutputSectionKind = output_section.OutputSectionKind;
const OutputSection = layout.OutputSection;
const ObjectLayout = layout.ObjectLayout;
const contributionAt = layout.contributionAt;
const ehFrameSectionLayout = layout.ehFrameSection;
const GlobalSymbol = layout.GlobalSymbol;
const GotLayout = layout.GotLayout;
const ObjectFile = parser.ObjectFile;
const Rela = format.Rela;
const writeU16 = format.writeU16;
const writeU32 = format.writeU32;
const writeU64 = format.writeU64;
const sectionDiscarded = section_state.sectionDiscarded;
const foldedSection = section_state.foldedSection;
const canonicalGotSymbolRef = got_table.canonicalSymbolRef;
const tlsMemorySize = program.tlsMemorySize;
const SymbolAddressCache = elf.addressing.Cache;
const SymbolCacheAccess = elf.addressing.Access;
const relocationTargetAddress = elf.addressing.relocationTarget;
const symbolIsUnresolvedWeak = elf.addressing.symbolIsUnresolvedWeak;

const absolute64_run_relocation_limit = 4096;
const absolute64_run_relocations_per_worker = relocations_per_worker * 8;
const debug_absolute_run_min_relocations = 4;

const RelocationJob = struct {
    object_index: usize,
    contribution_size: u64,
    base_address: u64,
    base_file_offset: u64,
    relocations: []const Rela,
    absolute64_run: bool,
    ignore_missing_targets: bool,
    global_offset: usize,
    section_index: usize,
    deferred: bool = false,
};

const JobRange = struct {
    start: usize = 0,
    end: usize = 0,
};

const JobList = struct {
    jobs: std.ArrayListUnmanaged(RelocationJob) = .empty,
    object_ranges: []JobRange = &.{},
    total_relocations: usize = 0,
    deferred_jobs: usize = 0,

    fn deinit(self: *JobList, scratch: Allocator) void {
        if (self.object_ranges.len != 0) scratch.free(self.object_ranges);
        self.jobs.deinit(scratch);
    }
};

fn buildJobs(
    scratch: Allocator,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    options: model.LinkOptions,
    with_object_ranges: bool,
) model.Error!JobList {
    var list = JobList{};
    errdefer list.deinit(scratch);
    if (with_object_ranges) {
        list.object_ranges = try scratch.alloc(JobRange, objects.len);
        @memset(list.object_ranges, .{});
    }
    for (objects, 0..) |object, object_index| {
        const object_job_start = list.jobs.items.len;
        const object_relocation_start = list.total_relocations;
        if (with_object_ranges) list.object_ranges[object_index].start = object_job_start;
        defer if (with_object_ranges) {
            list.object_ranges[object_index].end = list.jobs.items.len;
            if (list.total_relocations - object_relocation_start > relocations_per_worker) {
                for (list.jobs.items[object_job_start..]) |*job| {
                    if (!job.deferred) {
                        job.deferred = true;
                        list.deferred_jobs += 1;
                    }
                }
            }
        };
        if (object.relocations.len == 0) continue;
        for (object.sections, 0..) |_, section_index| {
            const relocations = if (ehFrameSectionLayout(layouts[object_index], section_index)) |eh_frame_section|
                eh_frame_section.relocations
            else
                object.relocationsForSection(section_index);
            if (relocations.len == 0) continue;
            if (sectionDiscarded(object, section_index)) continue;
            if (foldedSection(object, section_index) != null) continue;

            const target_contribution = contributionAt(layouts[object_index].sections, section_index) orelse continue;
            const target_output = output_sections[target_contribution.outputIndex()];
            if (target_output.kind.isNoBits()) {
                const first_effective = firstEffectiveRelocation(relocations) orelse continue;
                diagnostic.recordUnsupportedRelocation(options, object, section_index, first_effective);
                return error.UnsupportedRelocation;
            }

            const absolute64_run = relocations.len <= absolute64_run_relocation_limit and relocationsAreAbsolute64Run(relocations);
            const deferred = relocations.len > relocations_per_worker;
            if (deferred) list.deferred_jobs += 1;
            try list.jobs.append(scratch, .{
                .object_index = object_index,
                .contribution_size = target_contribution.size,
                .base_address = target_output.address + target_contribution.offset,
                .base_file_offset = target_output.file_offset + target_contribution.offset,
                .relocations = relocations,
                .absolute64_run = absolute64_run,
                .ignore_missing_targets = !target_output.kind.isAllocated(),
                .global_offset = list.total_relocations,
                .section_index = section_index,
                .deferred = deferred,
            });
            list.total_relocations += relocations.len;
        }
    }
    return list;
}

const RelocationTask = struct {
    job_index: usize,
    start: usize,
    end: usize,
    global_offset: usize,
};

const RelocationFailure = struct {
    found: bool = false,
    global_index: usize = 0,
    err: model.Error = error.UnsupportedRelocation,
    object_index: usize = 0,
    section_index: usize = 0,
    relocation: Rela = undefined,
};

const RelocationFailures = parallel.FailureSlots(RelocationFailure);

const ParallelRelocationContext = struct {
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    got_layout: GotLayout,
    image: []u8,
    jobs: []const RelocationJob,
    tasks: []const RelocationTask,
    failures: *RelocationFailures,
    target_caches: []*relocation_target.Cache,
};

const RelocationPlace = struct {
    address: u64,
    offset: u64,
};

fn checkedRelocationPlace(
    contribution_size: u64,
    base_address: u64,
    base_file_offset: u64,
    relocation: Rela,
    write_size: u64,
) model.Error!RelocationPlace {
    if (relocation.offset > contribution_size or
        write_size > contribution_size - relocation.offset) return error.InvalidRange;
    return .{
        .address = base_address + relocation.offset,
        .offset = base_file_offset + relocation.offset,
    };
}

fn applyOneRelocation(
    comptime cache_access: SymbolCacheAccess,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    got_layout: GotLayout,
    image: []u8,
    object_index: usize,
    contribution_size: u64,
    base_address: u64,
    base_file_offset: u64,
    relocation: Rela,
    ignore_missing_target: bool,
    target_cache: *relocation_target.Cache,
) model.Error!void {
    const object = objects[object_index];
    const relocation_type = relocation.relocationType();
    const symbol_index: usize = @intCast(relocation.symbolIndex());
    if (symbol_index >= object.symbols.len) return error.UndefinedSymbol;

    switch (relocation_type) {
        @backingInt(std.elf.R_X86_64.@"64"),
        @backingInt(std.elf.R_X86_64.@"32"),
        @backingInt(std.elf.R_X86_64.@"32S"),
        @backingInt(std.elf.R_X86_64.@"16"),
        @backingInt(std.elf.R_X86_64.@"8"),
        => {
            const write_size: u64 = switch (relocation_type) {
                @backingInt(std.elf.R_X86_64.@"64") => 8,
                @backingInt(std.elf.R_X86_64.@"32"),
                @backingInt(std.elf.R_X86_64.@"32S"),
                => 4,
                @backingInt(std.elf.R_X86_64.@"16") => 2,
                @backingInt(std.elf.R_X86_64.@"8") => 1,
                else => unreachable,
            };
            const place = try checkedRelocationPlace(contribution_size, base_address, base_file_offset, relocation, write_size);
            const target = (try relocation_target.cachedOrSkip(cache_access, objects, layouts, output_sections, globals, symbol_addresses, object_index, symbol_index, relocation, false, false, ignore_missing_target, target_cache)) orelse return;
            const value = target.address + target.addend;
            switch (relocation_type) {
                @backingInt(std.elf.R_X86_64.@"64") => writeU64(image, @intCast(place.offset), try checked.checkedX8664U64(value)),
                @backingInt(std.elf.R_X86_64.@"32") => writeU32(image, @intCast(place.offset), try checked.checkedU32(value)),
                @backingInt(std.elf.R_X86_64.@"32S") => writeU32(image, @intCast(place.offset), @bitCast(try checked.checkedI32(value))),
                @backingInt(std.elf.R_X86_64.@"16") => writeU16(image, @intCast(place.offset), try checked.checkedX8664U16(value)),
                @backingInt(std.elf.R_X86_64.@"8") => image[@intCast(place.offset)] = try checked.checkedX8664U8(value),
                else => unreachable,
            }
        },
        @backingInt(std.elf.R_X86_64.PC16),
        @backingInt(std.elf.R_X86_64.PC8),
        @backingInt(std.elf.R_X86_64.PC32),
        @backingInt(std.elf.R_X86_64.PLT32),
        @backingInt(std.elf.R_X86_64.PC64),
        => {
            const write_size: u64 = switch (relocation_type) {
                @backingInt(std.elf.R_X86_64.PC64) => 8,
                @backingInt(std.elf.R_X86_64.PC16) => 2,
                @backingInt(std.elf.R_X86_64.PC8) => 1,
                else => 4,
            };
            const place = try checkedRelocationPlace(contribution_size, base_address, base_file_offset, relocation, write_size);
            const target = (try relocation_target.cachedOrSkip(cache_access, objects, layouts, output_sections, globals, symbol_addresses, object_index, symbol_index, relocation, false, false, ignore_missing_target, target_cache)) orelse return;
            const value = target.address + target.addend - @as(i128, @intCast(place.address));
            switch (relocation_type) {
                @backingInt(std.elf.R_X86_64.PC64) => writeU64(image, @intCast(place.offset), @bitCast(try checked.checkedI64(value))),
                @backingInt(std.elf.R_X86_64.PC32),
                @backingInt(std.elf.R_X86_64.PLT32),
                => writeU32(image, @intCast(place.offset), @bitCast(try checked.checkedI32(value))),
                @backingInt(std.elf.R_X86_64.PC16) => writeU16(image, @intCast(place.offset), @bitCast(try checked.checkedI16(value))),
                @backingInt(std.elf.R_X86_64.PC8) => image[@intCast(place.offset)] = @bitCast(try checked.checkedI8(value)),
                else => unreachable,
            }
        },
        @backingInt(std.elf.R_X86_64.GOTPCREL),
        @backingInt(std.elf.R_X86_64.GOTPCRELX),
        @backingInt(std.elf.R_X86_64.REX_GOTPCRELX),
        => {
            const place = try checkedRelocationPlace(contribution_size, base_address, base_file_offset, relocation, 4);
            if (relocation_type == @backingInt(std.elf.R_X86_64.GOTPCREL) and symbolIsUnresolvedWeak(object, symbol_index, globals)) {
                if (relax.gotpcrelWeakUndefinedNullCheck(image, @intCast(place.offset))) return;
            }
            if (relocation_type == @backingInt(std.elf.R_X86_64.GOTPCREL)) {
                if (relax.gotpcrelxInstruction(image, @intCast(place.offset), relocation_type)) |relaxation| {
                    const target = (try relocation_target.cachedOrSkip(cache_access, objects, layouts, output_sections, globals, symbol_addresses, object_index, symbol_index, relocation, false, false, ignore_missing_target, target_cache)) orelse return;
                    const value = switch (relaxation) {
                        .pc_relative => target.address + target.addend - @as(i128, @intCast(place.address)),
                        .absolute_signed_32 => target.address + target.addend + 4,
                    };
                    writeU32(image, @intCast(place.offset), @bitCast(try checked.checkedI32(value)));
                    return;
                }
                const ref = try canonicalGotSymbolRef(objects, globals, object_index, symbol_index);
                const got_offset = got_layout.entryOffset(ref) orelse return error.MissingSection;
                const got = output_sections[@backingInt(OutputSectionKind.got)];
                const value = @as(i128, @intCast(got.address + got_offset)) + relocation.addend - @as(i128, @intCast(place.address));
                writeU32(image, @intCast(place.offset), @bitCast(try checked.checkedI32(value)));
                return;
            }
            const target = (try relocation_target.cachedOrSkip(cache_access, objects, layouts, output_sections, globals, symbol_addresses, object_index, symbol_index, relocation, false, false, ignore_missing_target, target_cache)) orelse return;
            const relaxation = relax.gotpcrelxInstruction(image, @intCast(place.offset), relocation_type) orelse return error.UnsupportedRelocation;
            const value = switch (relaxation) {
                .pc_relative => target.address + target.addend - @as(i128, @intCast(place.address)),
                .absolute_signed_32 => target.address + target.addend + 4,
            };
            writeU32(image, @intCast(place.offset), @bitCast(try checked.checkedI32(value)));
        },
        @backingInt(std.elf.R_X86_64.SIZE32),
        @backingInt(std.elf.R_X86_64.SIZE64),
        => {
            const write_size: u64 = if (relocation_type == @backingInt(std.elf.R_X86_64.SIZE64)) 8 else 4;
            const place = try checkedRelocationPlace(contribution_size, base_address, base_file_offset, relocation, write_size);
            const target = (try relocation_target.cachedOrSkip(cache_access, objects, layouts, output_sections, globals, symbol_addresses, object_index, symbol_index, relocation, true, false, ignore_missing_target, target_cache)) orelse return;
            const value = @as(i128, @intCast(target.size)) + target.addend;
            switch (relocation_type) {
                @backingInt(std.elf.R_X86_64.SIZE32) => writeU32(image, @intCast(place.offset), try checked.checkedU32(value)),
                @backingInt(std.elf.R_X86_64.SIZE64) => writeU64(image, @intCast(place.offset), try checked.checkedU64(value)),
                else => unreachable,
            }
        },
        @backingInt(std.elf.R_X86_64.TPOFF32),
        @backingInt(std.elf.R_X86_64.TPOFF64),
        @backingInt(std.elf.R_X86_64.DTPOFF32),
        @backingInt(std.elf.R_X86_64.DTPOFF64),
        => {
            const write_size: u64 = switch (relocation_type) {
                @backingInt(std.elf.R_X86_64.TPOFF64),
                @backingInt(std.elf.R_X86_64.DTPOFF64),
                => 8,
                else => 4,
            };
            const place = try checkedRelocationPlace(contribution_size, base_address, base_file_offset, relocation, write_size);
            const target = (try relocation_target.cachedOrSkip(cache_access, objects, layouts, output_sections, globals, symbol_addresses, object_index, symbol_index, relocation, false, true, ignore_missing_target, target_cache)) orelse return;
            const tls_size: i128 = @intCast(tlsMemorySize(output_sections));
            const value = target.address + target.addend - tls_size;
            switch (relocation_type) {
                @backingInt(std.elf.R_X86_64.TPOFF32),
                @backingInt(std.elf.R_X86_64.DTPOFF32),
                => writeU32(image, @intCast(place.offset), @bitCast(try checked.checkedI32(value))),
                @backingInt(std.elf.R_X86_64.TPOFF64),
                @backingInt(std.elf.R_X86_64.DTPOFF64),
                => writeU64(image, @intCast(place.offset), @bitCast(try checked.checkedI64(value))),
                else => unreachable,
            }
        },
        @backingInt(std.elf.R_X86_64.GOTTPOFF) => {
            const place = try checkedRelocationPlace(contribution_size, base_address, base_file_offset, relocation, 4);
            const target = (try relocation_target.cachedOrSkip(cache_access, objects, layouts, output_sections, globals, symbol_addresses, object_index, symbol_index, relocation, false, true, ignore_missing_target, target_cache)) orelse return;
            const tls_size: i128 = @intCast(tlsMemorySize(output_sections));
            try relax.gottpoffToLocalExec(image, @intCast(place.offset), target.address - tls_size);
        },
        @backingInt(std.elf.R_X86_64.TLSGD) => {
            _ = try checkedRelocationPlace(contribution_size, base_address, base_file_offset, relocation, 4);
            const target = (try relocation_target.cachedOrSkip(cache_access, objects, layouts, output_sections, globals, symbol_addresses, object_index, symbol_index, relocation, false, true, ignore_missing_target, target_cache)) orelse return;
            const tls_size: i128 = @intCast(tlsMemorySize(output_sections));
            try relax.tlsGdToLocalExec(image, contribution_size, base_file_offset, relocation, target.address + target.addend - tls_size + 4);
        },
        @backingInt(std.elf.R_X86_64.TLSLD) => {
            _ = try checkedRelocationPlace(contribution_size, base_address, base_file_offset, relocation, 4);
            try relax.tlsLdToLocalExec(image, contribution_size, base_file_offset, relocation);
        },
        else => {
            std.debug.assert(!kind.applicationSupported(relocation_type));
            return error.UnsupportedRelocation;
        },
    }
}

fn recordRelocationDiagnostic(options: model.LinkOptions, object: ObjectFile, section_index: usize, err: model.Error, relocation: Rela) void {
    if (err == error.UnsupportedRelocation) diagnostic.recordUnsupportedRelocation(options, object, section_index, relocation);
}

fn relocationsAreAbsolute64Run(relocations: []const Rela) bool {
    if (relocations.len < 2) return false;
    const first = relocations[0];
    if (first.relocationType() != @backingInt(std.elf.R_X86_64.@"64")) return false;
    const symbol_index = first.symbolIndex();
    const addend = first.addend;
    for (relocations[1..]) |relocation| {
        if (relocation.relocationType() != @backingInt(std.elf.R_X86_64.@"64")) return false;
        if (relocation.symbolIndex() != symbol_index) return false;
        if (relocation.addend != addend) return false;
    }
    return true;
}

fn applyAbsolute64RelocationRun(
    comptime cache_access: SymbolCacheAccess,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    image: []u8,
    object_index: usize,
    contribution_size: u64,
    base_file_offset: u64,
    relocations: []const Rela,
    ignore_missing_targets: bool,
    target_cache: *relocation_target.Cache,
) model.Error!void {
    const first = relocations[0];
    const symbol_index: usize = @intCast(first.symbolIndex());
    if (symbol_index >= objects[object_index].symbols.len) return error.UndefinedSymbol;
    const target = target_cache.get(object_index, symbol_index, first.addend, false, false) orelse blk: {
        const resolved = relocationTargetAddress(
            cache_access,
            objects,
            layouts,
            output_sections,
            globals,
            symbol_addresses,
            object_index,
            symbol_index,
            first,
            false,
        ) catch |err| switch (err) {
            error.MissingSection => if (ignore_missing_targets) return else return err,
            else => return err,
        };
        target_cache.put(object_index, symbol_index, first.addend, false, false, resolved);
        break :blk resolved;
    };
    const resolved_value = try checked.checkedX8664U64(target.address + target.addend);
    for (relocations) |relocation| {
        if (relocation.offset > contribution_size or 8 > contribution_size - relocation.offset) return error.InvalidRange;
        const place_offset = base_file_offset + relocation.offset;
        writeU64(image, @intCast(place_offset), resolved_value);
    }
}

fn relocationTypeIsDebugAbsoluteRunCandidate(relocation_type: u32) bool {
    return switch (relocation_type) {
        @backingInt(std.elf.R_X86_64.@"64"),
        @backingInt(std.elf.R_X86_64.@"32"),
        => true,
        else => false,
    };
}

fn debugAbsoluteRunTargetDependsOnAddend(
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    object_index: usize,
    symbol_index: usize,
) model.Error!bool {
    const object = objects[object_index];
    if (symbol_index >= object.symbols.len) return error.UndefinedSymbol;
    const symbol_record = object.symbols[symbol_index];
    if (!symbol_record.isSection()) return false;
    if (symbol_record.section_index >= object.sections.len) return false;
    return layout.mergeSection(layouts[object_index], symbol_record.section_index) != null;
}

fn applyDebugAbsoluteRelocationRun(
    comptime cache_access: SymbolCacheAccess,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    image: []u8,
    object_index: usize,
    contribution_size: u64,
    base_address: u64,
    base_file_offset: u64,
    relocations: []const Rela,
    start: usize,
    end: usize,
    failed_local: *usize,
    target_cache: *relocation_target.Cache,
) model.Error!?usize {
    const first = relocations[start];
    const relocation_type = first.relocationType();
    if (!relocationTypeIsDebugAbsoluteRunCandidate(relocation_type)) return null;

    const symbol_index: usize = @intCast(first.symbolIndex());
    if (try debugAbsoluteRunTargetDependsOnAddend(objects, layouts, object_index, symbol_index)) return null;

    var run_end = start + 1;
    while (run_end < end) : (run_end += 1) {
        const relocation = relocations[run_end];
        if (relocation.relocationType() != relocation_type) break;
        if (relocation.symbolIndex() != first.symbolIndex()) break;
    }
    if (run_end - start < debug_absolute_run_min_relocations) return null;

    const write_size: u64 = if (relocation_type == @backingInt(std.elf.R_X86_64.@"64")) 8 else 4;
    failed_local.* = start;
    _ = try checkedRelocationPlace(contribution_size, base_address, base_file_offset, first, write_size);

    var base_relocation = first;
    base_relocation.addend = 0;
    const target = (try relocation_target.cachedOrSkip(cache_access, objects, layouts, output_sections, globals, symbol_addresses, object_index, symbol_index, base_relocation, false, false, true, target_cache)) orelse return run_end;
    const base_value = target.address + target.addend;

    var index = start;
    while (index < run_end) : (index += 1) {
        failed_local.* = index;
        const relocation = relocations[index];
        const place = try checkedRelocationPlace(contribution_size, base_address, base_file_offset, relocation, write_size);
        const value = base_value + relocation.addend;
        switch (relocation_type) {
            @backingInt(std.elf.R_X86_64.@"64") => writeU64(image, @intCast(place.offset), try checked.checkedX8664U64(value)),
            @backingInt(std.elf.R_X86_64.@"32") => writeU32(image, @intCast(place.offset), try checked.checkedU32(value)),
            else => unreachable,
        }
    }
    return run_end;
}

fn applySerialRelocationJob(
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    got_layout: GotLayout,
    image: []u8,
    options: model.LinkOptions,
    job: RelocationJob,
    target_cache: *relocation_target.Cache,
) model.Error!void {
    const object = objects[job.object_index];
    for (job.relocations, 0..) |relocation, relocation_index| {
        if (kind.isNone(relocation)) continue;
        if (kind.isRelaxedTlsRuntimeResolver(object, job.relocations, relocation_index)) continue;
        applyOneRelocation(
            .serial,
            objects,
            layouts,
            output_sections,
            globals,
            symbol_addresses,
            got_layout,
            image,
            job.object_index,
            job.contribution_size,
            job.base_address,
            job.base_file_offset,
            relocation,
            job.ignore_missing_targets,
            target_cache,
        ) catch |err| {
            recordRelocationDiagnostic(options, objects[job.object_index], job.section_index, err, relocation);
            return err;
        };
    }
}

fn relocationFailureFound(failure: RelocationFailure) bool {
    return failure.found;
}

fn relocationFailureBefore(lhs: RelocationFailure, rhs: RelocationFailure) bool {
    return lhs.global_index < rhs.global_index;
}

fn recordParallelRelocationFailure(
    context: *ParallelRelocationContext,
    worker: usize,
    global_index: usize,
    err: model.Error,
    job: RelocationJob,
    relocation: Rela,
) void {
    if (context.failures.items[worker].found) return;
    context.failures.record(worker, .{
        .found = true,
        .global_index = global_index,
        .err = err,
        .object_index = job.object_index,
        .section_index = job.section_index,
        .relocation = relocation,
    });
}

fn applyJobRange(
    context: *ParallelRelocationContext,
    worker: usize,
    job_index: usize,
    start: usize,
    end: usize,
    global_offset: usize,
) void {
    const job = context.jobs[job_index];
    const target_cache = context.target_caches[worker];

    if (job.absolute64_run) {
        const relocation = job.relocations[start];
        applyAbsolute64RelocationRun(
            .concurrent,
            context.objects,
            context.layouts,
            context.output_sections,
            context.globals,
            context.symbol_addresses,
            context.image,
            job.object_index,
            job.contribution_size,
            job.base_file_offset,
            job.relocations[start..end],
            job.ignore_missing_targets,
            target_cache,
        ) catch |err| {
            recordParallelRelocationFailure(context, worker, global_offset, err, job, relocation);
            return;
        };
        return;
    }

    var local = start;
    while (local < end) {
        const relocation = job.relocations[local];
        if (kind.isNone(relocation)) {
            local += 1;
            continue;
        }
        if (kind.isRelaxedTlsRuntimeResolver(context.objects[job.object_index], job.relocations, local)) {
            local += 1;
            continue;
        }
        if (job.ignore_missing_targets and end - local >= debug_absolute_run_min_relocations) {
            var failed_local = local;
            const next = applyDebugAbsoluteRelocationRun(
                .concurrent,
                context.objects,
                context.layouts,
                context.output_sections,
                context.globals,
                context.symbol_addresses,
                context.image,
                job.object_index,
                job.contribution_size,
                job.base_address,
                job.base_file_offset,
                job.relocations,
                local,
                end,
                &failed_local,
                target_cache,
            ) catch |err| {
                recordParallelRelocationFailure(context, worker, global_offset + failed_local - start, err, job, job.relocations[failed_local]);
                return;
            };
            if (next) |next_local| {
                local = next_local;
                continue;
            }
        }
        applyOneRelocation(
            .concurrent,
            context.objects,
            context.layouts,
            context.output_sections,
            context.globals,
            context.symbol_addresses,
            context.got_layout,
            context.image,
            job.object_index,
            job.contribution_size,
            job.base_address,
            job.base_file_offset,
            relocation,
            job.ignore_missing_targets,
            target_cache,
        ) catch |err| {
            recordParallelRelocationFailure(context, worker, global_offset + local - start, err, job, relocation);
            return;
        };
        local += 1;
    }
}

fn applyRelocationTask(context: *ParallelRelocationContext, worker: usize, task_index: usize) void {
    if (context.failures.items[worker].found) return;
    const task = context.tasks[task_index];
    applyJobRange(context, worker, task.job_index, task.start, task.end, task.global_offset);
}

fn applySerialJobs(
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    got_layout: GotLayout,
    image: []u8,
    options: model.LinkOptions,
    jobs: []const RelocationJob,
) model.Error!void {
    var target_cache = relocation_target.Cache{};
    for (jobs) |job| {
        if (job.relocations.len == 0) continue;
        if (job.absolute64_run) {
            const relocation = job.relocations[0];
            applyAbsolute64RelocationRun(
                .serial,
                objects,
                layouts,
                output_sections,
                globals,
                symbol_addresses,
                image,
                job.object_index,
                job.contribution_size,
                job.base_file_offset,
                job.relocations,
                job.ignore_missing_targets,
                &target_cache,
            ) catch |err| {
                recordRelocationDiagnostic(options, objects[job.object_index], job.section_index, err, relocation);
                return err;
            };
            continue;
        }
        try applySerialRelocationJob(
            objects,
            layouts,
            output_sections,
            globals,
            symbol_addresses,
            got_layout,
            image,
            options,
            job,
            &target_cache,
        );
    }
}

pub fn apply(
    scratch: Allocator,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    got_layout: GotLayout,
    image: []u8,
    options: model.LinkOptions,
) model.Error!void {
    var list = try buildJobs(scratch, objects, layouts, output_sections, options, false);
    defer list.deinit(scratch);
    if (list.total_relocations == 0) return;

    const workers = relocationWorkers(list, options);
    if (workers <= 1) {
        return applySerialJobs(objects, layouts, output_sections, globals, symbol_addresses, got_layout, image, options, list.jobs.items);
    }
    return applyJobsParallel(scratch, objects, layouts, output_sections, globals, symbol_addresses, got_layout, image, options, list.jobs.items, workers, false);
}

fn relocationWorkers(list: JobList, options: model.LinkOptions) usize {
    var absolute64_relocations: usize = 0;
    for (list.jobs.items) |job| {
        if (job.absolute64_run) absolute64_relocations += job.relocations.len;
    }
    const all_absolute64 = absolute64_relocations == list.total_relocations;
    const grain: usize = if (all_absolute64)
        absolute64_run_relocations_per_worker
    else
        relocations_per_worker;
    const wanted = parallel.grainWorkers(options.max_link_jobs, list.total_relocations, grain);
    return if (list.total_relocations >= parallel_relocation_threshold)
        parallel.chooseWorkers(list.total_relocations, wanted)
    else
        1;
}

fn applyJobsParallel(
    scratch: Allocator,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    got_layout: GotLayout,
    image: []u8,
    options: model.LinkOptions,
    jobs: []const RelocationJob,
    workers: usize,
    deferred_only: bool,
) model.Error!void {
    var tasks = std.ArrayListUnmanaged(RelocationTask).empty;
    defer tasks.deinit(scratch);
    for (jobs, 0..) |job, job_index| {
        if (deferred_only and !job.deferred) continue;
        if (job.relocations.len == 0) continue;
        const grain: usize = if (job.absolute64_run) absolute64_run_relocations_per_worker else relocations_per_worker;
        var start: usize = 0;
        while (start < job.relocations.len) {
            const end = @min(start + grain, job.relocations.len);
            try tasks.append(scratch, .{
                .job_index = job_index,
                .start = start,
                .end = end,
                .global_offset = job.global_offset + start,
            });
            start = end;
        }
    }
    if (tasks.items.len == 0) return;

    var failures = try RelocationFailures.init(scratch, workers, .{});
    defer failures.deinit(scratch);

    var worker_arenas = try parallel.WorkerArenaPool.init(scratch, workers);
    defer worker_arenas.deinit();

    const target_caches = try scratch.alloc(*relocation_target.Cache, workers);
    defer scratch.free(target_caches);
    for (target_caches, 0..) |*target_cache, worker| {
        target_cache.* = try worker_arenas.allocator(worker).create(relocation_target.Cache);
        target_cache.*.* = .{};
    }

    var context = ParallelRelocationContext{
        .objects = objects,
        .layouts = layouts,
        .output_sections = output_sections,
        .globals = globals,
        .symbol_addresses = symbol_addresses,
        .got_layout = got_layout,
        .image = image,
        .jobs = jobs,
        .tasks = tasks.items,
        .failures = &failures,
        .target_caches = target_caches,
    };
    parallel.forItems(tasks.items.len, workers, &context, applyRelocationTask);

    if (failures.earliest(relocationFailureFound, relocationFailureBefore)) |failure| {
        recordRelocationDiagnostic(options, objects[failure.object_index], failure.section_index, failure.err, failure.relocation);
        return failure.err;
    }
}

const CopyFailure = struct {
    found: bool = false,
    object_index: usize = 0,
    err: model.Error = error.InvalidObject,
};

const CopyFailures = parallel.FailureSlots(CopyFailure);

const MaterializeContext = struct {
    relocation: ParallelRelocationContext,
    copy_failures: *CopyFailures,
    worker_budget: usize,
};

const MaterializeObjectContext = struct {
    shared: MaterializeContext,
    object_ranges: []const JobRange,
};

fn materializeObjectTask(context: *MaterializeObjectContext, worker: usize, object_index: usize) void {
    const relocation = &context.shared.relocation;
    elf.payload.copyObjectSections(
        relocation.image,
        relocation.objects[object_index],
        relocation.layouts[object_index],
        relocation.output_sections,
        context.shared.worker_budget,
    ) catch |err| {
        const current = context.shared.copy_failures.items[worker];
        const failure = CopyFailure{
            .found = true,
            .object_index = object_index,
            .err = err,
        };
        if (!current.found or copyFailureBefore(failure, current)) {
            context.shared.copy_failures.record(worker, failure);
        }
        return;
    };
    if (relocation.failures.items[worker].found) return;
    const range = context.object_ranges[object_index];
    var job_index = range.start;
    while (job_index < range.end) : (job_index += 1) {
        const job = relocation.jobs[job_index];
        if (job.deferred) continue;
        applyJobRange(relocation, worker, job_index, 0, job.relocations.len, job.global_offset);
        if (relocation.failures.items[worker].found) return;
    }
}

fn copyFailureFound(failure: CopyFailure) bool {
    return failure.found;
}

fn copyFailureBefore(left: CopyFailure, right: CopyFailure) bool {
    return left.object_index < right.object_index;
}

pub fn materialize(
    scratch: Allocator,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    got_layout: GotLayout,
    image: []u8,
    options: model.LinkOptions,
) model.Error!void {
    if (elf.payload.wantsBatchedObjectCopy(objects)) {
        try elf.payload.copyAllocSections(scratch, image, objects, layouts, output_sections, options);
        return apply(scratch, objects, layouts, output_sections, globals, symbol_addresses, got_layout, image, options);
    }

    var list = try buildJobs(scratch, objects, layouts, output_sections, options, true);
    defer list.deinit(scratch);

    const workers = materializeWorkers(list, output_sections, options);
    if (workers <= 1) {
        try elf.payload.copyAllocSections(scratch, image, objects, layouts, output_sections, options);
        return applySerialJobs(objects, layouts, output_sections, globals, symbol_addresses, got_layout, image, options, list.jobs.items);
    }

    var copy_failures = try CopyFailures.init(scratch, workers, .{});
    defer copy_failures.deinit(scratch);
    var relocation_failures = try RelocationFailures.init(scratch, workers, .{});
    defer relocation_failures.deinit(scratch);

    var worker_arenas = try parallel.WorkerArenaPool.init(scratch, workers);
    defer worker_arenas.deinit();
    const target_caches = try scratch.alloc(*relocation_target.Cache, workers);
    defer scratch.free(target_caches);
    for (target_caches, 0..) |*target_cache, worker| {
        target_cache.* = try worker_arenas.allocator(worker).create(relocation_target.Cache);
        target_cache.*.* = .{};
    }

    var context = MaterializeObjectContext{
        .shared = .{
            .relocation = .{
                .objects = objects,
                .layouts = layouts,
                .output_sections = output_sections,
                .globals = globals,
                .symbol_addresses = symbol_addresses,
                .got_layout = got_layout,
                .image = image,
                .jobs = list.jobs.items,
                .tasks = &.{},
                .failures = &relocation_failures,
                .target_caches = target_caches,
            },
            .copy_failures = &copy_failures,
            .worker_budget = options.max_link_jobs,
        },
        .object_ranges = list.object_ranges,
    };
    parallel.forItems(objects.len, workers, &context, materializeObjectTask);

    if (copy_failures.earliest(copyFailureFound, copyFailureBefore)) |failure| {
        return failure.err;
    }

    if (list.deferred_jobs != 0) {
        try applyJobsParallel(scratch, objects, layouts, output_sections, globals, symbol_addresses, got_layout, image, options, list.jobs.items, workers, true);
    }

    if (relocation_failures.earliest(relocationFailureFound, relocationFailureBefore)) |failure| {
        recordRelocationDiagnostic(options, objects[failure.object_index], failure.section_index, failure.err, failure.relocation);
        return failure.err;
    }
}

fn materializeWorkers(list: JobList, output_sections: []const OutputSection, options: model.LinkOptions) usize {
    var load_bytes: usize = 0;
    for (output_sections) |section| {
        if (section.kind.isNoBits()) continue;
        load_bytes +|= @intCast(section.fileLoadSize());
    }
    const worker_budget = options.max_link_jobs;
    const wanted = @max(
        parallel.grainWorkers(worker_budget, list.total_relocations, relocations_per_worker),
        parallel.grainWorkers(worker_budget, load_bytes, parallel_materialize_bytes_per_worker),
    );
    const busy = list.total_relocations >= parallel_relocation_threshold or
        load_bytes >= parallel_materialize_threshold;
    return if (busy and list.object_ranges.len > 1)
        parallel.chooseWorkers(list.object_ranges.len, wanted)
    else
        1;
}

const parallel_materialize_threshold = 8 * 1024 * 1024;
const parallel_materialize_bytes_per_worker = 4 * 1024 * 1024;

fn firstEffectiveRelocation(relocations: []const Rela) ?Rela {
    for (relocations) |relocation| {
        if (!kind.isNone(relocation)) return relocation;
    }
    return null;
}
