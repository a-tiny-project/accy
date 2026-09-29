const std = @import("std");
const observe = @import("alloc_observe");
const pretty_json = @import("pretty").json;

pub const format_version: u32 = 3;

pub const Layer = enum {
    backing_boundary,
    logical_allocator,
    physical_page,

    pub fn tag(self: Layer) []const u8 {
        return @tagName(self);
    }

    pub fn fromTag(text: []const u8) ?Layer {
        return std.meta.stringToEnum(Layer, text);
    }
};

pub const LayerFilter = enum {
    backing,
    logical,
    physical,
    all,

    pub fn includes(self: LayerFilter, layer: Layer) bool {
        return switch (self) {
            .backing => layer == .backing_boundary,
            .logical => layer == .logical_allocator,
            .physical => layer == .physical_page,
            .all => true,
        };
    }

    pub fn tag(self: LayerFilter) []const u8 {
        return @tagName(self);
    }

    pub fn fromTag(text: []const u8) ?LayerFilter {
        return std.meta.stringToEnum(LayerFilter, text);
    }
};

pub const Kind = enum {
    trace_start,
    trace_stop,
    allocator,
    scope_enter,
    scope_exit,
    alloc,
    free,
    release,
    resize,
    remap,
    lifecycle,
    map,
    unmap,
    protect,
    discard,
    decommit,
    snapshot,
    census,
    advise,

    pub fn tag(self: Kind) []const u8 {
        return switch (self) {
            .trace_start => "trace.start",
            .trace_stop => "trace.stop",
            .allocator => "allocator",
            .scope_enter => "scope.enter",
            .scope_exit => "scope.exit",
            .alloc => "alloc",
            .free => "free",
            .release => "release",
            .resize => "resize",
            .remap => "remap",
            .lifecycle => "lifecycle",
            .map => "map",
            .unmap => "unmap",
            .protect => "protect",
            .discard => "discard",
            .decommit => "decommit",
            .advise => "advise",
            .snapshot => "snapshot",
            .census => "census",
        };
    }

    pub fn fromTag(text: []const u8) ?Kind {
        if (std.mem.eql(u8, text, "trace.start")) return .trace_start;
        if (std.mem.eql(u8, text, "trace.stop")) return .trace_stop;
        if (std.mem.eql(u8, text, "allocator")) return .allocator;
        if (std.mem.eql(u8, text, "scope.enter")) return .scope_enter;
        if (std.mem.eql(u8, text, "scope.exit")) return .scope_exit;
        if (std.mem.eql(u8, text, "alloc")) return .alloc;
        if (std.mem.eql(u8, text, "free")) return .free;
        if (std.mem.eql(u8, text, "release")) return .release;
        if (std.mem.eql(u8, text, "resize")) return .resize;
        if (std.mem.eql(u8, text, "remap")) return .remap;
        if (std.mem.eql(u8, text, "lifecycle")) return .lifecycle;
        if (std.mem.eql(u8, text, "map")) return .map;
        if (std.mem.eql(u8, text, "unmap")) return .unmap;
        if (std.mem.eql(u8, text, "protect")) return .protect;
        if (std.mem.eql(u8, text, "discard")) return .discard;
        if (std.mem.eql(u8, text, "decommit")) return .decommit;
        if (std.mem.eql(u8, text, "advise")) return .advise;
        if (std.mem.eql(u8, text, "snapshot")) return .snapshot;
        if (std.mem.eql(u8, text, "census")) return .census;
        return null;
    }

    /// Reads the wire tag, so that `trace_start` parses from `"trace.start"`.
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Kind {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const text = switch (token) {
            .string, .allocated_string => |text| text,
            else => return error.UnexpectedToken,
        };
        return fromTag(text) orelse error.InvalidEnumTag;
    }

    pub fn isMemoryOperation(self: Kind) bool {
        return switch (self) {
            .alloc,
            .free,
            .release,
            .resize,
            .remap,
            .map,
            .unmap,
            .protect,
            .discard,
            .decommit,
            .advise,
            => true,
            else => false,
        };
    }
};

