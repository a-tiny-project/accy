const std = @import("std");
const xkb = @import("../root.zig");
const compose = @import("root.zig");

const Keysym = xkb.keysym.Keysym;

pub const DiagnosticCode = enum {
    invalid_syntax,
    unknown_keysym,
    sequence_too_long,
    output_too_long,
    invalid_utf8,
};

pub const Diagnostic = struct {
    source: []const u8,
    line: usize,
    code: DiagnosticCode,
};

pub const DiagnosticFn = *const fn (context: *anyopaque, diagnostic: Diagnostic) void;

pub const Error = std.Io.File.OpenError || std.Io.File.StatError ||
    std.Io.File.Reader.Error || compose.Exhaustion || compose.ScratchExhaustion || error{
    StreamTooLong,
    InvalidEncoding,
    TooManyErrors,
    InvalidSyntax,
    UnknownKeysym,
    SequenceTooLong,
    OutputTooLong,
    InvalidUtf8,
    InvalidIncludeExpansion,
    MissingHome,
    LocaleUnavailable,
    InvalidFileKind,
    IncludeDepthExceeded,
};

pub const Options = struct {
    paths: compose.PathOptions,
    diagnostic_context: ?*anyopaque = null,
    diagnostic: ?DiagnosticFn = null,
};

pub fn parse(
    storage: *compose.Storage,
    scratch_storage: *compose.ScratchStorage,
    input: []const u8,
    source: []const u8,
    options: Options,
    include_depth: usize,
) Error!void {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidEncoding;
    const content = if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) input[3..] else input;
    if (content.len >= 2 and
        (content[0] == 0 or content[1] == 0 or !std.ascii.isAscii(content[0])))
    {
        return error.InvalidEncoding;
    }

    var error_count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        if (raw_line.len > scratch_storage.lineLimit()) {
            return error.LineByteCapacityExceeded;
        }
        try parseRecovering(
            storage,
            scratch_storage,
            std.mem.trimEnd(u8, raw_line, "\r"),
            source,
            line_number,
            options,
            include_depth,
            &error_count,
        );
    }
}

pub fn parseOpenedFile(
    storage: *compose.Storage,
    scratch_storage: *compose.ScratchStorage,
    file: std.Io.File,
    file_bytes: u64,
    source: []const u8,
    options: Options,
    include_depth: usize,
) Error!void {
    if (file_bytes >= compose.max_file_bytes) return error.StreamTooLong;
    var reader = file.reader(options.paths.io, scratch_storage.fileLine(include_depth));
    var error_count: usize = 0;
    var line_number: usize = 0;
    while (true) {
        const raw_line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.StreamTooLong => return error.LineByteCapacityExceeded,
        } orelse return;
        if (raw_line.len > scratch_storage.lineLimit()) {
            return error.LineByteCapacityExceeded;
        }
        line_number += 1;
        if (!std.unicode.utf8ValidateSlice(raw_line)) return error.InvalidEncoding;
        const content = if (line_number == 1 and
            std.mem.startsWith(u8, raw_line, "\xef\xbb\xbf"))
            raw_line[3..]
        else
            raw_line;
        if (line_number == 1 and content.len >= 2 and
            (content[0] == 0 or content[1] == 0 or !std.ascii.isAscii(content[0])))
        {
            return error.InvalidEncoding;
        }
        try parseRecovering(
            storage,
            scratch_storage,
            std.mem.trimEnd(u8, content, "\r"),
            source,
            line_number,
            options,
            include_depth,
            &error_count,
        );
    }
}

fn parseFile(
    storage: *compose.Storage,
    scratch_storage: *compose.ScratchStorage,
    file_path: []const u8,
    options: Options,
    include_depth: usize,
) Error!void {
    var file = try std.Io.Dir.cwd().openFile(options.paths.io, file_path, .{});
    defer file.close(options.paths.io);
    const stat = try file.stat(options.paths.io);
    if (stat.kind != .file) return error.InvalidFileKind;
    try parseOpenedFile(
        storage,
        scratch_storage,
        file,
        stat.size,
        file_path,
        options,
        include_depth,
    );
}

