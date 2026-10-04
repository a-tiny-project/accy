const std = @import("std");
const alloc_phase = @import("alloc_phase");
const parent = @import("../root.zig");
const format = @import("format.zig");
const patch = @import("patch.zig");
const model = parent.model;

const Allocator = std.mem.Allocator;

pub const StringSpan = extern struct {
    offset: u32 align(1),
    len: u32 align(1),
};

pub const Strings = struct {
    spans: []const StringSpan = &.{},
    blob: []const u8 = &.{},
    owned: bool = false,
    appendix_spans: std.ArrayListUnmanaged(StringSpan) = .empty,
    appendix: std.ArrayListUnmanaged(u8) = .empty,
    ids: IdMap = .empty,

    const IdMap: type = std.HashMapUnmanaged(u32, void, IdContext, 80);

    const IdContext = struct {
        strings: *const Strings,

        pub fn hash(context: IdContext, id: u32) u64 {
            return std.hash.Wyhash.hash(0, context.strings.get(id));
        }

        pub fn eql(context: IdContext, a: u32, b: u32) bool {
            if (a == b) return true;
            return std.mem.eql(u8, context.strings.get(a), context.strings.get(b));
        }
    };

    const BytesContext = struct {
        strings: *const Strings,

        pub fn hash(context: BytesContext, bytes: []const u8) u64 {
            _ = context;
            return std.hash.Wyhash.hash(0, bytes);
        }

        pub fn eql(context: BytesContext, bytes: []const u8, id: u32) bool {
            return std.mem.eql(u8, bytes, context.strings.get(id));
        }
    };

    pub fn deinit(self: *Strings, allocator: Allocator) void {
        if (self.owned) {
            if (self.spans.len != 0) allocator.free(self.spans);
            if (self.blob.len != 0) allocator.free(self.blob);
        }
        self.appendix_spans.deinit(allocator);
        self.appendix.deinit(allocator);
        self.ids.deinit(allocator);
        self.* = .{};
    }

    pub fn count(self: *const Strings) usize {
        return self.spans.len + self.appendix_spans.items.len;
    }

    pub fn get(self: *const Strings, id: u32) []const u8 {
        if (id < self.spans.len) {
            const span = self.spans[id];
            return self.blob[span.offset..][0..span.len];
        }
        const span = self.appendix_spans.items[id - self.spans.len];
        return self.appendix.items[span.offset..][0..span.len];
    }

    pub fn intern(self: *Strings, allocator: Allocator, bytes: []const u8) Allocator.Error!u32 {
        if (self.ids.size == 0 and self.count() != 0) try self.rebuildIds(allocator);
        const gop = try self.ids.getOrPutContextAdapted(
            allocator,
            bytes,
            BytesContext{ .strings = self },
            IdContext{ .strings = self },
        );
        if (gop.found_existing) return gop.key_ptr.*;
        errdefer self.ids.removeByPtr(gop.key_ptr);

        const id = std.math.cast(u32, self.count()) orelse return error.OutOfMemory;
        const offset = std.math.cast(u32, self.appendix.items.len) orelse return error.OutOfMemory;
        const len = std.math.cast(u32, bytes.len) orelse return error.OutOfMemory;
        try self.appendix.appendSlice(allocator, bytes);
        errdefer self.appendix.shrinkRetainingCapacity(offset);
        try self.appendix_spans.append(allocator, .{ .offset = offset, .len = len });
        gop.key_ptr.* = id;
        return id;
    }

    fn rebuildIds(self: *Strings, allocator: Allocator) Allocator.Error!void {
        const total = std.math.cast(u32, self.count()) orelse return error.OutOfMemory;
        try self.ids.ensureTotalCapacityContext(allocator, total, IdContext{ .strings = self });
        var id: u32 = 0;
        while (id < total) : (id += 1) {
            const gop = self.ids.getOrPutAssumeCapacityContext(id, IdContext{ .strings = self });
            if (!gop.found_existing) gop.key_ptr.* = id;
        }
    }
};

pub const InputRecord = extern struct {
    size: u64 align(1),
    hash: u64 align(1),
    mtime_ns: i64 align(1) = 0,
    inode: u64 align(1) = 0,
    identity_recorded: bool = false,
    _pad: [3]u8 = @splat(0),
    name_id: u32 align(1),
    link_hash: u64 align(1),
    selection_hash: u64 align(1) = 0,
};

pub const SectionRecord = extern struct {
    address: u64 align(1),
    file_offset: u64 align(1),
    size: u64 align(1),
    reserved_size: u64 align(1),
    alignment: u64 align(1),
    name_id: u32 align(1),
};

pub const ContributionKind = enum(u8) {
    section,
    common_symbol,
};

pub const ContributionRecord = extern struct {
    address: u64 align(1),
    file_offset: u64 align(1),
    size: u64 align(1),
    file_size: u64 align(1),
    reserved_size: u64 align(1),
    alignment: u64 align(1),
    input_index: u64 align(1),
    input_name_id: u32 align(1),
    name_id: u32 align(1),
    output_section_name_id: u32 align(1),
    ordinal: u32 align(1),
    kind: ContributionKind,
};

pub const DiscardReason = enum(u8) {
    discarded,
    identical_code_folded,
};

pub const DiscardedContributionRecord = extern struct {
    size: u64 align(1),
    alignment: u64 align(1),
    input_index: u64 align(1),
    input_name_id: u32 align(1),
    name_id: u32 align(1),
    ordinal: u32 align(1),
    reason: DiscardReason,
};

pub const ExternalTargetRecord = extern struct {
    address_bits: u64 align(1),
    size: u64 align(1),
    name_id: u32 align(1),
    address_signed: bool = false,

    pub fn fromResolved(name_id: u32, resolved_address: i128, size: u64) ?ExternalTargetRecord {
        if (resolved_address < 0) {
            const signed = std.math.cast(i64, resolved_address) orelse return null;
            return .{
                .name_id = name_id,
                .address_bits = @bitCast(signed),
                .address_signed = true,
                .size = size,
            };
        }
        return .{
            .name_id = name_id,
            .address_bits = std.math.cast(u64, resolved_address) orelse return null,
            .size = size,
        };
    }

    pub fn address(self: ExternalTargetRecord) i128 {
        if (self.address_signed) return @as(i64, @bitCast(self.address_bits));
        return self.address_bits;
    }
};

pub const ArchiveMemberRecord = extern struct {
    hash: u64 align(1),
    link_hash: u64 align(1) = 0,
    input_index: u64 align(1),
    name_id: u32 align(1),
    selected: bool,
};

pub const GotEntryRecord = extern struct {
    address: u64 align(1),
    input_index: u64 align(1),
    input_name_id: u32 align(1),
    name_id: u32 align(1),
    ordinal: u32 align(1),
};

pub const MergePieceRecord = extern struct {
    input_offset: u64 align(1),
    size: u64 align(1),
    address: u64 align(1),
    input_index: u64 align(1),
    input_name_id: u32 align(1),
    ordinal: u32 align(1),
};

pub const InputChangeKind = enum {
    unchanged,
    changed,
    added,
    removed,
};

pub const InputChange = struct {
    kind: InputChangeKind,
    recorded_index: ?usize = null,
    current_index: ?usize = null,
};

pub const InputChangeSummary = struct {
    unchanged: usize = 0,
    changed: usize = 0,
    added: usize = 0,
    removed: usize = 0,

    pub fn allUnchanged(self: InputChangeSummary) bool {
        return self.changed == 0 and self.added == 0 and self.removed == 0;
    }
};

pub const InputContributionSummary = struct {
    retained: usize = 0,
    discarded: usize = 0,
    retained_size: u64 = 0,
    discarded_size: u64 = 0,

    pub fn isEmpty(self: InputContributionSummary) bool {
        return self.retained == 0 and self.discarded == 0;
    }
};

pub const InputChanges = struct {
    /// The slice carries one record per recorded or current input, each marked
    /// unchanged, changed, added or removed: the recorded inputs come first in
    /// their recorded order, and the added inputs follow in their current
    /// order. The relink planner reads these records to decide whether the
    /// output can be reused or patched during a relink (a later link that
    /// compares its inputs with recorded ones). This slice lives in the
    /// classification storage and stays valid until that storage completes
    /// another classification or is torn down.
    changes: []const InputChange = &.{},
    summary: InputChangeSummary = .{},

    pub fn allUnchanged(self: InputChanges) bool {
        return self.summary.allUnchanged();
    }
};

/// This struct borrows the parts of a manifest (the record a prepared link
/// keeps beside its output) that input classification (matching current inputs
/// to recorded ones by name) reads: the input records, the time the inputs were
/// read, and the string tables that hold input names. Callers build one with
/// `fromManifest` and pass it to `classify`. Classification through this struct
/// allocates nothing. The struct points into the arrays of the manifest, so the
/// instance stays valid only while that manifest is alive and gains no new
/// strings.
pub const RecordedInputs = struct {
    inputs: []const InputRecord,
    inputs_read_at_ns: i64,
    spans: []const StringSpan,
    blob: []const u8,
    appendix_spans: []const StringSpan,
    appendix: []const u8,

    pub fn fromManifest(manifest: *const Manifest) RecordedInputs {
        return .{
            .inputs = manifest.inputs,
            .inputs_read_at_ns = manifest.inputs_read_at_ns,
            .spans = manifest.strings.spans,
            .blob = manifest.strings.blob,
            .appendix_spans = manifest.strings.appendix_spans.items,
            .appendix = manifest.strings.appendix.items,
        };
    }

    pub fn string(self: RecordedInputs, id: u32) []const u8 {
        const string_count = std.math.add(
            usize,
            self.spans.len,
            self.appendix_spans.len,
        ) catch unreachable;
        std.debug.assert(id < string_count);
        if (id < self.spans.len) {
            const span = self.spans[id];
            return self.blob[span.offset..][0..span.len];
        }
        const span = self.appendix_spans[id - self.spans.len];
        return self.appendix[span.offset..][0..span.len];
    }
};

const InputChangeLimits = struct {
    recorded_inputs: usize,
    current_inputs: usize,

    pub fn inspect(recorded: RecordedInputs, current_inputs: []const model.Input) InputChangeLimits {
        return .{
            .recorded_inputs = recorded.inputs.len,
            .current_inputs = current_inputs.len,
        };
    }
};

const InputChangeNameEntry = struct {
    key_index: u32 = no_input_index,
    head_index: u32 = no_input_index,
};

const InputChangeCapacity = struct {
    recorded_inputs: usize,
    current_inputs: usize,
    change_records: usize,
    matched_flags: usize,
    current_links: usize,
    name_slots: usize,
    changes_offset: usize,
    matched_offset: usize,
    links_offset: usize,
    names_offset: usize,
    storage_bytes: usize,

    pub const DeriveError = error{CapacityOverflow};

    pub fn derive(limits: InputChangeLimits) DeriveError!InputChangeCapacity {
        _ = std.math.cast(u32, limits.current_inputs) orelse
            return error.CapacityOverflow;
        const change_records = std.math.add(
            usize,
            limits.recorded_inputs,
            limits.current_inputs,
        ) catch return error.CapacityOverflow;
        const name_slots = try inputChangeNameSlots(limits.current_inputs);
        const changes = try placeInputChangeRegion(InputChange, 0, change_records);
        const matched = try placeInputChangeRegion(bool, changes.end, limits.current_inputs);
        const links = try placeInputChangeRegion(u32, matched.end, limits.current_inputs);
        const names = try placeInputChangeRegion(InputChangeNameEntry, links.end, name_slots);
        return .{
            .recorded_inputs = limits.recorded_inputs,
            .current_inputs = limits.current_inputs,
            .change_records = change_records,
            .matched_flags = limits.current_inputs,
            .current_links = limits.current_inputs,
            .name_slots = name_slots,
            .changes_offset = changes.start,
            .matched_offset = matched.start,
            .links_offset = links.start,
            .names_offset = names.start,
            .storage_bytes = names.end,
        };
    }
};

const InputChangeRegion = struct {
    start: usize,
    end: usize,
};

fn placeInputChangeRegion(
    comptime T: type,
    offset: usize,
    count: usize,
) InputChangeCapacity.DeriveError!InputChangeRegion {
    const mask: usize = @alignOf(T) - 1;
    const padded = std.math.add(usize, offset, mask) catch return error.CapacityOverflow;
    const start = padded & ~mask;
    const bytes = std.math.mul(usize, count, @sizeOf(T)) catch
        return error.CapacityOverflow;
    return .{
        .start = start,
        .end = std.math.add(usize, start, bytes) catch return error.CapacityOverflow,
    };
}

