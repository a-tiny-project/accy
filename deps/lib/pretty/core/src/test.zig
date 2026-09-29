const namespace = @import("root.zig");
const pretty = namespace;
const std = @import("std");
const types = @import("types.zig");
const builder_product = @import("builder.zig");
const render = @import("render.zig");

const json = namespace.json;
const compact = namespace.compact;
const diagnostic = namespace.diagnostic;
const Doc = namespace.Doc;
const WriteState = namespace.WriteState;
const softline = namespace.softline;
const softbreak = namespace.softbreak;
const hardline = namespace.hardline;
const Builder = namespace.Builder;
const FlatFitWriter = namespace.FlatFitWriter;
const renderAlloc = namespace.renderAlloc;
const writeWithState = namespace.writeWithState;
test {
    _ = @import("compact/test.zig");
    _ = @import("json/test.zig");
    _ = @import("stream.zig");
}

test "pretty package namespace" {
    std.testing.refAllDecls(types);
    std.testing.refAllDecls(builder_product);
    std.testing.refAllDecls(render);
    std.testing.refAllDecls(json);
    std.testing.refAllDecls(compact);
    std.testing.refAllDecls(diagnostic);
}
test "group keeps soft breaks flat when it fits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const builder = Builder.init(arena);

    const body = try builder.concat(&.{
        builder.text("["),
        try builder.nest(2, try builder.concat(&.{
            softbreak,
            builder.text("alpha"),
            builder.text(","),
            softline,
            builder.text("beta"),
        })),
        softbreak,
        builder.text("]"),
    });
    const doc = try builder.group(body);

    const rendered = try renderAlloc(std.testing.allocator, doc, .{ .width = 20 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("[alpha, beta]", rendered);
}

test "group breaks soft breaks when it does not fit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const builder = Builder.init(arena);

    const body = try builder.concat(&.{
        builder.text("["),
        try builder.nest(2, try builder.concat(&.{
            softbreak,
            builder.text("alpha"),
            builder.text(","),
            softline,
            builder.text("beta"),
        })),
        softbreak,
        builder.text("]"),
    });
    const doc = try builder.group(body);

    const rendered = try renderAlloc(std.testing.allocator, doc, .{ .width = 8 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\[
        \\  alpha,
        \\  beta
        \\]
    , rendered);
}

test "group fit includes the same-line continuation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const builder = Builder.init(arena_state.allocator());

    const grouped = try builder.group(try builder.concat(&.{
        builder.text("abc"),
        softline,
        builder.text("de"),
    }));
    const doc = try builder.concat(&.{ grouped, builder.text("XY") });
    const rendered = try renderAlloc(std.testing.allocator, doc, .{ .width = 6 });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("abc\ndeXY", rendered);
}

test "unavoidable width overflow remains renderable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const builder = Builder.init(arena_state.allocator());

    const atom = try builder.concat(&.{
        try builder.group(try builder.concat(&.{
            builder.text("a"),
            softline,
            builder.text("b"),
        })),
        builder.text("1234567"),
    });
    const atom_rendered = try renderAlloc(std.testing.allocator, atom, .{ .width = 6 });
    defer std.testing.allocator.free(atom_rendered);
    try std.testing.expectEqualStrings("a\nb1234567", atom_rendered);

    const contextual = try builder.group(try builder.concat(&.{
        builder.text("a"),
        softline,
        builder.text("b"),
    }));
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeWithState(&out.writer, contextual, .{ .width = 6 }, .{ .column = 8 });
    try std.testing.expectEqualStrings("a\nb", out.written());
}

test "hardline stays hard inside a flat group" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const builder = Builder.init(arena);

    const doc = try builder.group(try builder.concat(&.{
        builder.text("first"),
        softline,
        builder.text("middle"),
        hardline,
        builder.text("second"),
    }));

    const rendered = try renderAlloc(std.testing.allocator, doc, .{ .width = 80 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\first
        \\middle
        \\second
    , rendered);
}

