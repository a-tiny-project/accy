const std = @import("std");
const allocators = @import("alloc");
const root = @import("../../root.zig");
const addressing = @import("address/root.zig");
const archive_selection = @import("archive/root.zig");
const format = @import("format.zig");
const object_writer = @import("object/root.zig");
const parser = @import("parser.zig");
const relocation = @import("relocation/root.zig");

const Allocator = std.mem.Allocator;
const archive = root.archive;
const checked = relocation.value;
const incremental = root.incremental;
const model = root.model;
const parallel = root.parallel;

const ContributionKind = incremental.ContributionKind;
const ContributionRecord = incremental.ContributionRecord;
const InputChangeStorage = incremental.InputChangeStorage;
const InputChanges = incremental.InputChanges;
const Manifest = incremental.Manifest;
const RecordedInputs = incremental.RecordedInputs;
const DirectRelinkEvidence = incremental.DirectRelinkEvidence;
const ReplacementContribution = incremental.ReplacementContribution;
const ObjectFile = parser.ObjectFile;
const ObjectRelocation = object_writer.Relocation;
const ObjectSection = object_writer.Section;
const ObjectSymbol = object_writer.Symbol;
const SectionHeader = format.SectionHeader;
const Symbol = format.Symbol;
const Rela = format.Rela;
const buildObject = object_writer.build;
const sectionBytes = format.sectionBytes;
const sectionName = parser.sectionName;
const writeU16 = format.writeU16;
const writeU32 = format.writeU32;
const writeU64 = format.writeU64;

pub fn linkageHash(object: ObjectFile) model.Error!u64 {
    var hasher = std.hash.Wyhash.init(0x544c44524c494e4b);
    try hashSections(&hasher, object);
    hashSymbols(&hasher, object.symbols);
    hashRelocations(&hasher, object.relocations);
    return hasher.final();
}

pub fn recordInputLinkEvidence(
    builder: *incremental.Builder,
    allocator: Allocator,
    inputs: []const model.Input,
    objects: []const ObjectFile,
    archive_state: *const archive_selection.ExtractionState,
) model.Error!void {
    if (inputs.len == 0) return;

    const states = try allocator.alloc(InputLinkHashState, inputs.len);
    defer allocator.free(states);
    for (states) |*state| state.* = InputLinkHashState.init();

    for (objects) |object| {
        if (object.input_index >= states.len) continue;
        try states[object.input_index].update(object);
    }

    for (states, inputs, 0..) |*state, input, input_index| {
        if (archive.isArchive(input.bytes)) {
            builder.setInputSelectionHash(input_index, try selectionHashForInput(allocator, input));
        }
        if (state.count == 0) continue;
        builder.setInputLinkHash(input_index, state.final());
    }

    for (objects) |object| {
        if (object.input_index >= inputs.len) continue;
        if (!archive.isArchive(inputs[object.input_index].bytes)) continue;
        try builder.addArchiveMember(
            object.input_index,
            object.name,
            incremental.hashBytes(object.bytes),
            try linkageHash(object),
            true,
        );
    }
    for (archive_state.candidates.items) |candidate| {
        if (candidate.extracted) continue;
        if (candidate.object == null) continue;
        try builder.addArchiveMember(
            candidate.archive_input_index,
            candidate.member.name,
            incremental.hashBytes(candidate.member.bytes),
            0,
            false,
        );
    }
}

pub fn directEvidenceAlloc(
    allocator: Allocator,
    manifest: Manifest,
    inputs: []const model.Input,
    input_changes: InputChanges,
    options: model.LinkOptions,
) model.Error!DirectRelinkEvidence {
    if (!directReplacementsEnabled(options)) return .{};

    const changed_inputs = try changedInputFilterAlloc(allocator, manifest, input_changes);
    defer allocator.free(changed_inputs);

    var context = try DirectRelocationContext.init(allocator, manifest, changed_inputs);
    defer context.deinit(allocator);
    try context.seedGotEntries(allocator, manifest.got_entries);
    try context.seedMergePieces(allocator, manifest.merge_pieces);
    const inputs_proven = try context.addProvenInputs(allocator, manifest, inputs, input_changes, options);
    if (!inputs_proven) return .{};

    const member_updates = try context.member_updates.toOwnedSlice(allocator);
    errdefer if (member_updates.len != 0) allocator.free(member_updates);

    if (input_changes.summary.changed == 0 or manifest.contributions.len == 0) {
        return .{ .member_updates = member_updates, .inputs_proven = true };
    }

    var replacements: std.ArrayListUnmanaged(ReplacementContribution) = .empty;
    errdefer freeReplacementList(allocator, &replacements);

    for (input_changes.changes) |change| {
        if (change.kind != .changed) continue;
        const recorded_index = change.recorded_index orelse continue;
        if (recorded_index >= manifest.inputs.len) continue;
        try context.appendProvenInputReplacements(allocator, &replacements, recorded_index);
    }

    if (replacements.items.len == 0) {
        replacements.deinit(allocator);
        return .{ .member_updates = member_updates, .inputs_proven = true };
    }
    return .{
        .replacements = try replacements.toOwnedSlice(allocator),
        .member_updates = member_updates,
        .inputs_proven = true,
    };
}

fn directReplacementsEnabled(options: model.LinkOptions) bool {
    return options.icf == .off;
}

fn appendInputReplacements(
    allocator: Allocator,
    replacements: *std.ArrayListUnmanaged(ReplacementContribution),
    context: *const DirectRelocationContext,
    object: ObjectFile,
    recorded_index: usize,
) model.Error!void {
    for (context.contributionIndexesForInputName(object.name, recorded_index)) |contribution_index| {
        if (contribution_index >= context.contributions.len) continue;
        const contribution = context.contributions[contribution_index];
        if (contribution.input_index != recorded_index or !std.mem.eql(u8, context.manifest.string(contribution.input_name_id), object.name)) continue;
        const replacement = try replacementForContribution(allocator, context, contribution, object, recorded_index) orelse continue;
        errdefer freeReplacementPayload(allocator, replacement);
        try replacements.append(allocator, replacement);
    }
}

