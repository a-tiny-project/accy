const std = @import("std");

const footer_dash = "\xE2\x80\x94";
pub const truncation_line = "(output truncated at 16 KB " ++ footer_dash ++
    " use filters or --limit to scope down, --json for exact records)";
pub const full_cap = 16 * 1024;
const reserved = truncation_line.len + 1;
pub const body_budget = full_cap - reserved;

pub fn cap16kb(allocator: std.mem.Allocator, output: []const u8) ![]u8 {
    if (output.len <= body_budget) return try allocator.dupe(u8, output);
    var end: usize = 0;
    var next: usize = 0;
    while (next < output.len and next < body_budget) {
        const line_end = std.mem.indexOfScalarPos(u8, output, next, '\n') orelse break;
        if (line_end + 1 > body_budget) break;
        end = line_end + 1;
        next = line_end + 1;
    }
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    if (end != 0) try out.writer.writeAll(output[0..end]);
    try out.writer.writeAll(truncation_line);
    try out.writer.writeByte('\n');
    return try out.toOwnedSlice();
}

test "output cap keeps line boundary" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    for (0..4000) |_| try source.appendSlice(allocator, "line\n");
    const out = try cap16kb(allocator, source.items);
    defer allocator.free(out);
    try std.testing.expect(std.mem.endsWith(u8, out, truncation_line ++ "\n"));
}