test "sibling hardline ends group continuation fit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const builder = Builder.init(arena_state.allocator());

    const grouped = try builder.group(try builder.concat(&.{
        builder.text("abc"),
        softline,
        builder.text("de"),
    }));
    const doc = try builder.concat(&.{ grouped, hardline, builder.text("XY") });
    const rendered = try renderAlloc(std.testing.allocator, doc, .{ .width = 6 });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("abc de\nXY", rendered);
}

test "continuation text fits its prefix before a line reset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const builder = Builder.init(arena_state.allocator());

    const grouped = try builder.group(try builder.concat(&.{
        builder.text("abc"),
        softline,
    }));
    const doc = try builder.concat(&.{ grouped, builder.text("XY12\n") });
    const rendered = try renderAlloc(std.testing.allocator, doc, .{ .width = 6 });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("abc\nXY12\n", rendered);
}

test "styled docs emit ANSI without changing fit width" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const builder = Builder.init(arena);

    const doc = try builder.group(try builder.concat(&.{
        builder.text("a"),
        softline,
        try builder.style(.keyword, builder.text("bc")),
    }));

    const plain = try renderAlloc(std.testing.allocator, doc, .{ .width = 4 });
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("a bc", plain);

    const colored = try renderAlloc(std.testing.allocator, doc, .{ .width = 4, .color = .ansi });
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[1;94m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "a \x1b[1;94mbc\x1b[0m") != null);
}

test "nested styled docs restore the outer ANSI style" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const builder = Builder.init(arena);

    const doc = try builder.style(.keyword, try builder.concat(&.{
        builder.text("a "),
        try builder.styledText(.number, "42"),
        builder.text(" c"),
    }));

    const plain = try renderAlloc(std.testing.allocator, doc, .{ .width = 80 });
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("a 42 c", plain);

    const colored = try renderAlloc(std.testing.allocator, doc, .{ .width = 80, .color = .ansi });
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(
        u8,
        colored,
        "\x1b[1;94ma \x1b[35m42\x1b[0m\x1b[1;94m c\x1b[0m",
    ) != null);
}

test "builder helpers standardize styled punctuation and joins" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const builder = Builder.init(arena);

    const items = [_]Doc{
        try builder.styledText(.name, "alpha"),
        try builder.styledFmt(.number, "{d}", .{42}),
    };
    const doc = try builder.group(try builder.concat(&.{
        try builder.spaces(2),
        try builder.punct("["),
        try builder.join(&items, try builder.concat(&.{
            try builder.punct(","),
            softline,
        })),
        try builder.punct("]"),
    }));

    const plain = try renderAlloc(std.testing.allocator, doc, .{ .width = 80 });
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("  [alpha, 42]", plain);

    const colored = try renderAlloc(std.testing.allocator, doc, .{ .width = 80, .color = .ansi });
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[96malpha\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[2m[\x1b[0m") != null);
}

test "word docs wrap greedily at soft boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const builder = Builder.init(arena);

    const doc = try builder.words("alpha beta gamma");
    const rendered = try renderAlloc(std.testing.allocator, doc, .{ .width = 10 });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\alpha beta
        \\gamma
    , rendered);
}

test "word docs preserve explicit hard lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const builder = Builder.init(arena);

    const doc = try builder.words("alpha\nbeta gamma");
    const rendered = try renderAlloc(std.testing.allocator, doc, .{ .width = 80 });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\alpha
        \\beta gamma
    , rendered);
}