fn parseRecovering(
    storage: *compose.Storage,
    scratch_storage: *compose.ScratchStorage,
    raw_line: []const u8,
    source: []const u8,
    line_number: usize,
    options: Options,
    include_depth: usize,
    error_count: *usize,
) Error!void {
    parseLine(
        storage,
        scratch_storage,
        raw_line,
        source,
        line_number,
        options,
        include_depth,
    ) catch |err| switch (err) {
        error.InvalidSyntax => {
            error_count.* += 1;
            report(options, .{ .source = source, .line = line_number, .code = .invalid_syntax });
            if (error_count.* > 10) return error.TooManyErrors;
        },
        error.UnknownKeysym => {
            error_count.* += 1;
            report(options, .{ .source = source, .line = line_number, .code = .unknown_keysym });
            if (error_count.* > 10) return error.TooManyErrors;
        },
        error.SequenceTooLong => {
            report(options, .{ .source = source, .line = line_number, .code = .sequence_too_long });
        },
        error.OutputTooLong => {
            report(options, .{ .source = source, .line = line_number, .code = .output_too_long });
        },
        error.InvalidUtf8 => {
            error_count.* += 1;
            report(options, .{ .source = source, .line = line_number, .code = .invalid_utf8 });
            if (error_count.* > 10) return error.TooManyErrors;
        },
        else => return err,
    };
}

fn parseLine(
    storage: *compose.Storage,
    scratch_storage: *compose.ScratchStorage,
    raw_line: []const u8,
    source: []const u8,
    line_number: usize,
    options: Options,
    include_depth: usize,
) Error!void {
    var cursor = Cursor{ .input = raw_line };
    cursor.skipSpace();
    if (cursor.done() or cursor.peek() == '#') return;

    const initial = cursor.position;
    if (cursor.identifier()) |identifier| {
        if (std.mem.eql(u8, identifier, "include")) {
            return parseInclude(
                storage,
                scratch_storage,
                &cursor,
                options,
                include_depth,
            );
        }
    }
    cursor.position = initial;

    var sequence: [compose.max_sequence_length]Keysym = undefined;
    var sequence_length: usize = 0;
    while (true) {
        cursor.skipSpace();
        if (cursor.take(':')) break;
        if (cursor.done() or cursor.peek() == '#') return error.InvalidSyntax;

        const opening = std.mem.indexOfScalarPos(
            u8,
            cursor.input,
            cursor.position,
            '<',
        ) orelse return error.InvalidSyntax;
        if (!validModifiers(cursor.input[cursor.position..opening])) {
            return error.InvalidSyntax;
        }
        cursor.position = opening + 1;
        const closing = std.mem.indexOfScalarPos(
            u8,
            cursor.input,
            cursor.position,
            '>',
        ) orelse return error.InvalidSyntax;
        const name = cursor.input[cursor.position..closing];
        cursor.position = closing + 1;
        const symbol = xkb.keysym.fromName(name) orelse return error.UnknownKeysym;
        if (symbol == .no_symbol) return error.UnknownKeysym;
        if (sequence_length == sequence.len) return error.SequenceTooLong;
        sequence[sequence_length] = symbol;
        sequence_length += 1;
    }
    if (sequence_length == 0) return error.InvalidSyntax;

    cursor.skipSpace();
    var text_buffer: [compose.max_output_bytes]u8 = undefined;
    const text = if (!cursor.done() and cursor.peek() == '"')
        try parseString(&cursor, &text_buffer)
    else
        null;
    cursor.skipSpace();
    const symbol = if (!cursor.done() and cursor.peek() != '#') blk: {
        const name = cursor.identifier() orelse return error.InvalidSyntax;
        const value = xkb.keysym.fromName(name) orelse return error.UnknownKeysym;
        if (value == .no_symbol) return error.UnknownKeysym;
        break :blk value;
    } else null;
    cursor.skipSpace();
    if (!cursor.done() and cursor.peek() != '#') return error.InvalidSyntax;
    if (text == null and symbol == null) return error.InvalidSyntax;

    try storage.insert(sequence[0..sequence_length], .{
        .text = text,
        .symbol = symbol,
    });
    _ = source;
    _ = line_number;
}

fn parseInclude(
    storage: *compose.Storage,
    scratch_storage: *compose.ScratchStorage,
    cursor: *Cursor,
    options: Options,
    include_depth: usize,
) Error!void {
    cursor.skipSpace();
    if (!cursor.take('"')) return error.InvalidSyntax;
    const start = cursor.position;
    while (!cursor.done() and cursor.peek() != '"') cursor.position += 1;
    if (cursor.done()) return error.InvalidSyntax;
    const raw_path = cursor.input[start..cursor.position];
    cursor.position += 1;
    cursor.skipSpace();
    if (!cursor.done() and cursor.peek() != '#') return error.InvalidSyntax;
    if (include_depth >= compose.max_include_depth) return error.IncludeDepthExceeded;

    const file_path = try compose.expandInclude(
        scratch_storage,
        scratch_storage.filePath(include_depth + 1),
        options.paths,
        raw_path,
    );
    try parseFile(
        storage,
        scratch_storage,
        file_path,
        options,
        include_depth + 1,
    );
}

