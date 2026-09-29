const composition = @import("../../root.zig");
const serialization = @import("root.zig");

const source = composition.source;
const Reader = serialization.format.Reader;
const Writer = serialization.format.Writer;

pub fn write(writer: *Writer, value: source.Provenance) serialization.SerializeError!void {
    try writer.writeString(value.path);
    try writer.writeString(value.symbol);
    try writer.writeInt(u32, value.line);
    try writer.writeInt(u32, value.column);
}

pub fn read(reader: *Reader) serialization.DeserializeError!source.ProvenanceSpec {
    const path = try reader.readString();
    const symbol = try reader.readString();
    const line = try reader.readInt(u32);
    const column = try reader.readInt(u32);
    return .{
        .path = path,
        .symbol = symbol,
        .line = line,
        .column = column,
    };
}
