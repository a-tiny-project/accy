pub const pass = @import("pass/root.zig");
pub const Pass = pass.Pass;
pub const PassMutationScope = pass.PassMutationScope;
pub const PassStateConcurrency = pass.PassStateConcurrency;
pub const PassRerunPolicy = pass.PassRerunPolicy;
pub const DependentDialects = pass.DependentDialects;
pub const dialectDependencies = pass.dialectDependencies;
pub const PassContext = pass.PassContext;
pub const PassResult = pass.PassResult;
pub const PassFailureKind = pass.PassFailureKind;
pub const PassFailureReproducer = pass.PassFailureReproducer;
pub const PassManagerRunOptions = pass.PassManagerRunOptions;
pub const PassManagerFixedPointResult = pass.PassManagerFixedPointResult;
pub const PassManager = pass.PassManager;
pub const OpPassManager = pass.OpPassManager;
pub const OpPassManagerTargetKind = pass.OpPassManagerTargetKind;
pub const PipelineEntry = pass.PipelineEntry;
pub const OperationPass = pass.OperationPass;
pub const AnalysisId = pass.AnalysisId;
pub const analysisId = pass.analysisId;
pub const Analysis = pass.Analysis;
pub const AnalysisDescriptor = pass.AnalysisDescriptor;
pub const PreservedAnalyses = pass.PreservedAnalyses;
pub const AnalysisCache = pass.AnalysisCache;
pub const PassManagerStats = pass.PassManagerStats;

pub const reproducer = @import("reproducer.zig");
pub const ReplayOptions = reproducer.ReplayOptions;
pub const ReplayResult = reproducer.ReplayResult;
pub const formatPassFailureReproducerAlloc = reproducer.formatPassFailureReproducerAlloc;
pub const writePassFailureReproducer = reproducer.writePassFailureReproducer;
pub const writePassFailureReproducerFile = reproducer.writePassFailureReproducerFile;
pub const parsePassFailureReproducerAlloc = reproducer.parsePassFailureReproducerAlloc;
pub const replayPassFailureReproducer = reproducer.replayPassFailureReproducer;

pub const pipeline = @import("pipeline.zig");
pub const PassRegistration = pipeline.PassRegistration;
pub const PassRegistry = pipeline.PassRegistry;
pub const PassOptionSpec = pipeline.PassOptionSpec;
pub const PassOptionChoice = pipeline.PassOptionChoice;
pub const PassOptionAssignment = pipeline.PassOptionAssignment;
pub const PassOptionSet = pipeline.PassOptionSet;
pub const PassOptionsBuilderFn = pipeline.PassOptionsBuilderFn;
pub const PipelineOptionsBuilderFn = pipeline.PipelineOptionsBuilderFn;
pub const PipelineBuilderFn = pipeline.PipelineBuilderFn;
pub const PipelineRegistration = pipeline.PipelineRegistration;
pub const PipelineRegistry = pipeline.PipelineRegistry;
pub const PipelineError = pipeline.PipelineError;
pub const RegistryError = pipeline.RegistryError;
pub const plan = @import("plan.zig");
pub const PassPlan = plan.Plan;
pub const PassPlanStep = plan.Step;
pub const PassPlanTarget = plan.Target;
pub const PassPlanInvocation = plan.Invocation;
pub const PassPlanNested = plan.Nested;
pub const formatPassPlanOptionsAlloc = plan.formatOptionsAlloc;
pub const writePassPlanOptions = plan.writeOptions;
pub const textual_pipeline = @import("textual.zig");
pub const TextualPipelineError = textual_pipeline.TextualPipelineError;
pub const parsePassPipeline = textual_pipeline.parsePassPipeline;
pub const parseOpPassPipeline = textual_pipeline.parseOpPassPipeline;
pub const writePassManagerPipeline = textual_pipeline.writePassManagerPipeline;
pub const writeOpPassManagerPipeline = textual_pipeline.writeOpPassManagerPipeline;
pub const formatPassManagerPipelineAlloc = textual_pipeline.formatPassManagerPipelineAlloc;
pub const formatOpPassManagerPipelineAlloc = textual_pipeline.formatOpPassManagerPipelineAlloc;

