const std = @import("std");
const allocators = @import("alloc");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const parallel = root.parallel;
const trace = root.trace;
const ObjectFile = elf.parser.ObjectFile;
const OutputSection = elf.layout.OutputSection;
const SectionContribution = elf.layout.SectionContribution;
const ObjectLayout = elf.layout.ObjectLayout;
const SymbolRef = elf.layout.SymbolRef;
const GlobalSymbol = elf.layout.GlobalSymbol;
const OutputSectionKind = elf.output_section.OutputSectionKind;
const SectionHeader = elf.format.SectionHeader;
const Symbol = elf.format.Symbol;
const output_section_count = elf.output_section.output_section_count;
const debugOutputIndexForName = elf.output_section.debugOutputIndexForName;
const outputIndexForAlloc = elf.output_section.indexForAllocatedNamed;
const outputIndexForFixedMerge = elf.output_section.indexForAllocated;
const isAllocPayloadSection = elf.output_section.isAllocatedPayloadType;
const sectionIsAllocated = elf.format.sectionIsAllocated;
const sectionNameOrEmpty = elf.parser.sectionNameOrEmpty;
const validateAlignment = elf.format.validateAlignment;
const alignForwardU64 = elf.format.alignForwardU64;
const contributionReserveSize = elf.layout.contributionReserveSize;

const parallel_section_threshold = 4096;

const Class = enum(u8) {
    none,
    empty_alloc,
    payload,
    ehframe,
    fixed_merge,
    string_merge,
};

const Classification = struct {
    classes: []Class,
    outputs: []u8,
    merge_flags: []bool,
    object_bases: []usize,
};

const WalkFailure = struct {
    object_index: usize = std.math.maxInt(usize),
    section_index: usize = 0,
    err: ?model.Error = null,

    fn found(self: WalkFailure) bool {
        return self.err != null;
    }

    fn before(self: WalkFailure, other: WalkFailure) bool {
        if (self.object_index != other.object_index) return self.object_index < other.object_index;
        return self.section_index < other.section_index;
    }
};

const WalkFailures = parallel.FailureSlots(WalkFailure);

pub fn sections(
    allocator: Allocator,
    objects: []const ObjectFile,
    output_sections: *[output_section_count]OutputSection,
    layouts: []ObjectLayout,
    section_contributions: []SectionContribution,
    layout_count: *usize,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    options: model.LinkOptions,
) model.Error!void {
    var string_merge: elf.merge.String = .{};
    defer string_merge.deinit(allocator);
    var eh_frame_scan: elf.ehframe.Scan = .{};
    defer eh_frame_scan.deinit(allocator);

    initObjectLayouts(objects, layouts, section_contributions);
    layout_count.* += objects.len;

    const classification = Classification{
        .classes = try allocator.alloc(Class, section_contributions.len),
        .outputs = try allocator.alloc(u8, section_contributions.len),
        .merge_flags = try allocator.alloc(bool, objects.len),
        .object_bases = try allocator.alloc(usize, objects.len),
    };
    defer {
        allocator.free(classification.object_bases);
        allocator.free(classification.merge_flags);
        allocator.free(classification.outputs);
        allocator.free(classification.classes);
    }
    var object_base: usize = 0;
    for (objects, 0..) |object, object_index| {
        classification.object_bases[object_index] = object_base;
        object_base += object.sections.len;
    }

    const classify_failure = run_classify: {
        const classify_phase = trace.product(.contribution_classification);
        defer classify_phase.end();
        break :run_classify try classify(allocator, objects, layouts, classification, options);
    };
    {
        const scan_phase = trace.product(.contribution_ehframe_scan);
        defer scan_phase.end();
        var eh_references: std.ArrayListUnmanaged(elf.ehframe.Scan.Reference) = .empty;
        defer eh_references.deinit(allocator);
        for (objects, 0..) |object, object_index| {
            const base = classification.object_bases[object_index];
            for (0..object.sections.len) |section_index| {
                if (classification.classes[base + section_index] != .ehframe) continue;
                try eh_references.append(allocator, .{
                    .object_index = @intCast(object_index),
                    .section_index = @intCast(section_index),
                });
            }
        }
        try eh_frame_scan.prepare(allocator, objects, layouts, globals, options, eh_references.items);
    }
    const register_failure = run_register: {
        const register_phase = trace.product(.contribution_merge_registration);
        defer register_phase.end();
        try reserveCommonSymbols(allocator, objects, layouts, globals);
        try reserveMergeLayouts(allocator, objects, layouts, classification);
        break :run_register try registerStringMerges(
            allocator,
            objects,
            layouts,
            classification,
            output_sections,
            &string_merge,
        );
    };
    const assign_failure = run_assign: {
        const assign_phase = trace.product(.contribution_chain_assignment);
        defer assign_phase.end();
        break :run_assign try assignChains(
            allocator,
            objects,
            layouts,
            classification,
            eh_frame_scan.pending.items,
            output_sections,
            globals,
            options,
        );
    };

    if (earliestWalkFailure(classify_failure, earliestWalkFailure(register_failure, assign_failure))) |failure| {
        return failure.err.?;
    }
    const finish_phase = trace.product(.contribution_string_merge);
    defer finish_phase.end();
    try string_merge.finish(allocator, output_sections, options);
}

