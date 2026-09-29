const namespace = @import("root.zig");
const output = @import("output.zig");
const parse = @import("parse.zig");
const repeated = @import("repeated.zig");
const spec = @import("spec.zig");

const parseApp = namespace.parseApp;
test "pretty: usage command namespace" {
    _ = output;
    _ = parse;
    _ = repeated;
    _ = spec;
}

const usage = @import("../root.zig");
const std = @import("std");
const FamilyFacts = struct { executes: bool = false };
const FamilyCommand = struct {
    pub const Payload = union(enum) { show: []const u8, start: []const []const u8 };
    pub const meta = .{
        .aliases = .{"r"},
        .args = "show HANDLE | -- COMMAND...",
        .summary = "Inspect or execute a command.",
        .facts = FamilyFacts{ .executes = true },
    };
    pub const help = usage.Help{
        .name = "sample run",
        .summary = "Preserve command boundaries.",
        .notes = &.{"Arguments after -- belong to the child."},
    };

    pub fn parse(args: []const []const u8) !Payload {
        if (args.len == 2 and std.mem.eql(u8, args[0], "show")) return .{ .show = args[1] };
        if (args.len >= 2 and std.mem.eql(u8, args[0], "--")) return .{ .start = args[1..] };
        return error.InvalidFamilyArguments;
    }
};

const FamilyApp = namespace.AppSpec(struct {
    pub const meta = .{
        .name = "sample",
        .description = "Inspect commands.",
        .version = "1",
        .strict = true,
    };
    pub const GlobalOptions = struct {};
    pub const CommandFacts: type = FamilyFacts;
    pub const commands = .{ .run = FamilyCommand, .list = struct { limit: ?u32 = null } };
    pub const presentation = .{
        .usages = @as([]const usage.Usage, &.{}),
        .sections = @as([]const usage.Section, &.{}),
        .examples = @as([]const usage.Example, &.{}),
        .notes = @as([]const []const u8, &.{}),
    };
});

test "AppSpec custom family preserves union payload aliases tails help and error identity" {
    const args = [_][]const u8{ "r", "--", "printf", "", "--help", "$literal;" };
    const parsed = parseApp(FamilyApp, &args);
    try std.testing.expectEqualSlices([]const u8, args[2..], parsed.ok.command.run.start);
    const shown = parseApp(FamilyApp, &.{ "run", "show", "retained" });
    try std.testing.expectEqualStrings("retained", shown.ok.command.run.show);
    try std.testing.expect(FamilyApp.facts(shown.ok.command).executes);
    const invalid = parseApp(FamilyApp, &.{ "run", "show", "one", "extra" });
    try std.testing.expectEqual(error.InvalidFamilyArguments, invalid.err.cause.?);
    try std.testing.expectEqualStrings("run", invalid.err.command.?);
    const help = parseApp(FamilyApp, &.{ "help", "r" });
    try std.testing.expectEqualStrings("r", help.command_help);
    const text = try usage.renderHelpAlloc(std.testing.allocator, FamilyApp.help, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "run show HANDLE") != null);
    try std.testing.expectEqualStrings(
        "Arguments after -- belong to the child.",
        FamilyApp.help.commandHelp("r").?.notes[0],
    );
    const list = parseApp(FamilyApp, &.{ "list", "--limit", "3" });
    try std.testing.expectEqual(@as(?u32, 3), list.ok.command.list.limit);
}

test "AppSpec strict terminal requests reject trailing arguments" {
    const cases = [_][]const []const u8{
        &.{ "--help", "extra" },
        &.{ "--version", "extra" },
        &.{ "help", "run", "extra" },
    };
    for (cases) |args| {
        const result = parseApp(FamilyApp, args);
        try std.testing.expectEqual(error.UnexpectedArgument, result.err.cause.?);
    }
    try std.testing.expect(parseApp(FamilyApp, &.{"--help"}) == .help);
    try std.testing.expect(parseApp(FamilyApp, &.{"--version"}) == .version);
}
