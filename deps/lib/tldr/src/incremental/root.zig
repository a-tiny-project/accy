const manifest = @import("manifest.zig");
const patch_module = @import("patch.zig");
const format_module = @import("format.zig");

pub const StringSpan = manifest.StringSpan;
pub const Strings = manifest.Strings;
pub const RecordOwnership = manifest.RecordOwnership;
pub const InputRecord = manifest.InputRecord;
pub const SectionRecord = manifest.SectionRecord;
pub const ContributionKind = manifest.ContributionKind;
pub const ContributionRecord = manifest.ContributionRecord;
pub const DiscardReason = manifest.DiscardReason;
pub const DiscardedContributionRecord = manifest.DiscardedContributionRecord;
pub const ExternalTargetRecord = manifest.ExternalTargetRecord;
pub const ArchiveMemberRecord = manifest.ArchiveMemberRecord;
pub const GotEntryRecord = manifest.GotEntryRecord;
pub const MergePieceRecord = manifest.MergePieceRecord;
pub const InputChangeKind = manifest.InputChangeKind;
pub const InputChange = manifest.InputChange;
pub const InputChangeSummary = manifest.InputChangeSummary;
pub const InputContributionSummary = manifest.InputContributionSummary;
pub const InputChanges = manifest.InputChanges;
pub const RecordedInputs = manifest.RecordedInputs;
pub const InputChangeStorage = manifest.InputChangeStorage;
pub const RelinkDecision = manifest.RelinkDecision;
pub const RelinkBlocker = manifest.RelinkBlocker;
pub const RelinkPlan = manifest.RelinkPlan;

pub const manifest_binary_protocol = manifest.manifest_binary_protocol;

pub const ReplacementContribution = manifest.ReplacementContribution;
pub const DirectRelinkEvidence = manifest.DirectRelinkEvidence;
pub const MemberHashUpdate = manifest.MemberHashUpdate;
pub const PatchDecision = manifest.PatchDecision;
pub const PatchBlocker = manifest.PatchBlocker;
pub const PatchPlan = manifest.PatchPlan;
pub const PatchApplication = manifest.PatchApplication;
pub const FileRange = patch_module.FileRange;
pub const ManifestFieldPatch = format_module.ManifestFieldPatch;
pub const PatchApplyError = manifest.PatchApplyError;
pub const IndexError = manifest.IndexError;
pub const ContributionIndex = manifest.ContributionIndex;

pub const RelinkApplyError = manifest.RelinkApplyError;
pub const ReplacementExtractError = manifest.ReplacementExtractError;
pub const CandidateRelinkApplyError = manifest.CandidateRelinkApplyError;
pub const RelinkManifestUpdateError = manifest.RelinkManifestUpdateError;
pub const RelinkManifestClassifyError = manifest.RelinkManifestClassifyError;
pub const RelinkApplication = manifest.RelinkApplication;
pub const Manifest = manifest.Manifest;
pub const PreparedState = manifest.PreparedState;

pub const planRelinkFromInputChanges = manifest.planRelinkFromInputChanges;
pub const replacementContributionsFromImage = manifest.replacementContributionsFromImage;
pub const freeReplacementContributions = manifest.freeReplacementContributions;
pub const Builder = manifest.Builder;
pub const hashBytes = manifest.hashBytes;
