const base = @import("base.zig");
const traits = @import("traits.zig");
const attrs = @import("attrs.zig");
const ops = @import("ops.zig");
const types = @import("types.zig");
const entry = @import("entry.zig");

pub const InlineList = entry.InlineList;

pub const ContextOpaque = base.ContextOpaque;
pub const castContext = base.castContext;
pub const InterfaceId = base.InterfaceId;
pub const interfaceId = base.interfaceId;
pub const interfaceIdRuntime = base.interfaceIdRuntime;
pub const InterfaceEntry = base.InterfaceEntry;
pub const TypeParamPayload = base.TypeParamPayload;

pub const TraitId = traits.TraitId;
pub const traitId = traits.traitId;
pub const traitIdRuntime = traits.traitIdRuntime;
pub const OperationTraits = traits.OperationTraits;
pub const TraitVTable = traits.TraitVTable;
pub const TraitEntry = traits.TraitEntry;
pub const TraitRegistry = traits.TraitRegistry;

pub const AbstractAttribute = attrs.AbstractAttribute;
pub const AttributeEqualInterface = attrs.AttributeEqualInterface;
pub const AttributePrintInterface = attrs.AttributePrintInterface;
pub const AttributeArrayInterface = attrs.AttributeArrayInterface;
pub const SymbolUserAttrInterface = attrs.SymbolUserAttrInterface;
pub const AttributeRegistry = attrs.AttributeRegistry;

pub const OperationInfo = ops.OperationInfo;
pub const CountRange = ops.CountRange;
pub const OperationShape = ops.OperationShape;
pub const OperationSegmentSpec = ops.OperationSegmentSpec;
pub const OperationTypeConstraint = ops.OperationTypeConstraint;
pub const OperationPropertiesModel = ops.OperationPropertiesModel;
pub const singleAttributePropertiesModel = ops.singleAttributePropertiesModel;
pub const OperationRegistry = ops.OperationRegistry;
pub const CseOpInterface = ops.CseOpInterface;
pub const SymbolOpInterface = ops.SymbolOpInterface;
pub const SymbolUserOpInterface = ops.SymbolUserOpInterface;
pub const CallOpInterface = ops.CallOpInterface;
pub const FunctionOpInterface = ops.FunctionOpInterface;
pub const RegionKind = ops.RegionKind;
pub const RegionKindInterface = ops.RegionKindInterface;
pub const ControlFlowInterface = ops.ControlFlowInterface;
pub const InferTypeOpInterface = ops.InferTypeOpInterface;
pub const FoldResult = ops.FoldResult;
pub const FoldResults = ops.FoldResults;
pub const FoldOpInterface = ops.FoldOpInterface;
pub const DiagnosticKind = ops.DiagnosticKind;
pub const EvalError = ops.EvalError;
pub const EvalContext = ops.EvalContext;
pub const Evaluatable = ops.Evaluatable;
pub const YieldOpInterface = ops.YieldOpInterface;
pub const HandlerEntryOpInterface = ops.HandlerEntryOpInterface;
pub const TranslationDialectInterface = ops.TranslationDialectInterface;

pub const TypeInfo = types.TypeInfo;
pub const TypeRegistry = types.TypeRegistry;
pub const TypePrintInterface = types.TypePrintInterface;
pub const TypeVerifyInterface = types.TypeVerifyInterface;
pub const TypeParamInterface = types.TypeParamInterface;
pub const ShapedTypeInterface = types.ShapedTypeInterface;

pub const effects = @import("effects.zig");
pub const EffectOpInterface = effects.EffectOpInterface;
