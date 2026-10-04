const std = @import("std");
const pretty = @import("pretty");
const root = @import("../../root.zig");
const format = @import("format.zig");
const layout = @import("layout/root.zig");
const parser = @import("parser.zig");

const model = root.model;
const parallel = root.parallel;
const ObjectFile = parser.ObjectFile;
const SectionHeader = format.SectionHeader;
const sectionBytes = format.sectionBytes;
const copyInto = format.copyInto;
const writeU32 = format.writeU32;
const OutputSection = layout.OutputSection;
const SectionContribution = layout.SectionContribution;
const ObjectLayout = layout.ObjectLayout;
const EhFrameSectionLayout = layout.EhFrameSectionLayout;
const contributionAt = layout.contributionAt;

const CopyFailure = struct {
    found: bool = false,
    object_index: usize = 0,
    section_index: usize = 0,
    err: model.Error = error.InvalidObject,

    fn isFound(failure: CopyFailure) bool {
        return failure.found;
    }

    fn before(left: CopyFailure, right: CopyFailure) bool {
        if (left.object_index != right.object_index) return left.object_index < right.object_index;
        return left.section_index < right.section_index;
    }
};

const CopyFailures = parallel.FailureSlots(CopyFailure);

const ParallelObjectCopyContext = struct {
    image: []u8,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    worker_budget: usize,
    failures: *CopyFailures,
};

const SectionCopyTask = struct {
    object_index: usize,
    section_index: usize,
};

const ParallelSectionCopyContext = struct {
    image: []u8,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    worker_budget: usize,
    tasks: []const SectionCopyTask,
    failures: *CopyFailures,
};

const CopyRun = struct {
    worker_budget: usize,
    source_start: usize = 0,
    dest_start: usize = 0,
    len: usize = 0,

    fn append(self: *CopyRun, image: []u8, object_bytes: []const u8, source_start: usize, dest_start: usize, len: usize) void {
        if (len == 0) return;
        if (self.len != 0 and source_start == self.source_start + self.len and dest_start == self.dest_start + self.len) {
            self.len += len;
            return;
        }
        self.flush(image, object_bytes);
        self.* = .{
            .worker_budget = self.worker_budget,
            .source_start = source_start,
            .dest_start = dest_start,
            .len = len,
        };
    }

    fn flush(self: *CopyRun, image: []u8, object_bytes: []const u8) void {
        if (self.len == 0) return;
        const bytes = object_bytes[self.source_start..][0..self.len];
        copyBytes(image, self.dest_start, bytes, self.worker_budget);
        self.len = 0;
    }
};

const copy_run_section_threshold = 128;
const parallel_section_copy_threshold = 8 * 1024 * 1024;
const parallel_copy_threshold = 8 * 1024 * 1024;
pub const parallel_object_copy_threshold = 16 * 1024 * 1024;
const parallel_copy_bytes_per_worker = 8 * 1024 * 1024;
const parallel_section_copy_bytes_per_worker = 4 * 1024 * 1024;

const ParallelCopy = struct {
    dest: []u8,
    source: []const u8,
};

fn copyChunk(copy: *ParallelCopy, worker: usize, start: usize, end: usize) void {
    _ = worker;
    @memcpy(copy.dest[start..end], copy.source[start..end]);
}

fn copyBytes(image: []u8, start: usize, bytes: []const u8, worker_budget: usize) void {
    if (bytes.len == 0) return;
    const dest = image[start..][0..bytes.len];
    if (bytes.len >= parallel_copy_threshold) {
        var copy = ParallelCopy{
            .dest = dest,
            .source = bytes,
        };
        const workers =
            parallel.grainWorkers(worker_budget, bytes.len, parallel_copy_bytes_per_worker);
        parallel.forChunks(bytes.len, workers, &copy, copyChunk);
        return;
    }
    @memcpy(dest, bytes);
}

test "parallel payload copy matches direct copy" {
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, parallel_copy_threshold + 4096);
    defer allocator.free(source);
    for (source, 0..) |*byte, index| byte.* = @truncate(index *% 251);

    const padding = 32;
    const parallel_image = try allocator.alloc(u8, source.len + padding * 2);
    defer allocator.free(parallel_image);
    const serial_image = try allocator.alloc(u8, source.len + padding * 2);
    defer allocator.free(serial_image);
    @memset(parallel_image, 0xaa);
    @memset(serial_image, 0xaa);

    copyBytes(parallel_image, padding, source, 8);
    @memcpy(serial_image[padding..][0..source.len], source);

    try std.testing.expectEqualSlices(u8, serial_image, parallel_image);
}

