const std = @import("std");
const choir = @import("choir");
const reference = @import("root.zig").reference;
const Stage = @import("../root.zig").publication.Stage;
const binary = choir.serialization.binary;

pub const limits = binary.Limits{
    .serialized_bytes = 64 * 1024 * 1024,
    .string_bytes = 64 * 1024 * 1024,
    .blob_bytes = 64 * 1024 * 1024,
    .collection_entries = 1024 * 1024,
    .total_entries = 4 * 1024 * 1024,
};
const Writer = binary.Writer(limits);
const Reader = binary.Reader(limits);

pub fn Decoded(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

/// Writes a stage's plan into a stage record at the end of a stage for the
/// compiler. The call writes version 1, the stage tag, and then every declared
/// field of the record type `T`, read by name from `source`. Each pointer to an
/// operation or value is written as its number from `references`, and a pointer
/// absent from the reference index fails with `error.UnboundProductInput`. An
/// integer exceeding its field fails with `error.InvalidStageRecord`, and the
/// bytes are capped at 64 MiB with at most about a million entries per list and
/// four million in all. The caller owns the returned bytes.
pub fn encode(
    allocator: std.mem.Allocator,
    comptime T: type,
    stage: Stage,
    source: anytype,
    references: *const reference.Index,
) ![]u8 {
    var writer = Writer.init(allocator);
    defer writer.deinit();
    try writer.writeInt(u32, 1);
    try writer.writeTag(stage);
    try write(&writer, references, T, source, 0);
    return writer.finish();
}

/// Reads a stage's plan back out of a stage record. The call reads the bytes
/// into a new value of `T` whose slices and bytes all live in an arena of the
/// result, apart from `bytes`. The errors are `error.UnknownSchema` for a
/// version other than 1, `error.WrongStage` for another stage's tag, and
/// `error.InvalidStageRecord` for bytes left over. `Decoded.deinit` frees the
/// arena and everything read into it.
pub fn decode(
    allocator: std.mem.Allocator,
    comptime T: type,
    stage: Stage,
    bytes: []const u8,
) !Decoded(
    T,
) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var reader = try Reader.init(bytes);
    if (try reader.readInt(u32) != 1) return error.UnknownSchema;
    if (try reader.readTag(Stage) != stage) return error.WrongStage;
    const value = try read(&reader, arena.allocator(), T, 0);
    if (!reader.atEnd()) return error.InvalidStageRecord;
    return .{ .arena = arena, .value = value };
}

fn write(
    writer: *Writer,
    refs: *const reference.Index,
    comptime T: type,
    source: anytype,
    comptime depth: u8,
) anyerror!void {
    if (depth == 32) @compileError("stage record type exceeds codec depth");
    if (T == reference.Operation and @TypeOf(source) != T) {
        return write(writer, refs, T, try refs.operation(source), depth + 1);
    }
    if (T == reference.Value and @TypeOf(source) != T) {
        return write(writer, refs, T, try refs.value(source), depth + 1);
    }
    const value = indirect(source);
    switch (@typeInfo(T)) {
        .int => try writer.writeInt(if (T == usize) u64 else T, std.math.cast(T, value) orelse
            return error.InvalidStageRecord),
        .float => |info| try writer.writeInt(@Int(.unsigned, info.bits), @bitCast(@as(T, value))),
        .bool => try writer.writeBool(value),
        .@"enum" => |info| if (info.mode == .nonexhaustive)
            try writer.writeInt(info.tag_type, @backingInt(@as(T, value)))
        else
            try writer.writeTag(@as(T, value)),
        .optional => |info| {
            try writer.writeBool(value != null);
            if (value) |present| try write(writer, refs, info.child, present, depth + 1);
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("retained stage pointers must be slices");
            const items = slice(value);
            try writer.writeCount(items.len);
            for (items) |item| try write(writer, refs, info.child, item, depth + 1);
        },
        .array => |info| for (value) |item| try write(writer, refs, info.child, item, depth + 1),
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| {
            try write(writer, refs, Field, @field(value, name), depth + 1);
        },
        .@"union" => |info| {
            const tag = std.meta.activeTag(value);
            try writer.writeTag(tag);
            inline for (info.field_names, info.field_types) |name, Field| {
                if (std.mem.eql(u8, @tagName(tag), name)) {
                    try write(writer, refs, Field, @field(value, name), depth + 1);
                    return;
                }
            }
            unreachable;
        },
        .void => {},
        else => @compileError("unsupported stage record field"),
    }
}

fn read(
    reader: *Reader,
    allocator: std.mem.Allocator,
    comptime T: type,
    comptime depth: u8,
) anyerror!T {
    if (depth == 32) @compileError("stage record type exceeds codec depth");
    return switch (@typeInfo(T)) {
        .int => std.math.cast(T, try reader.readInt(if (T == usize) u64 else T)) orelse
            error.InvalidStageRecord,
        .float => |info| @bitCast(try reader.readInt(@Int(.unsigned, info.bits))),
        .bool => reader.readBool(),
        .@"enum" => |info| if (info.mode == .nonexhaustive)
            @fromBackingInt(try reader.readInt(info.tag_type))
        else
            reader.readTag(T),
        .optional => |info| if (try reader.readBool())
            try read(reader, allocator, info.child, depth + 1)
        else
            null,
        .pointer => |info| result: {
            if (info.size != .slice) @compileError("retained stage pointers must be slices");
            const items = try allocator.alloc(info.child, try reader.readCount());
            for (items) |*item| item.* = try read(reader, allocator, info.child, depth + 1);
            break :result items;
        },
        .array => |info| result: {
            var items: T = undefined;
            for (&items) |*item| item.* = try read(reader, allocator, info.child, depth + 1);
            break :result items;
        },
        .@"struct" => |info| result: {
            var value: T = undefined;
            inline for (info.field_names, info.field_types) |name, Field| {
                @field(value, name) = try read(reader, allocator, Field, depth + 1);
            }
            break :result value;
        },
        .@"union" => |info| result: {
            const tag = try reader.readTag(info.tag_type.?);
            inline for (info.field_names, info.field_types) |name, Field| {
                if (std.mem.eql(u8, @tagName(tag), name)) {
                    const payload = try read(reader, allocator, Field, depth + 1);
                    break :result @unionInit(T, name, payload);
                }
            }
            unreachable;
        },
        .void => {},
        else => @compileError("unsupported stage record field"),
    };
}

