const std = @import("std");
const pretty = @import("pretty");
const types = @import("types.zig");

const ErrorTextOptions = types.ErrorTextOptions;

pub fn docAlloc(
    builder: pretty.Builder,
    prefix: []const u8,
    text: []const u8,
    prefix_style: pretty.Style,
) !pretty.Doc {
    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    try parts.append(builder.allocator, try builder.styledText(prefix_style, prefix));
    try parts.append(builder.allocator, try builder.punct(":"));
    if (text.len > 0) {
        try parts.append(builder.allocator, builder.text(" "));
        try parts.append(builder.allocator, try builder.nest(prefix.len + 2, try builder.words(text)));
    }
    try parts.append(builder.allocator, pretty.hardline);
    return try builder.concat(parts.items);
}

fn renderErrorTextAlloc(allocator: std.mem.Allocator, prefix: []const u8, text: []const u8, options: ErrorTextOptions) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const builder = pretty.Builder.init(arena_state.allocator());
    const doc = try docAlloc(builder, prefix, text, options.prefix_style);
    return try pretty.renderAlloc(allocator, doc, options.layout);
}

test "error text renders through pretty plain and colored output" {
    const plain = try renderErrorTextAlloc(
        std.testing.allocator,
        "tiny check",
        "missing PATH argument",
        .{ .layout = .{ .width = 88 } },
    );
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("tiny check: missing PATH argument\n", plain);

    const colored = try renderErrorTextAlloc(
        std.testing.allocator,
        "tiny check",
        "missing PATH argument",
        .{ .layout = .{ .width = 88, .color = .ansi } },
    );
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
}

test "error text wraps with hanging message indentation" {
    const rendered = try renderErrorTextAlloc(
        std.testing.allocator,
        "tool",
        "alpha beta gamma delta epsilon",
        .{ .layout = .{ .width = 18 } },
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\tool: alpha beta
        \\      gamma delta
        \\      epsilon
        \\
    , rendered);
}

test "warning text uses warning prefix style" {
    const plain = try renderErrorTextAlloc(
        std.testing.allocator,
        "warning",
        "skipping malformed record",
        .{
            .layout = .{ .width = 88 },
            .prefix_style = .warning,
        },
    );
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("warning: skipping malformed record\n", plain);

    const colored = try renderErrorTextAlloc(
        std.testing.allocator,
        "warning",
        "skipping malformed record",
        .{
            .layout = .{ .width = 88, .color = .ansi },
            .prefix_style = .warning,
        },
    );
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[1;33mwarning") != null);
}
