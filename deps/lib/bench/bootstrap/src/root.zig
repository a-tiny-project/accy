//! Bootstrap resampling shared by bench's statistics and comparisons and by
//! capture's effect intervals. The package imports only `std`, so capture takes
//! these primitives without linking bench.
//!
//! Each named interval stays with its owner, which chooses the statistic, the
//! draw order, the seed and the rule that reads the interval off the sorted
//! bootstrap distribution. The primitives here fix what a resample and a rank
//! mean, so every owner draws and ranks the same way.

const interval_mod = @import("interval.zig");
const resample = @import("resample.zig");

pub const resampleCounts = resample.resampleCounts;
pub const resampleMean = resample.resampleMean;
pub const rankValue = resample.rankValue;
pub const nearestRank = resample.nearestRank;
pub const Interval = interval_mod.Interval;
pub const Rule = interval_mod.Rule;
pub const interval = interval_mod.interval;