fn earliestWalkFailure(left: ?WalkFailure, right: ?WalkFailure) ?WalkFailure {
    const first = left orelse return right;
    const second = right orelse return left;
    return if (WalkFailure.before(first, second)) first else second;
}

const ClassifyContext = struct {
    objects: []const ObjectFile,
    layouts: []ObjectLayout,
    classification: Classification,
    options: model.LinkOptions,
    failures: *WalkFailures,
};

fn classify(
    allocator: Allocator,
    objects: []const ObjectFile,
    layouts: []ObjectLayout,
    classification: Classification,
    options: model.LinkOptions,
) model.Error!?WalkFailure {
    const workers = if (classification.classes.len >= parallel_section_threshold)
        parallel.chooseWorkers(objects.len, options.max_link_jobs)
    else
        1;

    var failures = try WalkFailures.init(allocator, workers, .{});
    defer failures.deinit(allocator);

    var context = ClassifyContext{
        .objects = objects,
        .layouts = layouts,
        .classification = classification,
        .options = options,
        .failures = &failures,
    };
    if (workers <= 1) {
        for (objects, 0..) |_, object_index| classifyObject(&context, 0, object_index);
    } else {
        parallel.forItems(objects.len, workers, &context, classifyObject);
    }
    return failures.earliest(WalkFailure.found, WalkFailure.before);
}

fn classifyObject(context: *ClassifyContext, worker: usize, object_index: usize) void {
    const object = context.objects[object_index];
    const object_base = context.classification.object_bases[object_index];
    const classes = context.classification.classes[object_base..][0..object.sections.len];
    const outputs = context.classification.outputs[object_base..][0..object.sections.len];
    const contributions = context.layouts[object_index].sections;
    var has_merge = false;

    for (object.sections, 0..) |section, section_index| {
        const class = classifySection(object, section, section_index, context.options) catch |err| {
            recordWalkFailure(context.failures, worker, object_index, section_index, err);
            classes[section_index] = .none;
            outputs[section_index] = 0;
            contributions[section_index] = .{};
            continue;
        };
        classes[section_index] = class.class;
        outputs[section_index] = class.output;
        switch (class.class) {
            .none, .fixed_merge, .string_merge => contributions[section_index] = .{},
            .empty_alloc, .payload, .ehframe => {},
        }
        if (class.class == .fixed_merge or class.class == .string_merge) has_merge = true;
    }
    context.classification.merge_flags[object_index] = has_merge;
}

