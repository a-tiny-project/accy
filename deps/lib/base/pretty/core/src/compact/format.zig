const std = @import("std");
const types = @import("types.zig");

const Column = types.Column;
pub const gutter = "  ";
const ellipsis = "\xE2\x80\xA6";
const footer_dash = "\xE2\x80\x94";
pub const footer_tail = " " ++ footer_dash ++
    " use --limit 0 for all, --json for exact records)\n";

pub fn maximumLineBytes(
    columns: []const Column,
    rows: []const []const []const u8,
) error{CapacityOverflow}!usize {
    var content_bytes: usize = 0;
    for (columns, 0..) |column, column_index| {
        var width = rawTruncatedLength(column.header, column.max_width);
        for (rows) |row| {
            const value = if (column_index < row.len) row[column_index] else "";
            width = @max(width, normalizedTruncatedLength(value, column.max_width));
        }
        content_bytes = std.math.add(usize, content_bytes, width) catch
            return error.CapacityOverflow;
    }
    const gutters = if (columns.len == 0) 0 else std.math.mul(
        usize,
        columns.len - 1,
        gutter.len,
    ) catch return error.CapacityOverflow;
    const with_gutters = std.math.add(usize, content_bytes, gutters) catch
        return error.CapacityOverflow;
    return std.math.add(usize, with_gutters, 1) catch error.CapacityOverflow;
}

pub fn footerLength(displayed: usize, total: ?usize) error{CapacityOverflow}!usize {
    const count = total orelse return 0;
    if (count <= displayed) return 0;
    var bytes = "(showing ".len;
    bytes = std.math.add(usize, bytes, decimalLength(displayed)) catch
        return error.CapacityOverflow;
    bytes = std.math.add(usize, bytes, " of ".len) catch
        return error.CapacityOverflow;
    bytes = std.math.add(usize, bytes, decimalLength(count)) catch
        return error.CapacityOverflow;
    return std.math.add(usize, bytes, footer_tail.len) catch error.CapacityOverflow;
}

pub fn measureWidths(
    widths: []usize,
    columns: []const Column,
    rows: []const []const []const u8,
) void {
    std.debug.assert(widths.len == columns.len);
    for (columns, widths, 0..) |column, *width, column_index| {
        width.* = rawTruncatedLength(column.header, column.max_width);
        for (rows) |row| {
            const value = if (column_index < row.len) row[column_index] else "";
            width.* = @max(
                width.*,
                normalizedTruncatedLength(value, column.max_width),
            );
        }
    }
}

pub fn renderInto(
    writer: *std.Io.Writer,
    widths: []const usize,
    columns: []const Column,
    rows: []const []const []const u8,
    total: ?usize,
) std.Io.Writer.Error!void {
    try writeHeaderRow(writer, widths, columns);
    try writeSeparator(writer, widths);
    for (rows) |row| try writeDataRow(writer, widths, columns, row);
    if (total) |count| {
        if (count > rows.len) {
            try writer.print(
                "(showing {d} of {d}{s}",
                .{ rows.len, count, footer_tail },
            );
        }
    }
}

fn writeHeaderRow(
    writer: *std.Io.Writer,
    widths: []const usize,
    columns: []const Column,
) std.Io.Writer.Error!void {
    std.debug.assert(widths.len == columns.len);
    for (columns, 0..) |column, index| {
        if (index != 0) try writer.writeAll(gutter);
        const length = rawTruncatedLength(column.header, column.max_width);
        if (column.alignment == .right) try writeSpaces(writer, widths[index] - length);
        try writeLowerTruncated(writer, column.header, column.max_width);
        if (column.alignment == .left and index + 1 != columns.len) {
            try writeSpaces(writer, widths[index] - length);
        }
    }
    try writer.writeByte('\n');
}

