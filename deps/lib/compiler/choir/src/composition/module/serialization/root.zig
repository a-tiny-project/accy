const model = @import("../root.zig");
const artifact = @import("../../../backends/root.zig").artifact;

pub const codec = @import("codec.zig");
pub const reference = @import("reference.zig");
pub const serialize = codec.serialize;
pub const deserialize = codec.deserialize;

pub const format = @import("format.zig");
pub const provenance = @import("provenance.zig");
pub const source = @import("source.zig");
pub const fragment = @import("fragment.zig");
pub const call = @import("call.zig");
pub const variant = @import("variant.zig");

pub const magic = format.magic;
pub const format_version = format.version;
pub const SerializeError = format.WriteError || model.VerificationError;
pub const DeserializeError = format.Error || artifact.serialization.DeserializeError ||
    model.VerificationError || error{ InvalidProductRecord, ProductRecordCapacityExceeded };
