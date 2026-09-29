const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const record = @import("record.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const ObjectFile = elf.parser.ObjectFile;
const Symbol = elf.format.Symbol;
const SymbolRef = elf.layout.SymbolRef;
const ensureDiscardedSections = elf.section_state.ensureDiscardedSections;
const sectionName = elf.parser.sectionName;

pub fn duplicates(
    allocator: Allocator,
    objects: []ObjectFile,
) model.Error!void {
    var retained: std.StringHashMapUnmanaged(SymbolRef) = .{};
    defer retained.deinit(allocator);

    for (objects, 0..) |*object, object_index| {
        if (!object.has_group_sections) continue;
        for (object.sections) |section| {
            if (section.section_type != std.elf.SHT_GROUP) continue;
            if (section.info >= object.symbols.len) return error.InvalidObject;

            const group_bytes = try record.bytes(object.*, section);
            if (group_bytes.len == 0) return error.InvalidObject;
            if ((record.word(group_bytes, 0) & std.elf.GRP_COMDAT) == 0) continue;

            const signature = object.symbols[section.info];
            const name = try signatureName(object.*, signature);
            const gop = try retained.getOrPut(allocator, name);
            if (gop.found_existing) {
                try discardMembers(allocator, object, group_bytes);
            } else {
                gop.value_ptr.* = .{
                    .object_index = object_index,
                    .symbol_index = section.info,
                };
            }
        }
    }
}

fn signatureName(object: ObjectFile, signature: Symbol) model.Error![]const u8 {
    if (signature.name.len != 0) return signature.name;
    if (!signature.isSection()) return error.InvalidObject;
    if (signature.section_index == 0 or signature.section_index >= object.sections.len) return error.InvalidObject;
    const name = try sectionName(object, signature.section_index);
    if (name.len == 0) return error.InvalidObject;
    return name;
}

fn discardMembers(allocator: Allocator, object: *ObjectFile, group_bytes: []const u8) model.Error!void {
    const discarded_sections = try ensureDiscardedSections(allocator, object);
    var member_iterator = record.members(group_bytes);
    while (member_iterator.next()) |member_index| {
        if (member_index >= object.sections.len) return error.MissingSection;
        discarded_sections[member_index] = true;
    }
}
