const arguments = @import("arguments.zig");
const artifact = @import("artifact.zig");
const body = @import("body.zig");

pub const histogramRuntimeArguments = arguments.histogramRuntimeArguments;
pub const HistogramRuntimeFamilyF32 = body.HistogramRuntimeFamilyF32;
pub const createHistogramFamilyArtifact = artifact.createHistogramFamilyArtifact;
