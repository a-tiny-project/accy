const std = @import("std");
const sys = @import("sys");
const tldr = @import("../../root.zig");
const elf = @import("root.zig");
const link = @import("link.zig");
const metadata = @import("metadata.zig");

pub const address_suite = @import("address/test.zig");
pub const archive_suite = @import("archive/test.zig");
pub const ehframe_suite = @import("ehframe/test.zig");
pub const group_suite = @import("group/test.zig");
pub const icf_suite = @import("icf/test.zig");
pub const image_suite = @import("image/test.zig");
pub const layout_suite = @import("layout/test.zig");
pub const liveness_suite = @import("liveness/test.zig");
pub const merge_suite = @import("merge/test.zig");
pub const object_suite = @import("object/test.zig");
pub const relocation_suite = @import("relocation/test.zig");

const archive = tldr.archive;
const incremental = tldr.incremental;
const model = tldr.model;
const format = elf.format;
const build_id_note = elf.note;
const ifunc = elf.ifunc;
const payload = elf.payload;
const symbol_table = elf.symbol_table;

const ehdr_size = format.ehdr_size;
const phdr_size = format.phdr_size;
const eh_frame_hdr_fixed_size = format.eh_frame_hdr_fixed_size;
const eh_frame_hdr_entry_size = format.eh_frame_hdr_entry_size;
const dwarf_eh_pe_udata4 = format.dwarf_eh_pe_udata4;
const dwarf_eh_pe_sdata4 = format.dwarf_eh_pe_sdata4;
const dwarf_eh_pe_pcrel = format.dwarf_eh_pe_pcrel;
const dwarf_eh_pe_datarel = format.dwarf_eh_pe_datarel;
const buildIdNoteSize = build_id_note.size;
const alignForward = format.alignForward;
const alignForwardU64 = format.alignForwardU64;
const readU16 = format.readU16;
const readU32 = format.readU32;
const readU64 = format.readU64;

const Allocator = std.mem.Allocator;
const linkExecutable = elf.linkExecutable;
const patchIncrementalMetadata = elf.patchIncrementalMetadata;
const object_writer = elf.object;
const Section = object_writer.Section;
const Symbol = object_writer.Symbol;
const Relocation = object_writer.Relocation;
const groupBytes = object_writer.groupBytes;
const buildObject = object_writer.build;

fn coffHeaderBytes() [@sizeOf(std.coff.Header)]u8 {
    var bytes = @as([@sizeOf(std.coff.Header)]u8, @splat(0));
    std.mem.writeInt(u16, bytes[0..2], @backingInt(std.coff.IMAGE.FILE.MACHINE.AMD64), .little);
    return bytes;
}

fn expectAllZeroes(bytes: []const u8) !void {
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "ELF linker emits executable with incremental section manifest" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0xb8, 0x3c, 0x00, 0x00, 0x00,
        0x31, 0xff, 0x0f, 0x05,
    };
    const text_index: u16 = 1;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{ Symbol.section(text_index), Symbol.function("_start", text_index, 0, text.len) },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "start.o", .bytes = object }}, .{});
    defer linked.deinit(allocator);

    try std.testing.expectEqualSlices(u8, std.elf.MAGIC, linked.bytes[0..4]);
    try std.testing.expectEqual(@as(u16, @backingInt(std.elf.ET.EXEC)), readU16(linked.bytes, 16));
    try std.testing.expectEqual(@as(u16, 2), readU16(linked.bytes, 56));
    try std.testing.expect(linked.manifest.canReuseFor(.{}, &.{.{ .name = "start.o", .bytes = object }}));
    try std.testing.expectEqualStrings(".text", linked.manifest.string(linked.manifest.sections[0].name_id));
    try std.testing.expect(linked.manifest.sections[0].reserved_size > linked.manifest.sections[0].size);

    const text_contribution = metadata.manifestContribution(linked.manifest, "start.o", .section, ".text", text_index) orelse return error.MissingSection;
    try std.testing.expectEqualStrings(".text", linked.manifest.string(text_contribution.output_section_name_id));
    try std.testing.expectEqual(linked.manifest.sections[0].address, text_contribution.address);
    try std.testing.expectEqual(linked.manifest.sections[0].file_offset, text_contribution.file_offset);
    try std.testing.expectEqual(@as(u64, text.len), text_contribution.size);
    try std.testing.expect(text_contribution.reserved_size > text_contribution.size);
    _ = try metadata.programHeaderByType(linked.bytes, @backingInt(std.elf.PT.PHDR));
    _ = try metadata.loadProgramHeaderByAddress(linked.bytes, text_contribution.address);

    const plan = linked.manifest.planContributionReplacement(&.{
        .{ .input_name = "start.o", .input_index = 0, .kind = .section, .name = ".text", .ordinal = text_index, .size = text.len + 1, .alignment = 16 },
    });
    try std.testing.expectEqual(incremental.PatchDecision.in_place, plan.decision);
}

test "ELF linker mapped output matches heap output" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0xb8, 0x3c, 0x00, 0x00, 0x00,
        0x31, 0xff, 0x0f, 0x05,
    };
    const text_index: u16 = 1;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{ Symbol.section(text_index), Symbol.function("_start", text_index, 0, text.len) },
    });
    defer allocator.free(object);
    const inputs = [_]model.Input{.{ .name = "start.o", .bytes = object }};

    var heap_linked = try linkExecutable(allocator, &inputs, .{});
    defer heap_linked.deinit(allocator);
    try std.testing.expect(!heap_linked.isMaterialized());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output_file = try tmp.dir.createFile(sys.fs.debugIo(), "mapped.out", .{ .read = true });
    defer output_file.close(sys.fs.debugIo());

    var mapped_linked = try linkExecutable(allocator, &inputs, .{
        .mapped_output_file = output_file,
        .mapped_output_min_size = 0,
    });
    try std.testing.expect(mapped_linked.isMaterialized());
    try std.testing.expectEqualSlices(u8, heap_linked.bytes, mapped_linked.bytes);
    const mapped_len = mapped_linked.bytes.len;
    mapped_linked.deinit(allocator);

    const file_bytes = try tmp.dir.readFileAlloc(sys.fs.debugIo(), "mapped.out", allocator, .limited(mapped_len + 1));
    defer allocator.free(file_bytes);
    try std.testing.expectEqualSlices(u8, heap_linked.bytes, file_bytes);
}

test "ELF linker emits GNU SHA1 build id note" {
    const allocator = std.testing.allocator;
    const text = [_]u8{0xc3};
    const text_index: u16 = 1;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{ Symbol.section(text_index), Symbol.function("_start", text_index, 0, text.len) },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "build-id.o", .bytes = object }}, .{
        .incremental_mode = .off,
        .build_id = .sha1,
    });
    defer linked.deinit(allocator);

    const build_note = try metadata.linkedSectionByName(linked.bytes, build_id_note.section_name);
    try std.testing.expectEqual(std.elf.SHT_NOTE, build_note.section_type);
    try std.testing.expectEqual(std.elf.SHF_ALLOC, build_note.flags);
    try std.testing.expectEqual(buildIdNoteSize(.sha1), build_note.size);
    try std.testing.expectEqual(@as(u64, 4), build_note.alignment);

    const note_program = try metadata.programHeaderByType(linked.bytes, @backingInt(std.elf.PT.NOTE));
    try std.testing.expectEqual(build_note.offset, note_program.file_offset);
    try std.testing.expectEqual(build_note.address, note_program.virtual_address);
    try std.testing.expectEqual(build_note.size, note_program.file_size);
    try std.testing.expectEqual(build_note.size, note_program.memory_size);

    const start: usize = @intCast(build_note.offset);
    try std.testing.expectEqual(@as(u32, 4), readU32(linked.bytes, start + 0));
    try std.testing.expectEqual(@as(u32, build_id_note.sha1_desc_size), readU32(linked.bytes, start + 4));
    try std.testing.expectEqual(@as(u32, std.elf.NT_GNU_BUILD_ID), readU32(linked.bytes, start + 8));
    try std.testing.expectEqualSlices(u8, "GNU\x00", linked.bytes[start + 12 .. start + 16]);

    const comparable = try allocator.dupe(u8, linked.bytes);
    defer allocator.free(comparable);
    @memset(comparable[start + build_id_note.desc_offset ..][0..build_id_note.sha1_desc_size], 0);
    var expected: [build_id_note.sha1_desc_size]u8 = undefined;
    std.crypto.hash.Sha1.hash(comparable, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, linked.bytes[start + build_id_note.desc_offset ..][0..build_id_note.sha1_desc_size]);

    const note_record = metadata.manifestSection(linked.manifest, build_id_note.section_name) orelse return error.MissingSection;
    try std.testing.expectEqual(build_note.offset, note_record.file_offset);
}

test "ELF linker emits fast GNU build id note" {
    const allocator = std.testing.allocator;
    const text = [_]u8{0xc3};
    const text_index: u16 = 1;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{ Symbol.section(text_index), Symbol.function("_start", text_index, 0, text.len) },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "build-id-fast.o", .bytes = object }}, .{
        .incremental_mode = .off,
        .build_id = .fast,
    });
    defer linked.deinit(allocator);

    const build_note = try metadata.linkedSectionByName(linked.bytes, build_id_note.section_name);
    try std.testing.expectEqual(std.elf.SHT_NOTE, build_note.section_type);
    try std.testing.expectEqual(std.elf.SHF_ALLOC, build_note.flags);
    try std.testing.expectEqual(buildIdNoteSize(.fast), build_note.size);

    const start: usize = @intCast(build_note.offset);
    try std.testing.expectEqual(@as(u32, 4), readU32(linked.bytes, start + 0));
    try std.testing.expectEqual(@as(u32, build_id_note.fast_desc_size), readU32(linked.bytes, start + 4));
    try std.testing.expectEqual(@as(u32, std.elf.NT_GNU_BUILD_ID), readU32(linked.bytes, start + 8));
    try std.testing.expectEqualSlices(u8, "GNU\x00", linked.bytes[start + 12 .. start + 16]);

    const comparable = try allocator.dupe(u8, linked.bytes);
    defer allocator.free(comparable);
    @memset(comparable[start + build_id_note.desc_offset ..][0..build_id_note.fast_desc_size], 0);
    var hasher = std.hash.XxHash64.init(0);
    hasher.update(comparable);
    try std.testing.expectEqual(hasher.final(), readU64(linked.bytes, start + build_id_note.desc_offset));
}

test "ELF linker zeroes executable padding without clearing payloads" {
    const allocator = std.testing.allocator;
    const start_text = [_]u8{0xc3};
    const helper_text = [_]u8{ 0x90, 0xc3 };
    const start_index: u16 = 1;
    const helper_index: u16 = 2;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 1),
            Section.progbits(".text.helper", &helper_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            Symbol.section(start_index),
            Symbol.section(helper_index),
            Symbol.function("_start", start_index, 0, start_text.len),
            Symbol.function("helper", helper_index, 0, helper_text.len),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "padding.o", .bytes = object }}, .{});
    defer linked.deinit(allocator);

    try expectAllZeroes(linked.bytes[8..16]);

    const start_contribution = metadata.manifestContribution(linked.manifest, "padding.o", .section, ".text.start", start_index) orelse return error.MissingSection;
    const helper_contribution = metadata.manifestContribution(linked.manifest, "padding.o", .section, ".text.helper", helper_index) orelse return error.MissingSection;
    try std.testing.expectEqualSlices(u8, &start_text, linked.bytes[@intCast(start_contribution.file_offset)..][0..start_text.len]);
    try std.testing.expectEqualSlices(u8, &helper_text, linked.bytes[@intCast(helper_contribution.file_offset)..][0..helper_text.len]);
    try expectAllZeroes(linked.bytes[@intCast(start_contribution.file_offset + start_contribution.size)..@intCast(helper_contribution.file_offset)]);
    try expectAllZeroes(linked.bytes[@intCast(helper_contribution.file_offset + helper_contribution.size)..@intCast(helper_contribution.file_offset + helper_contribution.reserved_size)]);
}

test "ELF linker keeps loadable file ranges compact and page-congruent" {
    const allocator = std.testing.allocator;
    const text = [_]u8{0xc3};
    const rodata = [_]u8{ 1, 2, 3, 4 };
    const text_index: u16 = 1;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".rodata", &rodata, 0, 16),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(2),
            Symbol.function("_start", text_index, 0, text.len),
        },
    });
    defer allocator.free(object);

    const options = model.LinkOptions{};
    var linked = try linkExecutable(allocator, &.{.{ .name = "compact.o", .bytes = object }}, options);
    defer linked.deinit(allocator);

    const text_section = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const rodata_section = metadata.manifestSection(linked.manifest, ".rodata") orelse return error.MissingSection;
    try std.testing.expect(text_section.file_offset < options.page_size);
    try std.testing.expect(rodata_section.file_offset < options.page_size);
    try std.testing.expect(rodata_section.address >= alignForwardU64(text_section.address + text_section.reserved_size, options.page_size));

    const text_program = try metadata.loadProgramHeaderByAddress(linked.bytes, text_section.address);
    const rodata_program = try metadata.loadProgramHeaderByAddress(linked.bytes, rodata_section.address);
    const phdr_program = try metadata.programHeaderByType(linked.bytes, @backingInt(std.elf.PT.PHDR));
    try std.testing.expectEqual(@as(u64, ehdr_size), phdr_program.file_offset);
    try std.testing.expectEqual(@as(u64, readU16(linked.bytes, 56)) * phdr_size, phdr_program.file_size);
    try std.testing.expectEqual(@as(u64, 0), text_program.file_offset);
    try std.testing.expectEqual(rodata_section.file_offset, rodata_program.file_offset);
    try std.testing.expectEqual(text_program.file_offset % options.page_size, text_program.virtual_address % options.page_size);
    try std.testing.expectEqual(rodata_program.file_offset % options.page_size, rodata_program.virtual_address % options.page_size);
    try std.testing.expectEqual(text_section.file_offset - text_program.file_offset, text_section.address - text_program.virtual_address);
}

test "ELF linker records duplicate section names with distinct ordinals" {
    const allocator = std.testing.allocator;
    const start_text = [_]u8{0xc3};
    const helper_text = [_]u8{ 0x90, 0xc3 };
    const start_index: u16 = 1;
    const helper_index: u16 = 2;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &start_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text", &helper_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            Symbol.section(start_index),
            Symbol.section(helper_index),
            Symbol.function("_start", start_index, 0, start_text.len),
            Symbol.function("helper", helper_index, 0, helper_text.len),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "dup.o", .bytes = object }}, .{});
    defer linked.deinit(allocator);

    const start_contribution = metadata.manifestContribution(linked.manifest, "dup.o", .section, ".text", start_index) orelse return error.MissingSection;
    const helper_contribution = metadata.manifestContribution(linked.manifest, "dup.o", .section, ".text", helper_index) orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, start_text.len), start_contribution.size);
    try std.testing.expectEqual(@as(u64, helper_text.len), helper_contribution.size);
    try std.testing.expect(helper_contribution.address > start_contribution.address);

    const helper_plan = linked.manifest.planContributionReplacement(&.{
        .{ .input_name = "dup.o", .input_index = 0, .kind = .section, .name = ".text", .ordinal = helper_index, .size = helper_text.len + 1, .alignment = 16 },
    });
    try std.testing.expectEqual(incremental.PatchDecision.in_place, helper_plan.decision);
}

test "ELF linker applies PC-relative relocations across objects" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const caller_text_index: u16 = 1;
    const callee_symbol: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedFunction("callee"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, callee_symbol, .PLT32, -4)},
    });
    defer allocator.free(caller_object);

    const callee_text = [_]u8{0xc3};
    const callee_text_index: u16 = 1;
    const callee_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &callee_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(callee_text_index),
            Symbol.function("callee", callee_text_index, 0, callee_text.len),
        },
    });
    defer allocator.free(callee_object);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "callee.o", .bytes = callee_object },
    }, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_file_offset: usize = @intCast(linked.manifest.sections[0].file_offset);
    const patched = std.mem.readInt(i32, linked.bytes[text_file_offset + 1 ..][0..4], .little);
    try std.testing.expectEqual(@as(i32, 11), patched);
}

test "ELF incremental candidate relink patches changed relocation payloads" {
    const allocator = std.testing.allocator;
    const options = model.LinkOptions{};

    const old_caller_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const old_caller_text_index: u16 = 1;
    const old_callee_symbol: u32 = 3;
    const old_caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &old_caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(old_caller_text_index),
            Symbol.function("_start", old_caller_text_index, 0, old_caller_text.len),
            Symbol.undefinedFunction("callee"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, old_callee_symbol, .PLT32, -4)},
    });
    defer allocator.free(old_caller_object);

    const new_caller_text = [_]u8{ 0x90, 0xe8, 0, 0, 0, 0 };
    const new_caller_text_index: u16 = 1;
    const new_callee_symbol: u32 = 3;
    const new_caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &new_caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(new_caller_text_index),
            Symbol.function("_start", new_caller_text_index, 0, new_caller_text.len),
            Symbol.undefinedFunction("callee"),
        },
        .relocations = &.{Relocation.x86_64(1, 2, new_callee_symbol, .PLT32, -4)},
    });
    defer allocator.free(new_caller_object);

    const callee_text = [_]u8{0xc3};
    const callee_text_index: u16 = 1;
    const callee_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &callee_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(callee_text_index),
            Symbol.function("callee", callee_text_index, 0, callee_text.len),
        },
    });
    defer allocator.free(callee_object);

    const old_inputs = [_]model.Input{
        .{ .name = "caller.o", .bytes = old_caller_object },
        .{ .name = "callee.o", .bytes = callee_object },
    };
    const new_inputs = [_]model.Input{
        .{ .name = "caller.o", .bytes = new_caller_object },
        .{ .name = "callee.o", .bytes = callee_object },
    };

    var old_linked = try linkExecutable(allocator, &old_inputs, options);
    defer old_linked.deinit(allocator);
    var state = try old_linked.prepareIncrementalState(allocator);
    defer state.deinit(allocator);

    var candidate = try linkExecutable(allocator, &new_inputs, options);
    defer candidate.deinit(allocator);

    const input_change_limits = incremental.InputChangeStorage.Limits.inspect(
        incremental.RecordedInputs.fromManifest(&state.manifest),
        &new_inputs,
    );
    const input_change_capacity = try incremental.InputChangeStorage.Capacity.derive(
        input_change_limits,
    );
    const input_change_bytes = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(incremental.InputChangeStorage.storage_alignment),
        input_change_capacity.storage_bytes,
    );
    defer allocator.free(input_change_bytes);
    var input_change_storage = try incremental.InputChangeStorage.init(
        input_change_bytes,
        input_change_limits,
    );
    defer _ = input_change_storage.deinit();
    input_change_storage.activate();
    const application = try state.applyChangedInputRelinkFromCandidate(
        allocator,
        &input_change_storage,
        old_linked.bytes,
        options,
        &new_inputs,
        candidate.bytes,
        candidate.manifest,
    );

    try std.testing.expectEqual(incremental.RelinkDecision.in_place, application.plan.decision);
    try std.testing.expectEqual(@as(usize, 1), application.contributions_written);
    try std.testing.expectEqualSlices(u8, candidate.bytes, old_linked.bytes);
}

