const std = @import("std");
const simd = @import("simd");
const revision = @import("root.zig");
const record = revision.record;
const receipt = revision.receipt;

const Bytes = simd.ScalableTag(u8);

pub const Event = struct {
    store_epoch: u64,
    counter: u64,
    parent: ?ParentEvent,
};

pub const ParentEvent = struct { store_epoch: u64, counter: u64 };

pub const Limits = struct {
    revisions: u32,
    kinds: u32,
    builders: u32,
    compiler_manifests: u32,
    record_bytes: u32,
    gate_scratch_bytes: u32,
    candidate_count: u32,
    screening_bytes: u32,
};

/// The compiler manifest is owner-interned and arrives beside the record, since
/// no record carries the compiler that produced it.
pub const GateInput = struct {
    exact: record.Exact,
    compiler_manifest: []const u8,
    dependencies: []const record.Dependency,
};

pub const Gate = struct {
    identity: record.Version,
    definition: []const u8,
    scratch_bytes: u32,
    run: *const fn (GateInput, []u8) anyerror!record.EntityCounts,
};

pub const KindContract = struct {
    identity: record.Version,
    schema: Gate,
    gates: []const Gate,
};

pub const Dependency = struct {
    role: []const u8,
    revision: *const Revision,
};

pub const Request = struct {
    kind: *const Kind,
    address: record.Address,
    inputs: record.Inputs,
    dependencies: []const Dependency = &.{},
    parent: ?*const Revision = null,
    expected_image: ?[]const u8 = null,
};

pub const View = struct {
    exact: record.Exact,
    compiler_manifest: []const u8,
    semantic_record: []const u8,
    digest: [32]u8,
    bucket: u64,
    event: Event,
    entities: record.EntityCounts,
    work: receipt.WorkReceiptV1,
    gate_manifest: []const u8,
};

/// Exact transport metadata has no publication, gate, entity or reuse authority.
/// Retaining this handle keeps the store's immutable record allocation alive.
pub const Record = opaque {
    pub fn retain(self: *const Record) !*const Record {
        try recordData(self).owner.retain();
        return self;
    }

    pub fn release(self: *const Record) void {
        recordData(self).owner.release();
    }

    pub fn bytes(self: *const Record) []const u8 {
        return recordData(self).semantic;
    }

    pub fn view(self: *const Record) record.Exact {
        return recordData(self).exact;
    }

    pub fn address(self: *const Record) record.Address {
        return record.decodeAddress(self.view().address) catch unreachable;
    }

    pub fn inputs(self: *const Record) record.InputView {
        return record.decodeInputs(self.view().inputs) catch unreachable;
    }

    /// The owner-interned bytes this record was admitted under.
    pub fn compilerManifest(self: *const Record) []const u8 {
        return recordData(self).compiler_manifest;
    }

    pub fn eql(self: *const Record, other: *const Record) bool {
        return sameIdentity(recordData(self), recordData(other));
    }

    pub fn bucket(self: *const Record) u64 {
        const value = recordData(self).owner.digest_fn(self.view().image);
        return std.mem.readInt(u64, value[0..8], .little);
    }
};

/// This reference owns one retain on the revision's storage allocation.
pub const Entity = struct {
    revision: *const Revision,
    namespace: record.Namespace,
    ordinal: u32,

    pub fn release(self: Entity) void {
        self.revision.release();
    }

    pub fn eql(self: Entity, other: Entity) bool {
        return self.namespace == other.namespace and self.ordinal == other.ordinal and
            self.revision.eql(other.revision);
    }
};

pub const Revision = opaque {
    /// The returned reference is borrowed from this sealed revision. One handle
    /// stands for one record under one compiler, so a revision whose bytes a
    /// foreign compiler also produced still answers under its own.
    pub fn metadata(self: *const Revision) *const Record {
        const value = entry(self);
        return @ptrCast(value.owner.findRecordUnder(value.semantic, value.compiler_manifest).?);
    }

    pub fn retain(self: *const Revision) !*const Revision {
        try entry(self).owner.retain();
        return self;
    }

    pub fn release(self: *const Revision) void {
        entry(self).owner.release();
    }

    pub fn view(self: *const Revision) View {
        return entry(self).view();
    }

    pub fn eql(self: *const Revision, other: *const Revision) bool {
        return sameIdentity(&entry(self).metadata, &entry(other).metadata);
    }

    pub fn address(self: *const Revision) record.Address {
        return record.decodeAddress(entry(self).exact.address) catch unreachable;
    }

    pub fn inputs(self: *const Revision) record.InputView {
        return record.decodeInputs(entry(self).exact.inputs) catch unreachable;
    }

    pub fn requireDependency(
        self: *const Revision,
        role: []const u8,
        input: *const Revision,
    ) error{UndeclaredProductInput}!void {
        const value = entry(self);
        const declared = self.inputs().dependencies;
        std.debug.assert(value.references.len == declared.count);
        var dependencies = declared.iterator();
        for (value.references) |reference| {
            const dependency = (dependencies.next() catch unreachable).?;
            if (!std.mem.eql(u8, dependency.role, role)) continue;
            if (simd.equal(Bytes, reference, input.view().semantic_record)) return;
        }
        return error.UndeclaredProductInput;
    }

    pub fn entity(self: *const Revision, namespace: record.Namespace, ordinal: u32) !Entity {
        if (ordinal >= entry(self).entities[@backingInt(namespace)]) return error.InvalidEntity;
        return .{ .revision = try self.retain(), .namespace = namespace, .ordinal = ordinal };
    }

    pub fn requireGates(self: *const Revision, required: []const record.Version) !void {
        const kind = entry(self).kind;
        for (required) |identity| {
            if (kind.schema.identity.eql(identity)) continue;
            for (kind.gates) |gate| {
                if (gate.identity.eql(identity)) break;
            } else return error.MissingGateEvidence;
        }
    }
};

pub const Kind = opaque {};

pub const Store = opaque {
    pub fn create(allocator: std.mem.Allocator, limits: Limits) !*Store {
        return Storage.create(allocator, limits);
    }

    pub fn release(self: *Store) void {
        storage(self).release();
    }

    /// Copies and structurally validates restored metadata under explicit bounds.
    /// A matching record is interned, but this operation never creates a Revision.
    /// No record names its compiler, so the caller states which one produced these
    /// bytes and the store interns it exactly as it interns a draft's.
    pub fn importRecord(
        self: *Store,
        bytes: []const u8,
        compiler_manifest: []const u8,
        bounds: record.ClosureBounds,
    ) !*const Record {
        return storage(self).importRecord(bytes, compiler_manifest, bounds);
    }

    pub fn register(self: *Store, contract: KindContract) !*const Kind {
        return storage(self).register(contract);
    }

    pub fn freeze(self: *Store) void {
        std.debug.assert(!storage(self).frozen);
        storage(self).frozen = true;
    }

    pub fn begin(self: *Store, request: Request, limits: receipt.Limits) !*Builder {
        return Draft.create(storage(self), request, limits);
    }

    /// Candidates are borrowed until store release; lookup grants no reuse authority.
    pub fn lookup(
        self: *Store,
        bucket_hint: u64,
        output: []*const Revision,
    ) []const *const Revision {
        const state = storage(self);
        const bound = @min(output.len, state.limits.candidate_count);
        var count: usize = 0;
        for (state.entries[0..state.count]) |candidate| {
            if (count == bound) break;
            if (candidate.bucket != bucket_hint) continue;
            if (candidate.semantic.len > state.limits.screening_bytes) continue;
            output[count] = @ptrCast(candidate);
            count += 1;
        }
        return output[0..count];
    }

    pub fn publicationCount(self: *const Store) u32 {
        const state: *const Storage = @ptrCast(@alignCast(self));
        return state.count;
    }
};

