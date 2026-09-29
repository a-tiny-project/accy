const std = @import("std");
const pretty = @import("pretty");
const types = @import("types.zig");
const textdoc = @import("usage.zig");

const HelpStyles = types.HelpStyles;
const HelpOptions = types.HelpOptions;
const Help = types.Help;
const Usage = types.Usage;
const CommandGroup = types.CommandGroup;
const Command = types.Command;
const Argument = types.Argument;
const Option = types.Option;
const OptionGroup = types.OptionGroup;
const Section = types.Section;
const SectionRow = types.SectionRow;
const Example = types.Example;

pub fn docAlloc(builder: pretty.Builder, help: Help, options: HelpOptions) !pretty.Doc {
    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    var has_section = false;
    const styles = options.styles;

    try appendHelpUsages(builder, &parts, &has_section, help, styles);
    try appendHelpSummary(builder, &parts, &has_section, help.summary);
    try appendHelpGroups(builder, &parts, &has_section, help.groups, styles);
    try appendHelpArguments(builder, &parts, &has_section, help.arguments, styles);
    try appendHelpOptions(builder, &parts, &has_section, help.options, styles);
    try appendHelpOptionGroups(builder, &parts, &has_section, help.option_groups, styles);
    try appendHelpSections(builder, &parts, &has_section, help.sections, styles);
    try appendHelpExamples(builder, &parts, &has_section, help.examples, styles, options.example_inline_columns);
    try appendHelpNotes(builder, &parts, &has_section, help.notes, styles);

    return try builder.concat(parts.items);
}

fn appendHelpGap(
    builder: pretty.Builder,
    parts: *std.ArrayListUnmanaged(pretty.Doc),
    has_section: *bool,
) !void {
    if (has_section.*) try parts.append(builder.allocator, pretty.hardline);
    has_section.* = true;
}

fn appendHelpUsages(
    builder: pretty.Builder,
    parts: *std.ArrayListUnmanaged(pretty.Doc),
    has_section: *bool,
    help: Help,
    styles: HelpStyles,
) !void {
    try appendHelpGap(builder, parts, has_section);
    if (help.usages.len == 0) {
        try parts.append(builder.allocator, try helpUsageDocAlloc(builder, .{ .command = .{ .name = help.name } }, styles));
        try parts.append(builder.allocator, pretty.hardline);
        return;
    }
    for (help.usages) |usage| {
        try parts.append(builder.allocator, try helpUsageDocAlloc(builder, usage, styles));
        try parts.append(builder.allocator, pretty.hardline);
    }
}

fn appendHelpSummary(
    builder: pretty.Builder,
    parts: *std.ArrayListUnmanaged(pretty.Doc),
    has_section: *bool,
    summary: []const u8,
) !void {
    if (summary.len == 0) return;
    try appendHelpGap(builder, parts, has_section);
    try parts.append(builder.allocator, try textdoc.wordLineDocAlloc(builder, 0, null, summary));
    try parts.append(builder.allocator, pretty.hardline);
}

fn appendHelpGroups(
    builder: pretty.Builder,
    parts: *std.ArrayListUnmanaged(pretty.Doc),
    has_section: *bool,
    groups: []const CommandGroup,
    styles: HelpStyles,
) !void {
    for (groups) |group| {
        if (group.commands.len == 0) continue;
        try appendHelpGap(builder, parts, has_section);
        try parts.append(builder.allocator, try helpSectionDocAlloc(builder, group.title, styles));
        try parts.append(builder.allocator, pretty.hardline);

        const column_width = commandColumnWidth(group.commands);
        for (group.commands) |command| {
            const left = try commandLabelAlloc(builder.allocator, command);
            const right = try commandSummaryAlloc(builder.allocator, command);
            try parts.append(builder.allocator, try helpRowDocAlloc(builder, 2, column_width, left, right, styles.command));
            try parts.append(builder.allocator, pretty.hardline);
        }
    }
}

