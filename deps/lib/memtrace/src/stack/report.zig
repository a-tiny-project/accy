const std = @import("std");
const pretty_json = @import("pretty").json;
const sys = @import("sys");
const memtrace = @import("../root.zig");
const analyze_mod = @import("analyze.zig");
const capture_mod = @import("capture.zig");
const identity_mod = @import("identity.zig");
const symbolize_mod = @import("symbolize.zig");

const event_mod = memtrace.event;

pub const Format = enum {
    text,
    jsonl,
};

pub const Selection = analyze_mod.Selection;

pub const Options = struct {
    top: usize = std.math.maxInt(usize),
    frame_limit: usize = capture_mod.max_frames_limit,
    format: Format = .text,
    binary_path: ?[]const u8 = null,
    selection: analyze_mod.Selection = .allocations,
    layer: event_mod.LayerFilter = .backing,
    window: analyze_mod.Window = .{},
};

const SourceKey = struct {
    kind: event_mod.Kind,
    succeeded: bool,
    layer: event_mod.Layer,
    producer: @import("alloc_observe").Producer,
    site: u64,
    caller: u64,
};

const Source = struct {
    key: SourceKey,
    counters: analyze_mod.Counters,
    unique_stacks: u32,
};

const Display = struct {
    source_groups: usize,
    displayed_sources: usize,
    operation_stacks: usize,
    displayed_stacks: usize,
};

pub fn writeFromPath(
    allocator: std.mem.Allocator,
    events_path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    if (options.top == 0 or
        options.frame_limit == 0 or
        options.frame_limit > capture_mod.max_frames_limit)
    {
        return error.InvalidStackReportLimit;
    }
    try options.window.validate();
    var analyzer = analyze_mod.Analyzer.init(allocator, options.window);
    defer analyzer.deinit();
    try ingestPath(&analyzer, events_path);
    try analyzer.validate();

    var inferred_binary: ?[]u8 = null;
    defer if (inferred_binary) |path| allocator.free(path);
    const binary_path = options.binary_path orelse inferred: {
        inferred_binary = try identity_mod.artifactPathAlloc(
            allocator,
            events_path,
        );
        break :inferred inferred_binary.?;
    };
    const actual_digest = identity_mod.fileDigest(
        allocator,
        binary_path,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingExecutableArtifact,
        else => return err,
    };
    const expected_digest = analyzer.executable_digest.?;
    if (!std.mem.eql(u8, &actual_digest, &expected_digest)) {
        return error.ExecutableIdentityMismatch;
    }

    var summaries = try analyzer.collect(options.selection, options.layer);
    defer summaries.deinit(allocator);
    const totals = analyzer.totals(options.selection, options.layer);
    const stack_limit = @min(options.top, summaries.items.len);
    var sources = try collectSources(allocator, summaries.items);
    defer sources.deinit(allocator);
    const source_limit = @min(options.top, sources.items.len);
    const display = Display{
        .source_groups = sources.items.len,
        .displayed_sources = source_limit,
        .operation_stacks = summaries.items.len,
        .displayed_stacks = stack_limit,
    };
    var addresses = try collectAddresses(
        allocator,
        summaries.items[0..stack_limit],
        sources.items[0..source_limit],
        options.frame_limit,
    );
    defer addresses.deinit(allocator);
    var symbols = if (addresses.items.len == 0)
        null
    else
        try symbolize_mod.resolveAlloc(
            allocator,
            binary_path,
            addresses.items,
        );
    defer if (symbols) |*resolved| resolved.deinit(allocator);
    switch (options.format) {
        .text => try writeText(
            writer,
            &analyzer,
            totals,
            options.selection,
            options.layer,
            options.window,
            display,
            sources.items[0..source_limit],
            summaries.items[0..stack_limit],
            symbols,
            options.frame_limit,
            expected_digest,
        ),
        .jsonl => try writeJsonl(
            writer,
            &analyzer,
            totals,
            options.selection,
            options.layer,
            options.window,
            display,
            sources.items[0..source_limit],
            summaries.items[0..stack_limit],
            symbols,
            options.frame_limit,
            expected_digest,
        ),
    }
}

fn ingestPath(analyzer: *analyze_mod.Analyzer, path: []const u8) !void {
    var file = try sys.fs.cwd().openFile(sys.fs.debugIo(), path, .{});
    defer file.close(sys.fs.debugIo());
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(sys.fs.debugIo(), &buffer);
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        const actual = line orelse break;
        try analyzer.ingestJsonLine(actual);
    }
}

