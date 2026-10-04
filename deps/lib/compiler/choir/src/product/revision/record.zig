const std = @import("std");
const simd = @import("simd");
const binary = @import("../../serialization/binary/root.zig");

const Bytes = simd.ScalableTag(u8);

pub const schema_version: u32 = 2;

/// Maximum number of nested values in a semantic projection.
pub const maximum_projection_depth: u8 = 64;
pub const ProjectionError = binary.WriteError || error{UnencodableProduct};
pub const codec_limits = binary.Limits{
    .serialized_bytes = std.math.maxInt(u32),
    .string_bytes = std.math.maxInt(u32),
    .blob_bytes = std.math.maxInt(u32),
    .collection_entries = std.math.maxInt(u32),
    .total_entries = std.math.maxInt(u32),
};
pub const Writer = binary.Writer(codec_limits);
pub const Reader = binary.Reader(codec_limits);

pub const Version = struct {
    name: []const u8,
    version: u32,

    pub fn eql(self: Version, other: Version) bool {
        return self.version == other.version and std.mem.eql(u8, self.name, other.name);
    }
};

pub const Address = struct {
    producer: []const u8,
    source: []const u8,
    stage: []const u8,
    variant: []const u8,

    pub fn eql(self: Address, other: Address) bool {
        inline for (@typeInfo(Address).@"struct".field_names) |field| {
            if (!std.mem.eql(u8, @field(self, field), @field(other, field))) return false;
        }
        return true;
    }
};

/// A missing value records a negative observation, distinct from empty bytes.
pub const Fact = struct {
    key: []const u8,
    value: ?[]const u8,

    pub fn eql(self: Fact, other: Fact) bool {
        if (!std.mem.eql(u8, self.key, other.key)) return false;
        if (self.value) |value| {
            return std.mem.eql(u8, value, other.value orelse return false);
        }
        return other.value == null;
    }
};

/// Dependency records contain exact semantic bytes, excluding publication events.
pub const Dependency = struct {
    role: []const u8,
    exact: []const u8,
};

/// The compiler manifest is admission input, not encoded content. An owner
/// interns it and decides identity through the interned bytes, so `encodeInputs`
/// reads every other field and leaves this one to the store.
pub const Inputs = struct {
    compiler_manifest: []const u8,
    versions: []const Version,
    pipeline: []const Version,
    options: []const u8,
    policy: []const u8,
    facts: []const Fact = &.{},
};

/// Decoded input fields. A record does not carry its compiler manifest, so this
/// view cannot answer which compiler produced it; ask the owner that holds it.
pub const InputView = struct {
    versions: Entries(Version),
    pipeline: Entries(Version),
    options: []const u8,
    policy: []const u8,
    facts: Entries(Fact),
    dependencies: Entries(Dependency),
    gate_manifest: []const u8,

    /// Checks declared gate identities only. Transported bytes do not establish
    /// that gates ran; callers obtain publication authority from a live Revision.
    pub fn requireGateDeclarations(self: InputView, required: []const Version) !void {
        for (required) |identity| {
            if (!try declaresGate(self.gate_manifest, identity)) return error.MissingGateEvidence;
        }
    }
};

fn declaresGate(bytes: []const u8, required: Version) !bool {
    var reader = try Reader.init(bytes);
    if (try reader.readInt(u32) != schema_version) return error.UnknownSchema;
    _ = try reader.readString();
    _ = try reader.readInt(u32);
    var found = (try readGateIdentity(&reader)).eql(required);
    const count = try reader.readCount();
    for (0..count) |_| {
        const identity = try readGateIdentity(&reader);
        found = identity.eql(required) or found;
    }
    if (!reader.atEnd()) return error.InvalidRecord;
    return found;
}

fn readGateIdentity(reader: *Reader) !Version {
    const identity = Version{
        .name = try reader.readString(),
        .version = try reader.readInt(u32),
    };
    _ = try reader.readBlob();
    _ = try reader.readInt(u32);
    return identity;
}

pub const ClosureBounds = struct {
    bytes: u32,
    records: u32,
    depth: u8,
};

const ClosureFrame = struct {
    dependencies: Entries(Dependency).Iterator,
};