fn parseString(cursor: *Cursor, output: *[compose.max_output_bytes]u8) ![]const u8 {
    std.debug.assert(cursor.take('"'));
    var length: usize = 0;
    while (!cursor.done() and cursor.peek() != '"') {
        if (!cursor.take('\\')) {
            try appendOutput(output, &length, cursor.peek());
            cursor.position += 1;
            continue;
        }
        if (cursor.done()) return error.InvalidSyntax;
        switch (cursor.peek()) {
            '\\', '"' => {
                try appendOutput(output, &length, cursor.peek());
                cursor.position += 1;
            },
            'x', 'X' => {
                cursor.position += 1;
                const value = parseEscapedInteger(cursor, 16, 2);
                if (value) |byte| if (byte != 0) try appendOutput(output, &length, byte);
            },
            '0'...'7' => {
                const value = parseEscapedInteger(cursor, 8, 4);
                if (value) |byte| if (byte != 0) try appendOutput(output, &length, byte);
            },
            else => {
                try appendOutput(output, &length, cursor.peek());
                cursor.position += 1;
            },
        }
    }
    if (!cursor.take('"')) return error.InvalidSyntax;
    if (!std.unicode.utf8ValidateSlice(output[0..length])) return error.InvalidUtf8;
    return output[0..length];
}

fn parseEscapedInteger(cursor: *Cursor, base: u8, maximum_digits: usize) ?u8 {
    var value: u16 = 0;
    var digits: usize = 0;
    while (!cursor.done() and digits < maximum_digits) {
        const digit = std.fmt.charToDigit(cursor.peek(), base) catch break;
        if (value > (std.math.maxInt(u8) - digit) / base) {
            cursor.position += 1;
            return null;
        }
        value = value * base + digit;
        cursor.position += 1;
        digits += 1;
    }
    if (digits == 0) return null;
    return @intCast(value);
}

fn appendOutput(output: *[compose.max_output_bytes]u8, length: *usize, byte: u8) !void {
    if (length.* == output.len) return error.OutputTooLong;
    output[length.*] = byte;
    length.* += 1;
}

fn validModifiers(input: []const u8) bool {
    var cursor = Cursor{ .input = input };
    cursor.skipSpace();
    if (cursor.done()) return true;
    if (cursor.identifier()) |identifier| {
        if (std.mem.eql(u8, identifier, "None")) {
            cursor.skipSpace();
            return cursor.done();
        }
        cursor.position = 0;
    }
    _ = cursor.take('!');
    while (true) {
        cursor.skipSpace();
        if (cursor.done()) return true;
        _ = cursor.take('~');
        cursor.skipSpace();
        const identifier = cursor.identifier() orelse return false;
        if (!isModifierName(identifier)) return false;
    }
}

fn isModifierName(input: []const u8) bool {
    return std.mem.eql(u8, input, "Ctrl") or
        std.mem.eql(u8, input, "Lock") or
        std.mem.eql(u8, input, "Caps") or
        std.mem.eql(u8, input, "Shift") or
        std.mem.eql(u8, input, "Alt") or
        std.mem.eql(u8, input, "Meta");
}

fn report(options: Options, diagnostic: Diagnostic) void {
    const function = options.diagnostic orelse return;
    function(options.diagnostic_context orelse return, diagnostic);
}

const Cursor = struct {
    input: []const u8,
    position: usize = 0,

    fn done(self: Cursor) bool {
        return self.position >= self.input.len;
    }

    fn peek(self: Cursor) u8 {
        return self.input[self.position];
    }

    fn take(self: *Cursor, expected: u8) bool {
        if (self.done() or self.peek() != expected) return false;
        self.position += 1;
        return true;
    }

    fn skipSpace(self: *Cursor) void {
        while (!self.done() and isSpace(self.peek())) {
            self.position += 1;
        }
    }

    fn identifier(self: *Cursor) ?[]const u8 {
        if (self.done() or !isIdentifierStart(self.peek())) return null;
        const start = self.position;
        self.position += 1;
        while (!self.done() and isIdentifierContinue(self.peek())) self.position += 1;
        return self.input[start..self.position];
    }
};

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isIdentifierContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or (byte >= '\t' and byte <= '\r');
}