fn replacementForContribution(
    allocator: Allocator,
    context: *const DirectRelocationContext,
    contribution: ContributionRecord,
    object: ObjectFile,
    recorded_index: usize,
) model.Error!?ReplacementContribution {
    if (contribution.kind == .common_symbol) return replacementForCommonContribution(context.manifest, contribution, object);
    if (contribution.kind != .section) return null;

    const section_index: usize = contribution.ordinal;
    if (section_index >= object.sections.len) return null;
    const section = object.sections[section_index];
    const name = try sectionName(object, section_index);
    if (!std.mem.eql(u8, name, context.manifest.string(contribution.name_id))) return null;
    if (section.size != contribution.size) return null;
    if (@max(section.alignment, 1) > @max(contribution.alignment, 1)) return null;

    const relocations = object.relocationsForSection(section_index);
    if (hashCoveredPayloadSection(section, name)) return hashCoveredReplacement(context.manifest, contribution);
    const payload = if (section.section_type == std.elf.SHT_NOBITS) payload: {
        if (!filelessPayloadSection(section)) return null;
        break :payload &.{};
    } else if (relocations.len == 0) payload: {
        if (contribution.file_size != contribution.size) return null;
        break :payload try sectionBytes(object.bytes, section);
    } else payload: {
        if (contribution.file_size != contribution.size) return null;
        break :payload (try relocatedPayloadAlloc(allocator, context, contribution, object, recorded_index, section, relocations)) orelse return null;
    };

    return .{
        .input_name = context.manifest.string(contribution.input_name_id),
        .input_index = @intCast(contribution.input_index),
        .kind = contribution.kind,
        .name = context.manifest.string(contribution.name_id),
        .ordinal = contribution.ordinal,
        .size = section.size,
        .alignment = @max(section.alignment, 1),
        .output_section_name = context.manifest.string(contribution.output_section_name_id),
        .address = contribution.address,
        .file_offset = contribution.file_offset,
        .reserved_size = contribution.reserved_size,
        .payload = payload,
        .payload_owned = section.section_type != std.elf.SHT_NOBITS and relocations.len != 0,
    };
}

fn hashCoveredPayloadSection(section: SectionHeader, name: []const u8) bool {
    if (section.section_type == std.elf.SHT_NOBITS) return false;
    return !directPayloadSection(section, name);
}

fn hashCoveredReplacement(manifest: Manifest, contribution: ContributionRecord) ReplacementContribution {
    return .{
        .input_name = manifest.string(contribution.input_name_id),
        .input_index = @intCast(contribution.input_index),
        .kind = contribution.kind,
        .name = manifest.string(contribution.name_id),
        .ordinal = contribution.ordinal,
        .size = contribution.size,
        .alignment = contribution.alignment,
        .output_section_name = manifest.string(contribution.output_section_name_id),
        .address = contribution.address,
        .file_offset = contribution.file_offset,
        .reserved_size = contribution.reserved_size,
        .unchanged = true,
    };
}

fn replacementForCommonContribution(
    manifest: Manifest,
    contribution: ContributionRecord,
    object: ObjectFile,
) ?ReplacementContribution {
    const symbol_index: usize = contribution.ordinal;
    if (symbol_index >= object.symbols.len) return null;
    const symbol = object.symbols[symbol_index];
    if (!symbol.isCommon()) return null;
    if (!std.mem.eql(u8, symbol.name, manifest.string(contribution.name_id))) return null;
    if (symbol.size != contribution.size) return null;
    if (@max(symbol.value, 1) > @max(contribution.alignment, 1)) return null;
    return .{
        .input_name = manifest.string(contribution.input_name_id),
        .input_index = @intCast(contribution.input_index),
        .kind = contribution.kind,
        .name = manifest.string(contribution.name_id),
        .ordinal = contribution.ordinal,
        .size = symbol.size,
        .alignment = @max(symbol.value, 1),
        .output_section_name = manifest.string(contribution.output_section_name_id),
        .address = contribution.address,
        .file_offset = contribution.file_offset,
        .reserved_size = contribution.reserved_size,
    };
}

fn freeReplacementList(allocator: Allocator, replacements: *std.ArrayListUnmanaged(ReplacementContribution)) void {
    for (replacements.items) |replacement| freeReplacementPayload(allocator, replacement);
    replacements.deinit(allocator);
}

fn freeReplacementPayload(allocator: Allocator, replacement: ReplacementContribution) void {
    if (replacement.payload_owned) allocator.free(replacement.payload);
}

fn directPayloadSection(section: SectionHeader, name: []const u8) bool {
    return patchablePayloadSection(section, name) or stableRelocatedPayloadSection(section, name);
}

fn filelessPayloadSection(section: SectionHeader) bool {
    if ((section.flags & std.elf.SHF_ALLOC) == 0) return false;
    if ((section.flags & std.elf.SHF_MERGE) != 0) return false;
    return section.section_type == std.elf.SHT_NOBITS;
}

fn patchablePayloadSection(section: SectionHeader, name: []const u8) bool {
    if ((section.flags & std.elf.SHF_ALLOC) == 0) return false;
    if ((section.flags & std.elf.SHF_MERGE) != 0) return false;
    if (section.section_type != std.elf.SHT_PROGBITS) return false;
    if (std.mem.eql(u8, name, ".eh_frame")) return false;
    return true;
}

fn stableRelocatedPayloadSection(section: SectionHeader, name: []const u8) bool {
    if ((section.flags & std.elf.SHF_ALLOC) == 0) return false;
    if ((section.flags & std.elf.SHF_MERGE) != 0) return false;
    return section.section_type == std.elf.SHT_X86_64_UNWIND or std.mem.eql(u8, name, ".eh_frame");
}

fn relocatedPayloadAlloc(
    allocator: Allocator,
    context: *const DirectRelocationContext,
    contribution: ContributionRecord,
    object: ObjectFile,
    recorded_index: usize,
    section: SectionHeader,
    relocations: []const Rela,
) model.Error!?[]u8 {
    const bytes = try sectionBytes(object.bytes, section);
    const payload = try allocator.dupe(u8, bytes);
    var keep_payload = false;
    defer if (!keep_payload) allocator.free(payload);

    for (relocations) |entry| {
        if (relocation.isNone(entry)) continue;
        if (!try applyDirectRelocation(payload, context, contribution, object, recorded_index, entry)) return null;
    }

    keep_payload = true;
    return payload;
}

const DirectRelocationTarget = struct {
    address: i128,
    size: u64,
};