test "ELF incremental candidate relink patches metadata after contribution growth" {
    const allocator = std.testing.allocator;
    const options = model.LinkOptions{ .build_id = .fast };

    const old_text = [_]u8{0xc3};
    const old_text_index: u16 = 1;
    const old_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &old_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{ Symbol.section(old_text_index), Symbol.function("_start", old_text_index, 0, old_text.len) },
    });
    defer allocator.free(old_object);

    const new_text = [_]u8{ 0x90, 0xc3 };
    const new_text_index: u16 = 1;
    const new_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &new_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{ Symbol.section(new_text_index), Symbol.function("_start", new_text_index, 0, new_text.len) },
    });
    defer allocator.free(new_object);

    const old_inputs = [_]model.Input{.{ .name = "start.o", .bytes = old_object }};
    const new_inputs = [_]model.Input{.{ .name = "start.o", .bytes = new_object }};

    var old_linked = try linkExecutable(allocator, &old_inputs, options);
    defer old_linked.deinit(allocator);
    var state = try old_linked.prepareIncrementalState(allocator);
    defer state.deinit(allocator);

    var candidate = try linkExecutable(allocator, &new_inputs, options);
    defer candidate.deinit(allocator);

    const input_change_limits = incremental.InputChangeStorage.Limits.inspect(
        incremental.RecordedInputs.fromManifest(&state.manifest),
        &new_inputs,
    );
    const input_change_capacity = try incremental.InputChangeStorage.Capacity.derive(
        input_change_limits,
    );
    const input_change_bytes = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(incremental.InputChangeStorage.storage_alignment),
        input_change_capacity.storage_bytes,
    );
    defer allocator.free(input_change_bytes);
    var input_change_storage = try incremental.InputChangeStorage.init(
        input_change_bytes,
        input_change_limits,
    );
    defer _ = input_change_storage.deinit();
    input_change_storage.activate();
    const input_changes = try state.classifyInputs(
        &input_change_storage,
        &new_inputs,
    );
    const replacements = try incremental.replacementContributionsFromImage(
        allocator,
        candidate.bytes,
        candidate.manifest,
        input_changes,
    );
    defer allocator.free(replacements);

    const application = try state.applyChangedInputRelinkFromInputChanges(
        options,
        input_changes,
        old_linked.bytes,
        replacements,
    );
    try std.testing.expectEqual(incremental.RelinkDecision.in_place, application.plan.decision);
    try std.testing.expect(!std.mem.eql(u8, candidate.bytes, old_linked.bytes));

    try patchIncrementalMetadata(old_linked.bytes, candidate.bytes);
    try state.updateManifestForCandidateRelinkFromInputChanges(
        allocator,
        &new_inputs,
        input_changes,
        replacements,
        candidate.manifest,
    );

    const text_header = try metadata.linkedSectionByName(old_linked.bytes, ".text");
    const candidate_text_header = try metadata.linkedSectionByName(candidate.bytes, ".text");
    try std.testing.expectEqual(candidate_text_header.size, text_header.size);
    try std.testing.expectEqual(candidate.manifest.sections[0].size, state.manifest.sections[0].size);
    try std.testing.expectEqual(@as(u64, new_text.len), state.manifest.contributions[0].size);
    try std.testing.expectEqualSlices(u8, candidate.bytes, old_linked.bytes);
}

test "ELF linker applies repeated relocations to one global symbol" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{
        0xe8, 0, 0, 0, 0,
        0xe8, 0, 0, 0, 0,
        0xe8, 0, 0, 0, 0,
        0xc3,
    };
    const caller_text_index: u16 = 1;
    const callee_symbol: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedFunction("callee"),
        },
        .relocations = &.{
            Relocation.x86_64(1, 1, callee_symbol, .PLT32, -4),
            Relocation.x86_64(1, 6, callee_symbol, .PLT32, -4),
            Relocation.x86_64(1, 11, callee_symbol, .PLT32, -4),
        },
    });
    defer allocator.free(caller_object);

    const callee_text = [_]u8{0xc3};
    const callee_text_index: u16 = 1;
    const callee_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &callee_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(callee_text_index),
            Symbol.function("callee", callee_text_index, 0, callee_text.len),
        },
    });
    defer allocator.free(callee_object);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "callee.o", .bytes = callee_object },
    }, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_file_offset: usize = @intCast(linked.manifest.sections[0].file_offset);
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[text_file_offset + 1 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 6), std.mem.readInt(i32, linked.bytes[text_file_offset + 6 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, linked.bytes[text_file_offset + 11 ..][0..4], .little));
}

test "ELF linker resolves absolute symbol relocations" {
    const allocator = std.testing.allocator;

    const text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const text_index: u16 = 1;
    const absolute_symbol: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.undefinedObject("absolute_value"),
        },
        .relocations = &.{Relocation.x86_64(text_index, 2, absolute_symbol, .@"64", 5)},
    });
    defer allocator.free(caller_object);

    const absolute_object = try buildObject(allocator, .{
        .sections = &.{},
        .symbols = &.{Symbol.absoluteObject("absolute_value", 37, 0)},
    });
    defer allocator.free(absolute_object);

    var linked = try linkExecutable(
        allocator,
        &.{
            .{ .name = "caller.o", .bytes = caller_object },
            .{ .name = "absolute.o", .bytes = absolute_object },
        },
        .{
            .incremental_mode = .off,
            .gc_sections = true,
        },
    );
    defer linked.deinit(allocator);

    const text_section = try metadata.linkedSectionByName(linked.bytes, ".text");
    try std.testing.expectEqual(@as(u64, 42), readU64(linked.bytes, @intCast(text_section.offset + 2)));
}

test "ELF linker resolves signed absolute relocations" {
    const allocator = std.testing.allocator;

    const text = [_]u8{0xc3};
    const data = @as([12]u8, @splat(0));
    const text_index: u16 = 1;
    const data_index: u16 = 2;
    const neg_symbol: u32 = 4;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".data.signed", &data, std.elf.SHF_WRITE, 8),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(data_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.undefinedObject("negative_absolute"),
        },
        .relocations = &.{
            Relocation.x86_64(data_index, 0, neg_symbol, .@"32S", 0),
            Relocation.x86_64(data_index, 4, neg_symbol, .@"64", 0),
        },
    });
    defer allocator.free(caller_object);

    const absolute_object = try buildObject(allocator, .{
        .sections = &.{},
        .symbols = &.{Symbol.absoluteObject("negative_absolute", std.math.maxInt(u64), 0)},
    });
    defer allocator.free(absolute_object);

    var linked = try linkExecutable(
        allocator,
        &.{
            .{ .name = "caller.o", .bytes = caller_object },
            .{ .name = "absolute.o", .bytes = absolute_object },
        },
        .{ .incremental_mode = .off },
    );
    defer linked.deinit(allocator);

    const data_section = try metadata.linkedSectionByName(linked.bytes, ".data");
    const offset: usize = @intCast(data_section.offset);
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, linked.bytes[offset..][0..4], .little));
    try std.testing.expectEqual(std.math.maxInt(u64), std.mem.readInt(u64, linked.bytes[offset + 4 ..][0..8], .little));
}

test "ELF linker resolves narrow absolute relocations" {
    const allocator = std.testing.allocator;

    const text = [_]u8{0xc3};
    const data = [_]u8{ 0, 0, 0, 0 };
    const text_index: u16 = 1;
    const data_index: u16 = 2;
    const abs16_symbol: u32 = 4;
    const abs8_symbol: u32 = 5;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".data.narrow", &data, std.elf.SHF_WRITE, 2),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(data_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.undefinedObject("abs16"),
            Symbol.undefinedObject("abs8"),
        },
        .relocations = &.{
            Relocation.x86_64(data_index, 0, abs16_symbol, .@"16", 0),
            Relocation.x86_64(data_index, 2, abs8_symbol, .@"8", 0),
            Relocation.x86_64(data_index, 3, abs8_symbol, .@"8", -91),
        },
    });
    defer allocator.free(caller_object);

    const absolute_object = try buildObject(allocator, .{
        .sections = &.{},
        .symbols = &.{ Symbol.absoluteObject("abs16", 0x1234, 0), Symbol.absoluteObject("abs8", 0x5a, 0) },
    });
    defer allocator.free(absolute_object);

    var linked = try linkExecutable(
        allocator,
        &.{
            .{ .name = "caller.o", .bytes = caller_object },
            .{ .name = "absolute.o", .bytes = absolute_object },
        },
        .{ .incremental_mode = .off },
    );
    defer linked.deinit(allocator);

    const data_section = try metadata.linkedSectionByName(linked.bytes, ".data");
    const offset: usize = @intCast(data_section.offset);
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, linked.bytes[offset..][0..2], .little));
    try std.testing.expectEqual(@as(u8, 0x5a), linked.bytes[offset + 2]);
    try std.testing.expectEqual(@as(u8, 0xff), linked.bytes[offset + 3]);
}

test "ELF linker resolves narrow PC-relative relocations" {
    const allocator = std.testing.allocator;

    const text = [_]u8{0xc3};
    const data = [_]u8{ 0, 0, 0, 0 };
    const text_index: u16 = 1;
    const data_index: u16 = 2;
    const target_symbol: u32 = 4;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".data.pc", &data, std.elf.SHF_WRITE, 2),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(data_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.object("pc_target", data_index, 3, 1),
        },
        .relocations = &.{
            Relocation.x86_64(data_index, 0, target_symbol, .PC16, 0),
            Relocation.x86_64(data_index, 2, target_symbol, .PC8, 0),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "pc.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const data_record = metadata.manifestSection(linked.manifest, ".data") orelse return error.MissingSection;
    const offset: usize = @intCast(data_record.file_offset);
    try std.testing.expectEqual(@as(i16, 3), std.mem.readInt(i16, linked.bytes[offset..][0..2], .little));
    try std.testing.expectEqual(@as(u8, 1), linked.bytes[offset + 2]);
    try std.testing.expectEqual(@as(u8, 0), linked.bytes[offset + 3]);
}

test "ELF linker discards duplicate COMDAT groups by signature" {
    const allocator = std.testing.allocator;

    const retained_text = [_]u8{0xc3};
    const retained_text_index: u16 = 1;
    const retained_symbol: u32 = 2;
    var retained_group_payload: [(1 + 1) * 4]u8 = undefined;
    const retained_group_bytes = groupBytes(&retained_group_payload, &.{retained_text_index});
    const retained_object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.inline", &retained_text, std.elf.SHF_EXECINSTR | std.elf.SHF_GROUP, 16),
            Section.group(".group", retained_group_bytes, retained_symbol),
        },
        .symbols = &.{
            Symbol.section(retained_text_index),
            Symbol.function("inline_fn", retained_text_index, 0, retained_text.len),
        },
    });
    defer allocator.free(retained_object);

    const caller_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const caller_text_index: u16 = 1;
    const duplicate_text = [_]u8{0xcc};
    const duplicate_text_index: u16 = 2;
    const duplicate_symbol: u32 = 4;
    var caller_group_payload: [(1 + 1) * 4]u8 = undefined;
    const caller_group_bytes = groupBytes(&caller_group_payload, &.{duplicate_text_index});
    const caller_object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.inline", &duplicate_text, std.elf.SHF_EXECINSTR | std.elf.SHF_GROUP, 16),
            Section.group(".group", caller_group_bytes, duplicate_symbol),
        },
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.section(duplicate_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.function("inline_fn", duplicate_text_index, 0, duplicate_text.len),
        },
        .relocations = &.{Relocation.x86_64(1, 1, duplicate_symbol, .PLT32, -4)},
    });
    defer allocator.free(caller_object);

    const inputs = [_]model.Input{
        .{ .name = "retained.o", .bytes = retained_object },
        .{ .name = "caller.o", .bytes = caller_object },
    };

    var linked = try linkExecutable(allocator, &inputs, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    var manifest_linked = try linkExecutable(allocator, &inputs, .{});
    defer manifest_linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, 22), text_record.size);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "retained.o", .section, ".text.inline", retained_text_index) != null);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "caller.o", .section, ".text.inline", duplicate_text_index) == null);
    const discarded_duplicate = metadata.manifestDiscardedContribution(manifest_linked.manifest, "caller.o", ".text.inline", duplicate_text_index) orelse return error.MissingSection;
    try std.testing.expectEqual(incremental.DiscardReason.discarded, discarded_duplicate.reason);

    const text_file_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[text_file_offset]);
    try std.testing.expectEqual(@as(i32, -21), std.mem.readInt(i32, linked.bytes[text_file_offset + 17 ..][0..4], .little));
}

test "ELF linker uses section names for unnamed COMDAT section signatures" {
    const allocator = std.testing.allocator;

    const start_text = [_]u8{0xc3};
    const start_text_index: u16 = 1;
    const start_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(start_text_index),
            Symbol.function("_start", start_text_index, 0, start_text.len),
        },
    });
    defer allocator.free(start_object);

    const first_text = [_]u8{0x90};
    const first_text_index: u16 = 1;
    const first_section_symbol: u32 = 1;
    var first_group_payload: [(1 + 1) * 4]u8 = undefined;
    const first_group_bytes = groupBytes(&first_group_payload, &.{first_text_index});
    const first_object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.inline", &first_text, std.elf.SHF_EXECINSTR | std.elf.SHF_GROUP, 16),
            Section.group(".group", first_group_bytes, first_section_symbol),
        },
        .symbols = &.{Symbol.section(first_text_index)},
    });
    defer allocator.free(first_object);

    const duplicate_text = [_]u8{0xcc};
    const duplicate_text_index: u16 = 1;
    const duplicate_section_symbol: u32 = 1;
    var duplicate_group_payload: [(1 + 1) * 4]u8 = undefined;
    const duplicate_group_bytes = groupBytes(&duplicate_group_payload, &.{duplicate_text_index});
    const duplicate_object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.inline", &duplicate_text, std.elf.SHF_EXECINSTR | std.elf.SHF_GROUP, 16),
            Section.group(".group", duplicate_group_bytes, duplicate_section_symbol),
        },
        .symbols = &.{Symbol.section(duplicate_text_index)},
    });
    defer allocator.free(duplicate_object);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "start.o", .bytes = start_object },
        .{ .name = "first.o", .bytes = first_object },
        .{ .name = "duplicate.o", .bytes = duplicate_object },
    }, .{});
    defer linked.deinit(allocator);

    try std.testing.expect(metadata.manifestContribution(linked.manifest, "first.o", .section, ".text.inline", first_text_index) != null);
    try std.testing.expect(metadata.manifestContribution(linked.manifest, "duplicate.o", .section, ".text.inline", duplicate_text_index) == null);
    const discarded_duplicate = metadata.manifestDiscardedContribution(linked.manifest, "duplicate.o", ".text.inline", duplicate_text_index) orelse return error.MissingSection;
    try std.testing.expectEqual(incremental.DiscardReason.discarded, discarded_duplicate.reason);
}

test "ELF linker garbage collects unreferenced alloc sections" {
    const allocator = std.testing.allocator;

    const start_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const helper_text = [_]u8{0xc3};
    const dead_text = [_]u8{0xcc};
    const start_index: u16 = 1;
    const helper_index: u16 = 2;
    const dead_index: u16 = 3;
    const helper_symbol: u32 = 5;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.helper", &helper_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.dead", &dead_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            Symbol.section(start_index),
            Symbol.section(helper_index),
            Symbol.section(dead_index),
            Symbol.function("_start", start_index, 0, start_text.len),
            Symbol.function("helper", helper_index, 0, helper_text.len),
            Symbol.function("dead", dead_index, 0, dead_text.len),
        },
        .relocations = &.{Relocation.x86_64(1, 1, helper_symbol, .PLT32, -4)},
    });
    defer allocator.free(object);

    const inputs = [_]model.Input{.{ .name = "gc.o", .bytes = object }};
    var linked = try linkExecutable(allocator, &inputs, .{
        .incremental_mode = .off,
        .gc_sections = true,
    });
    defer linked.deinit(allocator);

    var manifest_linked = try linkExecutable(allocator, &inputs, .{
        .gc_sections = true,
    });
    defer manifest_linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, 17), text_record.size);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "gc.o", .section, ".text.start", start_index) != null);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "gc.o", .section, ".text.helper", helper_index) != null);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "gc.o", .section, ".text.dead", dead_index) == null);
    const discarded_dead = metadata.manifestDiscardedContribution(manifest_linked.manifest, "gc.o", ".text.dead", dead_index) orelse return error.MissingSection;
    try std.testing.expectEqual(incremental.DiscardReason.discarded, discarded_dead.reason);

    const text_file_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[text_file_offset + 1 ..][0..4], .little));
}

test "ELF linker keeps GNU retain sections during GC" {
    const allocator = std.testing.allocator;

    const start_text = [_]u8{0xc3};
    const retained_data = [_]u8{ 0x6d, 0x25, 0xe3, 0x91, 0x4a, 0xbf, 0x70, 0x0d };
    const dead_data = [_]u8{ 0xd0, 0x5c, 0xaa, 0x11 };
    const start_index: u16 = 1;
    const retained_index: u16 = 2;
    const dead_index: u16 = 3;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".rodata.retain", &retained_data, std.elf.SHF_GNU_RETAIN, 8),
            Section.progbits(".rodata.dead", &dead_data, 0, 4),
        },
        .symbols = &.{
            Symbol.section(start_index),
            Symbol.section(retained_index),
            Symbol.section(dead_index),
            Symbol.function("_start", start_index, 0, start_text.len),
            Symbol.object("retained_probe", retained_index, 0, retained_data.len),
            Symbol.object("dead_probe", dead_index, 0, dead_data.len),
        },
    });
    defer allocator.free(object);

    const inputs = [_]model.Input{.{ .name = "retain.o", .bytes = object }};
    var linked = try linkExecutable(allocator, &inputs, .{
        .incremental_mode = .off,
        .gc_sections = true,
    });
    defer linked.deinit(allocator);

    var manifest_linked = try linkExecutable(allocator, &inputs, .{
        .gc_sections = true,
    });
    defer manifest_linked.deinit(allocator);

    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "retain.o", .section, ".text.start", start_index) != null);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "retain.o", .section, ".rodata.retain", retained_index) != null);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "retain.o", .section, ".rodata.dead", dead_index) == null);
    const discarded_dead = metadata.manifestDiscardedContribution(manifest_linked.manifest, "retain.o", ".rodata.dead", dead_index) orelse return error.MissingSection;
    try std.testing.expectEqual(incremental.DiscardReason.discarded, discarded_dead.reason);
}

test "ELF linker keeps init arrays during GC" {
    const allocator = std.testing.allocator;

    const start_text = [_]u8{0xc3};
    const ctor_text = [_]u8{ 0xb8, 0x5d, 0x00, 0x00, 0x00, 0xc3 };
    const init_array = @as([8]u8, @splat(0));
    const dead_text = [_]u8{0xcc};
    const start_index: u16 = 1;
    const ctor_index: u16 = 2;
    const init_index: u16 = 3;
    const dead_index: u16 = 4;
    const ctor_symbol: u32 = 6;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.ctor", &ctor_text, std.elf.SHF_EXECINSTR, 16),
            .{
                .name = ".init_array",
                .section_type = std.elf.SHT_INIT_ARRAY,
                .flags = std.elf.SHF_WRITE | std.elf.SHF_ALLOC,
                .alignment = 8,
                .bytes = &init_array,
            },
            Section.progbits(".text.dead", &dead_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            Symbol.section(start_index),
            Symbol.section(ctor_index),
            Symbol.section(init_index),
            Symbol.section(dead_index),
            Symbol.function("_start", start_index, 0, start_text.len),
            Symbol.function("ctor", ctor_index, 0, ctor_text.len),
            Symbol.function("dead", dead_index, 0, dead_text.len),
        },
        .relocations = &.{Relocation.x86_64(init_index, 0, ctor_symbol, .@"64", 0)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "init.o", .bytes = object }}, .{
        .gc_sections = true,
    });
    defer linked.deinit(allocator);

    const init_contribution = metadata.manifestContribution(linked.manifest, "init.o", .section, ".init_array", init_index) orelse return error.MissingSection;
    const ctor_contribution = metadata.manifestContribution(linked.manifest, "init.o", .section, ".text.ctor", ctor_index) orelse return error.MissingSection;
    try std.testing.expect(metadata.manifestContribution(linked.manifest, "init.o", .section, ".text.start", start_index) != null);
    try std.testing.expect(metadata.manifestContribution(linked.manifest, "init.o", .section, ".text.dead", dead_index) == null);
    const discarded_dead = metadata.manifestDiscardedContribution(linked.manifest, "init.o", ".text.dead", dead_index) orelse return error.MissingSection;
    try std.testing.expectEqual(incremental.DiscardReason.discarded, discarded_dead.reason);

    const init_file_offset: usize = @intCast(init_contribution.file_offset);
    try std.testing.expectEqual(ctor_contribution.address, std.mem.readInt(u64, linked.bytes[init_file_offset..][0..8], .little));
}

