const std = @import("std");
const alloc_phase = @import("alloc_phase");
const metadata_storage = @import("storage.zig");
const revision = @import("root.zig").revision;

fn fixtureStore() !*revision.Store {
    return revision.Store.create(std.testing.allocator, .{
        .revisions = 64,
        .kinds = 1,
        .builders = 1,
        .compiler_manifests = 2,
        .record_bytes = 64 * 1024,
        .gate_scratch_bytes = 0,
        .candidate_count = 1,
        .screening_bytes = 64 * 1024,
    });
}

fn fixtureRecord(
    owner: *revision.Store,
    stage: []const u8,
    image: []const u8,
    options: []const u8,
) !*const revision.Record {
    return fixtureRecordUnder(owner, stage, image, options, "graph-fixture-v1");
}

fn fixtureRecordUnder(
    owner: *revision.Store,
    stage: []const u8,
    image: []const u8,
    options: []const u8,
    manifest: []const u8,
) !*const revision.Record {
    const allocator = std.testing.allocator;
    const address = try revision.record.encodeAddress(allocator, .{
        .producer = "graph-fixture",
        .source = "module",
        .stage = stage,
        .variant = "default",
    });
    defer allocator.free(address);
    const inputs = try revision.record.encodeInputs(allocator, .{
        .compiler_manifest = manifest,
        .versions = &.{},
        .pipeline = &.{},
        .options = options,
        .policy = "",
    }, &.{}, "fixture-gates");
    defer allocator.free(inputs);
    const bytes = try revision.record.encodeExact(allocator, .{
        .address = address,
        .inputs = inputs,
        .image = image,
    });
    defer allocator.free(bytes);
    return owner.importRecord(bytes, manifest, .{ .bytes = 64 * 1024, .records = 1, .depth = 1 });
}

test "product graph rejects equal buckets for unequal exact records" {
    const owner = try fixtureStore();
    defer owner.release();
    const first = try fixtureRecord(owner, "source", "same-image", "threshold=1");
    defer first.release();
    const second = try fixtureRecord(owner, "source", "same-image", "threshold=2");
    defer second.release();
    try std.testing.expect(!first.eql(second));
    const left = productKey(first);
    const right = productKey(second);
    try std.testing.expectEqual(left.fingerprint(), right.fingerprint());
    try std.testing.expect(!left.eql(right));
    var previous = try ProductGraph.init(std.testing.allocator, &.{left}, &.{});
    defer previous.deinit(std.testing.allocator);
    var current = try ProductGraph.init(std.testing.allocator, &.{right}, &.{});
    defer current.deinit(std.testing.allocator);
    try std.testing.expect(current.refreshDecision(previous, right).shouldRefresh());
}

pub const ProductMetadataError = std.mem.Allocator.Error || error{ CapacityOverflow, ReferenceOverflow, InvalidProductAddress };

pub const Fingerprint = u64;

pub const FingerprintBuilder = struct {
    value: Fingerprint = fnv_offset,

    const fnv_offset: Fingerprint = 14_695_981_039_346_656_037;
    const fnv_prime: Fingerprint = 1_099_511_628_211;

    pub fn updateBytes(self: *FingerprintBuilder, bytes: []const u8) void {
        self.updateU64(bytes.len);
        for (bytes) |byte| {
            self.value ^= byte;
            self.value *%= fnv_prime;
        }
    }

    pub fn updateRawBytes(self: *FingerprintBuilder, bytes: []const u8) void {
        for (bytes) |byte| {
            self.value ^= byte;
            self.value *%= fnv_prime;
        }
    }

    pub fn updateBool(self: *FingerprintBuilder, value: bool) void {
        self.updateU64(@intFromBool(value));
    }

    pub fn updateU64(self: *FingerprintBuilder, value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        self.updateRawBytes(&bytes);
    }

    pub fn updateU32(self: *FingerprintBuilder, value: u32) void {
        self.updateU64(value);
    }

    pub fn updateI64(self: *FingerprintBuilder, value: i64) void {
        self.updateU64(@bitCast(value));
    }

    pub fn updateUsize(self: *FingerprintBuilder, value: usize) void {
        self.updateU64(@intCast(value));
    }

    pub fn updateU64Slice(self: *FingerprintBuilder, values: []const u64) void {
        self.updateUsize(values.len);
        for (values) |value| self.updateU64(value);
    }

    pub fn updateI64Slice(self: *FingerprintBuilder, values: []const i64) void {
        self.updateUsize(values.len);
        for (values) |value| self.updateI64(value);
    }

    pub fn updateUsizeSlice(self: *FingerprintBuilder, values: []const usize) void {
        self.updateUsize(values.len);
        for (values) |value| self.updateUsize(value);
    }

    pub fn updateOptionalU64(self: *FingerprintBuilder, value: ?u64) void {
        self.updateBool(value != null);
        if (value) |payload| self.updateU64(payload);
    }

    pub fn updateOptionalU32(self: *FingerprintBuilder, value: ?u32) void {
        self.updateBool(value != null);
        if (value) |payload| self.updateU32(payload);
    }

    pub fn updateOptionalU64Slice(self: *FingerprintBuilder, values: ?[]const u64) void {
        self.updateBool(values != null);
        if (values) |slice| self.updateU64Slice(slice);
    }

    pub fn updateEnumTag(self: *FingerprintBuilder, value: anytype) void {
        self.updateBytes(@tagName(value));
    }

    pub fn updateOptionalEnumTag(self: *FingerprintBuilder, value: anytype) void {
        self.updateBool(value != null);
        if (value) |payload| self.updateEnumTag(payload);
    }

    pub fn updateStamp(self: *FingerprintBuilder, stamp: ProductStamp) void {
        self.updateBytes(stamp.name);
        self.updateU64(stamp.fingerprint);
    }

    pub fn updateProductRef(self: *FingerprintBuilder, ref: ProductRef) void {
        inline for (@typeInfo(ProductRef).@"struct".field_names) |field| {
            self.updateBytes(@field(ref, field));
        }
    }

    pub fn updateProductKey(self: *FingerprintBuilder, key: ProductKey) void {
        self.updateProductRef(key.ref);
        self.updateBytes(key.record.bytes());
    }

    pub fn finish(self: FingerprintBuilder) Fingerprint {
        return self.value;
    }
};

pub const ProductStamp = struct {
    name: []const u8,
    fingerprint: Fingerprint,

    pub fn eql(self: ProductStamp, other: ProductStamp) bool {
        return std.mem.eql(u8, self.name, other.name) and self.fingerprint == other.fingerprint;
    }
};

pub const ProductRef = revision.record.Address;

/// Borrows an owner-interned exact record. Graphs and reports retain it.
/// Equality describes metadata; reuse still requires Builder.admitReuse.
pub const ProductKey = struct {
    ref: ProductRef,
    record: *const revision.Record,

    pub fn validate(self: ProductKey) error{InvalidProductAddress}!void {
        if (!self.ref.eql(self.record.address())) return error.InvalidProductAddress;
    }

    pub fn eql(self: ProductKey, other: ProductKey) bool {
        return self.ref.eql(other.ref) and self.record.eql(other.record);
    }

    pub fn fingerprint(self: ProductKey) Fingerprint {
        return self.record.bucket();
    }

    pub fn stamp(self: ProductKey) ProductStamp {
        return productStamp(self.ref.stage, self.fingerprint());
    }
};

