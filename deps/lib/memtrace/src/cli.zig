const std = @import("std");
const pretty = @import("pretty");
const pretty_usage = @import("pretty_usage");
const sys = @import("sys");
const analysis = @import("analysis.zig");
const causal = @import("causal.zig");
const event = @import("event.zig");
const stack = @import("stack/root.zig");

const Allocator = std.mem.Allocator;

const usage_summary =
    "memtrace summary <events.jsonl> [--sort retained|traffic|lifetime] " ++
    "[--layer backing|logical|physical|all] " ++
    "[--format jsonl] [--top N] [--min-bytes N] [--include-zero-live] " ++
    "[--include-sites] [--site-detail ADDRESS] [--symbolize BINARY]";
const usage_allocations =
    "memtrace allocations <events.jsonl> [--scope PATH] [--from-seq N] " ++
    "[--to-seq N] [--layer backing|logical|physical|all] [--binary BINARY] " ++
    "[--top N] [--frames N] [--format jsonl]";
const usage_operations =
    "memtrace operations <events.jsonl> [--scope PATH] [--from-seq N] " ++
    "[--to-seq N] [--layer backing|logical|physical|all] [--binary BINARY] " ++
    "[--top N] [--frames N] [--format jsonl]";
const usage_operation =
    "memtrace operation <events.jsonl> <operation-id> [--binary BINARY] " ++
    "[--frames N] [--format jsonl]";
const usage_roots =
    "memtrace roots <events.jsonl> [--scope PATH] [--from-seq N] " ++
    "[--to-seq N] [--selection allocations|all] " ++
    "[--sort high-water|backing-bytes|requested-bytes|roots] " ++
    "[--detail summary|sources|full] [--binary BINARY] [--top N] " ++
    "[--frames N] [--format jsonl]";
const usage_budget = "memtrace budget <roots.jsonl> <budget.json> [--format jsonl]";

const SummaryArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: analysis.SummaryOptions = .{},
};

const AllocationArgs = struct {
    path: []const u8,
    options: stack.report.Options = .{},
};

const OperationArgs = struct {
    path: []const u8,
    operation_id: u64,
    options: causal.Options = .{},
};

const RootArgs = struct {
    path: []const u8,
    options: stack.roots.Options = .{},
};

const BudgetArgs = struct {
    report_path: []const u8,
    budget_path: []const u8,
    format: stack.budget.Format = .text,
};

const Format = enum {
    text,
    jsonl,
};

pub fn dispatch(allocator: Allocator, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try writeUsage(allocator, sys.stdio.stderr());
        return 1;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "summary")) return try summary(allocator, args[2..]);
    if (std.mem.eql(u8, command, "operation")) {
        return try operation(allocator, args[2..]);
    }
    if (std.mem.eql(u8, command, "allocations")) {
        return try operations(allocator, args[2..], .allocations);
    }
    if (std.mem.eql(u8, command, "operations")) {
        return try operations(allocator, args[2..], .all);
    }
    if (std.mem.eql(u8, command, "roots")) {
        return try roots(allocator, args[2..]);
    }
    if (std.mem.eql(u8, command, "budget")) {
        return try budget(allocator, args[2..]);
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try writeUsage(allocator, sys.stdio.stdout());
        return 0;
    }
    return error.UnknownCommand;
}

fn roots(allocator: Allocator, args: []const []const u8) !u8 {
    const parsed = try parseRootArgs(args);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout = sys.stdio.stdout().writer(
        sys.stdio.debugIo(),
        &stdout_buffer,
    );
    stack.roots.writeFromPath(
        allocator,
        parsed.path,
        &stdout.interface,
        parsed.options,
    ) catch |err| {
        try stdout.interface.flush();
        return err;
    };
    try stdout.interface.flush();
    return 0;
}

fn budget(allocator: Allocator, args: []const []const u8) !u8 {
    const parsed = try parseBudgetArgs(args);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout = sys.stdio.stdout().writer(
        sys.stdio.debugIo(),
        &stdout_buffer,
    );
    const outcome = try stack.budget.checkFromPaths(
        allocator,
        parsed.report_path,
        parsed.budget_path,
        &stdout.interface,
        parsed.format,
    );
    try stdout.interface.flush();
    return if (outcome.passed) 0 else 1;
}