fn writeDataRow(
    writer: *std.Io.Writer,
    widths: []const usize,
    columns: []const Column,
    row: []const []const u8,
) std.Io.Writer.Error!void {
    std.debug.assert(widths.len == columns.len);
    for (columns, 0..) |column, index| {
        if (index != 0) try writer.writeAll(gutter);
        const value = if (index < row.len) row[index] else "";
        const length = normalizedTruncatedLength(value, column.max_width);
        if (column.alignment == .right) try writeSpaces(writer, widths[index] - length);
        try writeNormalizedTruncated(writer, value, column.max_width);
        if (column.alignment == .left and index + 1 != columns.len) {
            try writeSpaces(writer, widths[index] - length);
        }
    }
    try writer.writeByte('\n');
}

fn writeSeparator(
    writer: *std.Io.Writer,
    widths: []const usize,
) std.Io.Writer.Error!void {
    for (widths, 0..) |width, index| {
        if (index != 0) try writer.writeAll(gutter);
        for (0..width) |_| try writer.writeByte('-');
    }
    try writer.writeByte('\n');
}

fn writeSpaces(writer: *std.Io.Writer, count: usize) std.Io.Writer.Error!void {
    for (0..count) |_| try writer.writeByte(' ');
}

fn rawTruncatedLength(value: []const u8, maximum: usize) usize {
    if (value.len <= maximum) return value.len;
    if (maximum <= ellipsis.len) return @min(maximum, ellipsis.len);
    var cut = maximum - ellipsis.len;
    while (cut > 0 and isContinuation(value[cut])) cut -= 1;
    return cut + ellipsis.len;
}

fn normalizedTruncatedLength(value: []const u8, maximum: usize) usize {
    const length = normalizedLength(value);
    if (length <= maximum) return length;
    if (maximum <= ellipsis.len) return @min(maximum, ellipsis.len);
    var cut = maximum - ellipsis.len;
    while (cut > 0 and isContinuation(normalizedByteAt(value, cut))) cut -= 1;
    return cut + ellipsis.len;
}

fn normalizedLength(value: []const u8) usize {
    var length: usize = 0;
    for (value) |byte| {
        if (normalizedByte(byte) != null) length += 1;
    }
    return length;
}

fn normalizedByteAt(value: []const u8, target: usize) u8 {
    var index: usize = 0;
    for (value) |byte| {
        const normalized = normalizedByte(byte) orelse continue;
        if (index == target) return normalized;
        index += 1;
    }
    unreachable;
}

fn normalizedByte(byte: u8) ?u8 {
    return switch (byte) {
        '\t', '\r', '\n' => ' ',
        0...8, 11...12, 14...31, 127 => null,
        else => byte,
    };
}

fn writeLowerTruncated(
    writer: *std.Io.Writer,
    value: []const u8,
    maximum: usize,
) std.Io.Writer.Error!void {
    const length = rawTruncatedLength(value, maximum);
    if (value.len <= maximum) {
        for (value) |byte| try writer.writeByte(std.ascii.toLower(byte));
        return;
    }
    if (maximum <= ellipsis.len) return writer.writeAll(ellipsis[0..length]);
    const prefix = length - ellipsis.len;
    for (value[0..prefix]) |byte| try writer.writeByte(std.ascii.toLower(byte));
    try writer.writeAll(ellipsis);
}

fn writeNormalizedTruncated(
    writer: *std.Io.Writer,
    value: []const u8,
    maximum: usize,
) std.Io.Writer.Error!void {
    const length = normalizedTruncatedLength(value, maximum);
    const normalized_length = normalizedLength(value);
    if (normalized_length <= maximum) return writeNormalizedPrefix(writer, value, length);
    if (maximum <= ellipsis.len) return writer.writeAll(ellipsis[0..length]);
    try writeNormalizedPrefix(writer, value, length - ellipsis.len);
    try writer.writeAll(ellipsis);
}

fn writeNormalizedPrefix(
    writer: *std.Io.Writer,
    value: []const u8,
    count: usize,
) std.Io.Writer.Error!void {
    var written: usize = 0;
    for (value) |byte| {
        if (written == count) break;
        const normalized = normalizedByte(byte) orelse continue;
        try writer.writeByte(normalized);
        written += 1;
    }
    std.debug.assert(written == count);
}

fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn decimalLength(value: usize) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) : (remaining /= 10) digits += 1;
    return digits;
}