pub const Event = struct {
    seq: u64 = 0,
    kind: Kind,
    allocator_id: u32 = 0,
    allocation_id: u64 = 0,
    scope_id: u32 = 0,
    label_id: u32 = 0,
    address: usize = 0,
    old_address: usize = 0,
    len: usize = 0,
    old_len: usize = 0,
    alignment: u32 = 0,
    return_address: usize = 0,
    stack_id: u32 = 0,
    succeeded: bool = true,
    tracked: bool = true,
    live_bytes: usize = 0,
    recording_failures: u64 = 0,
    retains_freed_memory: bool = false,
    layer: Layer = .backing_boundary,
    operation_id: u64 = 0,
    parent_operation_id: u64 = 0,
    producer_id: u64 = 0,
    producer: observe.Producer = .boundary,
    generation: u64 = 0,
    owner_cookie: usize = 0,
    lifecycle_disposition: observe.LifecycleDisposition = .none,
    lifecycle_reason: observe.LifecycleReason = .none,
    lifecycle_instrumented: bool = false,
    observation_prefix_complete: bool = true,

    pub fn writeJsonLine(
        self: Event,
        writer: *std.Io.Writer,
        label_text: ?[]const u8,
        scope_text: ?[]const u8,
    ) !void {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("v", format_version);
        try object.field("seq", self.seq);
        try object.field("kind", self.kind.tag());
        if (self.allocator_id != 0) try object.field("allocator_id", self.allocator_id);
        if (self.allocation_id != 0) try object.field("allocation_id", self.allocation_id);
        if (self.scope_id != 0) try object.field("scope_id", self.scope_id);
        if (self.address != 0) try object.field("address", self.address);
        if (self.old_address != 0 and self.old_address != self.address) {
            try object.field("old_address", self.old_address);
        }
        if (self.len != 0) try object.field("len", self.len);
        if (self.old_len != 0) try object.field("old_len", self.old_len);
        if (self.alignment != 0) try object.field("alignment", self.alignment);
        if (self.return_address != 0) try object.field("return_address", self.return_address);
        if (self.stack_id != 0) try object.field("stack_id", self.stack_id);
        if (!self.succeeded) try object.field("succeeded", false);
        if (!self.tracked) try object.field("tracked", false);
        if (self.recording_failures != 0) {
            try object.field("recording_failures", self.recording_failures);
        }
        if (self.retains_freed_memory) try object.field("retains_freed_memory", true);
        if (self.layer != .backing_boundary) try object.field("layer", self.layer.tag());
        if (self.operation_id != 0) try object.field("operation_id", self.operation_id);
        if (self.parent_operation_id != 0) {
            try object.field("parent_operation_id", self.parent_operation_id);
        }
        if (self.producer_id != 0) try object.field("producer_id", self.producer_id);
        if (self.producer != .boundary) try object.field("producer", @tagName(self.producer));
        if (self.generation != 0) try object.field("generation", self.generation);
        if (self.owner_cookie != 0) try object.field("owner_cookie", self.owner_cookie);
        if (self.lifecycle_disposition != .none) {
            try object.field(
                "lifecycle_disposition",
                @tagName(self.lifecycle_disposition),
            );
        }
        if (self.lifecycle_reason != .none) {
            try object.field("lifecycle_reason", @tagName(self.lifecycle_reason));
        }
        if (self.lifecycle_instrumented) {
            try object.field("lifecycle_instrumented", true);
        }
        if (!self.observation_prefix_complete) {
            try object.field("observation_prefix_complete", false);
        }
        if (label_text) |text| try object.field("label", text);
        if (scope_text) |text| try object.field("scope", text);
        try object.endLine();
    }
};

/// One event line, field for field as `Event.writeJsonLine` writes it. A
/// field the writer omits takes the value the writer omitted, and an absent
/// `old_address` means the address did not move.
pub const Record = struct {
    v: u64,
    seq: ?u64 = null,
    kind: Kind,
    allocator_id: u32 = 0,
    allocation_id: u64 = 0,
    scope_id: u32 = 0,
    address: u64 = 0,
    old_address: ?u64 = null,
    len: usize = 0,
    old_len: usize = 0,
    alignment: u32 = 0,
    return_address: u64 = 0,
    stack_id: u32 = 0,
    succeeded: bool = true,
    tracked: bool = true,
    recording_failures: u64 = 0,
    retains_freed_memory: bool = false,
    layer: Layer = .backing_boundary,
    operation_id: u64 = 0,
    parent_operation_id: u64 = 0,
    producer_id: u64 = 0,
    producer: observe.Producer = .boundary,
    generation: u64 = 0,
    owner_cookie: u64 = 0,
    lifecycle_disposition: observe.LifecycleDisposition = .none,
    lifecycle_reason: observe.LifecycleReason = .none,
    lifecycle_instrumented: bool = false,
    observation_prefix_complete: bool = true,
    label: ?[]const u8 = null,
    scope: []const u8 = "",
};

