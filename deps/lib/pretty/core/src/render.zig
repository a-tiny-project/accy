const std = @import("std");
const position = @import("position.zig");
const types = @import("types.zig");

const ColorMode = types.ColorMode;
const Doc = types.Doc;
const LayoutOptions = types.LayoutOptions;
const Style = types.Style;
const WriteState = types.WriteState;

pub const Error = error{IndentationOverflow};

const WriteError = Error || std.Io.Writer.Error;

pub const FlatFitWriter = struct {
    writer: std.Io.Writer,
    limit: usize,
    count: usize = 0,

    pub fn init(limit: usize) FlatFitWriter {
        return .{
            .writer = .{
                .vtable = &.{ .drain = drain },
                .buffer = &.{},
            },
            .limit = limit,
        };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *FlatFitWriter = @alignCast(@fieldParentPtr("writer", writer));
        try self.accept(writer.buffered());
        writer.end = 0;

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.accept(bytes);
            consumed += bytes.len;
        }

        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.accept(pattern);
            consumed += pattern.len;
        }
        return consumed;
    }

    fn accept(self: *FlatFitWriter, bytes: []const u8) std.Io.Writer.Error!void {
        var budget = self.limit -| self.count;
        if (!position.consumeFlatBytes(bytes, &budget)) return error.WriteFailed;
        self.count = self.limit - budget;
    }
};

pub fn renderAlloc(
    allocator: std.mem.Allocator,
    doc: Doc,
    options: LayoutOptions,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try write(&out.writer, doc, options);
    return try out.toOwnedSlice();
}

pub fn write(
    writer: *std.Io.Writer,
    doc: Doc,
    options: LayoutOptions,
) WriteError!void {
    try writeWithState(writer, doc, options, .{});
}

pub fn writeWithState(
    writer: *std.Io.Writer,
    doc: Doc,
    options: LayoutOptions,
    state: WriteState,
) WriteError!void {
    var renderer = Renderer{
        .writer = writer,
        .width = options.width,
        .color = options.color,
        .col = state.column,
    };
    try renderer.writeDoc(doc, state.indent, .broken, null);
}

const Mode = enum {
    flat,
    broken,
};

const Pending = struct {
    docs: []const Doc,
    mode: Mode,
    next: ?*const Pending,
};

const LineFit = enum {
    continued,
    broke,
    overflowed,
};

const Renderer = struct {
    writer: *std.Io.Writer,
    width: usize,
    color: ColorMode,
    col: usize = 0,
    active_style: ?Style = null,

    fn writeDoc(
        self: *Renderer,
        doc: Doc,
        indent: usize,
        mode: Mode,
        pending: ?*const Pending,
    ) WriteError!void {
        switch (doc) {
            .empty => {},
            .text => |bytes| {
                try self.writer.writeAll(bytes);
                self.col = position.Summary.fromBytes(bytes)
                    .advance(.{ .column = self.col }).column;
            },
            .concat => |parts| {
                for (parts, 0..) |part, index| {
                    const rest = Pending{
                        .docs = parts[index + 1 ..],
                        .mode = mode,
                        .next = pending,
                    };
                    try self.writeDoc(part, indent, mode, &rest);
                }
            },
            .line => |flat_text| {
                if (mode == .flat) {
                    try self.writer.writeAll(flat_text);
                    self.col = position.Summary.fromBytes(flat_text)
                        .advance(.{ .column = self.col }).column;
                    return;
                }
                try self.writer.writeByte('\n');
                try self.writer.splatByteAll(' ', indent);
                self.col = indent;
            },
            .hardline => {
                try self.writer.writeByte('\n');
                try self.writer.splatByteAll(' ', indent);
                self.col = indent;
            },
            .nest => |nested| {
                const nested_indent = std.math.add(usize, indent, nested.amount) catch {
                    return error.IndentationOverflow;
                };
                try self.writeDoc(nested.doc.*, nested_indent, mode, pending);
            },
            .group => |grouped| {
                const child_mode: Mode = if (mode == .flat or self.fits(grouped.*, pending))
                    .flat
                else
                    .broken;
                try self.writeDoc(grouped.*, indent, child_mode, pending);
            },
            .styled => |styled| {
                if (styled.style == .plain) {
                    try self.writeDoc(styled.doc.*, indent, mode, pending);
                    return;
                }
                const previous_style = self.active_style;
                try self.writeStyleStart(styled.style);
                self.active_style = styled.style;
                errdefer self.active_style = previous_style;
                try self.writeDoc(styled.doc.*, indent, mode, pending);
                try self.writeStyleEnd(previous_style);
                self.active_style = previous_style;
            },
        }
    }

    fn fits(self: Renderer, doc: Doc, pending: ?*const Pending) bool {
        return fitsCandidate(doc, pending, self.width -| self.col);
    }

    fn writeStyleStart(self: *Renderer, style_kind: Style) std.Io.Writer.Error!void {
        if (self.color != .ansi or style_kind == .plain) return;
        try self.writer.writeAll(ansiCodeFor(style_kind));
    }

    fn writeStyleEnd(self: *Renderer, previous_style: ?Style) std.Io.Writer.Error!void {
        if (self.color != .ansi) return;
        try self.writer.writeAll(ansi_reset);
        if (previous_style) |style_kind| {
            if (style_kind != .plain) try self.writer.writeAll(ansiCodeFor(style_kind));
        }
    }
};