fn inputChangeNameSlots(current_inputs: usize) InputChangeCapacity.DeriveError!usize {
    if (current_inputs == 0) return 0;
    const doubled = std.math.mul(usize, current_inputs, 2) catch
        return error.CapacityOverflow;
    return std.math.ceilPowerOfTwo(usize, doubled) catch error.CapacityOverflow;
}

pub const InputChangeStorage = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: Capacity,
    limits: Limits,
    storage: Storage,
    changes: []InputChange,
    matched_current: []bool,
    current_links: []u32,
    current_by_name: []InputChangeNameEntry,

    pub const storage_alignment: usize = @max(
        @alignOf(InputChange),
        @alignOf(InputChangeNameEntry),
    );
    pub const Storage = []align(storage_alignment) u8;
    pub const Limits: type = InputChangeLimits;
    pub const Capacity: type = InputChangeCapacity;

    pub const Exhaustion = error{InputCountExceedsCapacity};
    pub const InitError = Capacity.DeriveError || error{StorageTooShort};
    pub const work_limits: alloc_phase.capacity.WorkLimits = .{
        .transition_steps_max = std.math.maxInt(usize),
        .cleanup_steps_per_call_max = 0,
        .cleanup_calls_at_capacity_max = 0,
    };

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "tldr.input_change_storage",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "classification_scratch_and_retained_name_index",
                        .lifetime = .steady,
                        .detail = "classification scratch and retained name index",
                    },
                },
                .excluded = &.{
                    "borrowed manifest records, strings, and current input bytes",
                    "downstream replacement, candidate-image, and output storage",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "current_inputs", "current_inputs"),
                    alloc_phase.capacity.bindInput(Limits, "recorded_inputs", "recorded_inputs"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(InputChange, "change"),
                    alloc_phase.capacity.bindType(u32, "u32"),
                    alloc_phase.capacity.bindType(InputChangeNameEntry, "nameslot"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .literal = 2 } } },
                    .{ .next_power_of_two = 1 },
                    .{ .input = 1 },
                    .{ .scale = .{ .node = 3, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .alignment = .{ .node = 4, .alignment = .{ .literal = 16 } } },
                    .{ .alignment = .{ .node = 3, .alignment = .{ .literal = 16 } } },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 1 } } },
                    .{ .alignment = .{ .node = 7, .alignment = .{ .literal = 16 } } },
                    .{ .scale = .{ .node = 2, .coefficient = .{ .size_of_concrete_type = 2 } } },
                    .{ .alignment = .{ .node = 9, .alignment = .{ .literal = 16 } } },
                    .{ .add = .{ .left = 5, .right = 6 } },
                    .{ .add = .{ .left = 11, .right = 8 } },
                    .{ .add = .{ .left = 12, .right = 10 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 13,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "over-capacity input counts preserve the prior result and workspace",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "classification calls only fixed slices, Wyhash, and allocator-free content hashing",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "classification has no callback or operating-system boundary",
                },
            },
            .work = .{ .equation = "linear matching scans current inputs; indexed lookup probes at most name_slots" },
            .obligations = &.{
                .{ .key = "tldr_input_change_capacity_capacity_model", .role = .capacity_model },
                .{ .key = "tldr_input_change_capacity_overload", .role = .overload },
                .{ .key = "tldr_input_change_oom_retry", .role = .custom },
                .{ .key = "tldr_input_change_region", .role = .overload },
                .{ .key = "tldr_input_change_sealed_transitive_risk", .role = .transitive_risk },
                .{ .key = "tldr_input_change_sealed_foreign_risk", .role = .foreign_risk },
                .{ .key = "tldr_input_change_max_plus_one", .role = .overload },
                .{ .key = "tldr_input_change_differential", .role = .work_bound },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    pub fn init(storage: Storage, limits: Limits) InitError!InputChangeStorage {
        const capacity = try Capacity.derive(limits);
        if (storage.len < capacity.storage_bytes) return error.StorageTooShort;
        const owned = storage[0..capacity.storage_bytes];
        return .{
            .phase = .initialization,
            .capacity = capacity,
            .limits = limits,
            .storage = owned,
            .changes = inputChangeSlice(
                InputChange,
                owned,
                capacity.changes_offset,
                capacity.change_records,
            ),
            .matched_current = inputChangeSlice(
                bool,
                owned,
                capacity.matched_offset,
                capacity.matched_flags,
            ),
            .current_links = inputChangeSlice(
                u32,
                owned,
                capacity.links_offset,
                capacity.current_links,
            ),
            .current_by_name = inputChangeSlice(
                InputChangeNameEntry,
                owned,
                capacity.names_offset,
                capacity.name_slots,
            ),
        };
    }

    pub fn activate(self: *InputChangeStorage) void {
        std.debug.assert(self.phase == .initialization);
        self.assertStorage();
        self.phase = .steady;
    }

    /// The call matches `current_inputs` with the recorded inputs by name, in
    /// order, and marks each one unchanged, changed, added or removed. A relink
    /// (a later link that compares its inputs with recorded ones) calls this
    /// function first to learn which inputs changed since the manifest (the
    /// record a prepared link keeps beside its output) was written. An input
    /// counts as unchanged when its size matches and either its file identity
    /// matches or its content hash does. A file identity matches when the
    /// manifest recorded one, the current input carries one, the inode and
    /// modification time are equal, and that modification time is earlier than
    /// the time the recorded inputs were read. The returned view stays valid
    /// until the next successful classification or teardown. When either input
    /// count exceeds what the storage was sized for, the call returns
    /// `error.InputCountExceedsCapacity` and leaves the previous view and the
    /// workspace as they were.
    pub fn classify(
        self: *InputChangeStorage,
        recorded: RecordedInputs,
        current_inputs: []const model.Input,
    ) Exhaustion!InputChanges {
        std.debug.assert(self.phase == .steady);
        if (recorded.inputs.len > self.capacity.recorded_inputs or
            current_inputs.len > self.capacity.current_inputs)
        {
            return error.InputCountExceedsCapacity;
        }
        self.assertStorage();
        if (recorded.inputs.len <= linear_input_classification_limit or
            current_inputs.len <= linear_input_classification_limit)
        {
            return self.classifyLinear(recorded, current_inputs);
        }
        return self.classifyIndexed(recorded, current_inputs);
    }

    pub fn deinit(self: *InputChangeStorage) Storage {
        std.debug.assert(self.phase != .teardown);
        self.assertStorage();
        const storage = self.storage;
        self.phase = .teardown;
        self.storage = &.{};
        self.changes = &.{};
        self.matched_current = &.{};
        self.current_links = &.{};
        self.current_by_name = &.{};
        return storage;
    }

    fn classifyLinear(
        self: *InputChangeStorage,
        recorded_inputs: RecordedInputs,
        current_inputs: []const model.Input,
    ) InputChanges {
        const matched_current = self.matched_current[0..current_inputs.len];
        @memset(matched_current, false);
        var change_count: usize = 0;
        var summary: InputChangeSummary = .{};
        for (recorded_inputs.inputs, 0..) |recorded, recorded_index| {
            const current_index = findUnmatchedInput(
                current_inputs,
                matched_current,
                recorded_inputs.string(recorded.name_id),
            ) orelse {
                self.append(&change_count, &summary, .{
                    .kind = .removed,
                    .recorded_index = recorded_index,
                });
                continue;
            };
            matched_current[current_index] = true;
            const current = current_inputs[current_index];
            self.append(&change_count, &summary, .{
                .kind = if (inputContentUnchanged(
                    recorded,
                    current,
                    recorded_inputs.inputs_read_at_ns,
                )) .unchanged else .changed,
                .recorded_index = recorded_index,
                .current_index = current_index,
            });
        }
        for (matched_current, 0..) |matched, current_index| {
            if (matched) continue;
            self.append(&change_count, &summary, .{
                .kind = .added,
                .current_index = current_index,
            });
        }
        return .{ .changes = self.changes[0..change_count], .summary = summary };
    }

    fn classifyIndexed(
        self: *InputChangeStorage,
        recorded_inputs: RecordedInputs,
        current_inputs: []const model.Input,
    ) InputChanges {
        const matched_current = self.matched_current[0..current_inputs.len];
        @memset(matched_current, false);
        const current_links = self.current_links[0..current_inputs.len];
        @memset(current_links, no_input_index);
        @memset(self.current_by_name, .{});
        var current_index = current_inputs.len;
        while (current_index != 0) {
            current_index -= 1;
            self.pushCurrent(current_inputs, current_links, current_index);
        }

        var change_count: usize = 0;
        var summary: InputChangeSummary = .{};
        for (recorded_inputs.inputs, 0..) |recorded, recorded_index| {
            const matched_index = self.popCurrent(
                current_inputs,
                current_links,
                recorded_inputs.string(recorded.name_id),
            ) orelse {
                self.append(&change_count, &summary, .{
                    .kind = .removed,
                    .recorded_index = recorded_index,
                });
                continue;
            };
            matched_current[matched_index] = true;
            const current = current_inputs[matched_index];
            self.append(&change_count, &summary, .{
                .kind = if (inputContentUnchanged(
                    recorded,
                    current,
                    recorded_inputs.inputs_read_at_ns,
                )) .unchanged else .changed,
                .recorded_index = recorded_index,
                .current_index = matched_index,
            });
        }
        for (matched_current, 0..) |matched, unmatched_index| {
            if (matched) continue;
            self.append(&change_count, &summary, .{
                .kind = .added,
                .current_index = unmatched_index,
            });
        }
        return .{ .changes = self.changes[0..change_count], .summary = summary };
    }

    fn append(
        self: *InputChangeStorage,
        count: *usize,
        summary: *InputChangeSummary,
        change: InputChange,
    ) void {
        std.debug.assert(count.* < self.changes.len);
        self.changes[count.*] = change;
        count.* += 1;
        switch (change.kind) {
            .unchanged => summary.unchanged += 1,
            .changed => summary.changed += 1,
            .added => summary.added += 1,
            .removed => summary.removed += 1,
        }
    }

    fn popCurrent(
        self: *InputChangeStorage,
        current_inputs: []const model.Input,
        current_links: []const u32,
        name: []const u8,
    ) ?usize {
        const entry = self.findCurrent(current_inputs, name) orelse return null;
        const input_index = entry.head_index;
        if (input_index == no_input_index) return null;
        const current_index: usize = @intCast(input_index);
        const next_index = current_links[current_index];
        entry.head_index = next_index;
        return current_index;
    }

    fn pushCurrent(
        self: *InputChangeStorage,
        current_inputs: []const model.Input,
        current_links: []u32,
        input_index: usize,
    ) void {
        const entry = self.findOrCreateCurrent(current_inputs, input_index);
        if (entry.head_index != no_input_index) {
            current_links[input_index] = entry.head_index;
        }
        entry.head_index = @intCast(input_index);
    }

    fn findOrCreateCurrent(
        self: *InputChangeStorage,
        current_inputs: []const model.Input,
        input_index: usize,
    ) *InputChangeNameEntry {
        std.debug.assert(input_index < current_inputs.len);
        const name = current_inputs[input_index].name;
        const slots = self.current_by_name;
        std.debug.assert(slots.len != 0);
        const mask = slots.len - 1;
        const hash: usize = @truncate(std.hash.Wyhash.hash(0, name));
        var slot_index = hash & mask;
        var probes: usize = 0;
        while (probes < slots.len) : (probes += 1) {
            const entry = &slots[slot_index];
            if (entry.key_index == no_input_index) {
                entry.* = .{ .key_index = @intCast(input_index) };
                return entry;
            }
            const key_index: usize = @intCast(entry.key_index);
            if (std.mem.eql(u8, current_inputs[key_index].name, name)) {
                return entry;
            }
            slot_index = (slot_index + 1) & mask;
        }
        unreachable;
    }

    fn findCurrent(
        self: *InputChangeStorage,
        current_inputs: []const model.Input,
        name: []const u8,
    ) ?*InputChangeNameEntry {
        const slots = self.current_by_name;
        if (slots.len == 0) return null;
        const mask = slots.len - 1;
        const hash: usize = @truncate(std.hash.Wyhash.hash(0, name));
        var slot_index = hash & mask;
        var probes: usize = 0;
        while (probes < slots.len) : (probes += 1) {
            const entry = &slots[slot_index];
            if (entry.key_index == no_input_index) return null;
            const key_index: usize = @intCast(entry.key_index);
            if (std.mem.eql(u8, current_inputs[key_index].name, name)) {
                return entry;
            }
            slot_index = (slot_index + 1) & mask;
        }
        return null;
    }

    fn assertStorage(self: *const InputChangeStorage) void {
        const expected = Capacity.derive(self.limits) catch unreachable;
        std.debug.assert(std.meta.eql(expected, self.capacity));
        std.debug.assert(self.storage.len == self.capacity.storage_bytes);
        std.debug.assert(self.changes.len == self.capacity.change_records);
        std.debug.assert(self.matched_current.len == self.capacity.matched_flags);
        std.debug.assert(self.current_links.len == self.capacity.current_links);
        std.debug.assert(self.current_by_name.len == self.capacity.name_slots);
    }
};

