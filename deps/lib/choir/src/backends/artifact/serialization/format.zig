const binary = @import("../../../serialization/root.zig").binary;

pub const magic = "CHOIRART";
pub const version: u32 = 2;
pub const max_serialized_bytes: usize = 256 * 1024 * 1024;
pub const max_string_bytes: usize = 1024 * 1024;
pub const max_blob_bytes: usize = 64 * 1024 * 1024;
pub const max_collection_entries: usize = 1 << 16;
pub const max_total_entries: usize = 1 << 18;

pub const limits = binary.Limits{
    .serialized_bytes = max_serialized_bytes,
    .string_bytes = max_string_bytes,
    .blob_bytes = max_blob_bytes,
    .collection_entries = max_collection_entries,
    .total_entries = max_total_entries,
};

pub const Error = binary.Error || error{
    InvalidMagic,
    UnsupportedVersion,
    TrailingBytes,
};

pub const WriteError = binary.WriteError;
pub const Writer = binary.Writer(limits);
pub const Reader = binary.Reader(limits);