fn appendHelpArguments(
    builder: pretty.Builder,
    parts: *std.ArrayListUnmanaged(pretty.Doc),
    has_section: *bool,
    arguments: []const Argument,
    styles: HelpStyles,
) !void {
    if (arguments.len == 0) return;
    try appendHelpGap(builder, parts, has_section);
    try parts.append(builder.allocator, try helpSectionDocAlloc(builder, "Arguments", styles));
    try parts.append(builder.allocator, pretty.hardline);

    const column_width = argumentColumnWidth(arguments);
    for (arguments) |argument| {
        try parts.append(builder.allocator, try helpRowDocAlloc(builder, 2, column_width, argument.name, argument.summary, styles.argument));
        try parts.append(builder.allocator, pretty.hardline);
    }
}

fn appendHelpOptions(
    builder: pretty.Builder,
    parts: *std.ArrayListUnmanaged(pretty.Doc),
    has_section: *bool,
    options: []const Option,
    styles: HelpStyles,
) !void {
    if (options.len == 0) return;
    try appendHelpGap(builder, parts, has_section);
    try parts.append(builder.allocator, try helpSectionDocAlloc(builder, "Options", styles));
    try parts.append(builder.allocator, pretty.hardline);

    const column_width = optionColumnWidth(options);
    for (options) |option_item| {
        try parts.append(builder.allocator, try helpRowDocAlloc(builder, 2, column_width, option_item.flags, option_item.summary, styles.option));
        try parts.append(builder.allocator, pretty.hardline);
    }
}

fn appendHelpOptionGroups(
    builder: pretty.Builder,
    parts: *std.ArrayListUnmanaged(pretty.Doc),
    has_section: *bool,
    option_groups: []const OptionGroup,
    styles: HelpStyles,
) !void {
    for (option_groups) |group| {
        if (group.options.len == 0) continue;
        try appendHelpGap(builder, parts, has_section);
        try parts.append(builder.allocator, try helpSectionDocAlloc(builder, group.title, styles));
        try parts.append(builder.allocator, pretty.hardline);

        const column_width = optionColumnWidth(group.options);
        for (group.options) |option_item| {
            try parts.append(builder.allocator, try helpRowDocAlloc(builder, 2, column_width, option_item.flags, option_item.summary, styles.option));
            try parts.append(builder.allocator, pretty.hardline);
        }
    }
}

fn appendHelpSections(
    builder: pretty.Builder,
    parts: *std.ArrayListUnmanaged(pretty.Doc),
    has_section: *bool,
    sections: []const Section,
    styles: HelpStyles,
) !void {
    for (sections) |section| {
        if (section.rows.len == 0) continue;
        try appendHelpGap(builder, parts, has_section);
        try parts.append(builder.allocator, try helpSectionDocAlloc(builder, section.title, styles));
        try parts.append(builder.allocator, pretty.hardline);

        const column_width = sectionRowColumnWidth(section.rows);
        for (section.rows) |row| {
            try parts.append(builder.allocator, try helpRowDocAlloc(builder, 2, column_width, row.label, row.summary, styles.section_row));
            try parts.append(builder.allocator, pretty.hardline);
        }
    }
}

fn appendHelpExamples(
    builder: pretty.Builder,
    parts: *std.ArrayListUnmanaged(pretty.Doc),
    has_section: *bool,
    examples: []const Example,
    styles: HelpStyles,
    inline_columns: usize,
) !void {
    if (examples.len == 0) return;
    try appendHelpGap(builder, parts, has_section);
    try parts.append(builder.allocator, try helpSectionDocAlloc(builder, "Examples", styles));
    try parts.append(builder.allocator, pretty.hardline);

    const column_width = exampleInlineColumnWidth(examples, inline_columns);
    for (examples) |example| {
        if (example.command.len > inline_columns) {
            try parts.append(builder.allocator, try helpExampleBlockDocAlloc(builder, example, styles));
        } else {
            try parts.append(builder.allocator, try helpRowDocAlloc(builder, 2, column_width, example.command, example.summary, styles.example));
        }
        try parts.append(builder.allocator, pretty.hardline);
    }
}