fn operation(allocator: Allocator, args: []const []const u8) !u8 {
    const parsed = try parseOperationArgs(args);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout = sys.stdio.stdout().writer(
        sys.stdio.debugIo(),
        &stdout_buffer,
    );
    try causal.writeFromPath(
        allocator,
        parsed.path,
        parsed.operation_id,
        &stdout.interface,
        parsed.options,
    );
    try stdout.interface.flush();
    return 0;
}

fn operations(
    allocator: Allocator,
    args: []const []const u8,
    selection: stack.report.Selection,
) !u8 {
    var parsed = try parseAllocationArgs(args);
    parsed.options.selection = selection;
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout = sys.stdio.stdout().writer(
        sys.stdio.debugIo(),
        &stdout_buffer,
    );
    try stack.report.writeFromPath(
        allocator,
        parsed.path,
        &stdout.interface,
        parsed.options,
    );
    try stdout.interface.flush();
    return 0;
}

pub fn printError(allocator: Allocator, file: sys.stdio.File, text: []const u8) !void {
    try pretty_usage.Terminal.init(allocator, file, .{}).writeErrorText("memtrace", text);
}

fn summary(allocator: Allocator, args: []const []const u8) !u8 {
    const parsed = try parseSummaryArgs(args);
    var stdout_buffer: [8192]u8 = undefined;
    var stdout = sys.stdio.stdout().writer(sys.stdio.debugIo(), &stdout_buffer);
    switch (parsed.format) {
        .text => try analysis.writeSummaryFromJsonlPath(allocator, parsed.path, &stdout.interface, parsed.options),
        .jsonl => _ = try analysis.writeSummaryJsonlFromJsonlPath(
            allocator,
            parsed.path,
            &stdout.interface,
            parsed.options,
        ),
    }
    try stdout.interface.flush();
    return 0;
}

fn parseSummaryArgs(args: []const []const u8) !SummaryArgs {
    if (args.len == 0) return error.InvalidArguments;
    var parsed = SummaryArgs{ .path = args[0] };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--format")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            if (std.mem.eql(u8, args[index], "jsonl")) {
                parsed.format = .jsonl;
            } else if (std.mem.eql(u8, args[index], "text")) {
                parsed.format = .text;
            } else {
                return error.UnsupportedFormat;
            }
        } else if (std.mem.eql(u8, args[index], "--top")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.top = try parsePositiveUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--layer")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.layer = try parseLayer(args[index]);
        } else if (std.mem.eql(u8, args[index], "--sort")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.sort = analysis.Sort.parse(args[index]) orelse
                return error.UnsupportedSort;
        } else if (std.mem.eql(u8, args[index], "--min-bytes")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.min_bytes = try parseUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--include-zero-live")) {
            parsed.options.include_zero_live = true;
        } else if (std.mem.eql(u8, args[index], "--include-sites")) {
            parsed.options.include_sites = true;
        } else if (std.mem.eql(u8, args[index], "--site-detail")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.site_detail_return_address = try parseAddress(args[index]);
        } else if (std.mem.eql(u8, args[index], "--symbolize")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.include_sites = true;
            parsed.options.site_symbol_binary = args[index];
        } else {
            return error.UnknownArgument;
        }
    }
    return parsed;
}

fn parseAllocationArgs(args: []const []const u8) !AllocationArgs {
    if (args.len == 0) return error.InvalidArguments;
    var parsed = AllocationArgs{ .path = args[0] };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--format")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.format = if (std.mem.eql(u8, args[index], "jsonl"))
                .jsonl
            else if (std.mem.eql(u8, args[index], "text"))
                .text
            else
                return error.UnsupportedFormat;
        } else if (std.mem.eql(u8, args[index], "--top")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.top = try parsePositiveUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--layer")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.layer = try parseLayer(args[index]);
        } else if (std.mem.eql(u8, args[index], "--frames")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.frame_limit = try parsePositiveUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--scope")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.window.scope = args[index];
        } else if (std.mem.eql(u8, args[index], "--from-seq")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.window.first_sequence =
                try parsePositiveU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--to-seq")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.window.last_sequence =
                try parsePositiveU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--binary") or
            std.mem.eql(u8, args[index], "--symbolize"))
        {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.binary_path = args[index];
        } else {
            return error.UnknownArgument;
        }
    }
    try parsed.options.window.validate();
    return parsed;
}