fn recordWalkFailure(
    failures: *WalkFailures,
    worker: usize,
    object_index: usize,
    section_index: usize,
    err: model.Error,
) void {
    const failure = WalkFailure{
        .object_index = object_index,
        .section_index = section_index,
        .err = err,
    };
    const current = failures.items[worker];
    if (!current.found() or WalkFailure.before(failure, current)) {
        failures.record(worker, failure);
    }
}

const SectionClass = struct {
    class: Class,
    output: u8 = 0,
};

fn classifySection(
    object: ObjectFile,
    section: SectionHeader,
    section_index: usize,
    options: model.LinkOptions,
) model.Error!SectionClass {
    const discarded_sections = object.discarded_sections;
    if (discarded_sections.len != 0 and discarded_sections[section_index]) return .{ .class = .none };
    const folded_sections = object.folded_sections;
    if (folded_sections.len != 0 and folded_sections[section_index] != null) return .{ .class = .none };
    if (section.size == 0) {
        if (!sectionIsAllocated(section)) return .{ .class = .none };
        if (!isAllocPayloadSection(section.section_type)) return error.UnsupportedFormat;
        try validateAlignment(section.alignment);
        const output_index = outputIndexForAlloc(section, sectionNameOrEmpty(object, section_index));
        return .{ .class = .empty_alloc, .output = @intCast(output_index) };
    }
    if ((section.flags & std.elf.SHF_ALLOC) == 0) {
        if (section.section_type != std.elf.SHT_PROGBITS) return .{ .class = .none };
        const name = sectionNameOrEmpty(object, section_index);
        const output_index = debugOutputIndexForName(name) orelse return .{ .class = .none };
        if (options.strip_debug) return .{ .class = .none };
        try validateAlignment(section.alignment);
        return .{ .class = .payload, .output = @intCast(output_index) };
    }
    if (elf.ehframe.isSection(object, section_index, section) and object.relocationsForSection(section_index).len != 0) {
        try validateAlignment(section.alignment);
        return .{ .class = .ehframe, .output = @backingInt(OutputSectionKind.eh_frame) };
    }
    if (elf.merge.fixed(section)) {
        if (object.relocationsForSection(section_index).len != 0) {
            return classifyAllocPayload(object, section, section_index);
        }
        return .{ .class = .fixed_merge, .output = @intCast(outputIndexForFixedMerge(section)) };
    }
    if (elf.merge.string(section)) {
        if (object.relocationsForSection(section_index).len != 0) {
            return classifyAllocPayload(object, section, section_index);
        }
        return .{ .class = .string_merge };
    }
    return classifyAllocPayload(object, section, section_index);
}

fn classifyAllocPayload(
    object: ObjectFile,
    section: SectionHeader,
    section_index: usize,
) model.Error!SectionClass {
    if (!isAllocPayloadSection(section.section_type)) return error.UnsupportedFormat;
    try validateAlignment(section.alignment);
    const output_index = outputIndexForAlloc(section, sectionNameOrEmpty(object, section_index));
    return .{ .class = .payload, .output = @intCast(output_index) };
}

fn reserveCommonSymbols(
    allocator: Allocator,
    objects: []const ObjectFile,
    layouts: []ObjectLayout,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
) model.Error!void {
    for (objects, 0..) |object, object_index| {
        if (!object.has_common_symbols) continue;
        for (object.symbols, 0..) |symbol, symbol_index| {
            if (!commonSymbolEligible(object_index, symbol, symbol_index, globals)) continue;
            _ = try ensureCommonSymbolLayouts(allocator, object, &layouts[object_index].common_symbols);
            break;
        }
    }
}

fn commonSymbolEligible(
    object_index: usize,
    symbol: Symbol,
    symbol_index: usize,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
) bool {
    if (!symbol.isCommon()) return false;
    if (symbol.name.len == 0) return true;
    const global = globals.get(symbol.name) orelse return false;
    const current_ref = SymbolRef{ .object_index = object_index, .symbol_index = symbol_index };
    return global.ref.eql(current_ref);
}

