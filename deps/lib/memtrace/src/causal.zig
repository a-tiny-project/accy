const std = @import("std");
const pretty_json = @import("pretty").json;
const sys = @import("sys");
const coverage_mod = @import("coverage.zig");
const event_mod = @import("event.zig");
const stack = @import("stack/root.zig");

const Allocator = std.mem.Allocator;

pub const Format = enum {
    text,
    jsonl,
};

pub const Options = struct {
    format: Format = .text,
    binary_path: ?[]const u8 = null,
    frame_limit: usize = stack.capture.max_frames_limit,
};

const Relation = enum {
    ancestor,
    target,
    descendant,
};

const Record = struct {
    event: event_mod.ReplayEvent,
    first_child: u32 = 0,
    next_sibling: u32 = 0,
};

const Related = struct {
    record_index: u32,
    depth: u32,
    relation: Relation,
};

const Work = struct {
    record_index: u32,
    depth: u32,
};

const Graph = struct {
    allocator: Allocator,
    stack: stack.analyze.Analyzer,
    records: std.ArrayListUnmanaged(Record) = .empty,
    operation_indices: std.AutoHashMapUnmanaged(u64, u32) = .{},
    linked: bool = false,

    fn init(allocator: Allocator) Graph {
        return .{
            .allocator = allocator,
            .stack = stack.analyze.Analyzer.init(allocator, .{}),
        };
    }

    fn deinit(self: *Graph) void {
        self.stack.deinit();
        self.records.deinit(self.allocator);
        self.operation_indices.deinit(self.allocator);
        self.* = undefined;
    }

    fn ingestJsonLine(self: *Graph, line: []const u8) !void {
        if (self.linked) return error.CausalGraphAlreadyLinked;
        const text = std.mem.trim(u8, line, " \t\r\n");
        if (text.len == 0) return;
        try self.stack.ingestJsonLine(text);
        if (stack.identity.isMetadataLine(text) or
            coverage_mod.isMetadataLine(text) or
            stack.capture.isMetadataLine(text))
        {
            return;
        }
        var line_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer line_arena.deinit();
        const event = try event_mod.parseReplay(line_arena.allocator(), text);
        if (!event.kind.isMemoryOperation() or event.operation_id == 0) return;
        const record_index = std.math.cast(
            u32,
            self.records.items.len,
        ) orelse return error.CausalGraphTooLarge;
        var retained_event = event;
        retained_event.scope = "";
        try self.records.append(self.allocator, .{ .event = retained_event });
        errdefer _ = self.records.pop();
        try self.operation_indices.putNoClobber(
            self.allocator,
            event.operation_id,
            record_index,
        );
    }

    fn link(self: *Graph) !void {
        if (self.linked) return;
        for (0..self.records.items.len) |record_index| {
            const parent_operation_id =
                self.records.items[record_index].event.parent_operation_id;
            if (parent_operation_id == 0) continue;
            const parent_index = self.operation_indices.get(
                parent_operation_id,
            ) orelse return error.DanglingParentOperation;
            self.records.items[record_index].next_sibling =
                self.records.items[parent_index].first_child;
            self.records.items[parent_index].first_child =
                @intCast(record_index + 1);
        }
        self.linked = true;
    }

    fn related(
        self: *Graph,
        operation_id: u64,
    ) !std.ArrayListUnmanaged(Related) {
        try self.link();
        const target_index = self.operation_indices.get(operation_id) orelse
            return error.OperationNotFound;
        var ancestors = std.ArrayListUnmanaged(u32).empty;
        defer ancestors.deinit(self.allocator);
        var current_index = target_index;
        var traversed: usize = 0;
        while (self.records.items[current_index].event.parent_operation_id != 0) {
            traversed += 1;
            if (traversed > self.records.items.len) {
                return error.CausalOperationCycle;
            }
            const parent_index = self.operation_indices.get(
                self.records.items[current_index].event.parent_operation_id,
            ) orelse return error.DanglingParentOperation;
            try ancestors.append(self.allocator, parent_index);
            current_index = parent_index;
        }

        var result = std.ArrayListUnmanaged(Related).empty;
        errdefer result.deinit(self.allocator);
        var ancestor_offset = ancestors.items.len;
        while (ancestor_offset > 0) {
            ancestor_offset -= 1;
            try result.append(self.allocator, .{
                .record_index = ancestors.items[ancestor_offset],
                .depth = @intCast(ancestors.items.len - ancestor_offset - 1),
                .relation = .ancestor,
            });
        }

        var pending = std.ArrayListUnmanaged(Work).empty;
        defer pending.deinit(self.allocator);
        try pending.append(self.allocator, .{
            .record_index = target_index,
            .depth = @intCast(ancestors.items.len),
        });
        while (pending.pop()) |work| {
            try result.append(self.allocator, .{
                .record_index = work.record_index,
                .depth = work.depth,
                .relation = if (work.record_index == target_index)
                    .target
                else
                    .descendant,
            });
            var child = self.records.items[work.record_index].first_child;
            while (child != 0) {
                const child_index = child - 1;
                try pending.append(self.allocator, .{
                    .record_index = child_index,
                    .depth = work.depth + 1,
                });
                child = self.records.items[child_index].next_sibling;
            }
        }
        std.mem.sort(Related, result.items, self, relatedLessThan);
        return result;
    }
};