/// Embedded dependencies strictly decrease in byte extent, so exact cycles cannot
/// be represented. The iterative walk validates every closed record under bounds.
pub fn validateClosure(bytes: []const u8, bounds: ClosureBounds) !void {
    if (bytes.len > bounds.bytes) return error.RecordLimit;
    if (bounds.records == 0 or bounds.depth == 0) return error.RecordClosureLimit;
    var stack: [255]ClosureFrame = undefined;
    stack[0] = try closureFrame(bytes);
    var depth: usize = 1;
    var count: u32 = 1;
    while (depth != 0) {
        const dependency = try stack[depth - 1].dependencies.next() orelse {
            depth -= 1;
            continue;
        };
        if (count == bounds.records or depth == bounds.depth) return error.RecordClosureLimit;
        stack[depth] = try closureFrame(dependency.exact);
        depth += 1;
        count += 1;
    }
}

fn closureFrame(bytes: []const u8) !ClosureFrame {
    const exact = try decodeExact(bytes);
    _ = try decodeAddress(exact.address);
    const inputs = try decodeInputs(exact.inputs);
    return .{ .dependencies = inputs.dependencies.iterator() };
}

pub fn Entries(comptime T: type) type {
    return struct {
        bytes: []const u8,
        count: u32,

        pub fn iterator(self: @This()) Iterator {
            return .{
                .reader = Reader.init(self.bytes) catch unreachable,
                .remaining = self.count,
            };
        }

        pub const Iterator = struct {
            reader: Reader,
            remaining: u32,

            pub fn next(self: *Iterator) !?T {
                if (self.remaining == 0) return null;
                const result = try readEntry(T, &self.reader);
                self.remaining -= 1;
                return result;
            }
        };
    };
}

pub fn decodeAddress(bytes: []const u8) !Address {
    var reader = try Reader.init(bytes);
    if (try reader.readInt(u32) != schema_version) return error.UnknownSchema;
    var result: Address = undefined;
    inline for (@typeInfo(Address).@"struct".field_names, 1..) |field, tag| {
        @field(result, field) = try readField(&reader, tag);
    }
    if (result.producer.len == 0 or result.stage.len == 0) return error.InvalidAddress;
    if (!reader.atEnd()) return error.InvalidRecord;
    return result;
}

pub fn decodeInputs(bytes: []const u8) !InputView {
    var reader = try Reader.init(bytes);
    if (try reader.readInt(u32) != schema_version) return error.UnknownSchema;
    const versions = try readEntries(Version, &reader, 2, "name");
    const pipeline = try readEntries(Version, &reader, 3, null);
    const options = try readField(&reader, 4);
    const policy = try readField(&reader, 5);
    const facts = try readEntries(Fact, &reader, 6, "key");
    const dependencies = try readEntries(Dependency, &reader, 7, "role");
    const gate_manifest = try readField(&reader, 8);
    if (!reader.atEnd()) return error.InvalidRecord;
    return .{
        .versions = versions,
        .pipeline = pipeline,
        .options = options,
        .policy = policy,
        .facts = facts,
        .dependencies = dependencies,
        .gate_manifest = gate_manifest,
    };
}

fn readEntries(
    comptime T: type,
    reader: *Reader,
    tag: u8,
    comptime ordered: ?[]const u8,
) !Entries(T) {
    if (try reader.readInt(u8) != tag) return error.UnknownRequiredField;
    const count = try reader.readCount();
    const start = reader.offset;
    var previous: ?[]const u8 = null;
    for (0..count) |_| {
        const item = try readEntry(T, reader);
        if (ordered) |field| try orderedKey(&previous, @field(item, field));
    }
    return .{ .bytes = reader.bytes[start..reader.offset], .count = @intCast(count) };
}

fn readEntry(comptime T: type, reader: *Reader) !T {
    if (T == Version) {
        const name = try reader.readString();
        const version = try reader.readInt(u32);
        if (version == 0 or name.len == 0) return error.InvalidVersion;
        return .{ .name = name, .version = version };
    } else if (T == Fact) {
        return .{ .key = try reader.readString(), .value = try reader.readOptionalString() };
    } else if (T == Dependency) {
        const role = try reader.readString();
        const exact = try reader.readBlob();
        _ = try decodeExact(exact);
        return .{ .role = role, .exact = exact };
    } else @compileError("unknown canonical record collection");
}