fn parseOperationArgs(args: []const []const u8) !OperationArgs {
    if (args.len < 2) return error.InvalidArguments;
    var parsed = OperationArgs{
        .path = args[0],
        .operation_id = try parsePositiveU64(args[1]),
    };
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--format")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.format = if (std.mem.eql(u8, args[index], "jsonl"))
                .jsonl
            else if (std.mem.eql(u8, args[index], "text"))
                .text
            else
                return error.UnsupportedFormat;
        } else if (std.mem.eql(u8, args[index], "--frames")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.frame_limit = try parsePositiveUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--binary") or
            std.mem.eql(u8, args[index], "--symbolize"))
        {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.binary_path = args[index];
        } else {
            return error.UnknownArgument;
        }
    }
    return parsed;
}

fn parseRootArgs(args: []const []const u8) !RootArgs {
    if (args.len == 0) return error.InvalidArguments;
    var parsed = RootArgs{ .path = args[0] };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--format")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.format = if (std.mem.eql(u8, args[index], "jsonl"))
                .jsonl
            else if (std.mem.eql(u8, args[index], "text"))
                .text
            else
                return error.UnsupportedFormat;
        } else if (std.mem.eql(u8, args[index], "--top")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.top = try parsePositiveUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--frames")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.frame_limit = try parsePositiveUsize(args[index]);
        } else if (std.mem.eql(u8, args[index], "--scope")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.window.scope = args[index];
        } else if (std.mem.eql(u8, args[index], "--from-seq")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.window.first_sequence =
                try parsePositiveU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--to-seq")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.window.last_sequence =
                try parsePositiveU64(args[index]);
        } else if (std.mem.eql(u8, args[index], "--selection")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.selection = if (std.mem.eql(
                u8,
                args[index],
                "allocations",
            ))
                .allocations
            else if (std.mem.eql(u8, args[index], "all"))
                .all
            else
                return error.UnsupportedSelection;
        } else if (std.mem.eql(u8, args[index], "--sort")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.sort = if (std.mem.eql(
                u8,
                args[index],
                "high-water",
            ))
                .high_water
            else if (std.mem.eql(u8, args[index], "backing-bytes"))
                .backing_bytes
            else if (std.mem.eql(u8, args[index], "requested-bytes"))
                .requested_bytes
            else if (std.mem.eql(u8, args[index], "roots"))
                .roots
            else
                return error.UnsupportedSort;
        } else if (std.mem.eql(u8, args[index], "--detail")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.detail = if (std.mem.eql(
                u8,
                args[index],
                "summary",
            ))
                .summary
            else if (std.mem.eql(u8, args[index], "sources"))
                .sources
            else if (std.mem.eql(u8, args[index], "full"))
                .full
            else
                return error.UnsupportedDetail;
        } else if (std.mem.eql(u8, args[index], "--binary") or
            std.mem.eql(u8, args[index], "--symbolize"))
        {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.options.binary_path = args[index];
        } else {
            return error.UnknownArgument;
        }
    }
    try parsed.options.window.validate();
    return parsed;
}

fn parseBudgetArgs(args: []const []const u8) !BudgetArgs {
    if (args.len < 2) return error.InvalidArguments;
    var parsed = BudgetArgs{
        .report_path = args[0],
        .budget_path = args[1],
    };
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (!std.mem.eql(u8, args[index], "--format")) {
            return error.UnknownArgument;
        }
        index += 1;
        if (index >= args.len) return error.InvalidArguments;
        parsed.format = if (std.mem.eql(u8, args[index], "jsonl"))
            .jsonl
        else if (std.mem.eql(u8, args[index], "text"))
            .text
        else
            return error.UnsupportedFormat;
    }
    return parsed;
}

fn parseLayer(text: []const u8) !event.LayerFilter {
    return event.LayerFilter.fromTag(text) orelse error.UnsupportedLayer;
}

fn parsePositiveUsize(text: []const u8) !usize {
    const value = try parseUsize(text);
    if (value == 0) return error.InvalidArguments;
    return value;
}

fn parsePositiveU64(text: []const u8) !u64 {
    const value = std.fmt.parseUnsigned(u64, text, 10) catch
        return error.InvalidArguments;
    if (value == 0) return error.InvalidArguments;
    return value;
}

fn parseUsize(text: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, text, 10) catch error.InvalidArguments;
}

fn parseAddress(text: []const u8) !u64 {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        return std.fmt.parseUnsigned(u64, text[2..], 16) catch error.InvalidArguments;
    }
    return std.fmt.parseUnsigned(u64, text, 10) catch error.InvalidArguments;
}