pub const ReplayEvent = struct {
    seq: ?u64 = null,
    kind: Kind,
    allocator_id: u32 = 0,
    allocation_id: u64 = 0,
    scope_id: u32 = 0,
    address: u64 = 0,
    old_address: u64 = 0,
    len: usize = 0,
    old_len: usize = 0,
    alignment: u32 = 0,
    return_address: u64 = 0,
    stack_id: u32 = 0,
    succeeded: bool = true,
    tracked: bool = true,
    recording_failures: u64 = 0,
    scope: []const u8 = "root",
    retains_freed_memory: bool = false,
    layer: Layer = .backing_boundary,
    operation_id: u64 = 0,
    parent_operation_id: u64 = 0,
    producer_id: u64 = 0,
    producer: observe.Producer = .boundary,
    generation: u64 = 0,
    owner_cookie: u64 = 0,
    lifecycle_disposition: observe.LifecycleDisposition = .none,
    lifecycle_reason: observe.LifecycleReason = .none,
    lifecycle_instrumented: bool = false,
    observation_prefix_complete: bool = true,
};

const CanonicalCursor = struct {
    line: []const u8,
    index: usize = 0,

    fn expect(self: *CanonicalCursor, expected: []const u8) !void {
        if (!std.mem.startsWith(u8, self.line[self.index..], expected)) return error.UnsupportedFastEvent;
        self.index += expected.len;
    }

    fn consume(self: *CanonicalCursor, expected: []const u8) bool {
        if (!std.mem.startsWith(u8, self.line[self.index..], expected)) return false;
        self.index += expected.len;
        return true;
    }

    /// JSON has no leading zeros, so a line with one is not canonical.
    fn unsigned(self: *CanonicalCursor) !u64 {
        const start = self.index;
        var value: u64 = 0;
        var digits: usize = 0;
        while (self.index < self.line.len and self.line[self.index] >= '0' and self.line[self.index] <= '9') : (self.index += 1) {
            const digit: u64 = self.line[self.index] - '0';
            if (digits == 19) {
                if (value > std.math.maxInt(u64) / 10 or
                    (value == std.math.maxInt(u64) / 10 and digit > std.math.maxInt(u64) % 10)) return error.InvalidEventJson;
            } else if (digits > 19) {
                return error.UnsupportedFastEvent;
            }
            value = value * 10 + digit;
            digits += 1;
        }
        if (digits == 0) return error.UnsupportedFastEvent;
        if (digits > 1 and self.line[start] == '0') return error.UnsupportedFastEvent;
        return value;
    }

    fn skipUnsigned(self: *CanonicalCursor) !void {
        const start = self.index;
        while (self.index < self.line.len and self.line[self.index] >= '0' and self.line[self.index] <= '9') : (self.index += 1) {}
        if (self.index == start) return error.UnsupportedFastEvent;
        if (self.index - start > 1 and self.line[start] == '0') return error.UnsupportedFastEvent;
    }

    /// Reads a string that needs no decoding. Escapes, bare control bytes
    /// and invalid UTF-8 are left to std.json.
    fn string(self: *CanonicalCursor) ![]const u8 {
        try self.expect("\"");
        const start = self.index;
        var ascii = true;
        while (self.index < self.line.len) : (self.index += 1) {
            switch (self.line[self.index]) {
                '"' => {
                    const value = self.line[start..self.index];
                    self.index += 1;
                    if (!ascii and !std.unicode.utf8ValidateSlice(value)) {
                        return error.UnsupportedFastEvent;
                    }
                    return value;
                },
                '\\', 0...0x1f => return error.UnsupportedFastEvent,
                0x80...0xff => ascii = false,
                else => {},
            }
        }
        return error.InvalidEventJson;
    }

    fn boolean(self: *CanonicalCursor) !bool {
        if (self.consume("true")) return true;
        if (self.consume("false")) return false;
        return error.UnsupportedFastEvent;
    }

    fn finish(self: *CanonicalCursor) !void {
        try self.expect("}");
        if (self.index != self.line.len) return error.UnsupportedFastEvent;
    }
};

