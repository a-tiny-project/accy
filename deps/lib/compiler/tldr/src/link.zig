const std = @import("std");
const model = @import("model.zig");
const object = @import("object.zig");
const parallel = @import("parallel.zig");
const trace = @import("trace.zig");
const formats = @import("formats/root.zig");
const incremental = @import("incremental/root.zig");

const Input = model.Input;
const LinkOptions = model.LinkOptions;
const Error = model.Error;
const Diagnostics = model.Diagnostics;
const LinkedImage = object.LinkedImage;

pub fn link(
    allocator: std.mem.Allocator,
    inputs: []const Input,
    options: LinkOptions,
) Error!LinkedImage {
    const phase = trace.scope("link");
    defer phase.end();
    parallel.assertBudget(options.max_link_jobs);
    if (options.diagnostics) |diagnostics| diagnostics.clear();
    try model.validateOptions(options);
    return switch (options.target.object_format) {
        .elf => try formats.elf.linkExecutable(allocator, inputs, options),
        .coff => {
            {
                const input_phase = trace.product(.input_discovery);
                defer input_phase.end();
                try formats.validateInputFormats(inputs, options);
            }
            return try formats.coff.linkExecutable(allocator, inputs, options);
        },
        .macho => {
            {
                const input_phase = trace.product(.input_discovery);
                defer input_phase.end();
                try formats.validateInputFormats(inputs, options);
            }
            return try formats.macho.linkExecutable(allocator, inputs, options);
        },
        .wasm => error.UnsupportedFormat,
    };
}

pub fn applyIncrementalMetadataPatch(
    image: []u8,
    candidate_image: []const u8,
    options: LinkOptions,
) Error!void {
    return switch (options.target.object_format) {
        .elf => try formats.elf.patchIncrementalMetadata(image, candidate_image),
        .coff, .macho => {},
        .wasm => error.UnsupportedFormat,
    };
}

pub fn finishDirectIncrementalMetadataPatch(
    image: []u8,
    options: LinkOptions,
) Error!void {
    return switch (options.target.object_format) {
        .elf => try formats.elf.finishIncrementalMetadata(image, options),
        .coff, .macho => {},
        .wasm => error.UnsupportedFormat,
    };
}

pub const MetadataPatchRange = struct {
    offset: usize,
    len: usize,
};

pub fn incrementalBuildIdNoteRange(
    image: []const u8,
    options: LinkOptions,
) Error!?MetadataPatchRange {
    return switch (options.target.object_format) {
        .elf => {
            const range = (try formats.elf.buildIdNoteRange(image)) orelse return null;
            return .{ .offset = range.offset, .len = range.len };
        },
        .coff, .macho => null,
        .wasm => error.UnsupportedFormat,
    };
}

pub fn incrementalMetadataPatchRange(
    image: []const u8,
    options: LinkOptions,
) Error!?MetadataPatchRange {
    return switch (options.target.object_format) {
        .elf => {
            const range = try formats.elf.patchIncrementalMetadataRange(image);
            return .{ .offset = range.offset, .len = range.len };
        },
        .coff, .macho => null,
        .wasm => error.UnsupportedFormat,
    };
}

pub fn directIncrementalEvidenceAlloc(
    allocator: std.mem.Allocator,
    manifest: incremental.Manifest,
    inputs: []const Input,
    input_changes: incremental.InputChanges,
    options: LinkOptions,
) Error!incremental.DirectRelinkEvidence {
    return switch (options.target.object_format) {
        .elf => try formats.elf.relink.directEvidenceAlloc(allocator, manifest, inputs, input_changes, options),
        .coff, .macho, .wasm => .{},
    };
}