comptime {
    alloc_phase.capacity.requireProvisionedRejectingOwnerShape(InputChangeStorage);
}

fn inputChangeSlice(
    comptime T: type,
    storage: InputChangeStorage.Storage,
    offset: usize,
    count: usize,
) []T {
    const byte_count = std.math.mul(usize, count, @sizeOf(T)) catch unreachable;
    const bytes: []align(@alignOf(T)) u8 =
        @alignCast(storage[offset..][0..byte_count]);
    return std.mem.bytesAsSlice(T, bytes);
}

pub const RelinkDecision = enum {
    reuse_output,
    in_place,
    full_link,
};

pub const RelinkBlocker = enum {
    incremental_disabled,
    input_hashes_unrecorded,
    compatibility_mismatch,
    input_changed,
    input_added,
    input_removed,
    input_reordered,
    replacement_missing,
    replacement_not_changed,
    replacement_unpatchable,
    replacement_layout_changed,
    replacement_grew_past_reserve,
    replacement_alignment_increased,
};

pub const RelinkPlan = struct {
    decision: RelinkDecision,
    blocker: ?RelinkBlocker = null,
    blocking_change_index: ?usize = null,
    blocking_replacement_index: ?usize = null,
    input_summary: InputChangeSummary = .{},
    affected_contributions: InputContributionSummary = .{},
};

pub const manifest_binary_protocol = "tldr.incremental-manifest.bin/v10";

pub const ReplacementContribution = patch.ReplacementContribution;
pub const freeReplacementContributions = patch.freeReplacementContributions;
pub const DirectRelinkEvidence = patch.DirectRelinkEvidence;
pub const MemberHashUpdate = patch.MemberHashUpdate;
pub const PatchDecision = patch.PatchDecision;
pub const PatchBlocker = patch.PatchBlocker;
pub const PatchPlan = patch.PatchPlan;
pub const PatchApplication = patch.PatchApplication;
pub const PatchApplyError = patch.PatchApplyError;
pub const IndexError = patch.IndexError;
pub const ContributionIndex = patch.ContributionIndex;

pub const RelinkApplyError = InputChangeStorage.Exhaustion || PatchApplyError;
pub const ReplacementExtractError = Allocator.Error || error{
    PatchRangeOutOfBounds,
};
pub const CandidateRelinkApplyError =
    InputChangeStorage.Exhaustion || ReplacementExtractError || PatchApplyError;
pub const RelinkManifestUpdateError = Allocator.Error || error{
    RelinkUpdateRequiresInPlacePlan,
    ReplacementMissing,
    MemberMissing,
    SectionLayoutChanged,
};
pub const RelinkManifestClassifyError =
    InputChangeStorage.Exhaustion || RelinkManifestUpdateError;

pub const RelinkApplication = struct {
    plan: RelinkPlan,
    contributions_written: usize = 0,
    bytes_written: usize = 0,
    zero_fill_bytes: usize = 0,
};

const replacement_accounting_index_limit = 512;
const sparse_replacement_extraction_change_limit = 32;

pub const RecordOwnership = packed struct {
    inputs: bool = false,
    sections: bool = false,
    contributions: bool = false,
    discarded_contributions: bool = false,
    external_targets: bool = false,
    archive_members: bool = false,
    got_entries: bool = false,
    merge_pieces: bool = false,
};

pub const Manifest = struct {
    target: model.Target,
    output_kind: model.OutputKind,
    entry_symbol_id: u32 = 0,
    image_base: u64,
    page_size: u64,
    gc_sections: bool,
    icf: model.IcfMode,
    strip_debug: bool,
    build_id: model.BuildIdMode,
    input_hashes_recorded: bool,
    inputs_read_at_ns: i64 = 0,
    strings: Strings = .{},
    inputs: []InputRecord = &.{},
    sections: []SectionRecord = &.{},
    contributions: []ContributionRecord = &.{},
    discarded_contributions: []DiscardedContributionRecord = &.{},
    external_targets: []ExternalTargetRecord = &.{},
    archive_members: []ArchiveMemberRecord = &.{},
    got_entries: []GotEntryRecord = &.{},
    merge_pieces: []MergePieceRecord = &.{},
    owned: RecordOwnership = .{},

    pub fn empty() Manifest {
        return .{
            .target = .{},
            .output_kind = .executable,
            .image_base = 0,
            .page_size = 0,
            .gc_sections = false,
            .icf = .off,
            .strip_debug = false,
            .build_id = .none,
            .input_hashes_recorded = false,
        };
    }

    /// Decodes a binary manifest, validating large record sections across up
    /// to `worker_budget` workers, as `LinkOptions.max_link_jobs` defines it.
    pub fn fromBinary(allocator: Allocator, bytes: []u8, worker_budget: usize) !Manifest {
        return try format.manifestFromBinary(allocator, bytes, worker_budget);
    }

    pub fn string(self: *const Manifest, id: u32) []const u8 {
        return self.strings.get(id);
    }

    pub fn entrySymbol(self: *const Manifest) []const u8 {
        if (self.strings.count() == 0) return "";
        return self.strings.get(self.entry_symbol_id);
    }

    pub fn deinit(self: *Manifest, allocator: Allocator) void {
        if (self.owned.inputs and self.inputs.len != 0) allocator.free(self.inputs);
        if (self.owned.sections and self.sections.len != 0) allocator.free(self.sections);
        if (self.owned.contributions and self.contributions.len != 0) allocator.free(self.contributions);
        if (self.owned.discarded_contributions and self.discarded_contributions.len != 0) allocator.free(self.discarded_contributions);
        if (self.owned.external_targets and self.external_targets.len != 0) allocator.free(self.external_targets);
        if (self.owned.archive_members and self.archive_members.len != 0) allocator.free(self.archive_members);
        if (self.owned.got_entries and self.got_entries.len != 0) allocator.free(self.got_entries);
        if (self.owned.merge_pieces and self.merge_pieces.len != 0) allocator.free(self.merge_pieces);
        self.strings.deinit(allocator);
        self.* = empty();
    }

    pub fn take(self: *Manifest) Manifest {
        const manifest = self.*;
        self.* = empty();
        return manifest;
    }

    pub fn canReuseFor(self: Manifest, options: model.LinkOptions, inputs: []const model.Input) bool {
        if (!self.input_hashes_recorded) return false;
        if (!self.canReuseOptions(options)) return false;
        if (self.inputs.len != inputs.len) return false;

        for (inputs, 0..) |input, index| {
            const record = self.inputs[index];
            if (!std.mem.eql(u8, self.string(record.name_id), input.name)) return false;
            if (!inputContentUnchanged(record, input, self.inputs_read_at_ns)) return false;
        }
        return true;
    }

    pub fn canReuseOptions(self: Manifest, options: model.LinkOptions) bool {
        if (options.incremental_mode == .off) return false;
        if (self.target.object_format != options.target.object_format) return false;
        if (self.target.architecture != options.target.architecture) return false;
        if (self.target.endianness != options.target.endianness) return false;
        if (self.target.pointer_width_bits != options.target.pointer_width_bits) return false;
        if (self.output_kind != options.output_kind) return false;
        if (self.image_base != options.image_base) return false;
        if (self.page_size != options.page_size) return false;
        if (self.gc_sections != options.gc_sections) return false;
        if (self.icf != options.icf) return false;
        if (self.strip_debug != options.strip_debug) return false;
        if (self.build_id != options.build_id) return false;
        if (!std.mem.eql(u8, self.entrySymbol(), options.entry_symbol)) return false;
        return true;
    }

    pub fn planContributionReplacement(
        self: Manifest,
        replacements: []const ReplacementContribution,
    ) PatchPlan {
        return patch.planContributionReplacement(self, replacements);
    }

    pub fn applyContributionReplacement(
        self: Manifest,
        image: []u8,
        replacements: []const ReplacementContribution,
    ) PatchApplyError!PatchApplication {
        return try patch.applyContributionReplacement(self, image, replacements);
    }

    pub fn formatTextAlloc(self: Manifest, allocator: Allocator) ![]u8 {
        return try format.textAlloc(self, allocator);
    }

    pub fn scalarPatchesAlloc(
        self: Manifest,
        allocator: Allocator,
        encoded: []const u8,
        input_indexes: []const usize,
        contribution_indexes: []const usize,
        archive_member_indexes: []const usize,
    ) ![]format.ManifestFieldPatch {
        return format.manifestScalarPatchesAlloc(allocator, encoded, self, input_indexes, contribution_indexes, archive_member_indexes);
    }

    pub fn formatBinaryAlloc(self: Manifest, allocator: Allocator) ![]u8 {
        return try format.binaryAlloc(self, allocator);
    }

    pub fn writeBinary(self: Manifest, writer: *std.Io.Writer) !void {
        try format.writeBinary(self, writer);
    }

    pub fn writeText(self: Manifest, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try format.writeText(self, writer);
    }
};

