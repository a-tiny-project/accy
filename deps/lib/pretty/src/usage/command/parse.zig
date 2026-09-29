const std = @import("std");
const usage = @import("../root.zig");

pub const Error = struct {
    message: []const u8,
    context: ?[]const u8 = null,
    command: ?[]const u8 = null,
    suggestion: ?[]const u8 = null,
    cause: ?anyerror = null,

    pub fn usage(message: []const u8) Error {
        return .{ .message = message };
    }

    pub fn withContext(self: Error, context: []const u8) Error {
        var updated = self;
        updated.context = context;
        return updated;
    }

    pub fn withSuggestion(self: Error, suggestion: ?[]const u8) Error {
        var updated = self;
        updated.suggestion = suggestion;
        return updated;
    }

    pub fn withCommand(self: Error, command: []const u8) Error {
        var updated = self;
        updated.command = command;
        return updated;
    }

    pub fn withCause(self: Error, cause: anyerror) Error {
        var updated = self;
        updated.cause = cause;
        return updated;
    }
};

pub fn AppParseResult(comptime App: type) type {
    return union(enum) {
        ok: AppParseSuccess(App),
        err: Error,
        help,
        version,
        command_help: []const u8,
    };
}

fn AppParseSuccess(comptime App: type) type {
    return struct {
        global: GlobalType(App),
        command: App.Command,
    };
}

fn GlobalType(comptime App: type) type {
    return if (@hasDecl(App, "GlobalOptions")) App.GlobalOptions else struct {};
}

fn matchesOption(option: []const u8, comptime field_name: []const u8) bool {
    if (option.len != field_name.len) return false;
    for (option, field_name) |o, f| {
        const normalized = if (o == '-') '_' else o;
        if (normalized != f) return false;
    }
    return true;
}

fn matchesLong(option: []const u8, comptime T: type, comptime field_name: []const u8) bool {
    if (matchesOption(option, field_name)) return true;
    const meta = comptime usage.command.fieldMeta(T, field_name);
    inline for (meta.aliases) |alias| {
        if (comptime alias.len > 1) {
            if (matchesOption(option, alias)) return true;
        }
    }
    return false;
}

fn matchesShort(short: u8, comptime T: type, comptime field_name: []const u8) bool {
    const meta = comptime usage.command.fieldMeta(T, field_name);
    if (meta.short) |declared| {
        if (declared == short) return true;
    }
    inline for (meta.aliases) |alias| {
        if (comptime alias.len == 1) {
            if (alias[0] == short) return true;
        }
    }
    return false;
}

fn optionCandidates(comptime T: type) []const []const u8 {
    comptime var list: []const []const u8 = &.{};
    inline for (@typeInfo(T).@"struct".field_names) |field_name| {
        list = list ++ [_][]const u8{"--" ++ comptime usage.command.dashedName(field_name)};
        const meta = comptime usage.command.fieldMeta(T, field_name);
        inline for (meta.aliases) |alias| {
            if (comptime alias.len > 1) {
                list = list ++ [_][]const u8{"--" ++ comptime usage.command.dashedName(alias)};
            }
        }
    }
    const frozen = list[0..list.len].*;
    return &frozen;
}

const max_suggestion_distance: usize = 3;
const min_affix_len: usize = 3;

fn suggestionThreshold(input_len: usize) usize {
    return @min(max_suggestion_distance, @max(1, input_len / 3));
}

fn strippedOption(arg: []const u8) []const u8 {
    var start: usize = 0;
    while (start < arg.len and arg[start] == '-') start += 1;
    return arg[start..];
}

fn affixMatches(input: []const u8, candidate: []const u8) bool {
    if (input.len < min_affix_len or candidate.len < min_affix_len) return false;
    if (std.mem.startsWith(u8, input, candidate) or
        std.mem.endsWith(u8, input, candidate))
    {
        return true;
    }
    if (std.mem.startsWith(u8, candidate, input) or
        std.mem.endsWith(u8, candidate, input))
    {
        return true;
    }
    return false;
}

fn suggestOption(comptime T: type, arg: []const u8) ?[]const u8 {
    const candidates = comptime optionCandidates(T);
    const input = strippedOption(arg);
    const threshold = suggestionThreshold(input.len);
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (candidates) |candidate| {
        const name = strippedOption(candidate);
        var distance = usage.suggestionDistance(input, name);
        if (distance > threshold and affixMatches(input, name)) {
            distance = 1;
        }
        if (distance > threshold) continue;
        if (distance > best_distance) continue;
        if (distance == best_distance and !std.mem.lessThan(u8, candidate, best.?)) continue;
        best = candidate;
        best_distance = distance;
    }
    return best;
}

