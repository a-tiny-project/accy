const std = @import("std");
const topology = @import("../root.zig");

pub const CpuListOptions = struct {
    clamp: bool = false,
};

pub fn cpuList(
    text: []const u8,
    max_lp: usize,
    options: CpuListOptions,
    out: *topology.LogicalProcessorSet,
) bool {
    if (max_lp >= topology.max_logical_processors) return false;
    out.* = .{};
    const end = terminator(text);
    if (std.mem.trim(u8, text[0..end], " \t\r\n").len == 0) return true;
    var pos: usize = 0;
    while (pos < end) {
        var first = parseDigits(text[0..end], &pos) orelse return false;
        if (first > max_lp) {
            if (!options.clamp) return false;
            first = max_lp;
        }
        var last = first;
        if (pos < end and text[pos] == '-') {
            pos += 1;
            last = parseDigits(text[0..end], &pos) orelse return false;
            if (last > max_lp) {
                if (!options.clamp) return false;
                last = max_lp;
            }
            if (last < first) return false;
        }
        var lp = first;
        while (true) {
            out.set(lp);
            if (lp == last) break;
            lp += 1;
        }
        if (pos == end) break;
        if (text[pos] != ',') return false;
        pos += 1;
        if (pos == end) return false;
    }
    return true;
}

pub fn numberWithOptionalSuffix(text: []const u8) ?usize {
    const end = terminator(text);
    var pos: usize = 0;
    var value = parseDigits(text[0..end], &pos) orelse return null;
    if (pos < end and text[pos] == 'K') {
        value = std.math.mul(usize, value, 1 << 10) catch return null;
        pos += 1;
    } else if (pos < end and text[pos] == 'M') {
        value = std.math.mul(usize, value, 1 << 20) catch return null;
        pos += 1;
    }
    return if (pos == end) value else null;
}

pub fn unsignedPrefix(text: []const u8) ?usize {
    const end = terminator(text);
    var pos: usize = 0;
    return parseDigits(text[0..end], &pos);
}

fn parseDigits(text: []const u8, pos: *usize) ?usize {
    const begin = pos.*;
    const stop = @min(text.len, begin +| 9);
    var value: usize = 0;
    while (pos.* < stop) {
        const byte = text[pos.*];
        if (byte < '0' or byte > '9') break;
        value = value * 10 + byte - '0';
        pos.* += 1;
    }
    return if (pos.* == begin) null else value;
}

fn terminator(text: []const u8) usize {
    for (text, 0..) |byte, index| {
        if (byte == 0 or byte == '\n') return index;
    }
    return text.len;
}