pub const Namespace = enum(u8) { root, operation, region, block, value, attribute };
pub const EntityCounts = [@typeInfo(Namespace).@"enum".field_names.len]u32;

pub const Exact = struct {
    address: []const u8,
    inputs: []const u8,
    image: []const u8,

    pub fn eql(self: Exact, other: Exact) bool {
        return simd.equal(Bytes, self.address, other.address) and
            simd.equal(Bytes, self.inputs, other.inputs) and
            simd.equal(Bytes, self.image, other.image);
    }
};

const ValueTag = enum(u8) {
    boolean = 1,
    unsigned = 2,
    signed = 3,
    float_bits = 4,
    enum_name = 5,
    optional = 6,
    sequence = 7,
    structure = 8,
    choice = 9,
    bytes = 10,
    unit = 11,
};

/// Keep each owner's projection exhaustive when its option or plan type changes.
pub fn requireFields(comptime T: type, comptime names: []const []const u8) void {
    const fields = @typeInfo(T).@"struct".field_names;
    if (fields.len != names.len) {
        @compileError("classify every field before publishing this record");
    }
    inline for (fields, names) |field, expected| {
        if (!std.mem.eql(u8, field, expected)) {
            @compileError("update the explicit semantic projection");
        }
    }
}

/// Encode an owner's explicit semantic projection, never compiler pointers.
pub fn writeValue(writer: *Writer, value: anytype) ProjectionError!void {
    try writeValueDepth(writer, value, 0);
}

fn writeValueDepth(writer: *Writer, value: anytype, depth: u8) ProjectionError!void {
    if (depth >= maximum_projection_depth) return error.UnencodableProduct;
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void => try valueTag(writer, .unit),
        .bool => {
            try valueTag(writer, .boolean);
            try writer.writeBool(value);
        },
        .int => |info| {
            if (info.bits > 64) @compileError("declare a bounded wide-integer encoding");
            try valueTag(writer, if (info.signedness == .signed) .signed else .unsigned);
            if (info.signedness == .signed) try writer.writeInt(i64, value) else {
                try writer.writeInt(u64, value);
            }
        },
        .float => |info| {
            try valueTag(writer, .float_bits);
            try writer.writeInt(u16, info.bits);
            const Bits = @Int(.unsigned, info.bits);
            try writer.writeInt(Bits, @bitCast(value));
        },
        .@"enum" => {
            try valueTag(writer, .enum_name);
            try writer.writeString(@tagName(value));
        },
        .optional => {
            try valueTag(writer, .optional);
            try writer.writeBool(value != null);
            if (value) |present| try writeValueDepth(writer, present, depth + 1);
        },
        .array, .pointer => try writeSequence(writer, value, depth),
        .@"struct" => |info| {
            try valueTag(writer, .structure);
            try writer.writeCount(info.field_names.len);
            inline for (info.field_names) |field| {
                try writer.writeString(field);
                try writeValueDepth(writer, @field(value, field), depth + 1);
            }
        },
        .@"union" => {
            try valueTag(writer, .choice);
            try writer.writeString(@tagName(value));
            switch (value) {
                inline else => |payload| try writeValueDepth(writer, payload, depth + 1),
            }
        },
        else => @compileError("classify this semantic field before publication"),
    }
}

fn writeSequence(writer: *Writer, value: anytype, depth: u8) ProjectionError!void {
    std.debug.assert(depth < maximum_projection_depth);
    const info = @typeInfo(@TypeOf(value));
    if (info == .pointer) {
        if (info.pointer.size != .slice) {
            @compileError("project references into exact revision ordinals");
        }
        if (info.pointer.child == u8) {
            try valueTag(writer, .bytes);
            try writer.writeBlob(value);
            return;
        }
    }
    try valueTag(writer, .sequence);
    try writer.writeCount(value.len);
    for (value) |item| try writeValueDepth(writer, item, depth + 1);
}