pub const PreparedState = struct {
    manifest: Manifest,
    contribution_index: ?ContributionIndex = null,
    input_contributions: []InputContributionSummary = &.{},

    pub const RecordUpdates = struct {
        input_indexes: std.ArrayListUnmanaged(usize) = .empty,
        contribution_indexes: std.ArrayListUnmanaged(usize) = .empty,
        archive_member_indexes: std.ArrayListUnmanaged(usize) = .empty,

        pub fn deinit(self: *RecordUpdates, allocator: Allocator) void {
            self.input_indexes.deinit(allocator);
            self.contribution_indexes.deinit(allocator);
            self.archive_member_indexes.deinit(allocator);
        }
    };

    pub fn fromOwnedManifest(allocator: Allocator, manifest: Manifest) Allocator.Error!PreparedState {
        var owned_manifest = manifest;
        errdefer owned_manifest.deinit(allocator);

        const input_contributions = try buildInputContributionSummaries(allocator, owned_manifest);
        errdefer if (input_contributions.len != 0) allocator.free(input_contributions);

        return .{
            .manifest = owned_manifest,
            .input_contributions = input_contributions,
        };
    }

    pub fn ensureReplacementIndex(
        self: *PreparedState,
        allocator: Allocator,
        replacements: []const ReplacementContribution,
    ) IndexError!void {
        if (replacements.len == 0) return;
        if (self.contribution_index) |*index| {
            index.deinit(allocator);
            self.contribution_index = null;
        }
        self.contribution_index = try ContributionIndex.initForReplacements(
            allocator,
            self.manifest,
            replacements,
        );
    }

    pub fn deinit(self: *PreparedState, allocator: Allocator) void {
        if (self.contribution_index) |*index| index.deinit(allocator);
        if (self.input_contributions.len != 0) allocator.free(self.input_contributions);
        self.manifest.deinit(allocator);
        self.* = undefined;
    }

    pub fn canReuseFor(self: *const PreparedState, options: model.LinkOptions, inputs: []const model.Input) bool {
        return self.manifest.canReuseFor(options, inputs);
    }

    pub fn classifyInputs(
        self: *const PreparedState,
        storage: *InputChangeStorage,
        inputs: []const model.Input,
    ) InputChangeStorage.Exhaustion!InputChanges {
        return try storage.classify(RecordedInputs.fromManifest(&self.manifest), inputs);
    }

    pub fn contributionSummaryForInput(self: *const PreparedState, recorded_index: usize) InputContributionSummary {
        if (recorded_index >= self.input_contributions.len) return .{};
        return self.input_contributions[recorded_index];
    }

    pub fn contributionSummaryForChange(self: *const PreparedState, change: InputChange) InputContributionSummary {
        const recorded_index = change.recorded_index orelse return .{};
        return self.contributionSummaryForInput(recorded_index);
    }

    fn relinkPreconditionPlan(self: *const PreparedState, options: model.LinkOptions) ?RelinkPlan {
        if (options.incremental_mode == .off) {
            return .{
                .decision = .full_link,
                .blocker = .incremental_disabled,
            };
        }
        if (!self.manifest.input_hashes_recorded) {
            return .{
                .decision = .full_link,
                .blocker = .input_hashes_unrecorded,
            };
        }
        if (!self.manifest.canReuseOptions(options)) {
            return .{
                .decision = .full_link,
                .blocker = .compatibility_mismatch,
            };
        }
        return null;
    }

    pub fn planInputRelink(
        self: *const PreparedState,
        storage: *InputChangeStorage,
        options: model.LinkOptions,
        inputs: []const model.Input,
    ) InputChangeStorage.Exhaustion!RelinkPlan {
        if (self.relinkPreconditionPlan(options)) |plan| return plan;

        const input_changes = try self.classifyInputs(storage, inputs);
        return planRelinkFromInputChangesWithContributions(input_changes, self.input_contributions);
    }

    pub fn planChangedInputRelink(
        self: *const PreparedState,
        storage: *InputChangeStorage,
        options: model.LinkOptions,
        inputs: []const model.Input,
        replacements: []const ReplacementContribution,
    ) InputChangeStorage.Exhaustion!RelinkPlan {
        if (self.relinkPreconditionPlan(options)) |plan| return plan;

        const input_changes = try self.classifyInputs(storage, inputs);
        return self.planChangedInputRelinkFromInputChanges(options, input_changes, replacements);
    }

    pub fn planChangedInputRelinkFromInputChanges(
        self: *const PreparedState,
        options: model.LinkOptions,
        input_changes: InputChanges,
        replacements: []const ReplacementContribution,
    ) RelinkPlan {
        if (self.relinkPreconditionPlan(options)) |plan| return plan;
        return self.planChangedInputRelinkFromChanges(input_changes, replacements);
    }

    fn planChangedInputRelinkFromChanges(
        self: *const PreparedState,
        input_changes: InputChanges,
        replacements: []const ReplacementContribution,
    ) RelinkPlan {
        if (input_changes.summary.added != 0 or input_changes.summary.removed != 0) {
            for (input_changes.changes, 0..) |change, change_index| switch (change.kind) {
                .unchanged, .changed => {},
                .added => return .{
                    .decision = .full_link,
                    .blocker = .input_added,
                    .blocking_change_index = change_index,
                    .input_summary = input_changes.summary,
                },
                .removed => return .{
                    .decision = .full_link,
                    .blocker = .input_removed,
                    .blocking_change_index = change_index,
                    .input_summary = input_changes.summary,
                    .affected_contributions = self.contributionSummaryForChange(change),
                },
            };
        }

        if (inputOrderDriftChangeIndex(input_changes)) |change_index| {
            return .{
                .decision = .full_link,
                .blocker = .input_reordered,
                .blocking_change_index = change_index,
                .input_summary = input_changes.summary,
                .affected_contributions = self.contributionSummaryForChange(input_changes.changes[change_index]),
            };
        }

        if (input_changes.allUnchanged()) {
            if (replacements.len == 0) {
                return .{
                    .decision = .reuse_output,
                    .input_summary = input_changes.summary,
                };
            }
            return self.replacementNotChangedPlan(input_changes, replacements, 0);
        }

        if (input_changes.changes.len <= replacement_accounting_index_limit) {
            return self.planChangedInputRelinkFromIndexedChanges(input_changes, replacements);
        }
        return self.planChangedInputRelinkFromLinearChanges(input_changes, replacements);
    }

    fn planChangedInputRelinkFromLinearChanges(
        self: *const PreparedState,
        input_changes: InputChanges,
        replacements: []const ReplacementContribution,
    ) RelinkPlan {
        var affected: InputContributionSummary = .{};
        for (input_changes.changes, 0..) |change, change_index| {
            switch (change.kind) {
                .unchanged => {},
                .added => return .{
                    .decision = .full_link,
                    .blocker = .input_added,
                    .blocking_change_index = change_index,
                    .input_summary = input_changes.summary,
                },
                .removed => return .{
                    .decision = .full_link,
                    .blocker = .input_removed,
                    .blocking_change_index = change_index,
                    .input_summary = input_changes.summary,
                    .affected_contributions = self.contributionSummaryForChange(change),
                },
                .changed => {
                    const contribution_summary = self.contributionSummaryForChange(change);
                    addInputContributionSummary(&affected, contribution_summary);
                    const recorded_index = change.recorded_index orelse {
                        return .{
                            .decision = .full_link,
                            .blocker = .replacement_missing,
                            .blocking_change_index = change_index,
                            .input_summary = input_changes.summary,
                            .affected_contributions = contribution_summary,
                        };
                    };
                    if (countRetainedReplacementsForInput(replacements, recorded_index) != contribution_summary.retained) {
                        return .{
                            .decision = .full_link,
                            .blocker = .replacement_missing,
                            .blocking_change_index = change_index,
                            .input_summary = input_changes.summary,
                            .affected_contributions = contribution_summary,
                        };
                    }
                },
            }
        }

        if (replacementIndexOutsideChangedInputs(input_changes, replacements)) |replacement_index| {
            return self.replacementNotChangedPlan(input_changes, replacements, replacement_index);
        }

        return self.planReplacementRelinkFromChanges(input_changes, replacements, affected);
    }

    fn planChangedInputRelinkFromIndexedChanges(
        self: *const PreparedState,
        input_changes: InputChanges,
        replacements: []const ReplacementContribution,
    ) RelinkPlan {
        var recorded_change_indexes_storage = @as([replacement_accounting_index_limit]?usize, @splat(null));
        var replacement_counts_storage = @as([replacement_accounting_index_limit]usize, @splat(0));
        const recorded_change_indexes = recorded_change_indexes_storage[0..input_changes.changes.len];
        const replacement_counts = replacement_counts_storage[0..input_changes.changes.len];
        @memset(recorded_change_indexes, null);
        @memset(replacement_counts, 0);

        var affected: InputContributionSummary = .{};
        for (input_changes.changes, 0..) |change, change_index| {
            switch (change.kind) {
                .unchanged => {},
                .added => return .{
                    .decision = .full_link,
                    .blocker = .input_added,
                    .blocking_change_index = change_index,
                    .input_summary = input_changes.summary,
                },
                .removed => return .{
                    .decision = .full_link,
                    .blocker = .input_removed,
                    .blocking_change_index = change_index,
                    .input_summary = input_changes.summary,
                    .affected_contributions = self.contributionSummaryForChange(change),
                },
                .changed => {
                    const contribution_summary = self.contributionSummaryForChange(change);
                    addInputContributionSummary(&affected, contribution_summary);
                    const recorded_index = change.recorded_index orelse {
                        return .{
                            .decision = .full_link,
                            .blocker = .replacement_missing,
                            .blocking_change_index = change_index,
                            .input_summary = input_changes.summary,
                            .affected_contributions = contribution_summary,
                        };
                    };
                    if (recorded_index >= recorded_change_indexes.len) {
                        return .{
                            .decision = .full_link,
                            .blocker = .replacement_missing,
                            .blocking_change_index = change_index,
                            .input_summary = input_changes.summary,
                            .affected_contributions = contribution_summary,
                        };
                    }
                    recorded_change_indexes[recorded_index] = change_index;
                },
            }
        }

        var first_outside_replacement_index: ?usize = null;
        for (replacements, 0..) |replacement, replacement_index| {
            if (replacement.input_index >= recorded_change_indexes.len) {
                if (first_outside_replacement_index == null) first_outside_replacement_index = replacement_index;
                continue;
            }
            const change_index = recorded_change_indexes[replacement.input_index] orelse {
                if (first_outside_replacement_index == null) first_outside_replacement_index = replacement_index;
                continue;
            };
            if (input_changes.changes[change_index].kind != .changed) {
                if (first_outside_replacement_index == null) first_outside_replacement_index = replacement_index;
                continue;
            }
            replacement_counts[replacement.input_index] += 1;
        }

        for (input_changes.changes, 0..) |change, change_index| {
            if (change.kind != .changed) continue;
            const recorded_index = change.recorded_index orelse continue;
            const contribution_summary = self.contributionSummaryForChange(change);
            if (recorded_index >= replacement_counts.len or replacement_counts[recorded_index] != contribution_summary.retained) {
                return .{
                    .decision = .full_link,
                    .blocker = .replacement_missing,
                    .blocking_change_index = change_index,
                    .input_summary = input_changes.summary,
                    .affected_contributions = contribution_summary,
                };
            }
        }

        if (first_outside_replacement_index) |replacement_index| {
            return self.replacementNotChangedPlan(input_changes, replacements, replacement_index);
        }

        return self.planReplacementRelinkFromChanges(input_changes, replacements, affected);
    }

    fn replacementNotChangedPlan(
        self: *const PreparedState,
        input_changes: InputChanges,
        replacements: []const ReplacementContribution,
        replacement_index: usize,
    ) RelinkPlan {
        const blocking_change_index = if (replacement_index < replacements.len)
            changeIndexForRecordedInput(input_changes, replacements[replacement_index].input_index)
        else
            null;
        return .{
            .decision = .full_link,
            .blocker = .replacement_not_changed,
            .blocking_change_index = blocking_change_index,
            .blocking_replacement_index = replacement_index,
            .input_summary = input_changes.summary,
            .affected_contributions = if (blocking_change_index) |change_index|
                self.contributionSummaryForChange(input_changes.changes[change_index])
            else
                .{},
        };
    }

    fn planReplacementRelinkFromChanges(
        self: *const PreparedState,
        input_changes: InputChanges,
        replacements: []const ReplacementContribution,
        affected: InputContributionSummary,
    ) RelinkPlan {
        const patch_plan = self.planContributionReplacement(replacements);
        if (patch_plan.decision == .in_place) {
            return .{
                .decision = .in_place,
                .input_summary = input_changes.summary,
                .affected_contributions = affected,
            };
        }

        const blocking_replacement_index = patch_plan.blocking_index;
        const blocking_change_index = if (blocking_replacement_index) |replacement_index|
            if (replacement_index < replacements.len)
                changeIndexForRecordedInput(input_changes, replacements[replacement_index].input_index)
            else
                null
        else
            null;

        return .{
            .decision = .full_link,
            .blocker = relinkBlockerForPatchBlocker(patch_plan.blocker),
            .blocking_change_index = blocking_change_index,
            .blocking_replacement_index = blocking_replacement_index,
            .input_summary = input_changes.summary,
            .affected_contributions = if (blocking_change_index) |change_index|
                self.contributionSummaryForChange(input_changes.changes[change_index])
            else
                affected,
        };
    }

    pub fn planContributionReplacement(
        self: *const PreparedState,
        replacements: []const ReplacementContribution,
    ) PatchPlan {
        if (self.contribution_index) |index| {
            return index.planContributionReplacement(self.manifest, replacements);
        }
        return patch.planContributionReplacement(self.manifest, replacements);
    }

    fn contributionIndexForReplacement(
        self: *const PreparedState,
        cursor: *patch.ContributionCursor,
        replacement: ReplacementContribution,
    ) ?usize {
        if (self.contribution_index) |index| return index.contributionIndexForReplacement(replacement);
        const match = cursor.find(self.manifest, replacement) orelse return null;
        return match.index;
    }

    pub fn applyChangedInputRelink(
        self: *const PreparedState,
        storage: *InputChangeStorage,
        image: []u8,
        options: model.LinkOptions,
        inputs: []const model.Input,
        replacements: []const ReplacementContribution,
    ) RelinkApplyError!RelinkApplication {
        if (self.relinkPreconditionPlan(options)) |plan| return .{ .plan = plan };

        const input_changes = try self.classifyInputs(storage, inputs);
        return try self.applyChangedInputRelinkFromInputChanges(options, input_changes, image, replacements);
    }

    pub fn applyChangedInputRelinkFromCandidate(
        self: *const PreparedState,
        allocator: Allocator,
        storage: *InputChangeStorage,
        image: []u8,
        options: model.LinkOptions,
        inputs: []const model.Input,
        candidate_image: []const u8,
        candidate_manifest: Manifest,
    ) CandidateRelinkApplyError!RelinkApplication {
        if (self.relinkPreconditionPlan(options)) |plan| return .{ .plan = plan };

        const input_changes = try self.classifyInputs(storage, inputs);

        const replacements = try replacementContributionsFromImage(
            allocator,
            candidate_image,
            candidate_manifest,
            input_changes,
        );
        defer freeReplacementContributions(allocator, replacements);

        return try self.applyChangedInputRelinkFromChanges(input_changes, image, replacements);
    }

    pub fn applyChangedInputRelinkFromInputChanges(
        self: *const PreparedState,
        options: model.LinkOptions,
        input_changes: InputChanges,
        image: []u8,
        replacements: []const ReplacementContribution,
    ) PatchApplyError!RelinkApplication {
        if (self.relinkPreconditionPlan(options)) |plan| return .{ .plan = plan };
        return try self.applyChangedInputRelinkFromChanges(input_changes, image, replacements);
    }

    fn applyChangedInputRelinkFromChanges(
        self: *const PreparedState,
        input_changes: InputChanges,
        image: []u8,
        replacements: []const ReplacementContribution,
    ) PatchApplyError!RelinkApplication {
        const plan = self.planChangedInputRelinkFromChanges(input_changes, replacements);
        return try self.applyAcceptedChangedInputRelink(image, replacements, plan);
    }

    pub fn acceptedRelinkRecordUpdates(
        self: *const PreparedState,
        allocator: Allocator,
        inputs: []const model.Input,
        input_changes: InputChanges,
        replacements: []const ReplacementContribution,
        member_updates: []const MemberHashUpdate,
    ) !RecordUpdates {
        var updates = RecordUpdates{};
        errdefer updates.deinit(allocator);
        for (input_changes.changes) |change| {
            const recorded_index = change.recorded_index orelse continue;
            const current_index = change.current_index orelse continue;
            if (recorded_index >= self.manifest.inputs.len or current_index >= inputs.len) continue;
            try updates.input_indexes.append(allocator, recorded_index);
        }
        var cursor = patch.ContributionCursor{};
        for (replacements) |replacement| {
            const contribution_index = self.contributionIndexForReplacement(&cursor, replacement) orelse
                return error.ReplacementMissing;
            if (contribution_index >= self.manifest.contributions.len) return error.ReplacementMissing;
            try updates.contribution_indexes.append(allocator, contribution_index);
        }
        for (member_updates) |update| {
            if (update.member_index >= self.manifest.archive_members.len) return error.MemberMissing;
            try updates.archive_member_indexes.append(allocator, update.member_index);
        }
        return updates;
    }

    pub fn replacementFileRange(
        self: *const PreparedState,
        replacement: ReplacementContribution,
    ) ?patch.FileRange {
        var cursor = patch.ContributionCursor{};
        const contribution_index = self.contributionIndexForReplacement(&cursor, replacement) orelse return null;
        if (contribution_index >= self.manifest.contributions.len) return null;
        return patch.replacementFileRange(self.manifest.contributions[contribution_index], replacement);
    }

    pub fn applyAcceptedChangedInputRelink(
        self: *const PreparedState,
        image: []u8,
        replacements: []const ReplacementContribution,
        accepted_plan: RelinkPlan,
    ) PatchApplyError!RelinkApplication {
        var application = RelinkApplication{
            .plan = accepted_plan,
        };
        if (accepted_plan.decision != .in_place) return application;
        const patch_application = try self.applyContributionReplacementInPlace(image, replacements);
        if (patch_application.plan.decision == .full_link) {
            application.plan = .{
                .decision = .full_link,
                .blocker = relinkBlockerForPatchBlocker(patch_application.plan.blocker),
                .blocking_replacement_index = patch_application.plan.blocking_index,
                .input_summary = accepted_plan.input_summary,
                .affected_contributions = accepted_plan.affected_contributions,
            };
            return application;
        }
        application.contributions_written = patch_application.contributions_written;
        application.bytes_written = patch_application.bytes_written;
        application.zero_fill_bytes = patch_application.zero_fill_bytes;
        return application;
    }

    pub fn applyContributionReplacement(
        self: *const PreparedState,
        image: []u8,
        replacements: []const ReplacementContribution,
    ) PatchApplyError!PatchApplication {
        if (self.contribution_index) |index| {
            return try index.applyContributionReplacement(image, self.manifest, replacements);
        }
        return try patch.applyContributionReplacement(self.manifest, image, replacements);
    }

    fn applyContributionReplacementInPlace(
        self: *const PreparedState,
        image: []u8,
        replacements: []const ReplacementContribution,
    ) PatchApplyError!PatchApplication {
        if (self.contribution_index) |index| {
            return try index.applyContributionReplacementInPlace(image, self.manifest, replacements);
        }
        return try patch.applyContributionReplacementInPlace(self.manifest, image, replacements);
    }

    pub fn updateManifestForChangedInputRelinkFromInputChanges(
        self: *PreparedState,
        inputs: []const model.Input,
        input_changes: InputChanges,
        replacements: []const ReplacementContribution,
        member_updates: []const MemberHashUpdate,
        inputs_read_at_ns: i64,
    ) RelinkManifestUpdateError!void {
        if (!self.manifest.input_hashes_recorded) return error.RelinkUpdateRequiresInPlacePlan;

        const plan = self.planChangedInputRelinkFromChanges(input_changes, replacements);
        try self.updateManifestForAcceptedChangedInputRelinkFromInputChanges(
            inputs,
            input_changes,
            replacements,
            member_updates,
            inputs_read_at_ns,
            plan,
        );
    }

    pub fn updateManifestForAcceptedChangedInputRelinkFromInputChanges(
        self: *PreparedState,
        inputs: []const model.Input,
        input_changes: InputChanges,
        replacements: []const ReplacementContribution,
        member_updates: []const MemberHashUpdate,
        inputs_read_at_ns: i64,
        accepted_plan: RelinkPlan,
    ) RelinkManifestUpdateError!void {
        if (!self.manifest.input_hashes_recorded) return error.RelinkUpdateRequiresInPlacePlan;
        if (accepted_plan.decision != .in_place) return error.RelinkUpdateRequiresInPlacePlan;

        for (input_changes.changes) |change| {
            const recorded_index = change.recorded_index orelse continue;
            const current_index = change.current_index orelse continue;
            if (recorded_index >= self.manifest.inputs.len or current_index >= inputs.len) continue;
            const input = inputs[current_index];
            const identity = input.identity orelse model.InputIdentity{ .mtime_ns = 0, .inode = 0 };
            self.manifest.inputs[recorded_index].size = input.bytes.len;
            self.manifest.inputs[recorded_index].hash = hashBytes(input.bytes);
            self.manifest.inputs[recorded_index].mtime_ns = identity.mtime_ns;
            self.manifest.inputs[recorded_index].inode = identity.inode;
            self.manifest.inputs[recorded_index].identity_recorded = input.identity != null;
        }
        self.manifest.inputs_read_at_ns = inputs_read_at_ns;

        var cursor = patch.ContributionCursor{};
        for (replacements) |replacement| {
            const contribution_index = self.contributionIndexForReplacement(&cursor, replacement) orelse
                return error.ReplacementMissing;
            if (contribution_index >= self.manifest.contributions.len) return error.ReplacementMissing;
            const previous_file_size = self.manifest.contributions[contribution_index].file_size;
            self.manifest.contributions[contribution_index].size = replacement.size;
            self.manifest.contributions[contribution_index].file_size = if (previous_file_size == 0 and replacement.payload.len == 0)
                0
            else
                replacement.size;
        }

        for (member_updates) |update| {
            if (update.member_index >= self.manifest.archive_members.len) return error.MemberMissing;
            self.manifest.archive_members[update.member_index].hash = update.hash;
        }
    }

    pub fn updateManifestForCandidateRelink(
        self: *PreparedState,
        allocator: Allocator,
        storage: *InputChangeStorage,
        inputs: []const model.Input,
        replacements: []const ReplacementContribution,
        candidate_manifest: Manifest,
    ) RelinkManifestClassifyError!void {
        const input_changes = try self.classifyInputs(storage, inputs);
        try self.updateManifestForCandidateRelinkFromInputChanges(allocator, inputs, input_changes, replacements, candidate_manifest);
    }

    pub fn updateManifestForCandidateRelinkFromInputChanges(
        self: *PreparedState,
        allocator: Allocator,
        inputs: []const model.Input,
        input_changes: InputChanges,
        replacements: []const ReplacementContribution,
        candidate_manifest: Manifest,
    ) RelinkManifestUpdateError!void {
        const plan = self.planChangedInputRelinkFromChanges(input_changes, replacements);
        try self.updateManifestForAcceptedCandidateRelinkFromInputChanges(
            allocator,
            inputs,
            input_changes,
            replacements,
            candidate_manifest,
            plan,
        );
    }

    pub fn updateManifestForAcceptedCandidateRelinkFromInputChanges(
        self: *PreparedState,
        allocator: Allocator,
        inputs: []const model.Input,
        input_changes: InputChanges,
        replacements: []const ReplacementContribution,
        candidate_manifest: Manifest,
        accepted_plan: RelinkPlan,
    ) RelinkManifestUpdateError!void {
        try self.validateCandidateSectionLayout(candidate_manifest);
        try self.updateManifestForAcceptedChangedInputRelinkFromInputChanges(
            inputs,
            input_changes,
            replacements,
            &.{},
            candidate_manifest.inputs_read_at_ns,
            accepted_plan,
        );
        for (self.manifest.sections, 0..) |*section, section_index| {
            section.size = candidate_manifest.sections[section_index].size;
        }
        try self.updateInputLinkHashesFromCandidate(input_changes, candidate_manifest);
        try self.replaceDiscardedContributionsFromCandidate(allocator, input_changes, candidate_manifest);
        try self.replaceExternalTargetsFromCandidate(allocator, candidate_manifest);
        try self.replaceArchiveMembersFromCandidate(allocator, input_changes, candidate_manifest);
        try self.replaceGotEntriesFromCandidate(allocator, input_changes, candidate_manifest);
        try self.replaceMergePiecesFromCandidate(allocator, input_changes, candidate_manifest);
        try self.rebuildInputContributionSummaries(allocator);
    }

    fn updateInputLinkHashesFromCandidate(
        self: *PreparedState,
        input_changes: InputChanges,
        candidate_manifest: Manifest,
    ) RelinkManifestUpdateError!void {
        for (input_changes.changes) |change| {
            const recorded_index = change.recorded_index orelse continue;
            const current_index = change.current_index orelse continue;
            if (recorded_index >= self.manifest.inputs.len or current_index >= candidate_manifest.inputs.len) return error.SectionLayoutChanged;
            self.manifest.inputs[recorded_index].link_hash = candidate_manifest.inputs[current_index].link_hash;
            self.manifest.inputs[recorded_index].selection_hash = candidate_manifest.inputs[current_index].selection_hash;
        }
    }

    fn validateCandidateSectionLayout(
        self: *const PreparedState,
        candidate_manifest: Manifest,
    ) error{SectionLayoutChanged}!void {
        if (self.manifest.sections.len != candidate_manifest.sections.len) return error.SectionLayoutChanged;
        for (self.manifest.sections, candidate_manifest.sections) |recorded, candidate| {
            if (!std.mem.eql(u8, self.manifest.string(recorded.name_id), candidate_manifest.string(candidate.name_id))) return error.SectionLayoutChanged;
            if (recorded.address != candidate.address) return error.SectionLayoutChanged;
            if (recorded.file_offset != candidate.file_offset) return error.SectionLayoutChanged;
            if (recorded.reserved_size != candidate.reserved_size) return error.SectionLayoutChanged;
            if (recorded.alignment != candidate.alignment) return error.SectionLayoutChanged;
        }
    }

    fn replaceDiscardedContributionsFromCandidate(
        self: *PreparedState,
        allocator: Allocator,
        input_changes: InputChanges,
        candidate_manifest: Manifest,
    ) RelinkManifestUpdateError!void {
        const discarded_contributions = try cloneCandidateDiscardedContributions(
            allocator,
            &self.manifest.strings,
            input_changes,
            candidate_manifest,
        );
        errdefer if (discarded_contributions.len != 0) allocator.free(discarded_contributions);

        if (self.manifest.owned.discarded_contributions and self.manifest.discarded_contributions.len != 0) {
            allocator.free(self.manifest.discarded_contributions);
        }
        self.manifest.discarded_contributions = discarded_contributions;
        self.manifest.owned.discarded_contributions = true;
    }

    fn replaceArchiveMembersFromCandidate(
        self: *PreparedState,
        allocator: Allocator,
        input_changes: InputChanges,
        candidate_manifest: Manifest,
    ) RelinkManifestUpdateError!void {
        const archive_members = try cloneArchiveMemberRecords(allocator, &self.manifest.strings, input_changes, candidate_manifest);
        errdefer if (archive_members.len != 0) allocator.free(archive_members);

        if (self.manifest.owned.archive_members and self.manifest.archive_members.len != 0) {
            allocator.free(self.manifest.archive_members);
        }
        self.manifest.archive_members = archive_members;
        self.manifest.owned.archive_members = true;
    }

    fn replaceGotEntriesFromCandidate(
        self: *PreparedState,
        allocator: Allocator,
        input_changes: InputChanges,
        candidate_manifest: Manifest,
    ) RelinkManifestUpdateError!void {
        const got_entries = try cloneGotEntryRecords(allocator, &self.manifest.strings, input_changes, candidate_manifest);
        errdefer if (got_entries.len != 0) allocator.free(got_entries);

        if (self.manifest.owned.got_entries and self.manifest.got_entries.len != 0) {
            allocator.free(self.manifest.got_entries);
        }
        self.manifest.got_entries = got_entries;
        self.manifest.owned.got_entries = true;
    }

    fn replaceMergePiecesFromCandidate(
        self: *PreparedState,
        allocator: Allocator,
        input_changes: InputChanges,
        candidate_manifest: Manifest,
    ) RelinkManifestUpdateError!void {
        const merge_pieces = try cloneMergePieceRecords(allocator, &self.manifest.strings, input_changes, candidate_manifest);
        errdefer if (merge_pieces.len != 0) allocator.free(merge_pieces);

        if (self.manifest.owned.merge_pieces and self.manifest.merge_pieces.len != 0) {
            allocator.free(self.manifest.merge_pieces);
        }
        self.manifest.merge_pieces = merge_pieces;
        self.manifest.owned.merge_pieces = true;
    }

    fn replaceExternalTargetsFromCandidate(
        self: *PreparedState,
        allocator: Allocator,
        candidate_manifest: Manifest,
    ) Allocator.Error!void {
        const external_targets = try cloneExternalTargetRecords(allocator, &self.manifest.strings, candidate_manifest);
        errdefer if (external_targets.len != 0) allocator.free(external_targets);

        if (self.manifest.owned.external_targets and self.manifest.external_targets.len != 0) {
            allocator.free(self.manifest.external_targets);
        }
        self.manifest.external_targets = external_targets;
        self.manifest.owned.external_targets = true;
    }

    fn rebuildInputContributionSummaries(
        self: *PreparedState,
        allocator: Allocator,
    ) Allocator.Error!void {
        const input_contributions = try buildInputContributionSummaries(allocator, self.manifest);
        if (self.input_contributions.len != 0) allocator.free(self.input_contributions);
        self.input_contributions = input_contributions;
    }
};

