const std = @import("std");
const incremental = @import("root.zig");

const Allocator = std.mem.Allocator;
const ContributionKind = incremental.ContributionKind;
const ContributionRecord = incremental.ContributionRecord;
const Manifest = incremental.Manifest;

pub const ReplacementContribution = struct {
    input_name: []const u8,
    input_index: usize,
    kind: ContributionKind,
    name: []const u8,
    ordinal: u32,
    size: u64,
    alignment: u64,
    output_section_name: ?[]const u8 = null,
    address: ?u64 = null,
    file_offset: ?u64 = null,
    reserved_size: ?u64 = null,
    payload: []const u8 = &.{},
    payload_owned: bool = false,
    unchanged: bool = false,
};

pub const FileRange = struct {
    offset: usize,
    len: usize,
};

pub fn replacementFileRange(record: ContributionRecord, replacement: ReplacementContribution) ?FileRange {
    if (replacement.unchanged) return null;
    if (record.file_size == 0 and record.size != 0) return null;
    const offset = std.math.cast(usize, record.file_offset) orelse return null;
    const len = std.math.cast(usize, record.reserved_size) orelse return null;
    if (len == 0) return null;
    return .{ .offset = offset, .len = len };
}

pub fn freeReplacementContributions(allocator: Allocator, replacements: []const ReplacementContribution) void {
    for (replacements) |replacement| {
        if (replacement.payload_owned) allocator.free(replacement.payload);
    }
    if (replacements.len != 0) allocator.free(replacements);
}

pub const MemberHashUpdate = struct {
    member_index: usize,
    hash: u64,
};

pub const DirectRelinkEvidence = struct {
    replacements: []const ReplacementContribution = &.{},
    member_updates: []const MemberHashUpdate = &.{},
    inputs_proven: bool = false,

    pub fn deinit(self: DirectRelinkEvidence, allocator: Allocator) void {
        freeReplacementContributions(allocator, self.replacements);
        if (self.member_updates.len != 0) allocator.free(self.member_updates);
    }
};

pub const PatchDecision = enum {
    in_place,
    full_link,
};

pub const PatchBlocker = enum {
    missing_contribution,
    unpatchable_contribution,
    layout_changed,
    grew_past_reserve,
    alignment_increased,
};

pub const PatchPlan = struct {
    decision: PatchDecision,
    blocker: ?PatchBlocker = null,
    blocking_index: ?usize = null,
};

pub const PatchApplication = struct {
    plan: PatchPlan,
    contributions_written: usize = 0,
    bytes_written: usize = 0,
    zero_fill_bytes: usize = 0,
};

pub const PatchApplyError = error{
    PatchPayloadMismatch,
    PatchRangeOutOfBounds,
};

pub const ContributionMatch = struct {
    record: ContributionRecord,
    index: usize,
};

pub const ContributionCursor = struct {
    index: usize = 0,

    pub fn find(
        self: *ContributionCursor,
        manifest: Manifest,
        replacement: ReplacementContribution,
    ) ?ContributionMatch {
        const match = findContributionFrom(manifest, replacement, self.index) orelse
            findContributionFrom(manifest, replacement, 0) orelse return null;
        if (match.index >= self.index) self.index = match.index + 1;
        return match;
    }
};

const ContributionKey = struct {
    input_name: []const u8,
    input_index: usize,
    kind: ContributionKind,
    name: []const u8,
    ordinal: u32,

    fn fromRecord(manifest: Manifest, record: ContributionRecord) ContributionKey {
        return .{
            .input_name = manifest.string(record.input_name_id),
            .input_index = @intCast(record.input_index),
            .kind = record.kind,
            .name = manifest.string(record.name_id),
            .ordinal = record.ordinal,
        };
    }

    fn fromReplacement(replacement: ReplacementContribution) ContributionKey {
        return .{
            .input_name = replacement.input_name,
            .input_index = replacement.input_index,
            .kind = replacement.kind,
            .name = replacement.name,
            .ordinal = replacement.ordinal,
        };
    }
};