pub const instrumentation = @import("instrumentation.zig");
pub const PassInstrumentation = instrumentation.PassInstrumentation;
pub const PassInstrumentor = instrumentation.PassInstrumentor;
pub const PassInfo = instrumentation.PassInfo;
pub const PipelineInfo = instrumentation.PipelineInfo;
pub const AnalysisInfo = instrumentation.AnalysisInfo;
pub const PassStatisticInfo = instrumentation.PassStatisticInfo;
pub const TimingInstrumentation = instrumentation.TimingInstrumentation;
pub const IRPrintingInstrumentation = instrumentation.IRPrintingInstrumentation;
pub const VerifierInstrumentation = instrumentation.VerifierInstrumentation;
pub const CountingInstrumentation = instrumentation.CountingInstrumentation;
pub const PassStatisticsInstrumentation = instrumentation.PassStatisticsInstrumentation;
pub const PassStatisticSummary = instrumentation.PassStatisticSummary;
pub const PassTimingOptions = instrumentation.PassTimingOptions;
pub const PassAllocationSnapshot = instrumentation.PassAllocationSnapshot;
pub const PassAllocationSnapshotProvider = instrumentation.PassAllocationSnapshotProvider;
pub const PipelineTimingSummary = instrumentation.PipelineTimingSummary;
pub const PassRunTimingSummary = instrumentation.PassRunTimingSummary;
pub const PassTimingSummary = instrumentation.PassTimingSummary;
pub const IRPrintingOptions = instrumentation.IRPrintingOptions;
pub const VerifierInstrumentationFailure = instrumentation.VerifierInstrumentationFailure;
pub const VerifierInstrumentationOptions = instrumentation.VerifierInstrumentationOptions;

pub const control_flow = @import("control.zig");
pub const RegionControlFlow = control_flow.RegionControlFlow;
pub const ControlFlowGraphAnalysis = control_flow.ControlFlowGraphAnalysis;
pub const DominanceAnalysis = control_flow.DominanceAnalysis;
pub const PostDominanceAnalysis = control_flow.PostDominanceAnalysis;
pub const cfg_analysis_descriptor = control_flow.cfg_analysis_descriptor;
pub const dominance_analysis_descriptor = control_flow.dominance_analysis_descriptor;
pub const post_dominance_analysis_descriptor = control_flow.post_dominance_analysis_descriptor;
pub const getControlFlowGraphAnalysis = control_flow.getControlFlowGraphAnalysis;
pub const getDominanceAnalysis = control_flow.getDominanceAnalysis;
pub const getPostDominanceAnalysis = control_flow.getPostDominanceAnalysis;

pub const canonicalization = @import("canonicalization.zig");
pub const CanonicalizationPassSpec = canonicalization.CanonicalizationPassSpec;
pub const CanonicalizationPass = canonicalization.CanonicalizationPass;
pub const createCanonicalizationPass = canonicalization.createCanonicalizationPass;
pub const builtin_canonicalization_patterns = canonicalization.builtin_canonicalization_patterns;
pub const populateBuiltinCanonicalizationPatterns =
    canonicalization.populateBuiltinCanonicalizationPatterns;
pub const registeredFoldPatternSpec = canonicalization.registeredFoldPatternSpec;
pub const populateRegisteredFoldPatterns = canonicalization.populateRegisteredFoldPatterns;
pub const populateRegisteredCanonicalizationPatterns =
    canonicalization.populateRegisteredCanonicalizationPatterns;
pub const canonicalization_pass_name = canonicalization.canonicalization_pass_name;
pub const canonicalization_pass_description = canonicalization.canonicalization_pass_description;
pub const canonicalization_pass_registration = canonicalization.canonicalization_pass_registration;
pub const isTriviallyDead = canonicalization.isTriviallyDead;
pub const eliminateDeadOps = canonicalization.eliminateDeadOps;

pub const cse = @import("cse/root.zig");
pub const effects = @import("effects.zig");
pub const optimizations = @import("optimizations.zig");
pub const dead_code_elimination_pass_name = optimizations.dead_code_elimination_pass_name;
pub const dead_code_elimination_pass_description =
    optimizations.dead_code_elimination_pass_description;
pub const common_subexpression_elimination_pass_name =
    optimizations.common_subexpression_elimination_pass_name;
pub const common_subexpression_elimination_pass_description =
    optimizations.common_subexpression_elimination_pass_description;
pub const constant_folding_pass_name = optimizations.constant_folding_pass_name;
pub const constant_folding_pass_description = optimizations.constant_folding_pass_description;
pub const sparse_conditional_constant_propagation_pass_name =
    optimizations.sparse_conditional_constant_propagation_pass_name;
pub const sparse_conditional_constant_propagation_pass_description =
    optimizations.sparse_conditional_constant_propagation_pass_description;
pub const load_store_forwarding_pass_name = optimizations.load_store_forwarding_pass_name;
pub const load_store_forwarding_pass_description =
    optimizations.load_store_forwarding_pass_description;