pub fn inputContentUnchanged(record: InputRecord, input: model.Input, inputs_read_at_ns: i64) bool {
    if (record.size != input.bytes.len) return false;
    if (inputIdentityUnchanged(record, input, inputs_read_at_ns)) return true;
    return record.hash == hashBytes(input.bytes);
}

fn inputIdentityUnchanged(record: InputRecord, input: model.Input, inputs_read_at_ns: i64) bool {
    if (!record.identity_recorded) return false;
    const identity = input.identity orelse return false;
    return record.inode == identity.inode and
        record.mtime_ns == identity.mtime_ns and
        record.mtime_ns < inputs_read_at_ns;
}

const linear_input_classification_limit = 16;

const no_input_index = std.math.maxInt(u32);

pub fn planRelinkFromInputChanges(input_changes: InputChanges) RelinkPlan {
    return planRelinkFromInputChangesWithContributions(input_changes, &.{});
}

pub fn replacementContributionsFromImage(
    allocator: Allocator,
    image: []const u8,
    manifest: Manifest,
    input_changes: InputChanges,
) ReplacementExtractError![]ReplacementContribution {
    if (input_changes.summary.changed == 0 or manifest.contributions.len == 0) return &.{};
    if (input_changes.summary.changed <= sparse_replacement_extraction_change_limit) {
        return try replacementContributionsFromImageSparse(allocator, image, manifest, input_changes);
    }

    const current_change_indexes = try currentChangeIndexesAlloc(allocator, input_changes);
    defer if (current_change_indexes.len != 0) allocator.free(current_change_indexes);

    const replacement_count = countChangedInputContributions(manifest, input_changes, current_change_indexes);
    if (replacement_count == 0) return &.{};

    const replacements = try allocator.alloc(ReplacementContribution, replacement_count);
    errdefer allocator.free(replacements);

    var replacement_index: usize = 0;
    for (manifest.contributions) |contribution| {
        const current_index = std.math.cast(usize, contribution.input_index) orelse continue;
        const change = changeForCurrentInput(input_changes, current_change_indexes, current_index) orelse continue;
        if (change.kind != .changed) continue;
        const recorded_index = change.recorded_index orelse continue;
        replacements[replacement_index] = .{
            .input_name = manifest.string(contribution.input_name_id),
            .input_index = recorded_index,
            .kind = contribution.kind,
            .name = manifest.string(contribution.name_id),
            .ordinal = contribution.ordinal,
            .size = contribution.size,
            .alignment = contribution.alignment,
            .output_section_name = manifest.string(contribution.output_section_name_id),
            .address = contribution.address,
            .file_offset = contribution.file_offset,
            .reserved_size = contribution.reserved_size,
            .payload = try contributionPayload(image, contribution),
        };
        replacement_index += 1;
    }
    return replacements;
}

