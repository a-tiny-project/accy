const std = @import("std");
const pretty = @import("pretty");

pub const UsageTextStyles = struct {
    usage_label: pretty.Style = .keyword,
    command: pretty.Style = .name,
    section: pretty.Style = .keyword,
    column_left: pretty.Style = .value,
    flag: pretty.Style = .type_name,
};

pub const UsageTextOptions = struct {
    layout: pretty.LayoutOptions = .{},
    styles: UsageTextStyles = .{},
};

pub const HelpStyles = struct {
    usage_label: pretty.Style = .keyword,
    section: pretty.Style = .keyword,
    command: pretty.Style = .name,
    argument: pretty.Style = .value,
    option: pretty.Style = .type_name,
    section_row: pretty.Style = .value,
    example: pretty.Style = .value,
};

pub const HelpOptions = struct {
    layout: pretty.LayoutOptions = .{},
    styles: HelpStyles = .{},
    example_inline_columns: usize = 48,
};

pub const TerminalOptions = struct {
    default_width: usize = 88,
    min_width: usize = 48,
    max_width: usize = 120,
};

pub const ErrorTextOptions = struct {
    layout: pretty.LayoutOptions = .{},
    prefix_style: pretty.Style = .danger,
};

pub const HelpErrorOptions = struct {
    layout: pretty.LayoutOptions = .{},
    help_styles: HelpStyles = .{},
    error_prefix_style: pretty.Style = .danger,
    exit_code: u8 = 2,
};

pub const CommandSuggestionOptions = struct {
    enabled: bool = false,
    max_distance: usize = 3,
    intro: []const u8 = "Did you mean",
};

pub const CommandSuggestion = struct {
    command: *const Command,
    name: []const u8,
    distance: usize,
};

pub const CommandSuggestionWriteOptions = struct {
    layout: pretty.LayoutOptions = .{},
    intro: []const u8 = "Did you mean",
};

pub const CommandHelpErrorOptions = struct {
    layout: pretty.LayoutOptions = .{},
    help_styles: HelpStyles = .{},
    error_prefix: []const u8 = "error",
    error_prefix_style: pretty.Style = .danger,
    unknown_label: []const u8 = "unknown command",
    suggestions: CommandSuggestionOptions = .{},
    fallback_help: ?*const Help = null,
    fallback_note: ?[]const u8 = null,
    exit_code: u8 = 2,
};

pub const CommandPathHelpErrorOptions = struct {
    layout: pretty.LayoutOptions = .{},
    help_styles: HelpStyles = .{},
    error_prefix: ?[]const u8 = null,
    error_prefix_style: pretty.Style = .danger,
    unknown_label: []const u8 = "unknown command",
    nested_unknown_label: []const u8 = "unknown subcommand",
    suggestions: CommandSuggestionOptions = .{},
    fallback_help: ?*const Help = null,
    fallback_note: ?[]const u8 = null,
    parent_fallback_help: bool = false,
    exit_code: u8 = 2,
};

pub const Help = struct {
    name: []const u8,
    summary: []const u8 = "",
    usages: []const Usage = &.{},
    groups: []const CommandGroup = &.{},
    arguments: []const Argument = &.{},
    options: []const Option = &.{},
    option_groups: []const OptionGroup = &.{},
    sections: []const Section = &.{},
    examples: []const Example = &.{},
    notes: []const []const u8 = &.{},

    pub fn command(self: Help, name: []const u8) ?*const Command {
        for (self.groups) |group| {
            for (group.commands) |*candidate| {
                if (candidate.matches(name)) return candidate;
            }
        }
        return null;
    }

    pub fn commandHelp(self: Help, name: []const u8) ?*const Help {
        const resolved = self.command(name) orelse return null;
        return resolved.detail;
    }

    pub fn suggestCommand(self: Help, input: []const u8, options: CommandSuggestionOptions) ?CommandSuggestion {
        if (!options.enabled) return null;
        var best: ?CommandSuggestion = null;
        for (self.groups) |group| {
            for (group.commands) |*candidate| {
                updateCommandSuggestion(&best, candidate, candidate.name, input, options.max_distance);
                for (candidate.aliases) |alias| {
                    updateCommandSuggestion(&best, candidate, alias, input, options.max_distance);
                }
            }
        }
        return best;
    }

    pub fn commandPathHelp(self: Help, args: []const []const u8) ?*const Help {
        if (args.len == 0) return null;
        var current = self.commandHelp(args[0]) orelse return null;
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (isHelpArg(arg) or std.mem.startsWith(u8, arg, "-")) break;
            if (!current.hasCommands()) break;
            current = current.commandHelp(arg) orelse return null;
        }
        return current;
    }

    pub fn commandPathMissing(self: *const Help, args: []const []const u8) ?CommandPathMissing {
        var current = self;
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (isHelpArg(arg) or std.mem.startsWith(u8, arg, "-")) return null;
            if (!current.hasCommands()) return null;
            current = current.commandHelp(arg) orelse return .{
                .parent = current,
                .arg = arg,
                .path = args[0 .. index + 1],
                .depth = index,
            };
        }
        return null;
    }

    pub fn hasCommands(self: Help) bool {
        for (self.groups) |group| {
            if (group.commands.len > 0) return true;
        }
        return false;
    }
};