fn applyDirectRelocation(
    payload: []u8,
    context: *const DirectRelocationContext,
    contribution: ContributionRecord,
    object: ObjectFile,
    recorded_index: usize,
    entry: Rela,
) model.Error!bool {
    const symbol_index: usize = @intCast(entry.symbolIndex());
    if (symbol_index >= object.symbols.len) return false;
    const relocation_type = entry.relocationType();
    switch (relocation_type) {
        @backingInt(std.elf.R_X86_64.GOTPCREL),
        @backingInt(std.elf.R_X86_64.GOTPCRELX),
        @backingInt(std.elf.R_X86_64.REX_GOTPCRELX),
        => return applyDirectGotRelocation(payload, context, contribution, object, recorded_index, entry, relocation_type),
        else => {},
    }

    const symbol = object.symbols[symbol_index];
    var addend = @as(i128, entry.addend);
    const target = merged: {
        if (symbol.isSection() and entry.addend >= 0) {
            if (context.mergePieceAddress(object.name, recorded_index, symbol.section_index, @intCast(entry.addend))) |piece_address| {
                addend = 0;
                break :merged DirectRelocationTarget{ .address = piece_address, .size = 0 };
            }
        }
        break :merged directRelocationTarget(context, object, recorded_index, symbol_index) orelse return false;
    };

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
            const offset = directRelocationOffset(payload, entry, write_size) orelse return false;
            const value = target.address + addend;
            switch (relocation_type) {
                @backingInt(std.elf.R_X86_64.@"64") => writeU64(payload, offset, try checked.checkedX8664U64(value)),
                @backingInt(std.elf.R_X86_64.@"32") => writeU32(payload, offset, try checked.checkedU32(value)),
                @backingInt(std.elf.R_X86_64.@"32S") => writeU32(payload, offset, @bitCast(try checked.checkedI32(value))),
                @backingInt(std.elf.R_X86_64.@"16") => writeU16(payload, offset, try checked.checkedX8664U16(value)),
                @backingInt(std.elf.R_X86_64.@"8") => payload[offset] = try checked.checkedX8664U8(value),
                else => unreachable,
            }
            return true;
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
            const offset = directRelocationOffset(payload, entry, write_size) orelse return false;
            const place = @as(i128, @intCast(contribution.address)) + @as(i128, @intCast(entry.offset));
            const value = target.address + addend - place;
            switch (relocation_type) {
                @backingInt(std.elf.R_X86_64.PC64) => writeU64(payload, offset, @bitCast(try checked.checkedI64(value))),
                @backingInt(std.elf.R_X86_64.PC32),
                @backingInt(std.elf.R_X86_64.PLT32),
                => writeU32(payload, offset, @bitCast(try checked.checkedI32(value))),
                @backingInt(std.elf.R_X86_64.PC16) => writeU16(payload, offset, @bitCast(try checked.checkedI16(value))),
                @backingInt(std.elf.R_X86_64.PC8) => payload[offset] = @bitCast(try checked.checkedI8(value)),
                else => unreachable,
            }
            return true;
        },
        @backingInt(std.elf.R_X86_64.SIZE32),
        @backingInt(std.elf.R_X86_64.SIZE64),
        => {
            const write_size: u64 = if (relocation_type == @backingInt(std.elf.R_X86_64.SIZE64)) 8 else 4;
            const offset = directRelocationOffset(payload, entry, write_size) orelse return false;
            const value = @as(i128, @intCast(target.size)) + addend;
            if (relocation_type == @backingInt(std.elf.R_X86_64.SIZE64)) {
                writeU64(payload, offset, try checked.checkedU64(value));
            } else {
                writeU32(payload, offset, try checked.checkedU32(value));
            }
            return true;
        },
        else => return false,
    }
}

fn applyDirectGotRelocation(
    payload: []u8,
    context: *const DirectRelocationContext,
    contribution: ContributionRecord,
    object: ObjectFile,
    recorded_index: usize,
    entry: Rela,
    relocation_type: u32,
) model.Error!bool {
    const symbol_index: usize = @intCast(entry.symbolIndex());
    const symbol = object.symbols[symbol_index];
    const offset = directRelocationOffset(payload, entry, 4) orelse return false;
    const place = @as(i128, @intCast(contribution.address)) + @as(i128, @intCast(entry.offset));

    if (relocation_type == @backingInt(std.elf.R_X86_64.GOTPCREL) and symbol.isWeakUndefined()) {
        if (addressing.boundaryForSymbol(symbol.name) != null) return false;
        if (context.externalTarget(symbol.name) == null) {
            if (relocation.relax.gotpcrelWeakUndefinedNullCheck(payload, offset)) return true;
        }
    }

    const relaxation = relocation.relax.gotpcrelxInstruction(payload, offset, relocation_type);
    if (relocation_type == @backingInt(std.elf.R_X86_64.GOTPCREL)) {
        if (relaxation) |relaxed| {
            const target = directRelocationTarget(context, object, recorded_index, symbol_index) orelse return false;
            const value = switch (relaxed) {
                .pc_relative => target.address + entry.addend - place,
                .absolute_signed_32 => target.address + entry.addend + 4,
            };
            writeU32(payload, offset, @bitCast(try checked.checkedI32(value)));
            return true;
        }
        const slot = context.gotSlotAddress(object, recorded_index, symbol_index) orelse return false;
        const value = @as(i128, @intCast(slot)) + entry.addend - place;
        writeU32(payload, offset, @bitCast(try checked.checkedI32(value)));
        return true;
    }

    const relaxed = relaxation orelse return false;
    const target = directRelocationTarget(context, object, recorded_index, symbol_index) orelse return false;
    const value = switch (relaxed) {
        .pc_relative => target.address + entry.addend - place,
        .absolute_signed_32 => target.address + entry.addend + 4,
    };
    writeU32(payload, offset, @bitCast(try checked.checkedI32(value)));
    return true;
}

fn directRelocationOffset(payload: []const u8, entry: Rela, write_size: u64) ?usize {
    if (entry.offset > payload.len or write_size > payload.len - entry.offset) return null;
    return @intCast(entry.offset);
}

fn directRelocationTarget(
    context: *const DirectRelocationContext,
    object: ObjectFile,
    recorded_index: usize,
    symbol_index: usize,
) ?DirectRelocationTarget {
    if (symbol_index >= object.symbols.len) return null;
    const symbol = object.symbols[symbol_index];
    if (symbol.isUndefined()) {
        return context.externalTarget(symbol.name) orelse if (symbol.isWeakUndefined()) .{
            .address = 0,
            .size = 0,
        } else null;
    }
    if (!directSymbolBindingProven(symbol)) return null;
    if (symbol.isAbsolute()) return .{
        .address = @as(i64, @bitCast(symbol.value)),
        .size = symbol.size,
    };
    if (symbol.isCommon()) {
        const contribution = context.contributionForSymbol(object.name, recorded_index, symbol_index) orelse return null;
        return .{
            .address = @intCast(contribution.address),
            .size = symbol.size,
        };
    }
    if (context.contributionForSection(object.name, recorded_index, symbol.section_index)) |contribution| {
        return .{
            .address = @as(i128, @intCast(contribution.address)) + @as(i128, @intCast(symbol.value)),
            .size = symbol.size,
        };
    }
    const piece_address = context.mergePieceAddress(object.name, recorded_index, symbol.section_index, symbol.value) orelse return null;
    return .{
        .address = piece_address,
        .size = symbol.size,
    };
}

