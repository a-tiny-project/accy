const std = @import("std");
const tracy = @import("../../root.zig");
const types = @import("types.zig");

pub fn parse(args: []const []const u8) !types.ExportArgs {
    if (args.len < 2) return error.InvalidArguments;
    var parsed = types.ExportArgs{
        .mode = tracy.csv.Export.fromName(args[0]) orelse return error.InvalidExport,
        .path = args[1],
    };
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--output")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.output = args[index];
        } else {
            return error.UnknownArgument;
        }
    }
    return parsed;
}

test "export args parse output path" {
    const parsed = try parse(&.{ "zones", "events.jsonl", "--output", "zones.csv" });
    try std.testing.expectEqual(tracy.csv.Export.zones, parsed.mode);
    try std.testing.expectEqualStrings("events.jsonl", parsed.path);
    try std.testing.expectEqualStrings("zones.csv", parsed.output.?);
}