pub fn writeFromPath(
    allocator: Allocator,
    events_path: []const u8,
    operation_id: u64,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    if (operation_id == 0 or
        options.frame_limit == 0 or
        options.frame_limit > stack.capture.max_frames_limit)
    {
        return error.InvalidCausalQuery;
    }
    var graph = Graph.init(allocator);
    defer graph.deinit();
    try ingestPath(&graph, events_path);
    try graph.stack.validate();
    var related = try graph.related(operation_id);
    defer related.deinit(allocator);

    var inferred_binary: ?[]u8 = null;
    defer if (inferred_binary) |path| allocator.free(path);
    const binary_path = options.binary_path orelse inferred: {
        inferred_binary = try stack.identity.artifactPathAlloc(
            allocator,
            events_path,
        );
        break :inferred inferred_binary.?;
    };
    const actual_digest = stack.identity.fileDigest(
        allocator,
        binary_path,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingExecutableArtifact,
        else => return err,
    };
    const expected_digest = graph.stack.executable_digest.?;
    if (!std.mem.eql(u8, &actual_digest, &expected_digest)) {
        return error.ExecutableIdentityMismatch;
    }

    var addresses = try collectAddresses(
        allocator,
        &graph,
        related.items,
        options.frame_limit,
    );
    defer addresses.deinit(allocator);
    var symbols = try stack.symbolize.resolveAlloc(
        allocator,
        binary_path,
        addresses.items,
    );
    defer symbols.deinit(allocator);
    switch (options.format) {
        .text => try writeText(
            writer,
            &graph,
            related.items,
            operation_id,
            options.frame_limit,
            &symbols,
            expected_digest,
        ),
        .jsonl => try writeJsonl(
            writer,
            &graph,
            related.items,
            operation_id,
            options.frame_limit,
            &symbols,
            expected_digest,
        ),
    }
}

fn ingestPath(graph: *Graph, path: []const u8) !void {
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
        try graph.ingestJsonLine(actual);
    }
}

fn collectAddresses(
    allocator: Allocator,
    graph: *const Graph,
    related: []const Related,
    frame_limit: usize,
) !std.ArrayListUnmanaged(u64) {
    var seen = std.AutoHashMapUnmanaged(u64, void){};
    defer seen.deinit(allocator);
    var addresses = std.ArrayListUnmanaged(u64).empty;
    errdefer addresses.deinit(allocator);
    for (related) |item| {
        const event = graph.records.items[item.record_index].event;
        const definition = graph.stack.stackDefinition(event.stack_id).?;
        const limit = @min(frame_limit, definition.call_addresses.len);
        for (definition.call_addresses[0..limit]) |address| {
            const entry = try seen.getOrPut(allocator, address);
            if (entry.found_existing) continue;
            try addresses.append(allocator, address);
        }
    }
    std.mem.sort(u64, addresses.items, {}, u64LessThan);
    return addresses;
}