fn defaultInitialized(comptime T: type) T {
    var value: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |field_name, field_type, attrs| {
        if (attrs.defaultValue(field_type)) |default| {
            @field(value, field_name) = default;
        } else if (@typeInfo(field_type) == .optional) {
            @field(value, field_name) = null;
        }
    }
    return value;
}

fn assignValue(
    comptime T: type,
    value: *T,
    comptime field_name: []const u8,
    raw: []const u8,
) ?Error {
    const Field = @FieldType(T, field_name);
    const Unwrapped = switch (@typeInfo(Field)) {
        .optional => |optional| optional.child,
        else => Field,
    };
    if (Unwrapped == []const u8) {
        @field(value, field_name) = raw;
        return null;
    }
    if (Unwrapped == bool) {
        if (std.mem.eql(u8, raw, "true")) {
            @field(value, field_name) = true;
        } else if (std.mem.eql(u8, raw, "false")) {
            @field(value, field_name) = false;
        } else {
            return Error.usage("invalid value for option").withContext(raw);
        }
        return null;
    }
    if (@typeInfo(Unwrapped) == .int) {
        const parsed = std.fmt.parseInt(Unwrapped, raw, 10) catch {
            return Error.usage("invalid value for option").withContext(raw);
        };
        @field(value, field_name) = parsed;
        return null;
    }
    if (comptime @typeInfo(Unwrapped) == .@"struct") {
        if (comptime @hasDecl(Unwrapped, "command_repeated") and Unwrapped.command_repeated) {
            @field(value, field_name).append(raw) catch {
                return Error.usage("too many values for option").withContext("--" ++ field_name);
            };
            return null;
        }
    }
    @compileError("unsupported command field type: " ++ @typeName(Field));
}

const ParseCommandResult = union(enum) {
    ok,
    err: Error,
    help,
};

fn positionalFieldIndices(comptime T: type) []const usize {
    const field_names = @typeInfo(T).@"struct".field_names;
    const positionals = usage.command.positionalNames(T);
    var indices: [positionals.len]usize = undefined;
    inline for (positionals, 0..) |positional, slot| {
        inline for (field_names, 0..) |field_name, field_index| {
            if (comptime std.mem.eql(u8, field_name, positional)) {
                indices[slot] = field_index;
            }
        }
    }
    const frozen = indices;
    return &frozen;
}

fn CommandParseStateType(comptime T: type) type {
    const field_count = @typeInfo(T).@"struct".field_names.len;
    return struct {
        value: *T,
        args: []const []const u8,
        provided: [field_count]bool = @splat(false),
        positional_index: usize = 0,
        options_done: bool = false,
        index: usize = 0,
    };
}

fn parseLongOption(
    comptime T: type,
    state: *CommandParseStateType(T),
    arg: []const u8,
) ?Error {
    const field_names = @typeInfo(T).@"struct".field_names;
    const body = arg[2..];
    const eq = std.mem.indexOfScalar(u8, body, '=');
    const name = if (eq) |at| body[0..at] else body;
    var matched = false;
    inline for (field_names, 0..) |field_name, field_index| {
        if (!matched and matchesLong(name, T, field_name)) {
            matched = true;
            state.provided[field_index] = true;
            const Field = @FieldType(T, field_name);
            if (eq) |at| {
                if (assignValue(T, state.value, field_name, body[at + 1 ..])) |err| return err;
            } else if (Field == bool) {
                @field(state.value, field_name) = true;
            } else {
                if (state.index + 1 >= state.args.len) {
                    return Error.usage("missing value for option").withContext(arg);
                }
                state.index += 1;
                if (assignValue(
                    T,
                    state.value,
                    field_name,
                    state.args[state.index],
                )) |err| return err;
            }
        }
    }
    if (!matched) {
        return Error.usage("unknown option")
            .withContext(arg)
            .withSuggestion(suggestOption(T, arg));
    }
    return null;
}

