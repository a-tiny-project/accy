const std = @import("std");
const allocators = @import("alloc");
const root = @import("../../root.zig");
const elf = @import("root.zig");
const archive_selection = @import("archive/root.zig");

const Allocator = std.mem.Allocator;
const archive = root.archive;
const incremental = root.incremental;
const model = root.model;
const parallel = root.parallel;
const trace = root.trace;

const addressing = elf.addressing;
const diagnostic = elf.diagnostic;
const ehframe = elf.ehframe;
const format = elf.format;
const got_table = elf.got_table;
const group = elf.group;
const icf = elf.icf;
const image = elf.image;
const layout = elf.layout;
const liveness = elf.liveness;
const note = elf.note;
const output_section = elf.output_section;
const parser = elf.parser;
const program_headers = elf.program;
const relink = elf.relink;
const relocation_namespace = elf.relocation;
const section_state = elf.section_state;
const symbol_table = elf.symbol_table;

const build_id_note = note;
const collectGlobalSymbols = symbol_table.collectGlobalSymbols;
const collectGotEntries = got_table.collectEntries;
const countProgramHeaders = program_headers.countHeaders;
const finishBuildIdNote = build_id_note.finishBuildId;
const output_section_count = output_section.output_section_count;
const reserveBuildIdNote = build_id_note.reserveBuildId;
const sectionIsAllocated = format.sectionIsAllocated;
const ObjectFile = parser.ObjectFile;
const ObjectLayout = layout.ObjectLayout;
const OutputSection = layout.OutputSection;
const SectionContribution = layout.SectionContribution;
const SymbolAddressCache = addressing.Cache;
const SymbolRef = layout.SymbolRef;
const GlobalSymbol = layout.GlobalSymbol;
const boundarySectionNameMatches = addressing.boundarySectionNameMatches;
const contributionAt = layout.contributionAt;
const foldedSection = section_state.foldedSection;
const parseObjectWithOptions = parser.parseObjectWithOptions;
const sectionDiscarded = section_state.sectionDiscarded;
const sectionName = parser.sectionName;
const sectionNameOrEmpty = parser.sectionNameOrEmpty;
const sectionRelocationsAffectOutput = relocation_namespace.sectionRelocationsAffectOutput;
const symbolAddress = addressing.symbolAddress;
const syntheticBoundaryForSymbol = addressing.boundaryForSymbol;