fn writeText(
    writer: *std.Io.Writer,
    graph: *const Graph,
    related: []const Related,
    operation_id: u64,
    frame_limit: usize,
    symbols: *const stack.symbolize.Symbols,
    digest: stack.identity.Digest,
) !void {
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const root_event = graph.records.items[related[0].record_index].event;
    const coverage = graph.stack.coverage.?;
    try writer.print(
        "causal_operations status={s} universe={s} query_operation_id={d} " ++
            "root_operation_id={d} operations={d} process_complete={} " ++
            "binary_sha256={s}\n",
        .{
            coverage.statusTag(),
            coverage.universe.tag(),
            operation_id,
            root_event.operation_id,
            related.len,
            coverage.processComplete(),
            digest_hex,
        },
    );
    for (related) |item| {
        const event = graph.records.items[item.record_index].event;
        try writer.print(
            "operation relation={s} depth={d} seq={d} operation_id={d} " ++
                "parent_operation_id={d} layer={s} producer={s} kind={s} " ++
                "producer_id={d} allocator_id={d} allocation_id={d} " ++
                "scope_id={d} alignment={d} succeeded={} requested_bytes={d} " ++
                "address=0x{x} old_address=0x{x}\n",
            .{
                @tagName(item.relation),
                item.depth,
                event.seq.?,
                event.operation_id,
                event.parent_operation_id,
                event.layer.tag(),
                @tagName(event.producer),
                event.kind.tag(),
                event.producer_id,
                event.allocator_id,
                event.allocation_id,
                event.scope_id,
                event.alignment,
                event.succeeded,
                requestBytes(event),
                event.address,
                event.old_address,
            },
        );
        try writeTextFrames(
            writer,
            graph.stack.stackDefinition(event.stack_id).?,
            frame_limit,
            symbols,
        );
    }
}