pub const ReplayError = error{
    OutOfMemory,
    InvalidEventJson,
    UnsupportedTraceVersion,
};

/// Decodes one event line. The two canonical layouts decode in place, and
/// every other line goes through `Record`. Strings borrow from `line` or
/// live in `arena`, so the event lives as long as both do.
pub fn parseReplay(arena: std.mem.Allocator, line: []const u8) ReplayError!ReplayEvent {
    return parseFast(line) catch |err| switch (err) {
        error.UnsupportedFastEvent => parseRecord(arena, line),
        error.InvalidEventJson, error.UnsupportedTraceVersion => |fault| fault,
    };
}

/// Decodes a line in either byte layout the writer has produced, sparse
/// then dense. A line in neither layout is `UnsupportedFastEvent`. A line
/// this accepts decodes to the same event through `parseRecord`.
pub fn parseFast(line: []const u8) error{
    UnsupportedFastEvent,
    InvalidEventJson,
    UnsupportedTraceVersion,
}!ReplayEvent {
    return parseSparseCanonical(line) catch |sparse_err| switch (sparse_err) {
        error.UnsupportedFastEvent => parseCanonical(line),
        else => sparse_err,
    };
}

/// Decodes one event line through `Record`. std.json decides whether the
/// line is well formed, and unknown fields load for older and newer writers.
pub fn parseRecord(arena: std.mem.Allocator, line: []const u8) ReplayError!ReplayEvent {
    const record = std.json.parseFromSliceLeaky(Record, arena, line, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return versionFault(arena, line),
    };
    if (record.v != format_version) return error.UnsupportedTraceVersion;
    return .{
        .seq = record.seq,
        .kind = record.kind,
        .allocator_id = record.allocator_id,
        .allocation_id = record.allocation_id,
        .scope_id = record.scope_id,
        .address = record.address,
        .old_address = record.old_address orelse record.address,
        .len = record.len,
        .old_len = record.old_len,
        .alignment = record.alignment,
        .return_address = record.return_address,
        .stack_id = record.stack_id,
        .succeeded = record.succeeded,
        .tracked = record.tracked,
        .recording_failures = record.recording_failures,
        .scope = record.scope,
        .retains_freed_memory = record.retains_freed_memory,
        .layer = record.layer,
        .operation_id = record.operation_id,
        .parent_operation_id = record.parent_operation_id,
        .producer_id = record.producer_id,
        .producer = record.producer,
        .generation = record.generation,
        .owner_cookie = record.owner_cookie,
        .lifecycle_disposition = record.lifecycle_disposition,
        .lifecycle_reason = record.lifecycle_reason,
        .lifecycle_instrumented = record.lifecycle_instrumented,
        .observation_prefix_complete = record.observation_prefix_complete,
    };
}

/// Names the fault of a line that is not a version 3 record. A readable
/// version other than 3 outranks every other fault, because a newer writer's
/// fields are not this reader's to judge.
fn versionFault(arena: std.mem.Allocator, line: []const u8) ReplayError {
    const header = std.json.parseFromSliceLeaky(struct { v: u64 }, arena, line, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEventJson,
    };
    if (header.v != format_version) return error.UnsupportedTraceVersion;
    return error.InvalidEventJson;
}

