const std = @import("std");
const sys = @import("sys");
const event = @import("event.zig");
const record_mod = @import("record.zig");

pub const Export = enum {
    zones,
    messages,
    plots,
    allocs,

    pub fn fromName(text: []const u8) ?Export {
        if (std.mem.eql(u8, text, "zones")) return .zones;
        if (std.mem.eql(u8, text, "messages")) return .messages;
        if (std.mem.eql(u8, text, "plots")) return .plots;
        if (std.mem.eql(u8, text, "allocs")) return .allocs;
        return null;
    }
};

const ActiveZone = struct {
    name: []u8,
    text: ?[]u8 = null,
    file: ?[]u8 = null,
    line: u32 = 0,
    start_ns: u64 = 0,
    thread: u64 = 0,
    value: ?u64 = null,

    fn deinit(self: *ActiveZone, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.text) |text| allocator.free(text);
        if (self.file) |file| allocator.free(file);
        self.* = undefined;
    }
};

pub fn writeFromJsonlPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    mode: Export,
) !void {
    var file = try sys.fs.cwd().openFile(sys.fs.debugIo(), path, .{});
    defer file.close(sys.fs.debugIo());

    switch (mode) {
        .zones => try writer.writeAll("name,src_file,src_line,ns_since_start,exec_time_ns,thread,value,text\n"),
        .messages => try writer.writeAll("ns_since_start,time_ns,thread,text\n"),
        .plots => try writer.writeAll(
            "event,name,ns_since_start,time_ns,thread,value,kind,unit,step,fill,color\n",
        ),
        .allocs => try writer.writeAll("kind,name,ns_since_start,time_ns,thread,address,size\n"),
    }

    var active_zones: std.AutoHashMapUnmanaged(u64, ActiveZone) = .{};
    defer {
        var iter = active_zones.valueIterator();
        while (iter.next()) |zone| zone.deinit(allocator);
        active_zones.deinit(allocator);
    }

    var base_ns: ?u64 = null;
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(sys.fs.debugIo(), &buffer);
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        const actual = line orelse break;
        const text = std.mem.trim(u8, actual, " \t\r\n");
        if (text.len == 0) continue;
        var parsed = (try record_mod.parseEventLine(allocator, text)) orelse continue;
        defer parsed.deinit();
        if (base_ns == null and parsed.time_ns != 0) base_ns = parsed.time_ns;
        switch (mode) {
            .zones => try handleZoneEvent(allocator, writer, &active_zones, base_ns orelse parsed.time_ns, parsed),
            .messages => if (parsed.kind == .message) try writeMessage(writer, base_ns orelse parsed.time_ns, parsed),
            .plots => if (parsed.kind == .plot or parsed.kind == .plot_config) {
                try writePlot(writer, base_ns orelse parsed.time_ns, parsed);
            },
            .allocs => if (parsed.kind == .alloc or parsed.kind == .free) try writeAlloc(writer, base_ns orelse parsed.time_ns, parsed),
        }
    }
}

fn handleZoneEvent(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    active_zones: *std.AutoHashMapUnmanaged(u64, ActiveZone),
    base_ns: u64,
    parsed: event.Parsed,
) !void {
    switch (parsed.kind) {
        .zone_begin => {
            if (parsed.id == 0) return;
            if (active_zones.fetchRemove(parsed.id)) |removed| {
                var old = removed.value;
                old.deinit(allocator);
            }
            try active_zones.put(allocator, parsed.id, .{
                .name = try allocator.dupe(u8, parsed.name orelse "<zone>"),
                .file = try dupeOptional(allocator, parsed.file),
                .line = parsed.line,
                .start_ns = parsed.time_ns,
                .thread = parsed.thread,
            });
        },
        .zone_name => {
            const name = parsed.name orelse return;
            const zone = active_zones.getPtr(parsed.id) orelse return;
            allocator.free(zone.name);
            zone.name = try allocator.dupe(u8, name);
        },
        .zone_value => {
            const value = parsed.value_u64 orelse return;
            const zone = active_zones.getPtr(parsed.id) orelse return;
            zone.value = value;
        },
        .zone_text => {
            const text = parsed.text orelse return;
            const zone = active_zones.getPtr(parsed.id) orelse return;
            zone.text = try appendText(allocator, zone.text, text);
        },
        .zone_end => {
            const removed = active_zones.fetchRemove(parsed.id) orelse return;
            var zone = removed.value;
            defer zone.deinit(allocator);
            const duration = if (parsed.time_ns >= zone.start_ns) parsed.time_ns - zone.start_ns else 0;
            try writeCsvString(writer, zone.name);
            try writer.writeByte(',');
            if (zone.file) |file| try writeCsvString(writer, file);
            try writer.print(",{d},{d},{d},{d},", .{
                zone.line,
                nsSince(base_ns, zone.start_ns),
                duration,
                zone.thread,
            });
            if (zone.value) |value| try writer.print("{d}", .{value});
            try writer.writeByte(',');
            if (zone.text) |text| try writeCsvString(writer, text);
            try writer.writeByte('\n');
        },
        else => {},
    }
}

fn writeMessage(writer: *std.Io.Writer, base_ns: u64, parsed: event.Parsed) !void {
    try writer.print("{d},{d},{d},", .{ nsSince(base_ns, parsed.time_ns), parsed.time_ns, parsed.thread });
    try writeCsvString(writer, parsed.text orelse "");
    try writer.writeByte('\n');
}

