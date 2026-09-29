//! Source-owned semantic partitions, logical boundaries, call sites, and provenance.
//! Owned products copy durable descriptors and never retain compiler-context or IR pointers.

pub const identity = @import("identity.zig");
pub const provenance = @import("provenance.zig");
pub const boundary = @import("boundary.zig");
pub const partition = @import("partition.zig");
pub const callsite = @import("callsite.zig");
pub const module = @import("module.zig");
pub const input = @import("input.zig");
pub const slice = @import("slice.zig");
pub const verification = @import("verification/root.zig");

pub const PartitionId = identity.PartitionId;
pub const BoundaryId = identity.BoundaryId;
pub const FragmentId = identity.FragmentId;
pub const CallSiteId = identity.CallSiteId;
pub const Pipeline = identity.Pipeline;
pub const Access = identity.Access;
pub const Ownership = identity.Ownership;
pub const ProvenanceSpec = provenance.ProvenanceSpec;
pub const Provenance = provenance.Provenance;
pub const ElementType = boundary.ElementType;
pub const Alias = boundary.Alias;
pub const BoundarySpec = boundary.BoundarySpec;
pub const Boundary = boundary.Boundary;
pub const PartitionSpec = partition.PartitionSpec;
pub const Partition = partition.Partition;
pub const Effect = partition.Effect;
pub const SemanticCallSiteSpec = callsite.SemanticCallSiteSpec;
pub const SemanticCallSite = callsite.SemanticCallSite;
pub const VerificationError = verification.Error;
pub const PartitionedModule = module.PartitionedModule;
pub const PipelineInput = input.PipelineInput;
pub const boundaryIdsEqual = identity.boundaryIdsEqual;