fn parseSparseCanonical(line: []const u8) !ReplayEvent {
    var cursor = CanonicalCursor{ .line = line };
    try cursor.expect("{\"v\":");
    const version = try cursor.unsigned();
    if (version != format_version) return error.UnsupportedTraceVersion;
    try cursor.expect(",\"seq\":");
    const seq = try cursor.unsigned();
    try cursor.expect(",\"kind\":");
    const kind = Kind.fromTag(try cursor.string()) orelse
        return error.InvalidEventJson;
    const allocator_id = if (cursor.consume(",\"allocator_id\":"))
        std.math.cast(u32, try cursor.unsigned()) orelse
            return error.InvalidEventJson
    else
        0;
    const allocation_id = if (cursor.consume(",\"allocation_id\":"))
        try cursor.unsigned()
    else
        0;
    const scope_id = if (cursor.consume(",\"scope_id\":"))
        std.math.cast(u32, try cursor.unsigned()) orelse
            return error.InvalidEventJson
    else
        0;
    const address = if (cursor.consume(",\"address\":"))
        try cursor.unsigned()
    else
        0;
    const old_address = if (cursor.consume(",\"old_address\":"))
        try cursor.unsigned()
    else
        address;
    const len = if (cursor.consume(",\"len\":"))
        std.math.cast(usize, try cursor.unsigned()) orelse
            return error.InvalidEventJson
    else
        0;
    const old_len = if (cursor.consume(",\"old_len\":"))
        std.math.cast(usize, try cursor.unsigned()) orelse
            return error.InvalidEventJson
    else
        0;
    const alignment = if (cursor.consume(",\"alignment\":"))
        std.math.cast(u32, try cursor.unsigned()) orelse
            return error.InvalidEventJson
    else
        0;
    const return_address = if (cursor.consume(",\"return_address\":"))
        try cursor.unsigned()
    else
        0;
    const stack_id = if (cursor.consume(",\"stack_id\":"))
        std.math.cast(u32, try cursor.unsigned()) orelse
            return error.InvalidEventJson
    else
        0;
    const succeeded = if (cursor.consume(",\"succeeded\":"))
        try cursor.boolean()
    else
        true;
    const tracked = if (cursor.consume(",\"tracked\":"))
        try cursor.boolean()
    else
        true;
    const recording_failures =
        if (cursor.consume(",\"recording_failures\":"))
            try cursor.unsigned()
        else
            0;
    const retains_freed_memory =
        if (cursor.consume(",\"retains_freed_memory\":"))
            try cursor.boolean()
        else
            false;
    const layer = if (cursor.consume(",\"layer\":"))
        Layer.fromTag(try cursor.string()) orelse
            return error.InvalidEventJson
    else
        .backing_boundary;
    const operation_id = if (cursor.consume(",\"operation_id\":"))
        try cursor.unsigned()
    else
        0;
    const parent_operation_id =
        if (cursor.consume(",\"parent_operation_id\":"))
            try cursor.unsigned()
        else
            0;
    const producer_id = if (cursor.consume(",\"producer_id\":"))
        try cursor.unsigned()
    else
        0;
    const producer = if (cursor.consume(",\"producer\":"))
        std.meta.stringToEnum(observe.Producer, try cursor.string()) orelse
            return error.InvalidEventJson
    else
        .boundary;
    const generation = if (cursor.consume(",\"generation\":"))
        try cursor.unsigned()
    else
        0;
    const owner_cookie = if (cursor.consume(",\"owner_cookie\":"))
        try cursor.unsigned()
    else
        0;
    const lifecycle_disposition =
        if (cursor.consume(",\"lifecycle_disposition\":"))
            std.meta.stringToEnum(
                observe.LifecycleDisposition,
                try cursor.string(),
            ) orelse return error.InvalidEventJson
        else
            .none;
    const lifecycle_reason =
        if (cursor.consume(",\"lifecycle_reason\":"))
            std.meta.stringToEnum(
                observe.LifecycleReason,
                try cursor.string(),
            ) orelse return error.InvalidEventJson
        else
            .none;
    const lifecycle_instrumented =
        if (cursor.consume(",\"lifecycle_instrumented\":"))
            try cursor.boolean()
        else
            false;
    const observation_prefix_complete =
        if (cursor.consume(",\"observation_prefix_complete\":"))
            try cursor.boolean()
        else
            true;
    if (cursor.consume(",\"label\":")) _ = try cursor.string();
    const scope = if (cursor.consume(",\"scope\":"))
        try cursor.string()
    else
        "";
    try cursor.finish();
    return .{
        .seq = seq,
        .kind = kind,
        .allocator_id = allocator_id,
        .allocation_id = allocation_id,
        .scope_id = scope_id,
        .address = address,
        .old_address = old_address,
        .len = len,
        .old_len = old_len,
        .alignment = alignment,
        .return_address = return_address,
        .stack_id = stack_id,
        .succeeded = succeeded,
        .tracked = tracked,
        .recording_failures = recording_failures,
        .scope = scope,
        .retains_freed_memory = retains_freed_memory,
        .layer = layer,
        .operation_id = operation_id,
        .parent_operation_id = parent_operation_id,
        .producer_id = producer_id,
        .producer = producer,
        .generation = generation,
        .owner_cookie = owner_cookie,
        .lifecycle_disposition = lifecycle_disposition,
        .lifecycle_reason = lifecycle_reason,
        .lifecycle_instrumented = lifecycle_instrumented,
        .observation_prefix_complete = observation_prefix_complete,
    };
}