fn parseShortOption(
    comptime T: type,
    state: *CommandParseStateType(T),
    arg: []const u8,
) ?Error {
    const field_names = @typeInfo(T).@"struct".field_names;
    const short = arg[1];
    var matched = false;
    inline for (field_names, 0..) |field_name, field_index| {
        if (!matched and matchesShort(short, T, field_name)) {
            matched = true;
            state.provided[field_index] = true;
            const Field = @FieldType(T, field_name);
            if (Field == bool) {
                @field(state.value, field_name) = true;
            } else {
                if (state.index + 1 >= state.args.len) {
                    return Error.usage("missing value for option").withContext(arg);
                }
                state.index += 1;
                if (assignValue(
                    T,
                    state.value,
                    field_name,
                    state.args[state.index],
                )) |err| return err;
            }
        }
    }
    if (!matched) {
        return Error.usage("unknown option")
            .withContext(arg)
            .withSuggestion(suggestOption(T, arg));
    }
    return null;
}

fn parsePositionalArgument(
    comptime T: type,
    state: *CommandParseStateType(T),
    arg: []const u8,
) ?Error {
    const field_names = @typeInfo(T).@"struct".field_names;
    const positionals = comptime usage.command.positionalNames(T);
    const positional_fields = comptime positionalFieldIndices(T);
    while (state.positional_index < positionals.len and
        state.provided[positional_fields[state.positional_index]])
    {
        state.positional_index += 1;
    }
    if (state.positional_index >= positionals.len) {
        return Error.usage("unexpected argument").withContext(arg);
    }
    inline for (positionals, 0..) |positional, slot| {
        if (slot == state.positional_index) {
            inline for (field_names, 0..) |field_name, field_index| {
                if (comptime std.mem.eql(u8, field_name, positional)) {
                    state.provided[field_index] = true;
                    if (assignValue(T, state.value, field_name, arg)) |err| return err;
                }
            }
        }
    }
    state.positional_index += 1;
    return null;
}

fn validateRequiredFields(comptime T: type, state: *const CommandParseStateType(T)) ?Error {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |field_name, field_type, attrs, field_index| {
        const optional = @typeInfo(field_type) == .optional;
        const has_default = attrs.defaultValue(field_type) != null;
        if (!optional and !has_default and !state.provided[field_index]) {
            if (comptime usage.command.isPositional(T, field_name)) {
                return Error.usage("missing required argument").withContext(field_name);
            }
            return Error.usage("missing required option").withContext("--" ++ field_name);
        }
    }
    return null;
}

fn parseCommand(comptime T: type, value: *T, args: []const []const u8) ParseCommandResult {
    var state: CommandParseStateType(T) = .{ .value = value, .args = args };

    while (state.index < state.args.len) : (state.index += 1) {
        const arg = state.args[state.index];

        if (!state.options_done) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                return .help;
            }
            if (std.mem.eql(u8, arg, "--")) {
                state.options_done = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--")) {
                if (parseLongOption(T, &state, arg)) |err| return .{ .err = err };
                continue;
            }
            if (arg.len == 2 and arg[0] == '-' and arg[1] != '-') {
                if (parseShortOption(T, &state, arg)) |err| return .{ .err = err };
                continue;
            }
        }
        if (parsePositionalArgument(T, &state, arg)) |err| return .{ .err = err };
    }
    if (validateRequiredFields(T, &state)) |err| return .{ .err = err };
    return .ok;
}

fn parseGlobalOption(
    comptime App: type,
    global: *GlobalType(App),
    args: []const []const u8,
    index: *usize,
    arg: []const u8,
) ?Error {
    const Global = GlobalType(App);
    const field_names = @typeInfo(Global).@"struct".field_names;
    const body = arg[2..];
    const eq = std.mem.indexOfScalar(u8, body, '=');
    const name = if (eq) |at| body[0..at] else body;
    var matched = false;
    inline for (field_names) |field_name| {
        if (!matched and matchesOption(name, field_name)) {
            matched = true;
            const Field = @FieldType(Global, field_name);
            if (eq) |at| {
                if (assignValue(Global, global, field_name, body[at + 1 ..])) |err| return err;
            } else if (Field == bool) {
                @field(global, field_name) = true;
            } else {
                if (index.* + 1 >= args.len) {
                    return Error.usage("missing value for option").withContext(arg);
                }
                index.* += 1;
                if (assignValue(Global, global, field_name, args[index.*])) |err| return err;
            }
        }
    }
    if (!matched) return Error.usage("unknown global option").withContext(arg);
    return null;
}