fn appendHelpNotes(
    builder: pretty.Builder,
    parts: *std.ArrayListUnmanaged(pretty.Doc),
    has_section: *bool,
    notes: []const []const u8,
    styles: HelpStyles,
) !void {
    if (notes.len == 0) return;
    try appendHelpGap(builder, parts, has_section);
    try parts.append(builder.allocator, try helpSectionDocAlloc(builder, "Notes", styles));
    try parts.append(builder.allocator, pretty.hardline);
    for (notes) |note| {
        try parts.append(builder.allocator, try textdoc.wordLineDocAlloc(builder, 2, null, note));
        try parts.append(builder.allocator, pretty.hardline);
    }
}

fn helpUsageDocAlloc(builder: pretty.Builder, usage: Usage, styles: HelpStyles) !pretty.Doc {
    const body = try usageBodyAlloc(builder.allocator, usage);
    return try builder.group(try builder.concat(&.{
        try builder.styledText(styles.usage_label, "usage"),
        try builder.punct(":"),
        builder.text(" "),
        try builder.nest(7, try builder.styledWords(styles.command, body)),
    }));
}

fn usageBodyAlloc(allocator: std.mem.Allocator, usage: Usage) ![]const u8 {
    return switch (usage) {
        .text => |text| text,
        .command => |command| if (command.args.len == 0)
            command.name
        else
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ command.name, command.args }),
        .build => |build| if (build.args.len == 0)
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ build.runner, build.step })
        else if (build.separator) |separator|
            try std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{ build.runner, build.step, separator, build.args })
        else
            try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ build.runner, build.step, build.args }),
    };
}

fn helpSectionDocAlloc(builder: pretty.Builder, title: []const u8, styles: HelpStyles) !pretty.Doc {
    return try builder.group(try builder.concat(&.{
        try builder.styledText(styles.section, title),
        try builder.punct(":"),
    }));
}

fn helpRowDocAlloc(
    builder: pretty.Builder,
    indent: usize,
    column_width: usize,
    left: []const u8,
    right: []const u8,
    left_style: pretty.Style,
) !pretty.Doc {
    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    if (indent > 0) try parts.append(builder.allocator, try builder.spaces(indent));
    try parts.append(builder.allocator, try builder.styledText(left_style, left));
    if (right.len > 0) {
        const padding = if (column_width > left.len) column_width - left.len else 0;
        try parts.append(builder.allocator, try builder.spaces(padding + 2));
        try parts.append(builder.allocator, try builder.nest(indent + column_width + 2, try builder.words(right)));
    }
    return try builder.group(try builder.concat(parts.items));
}

fn helpExampleBlockDocAlloc(
    builder: pretty.Builder,
    example: Example,
    styles: HelpStyles,
) !pretty.Doc {
    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    try parts.append(builder.allocator, try builder.spaces(2));
    try parts.append(builder.allocator, try builder.nest(2, try builder.styledWords(styles.example, example.command)));
    if (example.summary.len > 0) {
        try parts.append(builder.allocator, pretty.hardline);
        try parts.append(builder.allocator, try textdoc.wordLineDocAlloc(builder, 4, null, example.summary));
    }
    return try builder.concat(parts.items);
}

fn commandColumnWidth(commands: []const Command) usize {
    var width: usize = 0;
    for (commands) |command| width = @max(width, commandLabelWidth(command));
    return width;
}

fn commandLabelWidth(command: Command) usize {
    return command.name.len + if (command.args.len == 0) @as(usize, 0) else command.args.len + 1;
}

fn commandLabelAlloc(allocator: std.mem.Allocator, command: Command) ![]const u8 {
    if (command.args.len == 0) return command.name;
    return try std.fmt.allocPrint(allocator, "{s} {s}", .{ command.name, command.args });
}

fn commandSummaryAlloc(allocator: std.mem.Allocator, command: Command) ![]const u8 {
    if (command.aliases.len == 0) return command.summary;
    const aliases = try aliasesTextAlloc(allocator, command.aliases);
    const label = if (command.aliases.len == 1) "Alias" else "Aliases";
    if (command.summary.len == 0) return try std.fmt.allocPrint(allocator, "{s}: {s}.", .{ label, aliases });
    return try std.fmt.allocPrint(allocator, "{s} {s}: {s}.", .{ command.summary, label, aliases });
}

