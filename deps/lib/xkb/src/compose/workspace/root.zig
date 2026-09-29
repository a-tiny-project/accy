const capacity = @import("capacity.zig");
const storage = @import("storage.zig");

pub const max_include_depth = capacity.max_include_depth;
pub const max_file_bytes = capacity.max_file_bytes;
pub const max_registry_bytes = capacity.max_registry_bytes;
pub const max_path_bytes = capacity.max_path_bytes;
pub const Limits = capacity.Limits;
pub const Capacity = capacity.Capacity;
pub const default_limits = capacity.default_limits;
pub const Storage = storage.Storage;
pub const Status = storage.Status;
pub const Exhaustion = storage.StorageExhaustion;