fn parseAppCommand(
    comptime App: type,
    global: GlobalType(App),
    args: []const []const u8,
    index: usize,
    arg: []const u8,
) AppParseResult(App) {
    const CommandUnion = App.Command;
    const command_info = @typeInfo(CommandUnion).@"union";
    inline for (command_info.field_names, command_info.field_types) |field_name, field_type| {
        const Definition = commandDefinition(App, field_name, field_type);
        if (usage.command.matchesCommand(Definition, field_name, arg)) {
            if (comptime @hasDecl(Definition, "Payload")) {
                const command = Definition.parse(args[index + 1 ..]) catch |err| {
                    return .{ .err = Error.usage(@errorName(err)).withCommand(arg).withCause(err) };
                };
                return .{ .ok = .{
                    .global = global,
                    .command = @unionInit(CommandUnion, field_name, command),
                } };
            }
            var command: field_type = defaultInitialized(field_type);
            return switch (parseCommand(field_type, &command, args[index + 1 ..])) {
                .ok => .{ .ok = .{
                    .global = global,
                    .command = @unionInit(CommandUnion, field_name, command),
                } },
                .err => |err| .{ .err = err.withCommand(arg) },
                .help => .{ .command_help = arg },
            };
        }
    }
    if (std.mem.eql(u8, arg, "help")) {
        if (index + 1 >= args.len) return .help;
        if (strictTerminal(App, args, index + 1)) |err| return .{ .err = err };
        const target = args[index + 1];
        inline for (command_info.field_names, command_info.field_types) |field_name, field_type| {
            const Definition = commandDefinition(App, field_name, field_type);
            if (usage.command.matchesCommand(Definition, field_name, target)) {
                return .{ .command_help = target };
            }
        }
        return .{ .err = Error.usage("unknown command")
            .withContext(target).withCause(error.UnknownCommand) };
    }
    return .{ .err = Error.usage("unknown command")
        .withContext(arg).withCause(error.UnknownCommand) };
}

fn commandDefinition(comptime App: type, comptime name: []const u8, comptime Payload: type) type {
    return if (@hasDecl(App, "definitionFor")) App.definitionFor(name) else Payload;
}

fn strictTerminal(comptime App: type, args: []const []const u8, index: usize) ?Error {
    if (comptime @hasDecl(App, "strict") and App.strict) {
        if (index + 1 != args.len) {
            return Error.usage("unexpected argument").withContext(args[index + 1])
                .withCause(error.UnexpectedArgument);
        }
    }
    return null;
}

pub fn parseApp(comptime App: type, args: []const []const u8) AppParseResult(App) {
    const Global = GlobalType(App);

    var global: Global = defaultInitialized(Global);
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            if (strictTerminal(App, args, index)) |err| return .{ .err = err };
            return .help;
        }
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            if (strictTerminal(App, args, index)) |err| return .{ .err = err };
            if (comptime @hasDecl(App, "supports_version")) {
                if (!App.supports_version) {
                    return .{ .err = Error.usage("unknown global option").withContext(arg) };
                }
            }
            return .version;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            if (parseGlobalOption(App, &global, args, &index, arg)) |err| return .{ .err = err };
            continue;
        }
        return parseAppCommand(App, global, args, index, arg);
    }
    return .{ .err = Error.usage("missing command") };
}

const EmptyGlobalOptions = struct {};

fn EmptyGlobalAppType(comptime defs: anytype) type {
    return struct {
        pub const GlobalOptions: type = EmptyGlobalOptions;
        pub const Command: type = usage.command.Commands(defs);
    };
}

const FullPostCommand = struct {
    title: []const u8,
    body: []const u8 = "",
    priority: ?i32 = null,
    json: bool = false,

    pub const positional = .{.title};
    pub const fields = .{
        .body = .{ .short = 'b', .description = "Body" },
        .priority = .{ .short = 'p', .description = "Priority" },
    };
};

const FullParseGlobalOptions = struct {
    store: ?[]const u8 = null,
};

const FullParseApp = struct {
    pub const GlobalOptions: type = FullParseGlobalOptions;
    pub const Command: type = usage.command.Commands(.{ .post = FullPostCommand });
};

const RequiredIdCommand = struct {
    id: []const u8,
    pub const positional = .{.id};
};

const OptionalIdCommand = struct {
    id: []const u8 = "",
};

const SyncCommand = struct {
    action: []const u8,
    dry_run: bool = false,

    pub const positional = .{.action};
};

const ListCommand = struct {
    limit: ?i64 = null,
};

const PositionalPostCommand = struct {
    title: []const u8,
    tag: ?[]const u8 = null,

    pub const positional = .{.title};
    pub const fields = .{
        .tag = .{ .short = 't', .aliases = .{"tags"} },
    };
};