fn reserveMergeLayouts(
    allocator: Allocator,
    objects: []const ObjectFile,
    layouts: []ObjectLayout,
    classification: Classification,
) model.Error!void {
    for (objects, 0..) |object, object_index| {
        if (!classification.merge_flags[object_index]) continue;
        _ = try elf.merge.ensure(allocator, object, &layouts[object_index].merge_sections);
    }
}

fn registerStringMerges(
    allocator: Allocator,
    objects: []const ObjectFile,
    layouts: []ObjectLayout,
    classification: Classification,
    output_sections: *[output_section_count]OutputSection,
    string_merge: *elf.merge.String,
) model.Error!?WalkFailure {
    for (objects, 0..) |object, object_index| {
        if (!classification.merge_flags[object_index]) continue;
        const object_base = classification.object_bases[object_index];
        const merge_sections = layouts[object_index].merge_sections;
        var merge_starts: elf.merge.StartIndex = .{};
        defer merge_starts.deinit(allocator);
        var use_merge_start_index: ?bool = null;
        for (object.sections, 0..) |section, section_index| {
            if (classification.classes[object_base + section_index] != .string_merge) continue;
            registerStringMerge(
                allocator,
                object,
                section,
                section_index,
                &merge_starts,
                &use_merge_start_index,
                output_sections,
                string_merge,
                merge_sections,
            ) catch |err| {
                return WalkFailure{
                    .object_index = object_index,
                    .section_index = section_index,
                    .err = err,
                };
            };
        }
    }
    return null;
}

fn registerStringMerge(
    allocator: Allocator,
    object: ObjectFile,
    section: SectionHeader,
    section_index: usize,
    merge_starts: *elf.merge.StartIndex,
    use_merge_start_index: *?bool,
    output_sections: *[output_section_count]OutputSection,
    string_merge: *elf.merge.String,
    merge_sections: []elf.layout.MergeSectionLayout,
) model.Error!void {
    if (use_merge_start_index.* == null) use_merge_start_index.* = elf.merge.shouldIndexStarts(object);
    const external_starts = if (use_merge_start_index.*.?)
        try merge_starts.forSection(allocator, object, section_index)
    else
        try elf.merge.collectStarts(allocator, object, section_index);
    defer if (!use_merge_start_index.*.? and external_starts.len != 0) allocator.free(external_starts);
    try string_merge.register(
        allocator,
        object,
        section,
        section_index,
        external_starts,
        output_sections,
        &merge_sections[section_index],
    );
}

const ChainContext = struct {
    allocator: Allocator,
    objects: []const ObjectFile,
    layouts: []ObjectLayout,
    classification: Classification,
    eh_pending: []const elf.ehframe.Scan.Pending,
    output_sections: *[output_section_count]OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    options: model.LinkOptions,
    failures: *WalkFailures,
};

fn assignChains(
    allocator: Allocator,
    objects: []const ObjectFile,
    layouts: []ObjectLayout,
    classification: Classification,
    eh_pending: []const elf.ehframe.Scan.Pending,
    output_sections: *[output_section_count]OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    options: model.LinkOptions,
) model.Error!?WalkFailure {
    const workers = if (classification.classes.len >= parallel_section_threshold)
        parallel.chooseWorkers(output_section_count, options.max_link_jobs)
    else
        1;

    var failures = try WalkFailures.init(allocator, workers, .{});
    defer failures.deinit(allocator);

    var locked_allocator = allocators.LockedAllocator.init(allocator);
    var context = ChainContext{
        .allocator = locked_allocator.allocator(),
        .objects = objects,
        .layouts = layouts,
        .classification = classification,
        .eh_pending = eh_pending,
        .output_sections = output_sections,
        .globals = globals,
        .options = options,
        .failures = &failures,
    };
    if (workers <= 1) {
        context.allocator = allocator;
        var chain_index: usize = 0;
        while (chain_index < output_section_count) : (chain_index += 1) assignChain(&context, 0, chain_index);
    } else {
        parallel.forItems(output_section_count, workers, &context, assignChain);
    }
    return failures.earliest(WalkFailure.found, WalkFailure.before);
}