fn writePlot(writer: *std.Io.Writer, base_ns: u64, parsed: event.Parsed) !void {
    try writeCsvString(writer, parsed.kind.tag());
    try writer.writeByte(',');
    try writeCsvString(writer, parsed.name orelse "");
    try writer.print(",{d},{d},{d},", .{ nsSince(base_ns, parsed.time_ns), parsed.time_ns, parsed.thread });
    if (parsed.value_f64) |value| {
        try writer.print("{d}", .{value});
    } else if (parsed.value_i64) |value| {
        try writer.print("{d}", .{value});
    }
    try writer.writeByte(',');
    try writeCsvString(writer, parsed.plot_kind orelse "");
    try writer.writeByte(',');
    try writeCsvString(writer, parsed.plot_unit orelse "");
    try writer.writeByte(',');
    if (parsed.kind == .plot_config) try writer.print("{}", .{parsed.plot_step});
    try writer.writeByte(',');
    if (parsed.kind == .plot_config) try writer.print("{}", .{parsed.plot_fill});
    try writer.writeByte(',');
    if (parsed.kind == .plot_config) {
        if (parsed.color) |color| try writer.print("{d}", .{color});
    }
    try writer.writeByte('\n');
}

fn writeAlloc(writer: *std.Io.Writer, base_ns: u64, parsed: event.Parsed) !void {
    try writeCsvString(writer, parsed.kind.tag());
    try writer.writeByte(',');
    try writeCsvString(writer, parsed.name orelse "");
    try writer.print(",{d},{d},{d},{d},{d}\n", .{
        nsSince(base_ns, parsed.time_ns),
        parsed.time_ns,
        parsed.thread,
        parsed.address,
        parsed.size,
    });
}

fn writeCsvString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\"\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]u8 {
    const actual = text orelse return null;
    return try allocator.dupe(u8, actual);
}

fn appendText(allocator: std.mem.Allocator, existing: ?[]u8, addition: []const u8) ![]u8 {
    if (existing) |old| {
        const joined = try allocator.alloc(u8, old.len + 1 + addition.len);
        @memcpy(joined[0..old.len], old);
        joined[old.len] = '\n';
        @memcpy(joined[old.len + 1 ..], addition);
        allocator.free(old);
        return joined;
    }
    return try allocator.dupe(u8, addition);
}

fn nsSince(base_ns: u64, time_ns: u64) u64 {
    if (time_ns <= base_ns) return 0;
    return time_ns - base_ns;
}

test "csv export emits completed zone rows" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 100, .thread = 1, .name = "test" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .zone_begin, .time_ns = 110, .thread = 1, .id = 7, .name = "phase", .file = "phase.zig", .line = 9 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .zone_value, .time_ns = 120, .thread = 1, .id = 7, .value_u64 = 42 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .zone_text, .time_ns = 130, .thread = 1, .id = 7, .text = "note" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .zone_end, .time_ns = 160, .thread = 1, .id = 7 }).writeJsonLine(&trace.writer);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "trace.jsonl" });
    defer std.testing.allocator.free(path);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = path, .data = trace.written() });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeFromJsonlPath(std.testing.allocator, path, &out.writer, .zones);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"phase\",\"phase.zig\",9,10,50,1,42,\"note\"") != null);
}

test "csv export includes allocation names and sized frees" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 100, .thread = 1, .name = "test" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .alloc, .time_ns = 110, .thread = 1, .name = "arena", .address = 4096, .size = 64 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .free, .time_ns = 120, .thread = 1, .name = "arena", .address = 4096, .size = 64 }).writeJsonLine(&trace.writer);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "trace.jsonl" });
    defer std.testing.allocator.free(path);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = path, .data = trace.written() });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeFromJsonlPath(std.testing.allocator, path, &out.writer, .allocs);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "kind,name,ns_since_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"alloc\",\"arena\",10,110,1,4096,64") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"free\",\"arena\",20,120,1,4096,64") != null);
}

test "csv plot export includes configuration metadata" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{
        .seq = 1,
        .kind = .plot_config,
        .time_ns = 100,
        .thread = 1,
        .name = "heap.live",
        .color = 7,
        .plot_unit = "bytes",
        .plot_step = true,
        .plot_fill = true,
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 2,
        .kind = .plot,
        .time_ns = 110,
        .thread = 1,
        .name = "heap.live",
        .value_i64 = 64,
        .plot_kind = "int",
    }).writeJsonLine(&trace.writer);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.parent_dir.realPathFileAlloc(
        sys.fs.debugIo(),
        tmp.sub_path[0..],
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "trace.jsonl" });
    defer std.testing.allocator.free(path);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = path, .data = trace.written() });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeFromJsonlPath(std.testing.allocator, path, &out.writer, .plots);
    const csv = out.written();
    try std.testing.expect(std.mem.indexOf(u8, csv, "event,name,ns_since_start") != null);
    const config = "\"plot.config\",\"heap.live\",0,100,1,,\"\",\"bytes\",true,true,7";
    try std.testing.expect(std.mem.indexOf(u8, csv, config) != null);
    const sample = "\"plot\",\"heap.live\",10,110,1,64,\"int\",\"\",,,";
    try std.testing.expect(std.mem.indexOf(u8, csv, sample) != null);
}
