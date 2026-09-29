const text_root = @import("../root.zig");
const keycodes = @import("keycodes.zig");
const types = @import("types.zig");
const compat = @import("compat.zig");
const symbols = @import("symbols.zig");
const state = @import("state.zig");

const Error = state.Error;

pub fn parse(
    allocator: @import("std").mem.Allocator,
    input: []const u8,
) Error!text_root.document.Document {
    var parser = try state.Parser.init(allocator, input);
    try parser.expectKeyword("xkb_keymap");
    _ = try parser.take(.string);
    _ = try parser.expect(.left_brace);

    var found_keycodes = false;
    var found_types = false;
    var found_compat = false;
    var found_symbols = false;
    while (!try parser.take(.right_brace)) {
        const section_name = (try parser.expect(.word)).text;
        _ = try parser.take(.string);
        if (state.keywordEqual(section_name, "xkb_keycodes")) {
            if (found_keycodes) return error.InvalidSyntax;
            found_keycodes = true;
            try keycodes.section(&parser);
        } else if (state.keywordEqual(section_name, "xkb_types")) {
            if (found_types) return error.InvalidSyntax;
            found_types = true;
            try types.section(&parser);
        } else if (state.keywordEqual(section_name, "xkb_compatibility") or
            state.keywordEqual(section_name, "xkb_compat"))
        {
            if (found_compat) return error.InvalidSyntax;
            found_compat = true;
            try compat.section(&parser);
        } else if (state.keywordEqual(section_name, "xkb_symbols")) {
            if (found_symbols) return error.InvalidSyntax;
            found_symbols = true;
            try symbols.section(&parser);
        } else if (state.keywordEqual(section_name, "xkb_geometry")) {
            _ = try parser.expect(.left_brace);
            try parser.skipBlock();
            _ = try parser.expect(.semicolon);
        } else {
            return error.InvalidSyntax;
        }
    }
    _ = try parser.expect(.semicolon);
    _ = try parser.expect(.end);
    if (!found_keycodes or !found_types or !found_compat or !found_symbols) {
        return error.InvalidSyntax;
    }
    return parser.finish();
}
