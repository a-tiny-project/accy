const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const section = @import("section.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const parallel = root.parallel;
const ObjectFile = elf.parser.ObjectFile;
const ObjectLayout = elf.layout.ObjectLayout;
const EhFramePieceLayout = elf.layout.EhFramePieceLayout;
const EhFrameCieLayout = elf.layout.EhFrameCieLayout;
const EhFrameSectionLayout = elf.layout.EhFrameSectionLayout;
const GlobalSymbol = elf.layout.GlobalSymbol;
const Rela = elf.format.Rela;
const sectionBytes = elf.format.sectionBytes;

const parallel_scan_threshold = 2 * 1024 * 1024;
const scan_bytes_per_worker = 256 * 1024;

pub const Scan = struct {
    pending: std.ArrayListUnmanaged(Pending) = .empty,

    pub const Pending = struct {
        object_index: u32,
        section_index: u32,
        bytes: []const u8 = &.{},
        relocations: []const Rela = &.{},
        piece_count: usize = 0,
        relocation_count: usize = 0,
        cie_count: usize = 0,
        output_size: u64 = 0,
        pieces: []EhFramePieceLayout = &.{},
        adjusted: []Rela = &.{},
        cies: []EhFrameCieLayout = &.{},
        failure: model.Error!void = {},
    };

    const PhaseContext = struct {
        pending: []Pending,
        objects: []const ObjectFile,
        globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    };

    pub const Reference = struct {
        object_index: u32,
        section_index: u32,
    };

    pub fn deinit(self: *Scan, allocator: Allocator) void {
        for (self.pending.items) |entry| {
            if (entry.cies.len != 0) allocator.free(entry.cies);
        }
        self.pending.deinit(allocator);
    }

    pub fn prepare(
        self: *Scan,
        allocator: Allocator,
        objects: []const ObjectFile,
        layouts: []ObjectLayout,
        globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
        options: model.LinkOptions,
        references: []const Reference,
    ) model.Error!void {
        var total_bytes: usize = 0;
        try self.pending.ensureTotalCapacity(allocator, references.len);
        for (references) |reference| {
            const object = objects[reference.object_index];
            const section_header = object.sections[reference.section_index];
            var entry = Pending{
                .object_index = reference.object_index,
                .section_index = reference.section_index,
                .relocations = object.relocationsForSection(reference.section_index),
            };
            if (sectionBytes(object.bytes, section_header)) |bytes| {
                entry.bytes = bytes;
                total_bytes += bytes.len;
            } else |err| {
                entry.failure = err;
            }
            self.pending.appendAssumeCapacity(entry);
        }
        if (self.pending.items.len == 0) return;

        const pending = self.pending.items;
        const workers = if (total_bytes >= parallel_scan_threshold)
            parallel.chooseWorkers(
                pending.len,
                parallel.grainWorkers(options.max_link_jobs, total_bytes, scan_bytes_per_worker),
            )
        else
            1;

        var context = PhaseContext{ .pending = pending, .objects = objects, .globals = globals };
        if (workers <= 1) {
            for (pending, 0..) |_, index| countPending(&context, 0, index);
        } else {
            parallel.forItems(pending.len, workers, &context, countPending);
        }

        for (pending) |*entry| {
            entry.failure catch continue;
            entry.pieces = try allocator.alloc(EhFramePieceLayout, entry.piece_count);
            entry.adjusted = try allocator.alloc(Rela, entry.relocation_count);
            const slots = try ensureLayouts(allocator, objects[entry.object_index], &layouts[entry.object_index].eh_frame_sections);
            slots[entry.section_index] = .{
                .present = true,
                .pieces = entry.pieces,
                .relocations = entry.adjusted,
            };
            entry.cies = try allocator.alloc(EhFrameCieLayout, entry.cie_count);
        }

        if (workers <= 1) {
            for (pending, 0..) |_, index| fillPending(&context, 0, index);
        } else {
            parallel.forItems(pending.len, workers, &context, fillPending);
        }
    }

    fn countPending(context: *PhaseContext, worker: usize, index: usize) void {
        _ = worker;
        const entry = &context.pending[index];
        entry.failure catch return;
        var consumer = Count{};
        entry.output_size = section.walk(
            context.objects,
            entry.object_index,
            entry.bytes,
            entry.relocations,
            context.globals,
            &consumer,
        ) catch |err| {
            entry.failure = err;
            return;
        };
        entry.piece_count = consumer.pieces;
        entry.relocation_count = consumer.relocations;
        entry.cie_count = consumer.cies;
    }

    fn fillPending(context: *PhaseContext, worker: usize, index: usize) void {
        _ = worker;
        const entry = &context.pending[index];
        entry.failure catch return;
        var consumer = Fill{ .entry = entry };
        const output_size = section.walk(
            context.objects,
            entry.object_index,
            entry.bytes,
            entry.relocations,
            context.globals,
            &consumer,
        ) catch |err| {
            entry.failure = err;
            return;
        };
        std.debug.assert(output_size == entry.output_size);
        std.debug.assert(consumer.piece_index == entry.piece_count);
        std.debug.assert(consumer.relocation_index == entry.relocation_count);
        std.debug.assert(consumer.cie_index == entry.cie_count);
    }
};

const Count = struct {
    pieces: usize = 0,
    relocations: usize = 0,
    cies: usize = 0,

    pub fn piece(self: *Count, piece_layout: EhFramePieceLayout) void {
        _ = piece_layout;
        self.pieces += 1;
    }

    pub fn cie(self: *Count, input_offset: u64, output_offset: u64) void {
        _ = input_offset;
        _ = output_offset;
        self.cies += 1;
    }

    pub fn relocation(self: *Count, adjusted: Rela) void {
        _ = adjusted;
        self.relocations += 1;
    }

    pub fn resolve(self: *Count, cie_input_offset: u64, output_size: u64) model.Error!u32 {
        _ = self;
        _ = cie_input_offset;
        _ = output_size;
        return 0;
    }
};

const Fill = struct {
    entry: *Scan.Pending,
    piece_index: usize = 0,
    relocation_index: usize = 0,
    cie_index: usize = 0,

    pub fn piece(self: *Fill, piece_layout: EhFramePieceLayout) void {
        self.entry.pieces[self.piece_index] = piece_layout;
        self.piece_index += 1;
    }

    pub fn cie(self: *Fill, input_offset: u64, output_offset: u64) void {
        self.entry.cies[self.cie_index] = .{
            .input_offset = input_offset,
            .output_offset = output_offset,
        };
        self.cie_index += 1;
    }

    pub fn relocation(self: *Fill, adjusted: Rela) void {
        self.entry.adjusted[self.relocation_index] = adjusted;
        self.relocation_index += 1;
    }

    pub fn resolve(self: *Fill, cie_input_offset: u64, output_size: u64) model.Error!u32 {
        const cie_output_offset = section.cieOutputOffset(self.entry.cies[0..self.cie_index], cie_input_offset) orelse return error.InvalidObject;
        if (output_size + 4 < cie_output_offset) return error.InvalidObject;
        return std.math.cast(u32, output_size + 4 - cie_output_offset) orelse return error.InvalidRange;
    }
};

fn ensureLayouts(
    allocator: Allocator,
    object: ObjectFile,
    eh_frame_sections: *[]EhFrameSectionLayout,
) Allocator.Error![]EhFrameSectionLayout {
    if (eh_frame_sections.*.len != 0) return eh_frame_sections.*;
    const sections = try allocator.alloc(EhFrameSectionLayout, object.sections.len);
    @memset(sections, .{});
    eh_frame_sections.* = sections;
    return sections;
}

fn testWalkBytes() [44]u8 {
    var bytes = @as([44]u8, @splat(0));
    std.mem.writeInt(u32, bytes[0..4], 16, .little);
    std.mem.writeInt(u32, bytes[4..8], 0, .little);
    std.mem.writeInt(u32, bytes[20..24], 16, .little);
    std.mem.writeInt(u32, bytes[24..28], 24, .little);
    std.mem.writeInt(u32, bytes[40..44], 0, .little);
    return bytes;
}

test "count and fill walks agree on synthetic eh_frame records" {
    const bytes = testWalkBytes();
    const globals: std.StringHashMapUnmanaged(GlobalSymbol) = .empty;

    var count = Count{};
    const counted_size = try section.walk(&.{}, 0, &bytes, &.{}, &globals, &count);
    try std.testing.expectEqual(@as(u64, 44), counted_size);
    try std.testing.expectEqual(@as(usize, 3), count.pieces);
    try std.testing.expectEqual(@as(usize, 1), count.cies);
    try std.testing.expectEqual(@as(usize, 0), count.relocations);

    var pieces: [3]EhFramePieceLayout = undefined;
    var cies: [1]EhFrameCieLayout = undefined;
    var entry = Scan.Pending{
        .object_index = 0,
        .section_index = 0,
        .pieces = &pieces,
        .cies = &cies,
    };
    var fill = Fill{ .entry = &entry };
    const filled_size = try section.walk(&.{}, 0, &bytes, &.{}, &globals, &fill);
    try std.testing.expectEqual(counted_size, filled_size);
    try std.testing.expectEqual(count.pieces, fill.piece_index);
    try std.testing.expectEqual(count.cies, fill.cie_index);

    try std.testing.expectEqual(@as(u64, 0), pieces[0].input_offset);
    try std.testing.expectEqual(@as(u64, 20), pieces[0].size);
    try std.testing.expect(!pieces[0].patch_cie_pointer);
    try std.testing.expectEqual(@as(u64, 20), pieces[1].input_offset);
    try std.testing.expectEqual(@as(u64, 20), pieces[1].output_offset);
    try std.testing.expect(pieces[1].patch_cie_pointer);
    try std.testing.expectEqual(@as(u32, 24), pieces[1].cie_pointer);
    try std.testing.expectEqual(@as(u64, 40), pieces[2].input_offset);
    try std.testing.expectEqual(@as(u64, 4), pieces[2].size);
    try std.testing.expectEqual(@as(u64, 0), cies[0].input_offset);
}

test "fill walk rejects an unresolved cie reference" {
    var bytes = @as([24]u8, @splat(0));
    std.mem.writeInt(u32, bytes[0..4], 16, .little);
    std.mem.writeInt(u32, bytes[4..8], 3, .little);
    std.mem.writeInt(u32, bytes[20..24], 0, .little);
    const globals: std.StringHashMapUnmanaged(GlobalSymbol) = .empty;

    var count = Count{};
    _ = try section.walk(&.{}, 0, &bytes, &.{}, &globals, &count);

    var pieces: [2]EhFramePieceLayout = undefined;
    var entry = Scan.Pending{
        .object_index = 0,
        .section_index = 0,
        .pieces = &pieces,
    };
    var fill = Fill{ .entry = &entry };
    try std.testing.expectError(error.InvalidObject, section.walk(&.{}, 0, &bytes, &.{}, &globals, &fill));
}