fn directSymbolBindingProven(symbol: Symbol) bool {
    return symbol.binding() == std.elf.STB_LOCAL or format.symbolBindingIsExternalDefinition(symbol.binding());
}

const DirectExternalMap = std.StringHashMapUnmanaged(DirectRelocationTarget);

const DirectArchiveMemberRecord = struct {
    member: archive.Member,
    ambiguous: bool = false,
};

const DirectArchiveMemberMap = std.StringHashMapUnmanaged(DirectArchiveMemberRecord);

const DirectArchiveMemberIndex = struct {
    members: DirectArchiveMemberMap = .{},

    fn init(allocator: Allocator, members: []const archive.Member) Allocator.Error!DirectArchiveMemberIndex {
        var index: DirectArchiveMemberIndex = .{};
        errdefer index.deinit(allocator);
        try index.members.ensureTotalCapacity(allocator, @intCast(members.len));
        for (members) |member| {
            const gop = index.members.getOrPutAssumeCapacity(member.name);
            if (gop.found_existing) {
                gop.value_ptr.ambiguous = true;
            } else {
                gop.value_ptr.* = .{ .member = member };
            }
        }
        return index;
    }

    fn deinit(self: *DirectArchiveMemberIndex, allocator: Allocator) void {
        self.members.deinit(allocator);
        self.* = .{};
    }

    fn uniqueMember(self: DirectArchiveMemberIndex, name: []const u8) ?archive.Member {
        const indexed = self.members.get(name) orelse return null;
        if (indexed.ambiguous) return null;
        return indexed.member;
    }
};

const DirectContributionKey = struct {
    input_name: []const u8,
    input_index: usize,
    kind: ContributionKind,
    ordinal: u32,

    fn fromContribution(manifest: Manifest, contribution: ContributionRecord) DirectContributionKey {
        return .{
            .input_name = manifest.string(contribution.input_name_id),
            .input_index = @intCast(contribution.input_index),
            .kind = contribution.kind,
            .ordinal = contribution.ordinal,
        };
    }

    fn section(input_name: []const u8, input_index: usize, section_index: u16) DirectContributionKey {
        return .{
            .input_name = input_name,
            .input_index = input_index,
            .kind = .section,
            .ordinal = section_index,
        };
    }

    fn common(input_name: []const u8, input_index: usize, symbol_index: u32) DirectContributionKey {
        return .{
            .input_name = input_name,
            .input_index = input_index,
            .kind = .common_symbol,
            .ordinal = symbol_index,
        };
    }
};

const DirectContributionKeyContext = struct {
    pub fn hash(_: DirectContributionKeyContext, key: DirectContributionKey) u64 {
        var hasher = std.hash.Wyhash.init(0x544c445244495245);
        hashBytes(&hasher, key.input_name);
        hashU64(&hasher, key.input_index);
        hashU8(&hasher, @backingInt(key.kind));
        hashU64(&hasher, key.ordinal);
        return hasher.final();
    }

    pub fn eql(_: DirectContributionKeyContext, a: DirectContributionKey, b: DirectContributionKey) bool {
        return a.input_index == b.input_index and
            a.kind == b.kind and
            a.ordinal == b.ordinal and
            std.mem.eql(u8, a.input_name, b.input_name);
    }
};

const direct_contribution_key_context = DirectContributionKeyContext{};
const DirectContributionMap = std.HashMapUnmanaged(DirectContributionKey, usize, DirectContributionKeyContext, 80);

const DirectInputKey = struct {
    input_name: []const u8,
    input_index: usize,

    fn fromContribution(manifest: Manifest, contribution: ContributionRecord) DirectInputKey {
        return .{
            .input_name = manifest.string(contribution.input_name_id),
            .input_index = @intCast(contribution.input_index),
        };
    }

    fn init(input_name: []const u8, input_index: usize) DirectInputKey {
        return .{
            .input_name = input_name,
            .input_index = input_index,
        };
    }
};

const DirectInputKeyContext = struct {
    pub fn hash(_: DirectInputKeyContext, key: DirectInputKey) u64 {
        var hasher = std.hash.Wyhash.init(0x544c445244494e50);
        hashBytes(&hasher, key.input_name);
        hashU64(&hasher, key.input_index);
        return hasher.final();
    }

    pub fn eql(_: DirectInputKeyContext, a: DirectInputKey, b: DirectInputKey) bool {
        return a.input_index == b.input_index and std.mem.eql(u8, a.input_name, b.input_name);
    }
};

const direct_input_key_context = DirectInputKeyContext{};

const DirectOrdinalKey = struct {
    input_name: []const u8,
    input_index: usize,
    ordinal: u32,
};

const DirectOrdinalKeyContext = struct {
    pub fn hash(_: DirectOrdinalKeyContext, key: DirectOrdinalKey) u64 {
        var hasher = std.hash.Wyhash.init(0x544c44524f52444e);
        hashBytes(&hasher, key.input_name);
        hashU64(&hasher, key.input_index);
        hashU64(&hasher, key.ordinal);
        return hasher.final();
    }

    pub fn eql(_: DirectOrdinalKeyContext, a: DirectOrdinalKey, b: DirectOrdinalKey) bool {
        return a.input_index == b.input_index and
            a.ordinal == b.ordinal and
            std.mem.eql(u8, a.input_name, b.input_name);
    }
};

const direct_ordinal_key_context = DirectOrdinalKeyContext{};
const DirectOrdinalValueMap = std.HashMapUnmanaged(DirectOrdinalKey, u64, DirectOrdinalKeyContext, 80);
const DirectOrdinalSliceMap = std.HashMapUnmanaged(DirectOrdinalKey, []const incremental.MergePieceRecord, DirectOrdinalKeyContext, 80);
const DirectInputContributionMap = std.HashMapUnmanaged(DirectInputKey, std.ArrayListUnmanaged(usize), DirectInputKeyContext, 80);

const ProvenInputTask = struct {
    recorded_index: usize,
    current_index: usize,
    proven: bool = true,
    member_updates: std.ArrayListUnmanaged(incremental.MemberHashUpdate) = .empty,
};