fn valueTag(writer: *Writer, value: ValueTag) !void {
    try writer.writeTag(value);
}

pub fn encodeAddress(allocator: std.mem.Allocator, value: Address) ![]u8 {
    if (value.producer.len == 0 or value.stage.len == 0) return error.InvalidAddress;
    var writer = Writer.init(allocator);
    defer writer.deinit();
    var length: usize = 24;
    inline for (@typeInfo(Address).@"struct".field_names) |field| {
        length = try sizeAdd(length, @field(value, field).len);
    }
    try writer.bytes.ensureTotalCapacityPrecise(allocator, length);
    try writer.writeInt(u32, schema_version);
    inline for (@typeInfo(Address).@"struct".field_names, 1..) |field, tag| {
        try writer.writeInt(u8, tag);
        try writer.writeString(@field(value, field));
    }
    std.debug.assert(writer.bytes.items.len == length);
    return writer.finish();
}

pub fn encodeInputs(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    dependencies: []const Dependency,
    gate_manifest: []const u8,
) ![]u8 {
    comptime std.debug.assert(@typeInfo(Inputs).@"struct".field_names.len == 6);
    const versions = try sortedMap(Version, allocator, inputs.versions, "name");
    defer allocator.free(versions);
    const facts = try sortedMap(Fact, allocator, inputs.facts, "key");
    defer allocator.free(facts);
    const ordered_dependencies = try sortedMap(Dependency, allocator, dependencies, "role");
    defer allocator.free(ordered_dependencies);
    var writer = Writer.init(allocator);
    defer writer.deinit();
    const length = try inputsSize(inputs, dependencies, gate_manifest);
    try writer.bytes.ensureTotalCapacityPrecise(allocator, length);
    try writer.writeInt(u32, schema_version);
    try writer.writeInt(u8, 2);
    try writeVersions(&writer, versions, true);
    try writer.writeInt(u8, 3);
    try writeVersions(&writer, inputs.pipeline, false);
    try fieldBlob(&writer, 4, inputs.options);
    try fieldBlob(&writer, 5, inputs.policy);
    try writer.writeInt(u8, 6);
    try writeFacts(&writer, facts);
    try writer.writeInt(u8, 7);
    try writeDependencies(&writer, ordered_dependencies);
    try fieldBlob(&writer, 8, gate_manifest);
    std.debug.assert(writer.bytes.items.len == length);
    return writer.finish();
}

fn inputsSize(inputs: Inputs, dependencies: []const Dependency, gates: []const u8) !usize {
    var size: usize = 39;
    for ([_][]const u8{ inputs.options, inputs.policy, gates }) |bytes| {
        size = try sizeAdd(size, bytes.len);
    }
    for ([_][]const Version{ inputs.versions, inputs.pipeline }) |versions| {
        for (versions) |version| size = try sizeAdd(size, try sizeAdd(8, version.name.len));
    }
    for (inputs.facts) |fact| {
        size = try sizeAdd(size, try sizeAdd(5, fact.key.len));
        if (fact.value) |bytes| size = try sizeAdd(size, try sizeAdd(4, bytes.len));
    }
    for (dependencies) |dependency| {
        size = try sizeAdd(size, try sizeAdd(8, dependency.role.len));
        size = try sizeAdd(size, dependency.exact.len);
    }
    return size;
}

fn sizeAdd(first: usize, second: usize) !usize {
    const size = std.math.add(usize, first, second) catch return error.RecordOverflow;
    if (size > codec_limits.serialized_bytes) return error.RecordLimit;
    return size;
}

fn sortedMap(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: []const T,
    comptime key: []const u8,
) ![]T {
    const copy = try allocator.dupe(T, source);
    errdefer allocator.free(copy);
    std.mem.sort(T, copy, {}, struct {
        fn less(_: void, first: T, second: T) bool {
            return std.mem.lessThan(u8, @field(first, key), @field(second, key));
        }
    }.less);
    var previous: ?[]const u8 = null;
    for (copy) |item| try orderedKey(&previous, @field(item, key));
    return copy;
}

fn fieldBlob(writer: anytype, tag: u8, bytes: []const u8) !void {
    try writer.writeInt(u8, tag);
    try writer.writeBlob(bytes);
}