test "FlatFitWriter rejects position resets and overflow" {
    var fit = FlatFitWriter.init(5);
    try fit.writer.writeAll("abc");
    try std.testing.expectEqual(@as(usize, 3), fit.count);

    try std.testing.expectError(error.WriteFailed, fit.writer.writeAll("\n"));
    try std.testing.expectError(error.WriteFailed, fit.writer.writeAll("def"));
    try std.testing.expectEqual(@as(usize, 3), fit.count);

    var carriage_return = FlatFitWriter.init(5);
    try std.testing.expectError(
        error.WriteFailed,
        carriage_return.writer.writeAll("\r"),
    );
    try std.testing.expectEqual(@as(usize, 0), carriage_return.count);

    var carriage_return_line_feed = FlatFitWriter.init(5);
    try std.testing.expectError(
        error.WriteFailed,
        carriage_return_line_feed.writer.writeAll("\r\n"),
    );
    try std.testing.expectEqual(@as(usize, 0), carriage_return_line_feed.count);
}

test "writeWithState uses caller column and break indentation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const builder = Builder.init(arena);

    const doc = try builder.group(try builder.concat(&.{
        builder.text("alpha"),
        softline,
        builder.text("beta"),
    }));

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try out.writer.writeAll("Label: ");
    try writeWithState(&out.writer, doc, .{ .width = 12 }, .{ .column = 7, .indent = 7 });
    const rendered = try out.toOwnedSlice();
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\Label: alpha
        \\       beta
    , rendered);
}

test "nested indentation rejects contextual overflow before nested output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const builder = Builder.init(arena_state.allocator());

    const nested = try builder.nest(
        std.math.maxInt(usize),
        builder.text("nested"),
    );
    var maximum = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer maximum.deinit();
    try writeWithState(&maximum.writer, nested, .{}, .{});
    try std.testing.expectEqualStrings("nested", maximum.written());

    const contextual = try builder.concat(&.{
        builder.text("outer"),
        nested,
    });
    var overflow = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer overflow.deinit();
    const expected: pretty.RenderError = error.IndentationOverflow;
    try std.testing.expectError(
        expected,
        writeWithState(&overflow.writer, contextual, .{}, .{ .indent = 1 }),
    );
    try std.testing.expectEqualStrings("outer", overflow.written());
}

test "embedded text line reset composes with later group" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const builder = Builder.init(arena_state.allocator());

    const suffix = try builder.group(try builder.concat(&.{
        softline,
        builder.text("c"),
    }));
    const doc = try builder.concat(&.{
        builder.text("a\nb"),
        suffix,
    });

    const rendered = try renderAlloc(std.testing.allocator, doc, .{ .width = 3 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("a\nb c", rendered);
}

fn expectResetComposition(
    prefix: []const u8,
    tail: []const u8,
    width: usize,
    state: pretty.WriteState,
    expected: []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const builder = Builder.init(arena_state.allocator());
    const suffix = try builder.group(try builder.concat(&.{
        softline,
        builder.text(tail),
    }));
    const doc = try builder.concat(&.{ builder.text(prefix), suffix });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeWithState(&out.writer, doc, .{ .width = width }, state);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "CR LF and CRLF reset caller position" {
    try expectResetComposition(
        "a\r\nb",
        "c",
        3,
        .{},
        "a\r\nb c",
    );
    try expectResetComposition(
        "abcd\r",
        "xy",
        4,
        .{},
        "abcd\r xy",
    );
    try expectResetComposition(
        "\n",
        "abcdef",
        8,
        .{ .column = 7, .indent = 3 },
        "\n abcdef",
    );
}

test "newline-bearing flat alternatives stay broken" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const builder = Builder.init(arena_state.allocator());

    const text_doc = try builder.group(try builder.concat(&.{
        builder.text("ab\ncd"),
        softline,
        builder.text("e"),
    }));
    const text_rendered = try renderAlloc(
        std.testing.allocator,
        text_doc,
        .{ .width = 10 },
    );
    defer std.testing.allocator.free(text_rendered);
    try std.testing.expectEqualStrings("ab\ncd\ne", text_rendered);

    const line_doc = try builder.group(.{ .line = "a\nb" });
    const line_rendered = try renderAlloc(
        std.testing.allocator,
        line_doc,
        .{ .width = 10 },
    );
    defer std.testing.allocator.free(line_rendered);
    try std.testing.expectEqualStrings("\n", line_rendered);
}