pub fn verifyMergePieceBytes(
    image: []const u8,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
) void {
    var clobbered: usize = 0;
    for (objects, 0..) |object, object_index| {
        const object_layout = layouts[object_index];
        for (object.sections, 0..) |section_header, section_index| {
            const merge_section = layout.mergeSection(object_layout, section_index) orelse continue;
            const bytes = sectionBytes(object.bytes, section_header) catch continue;
            for (merge_section.pieces) |piece| {
                const output = output_sections[piece.contribution.outputIndex()];
                const start: usize = @intCast(output.file_offset + piece.contribution.offset + piece.output_intra_offset);
                const piece_offset: usize = @intCast(piece.input_offset);
                const piece_size: usize = @intCast(piece.size);
                if (start > image.len or piece_size > image.len - start) {
                    pretty.diagnostic.writeStderrText(
                        "PIECE OOB {s} sec={d} off={d}\n",
                        .{ object.name, section_index, piece.input_offset },
                    );
                    continue;
                }
                if (!std.mem.eql(u8, image[start..][0..piece_size], bytes[piece_offset..][0..piece_size])) {
                    clobbered += 1;
                    if (clobbered <= 8) {
                        pretty.diagnostic.writeStderrText(
                            "PIECE CLOBBERED {s} sec={d} in_off={d} size={d} at=0x{x}\n",
                            .{ object.name, section_index, piece.input_offset, piece.size, start },
                        );
                    }
                }
            }
        }
    }
    if (clobbered != 0) {
        pretty.diagnostic.writeStderrText("PIECE CLOBBERED total={d}\n", .{clobbered});
    }
}

pub fn wantsBatchedObjectCopy(objects: []const ObjectFile) bool {
    return objects.len == 1 and objects[0].sections.len >= copy_run_section_threshold;
}

pub fn copyAllocSections(
    scratch: std.mem.Allocator,
    image: []u8,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    options: model.LinkOptions,
) model.Error!void {
    const worker_budget = options.max_link_jobs;
    if (wantsBatchedObjectCopy(objects)) {
        return copyObjectAllocSectionsBatched(
            image,
            objects[0],
            layouts[0],
            output_sections,
            worker_budget,
        );
    }

    const load_bytes = outputFileLoadBytes(output_sections);
    if (load_bytes < parallel_object_copy_threshold) {
        if (load_bytes >= parallel_section_copy_threshold) {
            return copyAllocSectionsParallelBySection(
                scratch,
                image,
                objects,
                layouts,
                output_sections,
                load_bytes,
                worker_budget,
            );
        }
        return copyAllocSectionsSerial(image, objects, layouts, output_sections, worker_budget);
    }

    const workers = parallel.chooseWorkers(
        objects.len,
        parallel.grainWorkers(worker_budget, load_bytes, parallel_copy_bytes_per_worker),
    );

    if (workers > 1) return copyAllocSectionsParallel(
        scratch,
        image,
        objects,
        layouts,
        output_sections,
        workers,
        worker_budget,
    );

    try copyAllocSectionsSerial(image, objects, layouts, output_sections, worker_budget);
}