const ProvenInputFanout = struct {
    context: *DirectRelocationContext,
    allocator: Allocator,
    manifest: Manifest,
    inputs: []const model.Input,
    options: model.LinkOptions,
    tasks: []ProvenInputTask,
    out_of_memory: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *ProvenInputFanout, worker: usize, item: usize) void {
        _ = worker;
        if (item == 0) {
            self.context.seedExternalTargets(self.allocator, self.manifest.external_targets) catch {
                self.out_of_memory.store(true, .monotonic);
            };
            return;
        }
        const task = &self.tasks[item - 1];
        const input = self.inputs[task.current_index];
        const result = if (archive.isArchive(input.bytes))
            self.context.addProvenArchive(self.allocator, self.manifest, input, task.recorded_index, self.options, &task.member_updates)
        else
            self.context.addProvenObjectInput(self.allocator, self.manifest, input, task.recorded_index, self.options);
        if (result) |proven| {
            task.proven = proven;
        } else |err| {
            if (err == error.OutOfMemory) self.out_of_memory.store(true, .monotonic);
            task.proven = false;
        }
    }
};

const DirectRelocationContext = struct {
    manifest: Manifest,
    contributions: []const ContributionRecord,
    changed_inputs: []const bool,
    contribution_indexes: DirectContributionMap = .{},
    input_contribution_indexes: DirectInputContributionMap = .{},
    proven_input_objects: []std.ArrayListUnmanaged(ObjectFile) = &.{},
    proven_unchanged_members: []std.ArrayListUnmanaged([]const u8) = &.{},
    member_updates: std.ArrayListUnmanaged(incremental.MemberHashUpdate) = .empty,
    externals: DirectExternalMap = .{},
    got_named: std.StringHashMapUnmanaged(u64) = .{},
    got_local: DirectOrdinalValueMap = .{},
    merge_piece_groups: DirectOrdinalSliceMap = .{},

    fn init(
        allocator: Allocator,
        manifest: Manifest,
        changed_inputs: []const bool,
    ) Allocator.Error!DirectRelocationContext {
        const contributions = manifest.contributions;
        var context = DirectRelocationContext{
            .manifest = manifest,
            .contributions = contributions,
            .changed_inputs = changed_inputs,
        };
        errdefer context.deinit(allocator);
        var changed_count: usize = 0;
        for (contributions) |contribution| {
            if (context.inputChanged(contribution.input_index)) changed_count += 1;
        }
        try context.contribution_indexes.ensureTotalCapacity(allocator, @intCast(changed_count));
        try context.input_contribution_indexes.ensureTotalCapacity(allocator, @intCast(changed_count));
        for (contributions, 0..) |contribution, contribution_index| {
            if (!context.inputChanged(contribution.input_index)) continue;
            const gop = context.contribution_indexes.getOrPutAssumeCapacityContext(
                DirectContributionKey.fromContribution(manifest, contribution),
                direct_contribution_key_context,
            );
            if (!gop.found_existing) gop.value_ptr.* = contribution_index;
            try context.addInputContributionIndex(allocator, contribution, contribution_index);
        }
        return context;
    }

    fn inputChanged(self: *const DirectRelocationContext, input_index: u64) bool {
        return input_index < self.changed_inputs.len and self.changed_inputs[@intCast(input_index)];
    }

    fn deinit(self: *DirectRelocationContext, allocator: Allocator) void {
        var input_iterator = self.input_contribution_indexes.iterator();
        while (input_iterator.next()) |entry| entry.value_ptr.deinit(allocator);
        for (self.proven_input_objects) |*objects| {
            for (objects.items) |*object| object.deinit(allocator);
            objects.deinit(allocator);
        }
        if (self.proven_input_objects.len != 0) allocator.free(self.proven_input_objects);
        for (self.proven_unchanged_members) |*members| members.deinit(allocator);
        if (self.proven_unchanged_members.len != 0) allocator.free(self.proven_unchanged_members);
        self.member_updates.deinit(allocator);
        self.contribution_indexes.deinit(allocator);
        self.input_contribution_indexes.deinit(allocator);
        self.externals.deinit(allocator);
        self.got_named.deinit(allocator);
        self.got_local.deinit(allocator);
        self.merge_piece_groups.deinit(allocator);
        self.* = .{ .manifest = Manifest.empty(), .contributions = &.{}, .changed_inputs = &.{} };
    }

    fn addInputContributionIndex(
        self: *DirectRelocationContext,
        allocator: Allocator,
        contribution: ContributionRecord,
        contribution_index: usize,
    ) Allocator.Error!void {
        const gop = self.input_contribution_indexes.getOrPutAssumeCapacityContext(
            DirectInputKey.fromContribution(self.manifest, contribution),
            direct_input_key_context,
        );
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, contribution_index);
    }

    fn seedExternalTargets(
        self: *DirectRelocationContext,
        allocator: Allocator,
        external_targets: []const incremental.ExternalTargetRecord,
    ) Allocator.Error!void {
        try self.externals.ensureTotalCapacity(allocator, std.math.cast(u32, external_targets.len) orelse return error.OutOfMemory);
        for (external_targets) |record| {
            self.externals.putAssumeCapacity(self.manifest.string(record.name_id), .{
                .address = record.address(),
                .size = record.size,
            });
        }
    }

    fn seedGotEntries(
        self: *DirectRelocationContext,
        allocator: Allocator,
        got_entries: []const incremental.GotEntryRecord,
    ) Allocator.Error!void {
        for (got_entries) |record| {
            const name = self.manifest.string(record.name_id);
            if (name.len != 0) {
                try self.got_named.put(allocator, name, record.address);
                continue;
            }
            if (!self.inputChanged(record.input_index)) continue;
            try self.got_local.putContext(allocator, .{
                .input_name = self.manifest.string(record.input_name_id),
                .input_index = @intCast(record.input_index),
                .ordinal = record.ordinal,
            }, record.address, direct_ordinal_key_context);
        }
    }

    fn seedMergePieces(
        self: *DirectRelocationContext,
        allocator: Allocator,
        merge_pieces: []const incremental.MergePieceRecord,
    ) Allocator.Error!void {
        var group_start: usize = 0;
        for (merge_pieces, 0..) |piece, piece_index| {
            const start_piece = merge_pieces[group_start];
            if (piece.input_index == start_piece.input_index and
                piece.ordinal == start_piece.ordinal and
                piece.input_name_id == start_piece.input_name_id) continue;
            try self.addMergePieceGroup(allocator, merge_pieces[group_start..piece_index]);
            group_start = piece_index;
        }
        if (group_start < merge_pieces.len) {
            try self.addMergePieceGroup(allocator, merge_pieces[group_start..]);
        }
    }

    fn addMergePieceGroup(
        self: *DirectRelocationContext,
        allocator: Allocator,
        group: []const incremental.MergePieceRecord,
    ) Allocator.Error!void {
        const first = group[0];
        if (!self.inputChanged(first.input_index)) return;
        try self.merge_piece_groups.putContext(allocator, .{
            .input_name = self.manifest.string(first.input_name_id),
            .input_index = @intCast(first.input_index),
            .ordinal = first.ordinal,
        }, group, direct_ordinal_key_context);
    }

    fn gotSlotAddress(
        self: *const DirectRelocationContext,
        object: ObjectFile,
        recorded_index: usize,
        symbol_index: usize,
    ) ?u64 {
        if (symbol_index >= object.symbols.len) return null;
        const symbol = object.symbols[symbol_index];
        if ((symbol.isUndefined() or symbol.isCommon()) and symbol.name.len != 0) {
            return self.got_named.get(symbol.name);
        }
        if (symbol.name.len != 0) {
            if (self.got_named.get(symbol.name)) |address| return address;
        }
        const ordinal = std.math.cast(u32, symbol_index) orelse return null;
        return self.got_local.getContext(.{
            .input_name = object.name,
            .input_index = recorded_index,
            .ordinal = ordinal,
        }, direct_ordinal_key_context);
    }

    fn mergePieceAddress(
        self: *const DirectRelocationContext,
        input_name: []const u8,
        input_index: usize,
        section_index: u16,
        offset: u64,
    ) ?u64 {
        const group = self.merge_piece_groups.getContext(.{
            .input_name = input_name,
            .input_index = input_index,
            .ordinal = section_index,
        }, direct_ordinal_key_context) orelse return null;
        for (group) |piece| {
            if (offset < piece.input_offset) continue;
            if (offset >= piece.input_offset + piece.size) continue;
            return piece.address + (offset - piece.input_offset);
        }
        return null;
    }

    fn addProvenInputs(
        self: *DirectRelocationContext,
        allocator: Allocator,
        manifest: Manifest,
        inputs: []const model.Input,
        input_changes: InputChanges,
        options: model.LinkOptions,
    ) model.Error!bool {
        if (input_changes.summary.changed != 0) try self.ensureProvenInputObjects(allocator, manifest.inputs.len);

        var changed_inputs_proven = true;
        var proving = std.ArrayListUnmanaged(ProvenInputTask).empty;
        defer {
            for (proving.items) |*task| task.member_updates.deinit(allocator);
            proving.deinit(allocator);
        }
        for (input_changes.changes) |change| {
            if (change.kind != .changed) continue;
            const recorded_index = change.recorded_index orelse {
                changed_inputs_proven = false;
                continue;
            };
            const current_index = change.current_index orelse {
                changed_inputs_proven = false;
                continue;
            };
            if (recorded_index >= manifest.inputs.len or current_index >= inputs.len) {
                changed_inputs_proven = false;
                continue;
            }
            try proving.append(allocator, .{
                .recorded_index = recorded_index,
                .current_index = current_index,
            });
        }

        var locked = allocators.LockedAllocator.init(allocator);
        var fanout = ProvenInputFanout{
            .context = self,
            .allocator = locked.allocator(),
            .manifest = manifest,
            .inputs = inputs,
            .options = options,
            .tasks = proving.items,
        };
        parallel.forItems(proving.items.len + 1, options.max_link_jobs, &fanout, ProvenInputFanout.run);
        if (fanout.out_of_memory.load(.monotonic)) return error.OutOfMemory;

        for (proving.items) |*task| {
            try self.member_updates.appendSlice(allocator, task.member_updates.items);
            if (!task.proven) changed_inputs_proven = false;
        }
        return changed_inputs_proven;
    }

    fn addProvenObjectInput(
        self: *DirectRelocationContext,
        allocator: Allocator,
        manifest: Manifest,
        input: model.Input,
        recorded_index: usize,
        options: model.LinkOptions,
    ) model.Error!bool {
        var object = parser.parseObjectWithOptions(allocator, input, .{
            .strip_debug = options.strip_debug,
            .worker_budget = options.max_link_jobs,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        var owns_object = true;
        defer if (owns_object) object.deinit(allocator);
        if ((try inputLinkHashForObject(object)) != manifest.inputs[recorded_index].link_hash) return false;
        if (try self.addProvenObject(allocator, recorded_index, object)) owns_object = false;
        return true;
    }

    fn addProvenArchive(
        self: *DirectRelocationContext,
        allocator: Allocator,
        manifest: Manifest,
        input: model.Input,
        recorded_index: usize,
        options: model.LinkOptions,
        member_updates: *std.ArrayListUnmanaged(incremental.MemberHashUpdate),
    ) model.Error!bool {
        var parsed = archive.parseDetailed(allocator, input) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer parsed.deinit(allocator);
        if (manifest.inputs[recorded_index].selection_hash != structuralSelectionHash(parsed)) return false;

        var member_index = try DirectArchiveMemberIndex.init(allocator, parsed.members);
        defer member_index.deinit(allocator);

        var objects = std.ArrayListUnmanaged(ObjectFile).empty;
        var transferred_objects = false;
        defer {
            if (!transferred_objects) for (objects.items) |*object| object.deinit(allocator);
            objects.deinit(allocator);
        }

        for (manifest.archive_members, 0..) |record, record_index| {
            if (record.input_index != recorded_index) continue;
            const record_name = manifest.string(record.name_id);
            const member = member_index.uniqueMember(record_name) orelse return false;
            const member_hash = incremental.hashBytes(member.bytes);
            if (!record.selected) {
                if (member_hash != record.hash) return false;
                continue;
            }
            if (member_hash == record.hash) {
                try self.addProvenUnchangedMember(allocator, recorded_index, record_name);
                continue;
            }
            var object = parser.parseObjectWithOptions(allocator, .{
                .name = member.name,
                .bytes = member.bytes,
            }, .{
                .strip_debug = options.strip_debug,
                .worker_budget = options.max_link_jobs,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
            errdefer object.deinit(allocator);
            const member_link_hash = linkageHash(object) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    object.deinit(allocator);
                    return false;
                },
            };
            if (member_link_hash != record.link_hash) {
                object.deinit(allocator);
                return false;
            }
            object.input_index = recorded_index;
            try member_updates.append(allocator, .{ .member_index = record_index, .hash = member_hash });
            try objects.append(allocator, object);
        }

        if (objects.items.len == 0) return true;
        if (try self.addProvenObjects(allocator, recorded_index, objects.items)) transferred_objects = true;
        return true;
    }

    fn ensureProvenInputObjects(
        self: *DirectRelocationContext,
        allocator: Allocator,
        input_count: usize,
    ) Allocator.Error!void {
        if (input_count > self.proven_input_objects.len) {
            const proven_input_objects = try allocator.alloc(std.ArrayListUnmanaged(ObjectFile), input_count);
            @memset(proven_input_objects, .empty);
            for (self.proven_input_objects, 0..) |objects, input_index| proven_input_objects[input_index] = objects;
            if (self.proven_input_objects.len != 0) allocator.free(self.proven_input_objects);
            self.proven_input_objects = proven_input_objects;
        }
        if (input_count > self.proven_unchanged_members.len) {
            const proven_unchanged_members = try allocator.alloc(std.ArrayListUnmanaged([]const u8), input_count);
            @memset(proven_unchanged_members, .empty);
            for (self.proven_unchanged_members, 0..) |members, input_index| proven_unchanged_members[input_index] = members;
            if (self.proven_unchanged_members.len != 0) allocator.free(self.proven_unchanged_members);
            self.proven_unchanged_members = proven_unchanged_members;
        }
    }

    fn addProvenUnchangedMember(
        self: *DirectRelocationContext,
        allocator: Allocator,
        input_index: usize,
        member_name: []const u8,
    ) Allocator.Error!void {
        if (input_index >= self.proven_unchanged_members.len) return;
        try self.proven_unchanged_members[input_index].append(allocator, member_name);
    }

    fn addProvenObject(
        self: *DirectRelocationContext,
        allocator: Allocator,
        input_index: usize,
        object: ObjectFile,
    ) Allocator.Error!bool {
        if (input_index >= self.proven_input_objects.len) return false;
        try self.proven_input_objects[input_index].append(allocator, object);
        return true;
    }

    fn addProvenObjects(
        self: *DirectRelocationContext,
        allocator: Allocator,
        input_index: usize,
        objects: []const ObjectFile,
    ) Allocator.Error!bool {
        if (input_index >= self.proven_input_objects.len) return false;
        try self.proven_input_objects[input_index].appendSlice(allocator, objects);
        return true;
    }

    fn appendProvenInputReplacements(
        self: *const DirectRelocationContext,
        allocator: Allocator,
        replacements: *std.ArrayListUnmanaged(ReplacementContribution),
        input_index: usize,
    ) model.Error!void {
        if (input_index < self.proven_unchanged_members.len) {
            for (self.proven_unchanged_members[input_index].items) |member_name| {
                try self.appendUnchangedMemberReplacements(allocator, replacements, member_name, input_index);
            }
        }
        if (input_index >= self.proven_input_objects.len) return;
        for (self.proven_input_objects[input_index].items) |object| {
            try appendInputReplacements(allocator, replacements, self, object, input_index);
        }
    }

    fn appendUnchangedMemberReplacements(
        self: *const DirectRelocationContext,
        allocator: Allocator,
        replacements: *std.ArrayListUnmanaged(ReplacementContribution),
        member_name: []const u8,
        input_index: usize,
    ) model.Error!void {
        for (self.contributionIndexesForInputName(member_name, input_index)) |contribution_index| {
            if (contribution_index >= self.contributions.len) continue;
            const contribution = self.contributions[contribution_index];
            if (contribution.input_index != input_index or !std.mem.eql(u8, self.manifest.string(contribution.input_name_id), member_name)) continue;
            try replacements.append(allocator, .{
                .input_name = self.manifest.string(contribution.input_name_id),
                .input_index = @intCast(contribution.input_index),
                .kind = contribution.kind,
                .name = self.manifest.string(contribution.name_id),
                .ordinal = contribution.ordinal,
                .size = contribution.size,
                .alignment = contribution.alignment,
                .output_section_name = self.manifest.string(contribution.output_section_name_id),
                .address = contribution.address,
                .file_offset = contribution.file_offset,
                .reserved_size = contribution.reserved_size,
                .unchanged = true,
            });
        }
    }

    fn externalTarget(self: *const DirectRelocationContext, name: []const u8) ?DirectRelocationTarget {
        return self.externals.get(name);
    }

    fn contributionIndexesForInputName(
        self: *const DirectRelocationContext,
        input_name: []const u8,
        input_index: usize,
    ) []const usize {
        const indexes = self.input_contribution_indexes.getContext(
            DirectInputKey.init(input_name, input_index),
            direct_input_key_context,
        ) orelse return &.{};
        return indexes.items;
    }

    fn contributionForSection(
        self: *const DirectRelocationContext,
        input_name: []const u8,
        input_index: usize,
        section_index: u16,
    ) ?ContributionRecord {
        return self.contributionForKey(DirectContributionKey.section(input_name, input_index, section_index));
    }

    fn contributionForSymbol(
        self: *const DirectRelocationContext,
        input_name: []const u8,
        input_index: usize,
        symbol_index: usize,
    ) ?ContributionRecord {
        const ordinal = std.math.cast(u32, symbol_index) orelse return null;
        return self.contributionForKey(DirectContributionKey.common(input_name, input_index, ordinal));
    }

    fn contributionForKey(self: *const DirectRelocationContext, key: DirectContributionKey) ?ContributionRecord {
        const contribution_index = self.contribution_indexes.getContext(
            key,
            direct_contribution_key_context,
        ) orelse return null;
        if (contribution_index >= self.contributions.len) return null;
        const contribution = self.contributions[contribution_index];
        if (!direct_contribution_key_context.eql(key, DirectContributionKey.fromContribution(self.manifest, contribution))) return null;
        return contribution;
    }
};

fn changedInputFilterAlloc(
    allocator: Allocator,
    manifest: Manifest,
    input_changes: InputChanges,
) Allocator.Error![]bool {
    const changed = try allocator.alloc(bool, manifest.inputs.len);
    @memset(changed, false);
    for (input_changes.changes) |change| {
        if (change.kind != .changed) continue;
        const recorded_index = change.recorded_index orelse continue;
        if (recorded_index >= changed.len) continue;
        changed[recorded_index] = true;
    }
    return changed;
}

fn inputLinkHashForObject(object: ObjectFile) model.Error!u64 {
    var state = InputLinkHashState.init();
    try state.update(object);
    return state.final();
}

fn selectionHashForInput(allocator: Allocator, input: model.Input) model.Error!u64 {
    var parsed = archive.parseDetailed(allocator, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return incremental.hashBytes(input.bytes),
    };
    defer parsed.deinit(allocator);
    return structuralSelectionHash(parsed);
}

fn structuralSelectionHash(parsed: archive.ParsedArchive) u64 {
    var hasher = std.hash.Wyhash.init(0x544c445241524348);
    hashU8(&hasher, if (parsed.has_symbol_index) 1 else 0);
    hashU64(&hasher, parsed.symbol_index.len);
    for (parsed.symbol_index) |entry| {
        hashBytes(&hasher, entry.name);
        hashU64(&hasher, memberOrdinalByOffset(parsed.members, entry.member_offset) orelse std.math.maxInt(u64));
    }
    hashU64(&hasher, parsed.members.len);
    for (parsed.members) |member| hashBytes(&hasher, member.name);
    return hasher.final();
}

fn memberOrdinalByOffset(members: []const archive.Member, offset: u64) ?u64 {
    var low: usize = 0;
    var high: usize = members.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const member_offset = members[middle].header_offset;
        if (member_offset == offset) return @intCast(middle);
        if (offset < member_offset) {
            high = middle;
        } else {
            low = middle + 1;
        }
    }
    return null;
}