fn assignChain(context: *ChainContext, worker: usize, chain_index: usize) void {
    const is_eh_chain = chain_index == @backingInt(OutputSectionKind.eh_frame);
    const is_bss_chain = chain_index == @backingInt(OutputSectionKind.bss);
    var eh_cursor: usize = 0;
    var fixed_merge: elf.merge.Fixed = .{};
    defer fixed_merge.deinit(context.allocator);

    for (context.objects, 0..) |object, object_index| {
        const object_base = context.classification.object_bases[object_index];
        const contributions = context.layouts[object_index].sections;
        for (object.sections, 0..) |section, section_index| {
            const flat = object_base + section_index;
            switch (context.classification.classes[flat]) {
                .ehframe => {
                    if (!is_eh_chain) continue;
                    const entry = context.eh_pending[eh_cursor];
                    std.debug.assert(entry.object_index == object_index);
                    std.debug.assert(entry.section_index == section_index);
                    eh_cursor += 1;
                    assignEhFrameSection(context, entry, section, section_index, contributions) catch |err| {
                        recordWalkFailure(context.failures, worker, object_index, section_index, err);
                        return;
                    };
                },
                .payload => {
                    if (context.classification.outputs[flat] != chain_index) continue;
                    payloadSection(context.output_sections, contributions, section, section_index, chain_index, context.options) catch |err| {
                        recordWalkFailure(context.failures, worker, object_index, section_index, err);
                        return;
                    };
                },
                .empty_alloc => {
                    if (context.classification.outputs[flat] != chain_index) continue;
                    emptyAllocSection(context.output_sections, contributions, section, section_index, chain_index) catch |err| {
                        recordWalkFailure(context.failures, worker, object_index, section_index, err);
                        return;
                    };
                },
                .fixed_merge => {
                    if (context.classification.outputs[flat] != chain_index) continue;
                    fixed_merge.collect(
                        context.allocator,
                        object,
                        section,
                        section_index,
                        context.output_sections,
                        context.layouts[object_index].merge_sections,
                        context.options,
                    ) catch |err| {
                        recordWalkFailure(context.failures, worker, object_index, section_index, err);
                        return;
                    };
                },
                .none, .string_merge => {},
            }
        }
        if (is_bss_chain and object.has_common_symbols and context.layouts[object_index].common_symbols.len != 0) {
            commonSymbols(
                object,
                object_index,
                context.output_sections,
                context.layouts[object_index].common_symbols,
                context.globals,
                context.options,
            ) catch |err| {
                recordWalkFailure(context.failures, worker, object_index, object.sections.len, err);
                return;
            };
        }
    }
}

fn assignEhFrameSection(
    context: *ChainContext,
    entry: elf.ehframe.Scan.Pending,
    section: SectionHeader,
    section_index: usize,
    contributions: []SectionContribution,
) model.Error!void {
    try entry.failure;
    try elf.ehframe.section.assign(
        context.output_sections,
        contributions,
        section,
        section_index,
        entry.output_size,
        context.options,
    );
}

fn initObjectLayouts(
    objects: []const ObjectFile,
    layouts: []ObjectLayout,
    section_contributions: []SectionContribution,
) void {
    var section_contribution_cursor: usize = 0;
    for (objects, 0..) |object, object_index| {
        const next_cursor = section_contribution_cursor + object.sections.len;
        layouts[object_index] = .{
            .sections = section_contributions[section_contribution_cursor..next_cursor],
            .common_symbols = &.{},
            .merge_sections = &.{},
            .eh_frame_sections = &.{},
        };
        section_contribution_cursor = next_cursor;
    }
    std.debug.assert(section_contribution_cursor == section_contributions.len);
}