test "parser accepts modifiers strings symbols escapes and line recovery" {
    const allocator = std.testing.allocator;
    var storage = try compose.Storage.init(allocator, .{
        .sequence_symbols = 32,
        .text_bytes = 64,
    });
    defer storage.deinit(allocator);
    var scratch_storage = try compose.ScratchStorage.init(allocator, compose.default_scratch_limits);
    defer scratch_storage.deinit(allocator);
    storage.activate();
    scratch_storage.activate();
    try storage.acquire();
    defer storage.reset();
    try scratch_storage.acquire();
    defer scratch_storage.reset();
    try parse(
        &storage,
        &scratch_storage,
        \\! Shift ~Ctrl <Multi_key> <a> : "A\x42\103" C
        \\None <dead_acute> <space> : "'" apostrophe
        \\<NoSuchKeysym> : "ignored"
        \\<A> : dollar
    ,
        "fixture",
        .{ .paths = .{ .locale = "C" } },
        0,
    );
    const published = storage.publish();

    var iterator_value = published.iterator();
    const a = iterator_value.next().?;
    try std.testing.expect(a.text == null);
    try std.testing.expectEqual(@as(?Keysym, @fromBackingInt(@intCast('$'))), a.symbol);
    const dead = iterator_value.next().?;
    try std.testing.expectEqualStrings("'", dead.text.?);
    const multi = iterator_value.next().?;
    try std.testing.expectEqualStrings("ABC", multi.text.?);
    try std.testing.expect(iterator_value.next() == null);
}

test "parser consumes a source BOM and matches four-digit octal escapes" {
    const allocator = std.testing.allocator;
    var storage = try compose.Storage.init(allocator, .{
        .sequence_symbols = 8,
        .text_bytes = 8,
    });
    defer storage.deinit(allocator);
    var scratch_storage = try compose.ScratchStorage.init(allocator, compose.default_scratch_limits);
    defer scratch_storage.deinit(allocator);
    storage.activate();
    scratch_storage.activate();
    try storage.acquire();
    defer storage.reset();
    try scratch_storage.acquire();
    defer scratch_storage.reset();
    try parse(
        &storage,
        &scratch_storage,
        "\xef\xbb\xbf<A> : \"\\0011\" A\n",
        "fixture",
        .{ .paths = .{ .locale = "C" } },
        0,
    );
    const published = storage.publish();

    var iterator_value = published.iterator();
    const entry = iterator_value.next().?;
    try std.testing.expectEqualStrings("\t", entry.text.?);
}

test "parser rejects zero-prefixed multibyte encodings" {
    const allocator = std.testing.allocator;
    var storage = try compose.Storage.init(allocator, .{
        .sequence_symbols = 8,
        .text_bytes = 8,
    });
    defer storage.deinit(allocator);
    var scratch_storage = try compose.ScratchStorage.init(allocator, compose.default_scratch_limits);
    defer scratch_storage.deinit(allocator);
    storage.activate();
    scratch_storage.activate();
    try storage.acquire();
    defer storage.reset();
    try scratch_storage.acquire();
    defer scratch_storage.reset();
    try std.testing.expectError(
        error.InvalidEncoding,
        parse(
            &storage,
            &scratch_storage,
            "<\x00A\x00>\x00 \x00:\x00 \x00X\x00",
            "fixture",
            .{ .paths = .{ .locale = "C" } },
            0,
        ),
    );
}

test "parser accepts the pinned ASCII whitespace set" {
    const allocator = std.testing.allocator;
    var storage = try compose.Storage.init(allocator, .{
        .sequence_symbols = 8,
        .text_bytes = 8,
    });
    defer storage.deinit(allocator);
    var scratch_storage = try compose.ScratchStorage.init(allocator, compose.default_scratch_limits);
    defer scratch_storage.deinit(allocator);
    storage.activate();
    scratch_storage.activate();
    try storage.acquire();
    defer storage.reset();
    try scratch_storage.acquire();
    defer scratch_storage.reset();
    try parse(
        &storage,
        &scratch_storage,
        "\x0b<A>\x0c:\x0b\"ok\"\n",
        "fixture",
        .{ .paths = .{ .locale = "C" } },
        0,
    );
    const published = storage.publish();
    var iterator_value = published.iterator();
    try std.testing.expectEqualStrings("ok", iterator_value.next().?.text.?);
}