pub const ProductDependency = struct {
    dependent: ProductRef,
    dependency: ProductRef,

    pub fn eql(self: ProductDependency, other: ProductDependency) bool {
        return self.dependent.eql(other.dependent) and self.dependency.eql(other.dependency);
    }
};

pub const ProductRefreshReason = enum {
    no_previous_product,
    revision_changed,
    dependency_changed,
};

pub const ProductMaterialization = enum {
    reusable,
    live,

    pub fn merge(self: ProductMaterialization, other: ProductMaterialization) ProductMaterialization {
        if (self == .live or other == .live) return .live;
        return .reusable;
    }
};

pub const ProductDependencyChange = struct {
    ref: ProductRef,
    previous_fingerprint: ?Fingerprint = null,
    current_fingerprint: ?Fingerprint = null,
};

pub const ProductRefreshDecision = struct {
    key: ProductKey,
    refresh: bool,
    reason: ?ProductRefreshReason = null,
    previous_fingerprint: ?Fingerprint = null,
    stale_dependency: ?ProductDependencyChange = null,
    materialization: ProductMaterialization = .reusable,

    pub fn isFresh(self: ProductRefreshDecision) bool {
        return !self.refresh;
    }

    pub fn shouldRefresh(self: ProductRefreshDecision) bool {
        return self.refresh;
    }

    pub fn isLive(self: ProductRefreshDecision) bool {
        return self.materialization == .live;
    }

    pub fn merge(self: ProductRefreshDecision, other: ProductRefreshDecision) ProductRefreshDecision {
        const materialization = self.materialization.merge(other.materialization);
        var result = if (!self.shouldRefresh() and other.shouldRefresh()) other else self;
        result.materialization = materialization;
        return result;
    }
};

const ProductRefSet = struct {
    refs: std.ArrayListUnmanaged(ProductRef) = .empty,

    pub fn deinit(self: *ProductRefSet, allocator: std.mem.Allocator) void {
        self.refs.deinit(allocator);
        self.* = .{};
    }

    pub fn contains(self: ProductRefSet, ref: ProductRef) bool {
        return productRefsContain(self.refs.items, ref);
    }

    pub fn append(self: *ProductRefSet, allocator: std.mem.Allocator, ref: ProductRef) std.mem.Allocator.Error!void {
        if (self.contains(ref)) return;
        try self.refs.append(allocator, ref);
    }

    pub fn appendSlice(
        self: *ProductRefSet,
        allocator: std.mem.Allocator,
        refs: []const ProductRef,
    ) std.mem.Allocator.Error!void {
        for (refs) |ref| try self.append(allocator, ref);
    }

    pub fn toOwnedSlice(self: *ProductRefSet, allocator: std.mem.Allocator) std.mem.Allocator.Error![]ProductRef {
        return try self.refs.toOwnedSlice(allocator);
    }
};

const ProductRefreshDecisionSet = struct {
    decisions: std.ArrayListUnmanaged(ProductRefreshDecision) = .empty,

    pub fn deinit(self: *ProductRefreshDecisionSet, allocator: std.mem.Allocator) void {
        self.decisions.deinit(allocator);
        self.* = .{};
    }

    pub fn contains(self: ProductRefreshDecisionSet, ref: ProductRef) bool {
        for (self.decisions.items) |decision| {
            if (decision.key.ref.eql(ref)) return true;
        }
        return false;
    }

    pub fn append(
        self: *ProductRefreshDecisionSet,
        allocator: std.mem.Allocator,
        decision: ProductRefreshDecision,
    ) std.mem.Allocator.Error!void {
        for (self.decisions.items) |*existing| {
            if (!existing.key.ref.eql(decision.key.ref)) continue;
            existing.* = existing.merge(decision);
            return;
        }
        try self.decisions.append(allocator, decision);
    }

    pub fn appendSlice(
        self: *ProductRefreshDecisionSet,
        allocator: std.mem.Allocator,
        decisions: []const ProductRefreshDecision,
    ) std.mem.Allocator.Error!void {
        for (decisions) |decision| try self.append(allocator, decision);
    }

    pub fn toOwnedSlice(
        self: *ProductRefreshDecisionSet,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]ProductRefreshDecision {
        return try self.decisions.toOwnedSlice(allocator);
    }
};

const NameWriter = struct {
    bytes: []u8,
    cursor: usize = 0,

    fn write(self: *NameWriter, source: []const u8) []const u8 {
        const end = std.math.add(usize, self.cursor, source.len) catch unreachable;
        std.debug.assert(end <= self.bytes.len);
        const destination = self.bytes[self.cursor..end];
        @memcpy(destination, source);
        self.cursor = end;
        return destination;
    }

    fn finish(self: NameWriter) void {
        std.debug.assert(self.cursor == self.bytes.len);
    }
};

const DecisionStorageRegions = struct {
    storage: metadata_storage.Storage,
    plan: []ProductRefreshDecision,
    closure: []ProductRef,
    refresh: []ProductRefreshDecision,
    names: []u8,

    fn init(
        allocator: std.mem.Allocator,
        decision_count: usize,
        refresh_count: usize,
        name_bytes: usize,
    ) ProductMetadataError!DecisionStorageRegions {
        std.debug.assert(decision_count > 0);
        std.debug.assert(refresh_count <= decision_count);
        var storage = try metadata_storage.Storage.init(allocator, .{ .segments = .{
            metadata_storage.segment(ProductRefreshDecision, decision_count),
            metadata_storage.segment(ProductRef, refresh_count),
            metadata_storage.segment(ProductRefreshDecision, refresh_count),
            metadata_storage.segment(u8, name_bytes),
        } });
        errdefer storage.deinit(allocator);
        return .{
            .plan = storage.region(ProductRefreshDecision, 0, decision_count),
            .closure = storage.region(ProductRef, 1, refresh_count),
            .refresh = storage.region(ProductRefreshDecision, 2, refresh_count),
            .names = storage.region(u8, 3, name_bytes),
            .storage = storage,
        };
    }
};

fn addNameBytes(total: *usize, name: []const u8) error{CapacityOverflow}!void {
    total.* = std.math.add(usize, total.*, name.len) catch return error.CapacityOverflow;
}

fn addRefBytes(total: *usize, ref: ProductRef) error{CapacityOverflow}!void {
    inline for (@typeInfo(ProductRef).@"struct".field_names) |field| {
        try addNameBytes(total, @field(ref, field));
    }
}

fn productRefreshDecisionNameBytes(decision: ProductRefreshDecision) error{CapacityOverflow}!usize {
    var total: usize = 0;
    try addRefBytes(&total, decision.key.ref);
    if (decision.stale_dependency) |dependency| try addRefBytes(&total, dependency.ref);
    return total;
}

fn productRefreshDecisionsNameBytes(decisions: []const ProductRefreshDecision) error{CapacityOverflow}!usize {
    var total: usize = 0;
    for (decisions) |decision| {
        total = std.math.add(
            usize,
            total,
            try productRefreshDecisionNameBytes(decision),
        ) catch return error.CapacityOverflow;
    }
    return total;
}