fn parseCanonical(line: []const u8) !ReplayEvent {
    var cursor = CanonicalCursor{ .line = line };
    try cursor.expect("{\"v\":");
    const version = try cursor.unsigned();
    if (version != format_version) return error.UnsupportedTraceVersion;
    try cursor.expect(",\"seq\":");
    const seq = try cursor.unsigned();
    try cursor.expect(",\"kind\":");
    const kind = Kind.fromTag(try cursor.string()) orelse return error.InvalidEventJson;
    try cursor.expect(",\"allocator_id\":");
    const allocator_id = std.math.cast(u32, try cursor.unsigned()) orelse return error.InvalidEventJson;
    try cursor.expect(",\"allocation_id\":");
    const allocation_id = try cursor.unsigned();
    try cursor.expect(",\"scope_id\":");
    const scope_id = std.math.cast(u32, try cursor.unsigned()) orelse
        return error.InvalidEventJson;
    try cursor.expect(",\"label_id\":");
    try cursor.skipUnsigned();
    try cursor.expect(",\"address\":");
    const address = try cursor.unsigned();
    try cursor.expect(",\"old_address\":");
    const old_address = try cursor.unsigned();
    try cursor.expect(",\"len\":");
    const len = std.math.cast(usize, try cursor.unsigned()) orelse return error.InvalidEventJson;
    try cursor.expect(",\"old_len\":");
    const old_len = std.math.cast(usize, try cursor.unsigned()) orelse return error.InvalidEventJson;
    try cursor.expect(",\"alignment\":");
    const alignment = std.math.cast(u32, try cursor.unsigned()) orelse
        return error.InvalidEventJson;
    try cursor.expect(",\"return_address\":");
    const return_address = try cursor.unsigned();
    const stack_id = if (cursor.consume(",\"stack_id\":"))
        std.math.cast(u32, try cursor.unsigned()) orelse
            return error.InvalidEventJson
    else
        0;
    try cursor.expect(",\"succeeded\":");
    const succeeded = try cursor.boolean();
    const tracked = if (cursor.consume(",\"tracked\":"))
        try cursor.boolean()
    else
        true;
    try cursor.expect(",\"live_bytes\":");
    try cursor.skipUnsigned();
    try cursor.expect(",\"recording_failures\":");
    const recording_failures = try cursor.unsigned();
    try cursor.expect(",\"retains_freed_memory\":");
    const retains_freed_memory = try cursor.boolean();
    const layer = if (cursor.consume(",\"layer\":"))
        Layer.fromTag(try cursor.string()) orelse
            return error.InvalidEventJson
    else
        .backing_boundary;
    const operation_id = if (cursor.consume(",\"operation_id\":"))
        try cursor.unsigned()
    else
        0;
    const parent_operation_id = if (cursor.consume(",\"parent_operation_id\":"))
        try cursor.unsigned()
    else
        0;
    const producer_id = if (cursor.consume(",\"producer_id\":"))
        try cursor.unsigned()
    else
        0;
    const producer = if (cursor.consume(",\"producer\":"))
        std.meta.stringToEnum(observe.Producer, try cursor.string()) orelse
            return error.InvalidEventJson
    else
        .boundary;
    const generation = if (cursor.consume(",\"generation\":"))
        try cursor.unsigned()
    else
        0;
    const owner_cookie = if (cursor.consume(",\"owner_cookie\":"))
        try cursor.unsigned()
    else
        0;
    const lifecycle_disposition =
        if (cursor.consume(",\"lifecycle_disposition\":"))
            std.meta.stringToEnum(
                observe.LifecycleDisposition,
                try cursor.string(),
            ) orelse return error.InvalidEventJson
        else
            .none;
    const lifecycle_reason =
        if (cursor.consume(",\"lifecycle_reason\":"))
            std.meta.stringToEnum(
                observe.LifecycleReason,
                try cursor.string(),
            ) orelse return error.InvalidEventJson
        else
            .none;
    const lifecycle_instrumented =
        if (cursor.consume(",\"lifecycle_instrumented\":"))
            try cursor.boolean()
        else
            false;
    const observation_prefix_complete =
        if (cursor.consume(",\"observation_prefix_complete\":"))
            try cursor.boolean()
        else
            true;
    if (cursor.consume(",\"label\":")) _ = try cursor.string();
    const scope = if (cursor.consume(",\"scope\":")) try cursor.string() else "";
    try cursor.finish();
    return .{
        .seq = seq,
        .kind = kind,
        .allocator_id = allocator_id,
        .allocation_id = allocation_id,
        .scope_id = scope_id,
        .address = address,
        .old_address = old_address,
        .len = len,
        .old_len = old_len,
        .alignment = alignment,
        .return_address = return_address,
        .stack_id = stack_id,
        .succeeded = succeeded,
        .tracked = tracked,
        .recording_failures = recording_failures,
        .scope = scope,
        .retains_freed_memory = retains_freed_memory,
        .layer = layer,
        .operation_id = operation_id,
        .parent_operation_id = parent_operation_id,
        .producer_id = producer_id,
        .producer = producer,
        .generation = generation,
        .owner_cookie = owner_cookie,
        .lifecycle_disposition = lifecycle_disposition,
        .lifecycle_reason = lifecycle_reason,
        .lifecycle_instrumented = lifecycle_instrumented,
        .observation_prefix_complete = observation_prefix_complete,
    };
}