const ChangedCurrentInput = struct {
    current_index: usize,
    recorded_index: usize,
};

fn replacementContributionsFromImageSparse(
    allocator: Allocator,
    image: []const u8,
    manifest: Manifest,
    input_changes: InputChanges,
) ReplacementExtractError![]ReplacementContribution {
    var changed_current_inputs_storage: [sparse_replacement_extraction_change_limit]ChangedCurrentInput = undefined;
    var changed_current_input_count: usize = 0;
    for (input_changes.changes) |change| {
        if (change.kind != .changed) continue;
        const current_index = change.current_index orelse continue;
        const recorded_index = change.recorded_index orelse continue;
        changed_current_inputs_storage[changed_current_input_count] = .{
            .current_index = current_index,
            .recorded_index = recorded_index,
        };
        changed_current_input_count += 1;
    }
    if (changed_current_input_count == 0) return &.{};

    const changed_current_inputs = changed_current_inputs_storage[0..changed_current_input_count];
    var replacements: std.ArrayListUnmanaged(ReplacementContribution) = .empty;
    errdefer replacements.deinit(allocator);
    try replacements.ensureTotalCapacity(allocator, @min(manifest.contributions.len, changed_current_inputs.len));

    for (manifest.contributions) |contribution| {
        const current_index = std.math.cast(usize, contribution.input_index) orelse continue;
        const changed_input = changedCurrentInputForContribution(changed_current_inputs, current_index) orelse continue;
        try replacements.append(allocator, .{
            .input_name = manifest.string(contribution.input_name_id),
            .input_index = changed_input.recorded_index,
            .kind = contribution.kind,
            .name = manifest.string(contribution.name_id),
            .ordinal = contribution.ordinal,
            .size = contribution.size,
            .alignment = contribution.alignment,
            .output_section_name = manifest.string(contribution.output_section_name_id),
            .address = contribution.address,
            .file_offset = contribution.file_offset,
            .reserved_size = contribution.reserved_size,
            .payload = try contributionPayload(image, contribution),
        });
    }

    if (replacements.items.len == 0) {
        replacements.deinit(allocator);
        return &.{};
    }
    return try replacements.toOwnedSlice(allocator);
}

fn changedCurrentInputForContribution(
    changed_current_inputs: []const ChangedCurrentInput,
    current_index: usize,
) ?ChangedCurrentInput {
    for (changed_current_inputs) |changed_input| {
        if (changed_input.current_index == current_index) return changed_input;
    }
    return null;
}

fn currentChangeIndexesAlloc(
    allocator: Allocator,
    input_changes: InputChanges,
) Allocator.Error![]?usize {
    var max_current_index: ?usize = null;
    for (input_changes.changes) |change| {
        const current_index = change.current_index orelse continue;
        if (max_current_index == null or current_index > max_current_index.?) max_current_index = current_index;
    }

    const index_count = if (max_current_index) |current_index| current_index + 1 else return &.{};
    const current_change_indexes = try allocator.alloc(?usize, index_count);
    @memset(current_change_indexes, null);
    for (input_changes.changes, 0..) |change, change_index| {
        const current_index = change.current_index orelse continue;
        current_change_indexes[current_index] = change_index;
    }
    return current_change_indexes;
}

fn planRelinkFromInputChangesWithContributions(
    input_changes: InputChanges,
    input_contributions: []const InputContributionSummary,
) RelinkPlan {
    if (inputOrderDriftChangeIndex(input_changes)) |change_index| {
        return .{
            .decision = .full_link,
            .blocker = .input_reordered,
            .blocking_change_index = change_index,
            .input_summary = input_changes.summary,
            .affected_contributions = contributionSummaryForRecordedInput(input_contributions, input_changes.changes[change_index].recorded_index),
        };
    }

    if (input_changes.allUnchanged()) {
        return .{
            .decision = .reuse_output,
            .input_summary = input_changes.summary,
        };
    }

    for (input_changes.changes, 0..) |change, change_index| {
        const blocker: RelinkBlocker = switch (change.kind) {
            .unchanged => continue,
            .changed => .input_changed,
            .added => .input_added,
            .removed => .input_removed,
        };
        const affected_contributions = contributionSummaryForRecordedInput(input_contributions, change.recorded_index);
        return .{
            .decision = .full_link,
            .blocker = blocker,
            .blocking_change_index = change_index,
            .input_summary = input_changes.summary,
            .affected_contributions = affected_contributions,
        };
    }
    return .{
        .decision = .reuse_output,
        .input_summary = input_changes.summary,
    };
}

fn contributionSummaryForRecordedInput(
    input_contributions: []const InputContributionSummary,
    recorded_index: ?usize,
) InputContributionSummary {
    const index = recorded_index orelse return .{};
    if (index >= input_contributions.len) return .{};
    return input_contributions[index];
}

fn countChangedInputContributions(
    manifest: Manifest,
    input_changes: InputChanges,
    current_change_indexes: []const ?usize,
) usize {
    var count: usize = 0;
    for (manifest.contributions) |contribution| {
        const current_index = std.math.cast(usize, contribution.input_index) orelse continue;
        const change = changeForCurrentInput(input_changes, current_change_indexes, current_index) orelse continue;
        if (change.kind == .changed and change.recorded_index != null) count += 1;
    }
    return count;
}

fn contributionPayload(
    image: []const u8,
    contribution: ContributionRecord,
) error{PatchRangeOutOfBounds}![]const u8 {
    const size = std.math.cast(usize, contribution.file_size) orelse return error.PatchRangeOutOfBounds;
    if (size == 0) return image[0..0];
    const start = std.math.cast(usize, contribution.file_offset) orelse return error.PatchRangeOutOfBounds;
    if (start > image.len or size > image.len - start) return error.PatchRangeOutOfBounds;
    return image[start..][0..size];
}

fn cloneCandidateDiscardedContributions(
    allocator: Allocator,
    strings: *Strings,
    input_changes: InputChanges,
    candidate_manifest: Manifest,
) RelinkManifestUpdateError![]DiscardedContributionRecord {
    const candidate_records = candidate_manifest.discarded_contributions;
    if (candidate_records.len == 0) return &.{};

    const discarded_contributions = try allocator.alloc(DiscardedContributionRecord, candidate_records.len);
    errdefer allocator.free(discarded_contributions);

    for (candidate_records, 0..) |candidate, index| {
        const current_index = std.math.cast(usize, candidate.input_index) orelse return error.SectionLayoutChanged;
        const input_index = recordedIndexForCurrentInput(input_changes, current_index) orelse return error.SectionLayoutChanged;
        discarded_contributions[index] = candidate;
        discarded_contributions[index].input_index = input_index;
        discarded_contributions[index].input_name_id = try strings.intern(allocator, candidate_manifest.string(candidate.input_name_id));
        discarded_contributions[index].name_id = try strings.intern(allocator, candidate_manifest.string(candidate.name_id));
    }

    return discarded_contributions;
}

