const std = @import("std");
const root = @import("../../../root.zig");
const record = @import("record.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const Record = record.Record;

const Group = struct {
    section_type: u32,
    output_index: u8,
    alignment: u64,

    fn of(value: Record) Group {
        return .{
            .section_type = value.section_type,
            .output_index = value.output_index,
            .alignment = value.alignment,
        };
    }

    fn eql(self: Group, other: Group) bool {
        return self.section_type == other.section_type and
            self.output_index == other.output_index and
            self.alignment == other.alignment;
    }

    fn less(_: void, left: Group, right: Group) bool {
        if (left.section_type != right.section_type) return left.section_type < right.section_type;
        if (left.output_index != right.output_index) return left.output_index < right.output_index;
        return left.alignment < right.alignment;
    }
};

const SortKey = struct {
    reverse_prefix: u64,
    index: u32,
    group: u16,
};

const KeyContext = struct {
    values: []const Record,
};

const parallel_sort_min_records = 16 * 1024;

pub fn records(
    allocator: Allocator,
    values: []Record,
    max_link_jobs: usize,
) model.Error!void {
    if (values.len < 2) return;

    var groups: std.ArrayListUnmanaged(Group) = .empty;
    defer groups.deinit(allocator);
    for (values) |value| {
        const group = Group.of(value);
        for (groups.items) |known| {
            if (known.eql(group)) break;
        } else {
            try groups.append(allocator, group);
        }
    }
    std.sort.pdq(Group, groups.items, {}, Group.less);

    const keys = try allocator.alloc(SortKey, values.len);
    defer allocator.free(keys);
    for (values, 0..) |value, index| {
        const group = Group.of(value);
        const rank = for (groups.items, 0..) |known, known_rank| {
            if (known.eql(group)) break known_rank;
        } else unreachable;
        keys[index] = .{
            .reverse_prefix = value.reverse_prefix,
            .index = @intCast(index),
            .group = @intCast(rank),
        };
    }

    const context = KeyContext{ .values = values };
    if (values.len < parallel_sort_min_records) {
        std.sort.pdq(SortKey, keys, context, keyLess);
    } else {
        const scratch = try allocator.alloc(SortKey, keys.len);
        defer allocator.free(scratch);
        const requested_workers = if (max_link_jobs != 0) max_link_jobs else 0;
        root.parallel.sortItems(SortKey, keys, context, keyLess, scratch, requested_workers);
    }

    const sorted = try allocator.alloc(Record, values.len);
    defer allocator.free(sorted);
    for (keys, 0..) |key, position| sorted[position] = values[key.index];
    @memcpy(values, sorted);
}

fn keyLess(context: KeyContext, left: SortKey, right: SortKey) bool {
    if (left.group != right.group) return left.group < right.group;
    if (left.reverse_prefix != right.reverse_prefix) return left.reverse_prefix > right.reverse_prefix;
    return deepSuffixLess(context.values[left.index], context.values[right.index]);
}

fn deepSuffixLess(left: Record, right: Record) bool {
    const left_len = left.bytes.len - 1;
    const right_len = right.bytes.len - 1;
    const common = @min(left_len, right_len);
    var index: usize = @min(common, record.reverse_prefix_bytes);
    while (index < common) : (index += 1) {
        const left_byte = left.bytes[left_len - 1 - index];
        const right_byte = right.bytes[right_len - 1 - index];
        if (left_byte != right_byte) return left_byte > right_byte;
    }
    if (left_len != right_len) return left_len > right_len;
    return left.ordinal < right.ordinal;
}

test "merge order places superstrings before their suffixes" {
    var pieces: [3]root.formats.elf.layout.MergePieceLayout = .{ .{}, .{}, .{} };
    var values = [_]Record{
        .{ .ordinal = 0, .section_type = 1, .output_index = 3, .alignment = 1, .reverse_prefix = record.reversePrefix("bar\x00"), .bytes = "bar\x00", .piece = &pieces[0], .external_start = false },
        .{ .ordinal = 1, .section_type = 1, .output_index = 3, .alignment = 1, .reverse_prefix = record.reversePrefix("foobar\x00"), .bytes = "foobar\x00", .piece = &pieces[1], .external_start = false },
        .{ .ordinal = 2, .section_type = 1, .output_index = 3, .alignment = 1, .reverse_prefix = record.reversePrefix("baz\x00"), .bytes = "baz\x00", .piece = &pieces[2], .external_start = false },
    };
    try records(std.testing.allocator, &values, 1);
    try std.testing.expectEqualStrings("baz\x00", values[0].bytes);
    try std.testing.expectEqualStrings("foobar\x00", values[1].bytes);
    try std.testing.expectEqualStrings("bar\x00", values[2].bytes);
}

test "merge order keeps storage groups ordered" {
    var pieces: [3]root.formats.elf.layout.MergePieceLayout = .{ .{}, .{}, .{} };
    var values = [_]Record{
        .{ .ordinal = 0, .section_type = 1, .output_index = 4, .alignment = 1, .reverse_prefix = record.reversePrefix("same\x00"), .bytes = "same\x00", .piece = &pieces[0], .external_start = false },
        .{ .ordinal = 1, .section_type = 1, .output_index = 3, .alignment = 8, .reverse_prefix = record.reversePrefix("same\x00"), .bytes = "same\x00", .piece = &pieces[1], .external_start = false },
        .{ .ordinal = 2, .section_type = 1, .output_index = 3, .alignment = 1, .reverse_prefix = record.reversePrefix("same\x00"), .bytes = "same\x00", .piece = &pieces[2], .external_start = false },
    };
    try records(std.testing.allocator, &values, 1);
    try std.testing.expectEqual(@as(u8, 3), values[0].output_index);
    try std.testing.expectEqual(@as(u64, 1), values[0].alignment);
    try std.testing.expectEqual(@as(u8, 3), values[1].output_index);
    try std.testing.expectEqual(@as(u64, 8), values[1].alignment);
    try std.testing.expectEqual(@as(u8, 4), values[2].output_index);
}

test "merge order breaks equal suffix ties by ordinal" {
    var pieces: [4]root.formats.elf.layout.MergePieceLayout = .{ .{}, .{}, .{}, .{} };
    var values = [_]Record{
        .{ .ordinal = 3, .section_type = 1, .output_index = 3, .alignment = 1, .reverse_prefix = record.reversePrefix("dup\x00"), .bytes = "dup\x00", .piece = &pieces[0], .external_start = false },
        .{ .ordinal = 1, .section_type = 1, .output_index = 3, .alignment = 1, .reverse_prefix = record.reversePrefix("dup\x00"), .bytes = "dup\x00", .piece = &pieces[1], .external_start = false },
        .{ .ordinal = 2, .section_type = 1, .output_index = 3, .alignment = 1, .reverse_prefix = record.reversePrefix("dup\x00"), .bytes = "dup\x00", .piece = &pieces[2], .external_start = false },
        .{ .ordinal = 0, .section_type = 1, .output_index = 3, .alignment = 1, .reverse_prefix = record.reversePrefix("longtaildup\x00"), .bytes = "longtaildup\x00", .piece = &pieces[3], .external_start = false },
    };
    try records(std.testing.allocator, &values, 1);
    try std.testing.expectEqual(@as(u32, 0), values[0].ordinal);
    try std.testing.expectEqual(@as(u32, 1), values[1].ordinal);
    try std.testing.expectEqual(@as(u32, 2), values[2].ordinal);
    try std.testing.expectEqual(@as(u32, 3), values[3].ordinal);
}