const InputLinkHashState = struct {
    hasher: std.hash.Wyhash,
    count: u64,

    fn init() InputLinkHashState {
        return .{
            .hasher = std.hash.Wyhash.init(0x544c4452494e5055),
            .count = 0,
        };
    }

    fn update(self: *InputLinkHashState, object: ObjectFile) model.Error!void {
        hashBytes(&self.hasher, object.name);
        hashU64(&self.hasher, try linkageHash(object));
        self.count += 1;
    }

    fn final(self: *InputLinkHashState) u64 {
        hashU64(&self.hasher, self.count);
        return self.hasher.final();
    }
};

fn hashSections(hasher: *std.hash.Wyhash, object: ObjectFile) model.Error!void {
    hashU64(hasher, object.sections.len);
    for (object.sections, 0..) |section, section_index| {
        const name = try sectionName(object, section_index);
        hashBytes(hasher, name);
        hashU32(hasher, section.section_type);
        hashU64(hasher, section.flags);
        hashU64(hasher, section.size);
        hashU32(hasher, section.link);
        hashU32(hasher, section.info);
        hashU64(hasher, section.alignment);
        hashU64(hasher, section.entry_size);
        if (!patchablePayloadSection(section, name)) hashBytes(hasher, try sectionBytes(object.bytes, section));
    }
}