fn copyProductRef(writer: *NameWriter, source: ProductRef) ProductRef {
    var copy: ProductRef = undefined;
    inline for (@typeInfo(ProductRef).@"struct".field_names) |field| {
        @field(copy, field) = writer.write(@field(source, field));
    }
    return copy;
}

fn copyProductKey(writer: *NameWriter, source: ProductKey) ProductMetadataError!ProductKey {
    try source.validate();
    return .{ .ref = copyProductRef(writer, source.ref), .record = try source.record.retain() };
}

fn copyProductDependency(writer: *NameWriter, source: ProductDependency) ProductDependency {
    return .{
        .dependent = copyProductRef(writer, source.dependent),
        .dependency = copyProductRef(writer, source.dependency),
    };
}

fn copyProductRefreshDecision(
    writer: *NameWriter,
    source: ProductRefreshDecision,
) ProductMetadataError!ProductRefreshDecision {
    var destination = source;
    destination.key = try copyProductKey(writer, source.key);
    if (source.stale_dependency) |dependency| {
        var owned_dependency = dependency;
        owned_dependency.ref = copyProductRef(writer, dependency.ref);
        destination.stale_dependency = owned_dependency;
    }
    return destination;
}

fn productRefreshDecisionWithMaterialization(
    source: ProductRefreshDecision,
    refs: []const ProductRef,
    materialization: ProductMaterialization,
) ProductRefreshDecision {
    var destination = source;
    if (productRefsContain(refs, source.key.ref)) {
        destination.materialization = destination.materialization.merge(materialization);
    }
    return destination;
}

pub const ProductRefreshPlan = struct {
    decisions: []ProductRefreshDecision = &.{},
    storage: ?metadata_storage.Storage = null,

    pub fn init(
        allocator: std.mem.Allocator,
        decisions: []const ProductRefreshDecision,
    ) ProductMetadataError!ProductRefreshPlan {
        if (decisions.len == 0) return .{};
        const name_bytes = try productRefreshDecisionsNameBytes(decisions);
        var regions = try DecisionStorageRegions.init(allocator, decisions.len, 0, name_bytes);
        errdefer regions.storage.deinit(allocator);

        var writer = NameWriter{ .bytes = regions.names };
        var copied: usize = 0;
        errdefer for (regions.plan[0..copied]) |item| item.key.record.release();
        for (decisions, regions.plan) |source, *destination| {
            destination.* = try copyProductRefreshDecision(&writer, source);
            copied += 1;
        }
        writer.finish();
        regions.storage.activate();
        return .{
            .decisions = regions.plan,
            .storage = regions.storage,
        };
    }

    pub fn deinit(self: *ProductRefreshPlan, allocator: std.mem.Allocator) void {
        for (self.decisions) |item| item.key.record.release();
        if (self.storage) |*storage| {
            storage.deinit(allocator);
        } else {
            std.debug.assert(self.decisions.len == 0);
        }
        self.* = .{};
    }

    pub fn productCount(self: ProductRefreshPlan) usize {
        return self.decisions.len;
    }

    pub fn refreshCount(self: ProductRefreshPlan) usize {
        var count: usize = 0;
        for (self.decisions) |decision| {
            if (decision.shouldRefresh()) {
                count = std.math.add(usize, count, 1) catch unreachable;
            }
        }
        return count;
    }

    pub fn freshCount(self: ProductRefreshPlan) usize {
        return std.math.sub(usize, self.productCount(), self.refreshCount()) catch unreachable;
    }

    pub fn materializationCount(self: ProductRefreshPlan, materialization: ProductMaterialization) usize {
        var count: usize = 0;
        for (self.decisions) |decision| {
            if (decision.materialization == materialization) {
                count = std.math.add(usize, count, 1) catch unreachable;
            }
        }
        return count;
    }

    pub fn liveCount(self: ProductRefreshPlan) usize {
        return self.materializationCount(.live);
    }

    pub fn decisionFor(self: ProductRefreshPlan, ref: ProductRef) ?ProductRefreshDecision {
        for (self.decisions) |decision| {
            if (decision.key.ref.eql(ref)) return decision;
        }
        return null;
    }

    pub fn markMaterialization(
        self: *ProductRefreshPlan,
        ref: ProductRef,
        materialization: ProductMaterialization,
    ) bool {
        for (self.decisions) |*decision| {
            if (!decision.key.ref.eql(ref)) continue;
            decision.materialization = decision.materialization.merge(materialization);
            return true;
        }
        return false;
    }

    pub fn markMaterializations(
        self: *ProductRefreshPlan,
        refs: []const ProductRef,
        materialization: ProductMaterialization,
    ) bool {
        for (refs) |ref| {
            if (self.decisionFor(ref) == null) return false;
        }
        for (refs) |ref| {
            std.debug.assert(self.markMaterialization(ref, materialization));
        }
        return true;
    }

    pub fn markRefreshMaterialization(
        self: *ProductRefreshPlan,
        materialization: ProductMaterialization,
    ) void {
        for (self.decisions) |*decision| {
            if (!decision.shouldRefresh()) continue;
            decision.materialization = decision.materialization.merge(materialization);
        }
    }

    pub fn shouldRefresh(self: ProductRefreshPlan, ref: ProductRef) bool {
        const decision = self.decisionFor(ref) orelse return false;
        return decision.shouldRefresh();
    }

    pub fn productsAreFresh(self: ProductRefreshPlan, refs: []const ProductRef) bool {
        for (refs) |ref| {
            const decision = self.decisionFor(ref) orelse return false;
            if (!decision.isFresh()) return false;
        }
        return true;
    }
};