fn collectAddresses(
    allocator: std.mem.Allocator,
    summaries: []const analyze_mod.Summary,
    sources: []const Source,
    frame_limit: usize,
) !std.ArrayListUnmanaged(u64) {
    var seen = std.AutoHashMapUnmanaged(u64, void){};
    defer seen.deinit(allocator);
    var addresses = std.ArrayListUnmanaged(u64).empty;
    errdefer addresses.deinit(allocator);
    for (sources) |source| {
        try appendAddress(allocator, &seen, &addresses, source.key.site);
        if (source.key.caller != 0) {
            try appendAddress(
                allocator,
                &seen,
                &addresses,
                source.key.caller,
            );
        }
    }
    for (summaries) |summary| {
        const limit = @min(
            frame_limit,
            summary.definition.call_addresses.len,
        );
        for (summary.definition.call_addresses[0..limit]) |address| {
            try appendAddress(allocator, &seen, &addresses, address);
        }
    }
    std.mem.sort(u64, addresses.items, {}, lessThan);
    return addresses;
}

fn appendAddress(
    allocator: std.mem.Allocator,
    seen: *std.AutoHashMapUnmanaged(u64, void),
    addresses: *std.ArrayListUnmanaged(u64),
    address: u64,
) !void {
    const entry = try seen.getOrPut(allocator, address);
    if (entry.found_existing) return;
    try addresses.append(allocator, address);
}

fn collectSources(
    allocator: std.mem.Allocator,
    summaries: []const analyze_mod.Summary,
) !std.ArrayListUnmanaged(Source) {
    var counts = std.AutoHashMapUnmanaged(SourceKey, Source){};
    defer counts.deinit(allocator);
    for (summaries) |summary| {
        const key = SourceKey{
            .kind = summary.key.kind,
            .succeeded = summary.key.succeeded,
            .layer = summary.key.layer,
            .producer = summary.key.producer,
            .site = summary.definition.call_addresses[0],
            .caller = callerAddress(summary.definition),
        };
        const entry = try counts.getOrPut(allocator, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .key = key,
                .counters = .{},
                .unique_stacks = 0,
            };
        }
        entry.value_ptr.counters.calls = try std.math.add(
            u64,
            entry.value_ptr.counters.calls,
            summary.counters.calls,
        );
        entry.value_ptr.counters.requested_bytes = try std.math.add(
            u128,
            entry.value_ptr.counters.requested_bytes,
            summary.counters.requested_bytes,
        );
        entry.value_ptr.unique_stacks = try std.math.add(
            u32,
            entry.value_ptr.unique_stacks,
            1,
        );
    }
    var sources = std.ArrayListUnmanaged(Source).empty;
    errdefer sources.deinit(allocator);
    try sources.ensureTotalCapacity(allocator, counts.count());
    var values = counts.valueIterator();
    while (values.next()) |source| sources.appendAssumeCapacity(source.*);
    std.mem.sort(Source, sources.items, {}, sourceGreaterThan);
    return sources;
}

fn callerAddress(definition: analyze_mod.Definition) u64 {
    const site = definition.call_addresses[0];
    for (definition.call_addresses[1..], 1..) |address, index| {
        if (address != site) continue;
        const caller_index = index + 1;
        if (caller_index < definition.call_addresses.len) {
            return definition.call_addresses[caller_index];
        }
        return 0;
    }
    return 0;
}

fn sourceGreaterThan(_: void, left: Source, right: Source) bool {
    if (left.counters.calls != right.counters.calls) {
        return left.counters.calls > right.counters.calls;
    }
    if (left.counters.requested_bytes != right.counters.requested_bytes) {
        return left.counters.requested_bytes > right.counters.requested_bytes;
    }
    if (left.key.kind != right.key.kind) {
        return @backingInt(left.key.kind) < @backingInt(right.key.kind);
    }
    if (left.key.layer != right.key.layer) {
        return @backingInt(left.key.layer) < @backingInt(right.key.layer);
    }
    if (left.key.producer != right.key.producer) {
        return @backingInt(left.key.producer) < @backingInt(right.key.producer);
    }
    if (left.key.succeeded != right.key.succeeded) return left.key.succeeded;
    if (left.key.site != right.key.site) return left.key.site < right.key.site;
    return left.key.caller < right.key.caller;
}