fn writeUsage(allocator: Allocator, file: sys.stdio.File) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const builder = pretty.Builder.init(arena_state.allocator());
    try pretty_usage.Terminal.init(allocator, file, .{}).writeDoc(try usageDocAlloc(builder));
}

fn renderUsageAlloc(allocator: Allocator, options: pretty.LayoutOptions) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const builder = pretty.Builder.init(arena_state.allocator());
    const doc = try usageDocAlloc(builder);
    return try pretty.renderAlloc(allocator, doc, options);
}

fn usageDocAlloc(builder: pretty.Builder) !pretty.Doc {
    return try builder.concat(&.{
        try builder.styledText(.keyword, "usage"),
        try builder.punct(":"),
        pretty.hardline,
        try builder.spaces(2),
        try builder.nest(4, try builder.styledWords(.name, usage_summary)),
        pretty.hardline,
        try builder.spaces(2),
        try builder.nest(
            4,
            try builder.styledWords(.name, usage_allocations),
        ),
        pretty.hardline,
        try builder.spaces(2),
        try builder.nest(
            4,
            try builder.styledWords(.name, usage_operations),
        ),
        pretty.hardline,
        try builder.spaces(2),
        try builder.nest(
            4,
            try builder.styledWords(.name, usage_operation),
        ),
        pretty.hardline,
        try builder.spaces(2),
        try builder.nest(
            4,
            try builder.styledWords(.name, usage_roots),
        ),
        pretty.hardline,
        try builder.spaces(2),
        try builder.nest(
            4,
            try builder.styledWords(.name, usage_budget),
        ),
        pretty.hardline,
    });
}

test "allocation args require positive report limits" {
    const parsed = try parseAllocationArgs(&.{
        "events.jsonl",
        "--binary",
        "events.jsonl.exe",
        "--top",
        "12",
        "--frames",
        "24",
        "--format",
        "jsonl",
        "--layer",
        "logical",
        "--scope",
        "root/fixture.phase.first",
        "--from-seq",
        "10928",
        "--to-seq",
        "299873",
    });
    try std.testing.expectEqualStrings("events.jsonl", parsed.path);
    try std.testing.expectEqualStrings(
        "events.jsonl.exe",
        parsed.options.binary_path.?,
    );
    try std.testing.expectEqual(@as(usize, 12), parsed.options.top);
    try std.testing.expectEqual(@as(usize, 24), parsed.options.frame_limit);
    try std.testing.expectEqual(stack.report.Format.jsonl, parsed.options.format);
    try std.testing.expectEqual(event.LayerFilter.logical, parsed.options.layer);
    try std.testing.expectEqualStrings(
        "root/fixture.phase.first",
        parsed.options.window.scope.?,
    );
    try std.testing.expectEqual(
        @as(?u64, 10928),
        parsed.options.window.first_sequence,
    );
    try std.testing.expectEqual(
        @as(?u64, 299873),
        parsed.options.window.last_sequence,
    );
}

test "summary args parse format and filters" {
    const parsed = try parseSummaryArgs(&.{
        "events.jsonl",
        "--format",
        "jsonl",
        "--layer",
        "all",
        "--sort",
        "traffic",
        "--top",
        "8",
        "--min-bytes",
        "32",
        "--include-zero-live",
        "--include-sites",
        "--site-detail",
        "0xabc",
        "--symbolize",
        "zig-out/bin/tiny",
    });
    try std.testing.expectEqualStrings("events.jsonl", parsed.path);
    try std.testing.expectEqual(Format.jsonl, parsed.format);
    try std.testing.expectEqual(event.LayerFilter.all, parsed.options.layer);
    try std.testing.expectEqual(analysis.Sort.traffic, parsed.options.sort);
    try std.testing.expectEqual(@as(usize, 8), parsed.options.top);
    try std.testing.expectEqual(@as(usize, 32), parsed.options.min_bytes);
    try std.testing.expect(parsed.options.include_zero_live);
    try std.testing.expect(parsed.options.include_sites);
    try std.testing.expectEqual(@as(u64, 0xabc), parsed.options.site_detail_return_address.?);
    try std.testing.expectEqualStrings("zig-out/bin/tiny", parsed.options.site_symbol_binary.?);
}