pub const CommandPathMissing = struct {
    parent: *const Help,
    arg: []const u8,
    path: []const []const u8,
    depth: usize,
};

pub const Usage = union(enum) {
    command: CommandUsage,
    build: BuildUsage,
    text: []const u8,
};

pub const CommandUsage = struct {
    name: []const u8,
    args: []const u8 = "",
};

pub const BuildUsage = struct {
    step: []const u8,
    args: []const u8 = "",
    runner: []const u8 = "zig build",
    separator: ?[]const u8 = "--",
};

pub const CommandGroup = struct {
    title: []const u8 = "Commands",
    commands: []const Command = &.{},
};

pub const Command = struct {
    name: []const u8,
    args: []const u8 = "",
    aliases: []const []const u8 = &.{},
    summary: []const u8 = "",
    detail: ?*const Help = null,

    pub fn matches(self: Command, name: []const u8) bool {
        if (std.mem.eql(u8, self.name, name)) return true;
        for (self.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) return true;
        }
        return false;
    }
};

pub const Argument = struct {
    name: []const u8,
    summary: []const u8 = "",
};

pub const Option = struct {
    flags: []const u8,
    summary: []const u8 = "",
};

pub const OptionGroup = struct {
    title: []const u8 = "Options",
    options: []const Option = &.{},
};

pub const Section = struct {
    title: []const u8,
    rows: []const SectionRow = &.{},
};

pub const SectionRow = struct {
    label: []const u8,
    summary: []const u8 = "",
};

pub const Example = struct {
    command: []const u8,
    summary: []const u8 = "",
};

pub fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn hasHelpArg(args: []const []const u8) bool {
    for (args) |arg| {
        if (isHelpArg(arg)) return true;
    }
    return false;
}

fn updateCommandSuggestion(
    best: *?CommandSuggestion,
    command: *const Command,
    name: []const u8,
    input: []const u8,
    max_distance: usize,
) void {
    const distance = suggestionDistance(input, name);
    if (distance > max_distance) return;
    if (best.*) |current| {
        if (distance > current.distance) return;
        if (distance == current.distance and !std.mem.lessThan(u8, name, current.name)) return;
    }
    best.* = .{
        .command = command,
        .name = name,
        .distance = distance,
    };
}

pub fn suggestionDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    var previous: [128]usize = undefined;
    var current: [128]usize = undefined;
    const max_command_name_len = previous.len - 1;
    if (a.len > max_command_name_len or b.len > max_command_name_len) return std.math.maxInt(usize);
    const a_len = a.len;
    const b_len = b.len;

    for (0..b_len + 1) |index| previous[index] = index;
    for (0..a_len) |a_index| {
        current[0] = a_index + 1;
        for (0..b_len) |b_index| {
            const cost: usize = if (a[a_index] == b[b_index]) 0 else 1;
            current[b_index + 1] = @min(
                @min(current[b_index] + 1, previous[b_index + 1] + 1),
                previous[b_index] + cost,
            );
        }
        const swap = previous;
        previous = current;
        current = swap;
    }
    return previous[b_len];
}

test "structured help identifies help arguments" {
    try std.testing.expect(isHelpArg("--help"));
    try std.testing.expect(isHelpArg("-h"));
    try std.testing.expect(!isHelpArg("help"));
    try std.testing.expect(hasHelpArg(&.{ "query", "--help" }));
    try std.testing.expect(hasHelpArg(&.{ "query", "surprise", "-h" }));
    try std.testing.expect(!hasHelpArg(&.{ "query", "surprise" }));
}
