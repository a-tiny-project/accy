const std = @import("std");
const pretty = @import("pretty");
const pretty_usage = @import("pretty_usage");

const usage_commands = [_][]const u8{
    "tracy-agent summary <events.jsonl> [--format text|jsonl] [--top N]",
    "tracy-agent tree <events.jsonl> [--format text|jsonl] [--top N] [--max-depth N] [--min-duration-ns N] [--thread ID]",
    "tracy-agent stats <events.jsonl> [--format text|jsonl] [--top N] [--sort self|total|mean|count|threads|name] [--min-total-ns N] [--min-self-ns N] [--thread ID]",
    "tracy-agent frames <events.jsonl> [--format text|jsonl] [--top N]" ++
        " [--sort max|total|mean|count|name] [--min-frame-ns N]" ++
        " [--budget-ns N] [--set NAME]",
    "tracy-agent memory <events.jsonl> [--format text|jsonl] [--top N]" ++
        " [--occurrences N] [--sort live|high-water|allocated|lifetime-tail|allocs" ++
        "|frees|name] [--min-live-bytes N] [--name NAME]",
    "tracy-agent locks <events.jsonl> [--format text|jsonl] [--top N]" ++
        " [--occurrences N] [--sort wait|wait-tail|hold|hold-tail|contention" ++
        "|count|name|last] [--kind all|wait|hold] [--mode all|lock|shared]" ++
        " [--min-wait-ns N] [--min-hold-ns N] [--lock ID] [--thread ID]" ++
        " [--since-ns N] [--until-ns N] [--around-ns N] [--window-ns N]" ++
        " [--match TEXT] [--ignore-case]",
    "tracy-agent messages <events.jsonl> [--format text|jsonl] [--top N] [--occurrences N] [--kind all|message|app-info] [--group thread|text|kind|none] [--sort time|count|last|thread|text|kind] [--thread ID] [--since-ns N] [--until-ns N] [--around-ns N] [--window-ns N] [--match TEXT] [--ignore-case]",
    "tracy-agent samples <events.jsonl> [--format text|jsonl] [--top N] [--occurrences N] [--group source|symbol|stack|thread|kind|none] [--sort samples|weight|last|first|thread|name|kind] [--kind TEXT] [--min-weight N] [--thread ID] [--since-ns N] [--until-ns N] [--around-ns N] [--window-ns N] [--match TEXT] [--ignore-case]",
    "tracy-agent fibers <events.jsonl> [--format text|jsonl] [--top N] [--occurrences N] [--group fiber|thread|transition|none] [--sort running|enters|leaves|migrations|unmatched|last|fiber|thread|label] [--fiber ID] [--thread ID] [--since-ns N] [--until-ns N] [--around-ns N] [--window-ns N] [--match TEXT] [--ignore-case]",
    "tracy-agent gpu <events.jsonl> [--format text|jsonl] [--top N]" ++
        " [--occurrences N] [--group context|name|thread|annotation|none]" ++
        " [--sort gpu|gpu-tail|cpu|cpu-tail|count|annotations|last|context|thread|label]" ++
        " [--context ID] [--thread ID] [--since-ns N] [--until-ns N]" ++
        " [--around-ns N] [--window-ns N] [--min-gpu-ns N] [--match TEXT]" ++
        " [--ignore-case]",
    "tracy-agent context <events.jsonl> [--format text|jsonl] [--top N]" ++
        " [--occurrences N] [--group thread|cpu|reason|state|transition|none]" ++
        " [--sort running|blocked|ready|latency|switches|wakeups|migrations|last" ++
        "|thread|cpu|label] [--thread ID] [--cpu ID] [--since-ns N]" ++
        " [--until-ns N] [--around-ns N] [--window-ns N] [--match TEXT]" ++
        " [--ignore-case]",
    "tracy-agent system <events.jsonl> [--format text|jsonl] [--top N] [--occurrences N] [--group kind|thread|cpu|address|topology|name|none] [--sort count|value|last|first|thread|cpu|address|label] [--thread ID] [--cpu ID] [--address ADDR] [--kind TEXT] [--since-ns N] [--until-ns N] [--around-ns N] [--window-ns N] [--match TEXT] [--ignore-case]",
    "tracy-agent plots <events.jsonl> [--format text|jsonl] [--top N] [--sort samples|max|min|mean|range|last|name] [--min-samples N] [--name NAME]",
    "tracy-agent source <events.jsonl> [--format text|jsonl] [--top N] [--sort self|total|mean|count|file|name] [--min-total-ns N] [--min-self-ns N] [--thread ID] [--match TEXT] [--root PATH] [--context N] [--context-back N] [--ignore-case]",
    "tracy-agent find <events.jsonl> PATTERN [--format text|jsonl] [--top N] [--occurrences N] [--group source|name|thread|parent|text|none] [--sort total|self|count|mean|max|name|time] [--thread ID] [--since-ns N] [--until-ns N] [--around-ns N] [--window-ns N] [--min-duration-ns N] [--ignore-case]",
    "tracy-agent flame <events.jsonl> [--format text|jsonl|folded] [--top N] [--sort time|name] [--max-depth N] [--min-ns N] [--thread ID] [--since-ns N] [--until-ns N] [--around-ns N] [--window-ns N] [--match TEXT]",
    "tracy-agent timeline <events.jsonl> [--format text|jsonl] [--top N] [--kind all|zone|message|app-info|frame|plot|alloc|free|thread|fiber|gpu|sample|context|lock|metadata] [--sort time|duration] [--thread ID] [--since-ns N] [--until-ns N] [--around-ns N] [--window-ns N] [--min-duration-ns N] [--match TEXT]",
    "tracy-agent compare BASELINE.jsonl RUN.jsonl [--format text|jsonl] [--top N]" ++
        " [--frame-budget-ns N] [--min-frame-delta-ns N]" ++
        " [--min-zone-delta-ns N] [--min-gpu-delta-ns N]" ++
        " [--min-memory-delta-bytes N] [--min-memory-lifetime-delta-ns N]" ++
        " [--include-stable]",
    "tracy-agent export zones|messages|plots|allocs <events.jsonl> [--output PATH]",
};