pub const ProductRefreshReport = struct {
    all_decisions: []const ProductRefreshDecision = &.{},
    closure: []const ProductRef = &.{},
    decisions: []const ProductRefreshDecision = &.{},
    storage: ?metadata_storage.Storage = null,

    fn initFromDecisions(
        allocator: std.mem.Allocator,
        decisions: []const ProductRefreshDecision,
    ) ProductMetadataError!ProductRefreshReport {
        if (decisions.len == 0) return .{};
        var refresh_count: usize = 0;
        for (decisions) |decision| {
            if (decision.shouldRefresh()) {
                refresh_count = std.math.add(usize, refresh_count, 1) catch unreachable;
            }
        }
        const name_bytes = try productRefreshDecisionsNameBytes(decisions);
        var regions = try DecisionStorageRegions.init(
            allocator,
            decisions.len,
            refresh_count,
            name_bytes,
        );
        errdefer regions.storage.deinit(allocator);

        var writer = NameWriter{ .bytes = regions.names };
        var copied: usize = 0;
        errdefer for (regions.plan[0..copied]) |item| item.key.record.release();
        for (decisions, regions.plan) |source, *destination| {
            destination.* = try copyProductRefreshDecision(&writer, source);
            copied += 1;
        }
        writer.finish();

        var refresh_index: usize = 0;
        for (regions.plan) |decision| {
            if (!decision.shouldRefresh()) continue;
            std.debug.assert(refresh_index < refresh_count);
            regions.closure[refresh_index] = decision.key.ref;
            regions.refresh[refresh_index] = decision;
            refresh_index = std.math.add(usize, refresh_index, 1) catch unreachable;
        }
        std.debug.assert(refresh_index == refresh_count);
        regions.storage.activate();
        return .{
            .all_decisions = regions.plan,
            .closure = regions.closure,
            .decisions = regions.refresh,
            .storage = regions.storage,
        };
    }

    fn initFromGraphDecisions(
        allocator: std.mem.Allocator,
        current: ProductGraph,
        previous: ProductGraph,
        materialization_refs: []const ProductRef,
        materialization: ProductMaterialization,
    ) ProductMetadataError!ProductRefreshReport {
        if (current.products.len == 0) return .{};

        var refresh_count: usize = 0;
        var name_bytes: usize = 0;
        for (current.products) |product| {
            const decision = productRefreshDecisionWithMaterialization(
                current.refreshDecision(previous, product),
                materialization_refs,
                materialization,
            );
            if (decision.shouldRefresh()) {
                refresh_count = std.math.add(usize, refresh_count, 1) catch unreachable;
            }
            name_bytes = std.math.add(
                usize,
                name_bytes,
                try productRefreshDecisionNameBytes(decision),
            ) catch return error.CapacityOverflow;
        }

        var regions = try DecisionStorageRegions.init(
            allocator,
            current.products.len,
            refresh_count,
            name_bytes,
        );
        errdefer regions.storage.deinit(allocator);
        var writer = NameWriter{ .bytes = regions.names };
        var copied: usize = 0;
        errdefer for (regions.plan[0..copied]) |item| item.key.record.release();
        for (current.products, regions.plan) |product, *destination| {
            destination.* = try copyProductRefreshDecision(
                &writer,
                productRefreshDecisionWithMaterialization(
                    current.refreshDecision(previous, product),
                    materialization_refs,
                    materialization,
                ),
            );
            copied += 1;
        }
        writer.finish();

        var refresh_index: usize = 0;
        for (regions.plan) |decision| {
            if (!decision.shouldRefresh()) continue;
            std.debug.assert(refresh_index < refresh_count);
            regions.closure[refresh_index] = decision.key.ref;
            regions.refresh[refresh_index] = decision;
            refresh_index = std.math.add(usize, refresh_index, 1) catch unreachable;
        }
        std.debug.assert(refresh_index == refresh_count);
        regions.storage.activate();
        return .{
            .all_decisions = regions.plan,
            .closure = regions.closure,
            .decisions = regions.refresh,
            .storage = regions.storage,
        };
    }

    pub fn initFromPlan(
        allocator: std.mem.Allocator,
        plan: ProductRefreshPlan,
    ) ProductMetadataError!ProductRefreshReport {
        var owned_plan = plan;
        defer owned_plan.deinit(allocator);
        return try initFromDecisions(allocator, owned_plan.decisions);
    }

    pub fn initFromGraph(
        allocator: std.mem.Allocator,
        current: ProductGraph,
        previous: ProductGraph,
    ) ProductMetadataError!ProductRefreshReport {
        return try initFromGraphDecisions(allocator, current, previous, &.{}, .reusable);
    }

    pub fn initFromReports(
        allocator: std.mem.Allocator,
        reports: []const *const ProductRefreshReport,
    ) ProductMetadataError!ProductRefreshReport {
        var closure = ProductRefreshDecisionSet{};
        defer closure.deinit(allocator);

        var decision_capacity: usize = 0;
        for (reports) |report| {
            decision_capacity = std.math.add(
                usize,
                decision_capacity,
                report.all_decisions.len,
            ) catch return error.CapacityOverflow;
        }
        try closure.decisions.ensureTotalCapacityPrecise(allocator, decision_capacity);

        for (reports) |report| {
            try closure.appendSlice(allocator, report.all_decisions);
        }

        return try initFromDecisions(allocator, closure.decisions.items);
    }

    pub fn refreshes(self: ProductRefreshReport, ref: ProductRef) bool {
        return productRefsContain(self.closure, ref);
    }

    pub fn refreshDecisionFor(self: ProductRefreshReport, ref: ProductRef) ?ProductRefreshDecision {
        for (self.decisions) |decision| {
            if (decision.key.ref.eql(ref)) return decision;
        }
        return null;
    }

    pub fn decisionFor(self: ProductRefreshReport, ref: ProductRef) ?ProductRefreshDecision {
        for (self.all_decisions) |decision| {
            if (decision.key.ref.eql(ref)) return decision;
        }
        return null;
    }

    pub fn productsAreFresh(self: ProductRefreshReport, refs: []const ProductRef) bool {
        for (refs) |ref| {
            const decision = self.decisionFor(ref) orelse return false;
            if (!decision.isFresh()) return false;
        }
        return true;
    }

    pub fn productCount(self: ProductRefreshReport) usize {
        return self.all_decisions.len;
    }

    pub fn refreshCount(self: ProductRefreshReport) usize {
        std.debug.assert(self.closure.len == self.decisions.len);
        var expected: usize = 0;
        for (self.all_decisions) |decision| {
            if (decision.shouldRefresh()) {
                expected = std.math.add(usize, expected, 1) catch unreachable;
            }
        }
        std.debug.assert(expected == self.decisions.len);
        return self.decisions.len;
    }

    pub fn freshCount(self: ProductRefreshReport) usize {
        return std.math.sub(usize, self.productCount(), self.refreshCount()) catch unreachable;
    }

    pub fn liveCount(self: ProductRefreshReport) usize {
        var count: usize = 0;
        for (self.all_decisions) |decision| {
            if (decision.materialization == .live) {
                count = std.math.add(usize, count, 1) catch unreachable;
            }
        }
        return count;
    }

    pub fn hasRefreshes(self: ProductRefreshReport) bool {
        return self.refreshCount() != 0;
    }

    pub fn refreshReasonsAre(self: ProductRefreshReport, reason: ProductRefreshReason) bool {
        for (self.decisions) |decision| {
            if (decision.reason == null or decision.reason.? != reason) return false;
        }
        return true;
    }

    pub fn refreshesAreLive(self: ProductRefreshReport) bool {
        for (self.decisions) |decision| {
            if (!decision.isLive()) return false;
        }
        return true;
    }

    pub fn deinit(self: *ProductRefreshReport, allocator: std.mem.Allocator) void {
        for (self.all_decisions) |item| item.key.record.release();
        if (self.storage) |*storage| {
            storage.deinit(allocator);
        } else {
            std.debug.assert(self.all_decisions.len == 0);
            std.debug.assert(self.closure.len == 0);
            std.debug.assert(self.decisions.len == 0);
        }
        self.* = .{};
    }
};

pub const ProductGraphBuilderError = ProductMetadataError || error{
    ConflictingProductKey,
};

const ProductDependencySliceSource = struct {
    dependencies: []const ProductDependency,

    fn get(self: ProductDependencySliceSource, index: usize) ProductDependency {
        std.debug.assert(index < self.dependencies.len);
        return self.dependencies[index];
    }
};

const LinearProductDependencySource = struct {
    products: []const ProductKey,

    fn get(self: LinearProductDependencySource, index: usize) ProductDependency {
        const dependency_count = if (self.products.len > 1)
            std.math.sub(usize, self.products.len, 1) catch unreachable
        else
            0;
        std.debug.assert(index < dependency_count);
        const dependent_index = std.math.add(usize, index, 1) catch unreachable;
        return productDependency(self.products[dependent_index], self.products[index]);
    }
};

