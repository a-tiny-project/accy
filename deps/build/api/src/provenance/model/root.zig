const model = @import("resolve.zig");

pub const revision_bytes = model.revision_bytes;
pub const source_base_bytes_max = model.source_base_bytes_max;
pub const source_prefix_bytes_max = model.source_prefix_bytes_max;
pub const version_bytes_max = model.version_bytes_max;
pub const Inputs = model.Inputs;
pub const RevisionInputs = model.RevisionInputs;
pub const resolveRevision = model.resolveRevision;
pub const Values = model.Values;
pub const Failure = model.Failure;
pub const Resolution = model.Resolution;
pub const resolve = model.resolve;
pub const writeStringModule = model.writeStringModule;
pub const validRevision = model.validRevision;
pub const sourceBaseEndsWith = model.sourceBaseEndsWith;
pub const writeUnavailableStringModule = model.writeUnavailableStringModule;
pub const source_base_unavailable_message = model.source_base_unavailable_message;
