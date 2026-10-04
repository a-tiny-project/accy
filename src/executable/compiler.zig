const std = @import("std");
const gpu = @import("gpu");
const choir = @import("choir");
const fragment = @import("fragment.zig");
const preparation = @import("../preparation/root.zig");
const semantic = @import("../choir/root.zig").semantic;
const Prepared = preparation.pipeline.BackendPreparedModule;

pub const FragmentCompilationRequest = struct {
    source: []const u8,
    variant: []const u8 = "",
    work: choir.product.revision.receipt.Limits,
    record_bytes: u32,
    artifact_workspace: []u8,
};

pub const FragmentCompilerCacheUpdate = struct {
    preparation: preparation.BackendPreparationCacheUpdate,
    /// The cache owns the loaded fragment that this refresh produced. A caller
    /// launches the current program through this pointer after a refresh. The
    /// pointer stays valid until the next refresh that succeeds or until the
    /// cache is destroyed, and both free it.
    fragment: *fragment.LoadedFragment,

    pub fn deinit(self: *FragmentCompilerCacheUpdate, allocator: std.mem.Allocator) void {
        self.preparation.deinit(allocator);
        self.* = undefined;
    }
};

/// The cache holds one preparation cache and the loaded fragment built from it.
/// A caller keeps one of these per program to recompile and reload it cheaply
/// as the program changes. A refresh reuses a compile stage only when the
/// preparation cache's own admission check accepts it. Device code is compiled
/// from the prepared result and loaded again on every refresh. A refresh works
/// on a forked copy of the preparation cache and swaps the copy and the new
/// loaded fragment in only after both succeed, so a failure leaves the earlier
/// preparation and fragment in place.
pub const FragmentCompilerCache = struct {
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    preparation_cache: preparation.BackendPreparationCache,
    loaded: ?*fragment.LoadedFragment = null,

    pub fn init(allocator: std.mem.Allocator, handle: gpu.BackendHandle) FragmentCompilerCache {
        return .{
            .allocator = allocator,
            .handle = handle,
            .preparation_cache = preparation.BackendPreparationCache.init(allocator),
        };
    }

    pub fn deinit(self: *FragmentCompilerCache) void {
        if (self.loaded) |loaded| loaded.deinit();
        self.preparation_cache.deinit();
        self.* = undefined;
    }

    pub fn currentPrepared(self: *const FragmentCompilerCache) ?*const Prepared {
        return self.preparation_cache.currentPrepared();
    }

    pub fn currentFragment(self: *const FragmentCompilerCache) ?*fragment.LoadedFragment {
        return self.loaded;
    }

    /// The call frees the draft, the caller's semantic module, whether the
    /// refresh succeeds or fails. A caller hands a new draft of the program to
    /// this call to recompile it. The caller owns `report`, which holds the
    /// receipts of the stages the refresh produced.
    pub fn refreshFromSemanticModule(
        self: *FragmentCompilerCache,
        module: *semantic.SemanticModule,
        options: fragment.FragmentCompilerOptions,
        request: FragmentCompilationRequest,
        report: *preparation.publication.PreparationReport,
        comptime configuration: choir.product.operation.Configuration,
    ) !FragmentCompilerCacheUpdate {
        return self.refresh(.{ .draft = module }, options, request, report, configuration);
    }

    pub fn refreshFromSemanticRevision(
        self: *FragmentCompilerCache,
        source: *const choir.product.revision.Revision,
        options: fragment.FragmentCompilerOptions,
        request: FragmentCompilationRequest,
        report: *preparation.publication.PreparationReport,
        comptime configuration: choir.product.operation.Configuration,
    ) !FragmentCompilerCacheUpdate {
        return self.refresh(.{ .retained = source }, options, request, report, configuration);
    }

    const Input = union(enum) {
        draft: *semantic.SemanticModule,
        retained: *const choir.product.revision.Revision,
    };

    fn refresh(
        self: *FragmentCompilerCache,
        input: Input,
        options: fragment.FragmentCompilerOptions,
        request: FragmentCompilationRequest,
        report: *preparation.publication.PreparationReport,
        comptime configuration: choir.product.operation.Configuration,
    ) !FragmentCompilerCacheUpdate {
        var draft_owned = input == .draft;
        defer if (draft_owned) input.draft.deinit();
        var plan: fragment.FragmentPreparationPlan = undefined;
        try plan.init(self.allocator, self.handle, options);
        defer plan.deinit();
        var staged = try self.preparation_cache.fork();
        var staged_owned = true;
        defer if (staged_owned) staged.deinit();
        const current = preparation.publication.PreparationRequest{
            .source = request.source,
            .variant = request.variant,
            .work = request.work,
            .record_bytes = request.record_bytes,
            .options = plan.run_options,
        };
        draft_owned = false;
        var update = switch (input) {
            .draft => |module| try staged.refreshFromSemanticModule(
                module,
                current,
                report,
                configuration,
            ),
            .retained => |source| try staged.refreshFromSemanticRevision(
                source,
                current,
                report,
                configuration,
            ),
        };
        errdefer update.deinit(self.allocator);
        try recordPreparation(options.instrumentation, report);
        const compiled = try fragment.compileFragmentFromPreparedModule(
            self.allocator,
            self.handle,
            update.prepared,
            options,
            request.artifact_workspace,
            configuration,
        );
        const loaded = try fragment.loadFragment(self.allocator, self.handle, compiled, options);
        self.preparation_cache.deinit();
        self.preparation_cache = staged;
        staged_owned = false;
        if (self.loaded) |previous| previous.deinit();
        self.loaded = loaded;
        return .{ .preparation = update, .fragment = loaded };
    }

    fn recordPreparation(
        instrumentation: fragment.FragmentInstrumentation,
        report: *const preparation.publication.PreparationReport,
    ) !void {
        const phases = [_]fragment.FragmentPhase{
            .run_contract_pipeline, .run_tensor_pipeline, .run_dispatch_pipeline,
            .run_memory_pipeline,   .run_kernel_pipeline, .run_target_pipeline,
        };
        for (phases, report.elapsed_ns[1..]) |phase, elapsed| {
            try instrumentation.recordElapsed(phase, elapsed);
        }
    }
};
