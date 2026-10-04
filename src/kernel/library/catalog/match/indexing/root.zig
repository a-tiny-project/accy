const gather = @import("gather.zig");
const histogram = @import("histogram.zig");
const scatter = @import("scatter.zig");
const scatter_add = @import("accumulate.zig");

pub const gatherDescriptorMatches = gather.gatherDescriptorMatches;
pub const scatterDescriptorMatches = scatter.scatterDescriptorMatches;
pub const scatterAddDescriptorMatches = scatter_add.scatterAddDescriptorMatches;
pub const histogramDescriptorMatches = histogram.histogramDescriptorMatches;