fn aliasesTextAlloc(allocator: std.mem.Allocator, aliases: []const []const u8) ![]const u8 {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    for (aliases, 0..) |alias, index| {
        if (index != 0) try text.appendSlice(allocator, ", ");
        try text.appendSlice(allocator, alias);
    }
    return try text.toOwnedSlice(allocator);
}

fn optionColumnWidth(options: []const Option) usize {
    var width: usize = 0;
    for (options) |option_item| width = @max(width, option_item.flags.len);
    return width;
}

fn argumentColumnWidth(arguments: []const Argument) usize {
    var width: usize = 0;
    for (arguments) |argument| width = @max(width, argument.name.len);
    return width;
}

fn sectionRowColumnWidth(rows: []const SectionRow) usize {
    var width: usize = 0;
    for (rows) |row| width = @max(width, row.label.len);
    return width;
}

fn exampleInlineColumnWidth(examples: []const Example, inline_columns: usize) usize {
    var width: usize = 0;
    for (examples) |example| {
        if (example.command.len <= inline_columns) width = @max(width, example.command.len);
    }
    return width;
}

fn renderHelpAlloc(allocator: std.mem.Allocator, help: Help, options: HelpOptions) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const builder = pretty.Builder.init(arena_state.allocator());
    const doc = try docAlloc(builder, help, options);
    return try pretty.renderAlloc(allocator, doc, options.layout);
}

test "structured help renders command usage groups options and examples" {
    const help = Help{
        .name = "diagrams",
        .summary = "Render diagram JSONL to SVG.",
        .usages = &.{
            .{ .command = .{ .name = "diagrams", .args = "render [path|-]" } },
        },
        .groups = &.{
            .{ .commands = &.{
                .{ .name = "render", .args = "[path|-]", .summary = "Render diagram JSONL to SVG." },
            } },
        },
        .options = &.{
            .{ .flags = "--format KIND", .summary = "Output format." },
        },
        .examples = &.{
            .{ .command = "diagrams render graph.jsonl", .summary = "Render a file." },
        },
    };

    const rendered = try renderHelpAlloc(std.testing.allocator, help, .{ .layout = .{ .width = 120 } });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\usage: diagrams render [path|-]
        \\
        \\Render diagram JSONL to SVG.
        \\
        \\Commands:
        \\  render [path|-]  Render diagram JSONL to SVG.
        \\
        \\Options:
        \\  --format KIND  Output format.
        \\
        \\Examples:
        \\  diagrams render graph.jsonl  Render a file.
        \\
    , rendered);
}

test "structured help resolves command detail pages" {
    const capture_help = Help{
        .name = "records capture",
        .summary = "Record a work packet.",
        .usages = &.{
            .{ .build = .{ .step = "records", .args = "capture --agent id --goal text --summary text" } },
        },
    };
    const help = Help{
        .name = "records",
        .groups = &.{
            .{ .commands = &.{
                .{ .name = "capture", .summary = "Record a work packet.", .detail = &capture_help },
                .{ .name = "list", .summary = "List work packets." },
            } },
        },
    };

    try std.testing.expect(help.commandHelp("capture") == &capture_help);
    try std.testing.expect(help.commandHelp("list") == null);
    try std.testing.expect(help.commandHelp("missing") == null);
}

test "structured help resolves and renders command aliases" {
    const post_help = Help{
        .name = "issue post",
        .summary = "Create a new issue.",
    };
    const help = Help{
        .name = "issue",
        .groups = &.{
            .{ .commands = &.{
                .{
                    .name = "post",
                    .args = "<title>",
                    .aliases = &.{ "new", "create" },
                    .summary = "Create a new issue.",
                    .detail = &post_help,
                },
                .{
                    .name = "list",
                    .aliases = &.{"ls"},
                    .summary = "List issues.",
                },
            } },
        },
    };

    try std.testing.expect(help.command("post").?.matches("new"));
    try std.testing.expect(help.commandHelp("post") == &post_help);
    try std.testing.expect(help.commandHelp("new") == &post_help);
    try std.testing.expect(help.commandHelp("create") == &post_help);
    try std.testing.expect(help.commandHelp("missing") == null);
    try std.testing.expect(help.commandPathHelp(&.{ "new", "--help" }) == &post_help);
    const suggestion = help.suggestCommand("crate", .{ .enabled = true }).?;
    try std.testing.expectEqualStrings("create", suggestion.name);
    try std.testing.expect(suggestion.command.detail == &post_help);
    try std.testing.expect(help.suggestCommand("zzzz", .{ .enabled = true }) == null);

    const rendered = try renderHelpAlloc(std.testing.allocator, help, .{ .layout = .{ .width = 120 } });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "post <title>  Create a new issue. Aliases: new, create.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "list          List issues. Alias: ls.") != null);
}