pub const State = enum { open, captured, gated, sealed, aborted };

pub const Builder = opaque {
    /// The lease keeps unpublished working bytes alive independently of this builder.
    pub fn acquireWorkspace(self: *Builder, region: WorkspaceRegion) !WorkspaceLease {
        const state = draft(self);
        if (state.state != .open) return error.InvalidBuilderState;
        if (state.work.view().outcome != .running) return error.TerminalWorkOutcome;
        return state.workspace.?.acquire(region);
    }

    /// A live lease binds producer storage to the request that reserved it.
    pub fn ownsWorkspace(self: *Builder, lease: WorkspaceLease) bool {
        const state = draft(self);
        std.debug.assert(state.state == .open);
        return state.workspace == workspaceData(lease.owner);
    }

    pub fn inputs(self: *Builder) record.InputView {
        const state = draft(self);
        std.debug.assert(state.state == .open);
        return record.decodeInputs(state.inputs) catch unreachable;
    }

    /// The owner-interned bytes this draft was admitted under.
    pub fn compilerManifest(self: *Builder) []const u8 {
        const state = draft(self);
        std.debug.assert(state.state == .open);
        return state.compiler_manifest;
    }

    pub fn accounting(self: *Builder) *receipt.AccountingV1 {
        std.debug.assert(draft(self).state == .open);
        return draft(self).work;
    }

    pub fn requireDependency(self: *Builder, role: []const u8, input: *const Revision) !void {
        const state = draft(self);
        errdefer state.work.fail(.rejected);
        if (state.state != .open) return error.InvalidBuilderState;
        if (state.work.view().outcome != .running) return error.TerminalWorkOutcome;
        for (state.dependencies) |dependency| {
            if (!std.mem.eql(u8, dependency.role, role)) continue;
            if (simd.equal(Bytes, dependency.exact, input.view().semantic_record)) return;
        }
        return error.UndeclaredProductInput;
    }

    pub fn capture(self: *Builder, bytes: []const u8, observations: []const record.Fact) !void {
        errdefer draft(self).work.fail(.rejected);
        try draft(self).capture(bytes, observations);
    }

    pub fn seal(self: *Builder, kind: *const Kind) !*const Revision {
        errdefer draft(self).work.fail(.rejected);
        return draft(self).seal(kind);
    }

    /// A mismatch is screened before compiler obligations. Exhaustion is terminal.
    pub fn admitReuse(self: *Builder, candidate: *const Revision) !?Reuse {
        errdefer draft(self).work.fail(.rejected);
        return draft(self).admitReuse(candidate);
    }

    /// A matching restored record only binds a comparison against fresh cold work.
    /// It cannot authorize replay; capture must reproduce its complete image.
    /// Restored bytes do not name their compiler, so the caller states which one
    /// produced them and a draft admitted under another compiler declines.
    pub fn screenRestored(
        self: *Builder,
        bytes: []const u8,
        compiler_manifest: []const u8,
    ) !bool {
        errdefer draft(self).work.fail(.rejected);
        return draft(self).screenRestored(bytes, compiler_manifest);
    }

    pub fn abort(self: *Builder, outcome: receipt.Outcome) ?Failure {
        const state = draft(self);
        std.debug.assert(state.state != .sealed);
        std.debug.assert(state.state != .aborted);
        state.work.fail(outcome);
        const failure = Failure.capture(state) catch null;
        state.state = .aborted;
        state.destroy();
        return failure;
    }
};

pub const WorkspaceRegion = enum { producer, scratch };
pub const Workspace = opaque {};

/// Exclusive mutable byte storage; it never becomes a revision view.
pub const WorkspaceLease = struct {
    owner: *Workspace,
    region: WorkspaceRegion,

    pub fn bytes(self: WorkspaceLease) []u8 {
        const state = workspaceData(self.owner);
        std.debug.assert(state.leased[@backingInt(self.region)]);
        const boundary = state.bytes.len - state.scratch_bytes;
        return switch (self.region) {
            .producer => state.bytes[0..boundary],
            .scratch => state.bytes[boundary..],
        };
    }

    pub fn release(self: WorkspaceLease) void {
        const state = workspaceData(self.owner);
        const active = &state.leased[@backingInt(self.region)];
        std.debug.assert(active.*);
        active.* = false;
        state.release();
    }
};

const WorkspaceData = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    scratch_bytes: u32,
    references: u32 = 1,
    leased: [2]bool = @splat(false),

    fn acquire(self: *WorkspaceData, region: WorkspaceRegion) !WorkspaceLease {
        const active = &self.leased[@backingInt(region)];
        if (active.*) return error.WorkspaceAlreadyLeased;
        std.debug.assert(self.references < 3);
        self.references += 1;
        active.* = true;
        return .{ .owner = @ptrCast(self), .region = region };
    }

    fn release(self: *WorkspaceData) void {
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return;
        std.debug.assert(!self.leased[0]);
        std.debug.assert(!self.leased[1]);
        const allocator = self.allocator;
        releaseUntouched(allocator, self.bytes);
        allocator.destroy(self);
    }
};

fn workspaceData(handle: *Workspace) *WorkspaceData {
    return @ptrCast(@alignCast(handle));
}

pub const Reuse = struct {
    allocator: std.mem.Allocator,
    revision: *const Revision,
    work: receipt.WorkReceiptV1,

    pub fn deinit(self: *Reuse) void {
        self.revision.release();
        self.allocator.free(self.work.events);
        self.* = undefined;
    }
};

pub const Failure = struct {
    allocator: std.mem.Allocator,
    address: []const u8,
    inputs: []const u8,
    work: receipt.WorkReceiptV1,

    fn capture(state: *const Draft) !Failure {
        const allocator = state.owner.allocator;
        const address = try allocator.dupe(u8, state.address);
        errdefer allocator.free(address);
        const inputs = try allocator.dupe(u8, state.inputs);
        errdefer allocator.free(inputs);
        var work = state.work.view();
        work.events = try allocator.dupe(receipt.Event, work.events);
        return .{ .allocator = allocator, .address = address, .inputs = inputs, .work = work };
    }

    pub fn deinit(self: *Failure) void {
        self.allocator.free(self.address);
        self.allocator.free(self.inputs);
        self.allocator.free(self.work.events);
        self.* = undefined;
    }
};

var next_epoch = std.atomic.Value(u64).init(1);

