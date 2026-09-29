const std = @import("std");
const usage = @import("../root.zig");

pub const FieldMeta = struct {
    short: ?u8 = null,
    description: []const u8 = "",
    aliases: []const []const u8 = &.{},
    argument_name: ?[]const u8 = null,
    option_description: ?[]const u8 = null,
    option_flags: ?[]const u8 = null,
    option_group: ?[]const u8 = null,
    value_name: ?[]const u8 = null,
};

fn stringTuple(comptime raw: anytype) []const []const u8 {
    const count = @typeInfo(@TypeOf(raw)).@"struct".field_names.len;
    comptime var list: [count][]const u8 = undefined;
    inline for (0..count) |index| list[index] = raw[index];
    const frozen = list;
    return &frozen;
}

pub fn fieldMeta(comptime T: type, comptime name: []const u8) FieldMeta {
    if (!@hasDecl(T, "fields")) return .{};
    const metas = T.fields;
    if (!@hasField(@TypeOf(metas), name)) return .{};
    const raw = @field(metas, name);
    var meta: FieldMeta = .{};
    if (@hasField(@TypeOf(raw), "short")) meta.short = raw.short;
    if (@hasField(@TypeOf(raw), "description")) meta.description = raw.description;
    if (@hasField(@TypeOf(raw), "argument_name")) meta.argument_name = raw.argument_name;
    if (@hasField(@TypeOf(raw), "option_description")) meta.option_description = raw.option_description;
    if (@hasField(@TypeOf(raw), "option_flags")) meta.option_flags = raw.option_flags;
    if (@hasField(@TypeOf(raw), "option_group")) meta.option_group = raw.option_group;
    if (@hasField(@TypeOf(raw), "value_name")) meta.value_name = raw.value_name;
    if (@hasField(@TypeOf(raw), "aliases")) {
        meta.aliases = stringTuple(raw.aliases);
        inline for (meta.aliases) |alias| {
            inline for (alias) |char| {
                if (char == '-') @compileError("declare option aliases with underscores: " ++ alias);
            }
        }
    }
    return meta;
}

pub fn positionalNames(comptime T: type) []const []const u8 {
    if (!@hasDecl(T, "positional")) return &.{};
    const decl = T.positional;
    const len = @typeInfo(@TypeOf(decl)).@"struct".field_names.len;
    comptime var names: [len][]const u8 = undefined;
    inline for (0..len) |index| names[index] = @tagName(decl[index]);
    const frozen = names;
    return &frozen;
}

pub fn isPositional(comptime T: type, comptime name: []const u8) bool {
    inline for (positionalNames(T)) |positional| {
        if (comptime std.mem.eql(u8, positional, name)) return true;
    }
    return false;
}

pub fn dashedName(comptime name: []const u8) []const u8 {
    comptime var out: [name.len]u8 = undefined;
    inline for (name, 0..) |char, index| out[index] = if (char == '_') '-' else char;
    const frozen = out;
    return &frozen;
}

fn commandAliases(comptime T: type) []const []const u8 {
    if (!@hasDecl(T, "meta")) return &.{};
    if (!@hasField(@TypeOf(T.meta), "aliases")) return &.{};
    return stringTuple(T.meta.aliases);
}

pub fn matchesCommand(
    comptime T: type,
    comptime canonical_name: []const u8,
    input: []const u8,
) bool {
    if (std.mem.eql(u8, input, canonical_name)) return true;
    inline for (comptime commandAliases(T)) |alias| {
        if (std.mem.eql(u8, input, alias)) return true;
    }
    return false;
}

pub fn Commands(comptime defs: anytype) type {
    const info = @typeInfo(@TypeOf(defs)).@"struct";
    const TagInt = std.math.IntFittingRange(0, info.field_names.len - 1);
    comptime var names: [info.field_names.len][:0]const u8 = undefined;
    comptime var values: [info.field_names.len]TagInt = undefined;
    comptime var payloads: [info.field_names.len]type = undefined;
    comptime var attrs: [info.field_names.len]std.builtin.Type.Union.FieldAttributes = undefined;
    inline for (info.field_names, 0..) |name, index| {
        names[index] = name;
        values[index] = @intCast(index);
        const Definition = @field(defs, name);
        payloads[index] = if (@hasDecl(Definition, "Payload")) Definition.Payload else Definition;
        attrs[index] = .{};
    }
    const Tag = @Enum(TagInt, .exhaustive, &names, &values);
    return @Union(.auto, Tag, &names, &payloads, &attrs);
}

