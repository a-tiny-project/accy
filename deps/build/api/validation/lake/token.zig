//! Lexical boundaries for explicit dependency declarations, not a Lean evaluator.
const std = @import("std");

pub const Token = struct {
    kind: enum { word, string, symbol, newline, end },
    text: []const u8,

    pub fn is(self: Token, text: []const u8) bool {
        return self.kind != .string and std.mem.eql(u8, self.text, text);
    }

    pub fn literal(self: Token) ![]const u8 {
        if (self.kind != .string or self.text.len == 0 or
            std.mem.indexOfAny(u8, self.text, "\\\r\n\x00") != null)
            return error.UnsupportedLakeRequire;
        return self.text;
    }
};

pub const Lexer = struct {
    bytes: []const u8,
    lean: bool,
    cursor: usize = 0,

    pub fn next(self: *Lexer) !Token {
        std.debug.assert(self.cursor <= self.bytes.len);
        while (self.cursor < self.bytes.len) {
            const start = self.cursor;
            const byte = self.bytes[start];
            self.cursor += 1;
            if (byte == '\n') return .{ .kind = .newline, .text = self.bytes[start..self.cursor] };
            if (byte == ' ' or byte == '\t' or byte == '\r') continue;
            if ((!self.lean and byte == '#') or (self.lean and self.at(start, "--"))) {
                while (self.cursor < self.bytes.len and self.bytes[self.cursor] != '\n') {
                    self.cursor += 1;
                }
                continue;
            }
            if (self.lean and self.at(start, "/-")) {
                self.cursor += 1;
                var depth: usize = 1;
                while (self.cursor < self.bytes.len and depth != 0) {
                    if (self.at(self.cursor, "/-")) {
                        depth += 1;
                        self.cursor += 2;
                    } else if (self.at(self.cursor, "-/")) {
                        depth -= 1;
                        self.cursor += 2;
                    } else self.cursor += 1;
                }
                if (depth != 0) return error.InvalidLakeSyntax;
                continue;
            }
            if (self.lean and byte == 'r' and
                (self.at(self.cursor, "\"") or self.at(self.cursor, "#")))
                return error.UnsupportedLakeLiteral;
            if (self.lean and byte == '\'') return self.character();
            if (byte == '"' or byte == '\'') return self.string(byte);
            if (word(byte)) {
                while (self.cursor < self.bytes.len and word(self.bytes[self.cursor])) {
                    self.cursor += 1;
                }
                return .{ .kind = .word, .text = self.bytes[start..self.cursor] };
            }
            return .{ .kind = .symbol, .text = self.bytes[start..self.cursor] };
        }
        return .{ .kind = .end, .text = "" };
    }

    pub fn significant(self: *Lexer) !Token {
        var token = try self.next();
        while (token.kind == .newline) token = try self.next();
        return token;
    }

    fn at(self: Lexer, offset: usize, text: []const u8) bool {
        return std.mem.startsWith(u8, self.bytes[offset..], text);
    }

    fn character(self: *Lexer) !Token {
        const content = self.cursor;
        if (self.cursor == self.bytes.len) return error.InvalidLakeSyntax;
        if (self.bytes[self.cursor] == '\\') {
            self.cursor += 1;
            if (self.cursor == self.bytes.len or
                std.mem.indexOfScalar(u8, "nrt\\\"'0", self.bytes[self.cursor]) == null)
                return error.UnsupportedLakeLiteral;
            self.cursor += 1;
        } else {
            const first = self.bytes[self.cursor];
            if (first == '\'' or first == '\n' or first == '\r') return error.InvalidLakeSyntax;
            const length = std.unicode.utf8ByteSequenceLength(first) catch
                return error.InvalidLakeSyntax;
            if (length > self.bytes.len - self.cursor) return error.InvalidLakeSyntax;
            _ = std.unicode.utf8Decode(self.bytes[self.cursor..][0..length]) catch
                return error.InvalidLakeSyntax;
            self.cursor += length;
        }
        const end = self.cursor;
        if (self.cursor == self.bytes.len or self.bytes[self.cursor] != '\'')
            return error.InvalidLakeSyntax;
        self.cursor += 1;
        // A character cannot serve as a path literal.
        return .{ .kind = .symbol, .text = self.bytes[content..end] };
    }

    fn string(self: *Lexer, quote: u8) !Token {
        const triple = !self.lean and self.cursor + 1 < self.bytes.len and
            self.bytes[self.cursor] == quote and self.bytes[self.cursor + 1] == quote;
        if (triple) self.cursor += 2;
        const content = self.cursor;
        const interpolated = self.lean and content >= 2 and self.bytes[content - 2] == '!';
        var braces: usize = 0;
        while (self.cursor < self.bytes.len) {
            const index = self.cursor;
            self.cursor += 1;
            if (self.bytes[index] == '\\' and (quote == '"' or self.lean)) {
                if (self.cursor == self.bytes.len) return error.InvalidLakeSyntax;
                self.cursor += 1;
                continue;
            }
            if (interpolated) {
                if (self.bytes[index] == '{') braces += 1;
                if (self.bytes[index] == '}' and braces != 0) braces -= 1;
                if (self.bytes[index] == quote and braces != 0)
                    return error.UnsupportedLakeLiteral;
            }
            if (self.bytes[index] != quote) continue;
            if (triple) {
                if (self.cursor + 1 >= self.bytes.len or self.bytes[self.cursor] != quote or
                    self.bytes[self.cursor + 1] != quote) continue;
                self.cursor += 2;
            }
            return .{ .kind = .string, .text = self.bytes[content..index] };
        }
        return error.InvalidLakeSyntax;
    }
};

fn word(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or
        byte == '\'' or byte >= 0x80;
}