const StatusCommand = struct {
    id: []const u8,
    status: []const u8,

    pub const positional = .{ .id, .status };
};

const CommentCommand = struct {
    id: []const u8,
    message: ?[]const u8 = null,

    pub const positional = .{ .id, .message };
    pub const fields = .{
        .message = .{ .short = 'm', .aliases = .{ "body", "b" } },
    };
};

const SuggestionPostCommand = struct {
    title: []const u8,
    tag: ?[]const u8 = null,
    priority: ?i32 = null,

    pub const positional = .{.title};
};

const RepeatedOptionCommand = struct {
    gate: usage.command.Repeated(2) = .{},
};

const MissingCommandApp: type = EmptyGlobalAppType(.{ .show = RequiredIdCommand });
const HelpApp: type = EmptyGlobalAppType(.{ .show = OptionalIdCommand });
const DashedOptionApp: type = EmptyGlobalAppType(.{ .sync = SyncCommand });
const OptionErrorApp: type = EmptyGlobalAppType(.{ .list = ListCommand });
const PositionalOptionApp: type = EmptyGlobalAppType(.{ .post = PositionalPostCommand });
const PositionalSlotsApp: type = EmptyGlobalAppType(.{ .status = StatusCommand });
const AliasApp: type = EmptyGlobalAppType(.{ .comment = CommentCommand });
const SuggestionApp: type = EmptyGlobalAppType(.{ .post = SuggestionPostCommand });
const RepeatedOptionApp: type = EmptyGlobalAppType(.{ .close = RepeatedOptionCommand });
const VersionlessApp = struct {
    pub const supports_version = false;
    pub const GlobalOptions: type = EmptyGlobalOptions;
    pub const Command: type = usage.command.Commands(.{ .show = OptionalIdCommand });
};

test "parseApp parses globals, command options, and positionals" {
    const result = parseApp(FullParseApp, &.{
        "--store", "/tmp/s", "post", "hello", "-b", "text", "--priority=3", "--json",
    });
    try std.testing.expect(result == .ok);
    try std.testing.expectEqualStrings("/tmp/s", result.ok.global.store.?);
    const post = result.ok.command.post;
    try std.testing.expectEqualStrings("hello", post.title);
    try std.testing.expectEqualStrings("text", post.body);
    try std.testing.expectEqual(@as(?i32, 3), post.priority);
    try std.testing.expect(post.json);
}

test "parseApp reports missing command, unknown command, and missing arguments" {
    const missing = parseApp(MissingCommandApp, &.{});
    try std.testing.expectEqualStrings("missing command", missing.err.message);

    const unknown = parseApp(MissingCommandApp, &.{"frobnicate"});
    try std.testing.expectEqualStrings("unknown command", unknown.err.message);
    try std.testing.expectEqualStrings("frobnicate", unknown.err.context.?);

    const incomplete = parseApp(MissingCommandApp, &.{"show"});
    try std.testing.expectEqualStrings("missing required argument", incomplete.err.message);
    try std.testing.expectEqualStrings("id", incomplete.err.context.?);
}

test "parseApp surfaces help, version, and command help" {
    try std.testing.expect(parseApp(HelpApp, &.{"--help"}) == .help);
    try std.testing.expect(parseApp(HelpApp, &.{"--version"}) == .version);
    const command_help = parseApp(HelpApp, &.{ "show", "--help" });
    try std.testing.expectEqualStrings("show", command_help.command_help);
}

test "parseApp rejects version when the application does not declare one" {
    const version = parseApp(VersionlessApp, &.{"--version"});
    try std.testing.expectEqualStrings("unknown global option", version.err.message);
    try std.testing.expectEqualStrings("--version", version.err.context.?);
}

test "parseApp maps dashed options and double dash terminator" {
    const dashed = parseApp(DashedOptionApp, &.{ "sync", "--dry-run", "push" });
    try std.testing.expect(dashed.ok.command.sync.dry_run);
    try std.testing.expectEqualStrings("push", dashed.ok.command.sync.action);

    const terminated = parseApp(DashedOptionApp, &.{ "sync", "--", "--dry-run" });
    try std.testing.expect(!terminated.ok.command.sync.dry_run);
    try std.testing.expectEqualStrings("--dry-run", terminated.ok.command.sync.action);
}

