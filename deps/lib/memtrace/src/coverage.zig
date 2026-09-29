const std = @import("std");
const pretty_json = @import("pretty").json;

const metadata_tag = "\"meta\":\"memtrace.coverage\"";

pub const Universe = enum {
    registered_allocator_handles,
    owned_allocator_producers_and_registered_boundaries,
    owned_allocator_producers_registered_boundaries_and_sys_memory_operations,
    process_memory_operations_during_trace_epoch,

    pub fn tag(self: Universe) []const u8 {
        return switch (self) {
            .registered_allocator_handles => "registered_allocator_handles",
            .owned_allocator_producers_and_registered_boundaries => "owned_allocator_producers_and_registered_boundaries",
            .owned_allocator_producers_registered_boundaries_and_sys_memory_operations => "owned_allocator_producers_registered_boundaries_and_sys_memory_operations",
            .process_memory_operations_during_trace_epoch => "process_memory_operations_during_trace_epoch",
        };
    }
};

pub const Inclusion = enum {
    observed,
    proved_absent,
    isolated,
    no_memory_effect,
    unobserved,

    pub fn tag(self: Inclusion) []const u8 {
        return switch (self) {
            .observed => "observed",
            .proved_absent => "proved_absent",
            .isolated => "isolated",
            .no_memory_effect => "no_memory_effect",
            .unobserved => "opaque",
        };
    }

    fn fromTag(text: []const u8) ?Inclusion {
        if (std.mem.eql(u8, text, "observed")) return .observed;
        if (std.mem.eql(u8, text, "proved_absent")) return .proved_absent;
        if (std.mem.eql(u8, text, "isolated")) return .isolated;
        if (std.mem.eql(u8, text, "no_memory_effect")) {
            return .no_memory_effect;
        }
        if (std.mem.eql(u8, text, "opaque")) return .unobserved;
        return null;
    }

    /// Reads the wire tag, so that `unobserved` parses from `"opaque"`.
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Inclusion {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const text = switch (token) {
            .string, .allocated_string => |text| text,
            else => return error.UnexpectedToken,
        };
        return fromTag(text) orelse error.InvalidEnumTag;
    }
};

pub const StaticEvidence = struct {
    direct_os_memory_operations_absent: bool = false,
    unowned_allocator_producers_absent: bool = false,
    foreign_allocations_absent: bool = false,
};

pub const Manifest = struct {
    universe: Universe = .registered_allocator_handles,
    child_allocator_fast_paths: Inclusion = .unobserved,
    sys_memory_operations: Inclusion = .unobserved,
    direct_os_memory_operations: Inclusion = .unobserved,
    unowned_allocator_producers: Inclusion = .unobserved,
    foreign_allocations: Inclusion = .unobserved,
    observer_control: Inclusion = .isolated,
    zero_length_operations: Inclusion = .no_memory_effect,
    predispatch_failures: Inclusion = .no_memory_effect,
    observer_control_operations: u64 = 0,

    pub fn processComplete(self: Manifest) bool {
        return self.universe ==
            .process_memory_operations_during_trace_epoch and
            self.child_allocator_fast_paths == .observed and
            self.sys_memory_operations == .observed and
            observedOrAbsent(self.direct_os_memory_operations) and
            observedOrAbsent(self.unowned_allocator_producers) and
            observedOrAbsent(self.foreign_allocations) and
            observedOrIsolated(self.observer_control) and
            observedOrNoEffect(self.zero_length_operations) and
            observedOrNoEffect(self.predispatch_failures);
    }

    pub fn statusTag(self: Manifest) []const u8 {
        if (self.processComplete()) return "process_memory_operation_complete";
        return switch (self.universe) {
            .registered_allocator_handles => "boundary_complete",
            .owned_allocator_producers_and_registered_boundaries => "owned_producer_complete",
            .owned_allocator_producers_registered_boundaries_and_sys_memory_operations => "owned_producer_and_sys_memory_operation_complete",
            .process_memory_operations_during_trace_epoch => "process_memory_operation_incomplete",
        };
    }
};

pub fn boundaryManifest() Manifest {
    return .{};
}

pub fn ownedProducerManifest() Manifest {
    return .{
        .universe = .owned_allocator_producers_registered_boundaries_and_sys_memory_operations,
        .child_allocator_fast_paths = .observed,
        .sys_memory_operations = .observed,
    };
}

pub fn processManifest(evidence: StaticEvidence) Manifest {
    var manifest = ownedProducerManifest();
    manifest.universe = .process_memory_operations_during_trace_epoch;
    manifest.direct_os_memory_operations = if (evidence.direct_os_memory_operations_absent)
        .proved_absent
    else
        .unobserved;
    manifest.unowned_allocator_producers = if (evidence.unowned_allocator_producers_absent)
        .proved_absent
    else
        .unobserved;
    manifest.foreign_allocations = if (evidence.foreign_allocations_absent)
        .proved_absent
    else
        .unobserved;
    return manifest;
}

fn observedOrAbsent(state: Inclusion) bool {
    return state == .observed or state == .proved_absent;
}

fn observedOrIsolated(state: Inclusion) bool {
    return state == .observed or state == .isolated;
}

fn observedOrNoEffect(state: Inclusion) bool {
    return state == .observed or state == .no_memory_effect;
}

pub fn isMetadataLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, metadata_tag) != null;
}