fn cloneArchiveMemberRecords(
    allocator: Allocator,
    strings: *Strings,
    input_changes: InputChanges,
    candidate_manifest: Manifest,
) RelinkManifestUpdateError![]ArchiveMemberRecord {
    const candidate_members = candidate_manifest.archive_members;
    if (candidate_members.len == 0) return &.{};

    const archive_members = try allocator.alloc(ArchiveMemberRecord, candidate_members.len);
    errdefer allocator.free(archive_members);

    for (candidate_members, 0..) |candidate, index| {
        const current_index = std.math.cast(usize, candidate.input_index) orelse return error.SectionLayoutChanged;
        const input_index = recordedIndexForCurrentInput(input_changes, current_index) orelse return error.SectionLayoutChanged;
        archive_members[index] = candidate;
        archive_members[index].input_index = input_index;
        archive_members[index].name_id = try strings.intern(allocator, candidate_manifest.string(candidate.name_id));
    }

    return archive_members;
}

fn cloneGotEntryRecords(
    allocator: Allocator,
    strings: *Strings,
    input_changes: InputChanges,
    candidate_manifest: Manifest,
) RelinkManifestUpdateError![]GotEntryRecord {
    const candidate_entries = candidate_manifest.got_entries;
    if (candidate_entries.len == 0) return &.{};

    const got_entries = try allocator.alloc(GotEntryRecord, candidate_entries.len);
    errdefer allocator.free(got_entries);

    for (candidate_entries, 0..) |candidate, index| {
        const current_index = std.math.cast(usize, candidate.input_index) orelse return error.SectionLayoutChanged;
        const input_index = recordedIndexForCurrentInput(input_changes, current_index) orelse return error.SectionLayoutChanged;
        got_entries[index] = candidate;
        got_entries[index].input_index = input_index;
        got_entries[index].input_name_id = try strings.intern(allocator, candidate_manifest.string(candidate.input_name_id));
        got_entries[index].name_id = try strings.intern(allocator, candidate_manifest.string(candidate.name_id));
    }

    return got_entries;
}

fn cloneMergePieceRecords(
    allocator: Allocator,
    strings: *Strings,
    input_changes: InputChanges,
    candidate_manifest: Manifest,
) RelinkManifestUpdateError![]MergePieceRecord {
    const candidate_pieces = candidate_manifest.merge_pieces;
    if (candidate_pieces.len == 0) return &.{};

    const merge_pieces = try allocator.alloc(MergePieceRecord, candidate_pieces.len);
    errdefer allocator.free(merge_pieces);

    for (candidate_pieces, 0..) |candidate, index| {
        const current_index = std.math.cast(usize, candidate.input_index) orelse return error.SectionLayoutChanged;
        const input_index = recordedIndexForCurrentInput(input_changes, current_index) orelse return error.SectionLayoutChanged;
        merge_pieces[index] = candidate;
        merge_pieces[index].input_index = input_index;
        merge_pieces[index].input_name_id = try strings.intern(allocator, candidate_manifest.string(candidate.input_name_id));
    }

    return merge_pieces;
}

fn cloneExternalTargetRecords(
    allocator: Allocator,
    strings: *Strings,
    candidate_manifest: Manifest,
) Allocator.Error![]ExternalTargetRecord {
    const candidate_targets = candidate_manifest.external_targets;
    if (candidate_targets.len == 0) return &.{};

    const external_targets = try allocator.alloc(ExternalTargetRecord, candidate_targets.len);
    errdefer allocator.free(external_targets);

    for (candidate_targets, 0..) |candidate, index| {
        external_targets[index] = candidate;
        external_targets[index].name_id = try strings.intern(allocator, candidate_manifest.string(candidate.name_id));
    }

    return external_targets;
}

fn addInputContributionSummary(total: *InputContributionSummary, next: InputContributionSummary) void {
    total.retained += next.retained;
    total.discarded += next.discarded;
    total.retained_size += next.retained_size;
    total.discarded_size += next.discarded_size;
}

fn countRetainedReplacementsForInput(
    replacements: []const ReplacementContribution,
    recorded_index: usize,
) usize {
    var count: usize = 0;
    for (replacements) |replacement| {
        if (replacement.input_index == recorded_index) count += 1;
    }
    return count;
}

fn replacementIndexOutsideChangedInputs(
    input_changes: InputChanges,
    replacements: []const ReplacementContribution,
) ?usize {
    var cached_input_index: ?usize = null;
    var cached_change_index: ?usize = null;
    for (replacements, 0..) |replacement, replacement_index| {
        if (cached_input_index != replacement.input_index) {
            cached_input_index = replacement.input_index;
            cached_change_index = changeIndexForRecordedInput(input_changes, replacement.input_index);
        }
        const change_index = cached_change_index orelse return replacement_index;
        if (input_changes.changes[change_index].kind != .changed) return replacement_index;
    }
    return null;
}

fn changeForCurrentInput(
    input_changes: InputChanges,
    current_change_indexes: []const ?usize,
    current_index: usize,
) ?InputChange {
    if (current_index >= current_change_indexes.len) return null;
    const change_index = current_change_indexes[current_index] orelse return null;
    if (change_index >= input_changes.changes.len) return null;
    return input_changes.changes[change_index];
}

fn changeIndexForRecordedInput(input_changes: InputChanges, recorded_index: usize) ?usize {
    for (input_changes.changes, 0..) |change, change_index| {
        if (change.recorded_index == recorded_index) return change_index;
    }
    return null;
}

fn inputOrderDriftChangeIndex(input_changes: InputChanges) ?usize {
    if (input_changes.summary.added != 0 or input_changes.summary.removed != 0) return null;
    for (input_changes.changes, 0..) |change, change_index| {
        const recorded_index = change.recorded_index orelse continue;
        const current_index = change.current_index orelse continue;
        if (recorded_index != current_index) return change_index;
    }
    return null;
}

fn recordedIndexForCurrentInput(input_changes: InputChanges, current_index: usize) ?usize {
    for (input_changes.changes) |change| {
        if (change.current_index != current_index) continue;
        return change.recorded_index;
    }
    return null;
}

fn relinkBlockerForPatchBlocker(blocker: ?PatchBlocker) ?RelinkBlocker {
    const patch_blocker = blocker orelse return null;
    return switch (patch_blocker) {
        .missing_contribution => .replacement_missing,
        .unpatchable_contribution => .replacement_unpatchable,
        .layout_changed => .replacement_layout_changed,
        .grew_past_reserve => .replacement_grew_past_reserve,
        .alignment_increased => .replacement_alignment_increased,
    };
}

pub const Builder = struct {
    allocator: Allocator,
    target: model.Target,
    output_kind: model.OutputKind,
    entry_symbol_id: u32,
    image_base: u64,
    page_size: u64,
    gc_sections: bool,
    icf: model.IcfMode,
    strip_debug: bool,
    build_id: model.BuildIdMode,
    input_hashes_recorded: bool,
    contribution_records_enabled: bool,
    inputs_read_at_ns: i64,
    strings: Strings = .{},
    inputs: std.ArrayListUnmanaged(InputRecord) = .empty,
    sections: std.ArrayListUnmanaged(SectionRecord) = .empty,
    contributions: std.ArrayListUnmanaged(ContributionRecord) = .empty,
    discarded_contributions: std.ArrayListUnmanaged(DiscardedContributionRecord) = .empty,
    external_targets: std.ArrayListUnmanaged(ExternalTargetRecord) = .empty,
    archive_members: std.ArrayListUnmanaged(ArchiveMemberRecord) = .empty,
    got_entries: std.ArrayListUnmanaged(GotEntryRecord) = .empty,
    merge_pieces: std.ArrayListUnmanaged(MergePieceRecord) = .empty,

    pub fn init(allocator: Allocator, options: model.LinkOptions) Allocator.Error!Builder {
        const incremental_records_enabled = options.incremental_mode != .off;
        var builder = Builder{
            .allocator = allocator,
            .target = options.target,
            .output_kind = options.output_kind,
            .entry_symbol_id = 0,
            .image_base = options.image_base,
            .page_size = options.page_size,
            .gc_sections = options.gc_sections,
            .icf = options.icf,
            .strip_debug = options.strip_debug,
            .build_id = options.build_id,
            .input_hashes_recorded = incremental_records_enabled,
            .contribution_records_enabled = incremental_records_enabled,
            .inputs_read_at_ns = options.inputs_read_at_ns,
        };
        errdefer builder.deinit();
        builder.entry_symbol_id = try builder.strings.intern(allocator, options.entry_symbol);
        return builder;
    }

    pub fn recordsContributions(self: Builder) bool {
        return self.contribution_records_enabled;
    }

    pub fn deinit(self: *Builder) void {
        self.strings.deinit(self.allocator);
        self.inputs.deinit(self.allocator);
        self.sections.deinit(self.allocator);
        self.contributions.deinit(self.allocator);
        self.discarded_contributions.deinit(self.allocator);
        self.external_targets.deinit(self.allocator);
        self.archive_members.deinit(self.allocator);
        self.got_entries.deinit(self.allocator);
        self.merge_pieces.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addInput(self: *Builder, input: model.Input) Allocator.Error!void {
        const hash = if (self.input_hashes_recorded) hashBytes(input.bytes) else 0;
        const identity = input.identity orelse model.InputIdentity{ .mtime_ns = 0, .inode = 0 };
        try self.inputs.append(self.allocator, .{
            .name_id = try self.strings.intern(self.allocator, input.name),
            .size = input.bytes.len,
            .hash = hash,
            .mtime_ns = identity.mtime_ns,
            .inode = identity.inode,
            .identity_recorded = input.identity != null,
            .link_hash = hash,
        });
    }

    pub fn setInputLinkHash(self: *Builder, input_index: usize, link_hash: u64) void {
        if (!self.input_hashes_recorded) return;
        if (input_index >= self.inputs.items.len) return;
        self.inputs.items[input_index].link_hash = link_hash;
    }

    pub fn setInputSelectionHash(self: *Builder, input_index: usize, selection_hash: u64) void {
        if (!self.input_hashes_recorded) return;
        if (input_index >= self.inputs.items.len) return;
        self.inputs.items[input_index].selection_hash = selection_hash;
    }

    pub fn addArchiveMember(
        self: *Builder,
        input_index: usize,
        name: []const u8,
        hash: u64,
        link_hash: u64,
        selected: bool,
    ) Allocator.Error!void {
        if (!self.contribution_records_enabled) return;

        try self.archive_members.append(self.allocator, .{
            .input_index = input_index,
            .name_id = try self.strings.intern(self.allocator, name),
            .hash = hash,
            .link_hash = link_hash,
            .selected = selected,
        });
    }

    pub fn addSection(
        self: *Builder,
        name: []const u8,
        address: u64,
        file_offset: u64,
        size: u64,
        reserved_size: u64,
        alignment: u64,
    ) Allocator.Error!void {
        try self.sections.append(self.allocator, .{
            .name_id = try self.strings.intern(self.allocator, name),
            .address = address,
            .file_offset = file_offset,
            .size = size,
            .reserved_size = reserved_size,
            .alignment = alignment,
        });
    }

    pub fn addContribution(
        self: *Builder,
        input_name: []const u8,
        input_index: usize,
        kind: ContributionKind,
        name: []const u8,
        ordinal: u32,
        output_section_name: []const u8,
        address: u64,
        file_offset: u64,
        size: u64,
        reserved_size: u64,
        alignment: u64,
    ) Allocator.Error!void {
        return try self.addContributionWithFileSize(
            input_name,
            input_index,
            kind,
            name,
            ordinal,
            output_section_name,
            address,
            file_offset,
            size,
            size,
            reserved_size,
            alignment,
        );
    }

    pub fn addContributionWithFileSize(
        self: *Builder,
        input_name: []const u8,
        input_index: usize,
        kind: ContributionKind,
        name: []const u8,
        ordinal: u32,
        output_section_name: []const u8,
        address: u64,
        file_offset: u64,
        size: u64,
        file_size: u64,
        reserved_size: u64,
        alignment: u64,
    ) Allocator.Error!void {
        if (!self.contribution_records_enabled) return;

        try self.contributions.append(self.allocator, .{
            .input_name_id = try self.strings.intern(self.allocator, input_name),
            .input_index = input_index,
            .kind = kind,
            .name_id = try self.strings.intern(self.allocator, name),
            .ordinal = ordinal,
            .output_section_name_id = try self.strings.intern(self.allocator, output_section_name),
            .address = address,
            .file_offset = file_offset,
            .size = size,
            .file_size = file_size,
            .reserved_size = reserved_size,
            .alignment = alignment,
        });
    }

    pub fn addDiscardedContribution(
        self: *Builder,
        input_name: []const u8,
        input_index: usize,
        name: []const u8,
        ordinal: u32,
        reason: DiscardReason,
        size: u64,
        alignment: u64,
    ) Allocator.Error!void {
        if (!self.contribution_records_enabled) return;

        try self.discarded_contributions.append(self.allocator, .{
            .input_name_id = try self.strings.intern(self.allocator, input_name),
            .input_index = input_index,
            .name_id = try self.strings.intern(self.allocator, name),
            .ordinal = ordinal,
            .reason = reason,
            .size = size,
            .alignment = alignment,
        });
    }

    pub fn addExternalTarget(
        self: *Builder,
        name: []const u8,
        resolved_address: i128,
        size: u64,
    ) Allocator.Error!void {
        if (!self.contribution_records_enabled) return;

        const name_id = try self.strings.intern(self.allocator, name);
        const record = ExternalTargetRecord.fromResolved(name_id, resolved_address, size) orelse return;
        try self.external_targets.append(self.allocator, record);
    }

    pub fn addGotEntry(
        self: *Builder,
        input_index: usize,
        input_name: []const u8,
        ordinal: u32,
        name: []const u8,
        address: u64,
    ) Allocator.Error!void {
        if (!self.contribution_records_enabled) return;

        try self.got_entries.append(self.allocator, .{
            .input_index = input_index,
            .input_name_id = try self.strings.intern(self.allocator, input_name),
            .ordinal = ordinal,
            .name_id = try self.strings.intern(self.allocator, name),
            .address = address,
        });
    }

    pub fn addMergePiece(
        self: *Builder,
        input_index: usize,
        input_name: []const u8,
        ordinal: u32,
        input_offset: u64,
        size: u64,
        address: u64,
    ) Allocator.Error!void {
        if (!self.contribution_records_enabled) return;

        try self.merge_pieces.append(self.allocator, .{
            .input_index = input_index,
            .input_name_id = try self.strings.intern(self.allocator, input_name),
            .ordinal = ordinal,
            .input_offset = input_offset,
            .size = size,
            .address = address,
        });
    }

    pub fn finish(self: *Builder) Allocator.Error!Manifest {
        var strings = self.strings;
        self.strings = .{};
        errdefer strings.deinit(self.allocator);
        strings.ids.deinit(self.allocator);
        strings.ids = .empty;
        const inputs = try self.inputs.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(inputs);
        const sections = try self.sections.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(sections);
        const contributions = try self.contributions.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(contributions);
        const discarded_contributions = try self.discarded_contributions.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(discarded_contributions);
        const external_targets = try self.external_targets.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(external_targets);
        const archive_members = try self.archive_members.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(archive_members);
        const got_entries = try self.got_entries.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(got_entries);
        const merge_pieces = try self.merge_pieces.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(merge_pieces);
        return .{
            .target = self.target,
            .output_kind = self.output_kind,
            .entry_symbol_id = self.entry_symbol_id,
            .image_base = self.image_base,
            .page_size = self.page_size,
            .gc_sections = self.gc_sections,
            .icf = self.icf,
            .strip_debug = self.strip_debug,
            .build_id = self.build_id,
            .input_hashes_recorded = self.input_hashes_recorded,
            .inputs_read_at_ns = self.inputs_read_at_ns,
            .strings = strings,
            .inputs = inputs,
            .sections = sections,
            .contributions = contributions,
            .discarded_contributions = discarded_contributions,
            .external_targets = external_targets,
            .archive_members = archive_members,
            .got_entries = got_entries,
            .merge_pieces = merge_pieces,
            .owned = .{
                .inputs = true,
                .sections = true,
                .contributions = true,
                .discarded_contributions = true,
                .external_targets = true,
                .archive_members = true,
                .got_entries = true,
                .merge_pieces = true,
            },
        };
    }
};

pub fn hashBytes(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x544c44, bytes);
}

