const std = @import("std");

pub const Error = error{InvalidSyntax};

pub const Tag = enum {
    word,
    string,
    key_name,
    left_brace,
    right_brace,
    left_bracket,
    right_bracket,
    left_paren,
    right_paren,
    equal,
    semicolon,
    comma,
    plus,
    dot,
    bang,
    minus,
    end,
};

pub const Token = struct {
    tag: Tag,
    text: []const u8,
};

pub const Lexer = struct {
    input: []const u8,
    position: usize = 0,

    pub fn next(self: *Lexer) Error!Token {
        try self.skipIgnored();
        if (self.position == self.input.len) return .{ .tag = .end, .text = "" };

        const start = self.position;
        const byte = self.input[self.position];
        self.position += 1;
        return switch (byte) {
            '{' => self.punctuation(.left_brace, start),
            '}' => self.punctuation(.right_brace, start),
            '[' => self.punctuation(.left_bracket, start),
            ']' => self.punctuation(.right_bracket, start),
            '(' => self.punctuation(.left_paren, start),
            ')' => self.punctuation(.right_paren, start),
            '=' => self.punctuation(.equal, start),
            ';' => self.punctuation(.semicolon, start),
            ',' => self.punctuation(.comma, start),
            '+' => self.punctuation(.plus, start),
            '.' => self.punctuation(.dot, start),
            '!' => self.punctuation(.bang, start),
            '-' => self.punctuation(.minus, start),
            '"' => try self.quoted(start),
            '<' => try self.keyName(start),
            else => self.word(start),
        };
    }

    fn punctuation(self: *const Lexer, tag: Tag, start: usize) Token {
        return .{ .tag = tag, .text = self.input[start .. start + 1] };
    }

    fn quoted(self: *Lexer, start: usize) Error!Token {
        var escaped = false;
        while (self.position < self.input.len) : (self.position += 1) {
            const byte = self.input[self.position];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (byte == '\\') {
                escaped = true;
                continue;
            }
            if (byte == '"') {
                const end = self.position;
                self.position += 1;
                return .{ .tag = .string, .text = self.input[start + 1 .. end] };
            }
            if (byte == 0) return error.InvalidSyntax;
        }
        return error.InvalidSyntax;
    }

    fn keyName(self: *Lexer, start: usize) Error!Token {
        const end = std.mem.indexOfScalarPos(u8, self.input, self.position, '>') orelse
            return error.InvalidSyntax;
        if (end == self.position) return error.InvalidSyntax;
        self.position = end + 1;
        return .{ .tag = .key_name, .text = self.input[start + 1 .. end] };
    }

    fn word(self: *Lexer, start: usize) Token {
        while (self.position < self.input.len and !delimiter(self.input[self.position])) {
            self.position += 1;
        }
        return .{ .tag = .word, .text = self.input[start..self.position] };
    }

    fn skipIgnored(self: *Lexer) Error!void {
        while (self.position < self.input.len) {
            if (std.ascii.isWhitespace(self.input[self.position])) {
                self.position += 1;
                continue;
            }
            if (self.input[self.position] != '/' or self.position + 1 == self.input.len) return;
            switch (self.input[self.position + 1]) {
                '/' => {
                    self.position += 2;
                    while (self.position < self.input.len and self.input[self.position] != '\n') {
                        self.position += 1;
                    }
                },
                '*' => {
                    const end = std.mem.indexOfPos(
                        u8,
                        self.input,
                        self.position + 2,
                        "*/",
                    ) orelse return error.InvalidSyntax;
                    self.position = end + 2;
                },
                else => return,
            }
        }
    }
};

fn delimiter(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or switch (byte) {
        '{', '}', '[', ']', '(', ')', '=', ';', ',', '+', '.', '!', '-', '"', '<' => true,
        else => false,
    };
}

test "lexer separates resolved XKB punctuation and comments" {
    var lexer = Lexer{ .input = "/* a */ key <AD01> { [ 0x61, NoSymbol ] }; // b" };
    const expected = [_]Tag{
        .word,
        .key_name,
        .left_brace,
        .left_bracket,
        .word,
        .comma,
        .word,
        .right_bracket,
        .right_brace,
        .semicolon,
        .end,
    };
    for (expected) |tag| try std.testing.expectEqual(tag, (try lexer.next()).tag);
}

test "lexer rejects unterminated strings key names and comments" {
    var string = Lexer{ .input = "\"bad" };
    try std.testing.expectError(error.InvalidSyntax, string.next());
    var key_name = Lexer{ .input = "<BAD" };
    try std.testing.expectError(error.InvalidSyntax, key_name.next());
    var comment = Lexer{ .input = "/* bad" };
    try std.testing.expectError(error.InvalidSyntax, comment.next());
}