pub fn writeMetadata(writer: *std.Io.Writer, manifest: Manifest) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("v", 3);
    try object.field("meta", "memtrace.coverage");
    try object.field("universe", manifest.universe.tag());
    try object.field("child_allocator_fast_paths", manifest.child_allocator_fast_paths.tag());
    try object.field("sys_memory_operations", manifest.sys_memory_operations.tag());
    try object.field("direct_os_memory_operations", manifest.direct_os_memory_operations.tag());
    try object.field("unowned_allocator_producers", manifest.unowned_allocator_producers.tag());
    try object.field("foreign_allocations", manifest.foreign_allocations.tag());
    try object.field("observer_control", manifest.observer_control.tag());
    try object.field("zero_length_operations", manifest.zero_length_operations.tag());
    try object.field("predispatch_failures", manifest.predispatch_failures.tag());
    try object.field("observer_control_operations", manifest.observer_control_operations);
    try object.endLine();
}

/// One `memtrace.coverage` line, field for field as `writeMetadata` writes it.
const Record = struct {
    v: u64,
    meta: []const u8,
    universe: Universe,
    child_allocator_fast_paths: Inclusion,
    sys_memory_operations: Inclusion,
    direct_os_memory_operations: Inclusion,
    unowned_allocator_producers: Inclusion,
    foreign_allocations: Inclusion,
    observer_control: Inclusion,
    zero_length_operations: Inclusion,
    predispatch_failures: Inclusion,
    observer_control_operations: u64,
};

pub fn parseMetadata(allocator: std.mem.Allocator, line: []const u8) !Manifest {
    const parsed = std.json.parseFromSlice(Record, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return versionFault(allocator, line),
    };
    defer parsed.deinit();
    const record = parsed.value;
    if (record.v != 3) return error.UnsupportedCoverageVersion;
    if (!std.mem.eql(u8, record.meta, "memtrace.coverage")) {
        return error.InvalidCoverageMetadata;
    }
    return .{
        .universe = record.universe,
        .child_allocator_fast_paths = record.child_allocator_fast_paths,
        .sys_memory_operations = record.sys_memory_operations,
        .direct_os_memory_operations = record.direct_os_memory_operations,
        .unowned_allocator_producers = record.unowned_allocator_producers,
        .foreign_allocations = record.foreign_allocations,
        .observer_control = record.observer_control,
        .zero_length_operations = record.zero_length_operations,
        .predispatch_failures = record.predispatch_failures,
        .observer_control_operations = record.observer_control_operations,
    };
}

/// Names the fault of a line that is not a version 3 record. A readable
/// version other than 3 outranks every other fault, because a newer writer's
/// fields are not this reader's to judge.
fn versionFault(
    allocator: std.mem.Allocator,
    line: []const u8,
) error{ OutOfMemory, UnsupportedCoverageVersion, InvalidCoverageMetadata } {
    const parsed = std.json.parseFromSlice(struct { v: u64 }, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCoverageMetadata,
    };
    defer parsed.deinit();
    if (parsed.value.v != 3) return error.UnsupportedCoverageVersion;
    return error.InvalidCoverageMetadata;
}

test "coverage record names exactly the fields the writer writes" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeMetadata(&output.writer, processManifest(.{}));
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
}

test "coverage metadata keeps observer counts above the signed range" {
    var expected = ownedProducerManifest();
    expected.observer_control_operations = std.math.maxInt(u64);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeMetadata(&output.writer, expected);
    const actual = try parseMetadata(std.testing.allocator, output.written());
    try std.testing.expectEqualDeep(expected, actual);
}

test "coverage metadata refuses a newer version before its fields" {
    try std.testing.expectError(
        error.UnsupportedCoverageVersion,
        parseMetadata(std.testing.allocator, "{\"v\":4,\"meta\":\"memtrace.coverage\"}"),
    );
    try std.testing.expectError(
        error.InvalidCoverageMetadata,
        parseMetadata(std.testing.allocator, "{\"v\":3,\"meta\":\"memtrace.coverage\"}"),
    );
}

test "coverage metadata preserves the allocator boundary contract" {
    const expected = boundaryManifest();
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeMetadata(&output.writer, expected);
    const actual = try parseMetadata(
        std.testing.allocator,
        std.mem.trimEnd(u8, output.written(), "\n"),
    );
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expect(!actual.processComplete());
}

test "coverage metadata preserves the owned producer contract" {
    const expected = ownedProducerManifest();
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeMetadata(&output.writer, expected);
    const actual = try parseMetadata(
        std.testing.allocator,
        std.mem.trimEnd(u8, output.written(), "\n"),
    );
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expectEqualStrings(
        "owned_producer_and_sys_memory_operation_complete",
        actual.statusTag(),
    );
    try std.testing.expect(!actual.processComplete());
}

test "coverage metadata preserves the certified process contract" {
    const expected = processManifest(.{
        .direct_os_memory_operations_absent = true,
        .unowned_allocator_producers_absent = true,
        .foreign_allocations_absent = true,
    });
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeMetadata(&output.writer, expected);
    const actual = try parseMetadata(
        std.testing.allocator,
        std.mem.trimEnd(u8, output.written(), "\n"),
    );
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expect(actual.processComplete());
    try std.testing.expectEqualStrings(
        "process_memory_operation_complete",
        actual.statusTag(),
    );
}

test "process coverage rejects category states with the wrong meaning" {
    var manifest = processManifest(.{
        .direct_os_memory_operations_absent = true,
        .unowned_allocator_producers_absent = true,
        .foreign_allocations_absent = true,
    });
    manifest.direct_os_memory_operations = .isolated;
    try std.testing.expect(!manifest.processComplete());
    manifest.direct_os_memory_operations = .proved_absent;
    manifest.observer_control = .no_memory_effect;
    try std.testing.expect(!manifest.processComplete());
    manifest.observer_control = .isolated;
    manifest.zero_length_operations = .proved_absent;
    try std.testing.expect(!manifest.processComplete());
}
