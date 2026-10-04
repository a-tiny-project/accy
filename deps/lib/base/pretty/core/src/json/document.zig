const std = @import("std");
const escape = @import("escape.zig");
const pretty = @import("../root.zig");

const Builder = pretty.Builder;
const Doc = pretty.Doc;
const LayoutOptions = pretty.LayoutOptions;
const WriteState = pretty.WriteState;
const softbreak = pretty.softbreak;
const softline = pretty.softline;

pub fn valueDoc(builder: Builder, value: std.json.Value) anyerror!Doc {
    return switch (value) {
        .null => try builder.styledText(.keyword, "null"),
        .bool => |item| try builder.styledText(.keyword, if (item) "true" else "false"),
        .integer => |item| try builder.styledFmt(.number, "{d}", .{item}),
        .float => |item| try builder.styledFmt(.number, "{d}", .{item}),
        .number_string => |item| try builder.styledText(.number, item),
        .string => |item| try builder.styledText(.string, try escape.stringAlloc(builder.allocator, item)),
        .array => |items| try arrayDoc(builder, items.items),
        .object => |object| try objectDoc(builder, object),
    };
}

pub fn renderValueAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    options: LayoutOptions,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const builder = Builder.init(arena_state.allocator());
    return try pretty.renderAlloc(allocator, try valueDoc(builder, value), options);
}

pub fn writeValue(
    writer: anytype,
    allocator: std.mem.Allocator,
    value: std.json.Value,
    options: LayoutOptions,
) !void {
    try writeValueWithState(writer, allocator, value, options, .{});
}

pub fn writeValueWithState(
    writer: anytype,
    allocator: std.mem.Allocator,
    value: std.json.Value,
    options: LayoutOptions,
    state: WriteState,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const builder = Builder.init(arena_state.allocator());
    try pretty.writeWithState(writer, try valueDoc(builder, value), options, state);
}

fn arrayDoc(builder: Builder, items: []const std.json.Value) anyerror!Doc {
    if (items.len == 0) return try builder.concat(&.{
        try builder.punct("["),
        try builder.punct("]"),
    });

    const docs = try builder.allocator.alloc(Doc, items.len);
    for (items, 0..) |item, index| docs[index] = try valueDoc(builder, item);

    return try builder.group(try builder.concat(&.{
        try builder.punct("["),
        try builder.nest(2, try builder.concat(&.{
            softbreak,
            try builder.join(docs, try builder.concat(&.{
                try builder.punct(","),
                softline,
            })),
        })),
        softbreak,
        try builder.punct("]"),
    }));
}

fn objectDoc(builder: Builder, object: std.json.ObjectMap) anyerror!Doc {
    if (object.count() == 0) return try builder.concat(&.{
        try builder.punct("{"),
        try builder.punct("}"),
    });

    var fields: std.ArrayList(Doc) = .empty;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try fields.append(builder.allocator, try builder.concat(&.{
            try builder.styledText(.string, try escape.stringAlloc(builder.allocator, entry.key_ptr.*)),
            try builder.punct(":"),
            builder.text(" "),
            try valueDoc(builder, entry.value_ptr.*),
        }));
    }

    return try builder.group(try builder.concat(&.{
        try builder.punct("{"),
        try builder.nest(2, try builder.concat(&.{
            softbreak,
            try builder.join(fields.items, try builder.concat(&.{
                try builder.punct(","),
                softline,
            })),
        })),
        softbreak,
        try builder.punct("}"),
    }));
}