pub const dead_store_elimination_pass_name = optimizations.dead_store_elimination_pass_name;
pub const dead_store_elimination_pass_description =
    optimizations.dead_store_elimination_pass_description;
pub const loop_invariant_code_motion_pass_name = optimizations.loop_invariant_code_motion_pass_name;
pub const loop_invariant_code_motion_pass_description =
    optimizations.loop_invariant_code_motion_pass_description;
pub const equality_saturation_pass_name = optimizations.equality_saturation_pass_name;
pub const equality_saturation_pass_description = optimizations.equality_saturation_pass_description;
pub const default_optimization_pipeline_name = optimizations.default_optimization_pipeline_name;
pub const default_optimization_pipeline_description =
    optimizations.default_optimization_pipeline_description;
pub const createDeadCodeEliminationPass = optimizations.createDeadCodeEliminationPass;
pub const createCommonSubexpressionEliminationPass =
    optimizations.createCommonSubexpressionEliminationPass;
pub const createConstantFoldingPass = optimizations.createConstantFoldingPass;
pub const createSparseConditionalConstantPropagationPass =
    optimizations.createSparseConditionalConstantPropagationPass;
pub const createLoadStoreForwardingPass = optimizations.createLoadStoreForwardingPass;
pub const createDeadStoreEliminationPass = optimizations.createDeadStoreEliminationPass;
pub const createLoopInvariantCodeMotionPass = optimizations.createLoopInvariantCodeMotionPass;
pub const createEqualitySaturationPass = optimizations.createEqualitySaturationPass;
pub const dead_code_elimination_pass_registration =
    optimizations.dead_code_elimination_pass_registration;
pub const common_subexpression_elimination_pass_registration =
    optimizations.common_subexpression_elimination_pass_registration;
pub const constant_folding_pass_registration = optimizations.constant_folding_pass_registration;
pub const sparse_conditional_constant_propagation_pass_registration =
    optimizations.sparse_conditional_constant_propagation_pass_registration;
pub const load_store_forwarding_pass_registration =
    optimizations.load_store_forwarding_pass_registration;
pub const dead_store_elimination_pass_registration =
    optimizations.dead_store_elimination_pass_registration;
pub const loop_invariant_code_motion_pass_registration =
    optimizations.loop_invariant_code_motion_pass_registration;
pub const equality_saturation_pass_registration =
    optimizations.equality_saturation_pass_registration;
pub const optimization_pass_registrations = optimizations.optimization_pass_registrations;
pub const default_optimization_pipeline_registration =
    optimizations.default_optimization_pipeline_registration;
pub const optimization_pipeline_registrations = optimizations.optimization_pipeline_registrations;
pub const addDefaultOptimizationPipeline = optimizations.addDefaultOptimizationPipeline;
pub const buildDefaultOptimizationPipeline = optimizations.buildDefaultOptimizationPipeline;
pub const registerOptimizationPassEntries = optimizations.registerOptimizationPassEntries;
pub const memref_views = @import("views.zig");
pub const promotion = @import("promotion.zig");

pub const saturation = @import("saturation.zig");
pub const EGraphOptimizationOptions = saturation.OptimizationOptions;
pub const EGraphOptimizationStats = saturation.OptimizationStats;
pub const EGraphPassConfig = saturation.PassConfig;
pub const EGraphPass = saturation.EGraphPass;
pub const runEGraphOptimization = saturation.runOptimization;

pub const conversion = @import("conversion.zig");
pub const ConversionTarget = conversion.ConversionTarget;
pub const Legality = conversion.Legality;
pub const ConversionOptions = conversion.ConversionOptions;
pub const applyPartialConversion = conversion.applyPartialConversion;
pub const applyFullConversion = conversion.applyFullConversion;
pub const applyPartialConversionWithOptions = conversion.applyPartialConversionWithOptions;
pub const applyFullConversionWithOptions = conversion.applyFullConversionWithOptions;
pub const GreedyRewriteStrictness = conversion.GreedyRewriteStrictness;
pub const GreedyRewriteConfig = conversion.GreedyRewriteConfig;
pub const GreedyRewriteResult = conversion.GreedyRewriteResult;
pub const applyPatternsGreedily = conversion.applyPatternsGreedily;

pub const BlockDominanceAnalysis = @import("control.zig").BlockDominanceAnalysis;
pub const RegionDominance = @import("control.zig").RegionDominance;
pub const ConversionInitialSnapshot = @import("conversion.zig").OperationSnapshot;