test "event json line includes identities and omits default fields" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try (Event{
        .seq = 7,
        .kind = .alloc,
        .allocation_id = 9,
        .scope_id = 3,
        .label_id = 2,
        .address = 128,
        .len = 64,
        .alignment = 8,
        .live_bytes = 64,
    }).writeJsonLine(&out.writer, "phase", "root/phase");

    const line = out.written();
    try std.testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"alloc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"label\":\"phase\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"scope\":\"root/phase\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"alignment\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"live_bytes\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"retains_freed_memory\"") == null);
}

test "replay parser consumes sparse event writer output" {
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try (Event{
        .seq = 19,
        .kind = .remap,
        .allocator_id = 7,
        .allocation_id = 11,
        .address = 8192,
        .old_address = 4096,
        .len = 96,
        .old_len = 64,
        .alignment = 16,
        .return_address = 0xabc,
        .live_bytes = 128,
        .retains_freed_memory = true,
    }).writeJsonLine(&bytes.writer, "heap", "root/phase");

    const line = std.mem.trimEnd(u8, bytes.written(), "\n");
    const parsed = try parseFast(line);
    try std.testing.expectEqual(@as(?u64, 19), parsed.seq);
    try std.testing.expectEqual(Kind.remap, parsed.kind);
    try std.testing.expectEqual(@as(u32, 7), parsed.allocator_id);
    try std.testing.expectEqual(@as(u64, 11), parsed.allocation_id);
    try std.testing.expectEqual(@as(u64, 8192), parsed.address);
    try std.testing.expectEqual(@as(u64, 4096), parsed.old_address);
    try std.testing.expectEqual(@as(usize, 96), parsed.len);
    try std.testing.expectEqual(@as(usize, 64), parsed.old_len);
    try std.testing.expectEqual(@as(u32, 16), parsed.alignment);
    try std.testing.expectEqual(@as(u64, 0xabc), parsed.return_address);
    try std.testing.expectEqualStrings("root/phase", parsed.scope);
    try std.testing.expect(parsed.retains_freed_memory);
}

