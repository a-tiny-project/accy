const std = @import("std");
const tracer_mod = @import("tracer.zig");
const census_mod = @import("census/root.zig");

pub const Span = struct {
    scope: ?tracer_mod.Scope = null,

    pub fn exit(self: *Span) void {
        if (self.scope) |*scope| scope.exit();
    }
};

/// A pair of borrowed callbacks that report the beginning and the end of a
/// phase, identified by a category byte. A caller with its own profiler uses
/// them to report memtrace's phase boundaries into that profiler. `begin` takes
/// the category and answers with a token, `end` takes that token back, and
/// neither call can fail. The owner keeps `context` alive for as long as the
/// sink is in use, because both callbacks receive it unchanged. A token is
/// closed from the thread that opened it, before any token opened after it,
/// which is the order `Context.enterInterval` and `IntervalSpan.exit` produce
/// when the spans nest lexically. The callbacks carry no synchronization of
/// their own, so one thread at a time uses a sink. `begin` answers with
/// `invalid_token` to decline a span, and the matching exit then calls nothing.
pub const IntervalSink = struct {
    pub const invalid_token = std.math.maxInt(u16);

    context: *anyopaque,
    begin_fn: *const fn (*anyopaque, u8) u16,
    end_fn: *const fn (*anyopaque, u16) void,

    pub fn begin(self: IntervalSink, category: u8) u16 {
        return self.begin_fn(self.context, category);
    }

    pub fn end(self: IntervalSink, token: u16) void {
        self.end_fn(self.context, token);
    }
};

pub const IntervalSpan = struct {
    sink: ?IntervalSink = null,
    token: u16 = IntervalSink.invalid_token,

    pub fn exit(self: *IntervalSpan) void {
        const sink = self.sink orelse return;
        if (self.token != IntervalSink.invalid_token) sink.end(self.token);
        self.sink = null;
        self.token = IntervalSink.invalid_token;
    }
};

pub const Context = struct {
    tracer: ?*tracer_mod.Tracer = null,
    census: ?*census_mod.Census = null,
    intervals: ?IntervalSink = null,

    pub fn init(tracer: ?*tracer_mod.Tracer, census: ?*census_mod.Census) Context {
        return .{
            .tracer = tracer,
            .census = census,
        };
    }

    pub fn disabled() Context {
        return .{};
    }

    pub fn tracesAllocations(self: Context) bool {
        return self.tracer != null;
    }

    pub fn recordsCensus(self: Context) bool {
        return self.census != null;
    }

    pub fn enabled(self: Context) bool {
        return self.tracesAllocations() or self.recordsCensus() or
            self.intervals != null;
    }

    pub fn withIntervals(self: Context, intervals: ?IntervalSink) Context {
        var result = self;
        result.intervals = intervals;
        return result;
    }

    pub fn enter(self: Context, label: []const u8) !Span {
        const actual = self.tracer orelse return .{};
        return .{ .scope = try actual.enter(label) };
    }

    pub fn enterInterval(self: Context, category: u8) IntervalSpan {
        const sink = self.intervals orelse return .{};
        const token = sink.begin(category);
        if (token == IntervalSink.invalid_token) return .{};
        return .{ .sink = sink, .token = token };
    }

    pub fn record(self: Context, label: []const u8, bytes: usize) !void {
        const actual = self.census orelse return;
        try actual.record(label, bytes);
    }

    pub fn recordPrefixed(self: Context, prefix: []const u8, label: []const u8, bytes: usize) !void {
        const actual = self.census orelse return;
        try actual.recordPrefixed(prefix, label, bytes);
    }

    pub fn recordCount(self: Context, label: []const u8, count: usize, bytes: usize) !void {
        const actual = self.census orelse return;
        try actual.recordCount(label, count, bytes);
    }

    pub fn recordCountPrefixed(self: Context, prefix: []const u8, label: []const u8, count: usize, bytes: usize) !void {
        const actual = self.census orelse return;
        try actual.recordCountPrefixed(prefix, label, count, bytes);
    }
};

const IntervalTestRecorder = struct {
    began: [8]u8 = undefined,
    ended: [8]u16 = undefined,
    begin_count: usize = 0,
    end_count: usize = 0,

    fn sink(self: *IntervalTestRecorder) IntervalSink {
        return .{
            .context = self,
            .begin_fn = begin,
            .end_fn = end,
        };
    }

    fn begin(opaque_context: *anyopaque, category: u8) u16 {
        const self: *IntervalTestRecorder = @ptrCast(@alignCast(opaque_context));
        if (category == 255) return IntervalSink.invalid_token;
        std.debug.assert(self.begin_count < self.began.len);
        const token = std.math.cast(u16, self.begin_count).?;
        self.began[self.begin_count] = category;
        self.begin_count += 1;
        return token;
    }

    fn end(opaque_context: *anyopaque, token: u16) void {
        const self: *IntervalTestRecorder = @ptrCast(@alignCast(opaque_context));
        std.debug.assert(self.end_count < self.ended.len);
        self.ended[self.end_count] = token;
        self.end_count += 1;
    }
};

test "disabled context is a no-op participation surface" {
    const context = Context.disabled();
    try std.testing.expect(!context.enabled());

    var span = try context.enter("phase");
    defer span.exit();
    try context.record("runtime.value.string", 32);
    try context.recordPrefixed("global.page.", "runtime.value.record", 16);
}

test "context records allocation scopes and census entries" {
    var tracer = try tracer_mod.Tracer.init(std.testing.allocator, .{});
    defer tracer.deinit();
    var census_storage = try census_mod.Storage.init(std.testing.allocator, .{
        .categories = 4,
        .label_bytes = 128,
        .joined_label_bytes = 64,
    });
    defer census_storage.deinit(std.testing.allocator);
    census_storage.activate();
    var census = try census_mod.Census.init(&census_storage);
    defer census.deinit();

    var traced = try tracer.tracedAllocator(std.testing.allocator, "test.heap");
    const allocator = traced.allocator();
    const context = Context.init(&tracer, &census);

    var span = try context.enter("phase");
    const bytes = try allocator.alloc(u8, 24);
    try context.record("runtime.value.bytes", bytes.len);
    span.exit();
    allocator.free(bytes);

    var trace_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace_out.deinit();
    try tracer.writeSummary(&trace_out.writer, .{ .top = 4, .include_zero_live = true });
    try std.testing.expect(std.mem.indexOf(u8, trace_out.written(), "root/phase") != null);

    var census_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer census_out.deinit();
    try census.writeSummary(&census_out.writer, .{ .top = 4 });
    try std.testing.expect(std.mem.indexOf(u8, census_out.written(), "runtime.value.bytes items=1 bytes=24") != null);
}

test "interval context preserves nested repeated and ignored spans" {
    var recorder: IntervalTestRecorder = .{};
    const context = Context.disabled().withIntervals(recorder.sink());
    try std.testing.expect(context.enabled());
    try std.testing.expect(!context.tracesAllocations());

    var outer = context.enterInterval(3);
    var inner = context.enterInterval(3);
    var ignored = context.enterInterval(255);
    ignored.exit();
    inner.exit();
    outer.exit();

    try std.testing.expectEqualSlices(u8, &.{ 3, 3 }, recorder.began[0..recorder.begin_count]);
    try std.testing.expectEqualSlices(u16, &.{ 1, 0 }, recorder.ended[0..recorder.end_count]);
}
