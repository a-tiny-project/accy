const geometry = @import("geometry.zig");
const names = @import("names.zig");
const profile = @import("profile.zig");
const types = @import("types.zig");

pub const Squares = types.Squares;
pub const squares_family_version = types.squares_family_version;
pub const squaresThreadsForCount = geometry.squaresThreadsForCount;
pub const squaresThreadCandidatesForCount = geometry.squaresThreadCandidatesForCount;
pub const squaresFamilyTarget = names.squaresFamilyTarget;
pub const squaresFamilyEntryName = names.squaresFamilyEntryName;
pub const squaresRuntimeArguments = profile.squaresRuntimeArguments;
pub const squaresShapeProfileDimensions = profile.squaresShapeProfileDimensions;
pub const squaresFamilyFingerprint = profile.squaresFamilyFingerprint;
pub const squaresShapeFamily = profile.squaresShapeFamily;
pub const squaresFamilySpecialization = profile.squaresFamilySpecialization;
pub const squaresInstanceFromSpecialization = profile.squaresInstanceFromSpecialization;