pub fn countObjectSections(objects: []const ObjectFile) model.Error!usize {
    var total: usize = 0;
    for (objects) |object| {
        if (object.sections.len > std.math.maxInt(usize) - total) return error.InvalidObject;
        total += object.sections.len;
    }
    return total;
}

fn emptyAllocSection(
    output_sections: *[output_section_count]OutputSection,
    contributions: []SectionContribution,
    section: SectionHeader,
    section_index: usize,
    output_index: usize,
) model.Error!void {
    var output = &output_sections[output_index];
    try validateAlignment(section.alignment);
    const alignment = @max(section.alignment, 1);
    output.alignment = @max(output.alignment, alignment);
    const offset = if (section.section_type == std.elf.SHT_NOBITS)
        alignForwardU64(output.memory_size, alignment)
    else
        alignForwardU64(output.file_size, alignment);
    contributions[section_index] = SectionContribution.init(output_index, offset, 0, 0, alignment);
}

fn payloadSize(
    output_sections: *[output_section_count]OutputSection,
    contributions: []SectionContribution,
    section: SectionHeader,
    section_index: usize,
    output_index: usize,
    size: u64,
    options: model.LinkOptions,
) model.Error!void {
    var output = &output_sections[output_index];
    try validateAlignment(section.alignment);
    output.alignment = @max(output.alignment, @max(section.alignment, 1));
    const alignment = @max(section.alignment, 1);
    const aligned_offset = if (section.section_type == std.elf.SHT_NOBITS)
        alignForwardU64(output.memory_size, alignment)
    else
        alignForwardU64(output.file_size, alignment);
    const reserved_size = contributionReserveSize(size, alignment, options);
    contributions[section_index] = SectionContribution.init(
        output_index,
        aligned_offset,
        size,
        reserved_size,
        alignment,
    );

    if (section.section_type == std.elf.SHT_NOBITS) {
        output.memory_size = aligned_offset + reserved_size;
    } else {
        output.file_size = aligned_offset + reserved_size;
        output.memory_size = output.file_size;
    }
}

fn payloadSection(
    output_sections: *[output_section_count]OutputSection,
    contributions: []SectionContribution,
    section: SectionHeader,
    section_index: usize,
    output_index: usize,
    options: model.LinkOptions,
) model.Error!void {
    try payloadSize(output_sections, contributions, section, section_index, output_index, section.size, options);
}

fn commonSymbols(
    object: ObjectFile,
    object_index: usize,
    output_sections: *[output_section_count]OutputSection,
    contributions: []SectionContribution,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    options: model.LinkOptions,
) model.Error!void {
    for (object.symbols, 0..) |symbol, symbol_index| {
        if (!commonSymbolEligible(object_index, symbol, symbol_index, globals)) continue;

        const alignment = @max(symbol.value, 1);
        try validateAlignment(alignment);
        const output_index = @backingInt(OutputSectionKind.bss);
        var output = &output_sections[output_index];
        output.alignment = @max(output.alignment, alignment);
        const aligned_offset = alignForwardU64(output.memory_size, alignment);
        const reserved_size = contributionReserveSize(symbol.size, alignment, options);
        contributions[symbol_index] = SectionContribution.init(
            output_index,
            aligned_offset,
            symbol.size,
            reserved_size,
            alignment,
        );
        output.memory_size = aligned_offset + reserved_size;
    }
}

fn ensureCommonSymbolLayouts(
    allocator: Allocator,
    object: ObjectFile,
    common_symbols: *[]SectionContribution,
) Allocator.Error![]SectionContribution {
    if (common_symbols.*.len != 0) return common_symbols.*;
    const symbols = try allocator.alloc(SectionContribution, object.symbols.len);
    @memset(symbols, .{});
    common_symbols.* = symbols;
    return symbols;
}