fn fitsCandidate(doc: Doc, pending: ?*const Pending, budget: usize) bool {
    var remaining = budget;
    if (!fitsWithin(doc, &remaining)) return false;
    return fitsPending(pending, &remaining);
}

fn fitsPending(initial: ?*const Pending, budget: *usize) bool {
    var pending = initial;
    while (pending) |work| : (pending = work.next) {
        for (work.docs) |doc| {
            switch (fitsLine(doc, work.mode, budget)) {
                .continued => {},
                .broke => return true,
                .overflowed => return false,
            }
        }
    }
    return true;
}

fn fitsLine(doc: Doc, mode: Mode, budget: *usize) LineFit {
    return switch (doc) {
        .empty => .continued,
        .text => |bytes| consumeLineBytes(bytes, budget),
        .concat => |parts| blk: {
            for (parts) |part| {
                const result = fitsLine(part, mode, budget);
                if (result != .continued) break :blk result;
            }
            break :blk .continued;
        },
        .line => |flat_text| if (mode == .flat)
            consumeLineBytes(flat_text, budget)
        else
            .broke,
        .hardline => .broke,
        .nest => |nested| fitsLine(nested.doc.*, mode, budget),
        .group => |grouped| fitsLine(grouped.*, mode, budget),
        .styled => |styled| fitsLine(styled.doc.*, mode, budget),
    };
}

fn consumeLineBytes(bytes: []const u8, budget: *usize) LineFit {
    const prefix = bytes[0..@min(bytes.len, budget.* +| 1)];
    if (std.mem.findAny(u8, prefix, "\r\n")) |index| {
        budget.* -= index;
        return .broke;
    }
    if (bytes.len > budget.*) return .overflowed;
    budget.* -= bytes.len;
    return .continued;
}

test "line lookahead preserves reset boundaries and overflow budgets" {
    var bytes: [129]u8 = undefined;
    for (0..bytes.len + 1) |length| {
        for (0..length + 1) |reset_index| {
            for ([_]u8{ '\r', '\n' }) |reset| {
                @memset(&bytes, 'x');
                if (reset_index < length) bytes[reset_index] = reset;
                const limits = [_]usize{
                    0, reset_index -| 1, reset_index, length, std.math.maxInt(usize),
                };
                for (limits) |limit| {
                    var budget = limit;
                    const cells = @min(length, reset_index);
                    const expected: LineFit = if (cells > limit)
                        .overflowed
                    else if (reset_index < length)
                        .broke
                    else
                        .continued;
                    try std.testing.expectEqual(
                        expected,
                        consumeLineBytes(bytes[0..length], &budget),
                    );
                    const remaining = if (expected == .overflowed) limit else limit - cells;
                    try std.testing.expectEqual(remaining, budget);
                }
            }
        }
    }
}

test "payload rendering preserves continuation resets at the margin without allocation" {
    var payload: [256]u8 = undefined;
    var output: [260]u8 = undefined;
    const parts = [_]Doc{ .{ .text = "key" }, types.softline };
    const grouped: Doc = .{ .concat = &parts };
    const docs = [_]Doc{ .{ .group = &grouped }, .{ .text = &payload } };
    for ([_]usize{ 0, 1, 75, 76, 77, 255, 256 }) |reset_index| {
        for ([_]u8{ '\r', '\n' }) |reset| {
            @memset(&payload, 'x');
            if (reset_index < payload.len) payload[reset_index] = reset;
            var writer: std.Io.Writer = .fixed(&output);
            try write(&writer, .{ .concat = &docs }, .{ .width = 80 });
            const prefix = if (reset_index <= 76) "key " else "key\n";
            try std.testing.expectEqualStrings(prefix, output[0..4]);
            try std.testing.expectEqualSlices(u8, &payload, output[4..]);
            try std.testing.expectEqual(output.len, writer.end);
        }
    }
}

fn fitsWithin(doc: Doc, budget: *usize) bool {
    return switch (doc) {
        .empty => true,
        .text => |bytes| position.consumeFlatBytes(bytes, budget),
        .concat => |parts| blk: {
            for (parts) |part| {
                if (!fitsWithin(part, budget)) break :blk false;
            }
            break :blk true;
        },
        .line => |flat_text| position.consumeFlatBytes(flat_text, budget),
        .hardline => false,
        .nest => |nested| fitsWithin(nested.doc.*, budget),
        .group => |grouped| fitsWithin(grouped.*, budget),
        .styled => |styled| fitsWithin(styled.doc.*, budget),
    };
}

const ansi_reset = "\x1b[0m";

fn ansiCodeFor(style_kind: Style) []const u8 {
    return switch (style_kind) {
        .plain => "",
        .title => "\x1b[1;96m",
        .keyword => "\x1b[1;94m",
        .name => "\x1b[96m",
        .value => "\x1b[32m",
        .string => "\x1b[32m",
        .number => "\x1b[35m",
        .type_name => "\x1b[33m",
        .attribute => "\x1b[36m",
        .block_label => "\x1b[1;35m",
        .source => "\x1b[37m",
        .punctuation => "\x1b[2m",
        .muted => "\x1b[2m",
        .accent => "\x1b[1m",
        .warning => "\x1b[1;33m",
        .danger => "\x1b[1;31m",
    };
}
