const std = @import("std");
const pretty_json = @import("pretty").json;
const memtrace = @import("../root.zig");
const model = @import("model.zig");
const storage_mod = @import("storage.zig");

const Entry = model.Entry;
const SummaryOptions = model.SummaryOptions;
const Storage = storage_mod.Storage;

const RecordingExhaustion = error{
    CategoryCapacityExceeded,
    LabelBytesCapacityExceeded,
    JoinedLabelCapacityExceeded,
    CensusCounterOverflow,
};

pub const Exhaustion = storage_mod.Exhaustion || RecordingExhaustion;

pub const Status = struct {
    categories: usize,
    category_capacity: usize,
    label_bytes_used: usize,
    label_bytes_capacity: usize,
    joined_label_bytes_capacity: usize,
    storage_bytes: usize,
};

const Lookup = union(enum) {
    existing: *model.Slot,
    vacant: *model.Slot,
};

pub const Census = struct {
    storage: *Storage,
    slots: []model.Slot,
    summary: []Entry,
    labels: []u8,
    joined_label: []u8,
    category_count: usize = 0,
    label_bytes_used: usize = 0,

    pub fn init(storage: *Storage) storage_mod.Exhaustion!Census {
        const regions = try storage.acquire();
        return .{
            .storage = storage,
            .slots = regions.slots,
            .summary = regions.summary,
            .labels = regions.labels,
            .joined_label = regions.joined_label,
        };
    }

    pub fn deinit(self: *Census) void {
        const storage = self.storage;
        self.* = undefined;
        storage.release();
    }

    pub fn record(self: *Census, label: []const u8, bytes: usize) Exhaustion!void {
        try self.recordCount(label, 1, bytes);
    }

    pub fn recordPrefixed(
        self: *Census,
        prefix: []const u8,
        label: []const u8,
        bytes: usize,
    ) Exhaustion!void {
        try self.recordCountPrefixed(prefix, label, 1, bytes);
    }

    pub fn recordCount(
        self: *Census,
        label: []const u8,
        count: usize,
        bytes: usize,
    ) Exhaustion!void {
        const hash = std.hash.Wyhash.hash(0, label);
        switch (self.locate(label, hash)) {
            .existing => |slot| {
                const next_items = std.math.add(usize, slot.entry.items, count) catch
                    return error.CensusCounterOverflow;
                const next_bytes = std.math.add(usize, slot.entry.bytes, bytes) catch
                    return error.CensusCounterOverflow;
                slot.entry.items = next_items;
                slot.entry.bytes = next_bytes;
            },
            .vacant => |slot| {
                if (self.category_count >= self.summary.len) return error.CategoryCapacityExceeded;
                if (label.len > self.labels.len - self.label_bytes_used) {
                    return error.LabelBytesCapacityExceeded;
                }
                const start = self.label_bytes_used;
                const end = start + label.len;
                const owned = self.labels[start..end];
                @memcpy(owned, label);
                slot.* = .{
                    .entry = .{
                        .label = owned,
                        .items = count,
                        .bytes = bytes,
                    },
                    .hash = hash,
                    .occupied = true,
                };
                self.label_bytes_used = end;
                self.category_count += 1;
            },
        }
    }

    pub fn recordCountPrefixed(
        self: *Census,
        prefix: []const u8,
        label: []const u8,
        count: usize,
        bytes: usize,
    ) Exhaustion!void {
        if (prefix.len == 0) return try self.recordCount(label, count, bytes);
        const joined_len = std.math.add(usize, prefix.len, label.len) catch
            return error.JoinedLabelCapacityExceeded;
        if (joined_len > self.joined_label.len) return error.JoinedLabelCapacityExceeded;
        @memcpy(self.joined_label[0..prefix.len], prefix);
        @memcpy(self.joined_label[prefix.len..joined_len], label);
        try self.recordCount(self.joined_label[0..joined_len], count, bytes);
    }

    pub fn writeSummary(
        self: *Census,
        writer: *std.Io.Writer,
        options: SummaryOptions,
    ) !void {
        var item_count: usize = 0;
        for (self.slots) |slot| {
            if (!slot.occupied or slot.entry.bytes < options.min_bytes) continue;
            std.debug.assert(item_count < self.summary.len);
            self.summary[item_count] = slot.entry;
            item_count += 1;
        }
        const items = self.summary[0..item_count];
        std.mem.sort(Entry, items, {}, entryGreaterThan);

        try writer.print("memtrace census categories={d}\n", .{items.len});
        const limit = @min(options.top, items.len);
        for (items[0..limit]) |entry| {
            try writer.print(
                "{s} items={d} bytes={d}\n",
                .{ entry.label, entry.items, entry.bytes },
            );
        }
    }

    pub fn writeJsonl(self: *const Census, writer: *std.Io.Writer) !void {
        var seq: u64 = 0;
        for (self.slots) |slot| {
            if (!slot.occupied) continue;
            seq = std.math.add(u64, seq, 1) catch return error.CensusCounterOverflow;
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("v", memtrace.event.format_version);
            try object.field("seq", seq);
            try object.field("kind", "census");
            try object.field("label", slot.entry.label);
            try object.field("items", slot.entry.items);
            try object.field("bytes", slot.entry.bytes);
            try object.endLine();
        }
    }

    pub fn status(self: *const Census) Status {
        return .{
            .categories = self.category_count,
            .category_capacity = self.summary.len,
            .label_bytes_used = self.label_bytes_used,
            .label_bytes_capacity = self.labels.len,
            .joined_label_bytes_capacity = self.joined_label.len,
            .storage_bytes = self.storage.capacity.storage_bytes,
        };
    }

    fn locate(self: *Census, label: []const u8, hash: u64) Lookup {
        std.debug.assert(self.slots.len >= 2);
        std.debug.assert(std.math.isPowerOfTwo(self.slots.len));
        const mask = self.slots.len - 1;
        const start = @as(usize, @truncate(hash)) & mask;
        for (0..self.slots.len) |probe| {
            const slot = &self.slots[(start +% probe) & mask];
            if (!slot.occupied) return .{ .vacant = slot };
            if (slot.hash == hash and std.mem.eql(u8, slot.entry.label, label)) {
                return .{ .existing = slot };
            }
        }
        unreachable;
    }
};

fn entryGreaterThan(_: void, left: Entry, right: Entry) bool {
    if (left.bytes != right.bytes) return left.bytes > right.bytes;
    if (left.items != right.items) return left.items > right.items;
    return std.mem.lessThan(u8, left.label, right.label);
}