test "ELF linker keeps allocated note sections during GC" {
    const allocator = std.testing.allocator;

    const start_text = [_]u8{0xc3};
    const note_payload = [_]u8{
        4,    0,    0,    0,
        4,    0,    0,    0,
        0x52, 0x44, 0x4c, 0x54,
        'T',  'L',  'D',  'R',
        0x79, 0x41, 0x6e, 0x23,
    };
    const dead_text = [_]u8{0xcc};
    const start_index: u16 = 1;
    const note_index: u16 = 2;
    const dead_index: u16 = 3;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16),
            .{
                .name = ".note.tldr",
                .section_type = std.elf.SHT_NOTE,
                .flags = std.elf.SHF_ALLOC,
                .alignment = 4,
                .bytes = &note_payload,
            },
            Section.progbits(".text.dead", &dead_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            Symbol.section(start_index),
            Symbol.section(note_index),
            Symbol.section(dead_index),
            Symbol.function("_start", start_index, 0, start_text.len),
            Symbol.function("dead", dead_index, 0, dead_text.len),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "note.o", .bytes = object }}, .{
        .gc_sections = true,
    });
    defer linked.deinit(allocator);

    const note_contribution = metadata.manifestContribution(linked.manifest, "note.o", .section, ".note.tldr", note_index) orelse return error.MissingSection;
    try std.testing.expect(metadata.manifestContribution(linked.manifest, "note.o", .section, ".text.start", start_index) != null);
    try std.testing.expect(metadata.manifestContribution(linked.manifest, "note.o", .section, ".text.dead", dead_index) == null);
    const discarded_dead = metadata.manifestDiscardedContribution(linked.manifest, "note.o", ".text.dead", dead_index) orelse return error.MissingSection;
    try std.testing.expectEqual(incremental.DiscardReason.discarded, discarded_dead.reason);

    const note_file_offset: usize = @intCast(note_contribution.file_offset);
    try std.testing.expectEqualSlices(u8, &note_payload, linked.bytes[note_file_offset..][0..note_payload.len]);
}

test "ELF linker ignores no-op relocations during GC" {
    const allocator = std.testing.allocator;

    const text = [_]u8{0xc3};
    const text_index: u16 = 1;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{ Symbol.section(text_index), Symbol.function("_start", text_index, 0, text.len) },
        .relocations = &.{Relocation.x86_64(text_index, 0, 0, .NONE, 0)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "none-gc.o", .bytes = object }}, .{
        .incremental_mode = .off,
        .gc_sections = true,
    });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, text.len), text_record.size);
}

test "ELF linker resolves start and stop section boundary symbols" {
    const allocator = std.testing.allocator;

    const text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0x48, 0xbb,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const caller_text_index: u16 = 1;
    const start_symbol: u32 = 3;
    const stop_symbol: u32 = 4;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, text.len),
            Symbol.undefinedObject("__start_meta"),
            Symbol.undefinedObject("__stop_meta"),
        },
        .relocations = &.{
            Relocation.x86_64(caller_text_index, 2, start_symbol, .@"64", 0),
            Relocation.x86_64(caller_text_index, 12, stop_symbol, .@"64", 0),
        },
    });
    defer allocator.free(caller_object);

    const meta = [_]u8{ 0x44, 0x33, 0x22, 0x11, 0x88, 0x77, 0x66, 0x55 };
    const meta_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits("meta", &meta, 0, 1)},
        .symbols = &.{Symbol.section(1)},
    });
    defer allocator.free(meta_object);

    var linked = try linkExecutable(
        allocator,
        &.{
            .{ .name = "caller.o", .bytes = caller_object },
            .{ .name = "meta.o", .bytes = meta_object },
        },
        .{
            .incremental_mode = .off,
            .gc_sections = true,
        },
    );
    defer linked.deinit(allocator);

    const text_section = try metadata.linkedSectionByName(linked.bytes, ".text");
    const rodata_section = try metadata.linkedSectionByName(linked.bytes, ".rodata");
    try std.testing.expectEqual(@as(u64, meta.len), rodata_section.size);
    try std.testing.expectEqual(rodata_section.address, readU64(linked.bytes, @intCast(text_section.offset + 2)));
    try std.testing.expectEqual(rodata_section.address + meta.len, readU64(linked.bytes, @intCast(text_section.offset + 12)));
}

test "ELF linker resolves runtime array boundary symbols" {
    const allocator = std.testing.allocator;

    const text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0x48, 0xbb,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const caller_text_index: u16 = 1;
    const start_symbol: u32 = 3;
    const end_symbol: u32 = 4;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, text.len),
            Symbol.undefinedObject("__init_array_start"),
            Symbol.undefinedObject("__init_array_end"),
        },
        .relocations = &.{
            Relocation.x86_64(caller_text_index, 2, start_symbol, .@"64", 0),
            Relocation.x86_64(caller_text_index, 12, end_symbol, .@"64", 0),
        },
    });
    defer allocator.free(caller_object);

    const first = @as([8]u8, @splat(0x11));
    const second = @as([8]u8, @splat(0x22));
    const first_index: u16 = 1;
    const second_index: u16 = 2;
    const arrays_object = try buildObject(allocator, .{
        .sections = &.{
            .{
                .name = ".init_array",
                .section_type = std.elf.SHT_INIT_ARRAY,
                .flags = std.elf.SHF_WRITE | std.elf.SHF_ALLOC,
                .alignment = 8,
                .bytes = &first,
            },
            .{
                .name = ".init_array.100",
                .section_type = std.elf.SHT_INIT_ARRAY,
                .flags = std.elf.SHF_WRITE | std.elf.SHF_ALLOC,
                .alignment = 8,
                .bytes = &second,
            },
        },
        .symbols = &.{ Symbol.section(first_index), Symbol.section(second_index) },
    });
    defer allocator.free(arrays_object);

    var linked = try linkExecutable(
        allocator,
        &.{
            .{ .name = "caller.o", .bytes = caller_object },
            .{ .name = "arrays.o", .bytes = arrays_object },
        },
        .{ .gc_sections = true },
    );
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const first_contribution = metadata.manifestContribution(linked.manifest, "arrays.o", .section, ".init_array", first_index) orelse return error.MissingSection;
    const second_contribution = metadata.manifestContribution(linked.manifest, "arrays.o", .section, ".init_array.100", second_index) orelse return error.MissingSection;
    const expected_start = @min(first_contribution.address, second_contribution.address);
    const expected_end = @max(first_contribution.address + first_contribution.size, second_contribution.address + second_contribution.size);
    const text_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(expected_start, readU64(linked.bytes, text_offset + 2));
    try std.testing.expectEqual(expected_end, readU64(linked.bytes, text_offset + 12));
}

test "ELF linker resolves absent runtime array boundaries to equal addresses" {
    const allocator = std.testing.allocator;

    const text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0x48, 0xbb,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const text_index: u16 = 1;
    const start_symbol: u32 = 3;
    const end_symbol: u32 = 4;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.undefinedObject("__preinit_array_start"),
            Symbol.undefinedObject("__preinit_array_end"),
        },
        .relocations = &.{
            Relocation.x86_64(text_index, 2, start_symbol, .@"64", 0),
            Relocation.x86_64(text_index, 12, end_symbol, .@"64", 0),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "preinit.o", .bytes = object }}, .{});
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const text_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(readU64(linked.bytes, text_offset + 2), readU64(linked.bytes, text_offset + 12));
}

test "ELF linker resolves ELF header start symbol" {
    const allocator = std.testing.allocator;

    const text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const text_index: u16 = 1;
    const ehdr_start: u32 = 3;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.undefinedObject("__ehdr_start"),
        },
        .relocations = &.{Relocation.x86_64(text_index, 2, ehdr_start, .@"64", 0)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "ehdr.o", .bytes = object }}, .{});
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const text_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(@as(u64, 0x400000), readU64(linked.bytes, text_offset + 2));
}

test "ELF linker records undefined relocation symbol diagnostics" {
    const allocator = std.testing.allocator;

    const start_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xe8, 0, 0, 0, 0, 0xc3 };
    const start_index: u16 = 1;
    const missing_symbol: u32 = 3;
    const second_missing_symbol: u32 = 4;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &start_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(start_index),
            Symbol.function("_start", start_index, 0, start_text.len),
            Symbol.undefinedFunction("missing_runtime_symbol"),
            Symbol.undefinedFunction("second_missing_runtime_symbol"),
        },
        .relocations = &.{
            Relocation.x86_64(1, 1, missing_symbol, .PLT32, -4),
            Relocation.x86_64(1, 6, second_missing_symbol, .PLT32, -4),
        },
    });
    defer allocator.free(object);

    var diagnostics: model.Diagnostics = .{};
    try std.testing.expectError(error.UndefinedSymbol, linkExecutable(
        allocator,
        &.{.{ .name = "missing.o", .bytes = object }},
        .{
            .incremental_mode = .off,
            .diagnostics = &diagnostics,
        },
    ));

    const undefined_symbol = diagnostics.first_undefined_symbol orelse return error.ExpectedUndefinedSymbolDiagnostic;
    try std.testing.expectEqualStrings("missing_runtime_symbol", undefined_symbol.name);
    try std.testing.expectEqualStrings("missing.o", undefined_symbol.input_name);
    const undefined_symbols = diagnostics.recordedUndefinedSymbols();
    try std.testing.expectEqual(@as(usize, 2), undefined_symbols.len);
    try std.testing.expectEqualStrings("missing_runtime_symbol", undefined_symbols[0].name);
    try std.testing.expectEqualStrings("second_missing_runtime_symbol", undefined_symbols[1].name);
}

test "ELF linker records unsupported relocation diagnostics" {
    const allocator = std.testing.allocator;

    const text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const text_index: u16 = 1;
    const helper_symbol: u32 = 3;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.function("helper", text_index, 0, text.len),
        },
        .relocations = &.{Relocation.x86_64(1, 1, helper_symbol, .GOT64, -4)},
    });
    defer allocator.free(object);

    var diagnostics: model.Diagnostics = .{};
    try std.testing.expectError(error.UnsupportedRelocation, linkExecutable(
        allocator,
        &.{.{ .name = "unsupported.o", .bytes = object }},
        .{
            .incremental_mode = .off,
            .diagnostics = &diagnostics,
        },
    ));

    const unsupported = diagnostics.first_unsupported_relocation orelse return error.ExpectedUnsupportedRelocationDiagnostic;
    try std.testing.expectEqualStrings("unsupported.o", unsupported.input_name);
    try std.testing.expectEqualStrings(".text", unsupported.section_name);
    try std.testing.expectEqualStrings("helper", unsupported.symbol_name);
    try std.testing.expectEqual(@backingInt(std.elf.R_X86_64.GOT64), unsupported.relocation_type);
}

const CommitWitness = struct {
    count: usize = 0,

    fn observer(self: *CommitWitness) model.LinkCommitObserver {
        return .{ .context = self, .committed = committed };
    }

    fn committed(context: *anyopaque) void {
        const self: *CommitWitness = @ptrCast(@alignCast(context));
        self.count += 1;
    }
};

fn startObjectAlloc(allocator: Allocator) ![]u8 {
    const text = [_]u8{
        0xb8, 0x3c, 0x00, 0x00, 0x00,
        0x31, 0xff, 0x0f, 0x05,
    };
    const text_index: u16 = 1;
    return try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{ Symbol.section(text_index), Symbol.function("_start", text_index, 0, text.len) },
    });
}

test "ELF linker notifies the commit observer once on success" {
    const allocator = std.testing.allocator;
    const object = try startObjectAlloc(allocator);
    defer allocator.free(object);

    var witness: CommitWitness = .{};
    var linked = try linkExecutable(
        allocator,
        &.{.{ .name = "start.o", .bytes = object }},
        .{ .commit_observer = witness.observer() },
    );
    defer linked.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), witness.count);
}

test "ELF linker withholds commit until resolution failures are impossible" {
    const allocator = std.testing.allocator;

    const call = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const undefined_text: u16 = 1;
    const missing_symbol: u32 = 3;
    const undefined_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &call, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(undefined_text),
            Symbol.function("_start", undefined_text, 0, call.len),
            Symbol.undefinedFunction("missing"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, missing_symbol, .PLT32, -4)},
    });
    defer allocator.free(undefined_object);

    var undefined_witness: CommitWitness = .{};
    try std.testing.expectError(error.UndefinedSymbol, linkExecutable(
        allocator,
        &.{.{ .name = "undefined.o", .bytes = undefined_object }},
        .{ .commit_observer = undefined_witness.observer() },
    ));
    try std.testing.expectEqual(@as(usize, 0), undefined_witness.count);

    const unsupported_text: u16 = 1;
    const helper_symbol: u32 = 3;
    const unsupported_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &call, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(unsupported_text),
            Symbol.function("_start", unsupported_text, 0, call.len),
            Symbol.function("helper", unsupported_text, 0, call.len),
        },
        .relocations = &.{Relocation.x86_64(1, 1, helper_symbol, .GOT64, -4)},
    });
    defer allocator.free(unsupported_object);

    var unsupported_witness: CommitWitness = .{};
    try std.testing.expectError(error.UnsupportedRelocation, linkExecutable(
        allocator,
        &.{.{ .name = "unsupported.o", .bytes = unsupported_object }},
        .{ .commit_observer = unsupported_witness.observer() },
    ));
    try std.testing.expectEqual(@as(usize, 0), unsupported_witness.count);
}

test "ELF linker fails missing entry symbols before commit" {
    const allocator = std.testing.allocator;
    const object = try startObjectAlloc(allocator);
    defer allocator.free(object);

    var witness: CommitWitness = .{};
    try std.testing.expectError(error.MissingEntrySymbol, linkExecutable(
        allocator,
        &.{.{ .name = "start.o", .bytes = object }},
        .{
            .entry_symbol = "absent_entry",
            .commit_observer = witness.observer(),
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), witness.count);
}

test "ELF linker applies no-op pc64 and size relocations" {
    const allocator = std.testing.allocator;

    const text = [_]u8{0xc3};
    const payload_bytes = [_]u8{ 'p', 'a', 'y', 'l', 'o', 'a', 'd' };
    var data = @as([32]u8, @splat(0xaa));
    const text_index: u16 = 1;
    const payload_index: u16 = 2;
    const data_index: u16 = 3;
    const start_symbol: u32 = 4;
    const payload_symbol: u32 = 5;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".rodata.payload", &payload_bytes, 0, 1),
            Section.progbits(".data.relocs", &data, std.elf.SHF_WRITE, 8),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(payload_index),
            Symbol.section(data_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.object("payload", payload_index, 0, payload_bytes.len),
        },
        .relocations = &.{
            Relocation.x86_64(data_index, 0, 0, .NONE, 0),
            Relocation.x86_64(data_index, 8, payload_symbol, .SIZE64, 5),
            Relocation.x86_64(data_index, 16, payload_symbol, .SIZE32, -1),
            Relocation.x86_64(data_index, 24, start_symbol, .PC64, 0),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "standard-relocs.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const data_record = metadata.manifestSection(linked.manifest, ".data") orelse return error.MissingSection;
    const data_offset: usize = @intCast(data_record.file_offset);
    try std.testing.expectEqualSlices(u8, data[0..8], linked.bytes[data_offset..][0..8]);
    try std.testing.expectEqual(@as(u64, payload_bytes.len + 5), std.mem.readInt(u64, linked.bytes[data_offset + 8 ..][0..8], .little));
    try std.testing.expectEqual(@as(u32, payload_bytes.len - 1), std.mem.readInt(u32, linked.bytes[data_offset + 16 ..][0..4], .little));

    const pc64 = std.mem.readInt(i64, linked.bytes[data_offset + 24 ..][0..8], .little);
    const expected_pc64: i64 = @intCast(@as(i128, text_record.address) - @as(i128, data_record.address + 24));
    try std.testing.expectEqual(expected_pc64, pc64);
}

test "ELF linker applies relocations in mergeable constant sections" {
    const allocator = std.testing.allocator;

    const text = [_]u8{0xc3};
    var constants = @as([16]u8, @splat(0));
    const text_index: u16 = 1;
    const constants_index: u16 = 2;
    const start_symbol: u32 = 3;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.mergeable(".rodata.cst8", &constants, 0, 8, 8),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(constants_index),
            Symbol.function("_start", text_index, 0, text.len),
        },
        .relocations = &.{Relocation.x86_64(constants_index, 0, start_symbol, .@"64", 0)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "merge-reloc.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const rodata_record = metadata.manifestSection(linked.manifest, ".rodata") orelse return error.MissingSection;
    const rodata_offset: usize = @intCast(rodata_record.file_offset);
    try std.testing.expectEqual(@as(u64, 16), rodata_record.size);
    try std.testing.expectEqual(text_record.address, std.mem.readInt(u64, linked.bytes[rodata_offset..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, linked.bytes[rodata_offset + 8 ..][0..8], .little));
}

test "ELF linker reports direct 32-bit relocation overflow" {
    const allocator = std.testing.allocator;

    const text = [_]u8{0xc3};
    const data = @as([4]u8, @splat(0));
    const text_index: u16 = 1;
    const data_index: u16 = 2;
    const too_large_symbol: u32 = 4;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".data", &data, std.elf.SHF_WRITE, 4),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(data_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.absoluteObject("too_large", @as(u64, std.math.maxInt(u32)) + 1, 0),
        },
        .relocations = &.{Relocation.x86_64(data_index, 0, too_large_symbol, .@"32", 0)},
    });
    defer allocator.free(object);

    try std.testing.expectError(error.RelocationOverflow, linkExecutable(
        allocator,
        &.{.{ .name = "overflow.o", .bytes = object }},
        .{ .incremental_mode = .off },
    ));
}

test "ELF linker rejects relocations that extend past section bytes" {
    const allocator = std.testing.allocator;

    const text = [_]u8{ 0xe8, 0, 0 };
    const text_index: u16 = 1;
    const start_symbol: u32 = 2;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{ Symbol.section(text_index), Symbol.function("_start", text_index, 0, text.len) },
        .relocations = &.{Relocation.x86_64(text_index, 1, start_symbol, .PC32, -4)},
    });
    defer allocator.free(object);

    try std.testing.expectError(error.InvalidRange, linkExecutable(
        allocator,
        &.{.{ .name = "truncated-reloc.o", .bytes = object }},
        .{ .incremental_mode = .off },
    ));
}

test "ELF linker follows relocation chains across sections during GC" {
    const allocator = std.testing.allocator;

    const call_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const leaf_text = [_]u8{0xc3};
    const start_index: u16 = 1;
    const first_index: u16 = 2;
    const second_index: u16 = 3;
    const first_symbol: u32 = 5;
    const second_symbol: u32 = 6;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.start", &call_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.first", &call_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.second", &leaf_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            Symbol.section(start_index),
            Symbol.section(first_index),
            Symbol.section(second_index),
            Symbol.function("_start", start_index, 0, call_text.len),
            Symbol.function("first", first_index, 0, call_text.len),
            Symbol.function("second", second_index, 0, leaf_text.len),
        },
        .relocations = &.{
            Relocation.x86_64(start_index, 1, first_symbol, .PLT32, -4),
            Relocation.x86_64(first_index, 1, second_symbol, .PLT32, -4),
        },
    });
    defer allocator.free(object);

    const inputs = [_]model.Input{.{ .name = "chain.o", .bytes = object }};
    var linked = try linkExecutable(allocator, &inputs, .{
        .incremental_mode = .off,
        .gc_sections = true,
    });
    defer linked.deinit(allocator);

    var manifest_linked = try linkExecutable(allocator, &inputs, .{
        .gc_sections = true,
    });
    defer manifest_linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, 33), text_record.size);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "chain.o", .section, ".text.start", start_index) != null);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "chain.o", .section, ".text.first", first_index) != null);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "chain.o", .section, ".text.second", second_index) != null);

    const text_file_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[text_file_offset + 1 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[text_file_offset + 17 ..][0..4], .little));
}