fn copyAllocSectionsParallelBySection(
    scratch: std.mem.Allocator,
    image: []u8,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    load_bytes: usize,
    worker_budget: usize,
) model.Error!void {
    const section_workers =
        parallel.grainWorkers(worker_budget, load_bytes, parallel_section_copy_bytes_per_worker);
    if (section_workers <= 1) {
        return copyAllocSectionsSerial(image, objects, layouts, output_sections, worker_budget);
    }

    var tasks = std.ArrayListUnmanaged(SectionCopyTask).empty;
    defer tasks.deinit(scratch);
    for (objects, 0..) |object, object_index| {
        try tasks.ensureUnusedCapacity(scratch, object.sections.len);
        for (object.sections, 0..) |_, section_index| {
            tasks.appendAssumeCapacity(.{
                .object_index = object_index,
                .section_index = section_index,
            });
        }
    }
    if (tasks.items.len == 0) return;
    const workers = parallel.chooseWorkers(tasks.items.len, section_workers);
    if (workers <= 1) {
        return copyAllocSectionsSerial(image, objects, layouts, output_sections, worker_budget);
    }

    var failures = try CopyFailures.init(scratch, workers, .{});
    defer failures.deinit(scratch);

    var context = ParallelSectionCopyContext{
        .image = image,
        .objects = objects,
        .layouts = layouts,
        .output_sections = output_sections,
        .worker_budget = worker_budget,
        .tasks = tasks.items,
        .failures = &failures,
    };
    parallel.forItems(tasks.items.len, workers, &context, copySectionTask);
    if (failures.earliest(CopyFailure.isFound, CopyFailure.before)) |failure| return failure.err;
}

fn copyAllocSectionsSerial(
    image: []u8,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    worker_budget: usize,
) model.Error!void {
    for (objects, 0..) |object, object_index| {
        const object_layout = layouts[object_index];
        try copyObjectSections(image, object, object_layout, output_sections, worker_budget);
    }
}

fn copyAllocSectionsParallel(
    scratch: std.mem.Allocator,
    image: []u8,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    workers: usize,
    worker_budget: usize,
) model.Error!void {
    var failures = try CopyFailures.init(scratch, workers, .{});
    defer failures.deinit(scratch);

    var context = ParallelObjectCopyContext{
        .image = image,
        .objects = objects,
        .layouts = layouts,
        .output_sections = output_sections,
        .worker_budget = worker_budget,
        .failures = &failures,
    };
    parallel.forItems(objects.len, workers, &context, copyObjectTask);
    if (failures.earliest(CopyFailure.isFound, CopyFailure.before)) |failure| return failure.err;
}

fn copyObjectTask(context: *ParallelObjectCopyContext, worker: usize, object_index: usize) void {
    copyObjectSections(
        context.image,
        context.objects[object_index],
        context.layouts[object_index],
        context.output_sections,
        context.worker_budget,
    ) catch |err| {
        const current = context.failures.items[worker];
        const failure = CopyFailure{
            .found = true,
            .object_index = object_index,
            .err = err,
        };
        if (!current.found or CopyFailure.before(failure, current)) {
            context.failures.record(worker, failure);
        }
    };
}

fn copySectionTask(context: *ParallelSectionCopyContext, worker: usize, task_index: usize) void {
    const task = context.tasks[task_index];
    copySection(
        context.image,
        context.objects[task.object_index],
        context.layouts[task.object_index],
        context.output_sections,
        task.section_index,
        context.worker_budget,
    ) catch |err| {
        const current = context.failures.items[worker];
        const failure = CopyFailure{
            .found = true,
            .object_index = task.object_index,
            .section_index = task.section_index,
            .err = err,
        };
        if (!current.found or CopyFailure.before(failure, current)) {
            context.failures.record(worker, failure);
        }
    };
}

pub fn copyObjectSections(
    image: []u8,
    object: ObjectFile,
    object_layout: ObjectLayout,
    output_sections: []const OutputSection,
    worker_budget: usize,
) model.Error!void {
    if (object.sections.len >= copy_run_section_threshold) {
        return copyObjectAllocSectionsBatched(
            image,
            object,
            object_layout,
            output_sections,
            worker_budget,
        );
    }

    for (object.sections, 0..) |_, section_index| {
        try copySection(
            image,
            object,
            object_layout,
            output_sections,
            section_index,
            worker_budget,
        );
    }
}