pub fn validateReferences(value: anytype, image: choir.bytecode.image.View) !void {
    return validate(value, image, 0);
}

fn validate(value: anytype, image: choir.bytecode.image.View, comptime depth: u8) anyerror!void {
    if (depth == 32) @compileError("stage record type exceeds codec depth");
    const T = @TypeOf(value);
    if (T == reference.Operation) return value.validate(image);
    if (T == reference.Value) {
        _ = try value.ordinal(image);
        return;
    }
    switch (@typeInfo(T)) {
        .optional => if (value) |present| try validate(present, image, depth + 1),
        .pointer, .array => for (value) |item| try validate(item, image, depth + 1),
        .@"struct" => |info| inline for (info.field_names) |name| {
            try validate(@field(value, name), image, depth + 1);
        },
        .@"union" => switch (value) {
            inline else => |payload| try validate(payload, image, depth + 1),
        },
        else => {},
    }
}

/// Runs at compile time for each plan type stage capture code records. The call
/// stops the build when a field of `Source` is missing from `Record` and
/// omitted from `administrative`. The build also stops when a name in
/// `administrative` is absent from `Source` or is present in `Record`. A new
/// analysis field so has to be recorded or named as administrative before the
/// code compiles.
pub fn coverage(
    comptime Source: type,
    comptime Record: type,
    comptime administrative: []const []const u8,
) void {
    inline for (@typeInfo(Source).@"struct".field_names) |name| {
        if (!@hasField(Record, name)) {
            const ignored = comptime for (administrative) |candidate| {
                if (std.mem.eql(u8, candidate, name)) break true;
            } else false;
            if (!ignored) {
                @compileError("uncaptured stage field: " ++ @typeName(Source) ++ "." ++ name);
            }
        }
    }
    inline for (administrative) |name| {
        if (!@hasField(Source, name) or @hasField(Record, name)) {
            @compileError("invalid administrative stage field: " ++ name);
        }
    }
}

fn indirect(value: anytype) Indirect(@TypeOf(value)) {
    return if (comptime @typeInfo(@TypeOf(value)) == .pointer and
        @typeInfo(@TypeOf(value)).pointer.size == .one) value.* else value;
}

fn Indirect(comptime T: type) type {
    return if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one)
        @typeInfo(T).pointer.child
    else
        T;
}

fn slice(value: anytype) Slice(@TypeOf(value)) {
    return if (comptime @typeInfo(@TypeOf(value)) == .@"struct") value.items else value;
}

fn Slice(comptime T: type) type {
    return if (@typeInfo(T) == .@"struct") @FieldType(T, "items") else T;
}

/// Proves that the stage record matches the live plan it came from, after stage
/// capture decodes its own output. The call walks the decoded value beside the
/// live `source` and returns `error.UnencodableProduct` at the first field that
/// differs. The walk has its own code path, apart from the encoder, so a fault
/// in the encoder shows up as a difference.
pub fn compare(value: anytype, source: anytype, refs: *const reference.Index) !void {
    return compareField(value, source, refs, 0);
}

fn compareField(
    value: anytype,
    source: anytype,
    refs: *const reference.Index,
    comptime depth: u8,
) anyerror!void {
    if (depth == 32) @compileError("stage record type exceeds codec depth");
    const T = @TypeOf(value);
    if (T == reference.Operation and @TypeOf(source) != T) {
        return compareField(value, try refs.operation(source), refs, depth + 1);
    }
    if (T == reference.Value and @TypeOf(source) != T) {
        return compareField(value, try refs.value(source), refs, depth + 1);
    }
    const expected = indirect(source);
    switch (@typeInfo(T)) {
        .int => if (value != (std.math.cast(T, expected) orelse return error.UnencodableProduct)) {
            return error.UnencodableProduct;
        },
        .float => |info| {
            const Bits = @Int(.unsigned, info.bits);
            if (@as(Bits, @bitCast(value)) != @as(Bits, @bitCast(@as(T, expected)))) {
                return error.UnencodableProduct;
            }
        },
        .bool, .@"enum" => if (value != expected) return error.UnencodableProduct,
        .optional => {
            if ((value == null) != (expected == null)) return error.UnencodableProduct;
            if (value) |present| try compareField(present, expected.?, refs, depth + 1);
        },
        .pointer, .array => {
            const items = slice(expected);
            if (value.len != items.len) return error.UnencodableProduct;
            for (value, items) |item, original| try compareField(item, original, refs, depth + 1);
        },
        .@"struct" => |info| inline for (info.field_names) |name| {
            try compareField(@field(value, name), @field(expected, name), refs, depth + 1);
        },
        .@"union" => {
            if (std.meta.activeTag(value) != std.meta.activeTag(expected)) {
                return error.UnencodableProduct;
            }
            switch (value) {
                inline else => |payload, tag| {
                    try compareField(payload, @field(expected, @tagName(tag)), refs, depth + 1);
                },
            }
        },
        .void => {},
        else => @compileError("unsupported stage record field"),
    }
}