const ContributionKeyContext = struct {
    pub fn hash(_: ContributionKeyContext, key: ContributionKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.input_name);
        hasher.update(&.{0});
        var input_index_bytes: [@sizeOf(usize)]u8 = undefined;
        std.mem.writeInt(usize, &input_index_bytes, key.input_index, .little);
        hasher.update(&input_index_bytes);
        hasher.update(&.{0});
        hasher.update(&.{@backingInt(key.kind)});
        hasher.update(&.{0});
        hasher.update(key.name);
        hasher.update(&.{0});
        var ordinal_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &ordinal_bytes, key.ordinal, .little);
        hasher.update(&ordinal_bytes);
        return hasher.final();
    }

    pub fn eql(_: ContributionKeyContext, a: ContributionKey, b: ContributionKey) bool {
        return a.kind == b.kind and
            a.ordinal == b.ordinal and
            a.input_index == b.input_index and
            std.mem.eql(u8, a.input_name, b.input_name) and
            std.mem.eql(u8, a.name, b.name);
    }
};

const contribution_key_context = ContributionKeyContext{};
const ContributionIndexMap = std.HashMapUnmanaged(ContributionKey, usize, ContributionKeyContext, 80);

const DuplicateContributionError = error{
    DuplicateContribution,
};

pub const IndexError = Allocator.Error || DuplicateContributionError;

pub const ContributionIndex = struct {
    map: ContributionIndexMap = .empty,

    pub fn init(allocator: Allocator, manifest: Manifest) IndexError!ContributionIndex {
        var index = ContributionIndex{};
        errdefer index.deinit(allocator);
        try index.map.ensureTotalCapacity(allocator, @intCast(manifest.contributions.len));
        for (manifest.contributions, 0..) |contribution, contribution_index| {
            const gop = index.map.getOrPutAssumeCapacityContext(
                ContributionKey.fromRecord(manifest, contribution),
                contribution_key_context,
            );
            if (gop.found_existing) return error.DuplicateContribution;
            gop.value_ptr.* = contribution_index;
        }
        return index;
    }

    pub fn initForReplacements(
        allocator: Allocator,
        manifest: Manifest,
        replacements: []const ReplacementContribution,
    ) IndexError!ContributionIndex {
        var index = ContributionIndex{};
        errdefer index.deinit(allocator);
        if (replacements.len == 0 or manifest.contributions.len == 0) return index;

        var max_input_index: usize = 0;
        for (manifest.contributions) |contribution| {
            max_input_index = @max(max_input_index, contribution.input_index);
        }
        var inputs = try std.DynamicBitSetUnmanaged.initEmpty(allocator, max_input_index + 1);
        defer inputs.deinit(allocator);
        for (replacements) |replacement| {
            if (replacement.input_index <= max_input_index) inputs.set(replacement.input_index);
        }

        var filtered: usize = 0;
        for (manifest.contributions) |contribution| {
            if (inputs.isSet(contribution.input_index)) filtered += 1;
        }
        if (filtered == 0) return index;

        try index.map.ensureTotalCapacity(allocator, @intCast(filtered));
        for (manifest.contributions, 0..) |contribution, contribution_index| {
            if (!inputs.isSet(contribution.input_index)) continue;
            const gop = index.map.getOrPutAssumeCapacityContext(
                ContributionKey.fromRecord(manifest, contribution),
                contribution_key_context,
            );
            if (gop.found_existing) return error.DuplicateContribution;
            gop.value_ptr.* = contribution_index;
        }
        return index;
    }

    pub fn deinit(self: *ContributionIndex, allocator: Allocator) void {
        self.map.deinit(allocator);
        self.* = .{};
    }

    pub fn contributionIndexForReplacement(self: ContributionIndex, replacement: ReplacementContribution) ?usize {
        return self.map.getContext(
            ContributionKey.fromReplacement(replacement),
            contribution_key_context,
        );
    }

    pub fn planContributionReplacement(
        self: ContributionIndex,
        manifest: Manifest,
        replacements: []const ReplacementContribution,
    ) PatchPlan {
        for (replacements, 0..) |replacement, replacement_index| {
            const contribution_index = self.contributionIndexForReplacement(replacement) orelse return .{
                .decision = .full_link,
                .blocker = .missing_contribution,
                .blocking_index = replacement_index,
            };
            if (contribution_index >= manifest.contributions.len) {
                return .{
                    .decision = .full_link,
                    .blocker = .missing_contribution,
                    .blocking_index = replacement_index,
                };
            }
            const record = manifest.contributions[contribution_index];
            if (!contribution_key_context.eql(ContributionKey.fromRecord(manifest, record), ContributionKey.fromReplacement(replacement))) {
                return .{
                    .decision = .full_link,
                    .blocker = .missing_contribution,
                    .blocking_index = replacement_index,
                };
            }
            if (blockerForRecord(manifest, record, replacement, replacement_index)) |plan| {
                return plan;
            }
        }
        return .{ .decision = .in_place };
    }

    pub fn applyContributionReplacement(
        self: ContributionIndex,
        image: []u8,
        manifest: Manifest,
        replacements: []const ReplacementContribution,
    ) PatchApplyError!PatchApplication {
        var application = PatchApplication{
            .plan = self.planContributionReplacement(manifest, replacements),
        };
        if (application.plan.decision == .full_link) return application;
        for (replacements, 0..) |replacement, replacement_index| {
            const contribution_index = self.contributionIndexForReplacement(replacement) orelse {
                application.plan = .{
                    .decision = .full_link,
                    .blocker = .missing_contribution,
                    .blocking_index = replacement_index,
                };
                return application;
            };
            if (contribution_index >= manifest.contributions.len) {
                application.plan = .{
                    .decision = .full_link,
                    .blocker = .missing_contribution,
                    .blocking_index = replacement_index,
                };
                return application;
            }
            try applyReplacementBytes(
                image,
                manifest.contributions[contribution_index],
                replacement,
                &application,
            );
        }
        return application;
    }

    pub fn applyContributionReplacementInPlace(
        self: ContributionIndex,
        image: []u8,
        manifest: Manifest,
        replacements: []const ReplacementContribution,
    ) PatchApplyError!PatchApplication {
        var application = PatchApplication{
            .plan = .{ .decision = .in_place },
        };
        for (replacements, 0..) |replacement, replacement_index| {
            const contribution_index = self.contributionIndexForReplacement(replacement) orelse {
                application.plan = .{
                    .decision = .full_link,
                    .blocker = .missing_contribution,
                    .blocking_index = replacement_index,
                };
                return application;
            };
            if (contribution_index >= manifest.contributions.len) {
                application.plan = .{
                    .decision = .full_link,
                    .blocker = .missing_contribution,
                    .blocking_index = replacement_index,
                };
                return application;
            }
            try applyReplacementBytes(
                image,
                manifest.contributions[contribution_index],
                replacement,
                &application,
            );
        }
        return application;
    }
};

