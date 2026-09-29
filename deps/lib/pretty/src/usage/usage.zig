const std = @import("std");
const pretty = @import("pretty");
const types = @import("types.zig");

const UsageTextStyles = types.UsageTextStyles;
const UsageTextOptions = types.UsageTextOptions;

pub fn docAlloc(builder: pretty.Builder, usage_text: []const u8, styles: UsageTextStyles) !pretty.Doc {
    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    var paragraph: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitScalar(u8, usage_text, '\n');
    while (lines.next()) |line| {
        if (isUsageParagraphLine(line)) {
            if (paragraph.items.len > 0) try paragraph.append(builder.allocator, ' ');
            try paragraph.appendSlice(builder.allocator, line);
            continue;
        }

        try flushUsageParagraph(builder, &parts, &paragraph);
        if (line.len == 0) {
            try parts.append(builder.allocator, pretty.hardline);
            continue;
        }
        try parts.append(builder.allocator, try usageTextLineDocAlloc(builder, line, styles));
        try parts.append(builder.allocator, pretty.hardline);
    }
    try flushUsageParagraph(builder, &parts, &paragraph);
    return try builder.concat(parts.items);
}

fn flushUsageParagraph(
    builder: pretty.Builder,
    parts: *std.ArrayListUnmanaged(pretty.Doc),
    paragraph: *std.ArrayListUnmanaged(u8),
) !void {
    if (paragraph.items.len == 0) return;
    const text = try builder.allocator.dupe(u8, paragraph.items);
    try parts.append(builder.allocator, try wordLineDocAlloc(builder, 0, null, text));
    try parts.append(builder.allocator, pretty.hardline);
    paragraph.clearRetainingCapacity();
}

fn isUsageParagraphLine(line: []const u8) bool {
    if (line.len == 0 or leadingSpaces(line) != 0) return false;
    if (std.mem.startsWith(u8, line, "usage:")) return false;
    if (isUsageSectionLine(line)) return false;
    return true;
}

fn usageTextLineDocAlloc(builder: pretty.Builder, line: []const u8, styles: UsageTextStyles) !pretty.Doc {
    const indent = leadingSpaces(line);
    const body = line[indent..];
    if (std.mem.startsWith(u8, body, "usage:")) return try usageLineDocAlloc(builder, indent, body, styles);
    if (indent == 0 and isUsageSectionLine(body)) return try sectionLineDocAlloc(builder, body, styles);
    if (columnGap(body) orelse inferredOptionGap(body)) |gap| return try columnLineDocAlloc(builder, indent, body, gap, styles);
    return try wordLineDocAlloc(builder, indent, null, body);
}

fn isUsageSectionLine(body: []const u8) bool {
    return body.len > 1 and body.len <= 32 and body[body.len - 1] == ':';
}

fn usageLineDocAlloc(builder: pretty.Builder, indent: usize, body: []const u8, styles: UsageTextStyles) !pretty.Doc {
    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    if (indent > 0) try parts.append(builder.allocator, try builder.spaces(indent));
    try parts.append(builder.allocator, try builder.styledText(styles.usage_label, "usage"));
    try parts.append(builder.allocator, try builder.punct(":"));

    const rest = std.mem.trim(u8, body["usage:".len..], " \t");
    if (rest.len > 0) {
        try parts.append(builder.allocator, builder.text(" "));
        try parts.append(builder.allocator, try builder.nest(indent + 2, try builder.styledWords(styles.command, rest)));
    }
    return try builder.group(try builder.concat(parts.items));
}

fn sectionLineDocAlloc(builder: pretty.Builder, body: []const u8, styles: UsageTextStyles) !pretty.Doc {
    return try builder.group(try builder.concat(&.{
        try builder.styledText(styles.section, body[0 .. body.len - 1]),
        try builder.punct(":"),
    }));
}

fn columnLineDocAlloc(
    builder: pretty.Builder,
    indent: usize,
    body: []const u8,
    gap: ColumnGap,
    styles: UsageTextStyles,
) !pretty.Doc {
    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    const left = body[0..gap.start];
    const right = std.mem.trim(u8, body[gap.end..], " \t");
    const gap_width = gap.end - gap.start;

    if (indent > 0) try parts.append(builder.allocator, try builder.spaces(indent));
    try parts.append(builder.allocator, try builder.styledText(columnLeftStyle(left, styles), left));
    try parts.append(builder.allocator, try builder.spaces(gap_width));
    try parts.append(builder.allocator, try builder.nest(indent + left.len + gap_width, try builder.words(right)));
    return try builder.group(try builder.concat(parts.items));
}