fn metaValue(comptime T: type, comptime name: []const u8, comptime fallback: anytype) @TypeOf(fallback) {
    if (!@hasDecl(T, "meta")) return fallback;
    if (!@hasField(@TypeOf(T.meta), name)) return fallback;
    return @field(T.meta, name);
}

fn commandFacts(comptime T: type, comptime Facts: type) Facts {
    if (!@hasDecl(T, "meta")) return .{};
    if (!@hasField(@TypeOf(T.meta), "facts")) return .{};
    const value = T.meta.facts;
    if (@TypeOf(value) != Facts) @compileError(@typeName(T) ++ " meta.facts has the wrong type");
    return value;
}

fn argumentValues(comptime T: type) [positionalNames(T).len]usage.Argument {
    const names = positionalNames(T);
    var arguments: [names.len]usage.Argument = undefined;
    inline for (names, 0..) |name, index| {
        const meta = comptime fieldMeta(T, name);
        arguments[index] = .{
            .name = meta.argument_name orelse dashedName(name),
            .summary = meta.description,
        };
    }
    return arguments;
}

fn optionCount(comptime T: type) usize {
    var count: usize = 0;
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        if (fieldMeta(T, name).option_group != null) count += 1;
    }
    return count;
}

fn optionValueName(comptime T: type, comptime name: []const u8) []const u8 {
    const meta = comptime fieldMeta(T, name);
    if (meta.value_name) |value_name| return value_name;
    const Field = @FieldType(T, name);
    const Value = switch (@typeInfo(Field)) {
        .optional => |optional| optional.child,
        else => Field,
    };
    return if (Value == bool) "" else "value";
}

fn optionFlags(comptime T: type, comptime name: []const u8) []const u8 {
    @setEvalBranchQuota(200_000);
    const meta = comptime fieldMeta(T, name);
    if (meta.option_flags) |flags| return flags;
    const long = "--" ++ comptime dashedName(name);
    const value_name = comptime optionValueName(T, name);
    if (meta.short) |short| {
        if (value_name.len == 0) return std.fmt.comptimePrint("-{c}, {s}", .{ short, long });
        return std.fmt.comptimePrint("-{c}, {s} {s}", .{ short, long, value_name });
    }
    if (value_name.len == 0) return long;
    return std.fmt.comptimePrint("{s} {s}", .{ long, value_name });
}

fn optionValues(comptime T: type) [optionCount(T)]usage.Option {
    var options: [optionCount(T)]usage.Option = undefined;
    var index: usize = 0;
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const meta = comptime fieldMeta(T, name);
        if (meta.option_group) |_| {
            options[index] = .{
                .flags = optionFlags(T, name),
                .summary = meta.option_description orelse meta.description,
            };
            index += 1;
        }
    }
    return options;
}

fn optionGroupCount(comptime T: type) usize {
    var count: usize = 0;
    var previous: ?[]const u8 = null;
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        if (fieldMeta(T, name).option_group) |group| {
            if (previous == null or !std.mem.eql(u8, previous.?, group)) count += 1;
            previous = group;
        }
    }
    return count;
}

fn closeOptionGroup(
    groups: anytype,
    group_index: *usize,
    title: []const u8,
    options: []const usage.Option,
    start: usize,
    end: usize,
) void {
    groups[group_index.*] = .{ .title = title, .options = options[start..end] };
    group_index.* += 1;
}

fn optionGroupValues(comptime T: type, options: []const usage.Option) [optionGroupCount(T)]usage.OptionGroup {
    var groups: [optionGroupCount(T)]usage.OptionGroup = undefined;
    var group_index: usize = 0;
    var option_index: usize = 0;
    var start: usize = 0;
    var previous: ?[]const u8 = null;
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        if (fieldMeta(T, name).option_group) |group| {
            if (previous) |prior| {
                if (!std.mem.eql(u8, prior, group)) {
                    closeOptionGroup(&groups, &group_index, prior, options, start, option_index);
                    start = option_index;
                }
            }
            previous = group;
            option_index += 1;
        }
    }
    if (previous) |prior| {
        closeOptionGroup(&groups, &group_index, prior, options, start, option_index);
    }
    return groups;
}

fn commandCount(comptime Spec: type) usize {
    return @typeInfo(@TypeOf(Spec.commands)).@"struct".field_names.len;
}