pub fn planContributionReplacement(
    manifest: Manifest,
    replacements: []const ReplacementContribution,
) PatchPlan {
    var cursor = ContributionCursor{};
    for (replacements, 0..) |replacement, replacement_index| {
        const contribution_match = cursor.find(manifest, replacement) orelse return .{
            .decision = .full_link,
            .blocker = .missing_contribution,
            .blocking_index = replacement_index,
        };
        if (blockerForRecord(manifest, contribution_match.record, replacement, replacement_index)) |plan| {
            return plan;
        }
    }
    return .{ .decision = .in_place };
}

pub fn applyContributionReplacement(
    manifest: Manifest,
    image: []u8,
    replacements: []const ReplacementContribution,
) PatchApplyError!PatchApplication {
    const application = PatchApplication{
        .plan = planContributionReplacement(manifest, replacements),
    };
    if (application.plan.decision == .full_link) return application;
    return try applyPlannedContributionReplacement(manifest, image, replacements, application);
}

pub fn applyContributionReplacementInPlace(
    manifest: Manifest,
    image: []u8,
    replacements: []const ReplacementContribution,
) PatchApplyError!PatchApplication {
    const application = PatchApplication{
        .plan = .{ .decision = .in_place },
    };
    return try applyPlannedContributionReplacement(manifest, image, replacements, application);
}