pub const ProductGraph = struct {
    products: []const ProductKey = &.{},
    dependencies: []const ProductDependency = &.{},
    storage: ?metadata_storage.Storage = null,

    pub fn init(
        allocator: std.mem.Allocator,
        products: []const ProductKey,
        dependencies: []const ProductDependency,
    ) ProductMetadataError!ProductGraph {
        return try initFromDependencySource(
            allocator,
            products,
            dependencies.len,
            ProductDependencySliceSource{ .dependencies = dependencies },
        );
    }

    fn initFromDependencySource(
        allocator: std.mem.Allocator,
        products: []const ProductKey,
        dependency_count: usize,
        dependency_source: anytype,
    ) ProductMetadataError!ProductGraph {
        if (products.len == 0 and dependency_count == 0) return .{};

        var name_bytes: usize = 0;
        for (products) |product| try addRefBytes(&name_bytes, product.ref);
        for (0..dependency_count) |index| {
            const dependency = dependency_source.get(index);
            try addRefBytes(&name_bytes, dependency.dependent);
            try addRefBytes(&name_bytes, dependency.dependency);
        }

        var storage = try metadata_storage.Storage.init(allocator, .{ .segments = .{
            metadata_storage.segment(ProductKey, products.len),
            metadata_storage.segment(ProductDependency, dependency_count),
            metadata_storage.segment(u8, 0),
            metadata_storage.segment(u8, name_bytes),
        } });
        errdefer storage.deinit(allocator);
        const owned_products = storage.region(ProductKey, 0, products.len);
        const owned_dependencies = storage.region(ProductDependency, 1, dependency_count);
        const names = storage.region(u8, 3, name_bytes);

        var writer = NameWriter{ .bytes = names };
        var copied: usize = 0;
        errdefer for (owned_products[0..copied]) |item| item.record.release();
        for (products, owned_products) |source, *destination| {
            destination.* = try copyProductKey(&writer, source);
            copied += 1;
        }
        for (owned_dependencies, 0..) |*destination, index| {
            destination.* = copyProductDependency(&writer, dependency_source.get(index));
        }
        writer.finish();
        storage.activate();

        return .{
            .products = owned_products,
            .dependencies = owned_dependencies,
            .storage = storage,
        };
    }

    pub fn initFromGraphs(
        allocator: std.mem.Allocator,
        graphs: []const ProductGraph,
        dependencies: []const ProductDependency,
    ) ProductGraphBuilderError!ProductGraph {
        var builder = ProductGraphBuilder{};
        defer builder.deinit(allocator);

        for (graphs) |graph_value| try builder.appendGraph(allocator, graph_value);
        for (dependencies) |dependency| try builder.recordDependency(allocator, dependency);

        return try builder.graph(allocator);
    }

    pub fn initLinear(
        allocator: std.mem.Allocator,
        products: []const ProductKey,
    ) ProductMetadataError!ProductGraph {
        const dependency_count = if (products.len > 1)
            std.math.sub(usize, products.len, 1) catch unreachable
        else
            0;
        return try initFromDependencySource(
            allocator,
            products,
            dependency_count,
            LinearProductDependencySource{ .products = products },
        );
    }

    pub fn deinit(self: *ProductGraph, allocator: std.mem.Allocator) void {
        for (self.products) |item| item.record.release();
        if (self.storage) |*storage| {
            storage.deinit(allocator);
        } else {
            std.debug.assert(self.products.len == 0);
            std.debug.assert(self.dependencies.len == 0);
        }
        self.* = .{};
    }

    pub fn containsFresh(self: ProductGraph, key: ProductKey) bool {
        for (self.products) |product| {
            if (product.eql(key)) return true;
        }
        return false;
    }

    pub fn productKeyFor(self: ProductGraph, ref: ProductRef) ?ProductKey {
        for (self.products) |product| {
            if (product.ref.eql(ref)) return product;
        }
        return null;
    }

    pub fn fingerprintFor(self: ProductGraph, ref: ProductRef) ?Fingerprint {
        const product = self.productKeyFor(ref) orelse return null;
        return product.fingerprint();
    }

    pub fn dependsOn(self: ProductGraph, dependent: ProductRef, dependency_ref: ProductRef) bool {
        for (self.dependencies) |dependency| {
            if (dependency.dependent.eql(dependent) and dependency.dependency.eql(dependency_ref)) {
                return true;
            }
        }
        return false;
    }

    pub fn dependencyCountFor(self: ProductGraph, dependent: ProductRef) usize {
        var count: usize = 0;
        for (self.dependencies) |dependency| {
            if (dependency.dependent.eql(dependent)) {
                count = std.math.add(usize, count, 1) catch unreachable;
            }
        }
        return count;
    }

    pub fn refreshDecision(
        self: ProductGraph,
        previous: ProductGraph,
        key: ProductKey,
    ) ProductRefreshDecision {
        const previous_key = previous.productKeyFor(key.ref) orelse {
            return .{
                .key = key,
                .refresh = true,
                .reason = .no_previous_product,
            };
        };

        const previous_fingerprint = previous_key.fingerprint();
        if (!previous_key.eql(key)) {
            return .{
                .key = key,
                .refresh = true,
                .reason = .revision_changed,
                .previous_fingerprint = previous_fingerprint,
            };
        }

        if (self.firstStalePreviousDependency(previous, key.ref)) |dependency| {
            return .{
                .key = key,
                .refresh = true,
                .reason = .dependency_changed,
                .previous_fingerprint = previous_fingerprint,
                .stale_dependency = dependency,
            };
        }

        return .{
            .key = key,
            .refresh = false,
            .previous_fingerprint = previous_fingerprint,
        };
    }

    pub fn firstStalePreviousDependency(
        self: ProductGraph,
        previous: ProductGraph,
        dependent: ProductRef,
    ) ?ProductDependencyChange {
        for (previous.dependencies) |dependency| {
            if (!dependency.dependent.eql(dependent)) continue;
            const before = previous.productKeyFor(dependency.dependency);
            const after = self.productKeyFor(dependency.dependency);
            if (!self.dependsOn(dependent, dependency.dependency) or
                before == null or after == null or !before.?.eql(after.?))
            {
                return dependencyChange(dependency.dependency, before, after);
            }
        }
        for (self.dependencies) |dependency| {
            if (!dependency.dependent.eql(dependent)) continue;
            if (!previous.dependsOn(dependent, dependency.dependency)) {
                return dependencyChange(
                    dependency.dependency,
                    previous.productKeyFor(dependency.dependency),
                    self.productKeyFor(dependency.dependency),
                );
            }
        }
        return null;
    }

    pub fn collectInvalidationClosure(
        self: ProductGraph,
        allocator: std.mem.Allocator,
        changed: ProductRef,
    ) std.mem.Allocator.Error![]ProductRef {
        var invalidated = ProductRefSet{};
        errdefer invalidated.deinit(allocator);

        try invalidated.append(allocator, changed);
        var cursor: usize = 0;
        while (cursor < invalidated.refs.items.len) : (cursor = std.math.add(usize, cursor, 1) catch unreachable) {
            const current = invalidated.refs.items[cursor];
            for (self.dependencies) |dependency| {
                if (!dependency.dependency.eql(current)) continue;
                try invalidated.append(allocator, dependency.dependent);
            }
        }

        return try invalidated.toOwnedSlice(allocator);
    }

    pub fn collectRefreshReport(
        self: ProductGraph,
        allocator: std.mem.Allocator,
        previous: ProductGraph,
    ) ProductMetadataError!ProductRefreshReport {
        return try ProductRefreshReport.initFromGraph(allocator, self, previous);
    }

    pub fn collectRetainedRefreshReport(
        self: ProductGraph,
        allocator: std.mem.Allocator,
    ) ProductMetadataError!ProductRefreshReport {
        return try self.collectRefreshReport(allocator, self);
    }

    pub fn collectRefreshReportWithMaterialization(
        self: ProductGraph,
        allocator: std.mem.Allocator,
        previous: ProductGraph,
        refs: []const ProductRef,
        materialization: ProductMaterialization,
    ) (ProductMetadataError || error{MissingMaterializationProduct})!ProductRefreshReport {
        for (refs) |ref| {
            if (self.productKeyFor(ref) == null) return error.MissingMaterializationProduct;
        }
        return try ProductRefreshReport.initFromGraphDecisions(
            allocator,
            self,
            previous,
            refs,
            materialization,
        );
    }

    pub fn collectRetainedRefreshReportWithMaterialization(
        self: ProductGraph,
        allocator: std.mem.Allocator,
        refs: []const ProductRef,
        materialization: ProductMaterialization,
    ) (ProductMetadataError || error{MissingMaterializationProduct})!ProductRefreshReport {
        return try self.collectRefreshReportWithMaterialization(
            allocator,
            self,
            refs,
            materialization,
        );
    }

    pub fn collectRefreshPlan(
        self: ProductGraph,
        allocator: std.mem.Allocator,
        previous: ProductGraph,
    ) ProductMetadataError!ProductRefreshPlan {
        if (self.products.len == 0) return .{};
        var name_bytes: usize = 0;
        for (self.products) |product| {
            const decision = self.refreshDecision(previous, product);
            name_bytes = std.math.add(
                usize,
                name_bytes,
                try productRefreshDecisionNameBytes(decision),
            ) catch return error.CapacityOverflow;
        }

        var regions = try DecisionStorageRegions.init(allocator, self.products.len, 0, name_bytes);
        errdefer regions.storage.deinit(allocator);
        var writer = NameWriter{ .bytes = regions.names };
        var copied: usize = 0;
        errdefer for (regions.plan[0..copied]) |item| item.key.record.release();
        for (self.products, regions.plan) |product, *decision| {
            decision.* = try copyProductRefreshDecision(
                &writer,
                self.refreshDecision(previous, product),
            );
            copied += 1;
        }
        writer.finish();
        regions.storage.activate();
        return .{
            .decisions = regions.plan,
            .storage = regions.storage,
        };
    }
};