fn hashSymbols(hasher: *std.hash.Wyhash, symbols: []const Symbol) void {
    hashU64(hasher, symbols.len);
    for (symbols) |symbol| {
        hashBytes(hasher, symbol.name);
        hashU8(hasher, symbol.info);
        hashU8(hasher, symbol.other);
        hashU16(hasher, symbol.section_index);
        hashU64(hasher, symbol.value);
        hashU64(hasher, symbol.size);
    }
}

fn hashRelocations(hasher: *std.hash.Wyhash, relocations: []const Rela) void {
    hashU64(hasher, relocations.len);
    for (relocations) |entry| {
        hashU64(hasher, entry.offset);
        hashU64(hasher, entry.info);
        hashI64(hasher, entry.addend);
    }
}

fn hashBytes(hasher: *std.hash.Wyhash, bytes: []const u8) void {
    hashU64(hasher, bytes.len);
    hasher.update(bytes);
}

fn hashU8(hasher: *std.hash.Wyhash, value: u8) void {
    hasher.update(&.{value});
}

fn hashU16(hasher: *std.hash.Wyhash, value: u16) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    hasher.update(&bytes);
}

fn hashU32(hasher: *std.hash.Wyhash, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hasher.update(&bytes);
}

fn hashU64(hasher: *std.hash.Wyhash, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hasher.update(&bytes);
}

