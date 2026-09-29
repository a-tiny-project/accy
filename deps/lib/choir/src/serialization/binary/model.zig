const std = @import("std");

pub const Limits = struct {
    serialized_bytes: usize,
    string_bytes: usize,
    blob_bytes: usize,
    collection_entries: usize,
    total_entries: usize,
};

pub const Error = error{
    Truncated,
    InvalidValue,
    InvalidTag,
    LimitExceeded,
};

pub const WriteError = std.mem.Allocator.Error || error{LimitExceeded};
