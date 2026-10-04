const std = @import("std");
const graph = @import("src/root.zig");
const layout = @import("src/build_layout.zig");
const timing = @import("timing/root.zig");
const provenance = @import("src/provenance/root.zig");

pub const RepositoryProvenanceOptions = provenance.Options;
pub const RepositoryProvenance = provenance.Modules;
pub const addRepositoryProvenance = provenance.add;
pub const RepositoryStatusOptions = provenance.StatusOptions;
pub const RepositoryStatus = provenance.StatusModules;
pub const addRepositoryStatus = provenance.addStatus;

pub const attachCompilerManifest = graph.attachCompilerManifest;
pub const exportCompilerBinding = graph.exportCompilerBinding;
pub const CompilerBinding = graph.CompilerBinding;
pub const exposeCompilerBinding = graph.exposeCompilerBinding;
pub const tryExposeCompilerBinding = graph.tryExposeCompilerBinding;
pub const CompilerBindingSelection = graph.CompilerBindingSelection;
pub const check = graph.check;
pub const requirements = graph.requirements;
pub const restriction = graph.restriction;
pub const validation = @import("validation/root.zig");
pub const validationBuild = @import("src/validation/root.zig");

pub const BuildLayout = layout.BuildLayout;
pub const ChildBuildLayout = graph.ChildBuildLayout;
pub const ChildBuildArguments = graph.ChildBuildArguments;
pub const ChildBuildArgument = graph.ChildBuildArgument;
pub const ChildBuildFileOption = graph.ChildBuildFileOption;
pub const ChildBuildOptions = graph.ChildBuildOptions;
pub const ChildBuildSummary = graph.ChildBuildSummary;
pub const ProductBackend = graph.ProductBackend;
pub const productBackendOption = graph.productBackendOption;
pub const RawCompileOptions = graph.RawCompileOptions;
pub const RawCompileSelection = graph.RawCompileSelection;
pub const rawCompilerBackend = graph.rawCompilerBackend;
pub const hostToolBackend = graph.hostToolBackend;
pub const IterationObservation = graph.IterationObservation;
pub const IterationMarkerExecutable = graph.IterationMarkerExecutable;
pub const BuildLifetime = graph.BuildLifetime;
pub const incrementalAudit = graph.incrementalAudit;
pub const buildArguments = graph.buildArguments;
pub const liveCompilerArguments = graph.liveCompilerArguments;
pub const compilerIncrementalArguments =
    graph.compilerIncrementalArguments;
pub const child_cache_directory_argument =
    graph.child_cache_directory_argument;
pub const applyCompilerIncrementalPolicy =
    graph.applyCompilerIncrementalPolicy;
pub const PackageConfiguration = graph.PackageConfiguration;
pub const addChildBuild = graph.addChildBuild;
pub const appendChildBuild = graph.appendChildBuild;
pub const addChildWatch = graph.addChildWatch;
pub const addIterationMarker = graph.addIterationMarker;
pub const addIterationObservation = graph.addIterationObservation;
pub const resolvePackageConfiguration = graph.resolvePackageConfiguration;
pub const focusedTestFilters = graph.focusedTestFilters;
pub const testFilters = graph.testFilters;
pub const mergeFilters = graph.mergeFilters;
pub const mergedTestFilters = graph.mergedTestFilters;
pub const LibrarySpec = graph.LibrarySpec;
pub const addStaticLibrary = graph.addStaticLibrary;
pub const ModuleOptions = graph.ModuleOptions;
pub const directory = graph.directory;
pub const parallel = graph.parallel;
pub const sourcePath = graph.sourcePath;
pub const sourceRelativePath = graph.sourceRelativePath;
pub const registerModule = graph.registerModule;
pub const requireImport = graph.requireImport;
pub const Targets = graph.Targets;
pub const standardTargets = graph.standardTargets;
pub const targetsEqual = graph.targetsEqual;
pub const targetQuery = graph.targetQuery;
pub const runnableBaselineTargetQuery = graph.runnableBaselineTargetQuery;
pub const addTestRun = graph.addTestRun;
pub const ResourceClass = graph.ResourceClass;
pub const addResourceReporter = graph.addResourceReporter;
pub const addResourceRun = graph.addResourceRun;
pub const ChildResources = graph.ChildResources;
pub const TestResourceMode = graph.TestResourceMode;
pub const TestResourcePolicy = graph.TestResourcePolicy;
pub const applyExecutedGraphResourcePolicy = graph.applyExecutedGraphResourcePolicy;
pub const applyTestCompileResourcePolicy = graph.applyTestCompileResourcePolicy;
pub const applyTestGraphResourcePolicy = graph.applyTestGraphResourcePolicy;
pub const applyTestRunResourceClaim = graph.applyTestRunResourceClaim;
pub const applyTestRunResourcePolicy = graph.applyTestRunResourcePolicy;
pub const defaultChildBuildJobs = graph.defaultChildBuildJobs;
pub const defaultTestResourceSlots = graph.defaultTestResourceSlots;
pub const requireStepReachable = graph.requireStepReachable;
pub const requireStepUnreachable = graph.requireStepUnreachable;
pub const addFocusedTestRun = timing.addFocusedRun;
pub const addCachedTestRun = timing.addCachedRun;
pub const TestTimeout = timing.TestTimeout;
pub const CachedTestRunInput = timing.CachedRunInput;
pub const CachedTestRunOptions = timing.CachedRunOptions;
pub const addShardedTestRun = timing.addShardedRun;
pub const ShardedTestRunOptions = timing.ShardedRunOptions;
pub const timingReceiptDirectoryOption = timing.directory_option;
pub const timingReceiptTokenOption = timing.token_option;
pub const timingReceiptDirectoryEnvironment = timing.directory_environment;
pub const timingReceiptTokenEnvironment = timing.token_environment;
pub const timingShardCountEnvironment = timing.shard_count_environment;
pub const configure = graph.configure;
pub const PackageGraph = graph.PackageGraph;
pub const package = graph.package;
pub const packageWithQualification = graph.packageWithQualification;
pub const RootInputs = graph.RootInputs;
pub const RootGraph = graph.RootGraph;
pub const rootPackage = graph.rootPackage;
pub const iterationSelectedStepOption = graph.iterationSelectedStepOption;
pub const iterationReceiptDirectoryOption = graph.iterationReceiptDirectoryOption;
pub const iterationReceiptTokenOption = graph.iterationReceiptTokenOption;
pub const iterationRequestFileOption = graph.iterationRequestFileOption;
pub const iterationExternalMarkerOption = graph.iterationExternalMarkerOption;
pub const buildDevFixtures = @import("src/register.zig").buildDevFixtures;

pub fn build(b: *std.Build) void {
    graph.package(b, buildWithValidation);
}

fn buildWithValidation(b: *std.Build) void {
    @import("src/register.zig").buildWithValidation(b, validationBuild);
}
