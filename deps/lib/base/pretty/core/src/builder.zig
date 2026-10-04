const std = @import("std");
const types = @import("types.zig");

const Doc = types.Doc;
const Style = types.Style;
const hardline = types.hardline;
const softline = types.softline;

pub const Builder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn empty(_: Builder) Doc {
        return .empty;
    }

    pub fn text(_: Builder, bytes: []const u8) Doc {
        if (bytes.len == 0) return .empty;
        return .{ .text = bytes };
    }

    pub fn textFmt(
        self: Builder,
        comptime fmt: []const u8,
        args: anytype,
    ) std.mem.Allocator.Error!Doc {
        return .{ .text = try std.fmt.allocPrint(self.allocator, fmt, args) };
    }

    pub fn spaces(
        self: Builder,
        amount: usize,
    ) std.mem.Allocator.Error!Doc {
        if (amount == 0) return self.empty();
        const bytes = try self.allocator.alloc(u8, amount);
        @memset(bytes, ' ');
        return self.text(bytes);
    }

    pub fn concat(
        self: Builder,
        parts: []const Doc,
    ) std.mem.Allocator.Error!Doc {
        if (parts.len == 0) return .empty;
        if (parts.len == 1) return parts[0];
        return .{ .concat = try self.allocator.dupe(Doc, parts) };
    }

    pub fn nest(
        self: Builder,
        amount: usize,
        doc: Doc,
    ) std.mem.Allocator.Error!Doc {
        if (amount == 0) return doc;
        const owned = try self.allocator.create(Doc);
        owned.* = doc;
        return .{ .nest = .{ .amount = amount, .doc = owned } };
    }

    pub fn group(
        self: Builder,
        doc: Doc,
    ) std.mem.Allocator.Error!Doc {
        const owned = try self.allocator.create(Doc);
        owned.* = doc;
        return .{ .group = owned };
    }

    pub fn style(
        self: Builder,
        style_kind: Style,
        doc: Doc,
    ) std.mem.Allocator.Error!Doc {
        if (style_kind == .plain) return doc;
        const owned = try self.allocator.create(Doc);
        owned.* = doc;
        return .{ .styled = .{ .style = style_kind, .doc = owned } };
    }

    pub fn styledText(
        self: Builder,
        style_kind: Style,
        bytes: []const u8,
    ) std.mem.Allocator.Error!Doc {
        return try self.style(style_kind, self.text(bytes));
    }

    pub fn styledFmt(
        self: Builder,
        style_kind: Style,
        comptime fmt: []const u8,
        args: anytype,
    ) std.mem.Allocator.Error!Doc {
        return try self.style(style_kind, try self.textFmt(fmt, args));
    }

    pub fn words(
        self: Builder,
        bytes: []const u8,
    ) std.mem.Allocator.Error!Doc {
        var parts: std.ArrayListUnmanaged(Doc) = .empty;
        defer parts.deinit(self.allocator);

        var line_start = true;
        var index: usize = 0;
        while (index < bytes.len) {
            while (index < bytes.len) : (index += 1) {
                switch (bytes[index]) {
                    ' ', '\t', '\r' => {},
                    '\n' => {
                        try parts.append(self.allocator, hardline);
                        line_start = true;
                    },
                    else => break,
                }
            }

            if (index >= bytes.len) break;

            const word_start = index;
            while (index < bytes.len and bytes[index] != ' ' and bytes[index] != '\t' and bytes[index] != '\r' and bytes[index] != '\n') : (index += 1) {}
            const word = self.text(bytes[word_start..index]);

            if (line_start) {
                try parts.append(self.allocator, word);
                line_start = false;
            } else {
                try parts.append(self.allocator, try self.group(try self.concat(&.{
                    softline,
                    word,
                })));
            }
        }

        return try self.concat(parts.items);
    }

    pub fn styledWords(
        self: Builder,
        style_kind: Style,
        bytes: []const u8,
    ) std.mem.Allocator.Error!Doc {
        return try self.style(style_kind, try self.words(bytes));
    }

    pub fn punct(
        self: Builder,
        bytes: []const u8,
    ) std.mem.Allocator.Error!Doc {
        return try self.styledText(.punctuation, bytes);
    }

    pub fn join(
        self: Builder,
        items: []const Doc,
        separator: Doc,
    ) std.mem.Allocator.Error!Doc {
        if (items.len == 0) return self.empty();
        if (items.len == 1) return items[0];

        const parts = try self.allocator.alloc(Doc, items.len * 2 - 1);
        var index: usize = 0;
        for (items, 0..) |item, item_index| {
            if (item_index != 0) {
                parts[index] = separator;
                index += 1;
            }
            parts[index] = item;
            index += 1;
        }
        return .{ .concat = parts };
    }
};