fn writeTextFrames(
    writer: *std.Io.Writer,
    definition: stack.analyze.Definition,
    frame_limit: usize,
    symbols: *const stack.symbolize.Symbols,
) !void {
    const limit = @min(frame_limit, definition.call_addresses.len);
    for (definition.call_addresses[0..limit], 0..) |address, frame_index| {
        const resolved = symbols.find(address);
        try writer.print(
            "  frame={d} call_address=0x{x}",
            .{ frame_index, address },
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

fn writeJsonl(
    writer: *std.Io.Writer,
    graph: *const Graph,
    related: []const Related,
    operation_id: u64,
    frame_limit: usize,
    symbols: *const stack.symbolize.Symbols,
    digest: stack.identity.Digest,
) !void {
    const root_event = graph.records.items[related[0].record_index].event;
    const coverage = graph.stack.coverage.?;
    var summary_stream = pretty_json.Writer.init(writer, .minified);
    const summary = try summary_stream.object();
    try summary.field("kind", "causal_operation_summary");
    try summary.field("status", coverage.statusTag());
    try summary.field("universe", coverage.universe.tag());
    try summary.field("query_operation_id", operation_id);
    try summary.field("root_operation_id", root_event.operation_id);
    try summary.field("operations", related.len);
    try summary.field("process_complete", coverage.processComplete());
    try summary.hexString("binary_sha256", &digest);
    try summary.endLine();
    for (related) |item| {
        const event = graph.records.items[item.record_index].event;
        var event_stream = pretty_json.Writer.init(writer, .minified);
        const object = try event_stream.object();
        try object.field("kind", "causal_operation");
        try object.field("relation", @tagName(item.relation));
        try object.field("depth", item.depth);
        try object.field("seq", event.seq.?);
        try object.field("operation_id", event.operation_id);
        try object.field("parent_operation_id", event.parent_operation_id);
        try object.field("layer", event.layer.tag());
        try object.field("producer", @tagName(event.producer));
        try object.field("operation", event.kind.tag());
        try object.field("producer_id", event.producer_id);
        try object.field("allocator_id", event.allocator_id);
        try object.field("allocation_id", event.allocation_id);
        try object.field("scope_id", event.scope_id);
        try object.field("alignment", event.alignment);
        try object.field("succeeded", event.succeeded);
        try object.field("requested_bytes", requestBytes(event));
        try object.field("address", event.address);
        try object.field("old_address", event.old_address);
        try object.endLine();
        const definition = graph.stack.stackDefinition(event.stack_id).?;
        const limit = @min(frame_limit, definition.call_addresses.len);
        for (definition.call_addresses[0..limit], 0..) |address, frame_index| {
            const resolved = symbols.find(address);
            if (resolved.len == 0) {
                try writeJsonFrame(
                    writer,
                    event.operation_id,
                    frame_index,
                    address,
                    0,
                    "",
                    "",
                );
                continue;
            }
            for (resolved, 0..) |inline_frame, inline_index| {
                try writeJsonFrame(
                    writer,
                    event.operation_id,
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

fn writeJsonFrame(
    writer: *std.Io.Writer,
    operation_id: u64,
    frame_index: usize,
    address: u64,
    inline_index: usize,
    function: []const u8,
    location: []const u8,
) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("kind", "causal_operation_frame");
    try object.field("operation_id", operation_id);
    try object.field("frame", frame_index);
    try object.field("call_address", address);
    try object.field("inline", inline_index);
    try object.field("function", function);
    try object.field("location", location);
    try object.endLine();
}

fn requestBytes(event: event_mod.ReplayEvent) usize {
    return switch (event.kind) {
        .free, .release, .unmap => event.old_len,
        .alloc, .resize, .remap, .map, .protect, .discard, .decommit, .advise => event.len,
        else => unreachable,
    };
}

fn relatedLessThan(graph: *Graph, left: Related, right: Related) bool {
    const left_id =
        graph.records.items[left.record_index].event.operation_id;
    const right_id =
        graph.records.items[right.record_index].event.operation_id;
    return left_id < right_id;
}

fn u64LessThan(_: void, left: u64, right: u64) bool {
    return left < right;
}

test "causal graph returns ancestors target and descendants" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.ingestJsonLine(
        "{\"v\":3,\"seq\":1,\"kind\":\"alloc\",\"operation_id\":12," ++
            "\"parent_operation_id\":11,\"stack_id\":1," ++
            "\"layer\":\"logical_allocator\",\"producer\":\"debug\"}",
    );
    try graph.ingestJsonLine(
        "{\"v\":3,\"seq\":2,\"kind\":\"alloc\",\"operation_id\":11," ++
            "\"parent_operation_id\":10,\"stack_id\":1}",
    );
    try graph.ingestJsonLine(
        "{\"v\":3,\"seq\":3,\"kind\":\"alloc\",\"operation_id\":10," ++
            "\"stack_id\":1,\"layer\":\"logical_allocator\"," ++
            "\"producer\":\"arena\"}",
    );
    try graph.ingestJsonLine(
        "{\"v\":3,\"seq\":4,\"kind\":\"alloc\",\"operation_id\":20," ++
            "\"stack_id\":1,\"layer\":\"logical_allocator\"," ++
            "\"producer\":\"bump\"}",
    );
    var related = try graph.related(11);
    defer related.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), related.items.len);
    try std.testing.expectEqual(Relation.ancestor, related.items[0].relation);
    try std.testing.expectEqual(Relation.target, related.items[1].relation);
    try std.testing.expectEqual(Relation.descendant, related.items[2].relation);
    try std.testing.expectEqual(
        @as(u64, 10),
        graph.records.items[related.items[0].record_index].event.operation_id,
    );
    try std.testing.expectEqual(
        @as(u64, 12),
        graph.records.items[related.items[2].record_index].event.operation_id,
    );
}