test "structured help resolves nested command detail paths" {
    const surprise_help = Help{
        .name = "intent query surprise",
        .summary = "Score action surprise.",
    };
    const query_help = Help{
        .name = "intent query",
        .groups = &.{
            .{ .commands = &.{
                .{ .name = "surprise", .args = "--action text", .summary = "Score action surprise.", .detail = &surprise_help },
            } },
        },
    };
    const adapt_help = Help{
        .name = "intent adapt",
        .summary = "Adapt a session.",
    };
    const help = Help{
        .name = "intent",
        .groups = &.{
            .{ .commands = &.{
                .{ .name = "adapt", .args = "<source> <session.jsonl>", .summary = "Adapt a session.", .detail = &adapt_help },
                .{ .name = "query", .args = "<name>", .summary = "Inspect model state.", .detail = &query_help },
            } },
        },
    };

    try std.testing.expect(help.hasCommands());
    try std.testing.expect(!adapt_help.hasCommands());
    try std.testing.expect(help.commandPathHelp(&.{"query"}) == &query_help);
    try std.testing.expect(help.commandPathHelp(&.{ "query", "surprise" }) == &surprise_help);
    try std.testing.expect(help.commandPathHelp(&.{ "query", "surprise", "--action", "rename", "--help" }) == &surprise_help);
    try std.testing.expect(help.commandPathHelp(&.{ "adapt", "codex", "session.jsonl", "--help" }) == &adapt_help);
    try std.testing.expect(help.commandPathHelp(&.{ "query", "missing", "--help" }) == null);
    try std.testing.expect(help.commandPathHelp(&.{"missing"}) == null);

    const missing_query = (&help).commandPathMissing(&.{ "query", "missing", "--help" }).?;
    try std.testing.expect(missing_query.parent == &query_help);
    try std.testing.expectEqualStrings("missing", missing_query.arg);
    try std.testing.expectEqual(@as(usize, 1), missing_query.depth);

    const missing_command = (&help).commandPathMissing(&.{ "missing", "--help" }).?;
    try std.testing.expectEqualStrings("missing", missing_command.arg);
    try std.testing.expectEqual(@as(usize, 0), missing_command.depth);
}

test "structured help renders option groups" {
    const help = Help{
        .name = "glom search",
        .option_groups = &.{
            .{
                .title = "Filters",
                .options = &.{
                    .{ .flags = "-k kind", .summary = "Restrict document kind." },
                    .{ .flags = "-p project", .summary = "Restrict project." },
                },
            },
            .{
                .title = "Output",
                .options = &.{
                    .{ .flags = "--json", .summary = "Render JSON." },
                },
            },
        },
    };

    const rendered = try renderHelpAlloc(std.testing.allocator, help, .{ .layout = .{ .width = 88 } });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\usage: glom search
        \\
        \\Filters:
        \\  -k kind     Restrict document kind.
        \\  -p project  Restrict project.
        \\
        \\Output:
        \\  --json  Render JSON.
        \\
    , rendered);
}

