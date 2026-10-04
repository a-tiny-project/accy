const std = @import("std");
const choir = @import("choir");

const accy_choir = @import("../choir/root.zig");
const target_product = @import("../target/root.zig");
const run_mod = @import("run.zig");

const contract = accy_choir.contract;
const dispatch = accy_choir.dispatch;
const kernel_product = accy_choir.gpu;
const memory_product = accy_choir.memory;
const semantic = accy_choir.semantic;
const tensor = accy_choir.tensor;
const publication = accy_choir.publication;
const revision = choir.product.revision;

/// A caller holds this as the finished result of one compile, to read any stage or to launch the
/// final one: the result holds one sealed stage record for each of the seven stages, and each is
/// checked to belong to its stage and to depend on the stage before it. The result holds no mutable
/// compiler job, so nothing can change a stage after the result is made. `retain` returns another
/// owner of the same records, and `deinit` releases this owner's references.
pub const BackendPreparedModule = opaque {
    const Data = struct {
        allocator: std.mem.Allocator,
        records: [7]*const revision.Revision,
    };

    const stages = [_]publication.Stage{
        .semantic, .contract, .tensor, .dispatch, .memory, .kernel, .target,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        records: [7]*const revision.Revision,
    ) !*BackendPreparedModule {
        inline for (stages, 0..) |selected, index| {
            const item = records[index];
            if (!std.mem.eql(u8, item.address().stage, selected.name())) return error.WrongStage;
            try item.requireGates(&.{ choir.product.operation.schema_identity, selected.schema() });
            if (index != 0) try requirePredecessor(item, records[index - 1]);
        }
        const owned = try allocator.create(Data);
        errdefer allocator.destroy(owned);
        var retained: usize = 0;
        errdefer for (records[0..retained]) |item| item.release();
        for (records) |item| {
            _ = try item.retain();
            retained += 1;
        }
        owned.* = .{ .allocator = allocator, .records = records };
        return @ptrCast(owned);
    }

    fn requirePredecessor(
        item: *const revision.Revision,
        previous: *const revision.Revision,
    ) !void {
        item.requireDependency("source", previous) catch |err| switch (err) {
            error.UndeclaredProductInput => return error.UnboundProductInput,
        };
    }

    fn data(self: *const BackendPreparedModule) *const Data {
        return @ptrCast(@alignCast(self));
    }

    pub fn deinit(self: *BackendPreparedModule) void {
        const owned = self.data();
        for (owned.records) |item| item.release();
        owned.allocator.destroy(@constCast(owned));
    }

    pub fn retain(
        self: *const BackendPreparedModule,
        allocator: std.mem.Allocator,
    ) !*BackendPreparedModule {
        return create(allocator, self.data().records);
    }

    /// A caller reads one sealed stage record, for example the final one to emit device code: the
    /// call returns the record for `selected`. The record is borrowed from this result, and a
    /// caller that needs it after the result is released retains it.
    pub fn stage(
        self: *const BackendPreparedModule,
        comptime selected: publication.Stage,
    ) *const revision.Revision {
        return self.data().records[@backingInt(selected)];
    }

    pub fn productKeys(self: *const BackendPreparedModule) BackendPreparationProductKeys {
        return .{
            .semantic = choir.product.incremental.productKey(self.stage(.semantic).metadata()),
            .contract = choir.product.incremental.productKey(self.stage(.contract).metadata()),
            .tensor = choir.product.incremental.productKey(self.stage(.tensor).metadata()),
            .dispatch = choir.product.incremental.productKey(self.stage(.dispatch).metadata()),
            .memory = choir.product.incremental.productKey(self.stage(.memory).metadata()),
            .kernel = choir.product.incremental.productKey(self.stage(.kernel).metadata()),
            .target = choir.product.incremental.productKey(self.stage(.target).metadata()),
        };
    }

    pub fn productGraph(
        self: *const BackendPreparedModule,
        allocator: std.mem.Allocator,
    ) !choir.product.incremental.ProductGraph {
        return graphFromKeys(allocator, self.productKeys());
    }
};

pub const BackendPreparationProductStamps = struct {
    semantic: ?choir.product.incremental.ProductStamp = null,
    contract: choir.product.incremental.ProductStamp,
    tensor: choir.product.incremental.ProductStamp,
    dispatch: choir.product.incremental.ProductStamp,
    memory: choir.product.incremental.ProductStamp,
    kernel: choir.product.incremental.ProductStamp,
    target: choir.product.incremental.ProductStamp,
};

pub const BackendPreparationProductKeys = struct {
    semantic: ?choir.product.incremental.ProductKey = null,
    contract: choir.product.incremental.ProductKey,
    tensor: choir.product.incremental.ProductKey,
    dispatch: choir.product.incremental.ProductKey,
    memory: choir.product.incremental.ProductKey,
    kernel: choir.product.incremental.ProductKey,
    target: choir.product.incremental.ProductKey,
};

/// A caller turns one run's plan summaries into stamps to display beside the run: the function
/// builds one run stamp, the per-stage display record built for people reading a run, from the
/// summaries recorded in `run`, and leaves the first stage's stamp null when the run has no summary
/// for it. The stamps are for display, and no key or reuse decision reads them.
pub fn stampsFromRun(run: run_mod.BackendPreparationRun) BackendPreparationProductStamps {
    return .{
        .semantic = if (run.semantic_fingerprint) |fingerprint|
            choir.product.incremental.productStamp(semantic.product_name, fingerprint)
        else
            null,
        .contract = choir.product.incremental.productStamp(
            contract.product_name,
            run.contract_fingerprint,
        ),
        .tensor = choir.product.incremental.productStamp(
            tensor.product_name,
            run.tensor_fingerprint,
        ),
        .dispatch = choir.product.incremental.productStamp(
            dispatch.product_name,
            run.dispatch_fingerprint,
        ),
        .memory = choir.product.incremental.productStamp(
            memory_product.product_name,
            run.memory_fingerprint,
        ),
        .kernel = choir.product.incremental.productStamp(
            kernel_product.product_name,
            run.kernel_fingerprint,
        ),
        .target = choir.product.incremental.productStamp(
            target_product.product_name,
            run.target_fingerprint,
        ),
    };
}

pub fn graphFromKeys(
    allocator: std.mem.Allocator,
    keys: BackendPreparationProductKeys,
) !choir.product.incremental.ProductGraph {
    var products: [7]choir.product.incremental.ProductKey = undefined;
    var count: usize = 0;
    if (keys.semantic) |semantic_key| {
        products[count] = semantic_key;
        count += 1;
    }
    products[count] = keys.contract;
    count += 1;
    products[count] = keys.tensor;
    count += 1;
    products[count] = keys.dispatch;
    count += 1;
    products[count] = keys.memory;
    count += 1;
    products[count] = keys.kernel;
    count += 1;
    products[count] = keys.target;
    count += 1;
    return try choir.product.incremental.ProductGraph.initLinear(allocator, products[0..count]);
}