test "ELF linker keeps COMDAT group members live during garbage collection" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const caller_text_index: u16 = 1;
    const grouped_symbol: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedFunction("grouped"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, grouped_symbol, .PLT32, -4)},
    });
    defer allocator.free(caller_object);

    const grouped_text = [_]u8{0xc3};
    const grouped_data = [_]u8{ 1, 2, 3, 4 };
    const grouped_text_index: u16 = 1;
    const grouped_data_index: u16 = 2;
    const grouped_definition: u32 = 3;
    var comdat_payload: [(2 + 1) * 4]u8 = undefined;
    const comdat_bytes = groupBytes(&comdat_payload, &.{ grouped_text_index, grouped_data_index });
    const group_object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.grouped", &grouped_text, std.elf.SHF_EXECINSTR | std.elf.SHF_GROUP, 16),
            Section.progbits(".rodata.grouped", &grouped_data, std.elf.SHF_GROUP, 1),
            Section.group(".group", comdat_bytes, grouped_definition),
        },
        .symbols = &.{
            Symbol.section(grouped_text_index),
            Symbol.section(grouped_data_index),
            Symbol.function("grouped", grouped_text_index, 0, grouped_text.len),
        },
    });
    defer allocator.free(group_object);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "group.o", .bytes = group_object },
    }, .{
        .gc_sections = true,
    });
    defer linked.deinit(allocator);

    try std.testing.expect(metadata.manifestContribution(linked.manifest, "group.o", .section, ".text.grouped", grouped_text_index) != null);
    try std.testing.expect(metadata.manifestContribution(linked.manifest, "group.o", .section, ".rodata.grouped", grouped_data_index) != null);
}

test "ELF linker folds identical code sections when ICF is enabled" {
    const allocator = std.testing.allocator;

    const start_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xe8, 0, 0, 0, 0, 0xc3 };
    const function_text = [_]u8{0xc3};
    const start_index: u16 = 1;
    const first_index: u16 = 2;
    const second_index: u16 = 3;
    const first_symbol: u32 = 5;
    const second_symbol: u32 = 6;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.first", &function_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.second", &function_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            Symbol.section(start_index),
            Symbol.section(first_index),
            Symbol.section(second_index),
            Symbol.function("_start", start_index, 0, start_text.len),
            Symbol.function("first", first_index, 0, function_text.len),
            Symbol.function("second", second_index, 0, function_text.len),
        },
        .relocations = &.{
            Relocation.x86_64(1, 1, first_symbol, .PLT32, -4),
            Relocation.x86_64(1, 6, second_symbol, .PLT32, -4),
        },
    });
    defer allocator.free(object);

    const inputs = [_]model.Input{.{ .name = "icf.o", .bytes = object }};
    var retained = try linkExecutable(allocator, &inputs, .{ .incremental_mode = .off });
    defer retained.deinit(allocator);
    var retained_manifest = try linkExecutable(allocator, &inputs, .{});
    defer retained_manifest.deinit(allocator);
    const retained_text = metadata.manifestSection(retained.manifest, ".text") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, 33), retained_text.size);
    try std.testing.expect(metadata.manifestContribution(retained_manifest.manifest, "icf.o", .section, ".text.first", first_index) != null);
    try std.testing.expect(metadata.manifestContribution(retained_manifest.manifest, "icf.o", .section, ".text.second", second_index) != null);

    var folded = try linkExecutable(allocator, &inputs, .{
        .incremental_mode = .off,
        .icf = .all,
    });
    defer folded.deinit(allocator);
    var folded_manifest = try linkExecutable(allocator, &inputs, .{
        .icf = .all,
    });
    defer folded_manifest.deinit(allocator);
    const folded_text = metadata.manifestSection(folded.manifest, ".text") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, 17), folded_text.size);
    try std.testing.expect(metadata.manifestContribution(folded_manifest.manifest, "icf.o", .section, ".text.first", first_index) != null);
    try std.testing.expect(metadata.manifestContribution(folded_manifest.manifest, "icf.o", .section, ".text.second", second_index) == null);
    const folded_second = metadata.manifestDiscardedContribution(folded_manifest.manifest, "icf.o", ".text.second", second_index) orelse return error.MissingSection;
    try std.testing.expectEqual(incremental.DiscardReason.identical_code_folded, folded_second.reason);

    const text_file_offset: usize = @intCast(folded_text.file_offset);
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, folded.bytes[text_file_offset + 1 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 6), std.mem.readInt(i32, folded.bytes[text_file_offset + 6 ..][0..4], .little));
}

test "ELF ICF ignores no-op relocations" {
    const allocator = std.testing.allocator;

    const start_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xe8, 0, 0, 0, 0, 0xc3 };
    const function_text = [_]u8{0xc3};
    const start_index: u16 = 1;
    const first_index: u16 = 2;
    const second_index: u16 = 3;
    const first_symbol: u32 = 5;
    const second_symbol: u32 = 6;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.first", &function_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.second", &function_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            Symbol.section(start_index),
            Symbol.section(first_index),
            Symbol.section(second_index),
            Symbol.function("_start", start_index, 0, start_text.len),
            Symbol.function("first", first_index, 0, function_text.len),
            Symbol.function("second", second_index, 0, function_text.len),
        },
        .relocations = &.{
            Relocation.x86_64(1, 1, first_symbol, .PLT32, -4),
            Relocation.x86_64(1, 6, second_symbol, .PLT32, -4),
            Relocation.x86_64(second_index, 0, 0, .NONE, 0),
        },
    });
    defer allocator.free(object);

    const inputs = [_]model.Input{.{ .name = "icf-none.o", .bytes = object }};
    var linked = try linkExecutable(allocator, &inputs, .{
        .incremental_mode = .off,
        .icf = .all,
    });
    defer linked.deinit(allocator);

    var manifest_linked = try linkExecutable(allocator, &inputs, .{
        .icf = .all,
    });
    defer manifest_linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, 17), text_record.size);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "icf-none.o", .section, ".text.first", first_index) != null);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "icf-none.o", .section, ".text.second", second_index) == null);
    const folded_second = metadata.manifestDiscardedContribution(manifest_linked.manifest, "icf-none.o", ".text.second", second_index) orelse return error.MissingSection;
    try std.testing.expectEqual(incremental.DiscardReason.identical_code_folded, folded_second.reason);
}

test "ELF linker folds relocated code sections with equivalent targets" {
    const allocator = std.testing.allocator;

    const start_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xe8, 0, 0, 0, 0, 0xc3 };
    const start_index: u16 = 1;
    const first_symbol: u32 = 3;
    const second_symbol: u32 = 4;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(start_index),
            Symbol.function("_start", start_index, 0, start_text.len),
            Symbol.undefinedFunction("first"),
            Symbol.undefinedFunction("second"),
        },
        .relocations = &.{
            Relocation.x86_64(1, 1, first_symbol, .PLT32, -4),
            Relocation.x86_64(1, 6, second_symbol, .PLT32, -4),
        },
    });
    defer allocator.free(caller_object);

    const function_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };

    const first_index: u16 = 1;
    const first_target_symbol: u32 = 3;
    const first_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text.first", &function_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(first_index),
            Symbol.function("first", first_index, 0, function_text.len),
            Symbol.undefinedFunction("target"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, first_target_symbol, .PLT32, -4)},
    });
    defer allocator.free(first_object);

    const second_index: u16 = 1;
    const second_target_symbol: u32 = 3;
    const second_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text.second", &function_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(second_index),
            Symbol.function("second", second_index, 0, function_text.len),
            Symbol.undefinedFunction("target"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, second_target_symbol, .PLT32, -4)},
    });
    defer allocator.free(second_object);

    const target_text = [_]u8{0xc3};
    const target_index: u16 = 1;
    const target_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text.target", &target_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{ Symbol.section(target_index), Symbol.function("target", target_index, 0, target_text.len) },
    });
    defer allocator.free(target_object);

    const inputs = [_]model.Input{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "first.o", .bytes = first_object },
        .{ .name = "second.o", .bytes = second_object },
        .{ .name = "target.o", .bytes = target_object },
    };

    var linked = try linkExecutable(allocator, &inputs, .{
        .incremental_mode = .off,
        .icf = .all,
    });
    defer linked.deinit(allocator);

    var manifest_linked = try linkExecutable(allocator, &inputs, .{
        .icf = .all,
    });
    defer manifest_linked.deinit(allocator);

    const text = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, 33), text.size);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "first.o", .section, ".text.first", first_index) != null);
    try std.testing.expect(metadata.manifestContribution(manifest_linked.manifest, "second.o", .section, ".text.second", second_index) == null);
    const folded_second = metadata.manifestDiscardedContribution(manifest_linked.manifest, "second.o", ".text.second", second_index) orelse return error.MissingSection;
    try std.testing.expectEqual(incremental.DiscardReason.identical_code_folded, folded_second.reason);

    const text_file_offset: usize = @intCast(text.file_offset);
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[text_file_offset + 1 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 6), std.mem.readInt(i32, linked.bytes[text_file_offset + 6 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[text_file_offset + 17 ..][0..4], .little));
}

test "ELF linker keeps relocated code sections with different targets distinct in ICF" {
    const allocator = std.testing.allocator;

    const start_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xe8, 0, 0, 0, 0, 0xc3 };
    const function_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const target_text = [_]u8{0xc3};
    const start_index: u16 = 1;
    const first_index: u16 = 2;
    const second_index: u16 = 3;
    const first_target_index: u16 = 4;
    const second_target_index: u16 = 5;
    const first_symbol: u32 = 7;
    const second_symbol: u32 = 8;
    const first_target_symbol: u32 = 9;
    const second_target_symbol: u32 = 10;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.first", &function_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.second", &function_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.first_target", &target_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.second_target", &target_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            Symbol.section(start_index),
            Symbol.section(first_index),
            Symbol.section(second_index),
            Symbol.section(first_target_index),
            Symbol.section(second_target_index),
            Symbol.function("_start", start_index, 0, start_text.len),
            Symbol.function("first", first_index, 0, function_text.len),
            Symbol.function("second", second_index, 0, function_text.len),
            Symbol.function("first_target", first_target_index, 0, target_text.len),
            Symbol.function("second_target", second_target_index, 0, target_text.len),
        },
        .relocations = &.{
            Relocation.x86_64(start_index, 1, first_symbol, .PLT32, -4),
            Relocation.x86_64(start_index, 6, second_symbol, .PLT32, -4),
            Relocation.x86_64(first_index, 1, first_target_symbol, .PLT32, -4),
            Relocation.x86_64(second_index, 1, second_target_symbol, .PLT32, -4),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "distinct-targets.o", .bytes = object }}, .{
        .icf = .all,
    });
    defer linked.deinit(allocator);

    try std.testing.expect(metadata.manifestContribution(linked.manifest, "distinct-targets.o", .section, ".text.first", first_index) != null);
    try std.testing.expect(metadata.manifestContribution(linked.manifest, "distinct-targets.o", .section, ".text.second", second_index) != null);
}

test "ELF linker applies absolute relocations to read-only data" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const rodata = [_]u8{ 'o', 'k', 0 };
    const text_index: u16 = 1;
    const rodata_index: u16 = 2;
    const message_symbol: u32 = 4;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".rodata", &rodata, 0, 1),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(rodata_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.object("message", rodata_index, 0, rodata.len),
        },
        .relocations = &.{Relocation.x86_64(1, 2, message_symbol, .@"64", 0)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "abs.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_file_offset: usize = @intCast(linked.manifest.sections[0].file_offset);
    const rodata_record = metadata.manifestSection(linked.manifest, ".rodata") orelse return error.MissingSection;
    const rodata_address = rodata_record.address;
    try std.testing.expectEqual(rodata_address, std.mem.readInt(u64, linked.bytes[text_file_offset + 2 ..][0..8], .little));
    const rodata_file_offset: usize = @intCast(rodata_record.file_offset);
    try std.testing.expectEqualSlices(u8, &rodata, linked.bytes[rodata_file_offset..][0..rodata.len]);
}

test "ELF linker merges fixed-size mergeable constants" {
    const allocator = std.testing.allocator;

    const text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0x48, 0xbb,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const text_index: u16 = 1;
    const duplicated_symbol: u32 = 3;
    const section_addend_symbol: u32 = 4;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.undefinedObject("duplicated_constant"),
            Symbol.undefinedObject("section_addend_constant"),
        },
        .relocations = &.{
            Relocation.x86_64(1, 2, duplicated_symbol, .@"64", 0),
            Relocation.x86_64(1, 12, section_addend_symbol, .@"64", 0),
        },
    });
    defer allocator.free(caller_object);

    const constant = [_]u8{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe };
    const first_section: u16 = 1;
    const first_object = try buildObject(allocator, .{
        .sections = &.{Section.mergeable(".rodata.cst8", &constant, 0, 8, 8)},
        .symbols = &.{
            Symbol.section(first_section),
            Symbol.object("first_constant", first_section, 0, constant.len),
        },
    });
    defer allocator.free(first_object);

    const duplicate_section: u16 = 1;
    const duplicate_object = try buildObject(allocator, .{
        .sections = &.{Section.mergeable(".rodata.cst8", &constant, 0, 8, 8)},
        .symbols = &.{
            Symbol.section(duplicate_section),
            Symbol.object("duplicated_constant", duplicate_section, 0, constant.len),
        },
    });
    defer allocator.free(duplicate_object);

    const pair = constant ++ constant;
    const pair_section: u16 = 1;
    const pair_section_symbol: u32 = 1;
    const probe_text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const probe_text_index: u16 = 2;
    const section_addend_object = try buildObject(allocator, .{
        .sections = &.{
            Section.mergeable(".rodata.cst8", &pair, 0, 8, 8),
            Section.progbits(".text.probe", &probe_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            Symbol.section(pair_section),
            Symbol.section(probe_text_index),
            Symbol.object("section_addend_constant", pair_section, 8, constant.len),
            Symbol.function("section_probe", probe_text_index, 0, probe_text.len),
        },
        .relocations = &.{Relocation.x86_64(probe_text_index, 2, pair_section_symbol, .@"64", 8)},
    });
    defer allocator.free(section_addend_object);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "first.o", .bytes = first_object },
        .{ .name = "duplicate.o", .bytes = duplicate_object },
        .{ .name = "section-addend.o", .bytes = section_addend_object },
    }, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const rodata = metadata.manifestSection(linked.manifest, ".rodata") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, constant.len), rodata.size);
    try std.testing.expectEqualSlices(u8, &constant, linked.bytes[@as(usize, @intCast(rodata.file_offset))..][0..constant.len]);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const text_file_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(rodata.address, std.mem.readInt(u64, linked.bytes[text_file_offset + 2 ..][0..8], .little));
    try std.testing.expectEqual(rodata.address, std.mem.readInt(u64, linked.bytes[text_file_offset + 12 ..][0..8], .little));

    const probe_file_offset = @as(usize, @intCast(text_record.file_offset)) + alignForward(text.len, 16);
    try std.testing.expectEqual(rodata.address, std.mem.readInt(u64, linked.bytes[probe_file_offset + 2 ..][0..8], .little));
}

test "ELF linker preserves external mergeable string starts" {
    const allocator = std.testing.allocator;

    const text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0x48, 0xbb,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const text_index: u16 = 1;
    const suffix_symbol: u32 = 3;
    const duplicate_symbol: u32 = 4;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.undefinedObject("suffix_string"),
            Symbol.undefinedObject("duplicate_suffix"),
        },
        .relocations = &.{
            Relocation.x86_64(1, 2, suffix_symbol, .@"64", 0),
            Relocation.x86_64(1, 12, duplicate_symbol, .@"64", 0),
        },
    });
    defer allocator.free(caller_object);

    const prefix = "prefix-";
    const suffix = "tail";
    const long_string = prefix ++ suffix ++ "\x00";
    const long_section: u16 = 1;
    const long_object = try buildObject(allocator, .{
        .sections = &.{Section.strings(".rodata.str1.1", long_string, 1)},
        .symbols = &.{
            Symbol.section(long_section),
            Symbol.object("long_string", long_section, 0, long_string.len),
        },
    });
    defer allocator.free(long_object);

    const suffix_string = suffix ++ "\x00";
    const suffix_section: u16 = 1;
    const suffix_object = try buildObject(allocator, .{
        .sections = &.{Section.strings(".rodata.str1.1", suffix_string, 1)},
        .symbols = &.{
            Symbol.section(suffix_section),
            Symbol.object("suffix_string", suffix_section, 0, suffix_string.len),
        },
    });
    defer allocator.free(suffix_object);

    const duplicate_section: u16 = 1;
    const duplicate_object = try buildObject(allocator, .{
        .sections = &.{Section.strings(".rodata.str1.1", suffix_string, 1)},
        .symbols = &.{
            Symbol.section(duplicate_section),
            Symbol.object("duplicate_suffix", duplicate_section, 0, suffix_string.len),
        },
    });
    defer allocator.free(duplicate_object);

    const second_prefix = "second-";
    const second_long = second_prefix ++ suffix ++ "\x00";
    const pair = second_long ++ suffix_string;
    const second_suffix_offset = second_long.len;
    const pair_section: u16 = 1;
    const pair_section_symbol: u32 = 1;
    const probe_text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const probe_text_index: u16 = 2;
    const section_addend_object = try buildObject(allocator, .{
        .sections = &.{
            Section.strings(".rodata.str1.1", pair, 1),
            Section.progbits(".text.probe", &probe_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            Symbol.section(pair_section),
            Symbol.section(probe_text_index),
            Symbol.function("section_probe", probe_text_index, 0, probe_text.len),
        },
        .relocations = &.{
            Relocation.x86_64(probe_text_index, 2, pair_section_symbol, .@"64", second_suffix_offset),
        },
    });
    defer allocator.free(section_addend_object);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "long.o", .bytes = long_object },
        .{ .name = "suffix.o", .bytes = suffix_object },
        .{ .name = "duplicate.o", .bytes = duplicate_object },
        .{ .name = "section-addend.o", .bytes = section_addend_object },
    }, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const rodata = metadata.manifestSection(linked.manifest, ".rodata") orelse return error.MissingSection;
    const expected_rodata = long_string ++ second_long ++ suffix_string;
    try std.testing.expectEqual(@as(u64, expected_rodata.len), rodata.size);
    try std.testing.expectEqualSlices(u8, expected_rodata, linked.bytes[@as(usize, @intCast(rodata.file_offset))..][0..expected_rodata.len]);

    const expected_suffix_address = rodata.address + long_string.len + second_long.len;
    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const text_file_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(expected_suffix_address, std.mem.readInt(u64, linked.bytes[text_file_offset + 2 ..][0..8], .little));
    try std.testing.expectEqual(expected_suffix_address, std.mem.readInt(u64, linked.bytes[text_file_offset + 12 ..][0..8], .little));

    const probe_file_offset = @as(usize, @intCast(text_record.file_offset)) + alignForward(text.len, 16);
    try std.testing.expectEqual(expected_suffix_address, std.mem.readInt(u64, linked.bytes[probe_file_offset + 2 ..][0..8], .little));
}

