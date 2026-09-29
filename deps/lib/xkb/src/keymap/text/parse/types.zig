const std = @import("std");
const text_root = @import("../root.zig");
const document = text_root.document;
const state = @import("state.zig");

pub fn section(parser: *state.Parser) state.Error!void {
    _ = try parser.expect(.left_brace);
    while (!try parser.take(.right_brace)) {
        const token = try parser.expect(.word);
        if (state.keywordEqual(token.text, "virtual_modifiers")) {
            try parser.virtualModifierDeclaration();
        } else if (state.keywordEqual(token.text, "type")) {
            try keyType(parser);
        } else {
            return error.InvalidSyntax;
        }
    }
    _ = try parser.expect(.semicolon);
}

fn keyType(parser: *state.Parser) state.Error!void {
    const name = (try parser.expect(.string)).text;
    _ = try parser.expect(.left_brace);
    var entries: std.ArrayListUnmanaged(document.TypeEntry) = .empty;
    var modifiers: u32 = 0;
    var level_count: usize = 1;

    while (!try parser.take(.right_brace)) {
        const field = (try parser.expect(.word)).text;
        if (state.keywordEqual(field, "modifiers")) {
            _ = try parser.expect(.equal);
            modifiers = try parser.mask(.both);
            _ = try parser.expect(.semicolon);
        } else if (state.keywordEqual(field, "map")) {
            _ = try parser.expect(.left_bracket);
            const mask = try parser.mask(.both);
            _ = try parser.expect(.right_bracket);
            _ = try parser.expect(.equal);
            const level = try parser.level();
            _ = try parser.expect(.semicolon);
            level_count = @max(level_count, level + 1);
            try setMap(parser, &entries, mask, level);
        } else if (state.keywordEqual(field, "preserve")) {
            _ = try parser.expect(.left_bracket);
            const mask = try parser.mask(.both);
            _ = try parser.expect(.right_bracket);
            _ = try parser.expect(.equal);
            const preserve = try parser.mask(.both);
            _ = try parser.expect(.semicolon);
            try setPreserve(parser, &entries, mask, preserve);
        } else if (state.keywordEqual(field, "level_name") or
            state.keywordEqual(field, "levelname"))
        {
            _ = try parser.expect(.left_bracket);
            const level = try parser.level();
            _ = try parser.expect(.right_bracket);
            _ = try parser.expect(.equal);
            _ = try parser.expect(.string);
            _ = try parser.expect(.semicolon);
            level_count = @max(level_count, level + 1);
        } else {
            try parser.skipStatement();
        }
    }
    _ = try parser.expect(.semicolon);
    try parser.types.append(parser.allocator, .{
        .name = name,
        .modifiers = modifiers,
        .level_count = level_count,
        .entries = try entries.toOwnedSlice(parser.allocator),
    });
}

fn setMap(
    parser: *state.Parser,
    entries: *std.ArrayListUnmanaged(document.TypeEntry),
    modifiers: u32,
    level: usize,
) state.Error!void {
    for (entries.items) |*entry| {
        if (entry.modifiers != modifiers) continue;
        entry.level = level;
        return;
    }
    try entries.append(parser.allocator, .{
        .modifiers = modifiers,
        .level = level,
    });
}

fn setPreserve(
    parser: *state.Parser,
    entries: *std.ArrayListUnmanaged(document.TypeEntry),
    modifiers: u32,
    preserve: u32,
) state.Error!void {
    for (entries.items) |*entry| {
        if (entry.modifiers != modifiers) continue;
        entry.preserve = preserve;
        return;
    }
    try entries.append(parser.allocator, .{
        .modifiers = modifiers,
        .preserve = preserve,
        .level = 0,
    });
}