fn hashI64(hasher: *std.hash.Wyhash, value: i64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, value, .little);
    hasher.update(&bytes);
}

const TestInputClassification = struct {
    bytes: InputChangeStorage.Storage,
    storage: InputChangeStorage,
    changes: InputChanges,

    fn deinit(self: *TestInputClassification, allocator: Allocator) void {
        const bytes = self.storage.deinit();
        std.debug.assert(bytes.ptr == self.bytes.ptr);
        std.debug.assert(bytes.len == self.bytes.len);
        allocator.free(bytes);
    }
};

fn classifyTestInputs(
    allocator: Allocator,
    manifest: Manifest,
    inputs: []const model.Input,
) !TestInputClassification {
    const limits = InputChangeStorage.Limits.inspect(
        RecordedInputs.fromManifest(&manifest),
        inputs,
    );
    const capacity = try InputChangeStorage.Capacity.derive(limits);
    const bytes = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(InputChangeStorage.storage_alignment),
        capacity.storage_bytes,
    );
    errdefer allocator.free(bytes);
    var storage = try InputChangeStorage.init(bytes, limits);
    storage.activate();
    const changes = try storage.classify(RecordedInputs.fromManifest(&manifest), inputs);
    return .{
        .bytes = bytes,
        .storage = storage,
        .changes = changes,
    };
}

/// Builds a relocatable object with one allocated, executable section at
/// alignment 16 that holds `text`, plus the symbols and relocations the caller
/// gives. The relink tests (tests of a later link) build their small old and
/// new objects with it. That section has file index 1, so a symbol list starts
/// with `ObjectSymbol.section(1)` and later entries take indices from 2.
fn relocatedTextObject(
    allocator: Allocator,
    name: []const u8,
    text: []const u8,
    symbols: []const ObjectSymbol,
    relocations: []const ObjectRelocation,
) ![]u8 {
    const sections = [_]ObjectSection{
        ObjectSection.progbits(name, text, std.elf.SHF_EXECINSTR, 16),
    };
    return try buildObject(allocator, .{
        .sections = &sections,
        .symbols = symbols,
        .relocations = relocations,
    });
}

/// Calls `relocatedTextObject` with an empty relocation list. The relink tests
/// use it for objects that need no relocation.
fn textObject(
    allocator: Allocator,
    name: []const u8,
    text: []const u8,
    symbols: []const ObjectSymbol,
) ![]u8 {
    return try relocatedTextObject(allocator, name, text, symbols, &.{});
}

fn twoCallArchiveMember(allocator: Allocator, symbol: []const u8, section: []const u8, text: []const u8) ![]u8 {
    return try textObject(allocator, section, text, &.{
        ObjectSymbol.section(1),
        ObjectSymbol.function(symbol, 1, 0, text.len),
    });
}

fn metadataContributionPresent(
    manifest: incremental.Manifest,
    input_name: []const u8,
    contribution_name: []const u8,
    ordinal: u16,
) bool {
    for (manifest.contributions) |contribution| {
        if (contribution.kind != .section) continue;
        if (!std.mem.eql(u8, manifest.string(contribution.input_name_id), input_name)) continue;
        if (!std.mem.eql(u8, manifest.string(contribution.name_id), contribution_name)) continue;
        if (contribution.ordinal != ordinal) continue;
        return true;
    }
    return false;
}