const Storage = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    epoch: u64,
    references: u64 = 1,
    entries: []*Entry,
    count: u32 = 0,
    records: []*RecordData,
    record_count: u32 = 0,
    kinds: []*KindData,
    kind_count: u32 = 0,
    manifests: [][]u8,
    manifest_count: u32 = 0,
    builder_count: u32 = 0,
    event_counter: u64 = 0,
    frozen: bool = false,
    digest_fn: *const fn ([]const u8) [32]u8 = digest,

    fn create(allocator: std.mem.Allocator, limits: Limits) !*Store {
        if (limits.revisions == 0 or limits.kinds == 0 or limits.builders == 0 or
            limits.record_bytes == 0 or limits.candidate_count == 0 or
            limits.compiler_manifests == 0)
        {
            return error.InvalidStoreLimits;
        }
        const self = try allocator.create(Storage);
        errdefer allocator.destroy(self);
        const entries = try allocator.alloc(*Entry, limits.revisions);
        errdefer allocator.free(entries);
        const records = try allocator.alloc(*RecordData, limits.revisions);
        errdefer allocator.free(records);
        const kinds = try allocator.alloc(*KindData, limits.kinds);
        errdefer allocator.free(kinds);
        const manifests = try allocator.alloc([]u8, limits.compiler_manifests);
        errdefer allocator.free(manifests);
        self.* = .{
            .allocator = allocator,
            .limits = limits,
            .epoch = try allocateEpoch(),
            .entries = entries,
            .records = records,
            .kinds = kinds,
            .manifests = manifests,
        };
        return @ptrCast(self);
    }

    /// Returns this store's copy of the given compiler manifest, admitting a new
    /// one only while the declared capacity has room. Interned bytes live until
    /// the store dies, because sealed records reference them and never re-copy.
    fn internManifest(self: *Storage, bytes: []const u8) ![]const u8 {
        std.debug.assert(self.manifest_count <= self.manifests.len);
        if (bytes.len == 0) return error.MissingCompilerManifest;
        if (bytes.len > self.limits.record_bytes) return error.RecordLimit;
        for (self.manifests[0..self.manifest_count]) |existing| {
            if (simd.equal(Bytes, existing, bytes)) return existing;
        }
        if (self.manifest_count == self.manifests.len) return error.CompilerManifestLimit;
        const copy = try self.allocator.dupe(u8, bytes);
        self.manifests[self.manifest_count] = copy;
        self.manifest_count += 1;
        return copy;
    }

    fn retain(self: *Storage) !void {
        self.references = std.math.add(u64, self.references, 1) catch {
            return error.ReferenceOverflow;
        };
    }

    fn release(self: *Storage) void {
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return;
        std.debug.assert(self.builder_count == 0);
        const allocator = self.allocator;
        for (self.entries[0..self.count]) |item| item.destroy();
        for (self.records[0..self.record_count]) |item| item.destroy();
        for (self.kinds[0..self.kind_count]) |kind| kind.destroy();
        for (self.manifests[0..self.manifest_count]) |manifest| allocator.free(manifest);
        allocator.free(self.entries);
        allocator.free(self.records);
        allocator.free(self.kinds);
        allocator.free(self.manifests);
        allocator.destroy(self);
    }

    /// Finds equal bytes regardless of compiler, which is what sharing one
    /// immutable buffer needs. Identity asks `findRecordUnder` instead.
    fn findRecord(self: *Storage, bytes: []const u8) ?*const RecordData {
        for (self.records[0..self.record_count]) |item| {
            if (simd.equal(Bytes, item.semantic, bytes)) return item;
        }
        for (self.entries[0..self.count]) |item| {
            if (simd.equal(Bytes, item.semantic, bytes)) return &item.metadata;
        }
        return null;
    }

    /// Every record this store holds names a manifest this store interned, so
    /// equal manifests are one address and the screen costs a pointer compare.
    fn findRecordUnder(
        self: *Storage,
        bytes: []const u8,
        manifest: []const u8,
    ) ?*const RecordData {
        for (self.records[0..self.record_count]) |item| {
            if (item.compiler_manifest.ptr != manifest.ptr) continue;
            if (simd.equal(Bytes, item.semantic, bytes)) return item;
        }
        for (self.entries[0..self.count]) |item| {
            if (item.metadata.compiler_manifest.ptr != manifest.ptr) continue;
            if (simd.equal(Bytes, item.semantic, bytes)) return &item.metadata;
        }
        return null;
    }

    fn importRecord(
        self: *Storage,
        bytes: []const u8,
        compiler_manifest: []const u8,
        bounds: record.ClosureBounds,
    ) !*const Record {
        if (bytes.len > self.limits.record_bytes) return error.RecordLimit;
        if (bytes.len > bounds.bytes) return error.RecordLimit;
        const interned = try self.internManifest(compiler_manifest);
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        try record.validateClosure(copy, bounds);
        if (self.findRecordUnder(copy, interned)) |existing| {
            try self.retain();
            self.allocator.free(copy);
            return @ptrCast(existing);
        }
        if (self.record_count == self.records.len) return error.RecordCountLimit;
        const metadata = try self.allocator.create(RecordData);
        errdefer self.allocator.destroy(metadata);
        metadata.* = .{
            .owner = self,
            .compiler_manifest = interned,
            .semantic = copy,
            .exact = record.decodeExact(copy) catch unreachable,
        };
        try self.retain();
        self.records[self.record_count] = metadata;
        self.record_count += 1;
        return @ptrCast(metadata);
    }

    fn register(self: *Storage, contract: KindContract) !*const Kind {
        if (self.frozen) return error.RegistrationFrozen;
        if (contract.schema.scratch_bytes > self.limits.gate_scratch_bytes) {
            return error.GateScratchLimit;
        }
        for (contract.gates) |gate| {
            if (gate.scratch_bytes > self.limits.gate_scratch_bytes) return error.GateScratchLimit;
        }
        const manifest = try encodeManifest(self.allocator, contract);
        errdefer self.allocator.free(manifest);
        if (manifest.len > self.limits.record_bytes) return error.RecordLimit;
        for (self.kinds[0..self.kind_count]) |existing| {
            if (!existing.identity.eql(contract.identity)) continue;
            if (!std.mem.eql(u8, existing.manifest, manifest) or
                !existing.sameCallbacks(contract)) return error.KindContractMismatch;
            self.allocator.free(manifest);
            return @ptrCast(existing);
        }
        if (self.kind_count == self.kinds.len) return error.KindLimit;
        const kind = try KindData.create(self, contract, manifest);
        self.kinds[self.kind_count] = kind;
        self.kind_count += 1;
        return @ptrCast(kind);
    }
};

const KindData = struct {
    owner: *Storage,
    identity: record.Version,
    manifest: []u8,
    schema: Gate,
    gates: []Gate,

    fn create(owner: *Storage, contract: KindContract, manifest: []u8) !*KindData {
        const allocator = owner.allocator;
        const self = try allocator.create(KindData);
        errdefer allocator.destroy(self);
        const name = try allocator.dupe(u8, contract.identity.name);
        errdefer allocator.free(name);
        const schema = try cloneGate(allocator, contract.schema);
        errdefer freeGate(allocator, schema);
        const gates = try allocator.alloc(Gate, contract.gates.len);
        errdefer allocator.free(gates);
        var count: usize = 0;
        errdefer for (gates[0..count]) |gate| freeGate(allocator, gate);
        for (contract.gates, gates) |gate, *copy| {
            copy.* = try cloneGate(allocator, gate);
            count += 1;
        }
        self.* = .{
            .owner = owner,
            .identity = .{ .name = name, .version = contract.identity.version },
            .manifest = manifest,
            .schema = schema,
            .gates = gates,
        };
        return self;
    }

    fn sameCallbacks(self: *const KindData, contract: KindContract) bool {
        if (self.schema.run != contract.schema.run) return false;
        if (self.gates.len != contract.gates.len) return false;
        for (self.gates, contract.gates) |first, second| {
            if (first.run != second.run) return false;
        }
        return true;
    }

    fn destroy(self: *KindData) void {
        const allocator = self.owner.allocator;
        allocator.free(self.identity.name);
        allocator.free(self.manifest);
        freeGate(allocator, self.schema);
        for (self.gates) |gate| freeGate(allocator, gate);
        allocator.free(self.gates);
        allocator.destroy(self);
    }
};

