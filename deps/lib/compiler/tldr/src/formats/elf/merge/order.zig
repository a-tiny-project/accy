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
    worker_budget: usize,
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
        root.parallel.sortItems(SortKey, keys, context, keyLess, scratch, worker_budget);
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