pub fn linkExecutable(
    allocator: Allocator,
    inputs: []const model.Input,
    options: model.LinkOptions,
) model.Error!root.LinkedImage {
    const link_phase = trace.scope("link.elf");
    defer link_phase.end();
    if (options.diagnostics) |diagnostics| diagnostics.clear();
    if (options.requiresDynamicLinking()) return error.UnsupportedDynamicLinking;
    if (options.output_kind != .executable) return error.UnsupportedOutputKind;
    if (options.target.architecture != .x86_64 or options.target.endianness != .little) {
        return error.UnsupportedArchitecture;
    }
    if (inputs.len == 0) return error.NoAllocSections;

    var selection_state = std.heap.ArenaAllocator.init(allocator);
    defer selection_state.deinit();
    var selection_lock = allocators.LockedAllocator.init(selection_state.allocator());
    const selection = selection_lock.allocator();

    var scratch_state = std.heap.ArenaAllocator.init(allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var manifest_builder = build_manifest: {
        const manifest_phase = trace.product(.manifest_recording);
        defer manifest_phase.end();
        var builder = try incremental.Builder.init(allocator, options);
        errdefer builder.deinit();
        for (inputs) |input| try builder.addInput(input);
        break :build_manifest builder;
    };
    errdefer manifest_builder.deinit();

    var objects = std.ArrayListUnmanaged(ObjectFile).empty;
    defer objects.deinit(scratch);
    try objects.ensureTotalCapacity(scratch, inputs.len);

    var archive_state: archive_selection.ExtractionState = .{};
    defer archive_state.deinit(scratch);

    var prefetcher = archive_selection.Prefetcher.init(selection, inputs, options);
    defer prefetcher.deinit();
    prefetcher.advance(0);

    for (inputs, 0..) |input, input_index| {
        if (archive.isArchive(input.bytes)) {
            const archive_phase = trace.product(.archive_member_selection);
            defer archive_phase.end();
            try archive_state.observeNewObjects(scratch, objects.items);
            try archive_selection.addCandidates(scratch, selection, input, input_index, &archive_state, options, &prefetcher);
            prefetcher.advance(input_index + 1);
        } else {
            var object = try parseInputObject(scratch, input, options);
            object.input_index = input_index;
            try objects.append(scratch, object);
        }
        if (archive_state.hasCandidates()) {
            const archive_phase = trace.product(.archive_member_selection);
            defer archive_phase.end();
            try archive_state.observeNewObjects(scratch, objects.items);
            try archive_selection.extractCandidates(
                scratch,
                selection,
                &objects,
                &archive_state,
                options,
            );
        }
    }
    if (manifest_builder.recordsContributions()) {
        const manifest_phase = trace.product(.manifest_recording);
        defer manifest_phase.end();
        try relink.recordInputLinkEvidence(&manifest_builder, scratch, inputs, objects.items, &archive_state);
    }
    var globals: std.StringHashMapUnmanaged(GlobalSymbol) = .{};
    defer globals.deinit(scratch);
    var global_symbol_refs = std.ArrayListUnmanaged(SymbolRef).empty;
    defer global_symbol_refs.deinit(scratch);
    {
        const symbol_phase = trace.product(.symbol_database);
        defer symbol_phase.end();
        {
            const duplicate_phase = trace.product(.duplicate_policy);
            defer duplicate_phase.end();
            try group.discardDuplicates(scratch, objects.items);
        }
        try collectGlobalSymbols(scratch, objects.items, &globals, &global_symbol_refs, options.max_link_jobs);
        if (options.gc_sections) {
            try liveness.discardUnreachable(scratch, objects.items, &globals, options);
        }
        if (options.icf == .all) {
            const duplicate_phase = trace.product(.duplicate_policy);
            defer duplicate_phase.end();
            try icf.fold(scratch, objects.items);
        }
        try requireResolvedRelocationSymbols(scratch, objects.items, &globals, options);
        try requireSupportedRelocations(scratch, objects.items, options);
        try requireEntrySymbol(&globals, options);
    }
    if (options.commit_observer) |observer| observer.notify();

    var output_sections = [output_section_count]OutputSection{
        .{ .kind = .build_id_note, .alignment = 4 },
        .{ .kind = .init, .alignment = 4 },
        .{ .kind = .text, .alignment = 16 },
        .{ .kind = .fini, .alignment = 4 },
        .{ .kind = .iplt, .alignment = 16 },
        .{ .kind = .eh_frame_hdr, .alignment = 4 },
        .{ .kind = .eh_frame, .alignment = 8 },
        .{ .kind = .rodata, .alignment = 1 },
        .{ .kind = .rela_iplt, .alignment = 8 },
        .{ .kind = .preinit_array, .alignment = 8 },
        .{ .kind = .init_array, .alignment = 8 },
        .{ .kind = .fini_array, .alignment = 8 },
        .{ .kind = .data, .alignment = 8 },
        .{ .kind = .got, .alignment = 8 },
        .{ .kind = .igot, .alignment = 8 },
        .{ .kind = .tdata, .alignment = 1 },
        .{ .kind = .tbss, .alignment = 1 },
        .{ .kind = .bss, .alignment = 1 },
        .{ .kind = .debug_abbrev, .alignment = 1 },
        .{ .kind = .debug_addr, .alignment = 1 },
        .{ .kind = .debug_aranges, .alignment = 1 },
        .{ .kind = .debug_cu_index, .alignment = 1 },
        .{ .kind = .debug_frame, .alignment = 1 },
        .{ .kind = .debug_info, .alignment = 1 },
        .{ .kind = .debug_line, .alignment = 1 },
        .{ .kind = .debug_line_str, .alignment = 1 },
        .{ .kind = .debug_loc, .alignment = 1 },
        .{ .kind = .debug_loclists, .alignment = 1 },
        .{ .kind = .debug_macinfo, .alignment = 1 },
        .{ .kind = .debug_macro, .alignment = 1 },
        .{ .kind = .debug_names, .alignment = 1 },
        .{ .kind = .debug_pubnames, .alignment = 1 },
        .{ .kind = .debug_pubtypes, .alignment = 1 },
        .{ .kind = .debug_ranges, .alignment = 1 },
        .{ .kind = .debug_rnglists, .alignment = 1 },
        .{ .kind = .debug_str, .alignment = 1 },
        .{ .kind = .debug_str_offsets, .alignment = 1 },
        .{ .kind = .debug_tu_index, .alignment = 1 },
        .{ .kind = .debug_types, .alignment = 1 },
    };

    var layouts = try scratch.alloc(ObjectLayout, objects.items.len);
    var layout_count: usize = 0;
    var section_contributions: []SectionContribution = &.{};
    defer {
        for (layouts[0..layout_count]) |*object_layout| object_layout.deinit(scratch);
        scratch.free(section_contributions);
        scratch.free(layouts);
    }

    {
        const layout_phase = trace.product(.section_contribution_graph);
        defer layout_phase.end();
        const section_contribution_count = try layout.collect.countObjectSections(objects.items);
        section_contributions = try scratch.alloc(SectionContribution, section_contribution_count);
        try layout.collect.sections(scratch, objects.items, &output_sections, layouts, section_contributions, &layout_count, &globals, options);
        reserveBuildIdNote(&output_sections, options);
        try ehframe.reserveHeader(&output_sections, objects.items, layouts[0..layout_count], options);
    }
    var ifunc_collector: elf.ifunc.Collector = undefined;
    var got_layout: layout.GotLayout = undefined;
    var ifunc_layout: elf.ifunc.IfuncLayout = undefined;
    {
        const layout_phase = trace.product(.layout_groups);
        defer layout_phase.end();
        ifunc_collector = try elf.ifunc.Collector.init(scratch, objects.items, &globals, options.max_link_jobs);
        errdefer ifunc_collector.deinit(scratch);
        const collect_ifunc = ifunc_collector.enabled();
        got_layout = if (collect_ifunc)
            try got_table.collectEntriesWithIfunc(scratch, objects.items, &output_sections, &globals, &ifunc_collector)
        else
            try collectGotEntries(scratch, objects.items, &output_sections, &globals);
        errdefer got_layout.deinit(scratch);
        ifunc_layout = if (collect_ifunc)
            try ifunc_collector.finish(scratch, &output_sections)
        else
            elf.ifunc.IfuncLayout{};
        errdefer ifunc_layout.deinit(scratch);
    }
    defer ifunc_collector.deinit(scratch);
    defer got_layout.deinit(scratch);
    defer ifunc_layout.deinit(scratch);

    const live_output_count = layout.output.countLive(&output_sections);
    if (live_output_count == 0) return error.NoAllocSections;
    const program_header_count = try countProgramHeaders(&output_sections);

    {
        const layout_phase = trace.product(.address_assignment);
        defer layout_phase.end();
        try layout.output.assign(&output_sections, options, program_header_count);
    }
    {
        const manifest_phase = trace.product(.manifest_recording);
        defer manifest_phase.end();
        for (output_sections) |section| {
            if (section.logicalSize() == 0) continue;
            try manifest_builder.addSection(
                section.kind.name(),
                section.address,
                section.file_offset,
                section.logicalSize(),
                section.reserved_size,
                section.alignment,
            );
        }
        if (manifest_builder.recordsContributions()) {
            try addContributionRecords(&manifest_builder, objects.items, layouts[0..layout_count], &output_sections);
        }
    }

    var symbol_addresses = try SymbolAddressCache.init(scratch, objects.items, layouts[0..layout_count], &output_sections);
    defer symbol_addresses.deinit(scratch);

    try elf.ifunc.finalize(objects.items, layouts[0..layout_count], &output_sections, &globals, &symbol_addresses, ifunc_layout);

    const entry_address = resolve_entry: {
        const symbol_phase = trace.product(.symbol_database);
        defer symbol_phase.end();
        break :resolve_entry try resolveEntry(objects.items, layouts, &output_sections, &globals, &symbol_addresses, options.entry_symbol);
    };

    var linked_image = write_image: {
        const write_phase = trace.product(.output_writing);
        defer write_phase.end();
        break :write_image try image.write(
            scratch,
            allocator,
            objects.items,
            layouts,
            &output_sections,
            &globals,
            global_symbol_refs.items,
            &symbol_addresses,
            got_layout,
            options,
            entry_address,
            live_output_count,
            program_header_count,
        );
    };
    errdefer linked_image.deinit(allocator);
    const linked_bytes = linked_image.bytes;

    try elf.ifunc.write(linked_bytes, &output_sections, ifunc_layout);
    {
        const materialize_phase = trace.product(.payload_materialization);
        defer materialize_phase.end();
        try relocation_namespace.materialize(scratch, objects.items, layouts, &output_sections, &globals, &symbol_addresses, got_layout, linked_bytes, options);
    }
    if (@import("builtin").mode == .debug) elf.payload.verifyMergePieceBytes(linked_bytes, objects.items, layouts, &output_sections);
    try finishBuildIdNote(linked_bytes, &output_sections, options);

    var manifest = finish_manifest: {
        const manifest_phase = trace.product(.manifest_recording);
        defer manifest_phase.end();
        if (manifest_builder.recordsContributions()) {
            try addExternalTargetRecords(
                &manifest_builder,
                scratch,
                objects.items,
                layouts[0..layout_count],
                &output_sections,
                &globals,
                global_symbol_refs.items,
                &symbol_addresses,
            );
            try addGotEntryRecords(&manifest_builder, objects.items, &output_sections, &globals, got_layout);
            try addMergePieceRecords(&manifest_builder, objects.items, layouts[0..layout_count], &output_sections);
        }
        break :finish_manifest try manifest_builder.finish();
    };
    errdefer manifest.deinit(allocator);

    return .{
        .bytes = linked_bytes,
        .storage = linked_image.storage,
        .manifest = manifest,
    };
}

fn parseInputObject(
    scratch: Allocator,
    input: model.Input,
    options: model.LinkOptions,
) model.Error!ObjectFile {
    return parseObjectWithOptions(scratch, input, .{
        .strip_debug = options.strip_debug,
        .worker_budget = options.max_link_jobs,
    }) catch |err| switch (err) {
        error.InvalidElfHeader => {
            const input_format = root.detectObjectFormat(input.bytes) catch |detect_err| switch (detect_err) {
                error.UnsupportedFormat => return error.UnsupportedFormat,
                else => return detect_err,
            };
            if (input_format == .elf) return err;
            if (options.diagnostics) |diagnostics| {
                diagnostics.recordUnsupportedInputFormat(
                    input.name,
                    input_format,
                    options.target.object_format,
                );
            }
            return error.UnsupportedFormat;
        },
        else => return err,
    };
}

const UndefinedRelocationFailure = struct {
    found: bool = false,
    object_index: usize = 0,
    section_index: usize = 0,
    relocation_index: usize = 0,
    symbol_index: usize = 0,

    fn isFound(failure: UndefinedRelocationFailure) bool {
        return failure.found;
    }

    fn before(left: UndefinedRelocationFailure, right: UndefinedRelocationFailure) bool {
        if (left.object_index != right.object_index) return left.object_index < right.object_index;
        if (left.section_index != right.section_index) return left.section_index < right.section_index;
        return left.relocation_index < right.relocation_index;
    }
};

const UnsupportedRelocationFailure = struct {
    found: bool = false,
    object_index: usize = 0,
    section_index: usize = 0,
    relocation_index: usize = 0,

    fn isFound(failure: UnsupportedRelocationFailure) bool {
        return failure.found;
    }

    fn before(left: UnsupportedRelocationFailure, right: UnsupportedRelocationFailure) bool {
        if (left.object_index != right.object_index) return left.object_index < right.object_index;
        if (left.section_index != right.section_index) return left.section_index < right.section_index;
        return left.relocation_index < right.relocation_index;
    }
};

const UnsupportedRelocationFailures = parallel.FailureSlots(UnsupportedRelocationFailure);

const UnsupportedRelocationContext = struct {
    objects: []const ObjectFile,
    failures: *UnsupportedRelocationFailures,
};

fn requireSupportedRelocations(
    scratch: Allocator,
    objects: []const ObjectFile,
    options: model.LinkOptions,
) model.Error!void {
    var total: usize = 0;
    for (objects) |object| total += object.relocations.len;
    const workers = if (total >= format.parallel_relocation_threshold)
        parallel.chooseWorkers(
            total,
            parallel.grainWorkers(options.max_link_jobs, total, format.relocations_per_worker),
        )
    else
        1;

    if (workers <= 1) {
        for (objects, 0..) |_, object_index| {
            if (firstUnsupportedRelocation(objects, object_index)) |failure| {
                return failSupportedRelocations(objects, failure, options);
            }
        }
        return;
    }

    var failures = try UnsupportedRelocationFailures.init(scratch, workers, .{});
    defer failures.deinit(scratch);

    var context = UnsupportedRelocationContext{
        .objects = objects,
        .failures = &failures,
    };
    parallel.forItems(objects.len, workers, &context, scanSupportedRelocationObject);
    if (failures.earliest(UnsupportedRelocationFailure.isFound, UnsupportedRelocationFailure.before)) |failure| {
        return failSupportedRelocations(objects, failure, options);
    }
}

fn failSupportedRelocations(
    objects: []const ObjectFile,
    failure: UnsupportedRelocationFailure,
    options: model.LinkOptions,
) model.Error {
    const object = objects[failure.object_index];
    const relocations = object.relocationsForSection(failure.section_index);
    diagnostic.recordUnsupportedRelocation(options, object, failure.section_index, relocations[failure.relocation_index]);
    return error.UnsupportedRelocation;
}

fn scanSupportedRelocationObject(context: *UnsupportedRelocationContext, worker: usize, object_index: usize) void {
    const failure = firstUnsupportedRelocation(context.objects, object_index) orelse return;
    const current = context.failures.items[worker];
    if (!current.found or UnsupportedRelocationFailure.before(failure, current)) {
        context.failures.record(worker, failure);
    }
}

fn firstUnsupportedRelocation(objects: []const ObjectFile, object_index: usize) ?UnsupportedRelocationFailure {
    const object = objects[object_index];
    if (object.relocations.len == 0) return null;
    for (object.sections, 0..) |_, section_index| {
        if (!sectionRelocationsAffectOutput(object, section_index)) continue;
        if (sectionDiscarded(object, section_index)) continue;
        if (foldedSection(object, section_index) != null) continue;

        const relocations = object.relocationsForSection(section_index);
        for (relocations, 0..) |entry, relocation_index| {
            if (relocation_namespace.applicationSupported(entry.relocationType())) continue;
            return .{
                .found = true,
                .object_index = object_index,
                .section_index = section_index,
                .relocation_index = relocation_index,
            };
        }
    }
    return null;
}

fn requireEntrySymbol(
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    options: model.LinkOptions,
) model.Error!void {
    if (!globals.contains(options.entry_symbol)) return error.MissingEntrySymbol;
}

const UndefinedRelocationFailures = parallel.FailureSlots(UndefinedRelocationFailure);

const UndefinedRelocationContext = struct {
    objects: []const ObjectFile,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    failures: *UndefinedRelocationFailures,
};

fn requireResolvedRelocationSymbols(
    scratch: Allocator,
    objects: []const ObjectFile,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    options: model.LinkOptions,
) model.Error!void {
    const total = unresolvedRelocationScanTotal(objects);
    const workers = if (total >= format.parallel_relocation_threshold)
        parallel.chooseWorkers(
            total,
            parallel.grainWorkers(options.max_link_jobs, total, format.relocations_per_worker),
        )
    else
        1;

    if (workers <= 1) return requireResolvedRelocationSymbolsSerial(objects, globals, options);

    var failures = try UndefinedRelocationFailures.init(scratch, workers, .{});
    defer failures.deinit(scratch);

    var context = UndefinedRelocationContext{
        .objects = objects,
        .globals = globals,
        .failures = &failures,
    };
    parallel.forItems(objects.len, workers, &context, scanResolvedRelocationObject);
    if (failures.earliest(UndefinedRelocationFailure.isFound, UndefinedRelocationFailure.before) != null) {
        return requireResolvedRelocationSymbolsSerial(objects, globals, options);
    }
}

fn requireResolvedRelocationSymbolsSerial(
    objects: []const ObjectFile,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    options: model.LinkOptions,
) model.Error!void {
    var found_undefined = false;
    for (objects) |object| {
        if (!object.has_named_strong_undefined_symbols) continue;
        if (object.relocations.len == 0) continue;
        for (object.sections, 0..) |_, section_index| {
            if (!sectionRelocationsAffectOutput(object, section_index)) continue;
            if (sectionDiscarded(object, section_index)) continue;
            if (foldedSection(object, section_index) != null) continue;

            const relocations = object.relocationsForSection(section_index);
            for (relocations, 0..) |entry, relocation_index| {
                if (relocation_namespace.isNone(entry)) continue;
                if (entry.symbolIndex() >= object.symbols.len) return error.UndefinedSymbol;

                const symbol = object.symbols[@intCast(entry.symbolIndex())];
                if (!symbol.isUndefined()) continue;
                if (globals.contains(symbol.name)) continue;
                if (symbol.isWeakUndefined()) continue;
                if (unresolvedSymbolHasSyntheticBoundary(objects, symbol.name)) continue;
                if (relocation_namespace.isRelaxedTlsRuntimeResolver(object, relocations, relocation_index)) continue;
                diagnostic.recordUndefinedSymbol(options, object, symbol);
                found_undefined = true;
            }
        }
    }
    if (found_undefined) return error.UndefinedSymbol;
}

fn unresolvedRelocationScanTotal(objects: []const ObjectFile) usize {
    var total: usize = 0;
    for (objects) |object| {
        if (!object.has_named_strong_undefined_symbols) continue;
        total += object.relocations.len;
    }
    return total;
}

fn scanResolvedRelocationObject(context: *UndefinedRelocationContext, worker: usize, object_index: usize) void {
    const failure = firstUnresolvedRelocation(context.objects, context.globals, object_index) orelse return;
    const current = context.failures.items[worker];
    if (!current.found or UndefinedRelocationFailure.before(failure, current)) {
        context.failures.record(worker, failure);
    }
}

fn firstUnresolvedRelocation(
    objects: []const ObjectFile,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    object_index: usize,
) ?UndefinedRelocationFailure {
    const object = objects[object_index];
    if (!object.has_named_strong_undefined_symbols) return null;
    if (object.relocations.len == 0) return null;
    for (object.sections, 0..) |_, section_index| {
        if (!sectionRelocationsAffectOutput(object, section_index)) continue;
        if (sectionDiscarded(object, section_index)) continue;
        if (foldedSection(object, section_index) != null) continue;

        const relocations = object.relocationsForSection(section_index);
        for (relocations, 0..) |entry, relocation_index| {
            if (relocation_namespace.isNone(entry)) continue;
            if (entry.symbolIndex() >= object.symbols.len) return .{
                .found = true,
                .object_index = object_index,
                .section_index = section_index,
                .relocation_index = relocation_index,
                .symbol_index = object.symbols.len,
            };

            const symbol_index: usize = @intCast(entry.symbolIndex());
            const symbol = object.symbols[symbol_index];
            if (!symbol.isUndefined()) continue;
            if (globals.contains(symbol.name)) continue;
            if (symbol.isWeakUndefined()) continue;
            if (unresolvedSymbolHasSyntheticBoundary(objects, symbol.name)) continue;
            if (relocation_namespace.isRelaxedTlsRuntimeResolver(object, relocations, relocation_index)) continue;
            return .{
                .found = true,
                .object_index = object_index,
                .section_index = section_index,
                .relocation_index = relocation_index,
                .symbol_index = symbol_index,
            };
        }
    }
    return null;
}

fn unresolvedSymbolHasSyntheticBoundary(objects: []const ObjectFile, symbol_name: []const u8) bool {
    const boundary = syntheticBoundaryForSymbol(symbol_name) orelse return false;
    if (boundary.optional) return true;
    return hasSyntheticBoundarySection(objects, boundary.section_name);
}

fn hasSyntheticBoundarySection(objects: []const ObjectFile, section_name: []const u8) bool {
    for (objects) |object| {
        for (object.sections, 0..) |section, section_index| {
            if (!sectionIsAllocated(section)) continue;
            if (section.size == 0) continue;
            if (sectionDiscarded(object, section_index)) continue;
            if (foldedSection(object, section_index) != null) continue;
            if (boundarySectionNameMatches(.{ .section_name = section_name, .stop = false }, sectionNameOrEmpty(object, section_index))) return true;
        }
    }
    return false;
}

fn addContributionRecords(
    manifest_builder: *incremental.Builder,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
) model.Error!void {
    for (objects, 0..) |object, object_index| {
        try addDiscardedSectionRecords(manifest_builder, object);

        const object_layout = layouts[object_index];
        for (object.sections, 0..) |_, section_index| {
            const contribution = contributionAt(object_layout.sections, section_index) orelse continue;
            const output = output_sections[contribution.outputIndex()];
            const name = try sectionName(object, section_index);
            try manifest_builder.addContributionWithFileSize(
                object.name,
                object.input_index,
                .section,
                name,
                @intCast(section_index),
                output.kind.name(),
                output.address + contribution.offset,
                output.file_offset + contribution.offset,
                contribution.size,
                if (output.kind.isNoBits()) 0 else contribution.size,
                contribution.reserved_size,
                contribution.alignment,
            );
        }
        if (object_layout.common_symbols.len != 0) {
            for (object.symbols, 0..) |symbol, symbol_index| {
                const contribution = contributionAt(object_layout.common_symbols, symbol_index) orelse continue;
                const output = output_sections[contribution.outputIndex()];
                try manifest_builder.addContributionWithFileSize(
                    object.name,
                    object.input_index,
                    .common_symbol,
                    symbol.name,
                    @intCast(symbol_index),
                    output.kind.name(),
                    output.address + contribution.offset,
                    output.file_offset + contribution.offset,
                    contribution.size,
                    if (output.kind.isNoBits()) 0 else contribution.size,
                    contribution.reserved_size,
                    contribution.alignment,
                );
            }
        }
    }
}

fn addExternalTargetRecords(
    manifest_builder: *incremental.Builder,
    scratch: Allocator,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    global_symbol_refs: []const SymbolRef,
    symbol_addresses: *SymbolAddressCache,
) model.Error!void {
    for (global_symbol_refs) |current_ref| {
        const object = objects[current_ref.object_index];
        const symbol = object.symbols[current_ref.symbol_index];
        if (section_state.symbolSectionDiscarded(object, symbol)) continue;
        const resolved_address = addressing.relocationAddress(
            .serial,
            objects,
            layouts,
            output_sections,
            globals,
            symbol_addresses,
            current_ref.object_index,
            current_ref.symbol_index,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        try manifest_builder.addExternalTarget(symbol.name, resolved_address, symbol.size);
    }

    var recorded_boundaries: std.StringHashMapUnmanaged(void) = .{};
    defer recorded_boundaries.deinit(scratch);
    for (objects) |object| {
        for (object.symbols) |symbol| {
            if (!symbol.isUndefined()) continue;
            if (symbol.name.len == 0) continue;
            if (globals.contains(symbol.name)) continue;
            const symbol_boundary = addressing.boundaryForSymbol(symbol.name) orelse continue;
            const boundary_address = symbol_addresses.syntheticBoundaryAddress(symbol_boundary) orelse continue;
            const gop = try recorded_boundaries.getOrPut(scratch, symbol.name);
            if (gop.found_existing) continue;
            try manifest_builder.addExternalTarget(symbol.name, boundary_address, 0);
        }
    }
}

fn addGotEntryRecords(
    manifest_builder: *incremental.Builder,
    objects: []const ObjectFile,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    got_layout: layout.GotLayout,
) model.Error!void {
    if (got_layout.entries.len == 0) return;
    const got = output_sections[@backingInt(output_section.OutputSectionKind.got)];
    for (got_layout.entries) |entry| {
        if (entry.ref.object_index >= objects.len) continue;
        const object = objects[entry.ref.object_index];
        if (entry.ref.symbol_index >= object.symbols.len) continue;
        const symbol = object.symbols[entry.ref.symbol_index];
        const unified_name = unified: {
            if (symbol.name.len == 0) break :unified "";
            const global = globals.get(symbol.name) orelse break :unified "";
            if (!global.ref.eql(entry.ref)) break :unified "";
            break :unified symbol.name;
        };
        const ordinal = std.math.cast(u32, entry.ref.symbol_index) orelse continue;
        try manifest_builder.addGotEntry(
            object.input_index,
            object.name,
            ordinal,
            unified_name,
            got.address + entry.offset,
        );
    }
}

fn addMergePieceRecords(
    manifest_builder: *incremental.Builder,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
) model.Error!void {
    for (objects, 0..) |object, object_index| {
        const merge_sections = layouts[object_index].merge_sections;
        for (merge_sections, 0..) |merge_section, section_index| {
            if (!merge_section.isPresent()) continue;
            const ordinal = std.math.cast(u32, section_index) orelse continue;
            for (merge_section.pieces) |piece| {
                const output = output_sections[piece.contribution.outputIndex()];
                try manifest_builder.addMergePiece(
                    object.input_index,
                    object.name,
                    ordinal,
                    piece.input_offset,
                    piece.size,
                    output.address + piece.contribution.offset + piece.output_intra_offset,
                );
            }
        }
    }
}

fn addDiscardedSectionRecords(
    manifest_builder: *incremental.Builder,
    object: ObjectFile,
) model.Error!void {
    for (object.sections, 0..) |section, section_index| {
        if ((section.flags & std.elf.SHF_ALLOC) == 0 or section.size == 0) continue;

        const reason: incremental.DiscardReason = if (foldedSection(object, section_index) != null)
            .identical_code_folded
        else if (sectionDiscarded(object, section_index))
            .discarded
        else
            continue;

        try manifest_builder.addDiscardedContribution(
            object.name,
            object.input_index,
            try sectionName(object, section_index),
            @intCast(section_index),
            reason,
            section.size,
            @max(section.alignment, 1),
        );
    }
}

fn resolveEntry(
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    entry_symbol: []const u8,
) model.Error!u64 {
    const global = globals.get(entry_symbol) orelse return error.MissingEntrySymbol;
    return symbolAddress(.serial, objects, layouts, output_sections, globals, symbol_addresses, global.ref.object_index, global.ref.symbol_index);
}