test "ELF linker relaxes x86_64 GOTPCRELX data address loads" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0x48, 0x8b, 0x05,
        0,    0,    0,
        0,    0xc3,
    };
    const rodata = [_]u8{ 'o', 'k', 0 };
    const text_index: u16 = 1;
    const rodata_index: u16 = 2;
    const message_symbol: u32 = 4;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".rodata", &rodata, 0, 1),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(rodata_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.object("message", rodata_index, 0, rodata.len),
        },
        .relocations = &.{Relocation.x86_64(1, 3, message_symbol, .REX_GOTPCRELX, -4)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "gotpcrelx.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const rodata_record = metadata.manifestSection(linked.manifest, ".rodata") orelse return error.MissingSection;
    const text_file_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(@as(u8, 0x8d), linked.bytes[text_file_offset + 1]);

    const displacement = std.mem.readInt(i32, linked.bytes[text_file_offset + 3 ..][0..4], .little);
    const next_instruction = text_record.address + 7;
    const loaded_address = @as(i128, next_instruction) + displacement;
    try std.testing.expectEqual(@as(i128, rodata_record.address), loaded_address);
}

test "ELF linker relaxes x86_64 REX_GOTPCRELX address ALU operations" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0x48, 0x3b, 0x35,
        0,    0,    0,
        0,    0x4c, 0x3b,
        0x0d, 0,    0,
        0,    0,    0x48,
        0x2b, 0x0d, 0,
        0,    0,    0,
        0xc3,
    };
    const rodata = [_]u8{ 'o', 'k', 0 };
    const text_index: u16 = 1;
    const rodata_index: u16 = 2;
    const message_symbol: u32 = 4;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".rodata", &rodata, 0, 1),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(rodata_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.object("message", rodata_index, 0, rodata.len),
        },
        .relocations = &.{
            Relocation.x86_64(1, 3, message_symbol, .REX_GOTPCRELX, -4),
            Relocation.x86_64(1, 10, message_symbol, .REX_GOTPCRELX, -4),
            Relocation.x86_64(1, 17, message_symbol, .REX_GOTPCRELX, -4),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "gotpcrelx-alu.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const rodata_record = metadata.manifestSection(linked.manifest, ".rodata") orelse return error.MissingSection;
    const text_file_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(@as(u8, 0x48), linked.bytes[text_file_offset]);
    try std.testing.expectEqual(@as(u8, 0x81), linked.bytes[text_file_offset + 1]);
    try std.testing.expectEqual(@as(u8, 0xfe), linked.bytes[text_file_offset + 2]);
    try std.testing.expectEqual(@as(i32, @intCast(rodata_record.address)), std.mem.readInt(i32, linked.bytes[text_file_offset + 3 ..][0..4], .little));
    try std.testing.expectEqual(@as(u8, 0x49), linked.bytes[text_file_offset + 7]);
    try std.testing.expectEqual(@as(u8, 0x81), linked.bytes[text_file_offset + 8]);
    try std.testing.expectEqual(@as(u8, 0xf9), linked.bytes[text_file_offset + 9]);
    try std.testing.expectEqual(@as(i32, @intCast(rodata_record.address)), std.mem.readInt(i32, linked.bytes[text_file_offset + 10 ..][0..4], .little));
    try std.testing.expectEqual(@as(u8, 0x48), linked.bytes[text_file_offset + 14]);
    try std.testing.expectEqual(@as(u8, 0x81), linked.bytes[text_file_offset + 15]);
    try std.testing.expectEqual(@as(u8, 0xe9), linked.bytes[text_file_offset + 16]);
    try std.testing.expectEqual(@as(i32, @intCast(rodata_record.address)), std.mem.readInt(i32, linked.bytes[text_file_offset + 17 ..][0..4], .little));
}

test "ELF linker relaxes x86_64 GOTPCRELX indirect calls" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0xff, 0x15,
        0,    0,
        0,    0,
        0xf4, 0xc3,
    };
    const text_index: u16 = 1;
    const callee_symbol: u32 = 3;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, 7),
            Symbol.function("callee", text_index, 7, 1),
        },
        .relocations = &.{Relocation.x86_64(1, 2, callee_symbol, .GOTPCRELX, -4)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "gotpcrelx-call.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const text_file_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(@as(u8, 0x67), linked.bytes[text_file_offset]);
    try std.testing.expectEqual(@as(u8, 0xe8), linked.bytes[text_file_offset + 1]);

    const displacement = std.mem.readInt(i32, linked.bytes[text_file_offset + 2 ..][0..4], .little);
    const next_instruction = text_record.address + 6;
    const loaded_address = @as(i128, next_instruction) + displacement;
    try std.testing.expectEqual(@as(i128, text_record.address + 7), loaded_address);
}

test "ELF linker relaxes x86_64 GOTPCRELX indirect jumps" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0xff, 0x25,
        0,    0,
        0,    0,
        0xf4, 0xc3,
    };
    const text_index: u16 = 1;
    const callee_symbol: u32 = 3;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, 7),
            Symbol.function("callee", text_index, 7, 1),
        },
        .relocations = &.{Relocation.x86_64(1, 2, callee_symbol, .GOTPCRELX, -4)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "gotpcrelx-jump.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const text_file_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(@as(u8, 0x67), linked.bytes[text_file_offset]);
    try std.testing.expectEqual(@as(u8, 0xe9), linked.bytes[text_file_offset + 1]);

    const displacement = std.mem.readInt(i32, linked.bytes[text_file_offset + 2 ..][0..4], .little);
    const next_instruction = text_record.address + 6;
    const loaded_address = @as(i128, next_instruction) + displacement;
    try std.testing.expectEqual(@as(i128, text_record.address + 7), loaded_address);
}

test "ELF linker relaxes legacy x86_64 GOTPCREL data address loads" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0x48, 0x8b, 0x05,
        0,    0,    0,
        0,    0xc3,
    };
    const rodata = [_]u8{ 'o', 'k', 0 };
    const text_index: u16 = 1;
    const rodata_index: u16 = 2;
    const message_symbol: u32 = 4;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".rodata", &rodata, 0, 1),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(rodata_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.object("message", rodata_index, 0, rodata.len),
        },
        .relocations = &.{Relocation.x86_64(1, 3, message_symbol, .GOTPCREL, -4)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "gotpcrel.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const rodata_record = metadata.manifestSection(linked.manifest, ".rodata") orelse return error.MissingSection;
    const text_file_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(@as(u8, 0x8d), linked.bytes[text_file_offset + 1]);

    const displacement = std.mem.readInt(i32, linked.bytes[text_file_offset + 3 ..][0..4], .little);
    const next_instruction = text_record.address + 7;
    const loaded_address = @as(i128, next_instruction) + displacement;
    try std.testing.expectEqual(@as(i128, rodata_record.address), loaded_address);
}

test "ELF linker emits x86_64 GOTPCREL entries for memory operands" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0xf3, 0x0f, 0x7e, 0x0d,
        0,    0,    0,    0,
        0xc3,
    };
    const rodata = [_]u8{ 'o', 'k', 0 };
    const text_index: u16 = 1;
    const rodata_index: u16 = 2;
    const message_symbol: u32 = 4;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".rodata", &rodata, 0, 1),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(rodata_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.object("message", rodata_index, 0, rodata.len),
        },
        .relocations = &.{Relocation.x86_64(1, 4, message_symbol, .GOTPCREL, -4)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "gotpcrel-memory.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const rodata_record = metadata.manifestSection(linked.manifest, ".rodata") orelse return error.MissingSection;
    const got_record = metadata.manifestSection(linked.manifest, ".got") orelse return error.MissingSection;
    const text_file_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(@as(u64, 8), got_record.size);
    try std.testing.expectEqual(rodata_record.address, readU64(linked.bytes, @intCast(got_record.file_offset)));
    try std.testing.expectEqualSlices(u8, text[0..4], linked.bytes[text_file_offset..][0..4]);

    const displacement = std.mem.readInt(i32, linked.bytes[text_file_offset + 4 ..][0..4], .little);
    const next_instruction = text_record.address + 8;
    const got_address = @as(i128, next_instruction) + displacement;
    try std.testing.expectEqual(@as(i128, got_record.address), got_address);
}

test "ELF linker relaxes x86_64 GOTPCREL weak undefined null checks" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0x48, 0x83, 0x3d,
        0,    0,    0,
        0,    0,    0x75,
        0x01, 0xcc, 0xc3,
    };
    const text_index: u16 = 1;
    const weak_symbol: u32 = 3;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.weakUndefinedFunction("weak_tls_init"),
        },
        .relocations = &.{Relocation.x86_64(text_index, 3, weak_symbol, .GOTPCREL, -5)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "gotpcrel-weak-null.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const text_file_offset: usize = @intCast(text_record.file_offset);
    const expected = [_]u8{ 0x48, 0x39, 0xe4, 0x0f, 0x1f, 0x44, 0x00, 0x00 };
    try std.testing.expectEqualSlices(u8, &expected, linked.bytes[text_file_offset..][0..expected.len]);
    try std.testing.expectEqual(@as(u8, 0x75), linked.bytes[text_file_offset + 8]);
}

test "ELF linker rejects malformed GOTPCRELX relaxation instructions" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0x48, 0x8b, 0x45,
        0,    0,    0,
        0,    0xc3,
    };
    const rodata = [_]u8{ 'o', 'k', 0 };
    const text_index: u16 = 1;
    const rodata_index: u16 = 2;
    const message_symbol: u32 = 4;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".rodata", &rodata, 0, 1),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(rodata_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.object("message", rodata_index, 0, rodata.len),
        },
        .relocations = &.{Relocation.x86_64(1, 3, message_symbol, .REX_GOTPCRELX, -4)},
    });
    defer allocator.free(object);

    var diagnostics: model.Diagnostics = .{};
    try std.testing.expectError(error.UnsupportedRelocation, linkExecutable(
        allocator,
        &.{.{ .name = "bad-gotpcrelx.o", .bytes = object }},
        .{
            .incremental_mode = .off,
            .diagnostics = &diagnostics,
        },
    ));

    const unsupported = diagnostics.first_unsupported_relocation orelse return error.ExpectedUnsupportedRelocationDiagnostic;
    try std.testing.expectEqual(@backingInt(std.elf.R_X86_64.REX_GOTPCRELX), unsupported.relocation_type);
}

test "ELF linker places x86_64 unwind sections in read-only output" {
    const allocator = std.testing.allocator;
    const text = [_]u8{0xc3};
    const unwind = [_]u8{ 0x14, 0, 0, 0, 0, 0, 0, 0 };
    const text_index: u16 = 1;
    const unwind_index: u16 = 2;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            .{
                .name = ".eh_frame",
                .section_type = std.elf.SHT_X86_64_UNWIND,
                .flags = std.elf.SHF_ALLOC,
                .alignment = 8,
                .bytes = &unwind,
            },
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(unwind_index),
            Symbol.function("_start", text_index, 0, text.len),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "unwind.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const eh_frame = metadata.manifestSection(linked.manifest, ".eh_frame") orelse return error.MissingSection;
    const payload_offset: usize = @intCast(eh_frame.file_offset);
    try std.testing.expectEqualSlices(u8, &unwind, linked.bytes[payload_offset..][0..unwind.len]);
}

test "ELF linker prunes eh_frame FDEs for discarded COMDAT sections" {
    const allocator = std.testing.allocator;

    const retained_text = [_]u8{0xc3};
    const retained_text_index: u16 = 1;
    const retained_symbol: u32 = 2;
    var retained_group_payload: [(1 + 1) * 4]u8 = undefined;
    const retained_group_bytes = groupBytes(&retained_group_payload, &.{retained_text_index});
    const retained_object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.inline", &retained_text, std.elf.SHF_EXECINSTR | std.elf.SHF_GROUP, 16),
            Section.group(".group", retained_group_bytes, retained_symbol),
        },
        .symbols = &.{
            Symbol.section(retained_text_index),
            Symbol.function("inline_fn", retained_text_index, 0, retained_text.len),
        },
    });
    defer allocator.free(retained_object);

    const start_text = [_]u8{0xc3};
    const duplicate_text = [_]u8{0xcc};
    var unwind = @as([0x40]u8, @splat(0));
    std.mem.writeInt(u32, unwind[0x00..][0..4], 0x14, .little);
    std.mem.writeInt(u32, unwind[0x04..][0..4], 0, .little);
    std.mem.writeInt(u32, unwind[0x18..][0..4], 0x10, .little);
    std.mem.writeInt(u32, unwind[0x1c..][0..4], 0x1c, .little);
    std.mem.writeInt(u32, unwind[0x24..][0..4], 1, .little);
    std.mem.writeInt(u32, unwind[0x2c..][0..4], 0x10, .little);
    std.mem.writeInt(u32, unwind[0x30..][0..4], 0x30, .little);
    std.mem.writeInt(u32, unwind[0x38..][0..4], 1, .little);

    const start_text_index: u16 = 1;
    const duplicate_text_index: u16 = 2;
    const eh_frame_index: u16 = 3;
    const duplicate_section_symbol: u32 = 2;
    const start_symbol: u32 = 4;
    const duplicate_symbol: u32 = 5;
    var frame_group_payload: [(1 + 1) * 4]u8 = undefined;
    const frame_group_bytes = groupBytes(&frame_group_payload, &.{duplicate_text_index});
    const frame_object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.inline", &duplicate_text, std.elf.SHF_EXECINSTR | std.elf.SHF_GROUP, 16),
            .{
                .name = ".eh_frame",
                .section_type = std.elf.SHT_X86_64_UNWIND,
                .flags = std.elf.SHF_ALLOC,
                .alignment = 8,
                .bytes = &unwind,
            },
            Section.group(".group", frame_group_bytes, duplicate_symbol),
        },
        .symbols = &.{
            Symbol.section(start_text_index),
            Symbol.section(duplicate_text_index),
            Symbol.section(eh_frame_index),
            Symbol.function("_start", start_text_index, 0, start_text.len),
            Symbol.function("inline_fn", duplicate_text_index, 0, duplicate_text.len),
        },
        .relocations = &.{
            Relocation.x86_64(eh_frame_index, 0x20, duplicate_section_symbol, .PC32, 0),
            Relocation.x86_64(eh_frame_index, 0x34, start_symbol, .PC32, 0),
        },
    });
    defer allocator.free(frame_object);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "retained.o", .bytes = retained_object },
        .{ .name = "frame.o", .bytes = frame_object },
    }, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const eh_frame_record = metadata.manifestSection(linked.manifest, ".eh_frame") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, 0x2c), eh_frame_record.size);
    const payload_offset: usize = @intCast(eh_frame_record.file_offset);
    try std.testing.expectEqual(@as(u32, 0x14), std.mem.readInt(u32, linked.bytes[payload_offset..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x10), std.mem.readInt(u32, linked.bytes[payload_offset + 0x18 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x1c), std.mem.readInt(u32, linked.bytes[payload_offset + 0x1c ..][0..4], .little));
    try std.testing.expect(std.mem.readInt(i32, linked.bytes[payload_offset + 0x20 ..][0..4], .little) != 0);
}

test "ELF linker emits eh_frame_hdr for retained FDEs" {
    const allocator = std.testing.allocator;

    const text = [_]u8{0xc3};
    var unwind = @as([0x2c]u8, @splat(0));
    std.mem.writeInt(u32, unwind[0x00..][0..4], 0x14, .little);
    std.mem.writeInt(u32, unwind[0x04..][0..4], 0, .little);
    std.mem.writeInt(u32, unwind[0x18..][0..4], 0x10, .little);
    std.mem.writeInt(u32, unwind[0x1c..][0..4], 0x1c, .little);
    std.mem.writeInt(u32, unwind[0x24..][0..4], 1, .little);

    const text_index: u16 = 1;
    const eh_frame_index: u16 = 2;
    const start_symbol: u32 = 3;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            .{
                .name = ".eh_frame",
                .section_type = std.elf.SHT_X86_64_UNWIND,
                .flags = std.elf.SHF_ALLOC,
                .alignment = 8,
                .bytes = &unwind,
            },
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(eh_frame_index),
            Symbol.function("_start", text_index, 0, text.len),
        },
        .relocations = &.{Relocation.x86_64(eh_frame_index, 0x20, start_symbol, .PC32, 0)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "eh-frame-hdr.o", .bytes = object }}, .{ .incremental_mode = .off, .eh_frame_header = true });
    defer linked.deinit(allocator);

    const header = try metadata.linkedSectionByName(linked.bytes, ".eh_frame_hdr");
    const rodata = metadata.manifestSection(linked.manifest, ".eh_frame") orelse return error.MissingSection;
    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const segment = try metadata.programHeaderByType(linked.bytes, @backingInt(std.elf.PT.GNU_EH_FRAME));

    try std.testing.expectEqual(std.elf.SHT_PROGBITS, header.section_type);
    try std.testing.expectEqual(@as(u64, std.elf.SHF_ALLOC), header.flags);
    try std.testing.expectEqual(@as(u64, eh_frame_hdr_fixed_size + eh_frame_hdr_entry_size), header.size);
    try std.testing.expectEqual(header.address, segment.virtual_address);
    try std.testing.expectEqual(header.offset, segment.file_offset);
    try std.testing.expectEqual(header.size, segment.file_size);

    const offset: usize = @intCast(header.offset);
    try std.testing.expectEqual(@as(u8, 1), linked.bytes[offset + 0]);
    try std.testing.expectEqual(@as(u8, dwarf_eh_pe_pcrel | dwarf_eh_pe_sdata4), linked.bytes[offset + 1]);
    try std.testing.expectEqual(@as(u8, dwarf_eh_pe_udata4), linked.bytes[offset + 2]);
    try std.testing.expectEqual(@as(u8, dwarf_eh_pe_datarel | dwarf_eh_pe_sdata4), linked.bytes[offset + 3]);
    try std.testing.expectEqual(@as(i32, @intCast(@as(i128, @intCast(rodata.address)) - @as(i128, @intCast(header.address + 4)))), std.mem.readInt(i32, linked.bytes[offset + 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, linked.bytes[offset + 8 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, @intCast(@as(i128, @intCast(text_record.address)) - @as(i128, @intCast(header.address)))), std.mem.readInt(i32, linked.bytes[offset + 12 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, @intCast(@as(i128, @intCast(rodata.address + 0x18)) - @as(i128, @intCast(header.address)))), std.mem.readInt(i32, linked.bytes[offset + 16 ..][0..4], .little));
}

test "ELF linker preserves non-allocated DWARF sections in executable output" {
    const allocator = std.testing.allocator;

    const text = [_]u8{0xc3};
    const debug = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const text_index: u16 = 1;
    const debug_index: u16 = 2;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.nonAlloc(".debug_info", &debug, std.elf.SHT_PROGBITS, 1),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(debug_index),
            Symbol.function("_start", text_index, 0, text.len),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "debug.o", .bytes = object }}, .{});
    defer linked.deinit(allocator);

    try std.testing.expect(metadata.manifestContribution(linked.manifest, "debug.o", .section, ".text", text_index) != null);
    const debug_contribution = metadata.manifestContribution(linked.manifest, "debug.o", .section, ".debug_info", debug_index) orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, debug.len), debug_contribution.file_size);
    try std.testing.expectEqual(@as(usize, 2), linked.manifest.sections.len);

    const debug_plan = linked.manifest.planContributionReplacement(&.{
        .{ .input_name = "debug.o", .input_index = 0, .kind = .section, .name = ".debug_info", .ordinal = debug_index, .size = debug.len, .alignment = 1 },
    });
    try std.testing.expectEqual(incremental.PatchDecision.in_place, debug_plan.decision);

    const debug_section = try metadata.linkedSectionByName(linked.bytes, ".debug_info");
    try std.testing.expectEqual(@as(u64, 0), debug_section.address);
    try std.testing.expect(debug_section.size >= debug.len);
    try std.testing.expectEqualSlices(u8, &debug, linked.bytes[@intCast(debug_section.offset)..][0..debug.len]);
}