const Entry = struct {
    owner: *Storage,
    metadata: RecordData,
    compiler_manifest: []const u8,
    semantic: []const u8,
    allocation: ?[]u8,
    references: []const []const u8,
    exact: record.Exact,
    digest_value: [32]u8,
    bucket: u64,
    event: Event,
    entities: record.EntityCounts,
    kind: *const KindData,
    work: receipt.WorkReceiptV1,

    fn view(self: *const Entry) View {
        return .{
            .exact = self.exact,
            .compiler_manifest = self.compiler_manifest,
            .semantic_record = self.semantic,
            .digest = self.digest_value,
            .bucket = self.bucket,
            .event = self.event,
            .entities = self.entities,
            .work = self.work,
            .gate_manifest = self.kind.manifest,
        };
    }

    fn destroy(self: *Entry) void {
        const allocator = self.owner.allocator;
        if (self.allocation) |bytes| releaseUntouched(allocator, bytes);
        allocator.free(self.references);
        allocator.free(self.work.events);
        allocator.destroy(self);
    }
};

const Draft = struct {
    owner: *Storage,
    kind: *const KindData,
    compiler_manifest: []const u8,
    state: State = .open,
    address: []u8,
    inputs: []u8,
    dependencies: []record.Dependency,
    revisions: []*const Revision,
    facts: []record.Fact,
    expected_image: ?[]u8,
    image: ?[]u8 = null,
    output: ?[]u8 = null,
    workspace: ?*WorkspaceData = null,
    parent: ?ParentEvent,
    work: *receipt.AccountingV1,
    entities: record.EntityCounts = @splat(0),
    screened_candidates: u32 = 0,
    screened_bytes: u64 = 0,
    restored: bool = false,

    fn create(owner: *Storage, request: Request, limits: receipt.Limits) !*Builder {
        if (!owner.frozen) return error.RegistrationOpen;
        const kind = kindData(request.kind);
        if (kind.owner != owner) return error.ForeignKind;
        if (owner.builder_count == owner.limits.builders) return error.BuilderLimit;
        const input_bound = try inspectRequest(request, owner.limits.record_bytes);
        const input_capacity = try requestCapacity(request, input_bound);
        const work = try receipt.AccountingV1.create(
            owner.allocator,
            limits,
            request.inputs.pipeline,
        );
        errdefer work.destroy();
        try transport(work, owner.limits);
        const output = try reserveOutput(owner, work);
        errdefer releaseUntouched(owner.allocator, output);
        const workspace = try reserveWorkspace(owner, work);
        errdefer workspace.release();
        const token = try work.begin(.input, .{
            .identity = .{ .name = "revision-input-v1", .version = 1 },
            .work = .{ .input_bytes = input_bound, .allocation_capacity = input_capacity },
            .workspace = input_capacity,
            .retained_storage = input_capacity,
        });
        const self = try copyRequest(owner, kind, request, work);
        errdefer self.freeRequest();
        try work.finish(token, .success, .{
            .work = .{ .input_bytes = self.address.len + self.inputs.len },
        });
        try owner.retain();
        owner.builder_count += 1;
        self.output = output;
        self.workspace = workspace;
        return @ptrCast(self);
    }

    fn copyRequest(
        owner: *Storage,
        kind: *const KindData,
        request: Request,
        work: *receipt.AccountingV1,
    ) !*Draft {
        const allocator = owner.allocator;
        const compiler_manifest = try owner.internManifest(request.inputs.compiler_manifest);
        const self = try allocator.create(Draft);
        errdefer allocator.destroy(self);
        const address = try record.encodeAddress(allocator, request.address);
        errdefer allocator.free(address);
        const revisions = try allocator.alloc(*const Revision, request.dependencies.len);
        errdefer allocator.free(revisions);
        const dependencies = try retainDependencies(allocator, request.dependencies, revisions);
        errdefer freeDependencies(allocator, dependencies, revisions);
        const inputs = try record.encodeInputs(
            allocator,
            request.inputs,
            dependencies,
            kind.manifest,
        );
        errdefer allocator.free(inputs);
        try recordSize(owner.limits.record_bytes, address.len, inputs.len, 0);
        const facts = try copyFacts(allocator, request.inputs.facts);
        errdefer freeFacts(allocator, facts);
        const expected = if (request.expected_image) |bytes|
            try allocator.dupe(u8, bytes)
        else
            null;
        self.* = .{
            .owner = owner,
            .kind = kind,
            .compiler_manifest = compiler_manifest,
            .address = address,
            .inputs = inputs,
            .dependencies = dependencies,
            .revisions = revisions,
            .facts = facts,
            .expected_image = expected,
            .parent = if (request.parent) |parent| .{
                .store_epoch = parent.view().event.store_epoch,
                .counter = parent.view().event.counter,
            } else null,
            .work = work,
        };
        return self;
    }

    fn capture(self: *Draft, bytes: []const u8, observations: []const record.Fact) !void {
        if (self.state != .open) return error.InvalidBuilderState;
        try self.work.producersComplete();
        try recordSize(
            self.owner.limits.record_bytes,
            self.address.len,
            self.inputs.len,
            bytes.len,
        );
        const token = try self.work.begin(.capture, .{
            .identity = .{ .name = "revision-capture-v1", .version = 1 },
            .work = .{
                .input_bytes = bytes.len,
                .output_bytes = bytes.len,
                .structural_visits = bytes.len,
                .allocation_capacity = bytes.len,
            },
            .workspace = bytes.len,
            .retained_storage = bytes.len,
        });
        errdefer self.work.finish(token, .rejected, .{}) catch {};
        try record.validateObservations(self.facts, observations);
        if (self.expected_image) |expected| {
            if (!simd.equal(Bytes, bytes, expected)) return error.UnexpectedImage;
        }
        self.image = try self.owner.allocator.dupe(u8, bytes);
        self.state = .captured;
        try self.work.finish(token, .success, .{ .work = .{
            .input_bytes = bytes.len,
            .output_bytes = bytes.len,
        } });
    }

    fn seal(self: *Draft, kind: *const Kind) !*const Revision {
        if (self.state != .captured) return error.InvalidBuilderState;
        if (kindData(kind) != self.kind) return error.KindContractMismatch;
        try self.work.producersComplete();
        self.entities = try self.runGate(self.kind.schema);
        for (self.kind.gates) |gate| _ = try self.runGate(gate);
        self.state = .gated;
        return self.publish();
    }

    fn runGate(self: *Draft, gate: Gate) !record.EntityCounts {
        const token = try self.work.begin(.gate, .{
            .identity = gate.identity,
            .work = .{
                .input_bytes = self.inputs.len + self.image.?.len,
                .structural_visits = self.image.?.len,
                .allocation_capacity = gate.scratch_bytes,
            },
            .workspace = gate.scratch_bytes,
        });
        errdefer self.work.finish(token, .rejected, .{}) catch {};
        const scratch = try self.workspace.?.acquire(.scratch);
        defer scratch.release();
        const counts = gate.run(.{
            .exact = .{ .address = self.address, .inputs = self.inputs, .image = self.image.? },
            .compiler_manifest = self.compiler_manifest,
            .dependencies = self.dependencies,
        }, scratch.bytes()[0..gate.scratch_bytes]) catch |err| {
            if (err == error.WorkExhausted) self.work.fail(.exhausted);
            return err;
        };
        try self.work.finish(token, .success, .{ .work = .{
            .input_bytes = self.inputs.len + self.image.?.len,
        } });
        return counts;
    }

    fn publish(self: *Draft) !*const Revision {
        const owner = self.owner;
        if (owner.count == owner.entries.len) return error.StoreFull;
        const event_counter = std.math.add(u64, owner.event_counter, 1) catch {
            return error.GenerationOverflow;
        };
        if (owner.references == std.math.maxInt(u64)) return error.ReferenceOverflow;
        const length = try record.exactSize(self.address.len, self.inputs.len, self.image.?.len);
        const references = try capacityMul(self.dependencies.len, @sizeOf([]const u8));
        const events = try capacityMul(self.work.view().events.len + 1, @sizeOf(receipt.Event));
        const metadata = try capacityAdd(try capacityAdd(@sizeOf(Entry), references), events);
        const token = try self.work.begin(.output, .{
            .identity = .{ .name = "revision-output-v1", .version = 1 },
            .work = .{
                .input_bytes = length,
                .output_bytes = length,
                .structural_visits = length,
                .allocation_capacity = metadata,
            },
            .workspace = try capacityAdd(length, metadata),
            .retained_storage = metadata,
        });
        var output_open = true;
        errdefer if (output_open) {
            self.work.finish(token, .rejected, .{}) catch {};
        };
        const published = try self.prepareEntry(event_counter);
        errdefer published.destroy();
        try self.work.finish(token, .success, .{ .work = .{
            .input_bytes = length,
            .output_bytes = length,
        } });
        output_open = false;
        try self.work.complete();
        const event_buffer = published.work.events;
        @memcpy(@constCast(event_buffer), self.work.view().events);
        published.work = self.work.view();
        published.work.events = event_buffer;
        owner.references += 1;
        owner.entries[owner.count] = published;
        owner.count += 1;
        owner.event_counter = event_counter;
        self.state = .sealed;
        self.destroy();
        return @ptrCast(published);
    }

    fn prepareEntry(self: *Draft, counter: u64) !*Entry {
        const owner = self.owner;
        const allocator = owner.allocator;
        const published = try allocator.create(Entry);
        errdefer allocator.destroy(published);
        const references = try allocator.alloc([]const u8, self.dependencies.len);
        errdefer allocator.free(references);
        const semantic = try record.encodeExactInto(self.output.?, .{
            .address = self.address,
            .inputs = self.inputs,
            .image = self.image.?,
        });
        var work = self.work.view();
        work.events = try allocator.dupe(receipt.Event, work.events);
        const digest_value = owner.digest_fn(self.image.?);
        published.* = .{
            .owner = owner,
            .metadata = undefined,
            .compiler_manifest = self.compiler_manifest,
            .semantic = semantic,
            .allocation = self.output,
            .references = references,
            .exact = record.decodeExact(semantic) catch unreachable,
            .digest_value = digest_value,
            .bucket = std.mem.readInt(u64, digest_value[0..8], .little),
            .event = .{ .store_epoch = owner.epoch, .counter = counter, .parent = self.parent },
            .entities = self.entities,
            .kind = self.kind,
            .work = work,
        };
        self.output = null;
        internImage(published);
        self.referenceDependencies(published.exact.inputs, references);
        published.metadata = .{
            .owner = owner,
            .compiler_manifest = self.compiler_manifest,
            .semantic = published.semantic,
            .exact = published.exact,
        };
        return published;
    }

    /// Producer bounds may depend on either exposed workspace region's capacity.
    /// A different reservation needs its own cold trace before it can authorize reuse.
    fn admitReuse(self: *Draft, candidate: *const Revision) !?Reuse {
        if (self.restored) return error.RestoredCandidateRequiresExecution;
        const prior = entry(candidate);
        if (!try self.screen(prior.semantic.len)) return null;
        if (!simd.equal(Bytes, prior.compiler_manifest, self.compiler_manifest)) return null;
        if (!simd.equal(Bytes, prior.kind.manifest, self.kind.manifest)) return null;
        if (!simd.equal(Bytes, prior.exact.address, self.address)) return null;
        if (!self.eqlInputs(prior)) return null;
        if (prior.work.limits.workspace != self.work.view().limits.workspace) return null;
        if (prior.owner.limits.gate_scratch_bytes != self.owner.limits.gate_scratch_bytes) {
            return null;
        }
        if (self.expected_image) |expected| {
            if (!simd.equal(Bytes, expected, prior.exact.image)) return null;
        }
        try self.work.replay(prior.work, 4);
        const allocator = self.owner.allocator;
        var work = self.work.view();
        work.events = try allocator.dupe(receipt.Event, work.events);
        errdefer allocator.free(work.events);
        const retained = try candidate.retain();
        errdefer retained.release();
        try self.work.complete();
        work.outcome = .success;
        const result = Reuse{
            .allocator = allocator,
            .revision = retained,
            .work = work,
        };
        self.state = .sealed;
        self.destroy();
        return result;
    }

    fn eqlInputs(self: *const Draft, prior: *const Entry) bool {
        const first = prior.exact.inputs;
        const second = self.inputs;
        if (first.len != second.len) return false;
        const embedded = (record.decodeInputs(first) catch unreachable).dependencies;
        const requested = (record.decodeInputs(second) catch unreachable).dependencies;
        if (embedded.count != requested.count) return false;
        std.debug.assert(prior.references.len == embedded.count);
        var prior_dependencies = embedded.iterator();
        var draft_dependencies = requested.iterator();
        var offset: usize = 0;
        for (prior.references) |reference| {
            const left = (prior_dependencies.next() catch unreachable).?;
            const right = (draft_dependencies.next() catch unreachable).?;
            const start = @intFromPtr(left.exact.ptr) - @intFromPtr(first.ptr);
            if (start != @intFromPtr(right.exact.ptr) - @intFromPtr(second.ptr)) return false;
            if (left.exact.len != right.exact.len) return false;
            std.debug.assert(offset <= start);
            if (!simd.equal(Bytes, first[offset..start], second[offset..start])) return false;
            const retained = self.dependencyRevision(right.role);
            if (!simd.equal(Bytes, reference, retained.view().semantic_record)) return false;
            offset = start + left.exact.len;
        }
        return simd.equal(Bytes, first[offset..], second[offset..]);
    }

    fn referenceDependencies(self: *const Draft, inputs: []const u8, output: [][]const u8) void {
        std.debug.assert(output.len == self.dependencies.len);
        const declared = (record.decodeInputs(inputs) catch unreachable).dependencies;
        std.debug.assert(declared.count == output.len);
        var dependencies = declared.iterator();
        for (output) |*reference| {
            const embedded = (dependencies.next() catch unreachable).?;
            const retained = self.dependencyRevision(embedded.role);
            reference.* = if (entry(retained).owner == self.owner)
                retained.view().semantic_record
            else
                embedded.exact;
            std.debug.assert(reference.len == embedded.exact.len);
        }
    }

    fn dependencyRevision(self: *const Draft, role: []const u8) *const Revision {
        for (self.dependencies, self.revisions) |dependency, retained| {
            if (std.mem.eql(u8, dependency.role, role)) return retained;
        }
        unreachable;
    }

    fn screen(self: *Draft, length: usize) !bool {
        if (self.state != .open) return error.InvalidBuilderState;
        const work = self.work.view();
        if (work.outcome != .running) return error.TerminalWorkOutcome;
        if (work.events.len != 4) return error.CompilerWorkAlreadyStarted;
        const limits = self.owner.limits;
        if (self.screened_candidates == limits.candidate_count) return false;
        if (length > limits.screening_bytes - self.screened_bytes) return false;
        self.screened_candidates += 1;
        self.screened_bytes += length;
        try self.work.observeTransport(length);
        return true;
    }

    fn screenRestored(self: *Draft, bytes: []const u8, compiler_manifest: []const u8) !bool {
        if (self.restored) return error.RestoredCandidateAlreadyBound;
        if (!try self.screen(bytes.len)) return false;
        if (!simd.equal(Bytes, self.compiler_manifest, compiler_manifest)) return false;
        const restored = record.decodeExact(bytes) catch return false;
        if (!simd.equal(Bytes, restored.address, self.address) or
            !simd.equal(Bytes, restored.inputs, self.inputs)) return false;
        if (self.expected_image) |expected| {
            if (!simd.equal(Bytes, expected, restored.image)) return false;
        } else {
            self.expected_image = try self.owner.allocator.dupe(u8, restored.image);
        }
        self.restored = true;
        return true;
    }

    fn freeRequest(self: *Draft) void {
        const allocator = self.owner.allocator;
        allocator.free(self.address);
        allocator.free(self.inputs);
        freeDependencies(allocator, self.dependencies, self.revisions);
        allocator.free(self.revisions);
        freeFacts(allocator, self.facts);
        if (self.expected_image) |bytes| allocator.free(bytes);
        if (self.image) |bytes| allocator.free(bytes);
        if (self.output) |bytes| releaseUntouched(allocator, bytes);
        if (self.workspace) |workspace| workspace.release();
        allocator.destroy(self);
    }

    fn destroy(self: *Draft) void {
        const owner = self.owner;
        self.work.destroy();
        self.freeRequest();
        std.debug.assert(owner.builder_count > 0);
        owner.builder_count -= 1;
        owner.release();
    }
};