fn writeVersions(writer: *Writer, versions: []const Version, sorted: bool) !void {
    try writer.writeCount(versions.len);
    var previous: ?[]const u8 = null;
    for (versions) |version| {
        if (version.version == 0 or version.name.len == 0) return error.InvalidVersion;
        if (sorted) try orderedKey(&previous, version.name);
        try writer.writeString(version.name);
        try writer.writeInt(u32, version.version);
    }
}

fn writeFacts(writer: *Writer, facts: []const Fact) !void {
    try writer.writeCount(facts.len);
    var previous: ?[]const u8 = null;
    for (facts) |fact| {
        try orderedKey(&previous, fact.key);
        try writer.writeString(fact.key);
        try writer.writeOptionalString(fact.value);
    }
}

fn writeDependencies(writer: *Writer, dependencies: []const Dependency) !void {
    try writer.writeCount(dependencies.len);
    var previous: ?[]const u8 = null;
    for (dependencies) |dependency| {
        try orderedKey(&previous, dependency.role);
        _ = try decodeExact(dependency.exact);
        try writer.writeString(dependency.role);
        try writer.writeBlob(dependency.exact);
    }
}

fn orderedKey(previous: *?[]const u8, key: []const u8) !void {
    if (key.len == 0) return error.InvalidKey;
    if (previous.*) |prior| {
        if (!std.mem.lessThan(u8, prior, key)) return error.NoncanonicalOrder;
    }
    previous.* = key;
}

pub fn encodeExact(allocator: std.mem.Allocator, exact: Exact) ![]u8 {
    var writer = Writer.init(allocator);
    defer writer.deinit();
    try writeExact(&writer, exact);
    return writer.finish();
}

/// The caller retains ownership of the output storage. Preflight refuses a short
/// buffer before writing; the writer has no allocator capacity for growth.
pub fn encodeExactInto(output: []u8, exact: Exact) ![]u8 {
    const length = try exactSize(exact.address.len, exact.inputs.len, exact.image.len);
    if (length > output.len) return error.RecordLimit;
    var writer = binary.FixedWriter(codec_limits).init(output);
    defer writer.deinit();
    try writeExact(&writer, exact);
    std.debug.assert(writer.bytes.items.len == length);
    std.debug.assert(writer.bytes.items.ptr == output.ptr);
    return writer.finish();
}

pub fn exactSize(address: usize, inputs: usize, image: usize) !usize {
    const prefix = std.math.add(usize, address, inputs) catch return error.RecordOverflow;
    const payload = std.math.add(usize, prefix, image) catch return error.RecordOverflow;
    const length = std.math.add(usize, payload, 19) catch return error.RecordOverflow;
    if (address > std.math.maxInt(u32) or inputs > std.math.maxInt(u32) or
        image > std.math.maxInt(u32)) return error.RecordLimit;
    return length;
}

fn writeExact(writer: anytype, exact: Exact) !void {
    comptime requireFields(Exact, &.{ "address", "inputs", "image" });
    try writer.writeInt(u32, schema_version);
    try fieldBlob(writer, 1, exact.address);
    try fieldBlob(writer, 2, exact.inputs);
    try fieldBlob(writer, 3, exact.image);
}

pub fn decodeExact(bytes: []const u8) !Exact {
    var reader = try Reader.init(bytes);
    if (try reader.readInt(u32) != schema_version) return error.UnknownSchema;
    const address = try readField(&reader, 1);
    const inputs = try readField(&reader, 2);
    const image = try readField(&reader, 3);
    if (!reader.atEnd()) return error.InvalidRecord;
    return .{ .address = address, .inputs = inputs, .image = image };
}

fn readField(reader: *Reader, tag: u8) ![]const u8 {
    if (try reader.readInt(u8) != tag) return error.UnknownRequiredField;
    return reader.readBlob();
}

pub fn validateObservations(declared: []const Fact, observed: []const Fact) !void {
    if (declared.len != observed.len) return error.IncompleteObservations;
    for (declared) |requested| {
        for (observed) |actual| {
            if (requested.eql(actual)) break;
        } else return error.UndeclaredObservation;
    }
}