pub const ProductGraphBuilder = struct {
    products: std.ArrayListUnmanaged(ProductKey) = .empty,
    dependencies: std.ArrayListUnmanaged(ProductDependency) = .empty,

    pub fn deinit(self: *ProductGraphBuilder, allocator: std.mem.Allocator) void {
        self.products.deinit(allocator);
        self.dependencies.deinit(allocator);
        self.* = .{};
    }

    pub fn recordProduct(
        self: *ProductGraphBuilder,
        allocator: std.mem.Allocator,
        key: ProductKey,
    ) ProductGraphBuilderError!void {
        try key.validate();
        for (self.products.items) |product| {
            if (!product.ref.eql(key.ref)) continue;
            if (!product.eql(key)) return error.ConflictingProductKey;
            return;
        }
        try self.products.append(allocator, key);
    }

    pub fn recordDependency(
        self: *ProductGraphBuilder,
        allocator: std.mem.Allocator,
        dependency: ProductDependency,
    ) std.mem.Allocator.Error!void {
        for (self.dependencies.items) |candidate| {
            if (candidate.eql(dependency)) return;
        }
        try self.dependencies.append(allocator, dependency);
    }

    pub fn appendGraph(
        self: *ProductGraphBuilder,
        allocator: std.mem.Allocator,
        source_graph: ProductGraph,
    ) ProductGraphBuilderError!void {
        for (source_graph.products) |product| try self.recordProduct(allocator, product);
        for (source_graph.dependencies) |dependency| try self.recordDependency(allocator, dependency);
    }

    pub fn graph(
        self: ProductGraphBuilder,
        allocator: std.mem.Allocator,
    ) ProductMetadataError!ProductGraph {
        return try ProductGraph.init(allocator, self.products.items, self.dependencies.items);
    }
};

pub fn fingerprintBytes(bytes: []const u8) Fingerprint {
    var builder = FingerprintBuilder{};
    builder.updateBytes(bytes);
    return builder.finish();
}

pub fn productStamp(name: []const u8, fingerprint: Fingerprint) ProductStamp {
    return .{
        .name = name,
        .fingerprint = fingerprint,
    };
}

pub fn productRef(
    producer: []const u8,
    source: []const u8,
    stage: []const u8,
    variant: []const u8,
) ProductRef {
    return .{ .producer = producer, .source = source, .stage = stage, .variant = variant };
}

pub fn cloneProductRef(allocator: std.mem.Allocator, ref: ProductRef) std.mem.Allocator.Error!ProductRef {
    const fields = @typeInfo(ProductRef).@"struct".field_names;
    var result: ProductRef = undefined;
    var count: usize = 0;
    errdefer inline for (fields, 0..) |field, index| {
        if (index < count) allocator.free(@field(result, field));
    };
    inline for (fields) |field| {
        @field(result, field) = try allocator.dupe(u8, @field(ref, field));
        count += 1;
    }
    return result;
}

pub fn deinitProductRef(allocator: std.mem.Allocator, ref: ProductRef) void {
    inline for (@typeInfo(ProductRef).@"struct".field_names) |field| {
        allocator.free(@field(ref, field));
    }
}

pub fn productKey(exact: *const revision.Record) ProductKey {
    return .{ .ref = exact.address(), .record = exact };
}

pub fn cloneProductKey(_: std.mem.Allocator, key: ProductKey) ProductMetadataError!ProductKey {
    try key.validate();
    return productKey(try key.record.retain());
}

pub fn deinitProductKey(_: std.mem.Allocator, key: ProductKey) void {
    key.record.release();
}

fn dependencyChange(
    ref: ProductRef,
    before: ?ProductKey,
    after: ?ProductKey,
) ProductDependencyChange {
    return .{
        .ref = ref,
        .previous_fingerprint = if (before) |key| key.fingerprint() else null,
        .current_fingerprint = if (after) |key| key.fingerprint() else null,
    };
}

pub fn derivedProductStamp(
    name: []const u8,
    dependencies: []const ProductStamp,
    local_fingerprint: Fingerprint,
) ProductStamp {
    var builder = FingerprintBuilder{};
    builder.updateBytes(name);
    builder.updateU64(local_fingerprint);
    builder.updateUsize(dependencies.len);
    for (dependencies) |dependency| builder.updateStamp(dependency);
    return productStamp(name, builder.finish());
}