fn copySection(
    image: []u8,
    object: ObjectFile,
    object_layout: ObjectLayout,
    output_sections: []const OutputSection,
    section_index: usize,
    worker_budget: usize,
) model.Error!void {
    const section_header = object.sections[section_index];
    if (layout.ehFrameSection(object_layout, section_index)) |eh_frame_section| {
        const contribution = contributionAt(object_layout.sections, section_index) orelse return;
        if (section_header.section_type == std.elf.SHT_NOBITS) return;
        const output = output_sections[contribution.outputIndex()];
        try copyEhFrameSection(image, object, section_header, output, contribution.*, eh_frame_section);
        return;
    }

    if (layout.mergeSection(object_layout, section_index)) |merge_section| {
        const bytes = try sectionBytes(object.bytes, section_header);
        for (merge_section.pieces) |piece| {
            const output = output_sections[piece.contribution.outputIndex()];
            const start: usize = @intCast(output.file_offset + piece.contribution.offset + piece.output_intra_offset);
            const piece_offset: usize = @intCast(piece.input_offset);
            const piece_size: usize = @intCast(piece.size);
            if (@import("builtin").mode == .debug) {
                if (piece.contribution.offset == 0 and piece.size != 0 and piece.contribution.size == 0) {
                    pretty.diagnostic.writeStderrText(
                        "CLOBBER unassigned piece: {s} sec={d} in_off={d} size={d}\n",
                        .{ object.name, section_index, piece.input_offset, piece.size },
                    );
                }
            }
            copyInto(image, start, bytes[piece_offset..][0..piece_size]);
        }
        return;
    }

    const contribution = contributionAt(object_layout.sections, section_index) orelse return;
    if (section_header.section_type == std.elf.SHT_NOBITS) return;

    const output = output_sections[contribution.outputIndex()];
    const start: usize = @intCast(output.file_offset + contribution.offset);
    copyBytes(image, start, try sectionBytes(object.bytes, section_header), worker_budget);
}

fn copyObjectAllocSectionsBatched(
    image: []u8,
    object: ObjectFile,
    object_layout: ObjectLayout,
    output_sections: []const OutputSection,
    worker_budget: usize,
) model.Error!void {
    var run = CopyRun{ .worker_budget = worker_budget };
    for (object.sections, 0..) |section_header, section_index| {
        if (layout.ehFrameSection(object_layout, section_index)) |eh_frame_section| {
            run.flush(image, object.bytes);
            const contribution = contributionAt(object_layout.sections, section_index) orelse continue;
            if (section_header.section_type == std.elf.SHT_NOBITS) continue;
            const output = output_sections[contribution.outputIndex()];
            try copyEhFrameSection(image, object, section_header, output, contribution.*, eh_frame_section);
            continue;
        }

        if (layout.mergeSection(object_layout, section_index)) |merge_section| {
            run.flush(image, object.bytes);
            const bytes = try sectionBytes(object.bytes, section_header);
            for (merge_section.pieces) |piece| {
                const output = output_sections[piece.contribution.outputIndex()];
                const start: usize = @intCast(output.file_offset + piece.contribution.offset + piece.output_intra_offset);
                const piece_offset: usize = @intCast(piece.input_offset);
                const piece_size: usize = @intCast(piece.size);
                copyInto(image, start, bytes[piece_offset..][0..piece_size]);
            }
            continue;
        }

        const contribution = contributionAt(object_layout.sections, section_index) orelse continue;
        if (section_header.section_type == std.elf.SHT_NOBITS) continue;

        const output = output_sections[contribution.outputIndex()];
        const start: usize = @intCast(output.file_offset + contribution.offset);
        const bytes = try sectionBytes(object.bytes, section_header);
        run.append(image, object.bytes, @intCast(section_header.offset), start, bytes.len);
    }
    run.flush(image, object.bytes);
}

fn copyEhFrameSection(
    image: []u8,
    object: ObjectFile,
    section_header: SectionHeader,
    output: OutputSection,
    contribution: SectionContribution,
    eh_frame_section: EhFrameSectionLayout,
) model.Error!void {
    const bytes = try sectionBytes(object.bytes, section_header);
    for (eh_frame_section.pieces) |piece| {
        const input_offset: usize = @intCast(piece.input_offset);
        const size: usize = @intCast(piece.size);
        const output_offset: usize = @intCast(output.file_offset + contribution.offset + piece.output_offset);
        copyInto(image, output_offset, bytes[input_offset..][0..size]);
        if (piece.patch_cie_pointer) writeU32(image, output_offset + 4, piece.cie_pointer);
    }
}

fn outputFileLoadBytes(output_sections: []const OutputSection) usize {
    var total: usize = 0;
    for (output_sections) |section| {
        const size = std.math.cast(usize, section.fileLoadSize()) orelse return std.math.maxInt(usize);
        total = std.math.add(usize, total, size) catch return std.math.maxInt(usize);
    }
    return total;
}
