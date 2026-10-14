//! Serializable fragments and complete physical target variants.
//! A variant selects a whole program so placement, calls, artifacts, and ABI facts cannot drift.

pub const symbol = @import("symbol.zig");
pub const fragment = @import("fragment.zig");
pub const callsite = @import("callsite.zig");
pub const variant = @import("variant.zig");
pub const composition = @import("composition.zig");
pub const serialization = @import("serialization/root.zig");
pub const verification = @import("verification/root.zig");

pub const ExportSpec = symbol.ExportSpec;
pub const Export = symbol.Export;
pub const ImportKind = symbol.ImportKind;
pub const ImportSpec = symbol.ImportSpec;
pub const Import = symbol.Import;
pub const FragmentSpec = fragment.FragmentSpec;
pub const Fragment = fragment.Fragment;
pub const CallSiteSpec = callsite.CallSiteSpec;
pub const CallSite = callsite.CallSite;
pub const CompositionVariantId = variant.CompositionVariantId;
pub const TargetChoiceSpec = variant.TargetChoiceSpec;
pub const TargetChoice = variant.TargetChoice;
pub const CompositionVariantSpec = variant.CompositionVariantSpec;
pub const CompositionVariant = variant.CompositionVariant;
pub const VerificationError = composition.VerificationError;
pub const DiagnosticPath = composition.DiagnosticPath;
pub const CompositionModule = composition.CompositionModule;