fn transport(work: *receipt.AccountingV1, limits: Limits) !void {
    const token = try work.begin(.transport, .{
        .identity = .{ .name = "revision-screen-v1", .version = 1 },
        .work = .{
            .input_bytes = limits.screening_bytes,
            .allocation_capacity = limits.screening_bytes,
        },
        .workspace = limits.screening_bytes,
        .retained_storage = limits.screening_bytes,
    });
    try work.finish(token, .success, .{});
}

fn reserveUntouched(allocator: std.mem.Allocator, capacity: usize) error{OutOfMemory}![]u8 {
    if (capacity == 0) return allocator.alloc(u8, 0);
    const bytes = allocator.rawAlloc(capacity, .of(u8), @returnAddress()) orelse
        return error.OutOfMemory;
    return bytes[0..capacity];
}

fn releaseUntouched(allocator: std.mem.Allocator, bytes: []u8) void {
    if (bytes.len == 0) return allocator.free(bytes);
    allocator.rawFree(bytes, .of(u8), @returnAddress());
}

fn reserveOutput(owner: *Storage, work: *receipt.AccountingV1) ![]u8 {
    const capacity = owner.limits.record_bytes;
    const token = try work.begin(.reservation, .{
        .identity = .{ .name = "revision-output-reservation-v1", .version = 1 },
        .work = .{ .allocation_capacity = capacity },
        .workspace = capacity,
        .retained_storage = capacity,
    });
    errdefer work.finish(token, .rejected, .{}) catch {};
    const bytes = try reserveUntouched(owner.allocator, capacity);
    errdefer releaseUntouched(owner.allocator, bytes);
    try work.finish(token, .success, .{ .work = .{ .allocation_capacity = bytes.len } });
    return bytes;
}