fn selectionTag(selection: analyze_mod.Selection) []const u8 {
    return switch (selection) {
        .allocations => "allocations",
        .all => "all",
    };
}

fn outcomeTag(succeeded: bool) []const u8 {
    return if (succeeded) "success" else "failure";
}

fn lessThan(_: void, left: u64, right: u64) bool {
    return left < right;
}

fn writeText(
    writer: *std.Io.Writer,
    analyzer: *const analyze_mod.Analyzer,
    totals: analyze_mod.Totals,
    selection: analyze_mod.Selection,
    layer: event_mod.LayerFilter,
    window: analyze_mod.Window,
    display: Display,
    sources: []const Source,
    summaries: []const analyze_mod.Summary,
    maybe_symbols: ?symbolize_mod.Symbols,
    frame_limit: usize,
    digest: identity_mod.Digest,
) !void {
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const coverage = analyzer.coverage.?;
    try writer.print(
        "memory_operations status={s} universe={s} selection={s} layer={s} " ++
            "calls={d} successful={d} failed={d} requested_bytes={d} " ++
            "source_groups={d} displayed_sources={d} operation_stacks={d} " ++
            "displayed_stacks={d} binary_sha256={s}",
        .{
            coverage.statusTag(),
            coverage.universe.tag(),
            selectionTag(selection),
            layer.tag(),
            totals.calls,
            totals.successful,
            totals.failed,
            totals.requested_bytes,
            display.source_groups,
            display.displayed_sources,
            display.operation_stacks,
            display.displayed_stacks,
            digest_hex,
        },
    );
    try writeTextWindow(writer, window, "memory_operation");
    try writer.writeByte('\n');
    try writer.print(
        "coverage child_allocator_fast_paths={s} sys_memory_operations={s} " ++
            "direct_os_memory_operations={s} unowned_allocator_producers={s} " ++
            "foreign_allocations={s} " ++
            "observer_control={s} observer_control_operations={d} " ++
            "zero_length_operations={s} predispatch_failures={s}\n",
        .{
            coverage.child_allocator_fast_paths.tag(),
            coverage.sys_memory_operations.tag(),
            coverage.direct_os_memory_operations.tag(),
            coverage.unowned_allocator_producers.tag(),
            coverage.foreign_allocations.tag(),
            coverage.observer_control.tag(),
            coverage.observer_control_operations,
            coverage.zero_length_operations.tag(),
            coverage.predispatch_failures.tag(),
        },
    );
    for (sources) |source| {
        try writer.print(
            "source layer={s} producer={s} operation={s} outcome={s} calls={d} " ++
                "requested_bytes={d} unique_stacks={d}",
            .{
                source.key.layer.tag(),
                @tagName(source.key.producer),
                source.key.kind.tag(),
                outcomeTag(source.key.succeeded),
                source.counters.calls,
                source.counters.requested_bytes,
                source.unique_stacks,
            },
        );
        try writeTextAddress(
            writer,
            " site",
            source.key.site,
            maybe_symbols,
        );
        if (source.key.caller != 0) {
            try writeTextAddress(
                writer,
                " caller",
                source.key.caller,
                maybe_symbols,
            );
        } else {
            try writer.writeAll(" caller=unavailable");
        }
        try writer.writeByte('\n');
    }
    for (summaries) |summary| {
        const displayed = @min(
            frame_limit,
            summary.definition.call_addresses.len,
        );
        try writer.print(
            "stack id={d} layer={s} producer={s} operation={s} outcome={s} calls={d} " ++
                "requested_bytes={d} captured_frames={d} displayed_frames={d}\n",
            .{
                summary.key.stack_id,
                summary.key.layer.tag(),
                @tagName(summary.key.producer),
                summary.key.kind.tag(),
                outcomeTag(summary.key.succeeded),
                summary.counters.calls,
                summary.counters.requested_bytes,
                summary.definition.call_addresses.len,
                displayed,
            },
        );
        for (
            summary.definition.call_addresses[0..displayed],
            0..,
        ) |address, frame_index| {
            const resolved = if (maybe_symbols) |symbols|
                symbols.find(address)
            else
                &.{};
            try writer.print(
                "  frame={d} kind={s} call_address=0x{x}",
                .{
                    frame_index,
                    if (frame_index == 0) "operation_site" else "physical",
                    address,
                },
            );
            if (resolved.len != 0) {
                try writer.writeAll(" function=");
                try pretty_json.writeString(writer, resolved[0].function);
                try writer.writeAll(" location=");
                try pretty_json.writeString(writer, resolved[0].location);
            }
            try writer.writeByte('\n');
            for (resolved[1..], 1..) |inline_frame, inline_index| {
                try writer.print("    inline={d} function=", .{inline_index});
                try pretty_json.writeString(writer, inline_frame.function);
                try writer.writeAll(" location=");
                try pretty_json.writeString(writer, inline_frame.location);
                try writer.writeByte('\n');
            }
        }
    }
}

