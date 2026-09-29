const std = @import("std");
const choir = @import("choir");
const semantic = @import("../choir/root.zig").semantic;
const publication = @import("publication.zig");
const product = @import("product.zig");
const incremental = choir.product.incremental;
const Prepared = product.BackendPreparedModule;

pub const BackendPreparationCacheUpdate = struct {
    /// A caller receives this from a refresh and owns the prepared result it names. `prepared`
    /// holds its own reference to the result, so a later refresh of the cache that replaces its
    /// result leaves this one valid. `reused` is true when every stage after the first was reused,
    /// `request_changed` is true when the final stage record, the sealed result of one compile
    /// stage, differs from the one held before, and `refresh` reports which stored products
    /// changed. `deinit` releases the prepared result and the refresh report.
    prepared: *Prepared,
    reused: bool,
    request_changed: bool,
    refresh: incremental.ProductRefreshReport,

    pub fn deinit(self: *BackendPreparationCacheUpdate, allocator: std.mem.Allocator) void {
        self.prepared.deinit();
        self.refresh.deinit(allocator);
        self.* = undefined;
    }
};

/// A caller keeps one of these per program to recompile it cheaply as its requests change. The
/// cache holds one earlier prepared result, its semantic source and the graph of stored products,
/// and offers that result as the candidate for the next refresh. The semantic source is the
/// immutable handle that keeps the first stage record, so no draft is needed. Reuse of any stage is
/// decided only by the exact admission check against that candidate's record. The refresh report
/// describes what changed and never causes or permits compiler work.
pub const BackendPreparationCache = struct {
    allocator: std.mem.Allocator,
    graph: incremental.ProductGraph = .{},
    prepared: ?*Prepared = null,
    source: ?*publication.SemanticSource = null,

    pub fn init(allocator: std.mem.Allocator) BackendPreparationCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BackendPreparationCache) void {
        if (self.prepared) |prepared| prepared.deinit();
        if (self.source) |source| source.deinit();
        self.graph.deinit(self.allocator);
        self.* = undefined;
    }

    /// A caller forks the cache to try a larger change against the current result without
    /// disturbing the original. The fork holds its own references to the same prepared result and
    /// source and its own copy of the product graph. A refresh or `deinit` on either cache leaves
    /// the other cache's state unchanged.
    pub fn fork(self: *const BackendPreparationCache) !BackendPreparationCache {
        var result = BackendPreparationCache.init(self.allocator);
        errdefer result.deinit();
        if (self.prepared) |prepared| result.prepared = try prepared.retain(self.allocator);
        if (self.source) |source| result.source = try source.retain(self.allocator);
        result.graph = try incremental.ProductGraph.initFromGraphs(
            self.allocator,
            &.{self.graph},
            &.{},
        );
        return result;
    }

    /// A caller reads the current prepared result to inspect or launch it. The call returns the
    /// result of the last successful refresh, or null before the first one. The pointer is borrowed
    /// and stays valid until the next successful refresh, and a caller that needs it longer retains
    /// it.
    pub fn currentPrepared(self: *const BackendPreparationCache) ?*const Prepared {
        return self.prepared;
    }

    /// A caller uses this to compile a new draft, the caller's mutable semantic module, of the
    /// program, reusing whatever stages of the current result still match. The call frees the draft
    /// in every case, on success and on failure. The caller owns `report` and the work receipts in
    /// it. The cache builds the whole replacement, graph, refresh report, retained result and
    /// source, before it changes any state it holds, so a failure leaves the cache as it was.
    pub fn refreshFromSemanticModule(
        self: *BackendPreparationCache,
        module: *semantic.SemanticModule,
        request: publication.PreparationRequest,
        report: *publication.PreparationReport,
        comptime configuration: choir.product.operation.Configuration,
    ) !BackendPreparationCacheUpdate {
        defer module.deinit();
        var current = request;
        current.candidate = self.prepared;
        const prepared = try publication.prepare(
            self.allocator,
            .{ .draft = module },
            current,
            report,
            configuration,
        );
        errdefer prepared.deinit();
        return self.replace(prepared, report);
    }

    /// A caller uses this to recompile after changing only the request, for example the device or
    /// schedule options, with no new draft. The call starts from the cache's own semantic source,
    /// so no draft is kept or needed. The call returns `error.MissingPreparedProduct` when the
    /// cache holds no source yet and `error.SemanticModuleRequired` when `semantic_revision`
    /// differs from that source. A change to the producer configuration or workspace can make the
    /// first stage fail its admission check, and then the call returns
    /// `error.SemanticModuleRequired` and the caller must refresh from a draft.
    pub fn refreshFromSemanticRevision(
        self: *BackendPreparationCache,
        semantic_revision: *const choir.product.revision.Revision,
        request: publication.PreparationRequest,
        report: *publication.PreparationReport,
        comptime configuration: choir.product.operation.Configuration,
    ) !BackendPreparationCacheUpdate {
        const source = self.source orelse return error.MissingPreparedProduct;
        if (!source.record().eql(semantic_revision)) return error.SemanticModuleRequired;
        var current = request;
        current.candidate = self.prepared;
        const prepared = try publication.prepare(
            self.allocator,
            .{ .retained = source },
            current,
            report,
            configuration,
        );
        errdefer prepared.deinit();
        return self.replace(prepared, report);
    }

    fn replace(
        self: *BackendPreparationCache,
        prepared: *Prepared,
        report: *const publication.PreparationReport,
    ) !BackendPreparationCacheUpdate {
        std.debug.assert(report.completed == 7);
        std.debug.assert(report.failure == null);
        std.debug.assert(report.source != null);
        var graph = try prepared.productGraph(self.allocator);
        errdefer graph.deinit(self.allocator);
        var live: [7]incremental.ProductRef = undefined;
        var count: usize = 0;
        for (report.stages[0..report.completed]) |*stage| {
            if (stage.* != .cold) continue;
            live[count] = stage.record().address();
            count += 1;
        }
        var refresh = try graph.collectRefreshReportWithMaterialization(
            self.allocator,
            self.graph,
            live[0..count],
            .live,
        );
        errdefer refresh.deinit(self.allocator);
        const retained = try prepared.retain(self.allocator);
        errdefer retained.deinit();
        const source = try report.source.?.retain(self.allocator);
        const changed = if (self.prepared) |previous|
            !previous.stage(.target).eql(prepared.stage(.target))
        else
            true;
        if (self.prepared) |previous| previous.deinit();
        if (self.source) |previous| previous.deinit();
        self.graph.deinit(self.allocator);
        self.prepared = prepared;
        self.source = source;
        self.graph = graph;
        var reused = true;
        for (report.stages[1..report.completed]) |stage| {
            if (stage == .cold) reused = false;
        }
        return .{
            .prepared = retained,
            .reused = reused,
            .request_changed = changed,
            .refresh = refresh,
        };
    }
};