test "lifecycle identity round trips through sparse event writer" {
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try (Event{
        .seq = 23,
        .kind = .lifecycle,
        .allocator_id = 4,
        .return_address = 0xdef,
        .layer = .logical_allocator,
        .operation_id = 31,
        .producer_id = 9,
        .producer = .arena,
        .generation = 5,
        .owner_cookie = 0x1234,
        .lifecycle_disposition = .invalidate,
        .lifecycle_reason = .reset,
    }).writeJsonLine(&bytes.writer, null, "root");

    const line = std.mem.trimEnd(u8, bytes.written(), "\n");
    const parsed = try parseFast(line);
    try std.testing.expectEqual(Kind.lifecycle, parsed.kind);
    try std.testing.expectEqual(Layer.logical_allocator, parsed.layer);
    try std.testing.expectEqual(@as(u64, 5), parsed.generation);
    try std.testing.expectEqual(@as(u64, 0x1234), parsed.owner_cookie);
    try std.testing.expectEqual(
        observe.LifecycleDisposition.invalidate,
        parsed.lifecycle_disposition,
    );
    try std.testing.expectEqual(
        observe.LifecycleReason.reset,
        parsed.lifecycle_reason,
    );
}

test "event record names exactly the fields the writer writes" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try (Event{
        .seq = 1,
        .kind = .remap,
        .allocator_id = 2,
        .allocation_id = 3,
        .scope_id = 4,
        .address = 5,
        .old_address = 6,
        .len = 7,
        .old_len = 8,
        .alignment = 16,
        .return_address = 9,
        .stack_id = 10,
        .succeeded = false,
        .tracked = false,
        .recording_failures = 11,
        .retains_freed_memory = true,
        .layer = .logical_allocator,
        .operation_id = 12,
        .parent_operation_id = 13,
        .producer_id = 14,
        .producer = .arena,
        .generation = 15,
        .owner_cookie = 16,
        .lifecycle_disposition = .invalidate,
        .lifecycle_reason = .reset,
        .lifecycle_instrumented = true,
        .observation_prefix_complete = false,
    }).writeJsonLine(&output.writer, "heap", "root/phase");
    const record = try std.json.parseFromSlice(
        Record,
        std.testing.allocator,
        output.written(),
        .{},
    );
    defer record.deinit();
    const written = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        output.written(),
        .{},
    );
    defer written.deinit();
    inline for (@typeInfo(Record).@"struct".field_names) |name| {
        try std.testing.expect(written.value.object.contains(name));
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const line = std.mem.trimEnd(u8, output.written(), "\n");
    try std.testing.expectEqualDeep(
        try parseFast(line),
        try parseRecord(arena_state.allocator(), line),
    );
}

test "replay decodes escaped strings and refuses what JSON refuses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const escaped = try parseReplay(
        arena,
        "{\"v\":3,\"seq\":1,\"kind\":\"alloc\",\"scope\":\"root/a\\\"b\"}",
    );
    try std.testing.expectEqualStrings("root/a\"b", escaped.scope);
    try std.testing.expectEqual(@as(?u64, 1), escaped.seq);
    const unsequenced = try parseReplay(arena, "{\"v\":3,\"kind\":\"free\"}");
    try std.testing.expectEqual(@as(?u64, null), unsequenced.seq);
    try std.testing.expectEqual(@as([]const u8, ""), unsequenced.scope);
    for ([_][]const u8{
        "{\"v\":3,\"seq\":01,\"kind\":\"alloc\"}",
        "{\"v\":3,\"seq\":1,\"kind\":\"alloc\",\"scope\":\"a\tb\"}",
        "{\"v\":3,\"seq\":1,\"kind\":\"alloc\",\"scope\":\"\xc0\xaf\"}",
        "{\"v\":3,\"seq\":1,\"kind\":\"alloc\",\"len\":-1}",
        "{\"v\":3,\"seq\":1,\"kind\":\"alloc\",\"stack_id\":4294967296}",
        "{\"v\":3,\"seq\":1,\"kind\":\"alloc\",\"tracked\":0}",
        "{\"v\":3,\"seq\":1,\"kind\":\"alloc\"} trailing",
    }) |line| {
        try std.testing.expectError(error.InvalidEventJson, parseReplay(arena, line));
    }
    try std.testing.expectError(
        error.UnsupportedTraceVersion,
        parseReplay(arena, "{\"kind\":\"x\",\"v\":4}"),
    );
}
