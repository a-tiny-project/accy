const std = @import("std");
const xkb = @import("../../../root.zig");
const text_root = @import("../root.zig");
const document = text_root.document;
const lexer = text_root.lexer;

pub const Error = std.mem.Allocator.Error || lexer.Error || error{
    InvalidEncoding,
    InvalidSyntax,
    TooManyModifiers,
};

pub const MaskKind = enum {
    real,
    virtual,
    both,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer_value: lexer.Lexer,
    lookahead: ?lexer.Token = null,
    keycodes: std.ArrayListUnmanaged(document.Keycode) = .empty,
    aliases: std.ArrayListUnmanaged(document.Alias) = .empty,
    virtual_modifiers: std.ArrayListUnmanaged(document.VirtualModifier) = .empty,
    types: std.ArrayListUnmanaged(document.KeyType) = .empty,
    interprets: std.ArrayListUnmanaged(document.Interpret) = .empty,
    keys: std.ArrayListUnmanaged(document.Key) = .empty,
    modifier_maps: std.ArrayListUnmanaged(document.ModifierMap) = .empty,
    default_repeat: bool = false,
    default_level_one_only: bool = false,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Error!Parser {
        if (!std.unicode.utf8ValidateSlice(input) or std.mem.indexOfScalar(u8, input, 0) != null) {
            return error.InvalidEncoding;
        }
        return .{
            .allocator = allocator,
            .lexer_value = .{ .input = input },
        };
    }

    pub fn finish(self: *Parser) Error!document.Document {
        return .{
            .keycodes = try self.keycodes.toOwnedSlice(self.allocator),
            .aliases = try self.aliases.toOwnedSlice(self.allocator),
            .virtual_modifiers = try self.virtual_modifiers.toOwnedSlice(self.allocator),
            .types = try self.types.toOwnedSlice(self.allocator),
            .interprets = try self.interprets.toOwnedSlice(self.allocator),
            .keys = try self.keys.toOwnedSlice(self.allocator),
            .modifier_maps = try self.modifier_maps.toOwnedSlice(self.allocator),
        };
    }

    pub fn peek(self: *Parser) Error!lexer.Token {
        if (self.lookahead == null) self.lookahead = try self.lexer_value.next();
        return self.lookahead.?;
    }

    pub fn next(self: *Parser) Error!lexer.Token {
        if (self.lookahead) |token| {
            self.lookahead = null;
            return token;
        }
        return self.lexer_value.next();
    }

    pub fn take(self: *Parser, tag: lexer.Tag) Error!bool {
        if ((try self.peek()).tag != tag) return false;
        _ = try self.next();
        return true;
    }

    pub fn expect(self: *Parser, tag: lexer.Tag) Error!lexer.Token {
        const token = try self.next();
        if (token.tag != tag) return error.InvalidSyntax;
        return token;
    }

    pub fn expectKeyword(self: *Parser, keyword: []const u8) Error!void {
        const token = try self.expect(.word);
        if (!keywordEqual(token.text, keyword)) return error.InvalidSyntax;
    }

    pub fn takeKeyword(self: *Parser, keyword: []const u8) Error!bool {
        const token = try self.peek();
        if (token.tag != .word or !keywordEqual(token.text, keyword)) return false;
        _ = try self.next();
        return true;
    }

    pub fn number(self: *Parser) Error!u32 {
        const token = try self.expect(.word);
        return parseNumber(token.text) orelse error.InvalidSyntax;
    }

    pub fn level(self: *Parser) Error!usize {
        const token = try self.expect(.word);
        const raw = if (startsWithIgnoreCase(token.text, "Level"))
            parseNumber(token.text["Level".len..]) orelse return error.InvalidSyntax
        else
            parseNumber(token.text) orelse return error.InvalidSyntax;
        if (raw == 0) return error.InvalidSyntax;
        return raw - 1;
    }

    pub fn group(self: *Parser) Error!usize {
        const token = try self.expect(.word);
        const raw = if (startsWithIgnoreCase(token.text, "Group"))
            parseNumber(token.text["Group".len..]) orelse return error.InvalidSyntax
        else
            parseNumber(token.text) orelse return error.InvalidSyntax;
        if (raw == 0) return error.InvalidSyntax;
        return raw - 1;
    }

    pub fn boolean(self: *Parser) Error!bool {
        const token = try self.expect(.word);
        if (keywordEqual(token.text, "true") or keywordEqual(token.text, "yes") or
            keywordEqual(token.text, "on")) return true;
        if (keywordEqual(token.text, "false") or keywordEqual(token.text, "no") or
            keywordEqual(token.text, "off")) return false;
        return error.InvalidSyntax;
    }

    pub fn keysym(self: *Parser) Error!?xkb.keysym.Keysym {
        const token = try self.expect(.word);
        if (keywordEqual(token.text, "NoSymbol")) return null;
        const raw = parseNumber(token.text) orelse {
            const value = xkb.keysym.fromName(token.text) orelse return error.InvalidSyntax;
            if (value == .no_symbol) return null;
            return value;
        };
        if (raw == 0) return null;
        if (raw > xkb.keysym.max) return error.InvalidSyntax;
        return @fromBackingInt(@intCast(raw));
    }

    pub fn mask(self: *Parser, kind: MaskKind) Error!u32 {
        var result: u32 = 0;
        var had_value = false;
        while (true) {
            const token = try self.expect(.word);
            result |= try self.maskTerm(token.text, kind);
            had_value = true;
            if (!try self.take(.plus)) break;
        }
        if (!had_value) return error.InvalidSyntax;
        return result;
    }

    pub fn virtualModifierDeclaration(self: *Parser) Error!void {
        while (true) {
            const name = (try self.expect(.word)).text;
            var mapping: ?u32 = null;
            if (try self.take(.equal)) mapping = try self.mask(.both);
            try self.addVirtualModifier(name, mapping);
            if (!try self.take(.comma)) break;
        }
        _ = try self.expect(.semicolon);
    }

    pub fn modifierIndex(self: *const Parser, name: []const u8, kind: MaskKind) ?usize {
        if (kind != .virtual) {
            for (xkb.keymap.core_modifiers, 0..) |modifier, index| {
                if (keywordEqual(name, modifier.name)) return index;
            }
        }
        if (kind != .real) {
            for (self.virtual_modifiers.items, 0..) |modifier, offset| {
                if (keywordEqual(name, modifier.name)) {
                    return xkb.keymap.core_modifier_count + offset;
                }
            }
        }
        return null;
    }

    pub fn addVirtualModifier(
        self: *Parser,
        name: []const u8,
        mapping: ?u32,
    ) Error!void {
        for (self.virtual_modifiers.items) |*modifier| {
            if (!keywordEqual(name, modifier.name)) continue;
            if (mapping) |value| {
                if (modifier.explicit_mapping) |existing| {
                    if (existing != value) return error.InvalidSyntax;
                } else modifier.explicit_mapping = value;
            }
            return;
        }
        if (xkb.keymap.core_modifier_count + self.virtual_modifiers.items.len ==
            @bitSizeOf(xkb.keymap.ModifierMask)) return error.TooManyModifiers;
        try self.virtual_modifiers.append(self.allocator, .{
            .name = name,
            .explicit_mapping = mapping,
        });
    }

    pub fn skipStatement(self: *Parser) Error!void {
        var braces: usize = 0;
        var brackets: usize = 0;
        var parens: usize = 0;
        while (true) {
            const token = try self.next();
            switch (token.tag) {
                .left_brace => braces += 1,
                .right_brace => {
                    if (braces == 0) return error.InvalidSyntax;
                    braces -= 1;
                },
                .left_bracket => brackets += 1,
                .right_bracket => {
                    if (brackets == 0) return error.InvalidSyntax;
                    brackets -= 1;
                },
                .left_paren => parens += 1,
                .right_paren => {
                    if (parens == 0) return error.InvalidSyntax;
                    parens -= 1;
                },
                .semicolon => if (braces == 0 and brackets == 0 and parens == 0) return,
                .end => return error.InvalidSyntax,
                else => {},
            }
        }
    }

    pub fn skipBlock(self: *Parser) Error!void {
        var depth: usize = 1;
        while (depth != 0) {
            switch ((try self.next()).tag) {
                .left_brace => depth += 1,
                .right_brace => depth -= 1,
                .end => return error.InvalidSyntax,
                else => {},
            }
        }
    }

    pub fn skipValue(self: *Parser) Error!void {
        var braces: usize = 0;
        var brackets: usize = 0;
        var parens: usize = 0;
        while (true) {
            const token = try self.peek();
            if (braces == 0 and brackets == 0 and parens == 0 and
                (token.tag == .comma or token.tag == .right_brace or token.tag == .semicolon)) return;
            _ = try self.next();
            switch (token.tag) {
                .left_brace => braces += 1,
                .right_brace => {
                    if (braces == 0) return error.InvalidSyntax;
                    braces -= 1;
                },
                .left_bracket => brackets += 1,
                .right_bracket => {
                    if (brackets == 0) return error.InvalidSyntax;
                    brackets -= 1;
                },
                .left_paren => parens += 1,
                .right_paren => {
                    if (parens == 0) return error.InvalidSyntax;
                    parens -= 1;
                },
                .end => return error.InvalidSyntax,
                else => {},
            }
        }
    }

    fn maskTerm(self: *Parser, text: []const u8, kind: MaskKind) Error!u32 {
        if (keywordEqual(text, "none")) return 0;
        if (keywordEqual(text, "all")) return xkb.keymap.core_modifier_mask;
        if (parseNumber(text)) |value| {
            const allowed = switch (kind) {
                .real => xkb.keymap.core_modifier_mask,
                .virtual => ~xkb.keymap.core_modifier_mask,
                .both => std.math.maxInt(u32),
            };
            if (value & ~allowed != 0) return error.InvalidSyntax;
            return value;
        }
        const index = self.modifierIndex(text, kind) orelse return error.InvalidSyntax;
        return xkb.keymap.modifierBit(index);
    }
};

pub fn keywordEqual(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

pub fn parseNumber(text: []const u8) ?u32 {
    if (text.len == 0) return null;
    return std.fmt.parseInt(u32, text, 0) catch null;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}