fn commandHelpValues(comptime Spec: type) [commandCount(Spec)]usage.Help {
    @setEvalBranchQuota(200_000);
    const info = @typeInfo(@TypeOf(Spec.commands)).@"struct";
    var helps: [info.field_names.len]usage.Help = undefined;
    inline for (info.field_names, 0..) |name, index| {
        const T = @field(Spec.commands, name);
        if (@hasDecl(T, "help")) {
            helps[index] = T.help;
            continue;
        }
        const arguments = argumentValues(T);
        const options = optionValues(T);
        const option_groups = optionGroupValues(T, &options);
        helps[index] = .{
            .name = std.fmt.comptimePrint("{s} {s}", .{ Spec.meta.name, name }),
            .summary = metaValue(T, "summary", @as([]const u8, "")),
            .usages = metaValue(T, "usages", @as([]const usage.Usage, &.{})),
            .arguments = &arguments,
            .option_groups = &option_groups,
            .sections = metaValue(T, "sections", @as([]const usage.Section, &.{})),
            .examples = metaValue(T, "examples", @as([]const usage.Example, &.{})),
            .notes = metaValue(T, "notes", @as([]const []const u8, &.{})),
        };
    }
    return helps;
}

fn commandValues(
    comptime Spec: type,
    helps: *const [commandCount(Spec)]usage.Help,
) [commandCount(Spec)]usage.Command {
    const info = @typeInfo(@TypeOf(Spec.commands)).@"struct";
    var commands: [info.field_names.len]usage.Command = undefined;
    inline for (info.field_names, 0..) |name, index| {
        const T = @field(Spec.commands, name);
        const summary = metaValue(T, "summary", @as([]const u8, ""));
        commands[index] = .{
            .name = name,
            .args = metaValue(T, "args", @as([]const u8, "")),
            .aliases = comptime commandAliases(T),
            .summary = metaValue(T, "list_summary", summary),
            .detail = &helps[index],
        };
    }
    return commands;
}

fn commandGroupCount(comptime Spec: type) usize {
    const info = @typeInfo(@TypeOf(Spec.commands)).@"struct";
    var count: usize = 0;
    var previous: ?[]const u8 = null;
    inline for (info.field_names) |name| {
        const T = @field(Spec.commands, name);
        const group = metaValue(T, "group", @as([]const u8, "Commands"));
        if (previous == null or !std.mem.eql(u8, previous.?, group)) count += 1;
        previous = group;
    }
    return count;
}

fn commandGroupValues(
    comptime Spec: type,
    commands: *const [commandCount(Spec)]usage.Command,
) [commandGroupCount(Spec)]usage.CommandGroup {
    const info = @typeInfo(@TypeOf(Spec.commands)).@"struct";
    var groups: [commandGroupCount(Spec)]usage.CommandGroup = undefined;
    var group_index: usize = 0;
    var start: usize = 0;
    var previous: ?[]const u8 = null;
    inline for (info.field_names, 0..) |name, index| {
        const T = @field(Spec.commands, name);
        const group = metaValue(T, "group", @as([]const u8, "Commands"));
        if (previous) |prior| {
            if (!std.mem.eql(u8, prior, group)) {
                groups[group_index] = .{ .title = prior, .commands = commands[start..index] };
                group_index += 1;
                start = index;
            }
        }
        previous = group;
    }
    groups[group_index] = .{ .title = previous.?, .commands = commands[start..] };
    return groups;
}

fn globalOptionValues(comptime Spec: type) [@typeInfo(Spec.GlobalOptions).@"struct".field_names.len]usage.Option {
    const Global = Spec.GlobalOptions;
    const names = @typeInfo(Global).@"struct".field_names;
    var options: [names.len]usage.Option = undefined;
    inline for (names, 0..) |name, index| {
        const meta = comptime fieldMeta(Global, name);
        options[index] = .{ .flags = optionFlags(Global, name), .summary = meta.description };
    }
    return options;
}

fn validateNames(comptime Spec: type) void {
    const info = @typeInfo(@TypeOf(Spec.commands)).@"struct";
    inline for (info.field_names, 0..) |name, index| {
        const T = @field(Spec.commands, name);
        if (std.mem.eql(u8, name, "help")) @compileError("help is reserved by AppSpec");
        inline for (comptime commandAliases(T), 0..) |alias, alias_index| {
            if (alias.len == 0) @compileError("command aliases cannot be empty");
            if (std.mem.eql(u8, alias, "help")) @compileError("help is a reserved alias");
            inline for (info.field_names, 0..) |other_name, other_index| {
                if (std.mem.eql(u8, alias, other_name)) {
                    @compileError("command alias duplicates a command: " ++ alias);
                }
                const Other = @field(Spec.commands, other_name);
                inline for (comptime commandAliases(Other), 0..) |other_alias, other_alias_index| {
                    const later = other_index > index or
                        (other_index == index and other_alias_index > alias_index);
                    if (later and std.mem.eql(u8, alias, other_alias)) {
                        @compileError("duplicate command alias: " ++ alias);
                    }
                }
            }
        }
    }
}

