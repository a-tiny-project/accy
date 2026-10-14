//! Durable cross-pipeline compilation products and their runtime materialization.
//! Source products own logical partitions and boundaries. Composition products own verified
//! fragments, complete target variants, the shared invocation ABI, and source provenance.
//! Process-local backend state exists only under `LoadedComposition` and per-call `Invocation`.

pub const source = @import("source/root.zig");
pub const module = @import("module/root.zig");
pub const diagnostic = @import("diagnostic/root.zig");
pub const serialization = module.serialization;
pub const abi = @import("abi/root.zig");
pub const loaded = @import("loaded/root.zig");
pub const invocation = @import("invocation.zig");
pub const plan = @import("plan.zig");

pub const PartitionId = source.PartitionId;
pub const BoundaryId = source.BoundaryId;
pub const FragmentId = source.FragmentId;
pub const CallSiteId = source.CallSiteId;
pub const Pipeline = source.Pipeline;
pub const Access = source.Access;
pub const Ownership = source.Ownership;
pub const Provenance = source.Provenance;
pub const ProvenanceSpec = source.ProvenanceSpec;
pub const ElementType = source.ElementType;
pub const Alias = source.Alias;
pub const Boundary = source.Boundary;
pub const BoundarySpec = source.BoundarySpec;
pub const Partition = source.Partition;
pub const PartitionSpec = source.PartitionSpec;
pub const Effect = source.Effect;
pub const SemanticCallSite = source.SemanticCallSite;
pub const SemanticCallSiteSpec = source.SemanticCallSiteSpec;
pub const PartitionedModule = source.PartitionedModule;
pub const PipelineInput = source.PipelineInput;
pub const FragmentPlan = plan.FragmentPlan;

pub const Export = module.Export;
pub const ExportSpec = module.ExportSpec;
pub const Import = module.Import;
pub const ImportSpec = module.ImportSpec;
pub const ImportKind = module.ImportKind;
pub const Fragment = module.Fragment;
pub const FragmentSpec = module.FragmentSpec;
pub const CallSite = module.CallSite;
pub const CallSiteSpec = module.CallSiteSpec;
pub const CompositionVariantId = module.CompositionVariantId;
pub const TargetChoice = module.TargetChoice;
pub const TargetChoiceSpec = module.TargetChoiceSpec;
pub const CompositionVariant = module.CompositionVariant;
pub const CompositionVariantSpec = module.CompositionVariantSpec;
pub const CompositionModule = module.CompositionModule;
pub const DiagnosticPath = module.DiagnosticPath;

pub const LoadedFragment = loaded.LoadedFragment;
pub const FragmentVTable = loaded.FragmentVTable;
pub const MaterializedFragment = loaded.MaterializedFragment;
pub const FragmentMaterializer = loaded.FragmentMaterializer;
pub const LoadedComposition = loaded.LoadedComposition;
pub const EntryError = loaded.EntryError;
pub const LifecycleEvent = loaded.LifecycleEvent;
pub const LifecycleObserver = loaded.LifecycleObserver;

pub const ResourceSpec = invocation.ResourceSpec;
pub const Invocation = invocation.Invocation;
pub const Entry = invocation.Entry;