test "structured help renders generic documentation sections" {
    const help = Help{
        .name = "issue",
        .options = &.{
            .{ .flags = "--store path", .summary = "Use the specified directory as the store." },
        },
        .sections = &.{
            .{ .title = "Behavior", .rows = &.{
                .{ .label = "Exit codes", .summary = "0 for success, 1 for failure, with errors on stderr." },
                .{ .label = "JSON", .summary = "--json outputs minified JSON with a trailing newline." },
            } },
            .{ .title = "Refs", .rows = &.{
                .{ .label = "issue:<id>", .summary = "Copyable issue ref." },
            } },
        },
    };

    const rendered = try renderHelpAlloc(std.testing.allocator, help, .{ .layout = .{ .width = 88 } });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\usage: issue
        \\
        \\Options:
        \\  --store path  Use the specified directory as the store.
        \\
        \\Behavior:
        \\  Exit codes  0 for success, 1 for failure, with errors on stderr.
        \\  JSON        --json outputs minified JSON with a trailing newline.
        \\
        \\Refs:
        \\  issue:<id>  Copyable issue ref.
        \\
    , rendered);
}

test "structured help renders positional arguments before options" {
    const help = Help{
        .name = "web site",
        .summary = "Assemble the public site.",
        .arguments = &.{
            .{ .name = "source", .summary = "Static public site source directory." },
            .{ .name = "output", .summary = "Rendered site output directory." },
        },
        .option_groups = &.{
            .{
                .title = "Options",
                .options = &.{
                    .{ .flags = "--version version", .summary = "Bake a site version into rendered assets." },
                },
            },
        },
    };

    const rendered = try renderHelpAlloc(std.testing.allocator, help, .{ .layout = .{ .width = 88 } });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\usage: web site
        \\
        \\Assemble the public site.
        \\
        \\Arguments:
        \\  source  Static public site source directory.
        \\  output  Rendered site output directory.
        \\
        \\Options:
        \\  --version version  Bake a site version into rendered assets.
        \\
    , rendered);
}

test "structured help colors semantic CLI roles" {
    const help = Help{
        .name = "tool",
        .usages = &.{
            .{ .command = .{ .name = "tool", .args = "[options]" } },
        },
        .options = &.{
            .{ .flags = "-h, --help", .summary = "Print help." },
        },
        .examples = &.{
            .{ .command = "tool --help", .summary = "Show usage." },
        },
    };

    const rendered = try renderHelpAlloc(std.testing.allocator, help, .{ .layout = .{ .width = 88, .color = .ansi } });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[1;94musage") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[96mtool") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[33m-h, --help") != null);
}

test "structured build usage wraps with hanging indentation" {
    const help = Help{
        .name = "toolcheck",
        .usages = &.{
            .{ .build = .{ .step = "toolcheck", .args = "--agent codex --goal text" } },
        },
    };

    const rendered = try renderHelpAlloc(std.testing.allocator, help, .{ .layout = .{ .width = 34 } });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\usage: zig build toolcheck --
        \\       --agent codex --goal text
        \\
    , rendered);
}

test "structured help renders long examples as blocks" {
    const help = Help{
        .name = "records",
        .examples = &.{
            .{ .command = "zig build records -- capture --agent codex --goal text --summary text", .summary = "Capture a work packet." },
        },
    };

    const rendered = try renderHelpAlloc(std.testing.allocator, help, .{ .layout = .{ .width = 44 }, .example_inline_columns = 32 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\usage: records
        \\
        \\Examples:
        \\  zig build records -- capture --agent codex
        \\  --goal text --summary text
        \\    Capture a work packet.
        \\
    , rendered);
}

test "structured help keeps block examples out of inline columns" {
    const help = Help{
        .name = "issue post",
        .examples = &.{
            .{ .command = "issue post \"Add caching\" -b \"Targets /v1/search\" -t perf -p 1", .summary = "Create a tagged high-priority issue." },
            .{ .command = "issue post \"Follow up\" --quiet", .summary = "Print only the new ID." },
        },
    };

    const rendered = try renderHelpAlloc(std.testing.allocator, help, .{ .layout = .{ .width = 88 }, .example_inline_columns = 48 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\usage: issue post
        \\
        \\Examples:
        \\  issue post "Add caching" -b "Targets /v1/search" -t perf -p 1
        \\    Create a tagged high-priority issue.
        \\  issue post "Follow up" --quiet  Print only the new ID.
        \\
    , rendered);
}