test "ELF linker strips non-allocated DWARF sections when requested" {
    const allocator = std.testing.allocator;

    const text = [_]u8{0xc3};
    const debug = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const text_index: u16 = 1;
    const debug_index: u16 = 2;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.nonAlloc(".debug_info", &debug, std.elf.SHT_PROGBITS, 1),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(debug_index),
            Symbol.function("_start", text_index, 0, text.len),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "debug.o", .bytes = object }}, .{ .strip_debug = true });
    defer linked.deinit(allocator);

    try std.testing.expect(linked.manifest.strip_debug);
    try std.testing.expect(metadata.manifestContribution(linked.manifest, "debug.o", .section, ".text", text_index) != null);
    try std.testing.expect(metadata.manifestContribution(linked.manifest, "debug.o", .section, ".debug_info", debug_index) == null);
    try std.testing.expectEqual(@as(usize, 1), linked.manifest.sections.len);
    try std.testing.expectError(error.MissingSection, metadata.linkedSectionByName(linked.bytes, ".debug_info"));
}

test "ELF linker applies relocations in non-allocated DWARF sections" {
    const allocator = std.testing.allocator;

    const text = [_]u8{0xc3};
    const debug_info = @as([16]u8, @splat(0));
    const debug_abbrev = [_]u8{ 1, 2, 3, 4 };
    const text_index: u16 = 1;
    const debug_info_index: u16 = 2;
    const debug_abbrev_index: u16 = 3;
    const debug_abbrev_symbol: u32 = 3;
    const start_symbol: u32 = 4;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.nonAlloc(".debug_info", &debug_info, std.elf.SHT_PROGBITS, 1),
            Section.nonAlloc(".debug_abbrev", &debug_abbrev, std.elf.SHT_PROGBITS, 1),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(debug_info_index),
            Symbol.section(debug_abbrev_index),
            Symbol.function("_start", text_index, 0, text.len),
        },
        .relocations = &.{
            Relocation.x86_64(debug_info_index, 0, start_symbol, .@"64", 0),
            Relocation.x86_64(debug_info_index, 8, debug_abbrev_symbol, .@"64", 2),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "debug-reloc.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const debug_section = try metadata.linkedSectionByName(linked.bytes, ".debug_info");
    const debug_offset: usize = @intCast(debug_section.offset);
    try std.testing.expectEqual(text_record.address, readU64(linked.bytes, debug_offset));
    try std.testing.expectEqual(@as(u64, 2), readU64(linked.bytes, debug_offset + 8));
}

test "ELF linker leaves DWARF relocations to GC-discarded sections unresolved" {
    const allocator = std.testing.allocator;

    const live_text = [_]u8{0xc3};
    const dead_text = [_]u8{0xc3};
    const debug_info = @as([8]u8, @splat(0));
    const live_index: u16 = 1;
    const dead_index: u16 = 2;
    const debug_index: u16 = 3;
    const dead_symbol: u32 = 5;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text.live", &live_text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".text.dead", &dead_text, std.elf.SHF_EXECINSTR, 16),
            Section.nonAlloc(".debug_info", &debug_info, std.elf.SHT_PROGBITS, 1),
        },
        .symbols = &.{
            Symbol.section(live_index),
            Symbol.section(dead_index),
            Symbol.section(debug_index),
            Symbol.function("_start", live_index, 0, live_text.len),
            Symbol.function("dead", dead_index, 0, dead_text.len),
        },
        .relocations = &.{Relocation.x86_64(debug_index, 0, dead_symbol, .@"64", 0)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "debug-gc.o", .bytes = object }}, .{ .gc_sections = true, .incremental_mode = .off });
    defer linked.deinit(allocator);

    const debug_section = try metadata.linkedSectionByName(linked.bytes, ".debug_info");
    try std.testing.expectEqual(@as(u64, 0), readU64(linked.bytes, @intCast(debug_section.offset)));
}

test "ELF linker keeps SHT_NOBITS out of file payload" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const text_index: u16 = 1;
    const bss_index: u16 = 2;
    const scratch_symbol: u32 = 4;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.nobits(".bss", 32, std.elf.SHF_WRITE, 16),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(bss_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.object("scratch", bss_index, 0, 32),
        },
        .relocations = &.{Relocation.x86_64(1, 2, scratch_symbol, .@"64", 0)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "bss.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const bss_record = metadata.manifestSection(linked.manifest, ".bss") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, 32), bss_record.size);
    try std.testing.expectEqual(@as(u64, 32), bss_record.reserved_size);
    try std.testing.expectEqual(@as(u64, 16), bss_record.alignment);
    try std.testing.expectEqual(bss_record.address, std.mem.readInt(u64, linked.bytes[@as(usize, @intCast(text_record.file_offset)) + 2 ..][0..8], .little));

    const bss_header = try metadata.linkedSectionByName(linked.bytes, ".bss");
    try std.testing.expectEqual(std.elf.SHT_NOBITS, bss_header.section_type);
    try std.testing.expectEqual(bss_record.file_offset, bss_header.offset);
    try std.testing.expectEqual(@as(u64, 32), bss_header.size);

    const bss_load = try metadata.loadProgramHeaderByAddress(linked.bytes, bss_record.address);
    try std.testing.expectEqual(std.elf.PF_R | std.elf.PF_W, bss_load.flags);
    try std.testing.expectEqual(bss_record.file_offset, bss_load.file_offset);
    try std.testing.expectEqual(bss_record.address, bss_load.virtual_address);
    try std.testing.expectEqual(@as(u64, 0), bss_load.file_size);
    try std.testing.expectEqual(@as(u64, 32), bss_load.memory_size);
}

test "ELF linker resolves symbols on empty allocated sections" {
    const allocator = std.testing.allocator;

    const text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const caller_text_index: u16 = 1;
    const marker_ref: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, text.len),
            Symbol.undefinedObject("__TMC_END__"),
        },
        .relocations = &.{Relocation.x86_64(1, 2, marker_ref, .@"64", 0)},
    });
    defer allocator.free(caller_object);

    const data = [_]u8{ 1, 2, 3 };
    const marker_index: u16 = 2;
    const marker_object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".data.payload", &data, std.elf.SHF_WRITE, 1),
            Section.progbits(".tm_clone_table", &.{}, std.elf.SHF_WRITE, 8),
        },
        .symbols = &.{
            Symbol.section(1),
            Symbol.section(marker_index),
            Symbol.object("__TMC_END__", marker_index, 0, 0),
        },
    });
    defer allocator.free(marker_object);

    var linked = try linkExecutable(
        allocator,
        &.{
            .{ .name = "caller.o", .bytes = caller_object },
            .{ .name = "marker.o", .bytes = marker_object },
        },
        .{},
    );
    defer linked.deinit(allocator);

    const caller_contribution = metadata.manifestContribution(linked.manifest, "caller.o", .section, ".text", caller_text_index) orelse return error.MissingSection;
    const marker_contribution = metadata.manifestContribution(linked.manifest, "marker.o", .section, ".tm_clone_table", marker_index) orelse return error.MissingSection;
    const loaded = readU64(linked.bytes, @intCast(caller_contribution.file_offset + 2));
    try std.testing.expectEqual(@as(u64, 0), marker_contribution.size);
    try std.testing.expectEqual(@as(u64, 8), marker_contribution.alignment);
    try std.testing.expectEqual(@as(u64, 0), marker_contribution.address % 8);
    try std.testing.expectEqual(marker_contribution.address, loaded);
}

test "ELF linker emits static TLS sections and local-exec relocations" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0x64, 0x8b, 0x04, 0x25,
        0,    0,    0,    0,
        0x64, 0x8b, 0x14, 0x25,
        0,    0,    0,    0,
        0xc3,
    };
    const tdata = [_]u8{ 7, 0, 0, 0 };
    const text_index: u16 = 1;
    const tdata_index: u16 = 2;
    const tbss_index: u16 = 3;
    const x_symbol: u32 = 5;
    const y_symbol: u32 = 6;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".tdata", &tdata, std.elf.SHF_WRITE | std.elf.SHF_TLS, 4),
            Section.nobits(".tbss", 4, std.elf.SHF_WRITE | std.elf.SHF_TLS, 4),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(tdata_index),
            Symbol.section(tbss_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.tlsObject("x", tdata_index, 0, 4),
            Symbol.tlsObject("y", tbss_index, 0, 4),
        },
        .relocations = &.{
            Relocation.x86_64(text_index, 4, x_symbol, .TPOFF32, 0),
            Relocation.x86_64(text_index, 12, y_symbol, .TPOFF32, 0),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "tls.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const text_offset: usize = @intCast(text_record.file_offset);
    try std.testing.expectEqual(@as(i32, -8), @as(i32, @bitCast(readU32(linked.bytes, text_offset + 4))));
    try std.testing.expectEqual(@as(i32, -4), @as(i32, @bitCast(readU32(linked.bytes, text_offset + 12))));

    const tdata_header = try metadata.linkedSectionByName(linked.bytes, ".tdata");
    const tbss_header = try metadata.linkedSectionByName(linked.bytes, ".tbss");
    try std.testing.expect((tdata_header.flags & std.elf.SHF_TLS) != 0);
    try std.testing.expect((tbss_header.flags & std.elf.SHF_TLS) != 0);

    var saw_tls_header = false;
    const phnum = readU16(linked.bytes, 56);
    for (0..phnum) |index| {
        const offset = ehdr_size + index * phdr_size;
        if (readU32(linked.bytes, offset) != @backingInt(std.elf.PT.TLS)) continue;
        saw_tls_header = true;
        try std.testing.expectEqual(@as(u64, 4), readU64(linked.bytes, offset + 32));
        try std.testing.expectEqual(@as(u64, 8), readU64(linked.bytes, offset + 40));
    }
    try std.testing.expect(saw_tls_header);
}

test "ELF linker relaxes x86-64 initial-exec TLS for static executable" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0x48, 0x8b, 0x05,
        0,    0,    0,
        0,    0x4c, 0x8b,
        0x05, 0,    0,
        0,    0,    0xc3,
    };
    const tdata = [_]u8{ 7, 0, 0, 0 };
    const text_index: u16 = 1;
    const tdata_index: u16 = 2;
    const x_symbol: u32 = 5;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".tdata", &tdata, std.elf.SHF_WRITE | std.elf.SHF_TLS, 4),
            Section.nobits(".tbss", 4, std.elf.SHF_WRITE | std.elf.SHF_TLS, 4),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(tdata_index),
            Symbol.section(3),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.tlsObject("x", tdata_index, 0, 4),
        },
        .relocations = &.{
            Relocation.x86_64(text_index, 3, x_symbol, .GOTTPOFF, -4),
            Relocation.x86_64(text_index, 10, x_symbol, .GOTTPOFF, -4),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "tls-initial-exec.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const text_offset: usize = @intCast(text_record.file_offset);
    const rax_expected = [_]u8{ 0x48, 0xc7, 0xc0, 0xf8, 0xff, 0xff, 0xff };
    const r8_expected = [_]u8{ 0x49, 0xc7, 0xc0, 0xf8, 0xff, 0xff, 0xff };
    try std.testing.expectEqualSlices(u8, &rax_expected, linked.bytes[text_offset..][0..rax_expected.len]);
    try std.testing.expectEqualSlices(u8, &r8_expected, linked.bytes[text_offset + 7 ..][0..r8_expected.len]);
    try std.testing.expect(metadata.manifestSection(linked.manifest, ".got") == null);
}

test "ELF linker relaxes x86-64 TLS dynamic models for static executable" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0x66, 0x48, 0x8d, 0x3d, 0x00, 0x00, 0x00, 0x00,
        0x66, 0x66, 0x48, 0xe8, 0x00, 0x00, 0x00, 0x00,
        0x48, 0x8d, 0x3d, 0x00, 0x00, 0x00, 0x00, 0xe8,
        0x00, 0x00, 0x00, 0x00, 0x8b, 0x80, 0x00, 0x00,
        0x00, 0x00, 0xc3,
    };
    const tdata = [_]u8{ 7, 0, 0, 0 };
    const text_index: u16 = 1;
    const tdata_index: u16 = 2;
    const x_symbol: u32 = 4;
    const tls_get_addr: u32 = 5;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".tdata", &tdata, std.elf.SHF_WRITE | std.elf.SHF_TLS, 4),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(tdata_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.tlsObject("x", tdata_index, 0, 4),
            Symbol.undefinedFunction("__tls_get_addr"),
        },
        .relocations = &.{
            Relocation.x86_64(text_index, 4, x_symbol, .TLSGD, -4),
            Relocation.x86_64(text_index, 12, tls_get_addr, .PLT32, -4),
            Relocation.x86_64(text_index, 19, x_symbol, .TLSLD, -4),
            Relocation.x86_64(text_index, 24, tls_get_addr, .PLT32, -4),
            Relocation.x86_64(text_index, 30, x_symbol, .DTPOFF32, 0),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "tls-dynamic.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const text_offset: usize = @intCast(text_record.file_offset);
    const gd_expected = [_]u8{
        0x64, 0x48, 0x8b, 0x04, 0x25, 0x00, 0x00, 0x00,
        0x00, 0x48, 0x8d, 0x80, 0xfc, 0xff, 0xff, 0xff,
    };
    const ld_expected = [_]u8{
        0x66, 0x66, 0x66, 0x64, 0x48, 0x8b, 0x04, 0x25,
        0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectEqualSlices(u8, &gd_expected, linked.bytes[text_offset..][0..gd_expected.len]);
    try std.testing.expectEqualSlices(u8, &ld_expected, linked.bytes[text_offset + 16 ..][0..ld_expected.len]);
    try std.testing.expectEqual(@as(i32, -4), @as(i32, @bitCast(readU32(linked.bytes, text_offset + 30))));
}

test "ELF incremental manifest distinguishes TLS file payloads from TBSS memory" {
    const allocator = std.testing.allocator;
    const text = [_]u8{0xc3};
    const tdata = [_]u8{ 7, 0, 0, 0 };
    const text_index: u16 = 1;
    const tdata_index: u16 = 2;
    const tbss_index: u16 = 3;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".tdata", &tdata, std.elf.SHF_WRITE | std.elf.SHF_TLS, 4),
            Section.nobits(".tbss", 4, std.elf.SHF_WRITE | std.elf.SHF_TLS, 4),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(tdata_index),
            Symbol.section(tbss_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.tlsObject("x", tdata_index, 0, 4),
            Symbol.tlsObject("y", tbss_index, 0, 4),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "tls.o", .bytes = object }}, .{});
    defer linked.deinit(allocator);

    const tdata_contribution = metadata.manifestContribution(linked.manifest, "tls.o", .section, ".tdata", tdata_index) orelse return error.MissingSection;
    const tbss_contribution = metadata.manifestContribution(linked.manifest, "tls.o", .section, ".tbss", tbss_index) orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, tdata.len), tdata_contribution.file_size);
    try std.testing.expectEqual(@as(u64, 0), tbss_contribution.file_size);

    const tdata_plan = linked.manifest.planContributionReplacement(&.{
        .{ .input_name = "tls.o", .input_index = 0, .kind = .section, .name = ".tdata", .ordinal = tdata_index, .size = tdata.len, .alignment = 4 },
    });
    try std.testing.expectEqual(incremental.PatchDecision.in_place, tdata_plan.decision);

    const tbss_plan = linked.manifest.planContributionReplacement(&.{
        .{ .input_name = "tls.o", .input_index = 0, .kind = .section, .name = ".tbss", .ordinal = tbss_index, .size = 4, .alignment = 4 },
    });
    try std.testing.expectEqual(incremental.PatchDecision.in_place, tbss_plan.decision);
}

test "ELF linker allocates common symbols in bss" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const text_index: u16 = 1;
    const scratch_symbol: u32 = 3;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.commonObject("scratch", 16, 24),
        },
        .relocations = &.{Relocation.x86_64(1, 2, scratch_symbol, .@"64", 0)},
    });
    defer allocator.free(object);

    const inputs = [_]model.Input{.{ .name = "common.o", .bytes = object }};
    var linked = try linkExecutable(allocator, &inputs, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);
    var manifest_linked = try linkExecutable(allocator, &inputs, .{});
    defer manifest_linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const bss_record = metadata.manifestSection(linked.manifest, ".bss") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, 24), bss_record.size);
    try std.testing.expectEqual(@as(u64, 32), bss_record.reserved_size);
    try std.testing.expectEqual(@as(u64, 16), bss_record.alignment);
    try std.testing.expectEqual(@as(u64, 0), bss_record.address % 16);
    try std.testing.expectEqual(bss_record.address, std.mem.readInt(u64, linked.bytes[@as(usize, @intCast(text_record.file_offset)) + 2 ..][0..8], .little));

    const manifest_bss_record = metadata.manifestSection(manifest_linked.manifest, ".bss") orelse return error.MissingSection;
    const common_contribution = metadata.manifestContribution(manifest_linked.manifest, "common.o", .common_symbol, "scratch", scratch_symbol) orelse return error.MissingSection;
    try std.testing.expectEqualStrings(".bss", manifest_linked.manifest.string(common_contribution.output_section_name_id));
    try std.testing.expectEqual(manifest_bss_record.address, common_contribution.address);
    try std.testing.expectEqual(@as(u64, 24), common_contribution.size);
    try std.testing.expectEqual(@as(u64, 0), common_contribution.file_size);
    try std.testing.expect(common_contribution.reserved_size > common_contribution.size);
    try std.testing.expectEqual(@as(u64, 16), common_contribution.alignment);

    const common_plan = manifest_linked.manifest.planContributionReplacement(&.{
        .{ .input_name = "common.o", .input_index = 0, .kind = .common_symbol, .name = "scratch", .ordinal = scratch_symbol, .size = 24, .alignment = 16 },
    });
    try std.testing.expectEqual(incremental.PatchDecision.in_place, common_plan.decision);

    const bss_header = try metadata.linkedSectionByName(linked.bytes, ".bss");
    try std.testing.expectEqual(std.elf.SHT_NOBITS, bss_header.section_type);

    const bss_load = try metadata.loadProgramHeaderByAddress(linked.bytes, bss_record.address);
    try std.testing.expectEqual(@as(u64, 0), bss_load.file_size);
    try std.testing.expectEqual(bss_record.reserved_size, bss_load.memory_size);
}

test "ELF linker coalesces common symbols by size" {
    const allocator = std.testing.allocator;
    const text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const text_index: u16 = 1;
    const caller_scratch: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.commonObject("scratch", 8, 8),
        },
        .relocations = &.{Relocation.x86_64(1, 2, caller_scratch, .@"64", 0)},
    });
    defer allocator.free(caller_object);

    const storage_object = try buildObject(allocator, .{
        .sections = &.{},
        .symbols = &.{Symbol.commonObject("scratch", 16, 32)},
    });
    defer allocator.free(storage_object);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "storage.o", .bytes = storage_object },
    }, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const bss_record = metadata.manifestSection(linked.manifest, ".bss") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, 32), bss_record.size);
    try std.testing.expectEqual(@as(u64, 16), bss_record.alignment);
    try std.testing.expectEqual(bss_record.address, std.mem.readInt(u64, linked.bytes[@as(usize, @intCast(text_record.file_offset)) + 2 ..][0..8], .little));
}