fn reserveWorkspace(owner: *Storage, work: *receipt.AccountingV1) !*WorkspaceData {
    const capacity = std.math.cast(usize, work.view().limits.workspace) orelse {
        work.fail(.exhausted);
        return error.WorkOverflow;
    };
    const scratch = owner.limits.gate_scratch_bytes;
    const token = try work.begin(.reservation, .{
        .identity = .{ .name = "revision-workspace-reservation-v1", .version = 1 },
        .work = .{ .allocation_capacity = capacity },
        .workspace = @max(capacity, scratch),
        .retained_storage = capacity,
    });
    errdefer work.finish(token, .rejected, .{}) catch {};
    const allocator = owner.allocator;
    const state = try allocator.create(WorkspaceData);
    errdefer allocator.destroy(state);
    const bytes = try reserveUntouched(allocator, capacity);
    errdefer releaseUntouched(allocator, bytes);
    try work.finish(token, .success, .{ .work = .{ .allocation_capacity = bytes.len } });
    state.* = .{ .allocator = allocator, .bytes = bytes, .scratch_bytes = scratch };
    return state;
}

fn internImage(published: *Entry) void {
    const owner = published.owner;
    if (owner.findRecord(published.semantic)) |existing| {
        releaseUntouched(owner.allocator, published.allocation.?);
        published.semantic = existing.semantic;
        published.exact = existing.exact;
        published.allocation = null;
    }
}

/// A revision's identity is its exact bytes under its owner-interned compiler
/// manifest. Manifests intern per store, so revisions that share one meet at a
/// single address and settle in constant time; across stores the bytes decide.
fn sameIdentity(self: *const RecordData, other: *const RecordData) bool {
    if (!simd.equal(Bytes, self.compiler_manifest, other.compiler_manifest)) return false;
    return self.exact.eql(other.exact);
}

const RecordData = struct {
    owner: *Storage,
    compiler_manifest: []const u8,
    semantic: []const u8,
    exact: record.Exact,

    fn destroy(self: *RecordData) void {
        const allocator = self.owner.allocator;
        allocator.free(self.semantic);
        allocator.destroy(self);
    }
};

fn recordData(handle: *const Record) *const RecordData {
    return @ptrCast(@alignCast(handle));
}

fn retainDependencies(
    allocator: std.mem.Allocator,
    source: []const Dependency,
    revisions: []*const Revision,
) ![]record.Dependency {
    std.debug.assert(source.len == revisions.len);
    const result = try allocator.alloc(record.Dependency, source.len);
    errdefer allocator.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized], revisions[0..initialized]) |item, retained| {
        allocator.free(item.role);
        retained.release();
    };
    for (source, result, revisions) |dependency, *output, *retained| {
        const role = try allocator.dupe(u8, dependency.role);
        errdefer allocator.free(role);
        retained.* = try dependency.revision.retain();
        output.* = .{ .role = role, .exact = retained.*.view().semantic_record };
        initialized += 1;
    }
    return result;
}

fn freeDependencies(
    allocator: std.mem.Allocator,
    values: []const record.Dependency,
    revisions: []const *const Revision,
) void {
    std.debug.assert(values.len == revisions.len);
    for (values, revisions) |value, retained| {
        allocator.free(value.role);
        retained.release();
    }
    allocator.free(values);
}

fn copyFacts(allocator: std.mem.Allocator, source: []const record.Fact) ![]record.Fact {
    const result = try allocator.alloc(record.Fact, source.len);
    errdefer allocator.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |item| {
        allocator.free(item.key);
        if (item.value) |bytes| allocator.free(bytes);
    };
    for (source, result) |fact, *output| {
        const key = try allocator.dupe(u8, fact.key);
        errdefer allocator.free(key);
        output.* = .{
            .key = key,
            .value = if (fact.value) |bytes| try allocator.dupe(u8, bytes) else null,
        };
        initialized += 1;
    }
    return result;
}

fn freeFacts(allocator: std.mem.Allocator, values: []const record.Fact) void {
    for (values) |value| {
        allocator.free(value.key);
        if (value.value) |bytes| allocator.free(bytes);
    }
    allocator.free(values);
}

fn recordSize(limit: u32, address: usize, inputs: usize, image: usize) !void {
    if (try record.exactSize(address, inputs, image) > limit) return error.RecordLimit;
}