fn applyPlannedContributionReplacement(
    manifest: Manifest,
    image: []u8,
    replacements: []const ReplacementContribution,
    accepted: PatchApplication,
) PatchApplyError!PatchApplication {
    var application = accepted;
    var cursor = ContributionCursor{};
    for (replacements, 0..) |replacement, replacement_index| {
        const contribution_match = cursor.find(manifest, replacement) orelse {
            application.plan = .{
                .decision = .full_link,
                .blocker = .missing_contribution,
                .blocking_index = replacement_index,
            };
            return application;
        };
        try applyReplacementBytes(image, contribution_match.record, replacement, &application);
    }
    return application;
}

fn findContributionFrom(
    manifest: Manifest,
    replacement: ReplacementContribution,
    start_index: usize,
) ?ContributionMatch {
    var contribution_index = start_index;
    while (contribution_index < manifest.contributions.len) : (contribution_index += 1) {
        const contribution = manifest.contributions[contribution_index];
        if (!contributionMatchesReplacement(manifest, contribution, replacement)) continue;
        return .{
            .record = contribution,
            .index = contribution_index,
        };
    }
    return null;
}

fn contributionMatchesReplacement(
    manifest: Manifest,
    contribution: ContributionRecord,
    replacement: ReplacementContribution,
) bool {
    return contribution.kind == replacement.kind and
        contribution.ordinal == replacement.ordinal and
        contribution.input_index == replacement.input_index and
        std.mem.eql(u8, manifest.string(contribution.input_name_id), replacement.input_name) and
        std.mem.eql(u8, manifest.string(contribution.name_id), replacement.name);
}

fn blockerForRecord(
    manifest: Manifest,
    record: ContributionRecord,
    replacement: ReplacementContribution,
    replacement_index: usize,
) ?PatchPlan {
    if (replacement.unchanged) return null;
    if (record.file_size != record.size and !(record.file_size == 0 and replacement.payload.len == 0)) {
        return .{
            .decision = .full_link,
            .blocker = .unpatchable_contribution,
            .blocking_index = replacement_index,
        };
    }
    if (replacement.output_section_name) |output_section_name| {
        if (!std.mem.eql(u8, manifest.string(record.output_section_name_id), output_section_name)) {
            return .{
                .decision = .full_link,
                .blocker = .layout_changed,
                .blocking_index = replacement_index,
            };
        }
    }
    if (replacement.address) |address| {
        if (record.address != address) {
            return .{
                .decision = .full_link,
                .blocker = .layout_changed,
                .blocking_index = replacement_index,
            };
        }
    }
    if (replacement.file_offset) |file_offset| {
        if (record.file_offset != file_offset) {
            return .{
                .decision = .full_link,
                .blocker = .layout_changed,
                .blocking_index = replacement_index,
            };
        }
    }
    if (replacement.reserved_size) |reserved_size| {
        if (record.reserved_size != reserved_size) {
            return .{
                .decision = .full_link,
                .blocker = .layout_changed,
                .blocking_index = replacement_index,
            };
        }
    }
    if (@max(replacement.alignment, 1) > @max(record.alignment, 1)) {
        return .{
            .decision = .full_link,
            .blocker = .alignment_increased,
            .blocking_index = replacement_index,
        };
    }
    if (replacement.size > record.reserved_size) {
        return .{
            .decision = .full_link,
            .blocker = .grew_past_reserve,
            .blocking_index = replacement_index,
        };
    }
    return null;
}