fn writeTextAddress(
    writer: *std.Io.Writer,
    prefix: []const u8,
    address: u64,
    maybe_symbols: ?symbolize_mod.Symbols,
) !void {
    try writer.print("{s}_address=0x{x}", .{ prefix, address });
    const resolved = if (maybe_symbols) |symbols|
        symbols.find(address)
    else
        &.{};
    if (resolved.len == 0) return;
    try writer.print("{s}_function=", .{prefix});
    try pretty_json.writeString(writer, resolved[0].function);
    try writer.print("{s}_location=", .{prefix});
    try pretty_json.writeString(writer, resolved[0].location);
    if (resolved.len == 1) return;
    const owner = resolved[resolved.len - 1];
    try writer.print("{s}_owner_function=", .{prefix});
    try pretty_json.writeString(writer, owner.function);
    try writer.print("{s}_owner_location=", .{prefix});
    try pretty_json.writeString(writer, owner.location);
}

fn writeJsonl(
    writer: *std.Io.Writer,
    analyzer: *const analyze_mod.Analyzer,
    totals: analyze_mod.Totals,
    selection: analyze_mod.Selection,
    layer: event_mod.LayerFilter,
    window: analyze_mod.Window,
    display: Display,
    sources: []const Source,
    summaries: []const analyze_mod.Summary,
    maybe_symbols: ?symbolize_mod.Symbols,
    frame_limit: usize,
    digest: identity_mod.Digest,
) !void {
    const coverage = analyzer.coverage.?;
    var summary_stream = pretty_json.Writer.init(writer, .minified);
    const header = try summary_stream.object();
    try header.field("kind", "memory_operation_summary");
    try header.field("status", coverage.statusTag());
    try header.field("universe", coverage.universe.tag());
    try header.field("selection", selectionTag(selection));
    try header.field("layer", layer.tag());
    try header.field("calls", totals.calls);
    try header.field("successful", totals.successful);
    try header.field("failed", totals.failed);
    try header.field("requested_bytes", totals.requested_bytes);
    try header.field("source_groups", display.source_groups);
    try header.field("displayed_sources", display.displayed_sources);
    try header.field("operation_stacks", display.operation_stacks);
    try header.field("displayed_stacks", display.displayed_stacks);
    try header.hexString("binary_sha256", &digest);
    try writeJsonWindow(header, window, "memory_operation");
    try header.field("child_allocator_fast_paths", coverage.child_allocator_fast_paths.tag());
    try header.field("sys_memory_operations", coverage.sys_memory_operations.tag());
    try header.field("direct_os_memory_operations", coverage.direct_os_memory_operations.tag());
    try header.field("unowned_allocator_producers", coverage.unowned_allocator_producers.tag());
    try header.field("foreign_allocations", coverage.foreign_allocations.tag());
    try header.field("observer_control", coverage.observer_control.tag());
    try header.field("observer_control_operations", coverage.observer_control_operations);
    try header.field("zero_length_operations", coverage.zero_length_operations.tag());
    try header.field("predispatch_failures", coverage.predispatch_failures.tag());
    try header.endLine();
    for (sources) |source| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("kind", "memory_operation_source");
        try object.field("layer", source.key.layer.tag());
        try object.field("producer", @tagName(source.key.producer));
        try object.field("operation", source.key.kind.tag());
        try object.field("succeeded", source.key.succeeded);
        try object.field("calls", source.counters.calls);
        try object.field("requested_bytes", source.counters.requested_bytes);
        try object.field("unique_stacks", source.unique_stacks);
        try object.field("site_address", source.key.site);
        const caller_address: ?u64 = if (source.key.caller == 0) null else source.key.caller;
        try object.field("caller_address", caller_address);
        try writeJsonSymbol(
            object,
            "site",
            source.key.site,
            maybe_symbols,
        );
        if (source.key.caller != 0) {
            try writeJsonSymbol(
                object,
                "caller",
                source.key.caller,
                maybe_symbols,
            );
        }
        try object.endLine();
    }
    for (summaries) |summary| {
        const displayed = @min(
            frame_limit,
            summary.definition.call_addresses.len,
        );
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("kind", "memory_operation_stack");
        try object.field("stack_id", summary.key.stack_id);
        try object.field("layer", summary.key.layer.tag());
        try object.field("producer", @tagName(summary.key.producer));
        try object.field("operation", summary.key.kind.tag());
        try object.field("succeeded", summary.key.succeeded);
        try object.field("calls", summary.counters.calls);
        try object.field("requested_bytes", summary.counters.requested_bytes);
        try object.field("captured_frames", summary.definition.call_addresses.len);
        try object.field("displayed_frames", displayed);
        try object.endLine();
        for (
            summary.definition.call_addresses[0..displayed],
            0..,
        ) |address, frame_index| {
            const resolved = if (maybe_symbols) |symbols|
                symbols.find(address)
            else
                &.{};
            if (resolved.len == 0) {
                try writeFrameJsonl(
                    writer,
                    summary.key.stack_id,
                    frame_index,
                    address,
                    0,
                    "",
                    "",
                );
                continue;
            }
            for (resolved, 0..) |inline_frame, inline_index| {
                try writeFrameJsonl(
                    writer,
                    summary.key.stack_id,
                    frame_index,
                    address,
                    inline_index,
                    inline_frame.function,
                    inline_frame.location,
                );
            }
        }
    }
}