test "ELF linker lets strong definitions override common symbols" {
    const allocator = std.testing.allocator;

    const text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const text_index: u16 = 1;
    const slot_ref: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.undefinedObject("shared_slot"),
        },
        .relocations = &.{Relocation.x86_64(1, 2, slot_ref, .@"64", 0)},
    });
    defer allocator.free(caller_object);

    const common_symbol: u32 = 1;
    const common_object = try buildObject(allocator, .{
        .sections = &.{},
        .symbols = &.{Symbol.commonObject("shared_slot", 32, 128)},
    });
    defer allocator.free(common_object);

    const data = [_]u8{ 1, 2, 3, 4 };
    const data_index: u16 = 1;
    const strong_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".data.shared", &data, std.elf.SHF_WRITE, 4)},
        .symbols = &.{ Symbol.section(data_index), Symbol.object("shared_slot", data_index, 0, data.len) },
    });
    defer allocator.free(strong_object);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "common.o", .bytes = common_object },
        .{ .name = "strong.o", .bytes = strong_object },
    }, .{});
    defer linked.deinit(allocator);

    const caller_contribution = metadata.manifestContribution(linked.manifest, "caller.o", .section, ".text", text_index) orelse return error.MissingSection;
    const strong_contribution = metadata.manifestContribution(linked.manifest, "strong.o", .section, ".data.shared", data_index) orelse return error.MissingSection;
    try std.testing.expect(metadata.manifestContribution(linked.manifest, "common.o", .common_symbol, "shared_slot", common_symbol) == null);
    try std.testing.expect(metadata.manifestSection(linked.manifest, ".bss") == null);

    const loaded = std.mem.readInt(u64, linked.bytes[@as(usize, @intCast(caller_contribution.file_offset)) + 2 ..][0..8], .little);
    try std.testing.expectEqual(strong_contribution.address, loaded);
}

test "ELF linker lazily extracts archive members and rescans the same archive" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const caller_text_index: u16 = 1;
    const callee_symbol: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedFunction("callee"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, callee_symbol, .PLT32, -4)},
    });
    defer allocator.free(caller_object);

    const unused_text = [_]u8{0xc3};
    const unused_text_index: u16 = 1;
    const unused_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &unused_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(unused_text_index),
            Symbol.function("_start", unused_text_index, 0, unused_text.len),
        },
    });
    defer allocator.free(unused_object);

    const helper_text = [_]u8{0xc3};
    const helper_text_index: u16 = 1;
    const helper_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &helper_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(helper_text_index),
            Symbol.function("helper", helper_text_index, 0, helper_text.len),
        },
    });
    defer allocator.free(helper_object);

    const callee_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const callee_text_index: u16 = 1;
    const helper_symbol: u32 = 3;
    const callee_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &callee_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(callee_text_index),
            Symbol.function("callee", callee_text_index, 0, callee_text.len),
            Symbol.undefinedFunction("helper"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, helper_symbol, .PLT32, -4)},
    });
    defer allocator.free(callee_object);

    const archive_bytes = try archive.build(allocator, &.{
        .{ .name = "unused.o", .bytes = unused_object },
        .{ .name = "helper.o", .bytes = helper_object },
        .{ .name = "callee.o", .bytes = callee_object },
    });
    defer allocator.free(archive_bytes);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "libcall.a", .bytes = archive_bytes },
    }, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), linked.manifest.inputs.len);
    try std.testing.expectEqualStrings("libcall.a", linked.manifest.string(linked.manifest.inputs[1].name_id));
    try std.testing.expectEqual(@as(u64, archive_bytes.len), linked.manifest.inputs[1].size);

    const text = linked.manifest.sections[0];
    try std.testing.expectEqual(@as(u64, 33), text.size);
    const text_file_offset: usize = @intCast(text.file_offset);
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[text_file_offset + 1 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[text_file_offset + 17 ..][0..4], .little));
}

test "ELF linker extracts archive members that define GNU unique symbols" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const caller_text_index: u16 = 1;
    const slot_ref: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedObject("unique_slot"),
        },
        .relocations = &.{Relocation.x86_64(1, 2, slot_ref, .@"64", 0)},
    });
    defer allocator.free(caller_object);

    const data = [_]u8{ 9, 8, 7, 6 };
    const data_index: u16 = 1;
    const unique_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".data.unique", &data, std.elf.SHF_WRITE, 4)},
        .symbols = &.{ Symbol.section(data_index), Symbol.gnuUniqueObject("unique_slot", data_index, 0, data.len) },
    });
    defer allocator.free(unique_object);

    const archive_bytes = try archive.build(allocator, &.{
        .{ .name = "unique.o", .bytes = unique_object, .symbols = &.{"unique_slot"} },
    });
    defer allocator.free(archive_bytes);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "libunique.a", .bytes = archive_bytes },
    }, .{});
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const unique_contribution = metadata.manifestContribution(linked.manifest, "unique.o", .section, ".data.unique", data_index) orelse return error.MissingSection;
    const loaded = std.mem.readInt(u64, linked.bytes[@as(usize, @intCast(text_record.file_offset)) + 2 ..][0..8], .little);
    try std.testing.expectEqual(unique_contribution.address, loaded);
}

test "ELF linker coalesces duplicate GNU unique definitions" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const caller_text_index: u16 = 1;
    const slot_ref: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedObject("unique_slot"),
        },
        .relocations = &.{Relocation.x86_64(1, 2, slot_ref, .@"64", 0)},
    });
    defer allocator.free(caller_object);

    const first_data = [_]u8{ 1, 0, 0, 0 };
    const first_data_index: u16 = 1;
    const first_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".data.first_unique", &first_data, std.elf.SHF_WRITE, 4)},
        .symbols = &.{
            Symbol.section(first_data_index),
            Symbol.gnuUniqueObject("unique_slot", first_data_index, 0, first_data.len),
        },
    });
    defer allocator.free(first_object);

    const second_data = [_]u8{ 2, 0, 0, 0 };
    const second_data_index: u16 = 1;
    const second_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".data.second_unique", &second_data, std.elf.SHF_WRITE, 4)},
        .symbols = &.{
            Symbol.section(second_data_index),
            Symbol.gnuUniqueObject("unique_slot", second_data_index, 0, second_data.len),
        },
    });
    defer allocator.free(second_object);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "first.o", .bytes = first_object },
        .{ .name = "second.o", .bytes = second_object },
    }, .{});
    defer linked.deinit(allocator);

    const text_record = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const first_contribution = metadata.manifestContribution(linked.manifest, "first.o", .section, ".data.first_unique", first_data_index) orelse return error.MissingSection;
    _ = metadata.manifestContribution(linked.manifest, "second.o", .section, ".data.second_unique", second_data_index) orelse return error.MissingSection;
    const loaded = std.mem.readInt(u64, linked.bytes[@as(usize, @intCast(text_record.file_offset)) + 2 ..][0..8], .little);
    try std.testing.expectEqual(first_contribution.address, loaded);
}

test "ELF linker skips stale archive candidates after a symbol is resolved" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const caller_text_index: u16 = 1;
    const callee_symbol: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedFunction("callee"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, callee_symbol, .PLT32, -4)},
    });
    defer allocator.free(caller_object);

    const first_text = [_]u8{0xc3};
    const first_text_index: u16 = 1;
    const first_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &first_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(first_text_index),
            Symbol.function("callee", first_text_index, 0, first_text.len),
        },
    });
    defer allocator.free(first_object);

    const duplicate_text = [_]u8{ 0x90, 0x90, 0xc3 };
    const duplicate_text_index: u16 = 1;
    const duplicate_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &duplicate_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(duplicate_text_index),
            Symbol.function("callee", duplicate_text_index, 0, duplicate_text.len),
        },
    });
    defer allocator.free(duplicate_object);

    const archive_bytes = try archive.build(allocator, &.{
        .{ .name = "first.o", .bytes = first_object },
        .{ .name = "duplicate.o", .bytes = duplicate_object },
    });
    defer allocator.free(archive_bytes);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "libcallee.a", .bytes = archive_bytes },
    }, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const expected_size = alignForward(caller_text.len, 16) + first_text.len;
    try std.testing.expectEqual(@as(u64, expected_size), text.size);
}

test "ELF linker uses archive symbol indexes without parsing unreferenced members" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const caller_text_index: u16 = 1;
    const needed_symbol: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedFunction("needed"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, needed_symbol, .PLT32, -4)},
    });
    defer allocator.free(caller_object);

    const needed_text = [_]u8{0xc3};
    const needed_text_index: u16 = 1;
    const needed_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &needed_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(needed_text_index),
            Symbol.function("needed", needed_text_index, 0, needed_text.len),
        },
    });
    defer allocator.free(needed_object);

    const unused_coff = coffHeaderBytes();
    const archive_bytes = try archive.build(allocator, &.{
        .{ .name = "unused.obj", .bytes = &unused_coff, .symbols = &.{"unused"} },
        .{ .name = "needed.o", .bytes = needed_object, .symbols = &.{"needed"} },
    });
    defer allocator.free(archive_bytes);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "libneeded.a", .bytes = archive_bytes },
    }, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const expected_size = alignForward(caller_text.len, 16) + needed_text.len;
    try std.testing.expectEqual(@as(u64, expected_size), text.size);
}

test "ELF linker diagnoses extracted archive members with mismatched formats" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const caller_text_index: u16 = 1;
    const needed_symbol: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedFunction("needed"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, needed_symbol, .PLT32, -4)},
    });
    defer allocator.free(caller_object);

    const needed_coff = coffHeaderBytes();
    const archive_bytes = try archive.build(allocator, &.{
        .{ .name = "needed.obj", .bytes = &needed_coff, .symbols = &.{"needed"} },
    });
    defer allocator.free(archive_bytes);

    var diagnostics: model.Diagnostics = .{};
    try std.testing.expectError(
        error.UnsupportedFormat,
        linkExecutable(allocator, &.{
            .{ .name = "caller.o", .bytes = caller_object },
            .{ .name = "libmixed.a", .bytes = archive_bytes },
        }, .{ .diagnostics = &diagnostics, .incremental_mode = .off }),
    );

    const unsupported = diagnostics.first_unsupported_input_format orelse return error.ExpectedUnsupportedInputFormatDiagnostic;
    try std.testing.expectEqual(model.ObjectFormat.coff, unsupported.input_format);
    try std.testing.expectEqual(model.ObjectFormat.elf, unsupported.target_format);
    try std.testing.expectEqualStrings("libmixed.a", unsupported.input_name);
    try std.testing.expectEqualStrings("needed.obj", unsupported.member_name orelse return error.ExpectedUnsupportedInputFormatDiagnostic);

    const failure = diagnostics.linkFailure(error.UnsupportedFormat);
    const reported = switch (failure) {
        .unsupported_input_format => |reported| reported,
        else => return error.ExpectedUnsupportedInputFormatDiagnostic,
    };
    try std.testing.expectEqual(model.ObjectFormat.coff, reported.input_format);
    try std.testing.expectEqual(model.ObjectFormat.elf, reported.target_format);
    try std.testing.expectEqualStrings("libmixed.a", reported.input_name);
    try std.testing.expectEqualStrings("needed.obj", reported.member_name orelse return error.ExpectedUnsupportedInputFormatDiagnostic);
}

test "ELF linker extracts indexed archive fanout members" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{
        0xe8, 0, 0, 0, 0,
        0xe8, 0, 0, 0, 0,
        0xc3,
    };
    const caller_text_index: u16 = 1;
    const first_symbol: u32 = 3;
    const second_symbol: u32 = 4;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedFunction("first"),
            Symbol.undefinedFunction("second"),
        },
        .relocations = &.{
            Relocation.x86_64(1, 1, first_symbol, .PLT32, -4),
            Relocation.x86_64(1, 6, second_symbol, .PLT32, -4),
        },
    });
    defer allocator.free(caller_object);

    const function_text = [_]u8{0xc3};
    const first_text_index: u16 = 1;
    const first_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &function_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(first_text_index),
            Symbol.function("first", first_text_index, 0, function_text.len),
        },
    });
    defer allocator.free(first_object);

    const second_text_index: u16 = 1;
    const second_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &function_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(second_text_index),
            Symbol.function("second", second_text_index, 0, function_text.len),
        },
    });
    defer allocator.free(second_object);

    const malformed_elf = std.elf.MAGIC ++ "not enough header bytes";
    const archive_bytes = try archive.build(allocator, &.{
        .{ .name = "unused.o", .bytes = malformed_elf, .symbols = &.{"unused"} },
        .{ .name = "first.o", .bytes = first_object, .symbols = &.{"first"} },
        .{ .name = "second.o", .bytes = second_object, .symbols = &.{"second"} },
    });
    defer allocator.free(archive_bytes);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "libfanout.a", .bytes = archive_bytes },
    }, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(u64, 33), text.size);
    const text_file_offset: usize = @intCast(text.file_offset);
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[text_file_offset + 1 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 22), std.mem.readInt(i32, linked.bytes[text_file_offset + 6 ..][0..4], .little));
}

test "ELF linker preserves wide indexed archive fanout members" {
    const allocator = std.testing.allocator;
    const function_names = [_][]const u8{
        "fanout_0",
        "fanout_1",
        "fanout_2",
        "fanout_3",
        "fanout_4",
        "fanout_5",
        "fanout_6",
        "fanout_7",
    };
    const member_names = [_][]const u8{
        "fanout_0.o",
        "fanout_1.o",
        "fanout_2.o",
        "fanout_3.o",
        "fanout_4.o",
        "fanout_5.o",
        "fanout_6.o",
        "fanout_7.o",
    };
    const function_count = function_names.len;

    var caller_text: [function_count * 5 + 1]u8 = undefined;
    for (0..function_count) |index| {
        const call_offset = index * 5;
        caller_text[call_offset..][0..5].* = .{ 0xe8, 0, 0, 0, 0 };
    }
    caller_text[function_count * 5] = 0xc3;
    const caller_text_index: u16 = 1;
    var caller_symbols: [function_count + 2]Symbol = undefined;
    caller_symbols[0] = Symbol.section(caller_text_index);
    caller_symbols[1] = Symbol.function("_start", caller_text_index, 0, caller_text.len);
    var caller_relocations: [function_count]Relocation = undefined;
    for (function_names, 0..) |name, index| {
        const symbol: u32 = @intCast(index + 3);
        caller_symbols[index + 2] = Symbol.undefinedFunction(name);
        const offset = index * 5 + 1;
        caller_relocations[index] = Relocation.x86_64(caller_text_index, offset, symbol, .PLT32, -4);
    }
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &caller_symbols,
        .relocations = &caller_relocations,
    });
    defer allocator.free(caller_object);

    var member_bytes: [function_count][]u8 = undefined;
    var member_symbol_storage: [function_count][1][]const u8 = undefined;
    var members: [function_count]archive.BuildMember = undefined;
    const function_text = [_]u8{0xc3};
    for (function_names, 0..) |name, index| {
        const text_index: u16 = 1;
        member_bytes[index] = try buildObject(allocator, .{
            .sections = &.{Section.progbits(".text", &function_text, std.elf.SHF_EXECINSTR, 16)},
            .symbols = &.{ Symbol.section(text_index), Symbol.function(name, text_index, 0, function_text.len) },
        });
        member_symbol_storage[index][0] = name;
        members[index] = .{
            .name = member_names[index],
            .bytes = member_bytes[index],
            .symbols = member_symbol_storage[index][0..],
        };
    }
    defer for (member_bytes) |bytes| allocator.free(bytes);

    const archive_bytes = try archive.build(allocator, &members);
    defer allocator.free(archive_bytes);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "libfanout.a", .bytes = archive_bytes },
    }, .{ .incremental_mode = .off, .max_link_jobs = 2 });
    defer linked.deinit(allocator);

    const text = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const expected_size = alignForward(caller_text.len, 16) + (function_count - 1) * 16 + function_text.len;
    try std.testing.expectEqual(@as(u64, expected_size), text.size);
}

test "ELF linker resolves archive members referenced by later objects" {
    const allocator = std.testing.allocator;

    const callee_text = [_]u8{0xc3};
    const callee_text_index: u16 = 1;
    const callee_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &callee_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(callee_text_index),
            Symbol.function("callee", callee_text_index, 0, callee_text.len),
        },
    });
    defer allocator.free(callee_object);

    const archive_bytes = try archive.build(allocator, &.{.{ .name = "callee.o", .bytes = callee_object }});
    defer allocator.free(archive_bytes);

    const caller_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const caller_text_index: u16 = 1;
    const callee_symbol: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedFunction("callee"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, callee_symbol, .PLT32, -4)},
    });
    defer allocator.free(caller_object);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "libcallee.a", .bytes = archive_bytes },
        .{ .name = "caller.o", .bytes = caller_object },
    }, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const text_file_offset: usize = @intCast(text.file_offset);
    try std.testing.expectEqual(@as(u64, 17), text.size);
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[text_file_offset + 1 ..][0..4], .little));
}

test "ELF linker carries archive unresolved symbols across later archives" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const caller_text_index: u16 = 1;
    const first_symbol: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedFunction("first"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, first_symbol, .PLT32, -4)},
    });
    defer allocator.free(caller_object);

    const first_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const first_text_index: u16 = 1;
    const second_symbol: u32 = 3;
    const first_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &first_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(first_text_index),
            Symbol.function("first", first_text_index, 0, first_text.len),
            Symbol.undefinedFunction("second"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, second_symbol, .PLT32, -4)},
    });
    defer allocator.free(first_object);

    const second_text = [_]u8{0xc3};
    const second_text_index: u16 = 1;
    const second_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &second_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(second_text_index),
            Symbol.function("second", second_text_index, 0, second_text.len),
        },
    });
    defer allocator.free(second_object);

    const first_archive = try archive.build(allocator, &.{.{ .name = "first.o", .bytes = first_object, .symbols = &.{"first"} }});
    defer allocator.free(first_archive);
    const second_archive = try archive.build(allocator, &.{.{ .name = "second.o", .bytes = second_object, .symbols = &.{"second"} }});
    defer allocator.free(second_archive);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "libfirst.a", .bytes = first_archive },
        .{ .name = "libsecond.a", .bytes = second_archive },
    }, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const text = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const text_file_offset: usize = @intCast(text.file_offset);
    try std.testing.expectEqual(@as(u64, 33), text.size);
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[text_file_offset + 1 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[text_file_offset + 17 ..][0..4], .little));
}

test "ELF linker rejects malformed archives" {
    try std.testing.expectError(
        error.InvalidArchive,
        linkExecutable(std.testing.allocator, &.{.{ .name = "bad.a", .bytes = archive.magic ++ "short" }}, .{}),
    );
}

test "ELF linker rejects unresolved globals" {
    const allocator = std.testing.allocator;
    const text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const text_index: u16 = 1;
    const missing: u32 = 3;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.undefinedFunction("missing"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, missing, .PLT32, -4)},
    });
    defer allocator.free(object);

    try std.testing.expectError(error.UndefinedSymbol, linkExecutable(allocator, &.{.{ .name = "bad.o", .bytes = object }}, .{}));
}

test "ELF linker permits unresolved weak symbols" {
    const allocator = std.testing.allocator;
    const text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const text_index: u16 = 1;
    const weak_missing: u32 = 3;
    const object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.weakUndefinedFunction("weak_missing"),
        },
        .relocations = &.{Relocation.x86_64(1, 1, weak_missing, .PLT32, -4)},
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "weak.o", .bytes = object }}, .{});
    defer linked.deinit(allocator);
    try std.testing.expect(linked.bytes.len != 0);
}