pub fn printError(allocator: std.mem.Allocator, file: std.Io.File, text: []const u8) !void {
    try pretty_usage.Terminal.init(allocator, file, .{}).writeErrorText("tracy-agent", text);
}

pub fn write(allocator: std.mem.Allocator, file: std.Io.File) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const builder = pretty.Builder.init(arena_state.allocator());
    try pretty_usage.Terminal.init(allocator, file, .{}).writeDoc(try docAlloc(builder));
}

fn renderAlloc(allocator: std.mem.Allocator, options: pretty.LayoutOptions) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const builder = pretty.Builder.init(arena_state.allocator());
    const doc = try docAlloc(builder);
    return try pretty.renderAlloc(allocator, doc, options);
}

fn docAlloc(builder: pretty.Builder) !pretty.Doc {
    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    try parts.append(builder.allocator, try builder.styledText(.keyword, "usage"));
    try parts.append(builder.allocator, try builder.punct(":"));
    try parts.append(builder.allocator, pretty.hardline);
    for (usage_commands) |command| {
        try parts.append(builder.allocator, try builder.spaces(2));
        try parts.append(builder.allocator, try builder.nest(4, try builder.styledWords(.name, command)));
        try parts.append(builder.allocator, pretty.hardline);
    }
    return try builder.concat(parts.items);
}

test "usage renders through pretty plain and colored output" {
    const plain = try renderAlloc(std.testing.allocator, .{ .width = 88 });
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "usage:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "tracy-agent summary <events.jsonl>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "--budget-ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "--min-gpu-delta-ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "--frame-budget-ns") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, plain, "--min-memory-lifetime-delta-ns") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, plain, "gpu|gpu-tail|cpu|cpu-tail") != null);

    const colored = try renderAlloc(std.testing.allocator, .{ .width = 88, .color = .ansi });
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
}

test "usage wraps long tracy commands at terminal width" {
    const rendered = try renderAlloc(std.testing.allocator, .{ .width = 48 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "tracy-agent locks <events.jsonl> [--format\n") != null);
}

test "errors render through pretty plain and colored output" {
    const plain = try pretty_usage.renderErrorTextAlloc(
        std.testing.allocator,
        "tracy-agent",
        "UnknownCommand",
        .{ .layout = .{ .width = 88 } },
    );
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("tracy-agent: UnknownCommand\n", plain);

    const colored = try pretty_usage.renderErrorTextAlloc(
        std.testing.allocator,
        "tracy-agent",
        "UnknownCommand",
        .{ .layout = .{ .width = 88, .color = .ansi } },
    );
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "UnknownCommand") != null);
}
