//! The push-constant extent a stage writer reports beside a render payload.
//!
//! `RenderPipelineDesc.push_extent` has no default, so whoever builds a pipeline states the bytes
//! the payload's stages read. The writer that emitted the payload knows that number, and it puts it
//! in `<name>.push` beside the payload: the decimal count of bytes and a newline. This file defines
//! that format for every reader, and a writer outside the package names it as the definition.

const std = @import("std");

pub const Error = error{ MissingPushExtent, MalformedPushExtent };

/// Bytes the longest well-formed file holds: a `u32`'s ten digits and the newline.
const max_text_bytes = 11;

comptime {
    std.debug.assert(std.fmt.count("{d}\n", .{std.math.maxInt(u32)}) == max_text_bytes);
}

/// Reads `<name>.push` from `dir`, the push-constant bytes a stage writer reported for the module
/// `<name>`. A missing or malformed file is refused by name, never read as 0. The read takes one
/// byte more than the longest well-formed file, so a file that fills it is longer than any
/// extent, and it refuses rather than parse a prefix.
pub fn readPushExtent(io: std.Io, dir: std.Io.Dir, name: []const u8) !u32 {
    std.debug.assert(name.len != 0);
    var name_buffer: [64]u8 = undefined;
    var text_buffer: [max_text_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&name_buffer, "{s}.push", .{name});
    const text = dir.readFile(io, path, &text_buffer) catch |err| switch (err) {
        error.FileNotFound => return error.MissingPushExtent,
        else => |other| return other,
    };
    if (text.len == text_buffer.len) return error.MalformedPushExtent;
    std.debug.assert(text.len <= max_text_bytes);
    return parsePushExtent(text);
}

/// The extent one `.push` file's text states: one or more ASCII decimal digits followed by at most
/// one newline, naming a multiple of 4, since a push-constant block holds whole 4-byte words. No
/// sign, digit separator or other byte is part of the format.
pub fn parsePushExtent(text: []const u8) Error!u32 {
    const digits = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    if (digits.len == 0) return error.MalformedPushExtent;
    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return error.MalformedPushExtent;
    }
    const extent = std.fmt.parseInt(u32, digits, 10) catch return error.MalformedPushExtent;
    if (extent % 4 != 0) return error.MalformedPushExtent;
    return extent;
}

test "a push file states a word count of bytes in decimal" {
    try std.testing.expectEqual(@as(u32, 0), try parsePushExtent("0\n"));
    try std.testing.expectEqual(@as(u32, 64), try parsePushExtent("64\n"));
    try std.testing.expectEqual(@as(u32, 128), try parsePushExtent("128"));
    try std.testing.expectError(error.MalformedPushExtent, parsePushExtent("6\n"));
    try std.testing.expectError(error.MalformedPushExtent, parsePushExtent(""));
    try std.testing.expectError(error.MalformedPushExtent, parsePushExtent("-4\n"));
    try std.testing.expectError(error.MalformedPushExtent, parsePushExtent("64 \n"));
    try std.testing.expectError(error.MalformedPushExtent, parsePushExtent("+16\n"));
    try std.testing.expectError(error.MalformedPushExtent, parsePushExtent("1_6\n"));
    try std.testing.expectError(error.MalformedPushExtent, parsePushExtent("16\n\n"));
    try std.testing.expectError(error.MalformedPushExtent, parsePushExtent("\n"));
    try std.testing.expectError(error.MalformedPushExtent, parsePushExtent("4294967296\n"));
}

test "a missing or overlong push file is refused by name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.MissingPushExtent, readPushExtent(io, tmp.dir, "absent"));
    try tmp.dir.writeFile(io, .{ .sub_path = "pushed.push", .data = "16\n" });
    try std.testing.expectEqual(@as(u32, 16), try readPushExtent(io, tmp.dir, "pushed"));
    try tmp.dir.writeFile(io, .{ .sub_path = "long.push", .data = "000000000016\n" });
    try std.testing.expectError(error.MalformedPushExtent, readPushExtent(io, tmp.dir, "long"));
}