test "ELF linker lets strong definitions override weak definitions" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const caller_text_index: u16 = 1;
    const hook_ref: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedFunction("weak_hook"),
        },
        .relocations = &.{Relocation.x86_64(1, 2, hook_ref, .@"64", 0)},
    });
    defer allocator.free(caller_object);

    const weak_text = [_]u8{0xc3};
    const weak_index: u16 = 1;
    const weak_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text.weak", &weak_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{ Symbol.section(weak_index), Symbol.weakFunction("weak_hook", weak_index, 0, weak_text.len) },
    });
    defer allocator.free(weak_object);

    const strong_text = [_]u8{ 0x90, 0xc3 };
    const strong_index: u16 = 1;
    const strong_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text.strong", &strong_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(strong_index),
            Symbol.function("weak_hook", strong_index, 0, strong_text.len),
        },
    });
    defer allocator.free(strong_object);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "weak.o", .bytes = weak_object },
        .{ .name = "strong.o", .bytes = strong_object },
    }, .{});
    defer linked.deinit(allocator);

    const caller_contribution = metadata.manifestContribution(linked.manifest, "caller.o", .section, ".text", caller_text_index) orelse return error.MissingSection;
    const strong_contribution = metadata.manifestContribution(linked.manifest, "strong.o", .section, ".text.strong", strong_index) orelse return error.MissingSection;
    try std.testing.expect(metadata.manifestContribution(linked.manifest, "weak.o", .section, ".text.weak", weak_index) != null);

    const loaded = std.mem.readInt(u64, linked.bytes[@as(usize, @intCast(caller_contribution.file_offset)) + 2 ..][0..8], .little);
    try std.testing.expectEqual(strong_contribution.address, loaded);
}

test "ELF linker selects first weak definition when no strong definition exists" {
    const allocator = std.testing.allocator;

    const caller_text = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xc3,
    };
    const caller_text_index: u16 = 1;
    const hook_ref: u32 = 3;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_text_index),
            Symbol.function("_start", caller_text_index, 0, caller_text.len),
            Symbol.undefinedFunction("weak_only_hook"),
        },
        .relocations = &.{Relocation.x86_64(1, 2, hook_ref, .@"64", 0)},
    });
    defer allocator.free(caller_object);

    const first_text = [_]u8{0xc3};
    const first_index: u16 = 1;
    const first_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text.first_weak", &first_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(first_index),
            Symbol.weakFunction("weak_only_hook", first_index, 0, first_text.len),
        },
    });
    defer allocator.free(first_object);

    const second_text = [_]u8{ 0x90, 0xc3 };
    const second_index: u16 = 1;
    const second_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text.second_weak", &second_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(second_index),
            Symbol.weakFunction("weak_only_hook", second_index, 0, second_text.len),
        },
    });
    defer allocator.free(second_object);

    var linked = try linkExecutable(allocator, &.{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "first.o", .bytes = first_object },
        .{ .name = "second.o", .bytes = second_object },
    }, .{});
    defer linked.deinit(allocator);

    const caller_contribution = metadata.manifestContribution(linked.manifest, "caller.o", .section, ".text", caller_text_index) orelse return error.MissingSection;
    const first_contribution = metadata.manifestContribution(linked.manifest, "first.o", .section, ".text.first_weak", first_index) orelse return error.MissingSection;
    try std.testing.expect(metadata.manifestContribution(linked.manifest, "second.o", .section, ".text.second_weak", second_index) != null);

    const loaded = std.mem.readInt(u64, linked.bytes[@as(usize, @intCast(caller_contribution.file_offset)) + 2 ..][0..8], .little);
    try std.testing.expectEqual(first_contribution.address, loaded);
}

test "ELF linker parallel unresolved relocation scan matches serial output" {
    const allocator = std.testing.allocator;
    const relocation_count = format.parallel_relocation_threshold + 1024;

    const text = [_]u8{0xc3};
    const text_index: u16 = 1;
    const data = try allocator.alloc(u8, relocation_count * 8);
    defer allocator.free(data);
    @memset(data, 0);
    const data_index: u16 = 2;
    const target_ref: u32 = 4;
    const relocations = try allocator.alloc(Relocation, relocation_count);
    defer allocator.free(relocations);
    for (relocations, 0..) |*relocation, index| {
        relocation.* = Relocation.x86_64(data_index, index * 8, target_ref, .@"64", 0);
    }
    const caller_object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".data.refs", data, std.elf.SHF_WRITE, 8),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(data_index),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.undefinedObject("target_value"),
        },
        .relocations = relocations,
    });
    defer allocator.free(caller_object);

    const target_data = [_]u8{ 1, 2, 3, 4 };
    const target_index: u16 = 1;
    const target_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".rodata.target", &target_data, 0, 4)},
        .symbols = &.{
            Symbol.section(target_index),
            Symbol.object("target_value", target_index, 0, target_data.len),
        },
    });
    defer allocator.free(target_object);

    const inputs = [_]model.Input{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "target.o", .bytes = target_object },
    };

    var serial = try linkExecutable(allocator, &inputs, .{ .incremental_mode = .off, .max_link_jobs = 1 });
    defer serial.deinit(allocator);
    var concurrent = try linkExecutable(allocator, &inputs, .{ .incremental_mode = .off, .max_link_jobs = 8 });
    defer concurrent.deinit(allocator);

    try std.testing.expectEqualSlices(u8, serial.bytes, concurrent.bytes);
}

test "ELF linker parallel global symbols and executable entries match serial output" {
    const allocator = std.testing.allocator;
    const object_count = 128;
    const definitions_per_object = symbol_table.parallel_global_symbol_threshold / object_count + 8;

    const inputs = try allocator.alloc(model.Input, object_count);
    defer allocator.free(inputs);
    var built_count: usize = 0;
    defer {
        for (inputs[0..built_count]) |input| allocator.free(input.bytes);
    }

    for (inputs, 0..) |*input, object_index| {
        const text = [_]u8{0xc3};
        const section_name = try std.fmt.allocPrint(allocator, ".text.{d}", .{object_index});
        defer allocator.free(section_name);
        const text_index: u16 = 1;

        var names: [definitions_per_object][]u8 = undefined;
        var named: usize = 0;
        defer for (names[0..named]) |name| allocator.free(name);

        var symbols: [definitions_per_object + 2]Symbol = undefined;
        var symbol_count: usize = 0;
        symbols[symbol_count] = Symbol.section(text_index);
        symbol_count += 1;
        if (object_index == 0) {
            symbols[symbol_count] = Symbol.function("_start", text_index, 0, text.len);
            symbol_count += 1;
        }

        for (0..definitions_per_object) |symbol_index| {
            names[symbol_index] = try std.fmt.allocPrint(allocator, "global_{d}_{d}", .{ object_index, symbol_index });
            named += 1;
            symbols[symbol_count] = Symbol.object(names[symbol_index], text_index, 0, text.len);
            symbol_count += 1;
        }

        input.* = .{
            .name = "globals.o",
            .bytes = try buildObject(allocator, .{
                .sections = &.{Section.progbits(section_name, &text, std.elf.SHF_EXECINSTR, 16)},
                .symbols = symbols[0..symbol_count],
            }),
        };
        built_count += 1;
    }

    var serial = try linkExecutable(allocator, inputs, .{ .incremental_mode = .off, .max_link_jobs = 1 });
    defer serial.deinit(allocator);
    var concurrent = try linkExecutable(allocator, inputs, .{ .incremental_mode = .off, .max_link_jobs = 8 });
    defer concurrent.deinit(allocator);

    try std.testing.expectEqualSlices(u8, serial.bytes, concurrent.bytes);
}

test "ELF linker parallel output payload copy matches serial output" {
    const allocator = std.testing.allocator;
    const object_count = 64;
    const payload_size = payload.parallel_object_copy_threshold / object_count + 4096;

    const payload_bytes = try allocator.alloc(u8, payload_size);
    defer allocator.free(payload_bytes);
    for (payload_bytes, 0..) |*byte, index| byte.* = @truncate(index *% 251);

    const inputs = try allocator.alloc(model.Input, object_count);
    defer allocator.free(inputs);
    var built_count: usize = 0;
    defer {
        for (inputs[0..built_count]) |input| allocator.free(input.bytes);
    }

    for (inputs, 0..) |*input, object_index| {
        const text = [_]u8{0xc3};
        const section_name = try std.fmt.allocPrint(allocator, ".rodata.copy.{d}", .{object_index});
        defer allocator.free(section_name);
        const symbol_name = try std.fmt.allocPrint(allocator, "copy_payload_{d}", .{object_index});
        defer allocator.free(symbol_name);

        input.* = .{
            .name = "copy.o",
            .bytes = if (object_index == 0) try buildObject(allocator, .{
                .sections = &.{
                    Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
                    Section.progbits(section_name, payload_bytes, 0, 16),
                },
                .symbols = &.{
                    Symbol.section(1),
                    Symbol.section(2),
                    Symbol.function("_start", 1, 0, text.len),
                    Symbol.object(symbol_name, 2, 0, payload_bytes.len),
                },
            }) else try buildObject(allocator, .{
                .sections = &.{Section.progbits(section_name, payload_bytes, 0, 16)},
                .symbols = &.{ Symbol.section(1), Symbol.object(symbol_name, 1, 0, payload_bytes.len) },
            }),
        };
        built_count += 1;
    }

    var serial = try linkExecutable(allocator, inputs, .{ .incremental_mode = .off, .max_link_jobs = 1 });
    defer serial.deinit(allocator);
    var concurrent = try linkExecutable(allocator, inputs, .{ .incremental_mode = .off, .max_link_jobs = 8 });
    defer concurrent.deinit(allocator);

    try std.testing.expectEqualSlices(u8, serial.bytes, concurrent.bytes);
}

test "ELF linker keeps load segment pages disjoint with tls" {
    const allocator = std.testing.allocator;
    const text = [_]u8{0xc3};
    const tdata = [_]u8{ 7, 0, 0, 0, 0, 0, 0, 0 };
    const data = [_]u8{ 1, 2, 3, 4 };
    const text_index: u16 = 1;
    const tdata_index: u16 = 2;
    const object = try buildObject(allocator, .{
        .sections = &.{
            Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".tdata", &tdata, std.elf.SHF_WRITE | std.elf.SHF_TLS, 8),
            Section.nobits(".tbss", 64, std.elf.SHF_WRITE | std.elf.SHF_TLS, 8),
            Section.progbits(".data", &data, std.elf.SHF_WRITE, 4),
            Section.nobits(".bss", 128, std.elf.SHF_WRITE, 8),
        },
        .symbols = &.{
            Symbol.section(text_index),
            Symbol.section(tdata_index),
            Symbol.section(3),
            Symbol.section(4),
            Symbol.section(5),
            Symbol.function("_start", text_index, 0, text.len),
            Symbol.tlsObject("x", tdata_index, 0, 8),
        },
    });
    defer allocator.free(object);

    var linked = try linkExecutable(allocator, &.{.{ .name = "tls-pages.o", .bytes = object }}, .{ .incremental_mode = .off });
    defer linked.deinit(allocator);

    const page_size: u64 = 0x1000;
    const phnum = readU16(linked.bytes, 56);
    var previous_page_end: u64 = 0;
    var tls_vaddr: u64 = 0;
    var tls_offset: u64 = 0;
    var tls_filesz: u64 = 0;
    var load_count: usize = 0;
    for (0..phnum) |index| {
        const offset = ehdr_size + index * phdr_size;
        const header_type = readU32(linked.bytes, offset);
        if (header_type == @backingInt(std.elf.PT.TLS)) {
            tls_offset = readU64(linked.bytes, offset + 8);
            tls_vaddr = readU64(linked.bytes, offset + 16);
            tls_filesz = readU64(linked.bytes, offset + 32);
            continue;
        }
        if (header_type != @backingInt(std.elf.PT.LOAD)) continue;
        load_count += 1;
        const load_offset = readU64(linked.bytes, offset + 8);
        const load_vaddr = readU64(linked.bytes, offset + 16);
        const load_filesz = readU64(linked.bytes, offset + 32);
        const load_memsz = readU64(linked.bytes, offset + 40);
        try std.testing.expect(load_memsz >= load_filesz);
        const start_page = load_vaddr / page_size;
        try std.testing.expect(start_page >= previous_page_end);
        previous_page_end = (load_vaddr + load_memsz + page_size - 1) / page_size;
        _ = load_offset;
    }
    try std.testing.expect(load_count >= 3);
    try std.testing.expect(tls_filesz != 0);

    var template_backed = false;
    for (0..phnum) |index| {
        const offset = ehdr_size + index * phdr_size;
        if (readU32(linked.bytes, offset) != @backingInt(std.elf.PT.LOAD)) continue;
        const load_offset = readU64(linked.bytes, offset + 8);
        const load_vaddr = readU64(linked.bytes, offset + 16);
        const load_filesz = readU64(linked.bytes, offset + 32);
        if (tls_vaddr < load_vaddr or tls_vaddr + tls_filesz > load_vaddr + load_filesz) continue;
        if (tls_vaddr - tls_offset != load_vaddr - load_offset) continue;
        template_backed = true;
    }
    try std.testing.expect(template_backed);
}

test "ELF linker synthesizes iplt machinery for ifunc references" {
    const allocator = std.testing.allocator;

    const resolver_text = [_]u8{ 0x48, 0x8d, 0x05, 0, 0, 0, 0, 0xc3 };
    const resolver_index: u16 = 1;
    const provider_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text.resolver", &resolver_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(resolver_index),
            Symbol.ifunc("fast_copy", resolver_index, 0, resolver_text.len),
        },
    });
    defer allocator.free(provider_object);

    const caller_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0x48, 0x8d, 0x05, 0, 0, 0, 0, 0xc3 };
    const caller_index: u16 = 1;
    const copy_symbol: u32 = 3;
    const bounds_symbol: u32 = 4;
    const caller_object = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_index),
            Symbol.function("_start", caller_index, 0, caller_text.len),
            Symbol.undefinedFunction("fast_copy"),
            Symbol.undefinedObject("__rela_iplt_start"),
        },
        .relocations = &.{
            Relocation.x86_64(caller_index, 1, copy_symbol, .PLT32, -4),
            Relocation.x86_64(caller_index, 8, bounds_symbol, .PC32, -4),
        },
    });
    defer allocator.free(caller_object);

    const inputs = [_]model.Input{
        .{ .name = "caller.o", .bytes = caller_object },
        .{ .name = "provider.o", .bytes = provider_object },
    };
    var linked = try linkExecutable(allocator, &inputs, .{});
    defer linked.deinit(allocator);

    const iplt = metadata.manifestSection(linked.manifest, ".iplt") orelse return error.MissingSection;
    const igot = metadata.manifestSection(linked.manifest, ".igot") orelse return error.MissingSection;
    const rela = metadata.manifestSection(linked.manifest, ".rela.iplt") orelse return error.MissingSection;
    const resolver = metadata.manifestContribution(linked.manifest, "provider.o", .section, ".text.resolver", 1) orelse return error.MissingSection;

    try std.testing.expectEqual(@as(u64, 16), iplt.size);
    try std.testing.expectEqual(@as(u64, 8), igot.size);
    try std.testing.expectEqual(@as(u64, 24), rela.size);

    const stub_offset: usize = @intCast(iplt.file_offset);
    try std.testing.expectEqual(@as(u8, 0xff), linked.bytes[stub_offset]);
    try std.testing.expectEqual(@as(u8, 0x25), linked.bytes[stub_offset + 1]);
    const stub_disp = std.mem.readInt(i32, linked.bytes[stub_offset + 2 ..][0..4], .little);
    try std.testing.expectEqual(@as(i128, @intCast(igot.address)), @as(i128, @intCast(iplt.address + 6)) + stub_disp);

    const slot_offset: usize = @intCast(igot.file_offset);
    try std.testing.expectEqual(resolver.address, std.mem.readInt(u64, linked.bytes[slot_offset..][0..8], .little));

    const rela_offset: usize = @intCast(rela.file_offset);
    try std.testing.expectEqual(igot.address, std.mem.readInt(u64, linked.bytes[rela_offset..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 37), std.mem.readInt(u64, linked.bytes[rela_offset + 8 ..][0..8], .little));
    try std.testing.expectEqual(resolver.address, std.mem.readInt(u64, linked.bytes[rela_offset + 16 ..][0..8], .little));

    const text = metadata.manifestSection(linked.manifest, ".text") orelse return error.MissingSection;
    const text_offset: usize = @intCast(text.file_offset);
    const call_disp = std.mem.readInt(i32, linked.bytes[text_offset + 1 ..][0..4], .little);
    try std.testing.expectEqual(@as(i128, @intCast(iplt.address)), @as(i128, @intCast(text.address + 5)) + call_disp);
    const bounds_disp = std.mem.readInt(i32, linked.bytes[text_offset + 8 ..][0..4], .little);
    try std.testing.expectEqual(@as(i128, @intCast(rela.address)), @as(i128, @intCast(text.address + 12)) + bounds_disp);
}

test "ELF linker parallel ifunc marks match serial output" {
    const allocator = std.testing.allocator;
    const filler_count = 128;
    const symbols_per_filler = ifunc.parallel_mark_symbol_threshold / filler_count + 8;

    const inputs = try allocator.alloc(model.Input, filler_count + 2);
    defer allocator.free(inputs);
    var built_count: usize = 0;
    defer {
        for (inputs[0..built_count]) |input| allocator.free(input.bytes);
    }

    const caller_text = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const caller_index: u16 = 1;
    const copy_symbol: u32 = 3;
    inputs[built_count] = .{ .name = "caller.o", .bytes = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text", &caller_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(caller_index),
            Symbol.function("_start", caller_index, 0, caller_text.len),
            Symbol.undefinedFunction("fast_copy"),
        },
        .relocations = &.{Relocation.x86_64(caller_index, 1, copy_symbol, .PLT32, -4)},
    }) };
    built_count += 1;

    const resolver_text = [_]u8{ 0x48, 0x8d, 0x05, 0, 0, 0, 0, 0xc3 };
    const resolver_index: u16 = 1;
    inputs[built_count] = .{ .name = "provider.o", .bytes = try buildObject(allocator, .{
        .sections = &.{Section.progbits(".text.resolver", &resolver_text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            Symbol.section(resolver_index),
            Symbol.ifunc("fast_copy", resolver_index, 0, resolver_text.len),
        },
    }) };
    built_count += 1;

    for (0..filler_count) |object_index| {
        const text = [_]u8{0xc3};
        const text_index: u16 = 1;

        var names: [symbols_per_filler][]u8 = undefined;
        var named: usize = 0;
        defer for (names[0..named]) |name| allocator.free(name);

        var symbols: [symbols_per_filler + 1]Symbol = undefined;
        symbols[0] = Symbol.section(text_index);
        for (0..symbols_per_filler) |symbol_index| {
            const pattern = "ifunc_mark_fill_{d}_{d}";
            names[symbol_index] = try std.fmt.allocPrint(allocator, pattern, .{ object_index, symbol_index });
            named += 1;
            symbols[symbol_index + 1] = Symbol.function(names[symbol_index], text_index, 0, text.len);
        }

        inputs[built_count] = .{ .name = "fill.o", .bytes = try buildObject(allocator, .{
            .sections = &.{Section.progbits(".text.fill", &text, std.elf.SHF_EXECINSTR, 16)},
            .symbols = &symbols,
        }) };
        built_count += 1;
    }

    var serial = try linkExecutable(allocator, inputs, .{ .incremental_mode = .off, .max_link_jobs = 1 });
    defer serial.deinit(allocator);
    var concurrent = try linkExecutable(allocator, inputs, .{ .incremental_mode = .off, .max_link_jobs = 8 });
    defer concurrent.deinit(allocator);

    try std.testing.expectEqualSlices(u8, serial.bytes, concurrent.bytes);
}

test "elf namespace" {
    std.testing.refAllDecls(elf);
    std.testing.refAllDecls(link);
    std.testing.refAllDecls(metadata);
    std.testing.refAllDecls(address_suite);
    std.testing.refAllDecls(archive_suite);
    std.testing.refAllDecls(ehframe_suite);
    std.testing.refAllDecls(group_suite);
    std.testing.refAllDecls(icf_suite);
    std.testing.refAllDecls(image_suite);
    std.testing.refAllDecls(layout_suite);
    std.testing.refAllDecls(liveness_suite);
    std.testing.refAllDecls(merge_suite);
    std.testing.refAllDecls(relocation_suite);
}