fn findUnmatchedInput(
    inputs: []const model.Input,
    matched: []const bool,
    name: []const u8,
) ?usize {
    for (inputs, matched, 0..) |input, already_matched, index| {
        if (already_matched) continue;
        if (std.mem.eql(u8, input.name, name)) return index;
    }
    return null;
}

fn buildInputContributionSummaries(
    allocator: Allocator,
    manifest: Manifest,
) Allocator.Error![]InputContributionSummary {
    var input_count = manifest.inputs.len;
    for (manifest.contributions) |contribution| {
        input_count = @max(input_count, contribution.input_index + 1);
    }
    for (manifest.discarded_contributions) |contribution| {
        input_count = @max(input_count, contribution.input_index + 1);
    }
    if (input_count == 0) return &.{};

    const summaries = try allocator.alloc(InputContributionSummary, input_count);
    @memset(summaries, .{});

    for (manifest.contributions) |contribution| {
        summaries[contribution.input_index].retained += 1;
        summaries[contribution.input_index].retained_size += contribution.size;
    }
    for (manifest.discarded_contributions) |contribution| {
        summaries[contribution.input_index].discarded += 1;
        summaries[contribution.input_index].discarded_size += contribution.size;
    }
    return summaries;
}

const TestInputClassification = struct {
    owner: TestInputChangeOwner,
    changes: InputChanges,

    fn deinit(self: *TestInputClassification, allocator: Allocator) void {
        self.owner.deinit(allocator);
    }
};

const TestInputChangeOwner = struct {
    bytes: InputChangeStorage.Storage,
    storage: InputChangeStorage,

    fn init(allocator: Allocator, limits: InputChangeStorage.Limits) !TestInputChangeOwner {
        const capacity = try InputChangeStorage.Capacity.derive(limits);
        const bytes = try allocator.alignedAlloc(
            u8,
            .fromByteUnits(InputChangeStorage.storage_alignment),
            capacity.storage_bytes,
        );
        errdefer allocator.free(bytes);
        return .{
            .bytes = bytes,
            .storage = try InputChangeStorage.init(bytes, limits),
        };
    }

    fn deinit(self: *TestInputChangeOwner, allocator: Allocator) void {
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
    var owner = try TestInputChangeOwner.init(
        allocator,
        InputChangeStorage.Limits.inspect(RecordedInputs.fromManifest(&manifest), inputs),
    );
    errdefer owner.deinit(allocator);
    owner.storage.activate();
    const changes = try owner.storage.classify(RecordedInputs.fromManifest(&manifest), inputs);
    return .{
        .changes = changes,
        .owner = owner,
    };
}

fn initTestInputChangeStorage(
    allocator: Allocator,
    manifest: Manifest,
    inputs: []const model.Input,
) !TestInputChangeOwner {
    var owner = try TestInputChangeOwner.init(
        allocator,
        InputChangeStorage.Limits.inspect(RecordedInputs.fromManifest(&manifest), inputs),
    );
    owner.storage.activate();
    return owner;
}

fn planInputRelinkForTest(
    state: *const PreparedState,
    allocator: Allocator,
    options: model.LinkOptions,
    inputs: []const model.Input,
) !RelinkPlan {
    var storage = try initTestInputChangeStorage(
        allocator,
        state.manifest,
        inputs,
    );
    defer storage.deinit(allocator);
    return try state.planInputRelink(&storage.storage, options, inputs);
}

fn planChangedInputRelinkForTest(
    state: *const PreparedState,
    allocator: Allocator,
    options: model.LinkOptions,
    inputs: []const model.Input,
    replacements: []const ReplacementContribution,
) !RelinkPlan {
    var storage = try initTestInputChangeStorage(
        allocator,
        state.manifest,
        inputs,
    );
    defer storage.deinit(allocator);
    return try state.planChangedInputRelink(
        &storage.storage,
        options,
        inputs,
        replacements,
    );
}

fn applyChangedInputRelinkForTest(
    state: *const PreparedState,
    allocator: Allocator,
    image: []u8,
    options: model.LinkOptions,
    inputs: []const model.Input,
    replacements: []const ReplacementContribution,
) !RelinkApplication {
    var storage = try initTestInputChangeStorage(
        allocator,
        state.manifest,
        inputs,
    );
    defer storage.deinit(allocator);
    return try state.applyChangedInputRelink(
        &storage.storage,
        image,
        options,
        inputs,
        replacements,
    );
}

fn applyChangedInputRelinkFromCandidateForTest(
    state: *const PreparedState,
    allocator: Allocator,
    image: []u8,
    options: model.LinkOptions,
    inputs: []const model.Input,
    candidate_image: []const u8,
    candidate_manifest: Manifest,
) !RelinkApplication {
    var storage = try initTestInputChangeStorage(
        allocator,
        state.manifest,
        inputs,
    );
    defer storage.deinit(allocator);
    return try state.applyChangedInputRelinkFromCandidate(
        allocator,
        &storage.storage,
        image,
        options,
        inputs,
        candidate_image,
        candidate_manifest,
    );
}

fn updateManifestForCandidateRelinkForTest(
    state: *PreparedState,
    allocator: Allocator,
    inputs: []const model.Input,
    replacements: []const ReplacementContribution,
    candidate_manifest: Manifest,
) !void {
    var storage = try initTestInputChangeStorage(
        allocator,
        state.manifest,
        inputs,
    );
    defer storage.deinit(allocator);
    try state.updateManifestForCandidateRelink(
        allocator,
        &storage.storage,
        inputs,
        replacements,
        candidate_manifest,
    );
}

fn repeatedInputManifest(
    allocator: Allocator,
    count: usize,
    name: []const u8,
    bytes: []const u8,
) !Manifest {
    var builder = try Builder.init(allocator, .{});
    defer builder.deinit();
    for (0..count) |_| try builder.addInput(.{ .name = name, .bytes = bytes });
    return try builder.finish();
}

const InputChangeCapacityCase = struct {
    limits: InputChangeStorage.Limits,
    changes: usize,
    current: usize,
};

const InputChangeInitFailure = struct {
    fn run(allocator: Allocator) !void {
        var owner = try TestInputChangeOwner.init(allocator, .{
            .recorded_inputs = 31,
            .current_inputs = 37,
        });
        owner.storage.activate();
        owner.deinit(allocator);
    }
};

fn modelInputChangeCapacity(
    limits: InputChangeStorage.Limits,
) InputChangeStorage.Capacity.DeriveError!InputChangeStorage.Capacity {
    const recorded: u128 = limits.recorded_inputs;
    const current: u128 = limits.current_inputs;
    if (current > std.math.maxInt(u32)) return error.CapacityOverflow;
    const changes = recorded + current;
    var name_slots: u128 = if (current == 0) 0 else 1;
    const minimum_name_slots = current * 2;
    var shifts: usize = 0;
    while (name_slots < minimum_name_slots) : (shifts += 1) {
        std.debug.assert(shifts <= @bitSizeOf(usize));
        name_slots *= 2;
    }
    const changes_offset = modelInputChangeOffset(0, @alignOf(InputChange));
    const changes_end = changes_offset + changes * @sizeOf(InputChange);
    const matched_offset = modelInputChangeOffset(changes_end, @alignOf(bool));
    const matched_end = matched_offset + current * @sizeOf(bool);
    const links_offset = modelInputChangeOffset(matched_end, @alignOf(u32));
    const links_end = links_offset + current * @sizeOf(u32);
    const names_offset = modelInputChangeOffset(links_end, @alignOf(InputChangeNameEntry));
    const storage_bytes = names_offset + name_slots * @sizeOf(InputChangeNameEntry);
    if (changes > std.math.maxInt(usize) or
        name_slots > std.math.maxInt(usize) or
        changes_offset > std.math.maxInt(usize) or
        matched_offset > std.math.maxInt(usize) or
        links_offset > std.math.maxInt(usize) or
        names_offset > std.math.maxInt(usize) or
        storage_bytes > std.math.maxInt(usize))
    {
        return error.CapacityOverflow;
    }
    return .{
        .recorded_inputs = limits.recorded_inputs,
        .current_inputs = limits.current_inputs,
        .change_records = @intCast(changes),
        .matched_flags = limits.current_inputs,
        .current_links = limits.current_inputs,
        .name_slots = @intCast(name_slots),
        .changes_offset = @intCast(changes_offset),
        .matched_offset = @intCast(matched_offset),
        .links_offset = @intCast(links_offset),
        .names_offset = @intCast(names_offset),
        .storage_bytes = @intCast(storage_bytes),
    };
}

fn modelInputChangeOffset(offset: u128, alignment: usize) u128 {
    std.debug.assert(alignment != 0);
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    const requested_mask: u128 = alignment - 1;
    return (offset + requested_mask) & ~requested_mask;
}
