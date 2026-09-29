const xkb = @import("../../../root.zig");
const text_root = @import("../root.zig");
const document = text_root.document;
const state = @import("state.zig");

pub fn section(parser: *state.Parser) state.Error!void {
    _ = try parser.expect(.left_brace);
    while (!try parser.take(.right_brace)) {
        const token = try parser.expect(.word);
        if (state.keywordEqual(token.text, "virtual_modifiers")) {
            try parser.virtualModifierDeclaration();
        } else if (state.keywordEqual(token.text, "interpret")) {
            if (try parser.take(.dot)) {
                try defaultField(parser);
            } else {
                try interpret(parser);
            }
        } else if (state.keywordEqual(token.text, "indicator")) {
            _ = try parser.expect(.string);
            _ = try parser.expect(.left_brace);
            try parser.skipBlock();
            _ = try parser.expect(.semicolon);
        } else {
            return error.InvalidSyntax;
        }
    }
    _ = try parser.expect(.semicolon);
}

fn defaultField(parser: *state.Parser) state.Error!void {
    const field = (try parser.expect(.word)).text;
    _ = try parser.expect(.equal);
    if (state.keywordEqual(field, "repeat")) {
        parser.default_repeat = try parser.boolean();
        _ = try parser.expect(.semicolon);
    } else if (state.keywordEqual(field, "useModMapMods") or
        state.keywordEqual(field, "useModMap"))
    {
        const value = (try parser.expect(.word)).text;
        parser.default_level_one_only = state.keywordEqual(value, "level1");
        if (!parser.default_level_one_only and !state.keywordEqual(value, "AnyLevel")) {
            return error.InvalidSyntax;
        }
        _ = try parser.expect(.semicolon);
    } else {
        try parser.skipStatement();
    }
}

fn interpret(parser: *state.Parser) state.Error!void {
    const symbol_token = try parser.expect(.word);
    const symbol: ?xkb.keysym.Keysym = if (state.keywordEqual(symbol_token.text, "Any"))
        null
    else blk: {
        parser.lookahead = symbol_token;
        break :blk try parser.keysym() orelse return error.InvalidSyntax;
    };
    _ = try parser.expect(.plus);
    const match = try matchKind((try parser.expect(.word)).text);
    _ = try parser.expect(.left_paren);
    const modifiers = try parser.mask(.real);
    _ = try parser.expect(.right_paren);
    _ = try parser.expect(.left_brace);

    var repeat = parser.default_repeat;
    var level_one_only = parser.default_level_one_only;
    var virtual_modifier: ?usize = null;
    while (!try parser.take(.right_brace)) {
        const field = (try parser.expect(.word)).text;
        _ = try parser.expect(.equal);
        if (state.keywordEqual(field, "repeat")) {
            repeat = try parser.boolean();
            _ = try parser.expect(.semicolon);
        } else if (state.keywordEqual(field, "useModMapMods") or
            state.keywordEqual(field, "useModMap"))
        {
            const value = (try parser.expect(.word)).text;
            level_one_only = state.keywordEqual(value, "level1");
            if (!level_one_only and !state.keywordEqual(value, "AnyLevel")) {
                return error.InvalidSyntax;
            }
            _ = try parser.expect(.semicolon);
        } else if (state.keywordEqual(field, "virtualModifier") or
            state.keywordEqual(field, "virtualMod"))
        {
            const name = (try parser.expect(.word)).text;
            const index = parser.modifierIndex(name, .virtual) orelse return error.InvalidSyntax;
            virtual_modifier = index;
            _ = try parser.expect(.semicolon);
        } else {
            try parser.skipStatement();
        }
    }
    _ = try parser.expect(.semicolon);
    try parser.interprets.append(parser.allocator, .{
        .symbol = symbol,
        .match = match,
        .modifiers = modifiers,
        .repeat = repeat,
        .level_one_only = level_one_only,
        .virtual_modifier = virtual_modifier,
        .order = parser.interprets.items.len,
    });
}

fn matchKind(text: []const u8) state.Error!document.Match {
    if (state.keywordEqual(text, "Exactly")) return .exactly;
    if (state.keywordEqual(text, "AllOf")) return .all;
    if (state.keywordEqual(text, "NoneOf")) return .none;
    if (state.keywordEqual(text, "AnyOf")) return .any;
    if (state.keywordEqual(text, "AnyOfOrNone")) return .any_or_none;
    return error.InvalidSyntax;
}
