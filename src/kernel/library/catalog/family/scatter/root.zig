const scatter = @import("scatter.zig");
const scatter_add = @import("add.zig");

pub const ScatterCandidateDescriptors = scatter.ScatterCandidateDescriptors;
pub const ScatterAddCandidateDescriptors = scatter_add.ScatterAddCandidateDescriptors;
pub const selectScatter = scatter.selectScatter;
pub const selectScatterCandidates = scatter.selectScatterCandidates;
pub const selectScatterAdd = scatter_add.selectScatterAdd;
pub const selectScatterAddCandidates = scatter_add.selectScatterAddCandidates;
