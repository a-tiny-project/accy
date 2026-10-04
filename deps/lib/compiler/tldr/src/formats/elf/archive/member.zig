const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const prefetch = @import("prefetch.zig");

const Allocator = std.mem.Allocator;
const archive_format = root.archive;
const model = root.model;
const trace = root.trace;
const ObjectParseOptions = elf.parser.ObjectParseOptions;
const ObjectSelectionSummary = elf.parser.ObjectSelectionSummary;
const isElf = elf.format.isElf;
const parseObjectWithOptions = elf.parser.parseObjectWithOptions;

pub fn addCandidates(
    allocator: Allocator,
    selection: Allocator,
    input: model.Input,
    input_index: usize,
    state: anytype,
    parse_options: ObjectParseOptions,
    prefetched: ?prefetch.Prefetched,
) model.Error!void {
    const parsed = if (prefetched) |ready| ready.parsed else parse_table: {
        const table_phase = trace.product(.archive_table_parse);
        defer table_phase.end();
        break :parse_table try archive_format.parseDetailed(selection, input);
    };

    if (!parsed.has_symbol_index) {
        const first_candidate_index = state.candidates.items.len;
        try buildScannedCandidates(allocator, input.name, input_index, parsed.members, state, parse_options);
        try indexDefinitionsFromObjects(
            allocator,
            state,
            first_candidate_index,
        );
    } else {
        const indexing_phase = trace.product(.archive_definition_indexing);
        defer indexing_phase.end();
        try buildIndexedCandidates(
            allocator,
            input.name,
            input_index,
            parsed.members,
            parsed.symbol_index,
            state,
            if (prefetched) |ready| ready.summaries else &.{},
            if (prefetched) |ready| ready.failures else &.{},
        );
    }
}

fn buildScannedCandidates(
    allocator: Allocator,
    archive_name: []const u8,
    archive_input_index: usize,
    members: []const archive_format.Member,
    state: anytype,
    parse_options: ObjectParseOptions,
) model.Error!void {
    for (members) |member| {
        if (!isElf(member.bytes)) continue;
        var object = try parseObjectWithOptions(allocator, .{
            .name = member.name,
            .bytes = member.bytes,
        }, parse_options);
        object.input_index = archive_input_index;
        errdefer object.deinit(allocator);
        _ = try state.appendCandidate(allocator, .{
            .archive_name = archive_name,
            .archive_input_index = archive_input_index,
            .member = member,
            .object = object,
        });
    }
}

fn buildIndexedCandidates(
    allocator: Allocator,
    archive_name: []const u8,
    archive_input_index: usize,
    members: []const archive_format.Member,
    symbol_index: []const archive_format.SymbolIndexEntry,
    state: anytype,
    summaries: []const ?ObjectSelectionSummary,
    failures: []const ?model.Error,
) model.Error!void {
    try state.candidates.ensureUnusedCapacity(allocator, symbol_index.len);
    try state.active_candidate_counts.ensureUnusedCapacity(allocator, symbol_index.len);
    const definition_capacity = std.math.cast(u32, symbol_index.len) orelse return error.InvalidArchive;
    try state.definitions.ensureUnusedCapacity(allocator, definition_capacity);

    const missing_candidate = std.math.maxInt(usize);
    const candidate_by_member = try allocator.alloc(usize, members.len);
    defer allocator.free(candidate_by_member);
    @memset(candidate_by_member, missing_candidate);

    var offsets_ordered = true;
    var previous_member_offset: u64 = 0;
    var member_cursor: usize = 0;
    for (symbol_index) |entry| {
        if (entry.member_offset < previous_member_offset) offsets_ordered = false;
        previous_member_offset = entry.member_offset;
        const member_index = if (offsets_ordered)
            archive_format.memberIndexByOffsetWithCursor(members, entry.member_offset, &member_cursor) orelse return error.InvalidArchive
        else
            archive_format.memberIndexByOffset(members, entry.member_offset) orelse return error.InvalidArchive;
        var candidate_index = candidate_by_member[member_index];
        if (candidate_index == missing_candidate) {
            candidate_index = state.candidates.items.len;
            candidate_by_member[member_index] = candidate_index;
            state.active_candidate_counts.appendAssumeCapacity(0);
            state.candidates.appendAssumeCapacity(.{
                .archive_name = archive_name,
                .archive_input_index = archive_input_index,
                .member = members[member_index],
                .summary = if (summaries.len != 0) summaries[member_index] else null,
                .summary_failure = if (failures.len != 0) failures[member_index] else null,
            });
        }
        try state.addDefinition(allocator, entry.name, candidate_index);
    }
}

fn indexDefinitionsFromObjects(
    allocator: Allocator,
    state: anytype,
    first_candidate_index: usize,
) model.Error!void {
    for (state.candidates.items[first_candidate_index..], 0..) |candidate, index| {
        const parsed_object = candidate.object orelse return error.InvalidObject;
        for (parsed_object.symbols) |symbol| {
            if (!symbol.isGlobalDefinition()) continue;
            try state.addDefinition(allocator, symbol.name, first_candidate_index + index);
        }
    }
}
