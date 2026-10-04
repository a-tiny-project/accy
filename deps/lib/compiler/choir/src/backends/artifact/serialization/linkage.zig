const std = @import("std");
const artifact = @import("../root.zig");
const format = @import("root.zig").format;

const Signature = artifact.Signature;

pub fn write(writer: *format.Writer, value: artifact.Linkage) format.WriteError!void {
    try writer.writeCount(value.required_symbols.items.len);
    for (value.required_symbols.items) |symbol| try writeSymbol(writer, symbol);
    try writer.writeCount(value.provided_symbols.items.len);
    for (value.provided_symbols.items) |symbol| try writeSymbol(writer, symbol);
    try writer.writeCount(value.relocations.items.len);
    for (value.relocations.items) |relocation| {
        try writer.writeInt(u64, relocation.offset);
        try writer.writeString(relocation.symbol);
        try writer.writeTag(relocation.kind);
        try writer.writeInt(i64, relocation.addend);
        try writer.writeOptionalU16(relocation.width_bits);
    }
}

pub fn readInto(reader: *format.Reader, value: *artifact.Linkage) (format.Error || std.mem.Allocator.Error)!void {
    const required_count = try reader.readCount();
    for (0..required_count) |_| try value.addRequired(try readSymbol(reader));
    const provided_count = try reader.readCount();
    for (0..provided_count) |_| try value.addProvided(try readSymbol(reader));
    const relocation_count = try reader.readCount();
    for (0..relocation_count) |_| {
        try value.addRelocation(.{
            .offset = try reader.readInt(u64),
            .symbol = try reader.readString(),
            .kind = try reader.readTag(artifact.RelocationKind),
            .addend = try reader.readInt(i64),
            .width_bits = try reader.readOptionalU16(),
        });
    }
}

fn writeSymbol(writer: *format.Writer, symbol: artifact.Symbol) format.WriteError!void {
    try writer.writeString(symbol.name);
    try writer.writeTag(symbol.kind);
    try writer.writeTag(symbol.binding);
    try writer.writeBool(symbol.signature != null);
    if (symbol.signature) |*signature| try writeSignature(writer, signature);
}

fn readSymbol(reader: *format.Reader) format.Error!artifact.Symbol {
    const name = try reader.readString();
    const kind = try reader.readTag(artifact.SymbolKind);
    const binding = try reader.readTag(artifact.SymbolBinding);
    const signature: ?Signature = if (try reader.readBool()) try readSignature(reader) else null;
    return .{ .name = name, .kind = kind, .binding = binding, .signature = signature };
}

fn writeSignature(writer: *format.Writer, signature: *const Signature) format.WriteError!void {
    std.debug.assert(signature.isValid());
    try writer.writeInt(u8, signature.parameter_count);
    try writer.writeInt(u8, signature.result_count);
    for (signature.parameters()) |value_type| try writeValueType(writer, value_type);
    for (signature.results()) |value_type| try writeValueType(writer, value_type);
}

fn readSignature(reader: *format.Reader) format.Error!Signature {
    const parameter_count = try reader.readInt(u8);
    const result_count = try reader.readInt(u8);
    if (parameter_count > Signature.max_parameters) return error.LimitExceeded;
    if (result_count > Signature.max_results) return error.LimitExceeded;
    var parameters: [Signature.max_parameters]artifact.ValueType = undefined;
    for (parameters[0..parameter_count]) |*value_type| value_type.* = try readValueType(reader);
    var results: [Signature.max_results]artifact.ValueType = undefined;
    for (results[0..result_count]) |*value_type| value_type.* = try readValueType(reader);
    const signature = Signature.init(
        parameters[0..parameter_count],
        results[0..result_count],
    ) catch |err| switch (err) {
        error.TooManyParameters, error.TooManyResults => unreachable,
        error.InvalidValueType => return error.InvalidValue,
    };
    std.debug.assert(signature.parameter_count == parameter_count);
    std.debug.assert(signature.result_count == result_count);
    return signature;
}

fn writeValueType(writer: *format.Writer, value_type: artifact.ValueType) format.WriteError!void {
    try writer.writeTag(std.meta.activeTag(value_type));
    switch (value_type) {
        .scalar => |scalar| try writer.writeTag(scalar),
        .memref => {},
        .vector => |vector| {
            try writer.writeTag(vector.element);
            try writer.writeInt(u8, vector.lanes);
        },
    }
}

fn readValueType(reader: *format.Reader) format.Error!artifact.ValueType {
    return switch (try reader.readTag(artifact.ValueKind)) {
        .scalar => .{ .scalar = try reader.readTag(artifact.ScalarType) },
        .memref => .memref,
        .vector => .{ .vector = .{
            .element = try reader.readTag(artifact.ScalarType),
            .lanes = try reader.readInt(u8),
        } },
    };
}
