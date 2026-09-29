const std = @import("std");
const text_root = @import("../root.zig");
const document = text_root.document;
const state = @import("state.zig");

const GroupBuilder = struct {
    type_name: ?[]const u8 = null,
    levels: []const document.Level = &.{},
    has_actions: bool = false,
};

pub fn section(parser: *state.Parser) state.Error!void {
    _ = try parser.expect(.left_brace);
    while (!try parser.take(.right_brace)) {
        const token = try parser.expect(.word);
        if (state.keywordEqual(token.text, "virtual_modifiers")) {
            try parser.virtualModifierDeclaration();
        } else if (state.keywordEqual(token.text, "key")) {
            try key(parser);
        } else if (state.keywordEqual(token.text, "modifier_map") or
            state.keywordEqual(token.text, "modifierMap") or
            state.keywordEqual(token.text, "modmap"))
        {
            try modifierMap(parser);
        } else if (state.keywordEqual(token.text, "name")) {
            try parser.skipStatement();
        } else {
            return error.InvalidSyntax;
        }
    }
    _ = try parser.expect(.semicolon);
}

fn key(parser: *state.Parser) state.Error!void {
    const name = (try parser.expect(.key_name)).text;
    _ = try parser.expect(.left_brace);
    var groups: std.ArrayListUnmanaged(GroupBuilder) = .empty;
    var default_type: ?[]const u8 = null;
    var repeat: ?bool = null;
    var virtual_modifiers: ?u32 = null;
    var out_of_range: document.OutOfRange = .wrap;
    var body_closed = false;

    if ((try parser.peek()).tag == .left_bracket) {
        try ensureGroup(parser, &groups, 0);
        groups.items[0].levels = try symbolList(parser);
    } else {
        while (!try parser.take(.right_brace)) {
            const field = (try parser.expect(.word)).text;
            if (state.keywordEqual(field, "type")) {
                const group = try optionalGroup(parser);
                _ = try parser.expect(.equal);
                const type_name = (try parser.expect(.string)).text;
                if (group) |index| {
                    try ensureGroup(parser, &groups, index);
                    groups.items[index].type_name = type_name;
                } else default_type = type_name;
            } else if (state.keywordEqual(field, "symbols")) {
                const group = (try optionalGroup(parser)) orelse 0;
                _ = try parser.expect(.equal);
                try ensureGroup(parser, &groups, group);
                groups.items[group].levels = try symbolList(parser);
            } else if (state.keywordEqual(field, "actions")) {
                const group = (try optionalGroup(parser)) orelse 0;
                _ = try parser.expect(.equal);
                try ensureGroup(parser, &groups, group);
                groups.items[group].has_actions = true;
                try parser.skipValue();
            } else if (state.keywordEqual(field, "repeat") or
                state.keywordEqual(field, "repeating") or
                state.keywordEqual(field, "repeats"))
            {
                _ = try parser.expect(.equal);
                repeat = try parser.boolean();
            } else if (state.keywordEqual(field, "virtualMods") or
                state.keywordEqual(field, "virtualModifiers") or
                state.keywordEqual(field, "vmods"))
            {
                _ = try parser.expect(.equal);
                virtual_modifiers = try parser.mask(.virtual);
            } else if (state.keywordEqual(field, "groupsClamp") or
                state.keywordEqual(field, "clampGroups"))
            {
                out_of_range = if (try parser.take(.equal))
                    if (try parser.boolean()) .saturate else .wrap
                else
                    .saturate;
            } else if (state.keywordEqual(field, "groupsWrap") or
                state.keywordEqual(field, "wrapGroups"))
            {
                out_of_range = if (try parser.take(.equal))
                    if (try parser.boolean()) .wrap else .saturate
                else
                    .wrap;
            } else if (state.keywordEqual(field, "groupsRedirect") or
                state.keywordEqual(field, "redirectGroups"))
            {
                _ = try parser.expect(.equal);
                const group = try parser.number();
                if (group == 0) return error.InvalidSyntax;
                out_of_range = .{ .redirect = group - 1 };
            } else {
                _ = try parser.take(.equal);
                try parser.skipValue();
            }
            if (!try parser.take(.comma) and (try parser.peek()).tag != .right_brace) {
                return error.InvalidSyntax;
            }
        }
        body_closed = true;
    }

    if (!body_closed) _ = try parser.expect(.right_brace);
    _ = try parser.expect(.semicolon);
    const finished_groups = try parser.allocator.alloc(document.Group, groups.items.len);
    for (groups.items, finished_groups) |group, *finished| finished.* = .{
        .type_name = group.type_name,
        .levels = group.levels,
        .has_actions = group.has_actions,
    };
    try parser.keys.append(parser.allocator, .{
        .name = name,
        .default_type = default_type,
        .groups = finished_groups,
        .repeat = repeat,
        .virtual_modifiers = virtual_modifiers,
        .out_of_range = out_of_range,
    });
}

fn symbolList(parser: *state.Parser) state.Error![]const document.Level {
    _ = try parser.expect(.left_bracket);
    var levels: std.ArrayListUnmanaged(document.Level) = .empty;
    if (try parser.take(.right_bracket)) return levels.toOwnedSlice(parser.allocator);
    while (true) {
        var symbols: std.ArrayListUnmanaged(@import("../../../root.zig").keysym.Keysym) = .empty;
        if (try parser.take(.left_brace)) {
            if (!try parser.take(.right_brace)) {
                while (true) {
                    if (try parser.keysym()) |symbol| try symbols.append(parser.allocator, symbol);
                    if (try parser.take(.right_brace)) break;
                    _ = try parser.expect(.comma);
                }
            }
        } else if (try parser.keysym()) |symbol| {
            try symbols.append(parser.allocator, symbol);
        }
        try levels.append(parser.allocator, .{
            .symbols = try symbols.toOwnedSlice(parser.allocator),
        });
        if (try parser.take(.right_bracket)) break;
        _ = try parser.expect(.comma);
    }
    return levels.toOwnedSlice(parser.allocator);
}

fn optionalGroup(parser: *state.Parser) state.Error!?usize {
    if (!try parser.take(.left_bracket)) return null;
    const group = try parser.group();
    _ = try parser.expect(.right_bracket);
    return group;
}

fn ensureGroup(
    parser: *state.Parser,
    groups: *std.ArrayListUnmanaged(GroupBuilder),
    index: usize,
) state.Error!void {
    if (index >= @import("../../../root.zig").keymap.max_layouts) return error.InvalidSyntax;
    while (groups.items.len <= index) try groups.append(parser.allocator, .{});
}

fn modifierMap(parser: *state.Parser) state.Error!void {
    const modifier_name = (try parser.expect(.word)).text;
    const modifier = parser.modifierIndex(modifier_name, .real) orelse return error.InvalidSyntax;
    _ = try parser.expect(.left_brace);
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    if (!try parser.take(.right_brace)) {
        while (true) {
            const name = (try parser.expect(.key_name)).text;
            try keys.append(parser.allocator, name);
            if (try parser.take(.right_brace)) break;
            _ = try parser.expect(.comma);
        }
    }
    _ = try parser.expect(.semicolon);
    try parser.modifier_maps.append(parser.allocator, .{
        .modifier = modifier,
        .keys = try keys.toOwnedSlice(parser.allocator),
    });
}