pub fn productDependency(
    dependent: ProductKey,
    dependency: ProductKey,
) ProductDependency {
    return .{
        .dependent = dependent.ref,
        .dependency = dependency.ref,
    };
}

pub fn productRefsContain(refs: []const ProductRef, ref: ProductRef) bool {
    for (refs) |candidate| {
        if (candidate.eql(ref)) return true;
    }
    return false;
}

test "fingerprint builder is deterministic and length delimited" {
    var left = FingerprintBuilder{};
    left.updateBytes("ab");
    left.updateBytes("c");

    var right = FingerprintBuilder{};
    right.updateBytes("a");
    right.updateBytes("bc");

    try std.testing.expectEqual(left.finish(), left.finish());
    try std.testing.expect(left.finish() != right.finish());
}

test "fingerprint builder delimits numeric slices and optionals" {
    var left = FingerprintBuilder{};
    left.updateU64Slice(&.{ 1, 23 });

    var right = FingerprintBuilder{};
    right.updateU64Slice(&.{ 12, 3 });

    var empty = FingerprintBuilder{};
    empty.updateOptionalU64Slice(&.{});

    var missing = FingerprintBuilder{};
    missing.updateOptionalU64Slice(null);

    var negative = FingerprintBuilder{};
    negative.updateI64(-1);

    var positive = FingerprintBuilder{};
    positive.updateI64(1);

    try std.testing.expect(left.finish() != right.finish());
    try std.testing.expect(empty.finish() != missing.finish());
    try std.testing.expect(negative.finish() != positive.finish());
}

test "fingerprint builder delimits optional u32 and enum tags" {
    const Mode = enum { alpha, beta };

    var present_u32 = FingerprintBuilder{};
    present_u32.updateOptionalU32(7);

    var missing_u32 = FingerprintBuilder{};
    missing_u32.updateOptionalU32(null);

    var alpha = FingerprintBuilder{};
    alpha.updateOptionalEnumTag(@as(?Mode, .alpha));

    var beta = FingerprintBuilder{};
    beta.updateOptionalEnumTag(@as(?Mode, .beta));

    var missing_enum = FingerprintBuilder{};
    missing_enum.updateOptionalEnumTag(@as(?Mode, null));

    try std.testing.expect(present_u32.finish() != missing_u32.finish());
    try std.testing.expect(alpha.finish() != beta.finish());
    try std.testing.expect(alpha.finish() != missing_enum.finish());
}

test "product stamps include product name and dependencies" {
    const source = productStamp("source", fingerprintBytes("module"));
    const same = derivedProductStamp("target", &.{source}, 1);
    const same_again = derivedProductStamp("target", &.{source}, 1);
    const different_name = derivedProductStamp("artifact", &.{source}, 1);
    const different_local = derivedProductStamp("target", &.{source}, 2);

    try std.testing.expect(same.eql(same_again));
    try std.testing.expect(!same.eql(different_name));
    try std.testing.expect(!same.eql(different_local));
}

const Fixture = struct {
    owner: *revision.Store,

    fn init() !Fixture {
        return .{ .owner = try fixtureStore() };
    }

    fn deinit(self: Fixture) void {
        self.owner.release();
    }

    fn key(self: Fixture, stage: []const u8, image: []const u8) !ProductKey {
        const exact = try fixtureRecord(self.owner, stage, image, "");
        exact.release();
        return productKey(exact);
    }
};

test "exact product graphs retain records and full addresses across store destruction" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(metadata_storage.Storage, "choir_product_graph_lifetime_transitive_risk"),
        );
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(metadata_storage.Storage, "choir_product_graph_lifetime_foreign_risk"),
        );
    }
    const allocator = std.testing.allocator;
    const fixture = try Fixture.init();
    const source = try fixture.key("source", "source-v1");
    const target = try fixture.key("target", "target-v1");
    var initial = try ProductGraph.initLinear(allocator, &.{ source, target });
    fixture.deinit();
    var copy = try ProductGraph.initFromGraphs(allocator, &.{initial}, &.{});
    defer copy.deinit(allocator);
    initial.deinit(allocator);
    const independent = try Fixture.init();
    defer independent.deinit();
    const equal = try independent.key("source", "source-v1");
    try std.testing.expect(copy.containsFresh(equal));
    try std.testing.expect(copy.dependsOn(target.ref, source.ref));
    try std.testing.expectEqualStrings("graph-fixture", copy.products[0].ref.producer);
    try std.testing.expectEqualStrings("module", copy.products[0].ref.source);
    try std.testing.expectEqualStrings("default", copy.products[0].ref.variant);
}

test "exact product graph changes follow records and both dependency edge directions" {
    const allocator = std.testing.allocator;
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const source = try fixture.key("source", "v1");
    const changed = try fixture.key("source", "v2");
    const target = try fixture.key("target", "v1");
    var before = try ProductGraph.initLinear(allocator, &.{ source, target });
    defer before.deinit(allocator);
    var after = try ProductGraph.initLinear(allocator, &.{ changed, target });
    defer after.deinit(allocator);
    try std.testing.expectEqual(ProductRefreshReason.revision_changed, after.refreshDecision(before, changed).reason.?);
    const target_change = after.refreshDecision(before, target);
    try std.testing.expectEqual(ProductRefreshReason.dependency_changed, target_change.reason.?);
    try std.testing.expect(target_change.stale_dependency.?.ref.eql(source.ref));
    var detached = try ProductGraph.init(allocator, &.{ source, target }, &.{});
    defer detached.deinit(allocator);
    try std.testing.expect(detached.refreshDecision(before, target).shouldRefresh());
    try std.testing.expect(before.refreshDecision(detached, target).shouldRefresh());
    try std.testing.expectEqual(ProductRefreshReason.no_previous_product, before.refreshDecision(.{}, target).reason.?);
}

test "exact product reports retain records after graphs and stores are released" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(metadata_storage.Storage, "choir_product_refresh_lifetime"),
        );
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(metadata_storage.Storage, "choir_product_report_composition_lifetime"),
        );
    }
    const allocator = std.testing.allocator;
    const fixture = try Fixture.init();
    const source = try fixture.key("source", "v1");
    const changed = try fixture.key("source", "v2");
    const target = try fixture.key("target", "v1");
    var before = try ProductGraph.initLinear(allocator, &.{ source, target });
    var after = try ProductGraph.initLinear(allocator, &.{ changed, target });
    var plan = try after.collectRefreshPlan(allocator, before);
    before.deinit(allocator);
    after.deinit(allocator);
    fixture.deinit();
    plan.markRefreshMaterialization(.live);
    var report = try ProductRefreshReport.initFromPlan(allocator, plan);
    var composed = try ProductRefreshReport.initFromReports(allocator, &.{&report});
    defer composed.deinit(allocator);
    report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), composed.refreshCount());
    try std.testing.expectEqual(@as(usize, 2), composed.liveCount());
    try std.testing.expect(composed.refreshes(target.ref));
    try std.testing.expectEqualStrings("v2", composed.decisionFor(source.ref).?.key.record.view().image);
}