fn applyReplacementBytes(
    image: []u8,
    record: ContributionRecord,
    replacement: ReplacementContribution,
    application: *PatchApplication,
) PatchApplyError!void {
    if (replacement.unchanged) return;
    const size = std.math.cast(usize, replacement.size) orelse return error.PatchRangeOutOfBounds;
    if (record.file_size == 0 and record.size != 0) {
        if (replacement.payload.len != 0) return error.PatchPayloadMismatch;
        if (size > record.reserved_size) return error.PatchRangeOutOfBounds;
        application.contributions_written += 1;
        return;
    }

    const start = std.math.cast(usize, record.file_offset) orelse return error.PatchRangeOutOfBounds;
    const reserve = std.math.cast(usize, record.reserved_size) orelse return error.PatchRangeOutOfBounds;
    if (replacement.payload.len != size) return error.PatchPayloadMismatch;
    if (start > image.len or reserve > image.len - start) return error.PatchRangeOutOfBounds;
    if (size > reserve) return error.PatchRangeOutOfBounds;
    var wrote = false;
    const payload = image[start..][0..size];
    if (size != 0 and !std.mem.eql(u8, payload, replacement.payload)) {
        @memcpy(payload, replacement.payload);
        application.bytes_written += size;
        wrote = true;
    }
    const zero_fill = reserve - size;
    const zero_fill_payload = image[start + size ..][0..zero_fill];
    if (zero_fill != 0 and !allZero(zero_fill_payload)) {
        @memset(zero_fill_payload, 0);
        application.zero_fill_bytes += zero_fill;
        wrote = true;
    }
    if (wrote) application.contributions_written += 1;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

test "contribution index accepted in-place application reports stale replacements" {
    const allocator = std.testing.allocator;
    var builder = try incremental.Builder.init(allocator, .{});
    defer builder.deinit();
    try builder.addContribution("a.o", 0, .section, ".text", 1, ".text", 0x401000, 4, 3, 8, 16);

    var manifest = try builder.finish();
    defer manifest.deinit(allocator);

    var index = try ContributionIndex.init(allocator, manifest);
    defer index.deinit(allocator);

    var image = @as([16]u8, @splat(0xaa));
    const application = try index.applyContributionReplacementInPlace(
        image[0..],
        manifest,
        &.{
            .{ .input_name = "missing.o", .input_index = 9, .kind = .section, .name = ".text.missing", .ordinal = 1, .size = 4, .alignment = 16, .payload = "miss" },
        },
    );

    try std.testing.expectEqual(PatchDecision.full_link, application.plan.decision);
    try std.testing.expectEqual(PatchBlocker.missing_contribution, application.plan.blocker.?);
    try std.testing.expectEqual(@as(?usize, 0), application.plan.blocking_index);
    try std.testing.expectEqual(@as(usize, 0), application.contributions_written);
    try std.testing.expectEqual(@as(usize, 0), application.bytes_written);
    try std.testing.expectEqual(@as(u8, 0xaa), image[4]);
}

test "contribution replacement skips byte-identical image writes" {
    const allocator = std.testing.allocator;
    var builder = try incremental.Builder.init(allocator, .{});
    defer builder.deinit();
    try builder.addContribution("a.o", 0, .section, ".text", 1, ".text", 0x401000, 4, 3, 8, 16);

    var manifest = try builder.finish();
    defer manifest.deinit(allocator);

    const replacement = [_]ReplacementContribution{
        .{ .input_name = "a.o", .input_index = 0, .kind = .section, .name = ".text", .ordinal = 1, .size = 3, .alignment = 16, .payload = "old" },
    };

    var clean_image = @as([16]u8, @splat(0xaa));
    @memcpy(clean_image[4..7], "old");
    @memset(clean_image[7..12], 0);
    const clean_application = try manifest.applyContributionReplacement(clean_image[0..], &replacement);

    try std.testing.expectEqual(PatchDecision.in_place, clean_application.plan.decision);
    try std.testing.expectEqual(@as(usize, 0), clean_application.contributions_written);
    try std.testing.expectEqual(@as(usize, 0), clean_application.bytes_written);
    try std.testing.expectEqual(@as(usize, 0), clean_application.zero_fill_bytes);
    try std.testing.expectEqualSlices(u8, "old", clean_image[4..7]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0 }, clean_image[7..12]);

    var dirty_padding_image = @as([16]u8, @splat(0xaa));
    @memcpy(dirty_padding_image[4..7], "old");
    const dirty_padding_application = try manifest.applyContributionReplacement(dirty_padding_image[0..], &replacement);

    try std.testing.expectEqual(PatchDecision.in_place, dirty_padding_application.plan.decision);
    try std.testing.expectEqual(@as(usize, 1), dirty_padding_application.contributions_written);
    try std.testing.expectEqual(@as(usize, 0), dirty_padding_application.bytes_written);
    try std.testing.expectEqual(@as(usize, 5), dirty_padding_application.zero_fill_bytes);
    try std.testing.expectEqualSlices(u8, "old", dirty_padding_image[4..7]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0 }, dirty_padding_image[7..12]);
}