pub fn AppSpec(comptime Spec: type) type {
    @setEvalBranchQuota(200_000);
    validateNames(Spec);
    return struct {
        pub const meta = Spec.meta;
        pub const supports_version = @hasField(@TypeOf(Spec.meta), "version");
        pub const strict = metaValue(Spec, "strict", false);
        pub const GlobalOptions = Spec.GlobalOptions;
        pub const CommandFacts = if (@hasDecl(Spec, "CommandFacts")) Spec.CommandFacts else struct {};
        pub const Command = Commands(Spec.commands);

        const command_helps = commandHelpValues(Spec);
        pub const commands = commandValues(Spec, &command_helps);
        const groups = commandGroupValues(Spec, &commands);
        const global_options = globalOptionValues(Spec);

        pub const help = usage.Help{
            .name = Spec.meta.name,
            .summary = Spec.meta.description,
            .usages = Spec.presentation.usages,
            .groups = &groups,
            .options = &global_options,
            .sections = Spec.presentation.sections,
            .examples = Spec.presentation.examples,
            .notes = Spec.presentation.notes,
        };

        /// Returns the declaration that owns this command's payload, parser, help, and facts.
        pub fn definitionFor(comptime command_name: []const u8) type {
            return @field(Spec.commands, command_name);
        }

        pub fn facts(command: Command) CommandFacts {
            return switch (command) {
                inline else => |_, tag| factsFor(@tagName(tag)),
            };
        }

        pub fn factsFor(comptime command_name: []const u8) CommandFacts {
            return commandFacts(@field(Spec.commands, command_name), CommandFacts);
        }

        pub fn fact(command: Command, comptime name: []const u8) @FieldType(CommandFacts, name) {
            return @field(facts(command), name);
        }

        pub fn factFor(
            comptime command_name: []const u8,
            comptime name: []const u8,
        ) @FieldType(CommandFacts, name) {
            return @field(factsFor(command_name), name);
        }
    };
}

test "AppSpec derives aliases help and command facts" {
    const Facts = struct { writes: bool = false };
    const List = struct {
        limit: ?i64 = null,
        pub const meta = .{
            .aliases = .{"ls"},
            .group = "Read",
            .args = "[--limit n]",
            .summary = "List records.",
            .usages = &[_]usage.Usage{.{ .command = .{ .name = "sample", .args = "list [--limit n]" } }},
            .facts = Facts{},
        };
        pub const fields = .{
            .limit = .{ .description = "Limit records.", .option_group = "Options", .value_name = "n" },
        };
    };
    const Add = struct {
        name: []const u8,
        pub const meta = .{
            .group = "Write",
            .args = "<name>",
            .summary = "Add a record.",
            .usages = &[_]usage.Usage{.{ .command = .{ .name = "sample", .args = "add <name>" } }},
            .facts = Facts{ .writes = true },
        };
        pub const positional = .{.name};
        pub const fields = .{ .name = .{ .description = "Record name." } };
    };
    const Sample = AppSpec(struct {
        pub const meta = .{ .name = "sample", .description = "Manage records." };
        pub const GlobalOptions = struct {};
        pub const CommandFacts = Facts;
        pub const commands = .{ .list = List, .add = Add };
        pub const presentation = .{
            .usages = &[_]usage.Usage{.{ .command = .{ .name = "sample", .args = "<command>" } }},
            .sections = @as([]const usage.Section, &.{}),
            .examples = @as([]const usage.Example, &.{}),
            .notes = @as([]const []const u8, &.{}),
        };
    });

    try std.testing.expect(matchesCommand(List, "list", "ls"));
    try std.testing.expect(!Sample.supports_version);
    try std.testing.expect(!Sample.fact(.{ .list = .{} }, "writes"));
    try std.testing.expect(Sample.fact(.{ .add = .{ .name = "one" } }, "writes"));
    try std.testing.expect(Sample.help.commandHelp("ls") != null);
    const rendered = try usage.renderHelpAlloc(std.testing.allocator, Sample.help, .{});
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "list [--limit n]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Alias: ls.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--limit n") != null);
}