fn inspectRequest(request: Request, limit: u32) !u64 {
    var size: u64 = 256;
    inline for (@typeInfo(record.Address).@"struct".field_names) |field| {
        try addBound(&size, @field(request.address, field).len, limit);
    }
    try addBound(&size, request.inputs.options.len, limit);
    try addBound(&size, request.inputs.policy.len, limit);
    try addBound(&size, kindData(request.kind).manifest.len, limit);
    for (request.inputs.versions) |version| try addBound(&size, version.name.len + 8, limit);
    for (request.inputs.pipeline) |version| try addBound(&size, version.name.len + 8, limit);
    for (request.inputs.facts) |fact| {
        try addBound(&size, fact.key.len, limit);
        try addBound(&size, if (fact.value) |bytes| bytes.len else 0, limit);
        try addBound(&size, 9, limit);
    }
    for (request.dependencies) |dependency| {
        try addBound(&size, dependency.role.len, limit);
        try addBound(&size, dependency.revision.view().semantic_record.len, limit);
        try addBound(&size, 8, limit);
    }
    if (request.expected_image) |bytes| {
        if (bytes.len > limit) return error.RecordLimit;
    }
    return size;
}

fn requestCapacity(request: Request, encoded_bound: u64) !u64 {
    var size = try capacityMul(encoded_bound, 4);
    const tables = [_]struct { count: usize, item_bytes: usize }{
        .{ .count = request.inputs.versions.len, .item_bytes = @sizeOf(record.Version) },
        .{ .count = request.inputs.facts.len, .item_bytes = 2 * @sizeOf(record.Fact) },
        .{ .count = request.dependencies.len, .item_bytes = 2 * @sizeOf(record.Dependency) },
        .{ .count = request.dependencies.len, .item_bytes = @sizeOf(*const Revision) },
    };
    for (tables) |table| {
        size = try capacityAdd(size, try capacityMul(table.count, table.item_bytes));
    }
    size = try capacityAdd(size, @sizeOf(Draft));
    if (request.expected_image) |bytes| size = try capacityAdd(size, bytes.len);
    return size;
}

fn capacityAdd(first: u64, second: u64) !u64 {
    return std.math.add(u64, first, second) catch error.WorkOverflow;
}

fn capacityMul(first: u64, second: u64) !u64 {
    return std.math.mul(u64, first, second) catch error.WorkOverflow;
}

fn addBound(size: *u64, additional: usize, limit: u32) !void {
    size.* = std.math.add(u64, size.*, additional) catch return error.RecordOverflow;
    if (size.* > limit) return error.RecordLimit;
}

fn allocateEpoch() !u64 {
    var expected = next_epoch.load(.monotonic);
    for (0..1024) |_| {
        if (expected == std.math.maxInt(u64)) return error.GenerationOverflow;
        if (next_epoch.cmpxchgWeak(expected, expected + 1, .monotonic, .monotonic)) |actual| {
            expected = actual;
        } else return expected;
    }
    return error.EpochContention;
}

fn cloneGate(allocator: std.mem.Allocator, gate: Gate) !Gate {
    const name = try allocator.dupe(u8, gate.identity.name);
    errdefer allocator.free(name);
    return .{
        .identity = .{ .name = name, .version = gate.identity.version },
        .definition = try allocator.dupe(u8, gate.definition),
        .scratch_bytes = gate.scratch_bytes,
        .run = gate.run,
    };
}

fn freeGate(allocator: std.mem.Allocator, gate: Gate) void {
    allocator.free(gate.identity.name);
    allocator.free(gate.definition);
}

fn encodeManifest(allocator: std.mem.Allocator, contract: KindContract) ![]u8 {
    var writer = record.Writer.init(allocator);
    defer writer.deinit();
    try writer.writeInt(u32, record.schema_version);
    try writeVersion(&writer, contract.identity);
    try writeGate(&writer, contract.schema);
    try writer.writeCount(contract.gates.len);
    for (contract.gates, 0..) |gate, index| {
        if (gate.identity.eql(contract.schema.identity)) return error.DuplicateGate;
        for (contract.gates[0..index]) |previous| {
            if (std.mem.eql(u8, gate.identity.name, previous.identity.name)) {
                return error.DuplicateGate;
            }
        }
        try writeGate(&writer, gate);
    }
    return writer.finish();
}

fn writeVersion(writer: *record.Writer, identity: record.Version) !void {
    if (identity.version == 0 or identity.name.len == 0) return error.InvalidVersion;
    try writer.writeString(identity.name);
    try writer.writeInt(u32, identity.version);
}

fn writeGate(writer: *record.Writer, gate: Gate) !void {
    if (gate.definition.len == 0) return error.MissingGateContract;
    try writeVersion(writer, gate.identity);
    try writer.writeBlob(gate.definition);
    try writer.writeInt(u32, gate.scratch_bytes);
}

fn digest(bytes: []const u8) [32]u8 {
    var value: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &value, .{});
    return value;
}

fn storage(handle: *Store) *Storage {
    return @ptrCast(@alignCast(handle));
}

fn entry(handle: *const Revision) *const Entry {
    return @ptrCast(@alignCast(handle));
}

fn kindData(handle: *const Kind) *const KindData {
    return @ptrCast(@alignCast(handle));
}

fn draft(handle: *Builder) *Draft {
    return @ptrCast(@alignCast(handle));
}

const test_limits = Limits{
    .revisions = 8,
    .kinds = 4,
    .builders = 4,
    .compiler_manifests = 2,
    .record_bytes = 16 * 1024,
    .gate_scratch_bytes = 1024,
    .candidate_count = 8,
    .screening_bytes = 16 * 1024,
};

const test_work = receipt.Limits{
    .allowance = receipt.WorkVector.uniform(4 * 1024 * 1024),
    .workspace = 1024 * 1024,
    .events = 32,
};

fn testSchema(input: GateInput, scratch: []u8) !record.EntityCounts {
    if (scratch.len < 8) return error.OutOfMemory;
    scratch[0] = 0;
    if (input.exact.image.len == 0) return error.InvalidImage;
    if (input.exact.image[0] != 'v') return error.UnencodableProduct;
    var counts: record.EntityCounts = @splat(0);
    counts[@backingInt(record.Namespace.root)] = 1;
    return counts;
}

fn testContract() KindContract {
    return .{
        .identity = .{ .name = "test-kind", .version = 1 },
        .schema = .{
            .identity = .{ .name = "test-schema", .version = 1 },
            .definition = "v prefix; one root",
            .scratch_bytes = 8,
            .run = testSchema,
        },
        .gates = &.{},
    };
}

const test_options = "default=expanded";
const test_manifest = "exact compiled inputs";

fn testRequest(kind: *const Kind) Request {
    return .{
        .kind = kind,
        .address = .{ .producer = "test", .source = "source", .stage = "image", .variant = "" },
        .inputs = .{
            .compiler_manifest = test_manifest,
            .versions = &.{.{ .name = "codec", .version = 1 }},
            .pipeline = &.{},
            .options = test_options,
            .policy = "strict",
        },
    };
}

fn testPublish(owner: *Store, kind: *const Kind, bytes: []const u8) !*const Revision {
    const builder = try owner.begin(testRequest(kind), test_work);
    errdefer if (builder.abort(.rejected)) |failure| {
        var owned = failure;
        owned.deinit();
    };
    try builder.capture(bytes, &.{});
    return builder.seal(kind);
}

const TestSuccessor = struct {
    kind: *const Kind,
    source: *const Revision,
    role: []const u8 = "input",
    options: []const u8 = test_options,

    fn eqlRequest(left: TestSuccessor, right: TestSuccessor) bool {
        return left.kind == right.kind and std.mem.eql(u8, left.role, right.role) and
            std.mem.eql(u8, left.options, right.options) and left.source.eql(right.source);
    }
};

fn testBeginSuccessor(owner: *Store, successor: TestSuccessor) !*Builder {
    var request = testRequest(successor.kind);
    request.inputs.options = successor.options;
    const dependencies = [_]Dependency{.{ .role = successor.role, .revision = successor.source }};
    request.dependencies = &dependencies;
    return owner.begin(request, test_work);
}