test "exact product graph summaries cannot authorize reuse of restored metadata" {
    const allocator = std.testing.allocator;
    const first = try Fixture.init();
    defer first.deinit();
    const restored = try Fixture.init();
    defer restored.deinit();
    const key = try first.key("source", "v1");
    const equal = try restored.key("source", "v1");
    var before = try ProductGraph.init(allocator, &.{key}, &.{});
    defer before.deinit(allocator);
    var after = try ProductGraph.init(allocator, &.{equal}, &.{});
    defer after.deinit(allocator);
    var report = try after.collectRefreshReport(allocator, before);
    defer report.deinit(allocator);
    try std.testing.expect(report.productsAreFresh(&.{key.ref}));
    try std.testing.expectEqual(@as(u32, 0), restored.owner.publicationCount());
    try std.testing.expect(!@hasDecl(revision.Record, "entity"));
    try std.testing.expect(!@hasDecl(revision.Record, "requireGates"));
}

test "exact product graph composes fragments and rejects conflicting records" {
    const allocator = std.testing.allocator;
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const source = try fixture.key("source", "v1");
    const target = try fixture.key("target", "v1");
    const changed = try fixture.key("target", "v2");
    var first = try ProductGraph.init(allocator, &.{source}, &.{});
    defer first.deinit(allocator);
    var second = try ProductGraph.init(allocator, &.{target}, &.{});
    defer second.deinit(allocator);
    var conflict = try ProductGraph.init(allocator, &.{changed}, &.{});
    defer conflict.deinit(allocator);
    var joined = try ProductGraph.initFromGraphs(allocator, &.{ first, second }, &.{
        productDependency(target, source), productDependency(target, source),
    });
    defer joined.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), joined.products.len);
    try std.testing.expectEqual(@as(usize, 1), joined.dependencies.len);
    try std.testing.expectError(error.ConflictingProductKey, ProductGraph.initFromGraphs(allocator, &.{ second, conflict }, &.{}));
    var invalid = source;
    invalid.ref.stage = "not-the-record-address";
    try std.testing.expectError(error.InvalidProductAddress, ProductGraph.init(allocator, &.{invalid}, &.{}));
}

test "exact product graph refresh selections and materialization stay descriptive" {
    const allocator = std.testing.allocator;
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const source = try fixture.key("source", "v1");
    const target = try fixture.key("target", "v1");
    const absent = try fixture.key("absent", "v1");
    var graph = try ProductGraph.initLinear(allocator, &.{ source, target });
    defer graph.deinit(allocator);
    var retained = try graph.collectRetainedRefreshReportWithMaterialization(allocator, &.{source.ref}, .live);
    defer retained.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), retained.freshCount());
    try std.testing.expectEqual(@as(usize, 1), retained.liveCount());
    try std.testing.expect(!retained.hasRefreshes());
    try std.testing.expect(!retained.productsAreFresh(&.{absent.ref}));
    try std.testing.expectError(error.MissingMaterializationProduct, graph.collectRefreshReportWithMaterialization(allocator, .{}, &.{absent.ref}, .live));
    var plan = try graph.collectRefreshPlan(allocator, .{});
    defer plan.deinit(allocator);
    try std.testing.expect(plan.markMaterializations(&.{ source.ref, target.ref }, .live));
    try std.testing.expect(!plan.markMaterializations(&.{ source.ref, absent.ref }, .live));
    try std.testing.expectEqual(@as(usize, 2), plan.liveCount());
    const closure = try graph.collectInvalidationClosure(allocator, source.ref);
    defer allocator.free(closure);
    try std.testing.expect(productRefsContain(closure, target.ref));
}

test "exact product metadata acquires one local region and retains external records" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(metadata_storage.Storage, "choir_product_metadata_integration"),
        );
    }
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const key = try fixture.key("source", "v1");
    const decisions = [_]ProductRefreshDecision{.{ .key = key, .refresh = true }};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var graph = try ProductGraph.init(failing.allocator(), &.{key}, &.{});
    try std.testing.expectEqual(@as(usize, 1), failing.alloc_index);
    graph.deinit(failing.allocator());
    var plan = try ProductRefreshPlan.init(failing.allocator(), &decisions);
    try std.testing.expectEqual(@as(usize, 2), failing.alloc_index);
    plan.deinit(failing.allocator());
    var report = try ProductRefreshReport.initFromDecisions(failing.allocator(), &decisions);
    try std.testing.expectEqual(@as(usize, 3), failing.alloc_index);
    report.deinit(failing.allocator());
    const changed = try fixture.key("source", "v2");
    const target = try fixture.key("target", "v1");
    var before = try ProductGraph.initLinear(std.testing.allocator, &.{ key, target });
    defer before.deinit(std.testing.allocator);

    var graph_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var after = try ProductGraph.init(graph_allocator.allocator(), &.{ changed, target }, &.{productDependency(target, changed)});
    defer after.deinit(graph_allocator.allocator());
    try std.testing.expectEqual(@as(usize, 1), graph_allocator.alloc_index);
    try std.testing.expect(after.dependsOn(target.ref, changed.ref));

    const changed_decisions = [_]ProductRefreshDecision{
        after.refreshDecision(before, changed),
        after.refreshDecision(before, target),
    };
    try std.testing.expectEqual(ProductRefreshReason.dependency_changed, changed_decisions[1].reason.?);
    try std.testing.expect(changed_decisions[1].stale_dependency.?.ref.eql(key.ref));

    var plan_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var changed_plan = try ProductRefreshPlan.init(plan_allocator.allocator(), &changed_decisions);
    defer changed_plan.deinit(plan_allocator.allocator());
    try std.testing.expectEqual(@as(usize, 1), plan_allocator.alloc_index);

    var report_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var changed_report = try ProductRefreshReport.initFromDecisions(report_allocator.allocator(), &changed_decisions);
    defer changed_report.deinit(report_allocator.allocator());
    try std.testing.expectEqual(@as(usize, 1), report_allocator.alloc_index);
}

fn graphAllocationScenario(allocator: std.mem.Allocator, keys: []const ProductKey) !void {
    var current = try ProductGraph.initLinear(allocator, keys);
    defer current.deinit(allocator);
    var plan = try current.collectRefreshPlan(allocator, .{});
    defer plan.deinit(allocator);
    var report = try current.collectRefreshReport(allocator, .{});
    defer report.deinit(allocator);
    var composed = try ProductRefreshReport.initFromReports(allocator, &.{&report});
    defer composed.deinit(allocator);
}

test "exact product metadata releases retained prefixes at every allocation failure" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const source = try fixture.key("source", "v1");
    const target = try fixture.key("target", "v1");
    const keys = [_]ProductKey{ source, target };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, graphAllocationScenario, .{@as([]const ProductKey, &keys)});
}

test "exact product empty metadata allocates nothing and rejects byte count overflow" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var graph = try ProductGraph.init(failing.allocator(), &.{}, &.{});
    var plan = try ProductRefreshPlan.init(failing.allocator(), &.{});
    var report = try ProductRefreshReport.initFromDecisions(failing.allocator(), &.{});
    report.deinit(failing.allocator());
    plan.deinit(failing.allocator());
    graph.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    var total: usize = std.math.maxInt(usize);
    try std.testing.expectError(error.CapacityOverflow, addNameBytes(&total, "x"));
}
