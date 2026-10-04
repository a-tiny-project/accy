/// Failures a code generator or interface check reports. Runtime error sets
/// contain these names, so they propagate into a runtime by name.
pub const Error = error{
    UnsupportedOperation,
    InvalidArtifact,
    CapabilityMismatch,
    CompilationFailed,
    OutOfMemory,
};