fn testPublishSuccessor(owner: *Store, successor: TestSuccessor) !*const Revision {
    const builder = try testBeginSuccessor(owner, successor);
    errdefer if (builder.abort(.rejected)) |failure| {
        var owned = failure;
        owned.deinit();
    };
    try builder.capture("valid-successor", &.{});
    return builder.seal(successor.kind);
}

const test_closure = record.ClosureBounds{ .bytes = 16 * 1024, .records = 32, .depth = 8 };

fn recordAllocationScenario(allocator: std.mem.Allocator, bytes: []const u8) !void {
    const owner = try Store.create(allocator, test_limits);
    defer owner.release();
    errdefer std.debug.assert(storage(owner).record_count == 0);
    const imported = try owner.importRecord(bytes, test_manifest, test_closure);
    imported.release();
}

fn collidingDigest(_: []const u8) [32]u8 {
    return @splat(7);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    const owner = try Store.create(allocator, test_limits);
    defer owner.release();
    const kind = try owner.register(testContract());
    owner.freeze();
    errdefer std.debug.assert(owner.publicationCount() == 0);
    const result = try testPublish(owner, kind, "valid");
    defer result.release();
    try std.testing.expectEqual(1, owner.publicationCount());
}

fn dependencyAllocationScenario(allocator: std.mem.Allocator, foreign: bool) !void {
    const owner = try Store.create(allocator, test_limits);
    defer owner.release();
    const kind = try owner.register(testContract());
    owner.freeze();
    const source_owner = if (foreign) try Store.create(allocator, test_limits) else owner;
    defer if (foreign) source_owner.release();
    const source_kind = if (foreign) try source_owner.register(testContract()) else kind;
    if (foreign) source_owner.freeze();
    const source = try testPublish(source_owner, source_kind, "valid");
    defer source.release();
    const published = owner.publicationCount();
    errdefer std.debug.assert(owner.publicationCount() == published);
    const successor = try testPublishSuccessor(owner, .{ .kind = kind, .source = source });
    defer successor.release();
    try successor.requireDependency("input", source);
    try std.testing.expectEqual(published + 1, owner.publicationCount());
}

const test_pipeline = [_]record.Version{.{ .name = "producer", .version = 1 }};

fn runTestProducer(builder: *Builder) !void {
    const work = builder.accounting();
    const pass = try work.begin(.pass, .{
        .identity = test_pipeline[0],
        .work = .{ .structural_visits = 5, .rewrite_attempts = 3 },
        .workspace = 100,
    });
    errdefer work.finish(pass, .rejected, .{}) catch {};
    const analysis = try work.begin(.analysis, .{
        .identity = .{ .name = "analysis", .version = 1 },
        .work = .{ .structural_visits = 2, .analysis_computations = 1 },
        .workspace = 100,
    });
    try work.finish(analysis, .success, .{ .counters = .{ .analysis_misses = 1 } });
    try work.finish(pass, .success, .{ .counters = .{ .pass_runs = 1 } });
}

const WorkObservation = struct {
    outcome: receipt.Outcome,
    charged: receipt.WorkVector,
    executed: receipt.Executed,

    fn from(work: receipt.WorkReceiptV1) WorkObservation {
        return .{ .outcome = work.outcome, .charged = work.charged, .executed = work.executed };
    }
};

const TestCandidate = union(enum) { cold, warm: *const Revision, restored: []const u8 };

fn workAttempt(budget: receipt.Limits, candidate: TestCandidate) !WorkObservation {
    const owner = try Store.create(std.testing.allocator, test_limits);
    defer owner.release();
    const kind = try owner.register(testContract());
    owner.freeze();
    var request = testRequest(kind);
    request.inputs.pipeline = &test_pipeline;
    const builder = try owner.begin(request, budget);
    if (candidate == .warm) {
        var reused = (builder.admitReuse(candidate.warm) catch |err| {
            return failedAttempt(builder, err);
        }) orelse return failedAttempt(builder, error.UnexpectedCacheMiss);
        defer reused.deinit();
        return WorkObservation.from(reused.work);
    }
    if (candidate == .restored) {
        try std.testing.expect(try builder.screenRestored(candidate.restored, test_manifest));
    }
    runTestProducer(builder) catch |err| return failedAttempt(builder, err);
    builder.capture("valid", &.{}) catch |err| return failedAttempt(builder, err);
    const output = builder.seal(kind) catch |err| return failedAttempt(builder, err);
    defer output.release();
    return WorkObservation.from(output.view().work);
}

fn failedAttempt(builder: *Builder, err: anyerror) !WorkObservation {
    var failure = builder.abort(.rejected) orelse return error.MissingFailureReceipt;
    defer failure.deinit();
    if (err != error.WorkExhausted) return err;
    return WorkObservation.from(failure.work);
}

fn baselineWorkRevision(owner: *Store, kind: *const Kind) !*const Revision {
    var request = testRequest(kind);
    request.inputs.pipeline = &test_pipeline;
    const builder = try owner.begin(request, test_work);
    errdefer if (builder.abort(.rejected)) |failure| {
        var owned = failure;
        owned.deinit();
    };
    try runTestProducer(builder);
    try builder.capture("valid", &.{});
    return builder.seal(kind);
}

const WorkspaceReuseCase = struct {
    workspace: u64 = test_work.workspace,
    scratch: u32 = test_limits.gate_scratch_bytes,
    reuse: bool = false,
};

fn checkWorkspaceCandidate(candidate: *const Revision, request: WorkspaceReuseCase) !void {
    var limits = test_limits;
    limits.gate_scratch_bytes = request.scratch;
    const owner = try Store.create(std.testing.allocator, limits);
    defer owner.release();
    const kind = try owner.register(testContract());
    owner.freeze();
    var input = testRequest(kind);
    input.inputs.pipeline = &test_pipeline;
    var budget = test_work;
    budget.workspace = request.workspace;
    budget.allowance = receipt.WorkVector.uniform(8 * 1024 * 1024);
    const builder = try owner.begin(input, budget);
    var open = true;
    defer if (open) {
        var failure = builder.abort(.rejected).?;
        failure.deinit();
    };
    const charged = builder.accounting().view().charged;
    if (try builder.admitReuse(candidate)) |value| {
        open = false;
        var reused = value;
        defer reused.deinit();
        try std.testing.expect(request.reuse);
        try std.testing.expectEqual(@as(u64, 0), reused.work.executed.counters.pass_runs);
        try std.testing.expect(candidate.eql(reused.revision));
        return;
    }
    try std.testing.expect(!request.reuse);
    const before = builder.accounting().view();
    try std.testing.expectEqual(.running, before.outcome);
    try std.testing.expectEqualDeep(charged, before.charged);
    try std.testing.expectEqual(@as(usize, 4), before.events.len);
    try std.testing.expectEqual(@as(u64, 0), before.executed.counters.pass_runs);
    try std.testing.expectEqual(
        candidate.view().semantic_record.len,
        before.events[0].executed.work.input_bytes,
    );
    {
        const lease = try builder.acquireWorkspace(.producer);
        defer lease.release();
        try std.testing.expectEqual(request.workspace - request.scratch, lease.bytes().len);
    }
    try runTestProducer(builder);
    try builder.capture("valid", &.{});
    const result = try builder.seal(kind);
    open = false;
    defer result.release();
    try std.testing.expect(candidate.eql(result));
    try std.testing.expectEqual(@as(u64, 1), result.view().work.executed.counters.pass_runs);
}