fn writeTextWindow(
    writer: *std.Io.Writer,
    window: analyze_mod.Window,
    anchor: []const u8,
) !void {
    try writer.writeAll(" window_scope=");
    if (window.scope) |scope| {
        try pretty_json.writeString(writer, scope);
    } else {
        try writer.writeAll("all");
    }
    try writer.writeAll(" window_scope_match=subtree window_first_sequence=");
    try writeOptionalSequence(writer, window.first_sequence);
    try writer.writeAll(" window_last_sequence=");
    try writeOptionalSequence(writer, window.last_sequence);
    try writer.print(" window_sequence_bounds=inclusive window_anchor={s}", .{
        anchor,
    });
}

fn writeOptionalSequence(writer: *std.Io.Writer, sequence: ?u64) !void {
    if (sequence) |value| {
        try writer.print("{d}", .{value});
    } else {
        try writer.writeAll("all");
    }
}

fn writeJsonWindow(
    object: pretty_json.Object,
    window: analyze_mod.Window,
    anchor: []const u8,
) !void {
    try object.field("window_scope", window.scope);
    try object.field("window_scope_match", "subtree");
    try object.field("window_first_sequence", window.first_sequence);
    try object.field("window_last_sequence", window.last_sequence);
    try object.field("window_sequence_bounds", "inclusive");
    try object.field("window_anchor", anchor);
}

fn writeJsonSymbol(
    object: pretty_json.Object,
    prefix: []const u8,
    address: u64,
    maybe_symbols: ?symbolize_mod.Symbols,
) !void {
    const resolved = if (maybe_symbols) |symbols|
        symbols.find(address)
    else
        &.{};
    if (resolved.len == 0) return;
    try object.fieldParts(&.{ prefix, "_function" }, resolved[0].function);
    try object.fieldParts(&.{ prefix, "_location" }, resolved[0].location);
    if (resolved.len == 1) return;
    const owner = resolved[resolved.len - 1];
    try object.fieldParts(&.{ prefix, "_owner_function" }, owner.function);
    try object.fieldParts(&.{ prefix, "_owner_location" }, owner.location);
}

fn writeFrameJsonl(
    writer: *std.Io.Writer,
    stack_id: u32,
    frame_index: usize,
    address: u64,
    inline_index: usize,
    function: []const u8,
    location: []const u8,
) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("kind", "memory_operation_stack_frame");
    try object.field("stack_id", stack_id);
    try object.field("frame", frame_index);
    try object.field("frame_kind", if (frame_index == 0) "operation_site" else "physical");
    try object.field("call_address", address);
    try object.field("inline", inline_index);
    try object.field("function", function);
    try object.field("location", location);
    try object.endLine();
}