pub fn wordLineDocAlloc(
    builder: pretty.Builder,
    indent: usize,
    style: ?pretty.Style,
    body: []const u8,
) !pretty.Doc {
    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    if (indent > 0) try parts.append(builder.allocator, try builder.spaces(indent));
    const words = if (style) |resolved_style|
        try builder.styledWords(resolved_style, body)
    else
        try builder.words(body);
    try parts.append(builder.allocator, try builder.nest(indent, words));
    return try builder.group(try builder.concat(parts.items));
}

const ColumnGap = struct {
    start: usize,
    end: usize,
};

fn columnGap(body: []const u8) ?ColumnGap {
    var index: usize = 0;
    while (index < body.len) : (index += 1) {
        if (body[index] != ' ') continue;
        const start = index;
        while (index < body.len and body[index] == ' ') : (index += 1) {}
        if (index - start >= 2 and start > 0 and index < body.len) return .{
            .start = start,
            .end = index,
        };
    }
    return null;
}

fn inferredOptionGap(body: []const u8) ?ColumnGap {
    if (!std.mem.startsWith(u8, body, "-")) return null;

    var index: usize = 0;
    var boundary: ?usize = null;
    while (index < body.len) {
        while (index < body.len and body[index] == ' ') : (index += 1) {}
        if (index >= body.len) return null;

        const word_start = index;
        while (index < body.len and body[index] != ' ') : (index += 1) {}
        const word = body[word_start..index];

        if (isFlagWord(word) or (boundary != null and isMetavarWord(word))) {
            boundary = index;
            continue;
        }

        if (boundary) |start| {
            if (start < word_start) return .{
                .start = start,
                .end = word_start,
            };
        }
        return null;
    }
    return null;
}

fn isFlagWord(word: []const u8) bool {
    return word.len > 1 and std.mem.startsWith(u8, word, "-");
}

fn isMetavarWord(word: []const u8) bool {
    if (word.len == 0) return false;
    var has_upper = false;
    for (word) |byte| switch (byte) {
        'A'...'Z' => has_upper = true,
        '0'...'9',
        '_',
        '-',
        '|',
        '<',
        '>',
        => {},
        else => return false,
    };
    return has_upper;
}

fn leadingSpaces(line: []const u8) usize {
    var index: usize = 0;
    while (index < line.len and line[index] == ' ') : (index += 1) {}
    return index;
}

fn columnLeftStyle(left: []const u8, styles: UsageTextStyles) pretty.Style {
    if (std.mem.startsWith(u8, left, "-")) return styles.flag;
    if (std.mem.startsWith(u8, left, "tiny ")) return styles.command;
    return styles.column_left;
}

fn renderUsageTextAlloc(allocator: std.mem.Allocator, usage_text: []const u8, options: UsageTextOptions) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const builder = pretty.Builder.init(arena_state.allocator());
    const doc = try docAlloc(builder, usage_text, options.styles);
    return try pretty.renderAlloc(allocator, doc, options.layout);
}

test "usage text renders through pretty plain and colored output" {
    const usage_text =
        \\usage: tiny test [--filter SUBSTRING] [--timings] [PATH ...]
        \\
        \\Options:
        \\  --filter SUBSTRING  Only run tests whose name contains SUBSTRING.
        \\  -h, --help          Print this message.
    ;

    const plain = try renderUsageTextAlloc(std.testing.allocator, usage_text, .{ .layout = .{ .width = 88 } });
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "usage: tiny test") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Options:\n") != null);

    const colored = try renderUsageTextAlloc(std.testing.allocator, usage_text, .{ .layout = .{ .width = 88, .color = .ansi } });
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "tiny test") != null);
}

test "usage text wraps option columns with pretty continuation indent" {
    const usage_text =
        \\Options:
        \\  --long-option-name  Alpha beta gamma delta epsilon
    ;

    const rendered = try renderUsageTextAlloc(std.testing.allocator, usage_text, .{ .layout = .{ .width = 34 } });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\Options:
        \\  --long-option-name  Alpha beta
        \\                      gamma delta
        \\                      epsilon
        \\
    , rendered);
}

test "usage text reflows top-level prose paragraphs" {
    const usage_text =
        \\First sentence split
        \\across source lines.
        \\This longer prose line ends with a colon:
        \\
        \\Options:
        \\  --flag  Keep option lines separate.
    ;

    const rendered = try renderUsageTextAlloc(std.testing.allocator, usage_text, .{ .layout = .{ .width = 120 } });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\First sentence split across source lines. This longer prose line ends with a colon:
        \\
        \\Options:
        \\  --flag  Keep option lines separate.
        \\
    , rendered);
}

test "usage text preserves indented bullets as prose" {
    const usage_text =
        \\Items:
        \\  - alpha beta gamma
    ;

    const rendered = try renderUsageTextAlloc(std.testing.allocator, usage_text, .{ .layout = .{ .width = 12 } });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\Items:
        \\  - alpha
        \\  beta gamma
        \\
    , rendered);
}