test "parseApp rejects unknown and valueless options" {
    const unknown = parseApp(OptionErrorApp, &.{ "list", "--nope" });
    try std.testing.expectEqualStrings("unknown option", unknown.err.message);

    const missing_value = parseApp(OptionErrorApp, &.{ "list", "--limit" });
    try std.testing.expectEqualStrings("missing value for option", missing_value.err.message);

    const bad_value = parseApp(OptionErrorApp, &.{ "list", "--limit", "many" });
    try std.testing.expectEqualStrings("invalid value for option", bad_value.err.message);
}

test "parseApp accepts positional fields as long options" {
    const flagged = parseApp(PositionalOptionApp, &.{
        "post", "--title", "hello", "--tags", "a,b",
    });
    try std.testing.expectEqualStrings("hello", flagged.ok.command.post.title);
    try std.testing.expectEqualStrings("a,b", flagged.ok.command.post.tag.?);

    const positional = parseApp(PositionalOptionApp, &.{ "post", "hello", "--tag", "a" });
    try std.testing.expectEqualStrings("hello", positional.ok.command.post.title);

    const surplus = parseApp(PositionalOptionApp, &.{ "post", "--title", "hello", "extra" });
    try std.testing.expectEqualStrings("unexpected argument", surplus.err.message);
    try std.testing.expectEqualStrings("extra", surplus.err.context.?);
}

test "parseApp fills positional slots around flag-provided fields" {
    const skipped = parseApp(PositionalSlotsApp, &.{ "status", "--id", "abc", "closed" });
    try std.testing.expectEqualStrings("abc", skipped.ok.command.status.id);
    try std.testing.expectEqualStrings("closed", skipped.ok.command.status.status);
}

test "parseApp matches single-character aliases as shorts" {
    const short = parseApp(AliasApp, &.{ "comment", "id1", "-m", "text" });
    try std.testing.expectEqualStrings("text", short.ok.command.comment.message.?);

    const alias_long = parseApp(AliasApp, &.{ "comment", "id1", "--body", "text" });
    try std.testing.expectEqualStrings("text", alias_long.ok.command.comment.message.?);

    const alias_short = parseApp(AliasApp, &.{ "comment", "id1", "-b", "text" });
    try std.testing.expectEqualStrings("text", alias_short.ok.command.comment.message.?);

    const flag_form = parseApp(AliasApp, &.{ "comment", "id1", "--message", "text" });
    try std.testing.expectEqualStrings("text", flag_form.ok.command.comment.message.?);
}

test "parseApp suggests the nearest option for unknown options" {
    const plural = parseApp(SuggestionApp, &.{ "post", "t", "--tags", "a" });
    try std.testing.expectEqualStrings("unknown option", plural.err.message);
    try std.testing.expectEqualStrings("--tag", plural.err.suggestion.?);
    try std.testing.expectEqualStrings("post", plural.err.command.?);

    const affix = parseApp(SuggestionApp, &.{ "post", "t", "--add-tag", "a" });
    try std.testing.expectEqualStrings("--tag", affix.err.suggestion.?);

    const hopeless = parseApp(SuggestionApp, &.{ "post", "t", "--zzz", "a" });
    try std.testing.expect(hopeless.err.suggestion == null);
}

test "parseApp accumulates repeated options within a fixed capacity" {
    const parsed = parseApp(RepeatedOptionApp, &.{
        "close", "--gate", "tests=pass:unit", "--gate=review=warn:manual",
    });
    try std.testing.expect(parsed == .ok);
    const gates = parsed.ok.command.close.gate.slice();
    try std.testing.expectEqual(@as(usize, 2), gates.len);
    try std.testing.expectEqualStrings("tests=pass:unit", gates[0]);
    try std.testing.expectEqualStrings("review=warn:manual", gates[1]);

    const overflow = parseApp(RepeatedOptionApp, &.{
        "close", "--gate", "one", "--gate", "two", "--gate", "three",
    });
    try std.testing.expectEqualStrings("too many values for option", overflow.err.message);
}

test "parseApp resolves help as app and command help" {
    try std.testing.expect(parseApp(HelpApp, &.{"help"}) == .help);
    const targeted = parseApp(HelpApp, &.{ "help", "show" });
    try std.testing.expectEqualStrings("show", targeted.command_help);

    const unknown = parseApp(HelpApp, &.{ "help", "nosuch" });
    try std.testing.expectEqualStrings("unknown command", unknown.err.message);
    try std.testing.expectEqualStrings("nosuch", unknown.err.context.?);
}