test "operation args parse exact identifier and symbol options" {
    const parsed = try parseOperationArgs(&.{
        "events.jsonl",
        "42",
        "--binary",
        "events.jsonl.exe",
        "--frames",
        "24",
        "--format",
        "jsonl",
    });
    try std.testing.expectEqualStrings("events.jsonl", parsed.path);
    try std.testing.expectEqual(@as(u64, 42), parsed.operation_id);
    try std.testing.expectEqualStrings(
        "events.jsonl.exe",
        parsed.options.binary_path.?,
    );
    try std.testing.expectEqual(@as(usize, 24), parsed.options.frame_limit);
    try std.testing.expectEqual(causal.Format.jsonl, parsed.options.format);
}

test "causal root args parse selection and symbol options" {
    const parsed = try parseRootArgs(&.{
        "events.jsonl",
        "--binary",
        "events.jsonl.exe",
        "--top",
        "12",
        "--frames",
        "24",
        "--format",
        "jsonl",
        "--selection",
        "all",
        "--sort",
        "backing-bytes",
        "--detail",
        "sources",
        "--scope",
        "root/fixture.phase.repeat",
        "--from-seq",
        "299874",
        "--to-seq",
        "438296",
    });
    try std.testing.expectEqualStrings("events.jsonl", parsed.path);
    try std.testing.expectEqualStrings(
        "events.jsonl.exe",
        parsed.options.binary_path.?,
    );
    try std.testing.expectEqual(@as(usize, 12), parsed.options.top);
    try std.testing.expectEqual(@as(usize, 24), parsed.options.frame_limit);
    try std.testing.expectEqual(stack.roots.Format.jsonl, parsed.options.format);
    try std.testing.expectEqual(
        stack.report.Selection.all,
        parsed.options.selection,
    );
    try std.testing.expectEqual(stack.roots.Sort.backing_bytes, parsed.options.sort);
    try std.testing.expectEqual(stack.roots.Detail.sources, parsed.options.detail);
    try std.testing.expectEqualStrings(
        "root/fixture.phase.repeat",
        parsed.options.window.scope.?,
    );
    try std.testing.expectEqual(
        @as(?u64, 299874),
        parsed.options.window.first_sequence,
    );
    try std.testing.expectEqual(
        @as(?u64, 438296),
        parsed.options.window.last_sequence,
    );
}

test "allocation and root args reject inverted sequence windows" {
    try std.testing.expectError(
        error.InvalidSequenceWindow,
        parseAllocationArgs(&.{
            "events.jsonl",
            "--from-seq",
            "8",
            "--to-seq",
            "7",
        }),
    );
    try std.testing.expectError(
        error.InvalidSequenceWindow,
        parseRootArgs(&.{
            "events.jsonl",
            "--from-seq",
            "8",
            "--to-seq",
            "7",
        }),
    );
}

test "causal budget args parse report budget and format" {
    const parsed = try parseBudgetArgs(&.{
        "roots.jsonl",
        "budget.json",
        "--format",
        "jsonl",
    });
    try std.testing.expectEqualStrings("roots.jsonl", parsed.report_path);
    try std.testing.expectEqualStrings("budget.json", parsed.budget_path);
    try std.testing.expectEqual(stack.budget.Format.jsonl, parsed.format);
}

test "usage renders through pretty plain and colored output" {
    const plain = try renderUsageAlloc(std.testing.allocator, .{ .width = 88 });
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "usage:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "memtrace summary <events.jsonl>") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        plain,
        "memtrace allocations <events.jsonl>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        plain,
        "memtrace roots <events.jsonl>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        plain,
        "memtrace budget <roots.jsonl>",
    ) != null);

    const colored = try renderUsageAlloc(std.testing.allocator, .{ .width = 88, .color = .ansi });
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
}

test "usage wraps long memtrace command at terminal width" {
    const rendered = try renderUsageAlloc(std.testing.allocator, .{ .width = 48 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "memtrace summary <events.jsonl> [--sort\n",
    ) != null);
}

test "errors render through pretty plain and colored output" {
    const plain = try pretty_usage.renderErrorTextAlloc(
        std.testing.allocator,
        "memtrace",
        "UnknownCommand",
        .{ .layout = .{ .width = 88 } },
    );
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("memtrace: UnknownCommand\n", plain);

    const colored = try pretty_usage.renderErrorTextAlloc(
        std.testing.allocator,
        "memtrace",
        "UnknownCommand",
        .{ .layout = .{ .width = 88, .color = .ansi } },
    );
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "UnknownCommand") != null);
}
