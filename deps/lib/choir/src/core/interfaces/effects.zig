const std = @import("std");
const ir = @import("../root.zig");
const interfaces = @import("root.zig");

/// Shared premise for value-level floating operations, independent of any dialect.
pub const ArithmeticPolicy = struct {
    exceptions_masked: bool = true,
    default_rounding: bool = true,
    environment_observable: bool = false,

    pub fn permitsFloatingValues(self: ArithmeticPolicy) bool {
        return self.exceptions_masked and self.default_rounding and !self.environment_observable;
    }
};

pub const ContextPremise = enum { floating_environment };

/// Subjects are local to the declaring operation. Different SSA values may alias.
pub const Subject = union(enum) {
    operation,
    operand: usize,
    result: usize,
    global: []const u8,
    region: usize,
};

pub const Footprint = struct {
    offset: u64,
    length: u64,
};

pub const Scope = union(enum) {
    unknown,
    operation,
    region: usize,
    named: []const u8,
};

pub const Resource = struct {
    subject: Subject = .operation,
    address_space: ?u32 = null,
    bytes: ?Footprint = null,
    alias_scope: Scope = .unknown,
    lifetime: Scope = .unknown,
    allocator_domain: ?[]const u8 = null,
    ordering_scope: Scope = .unknown,
    state_key: ?[]const u8 = null,
};

pub const EventKind = enum {
    read,
    write,
    failure,
    trap,
    diverge,
    allocate,
    free,
    retain,
    release,
    borrow,
    move,
    foreign,
    io,
    state_observe,
    state_update,
    state_draw,
    state_memo,
    launch,
    synchronize,
};

pub const Event = struct {
    kind: EventKind,
    resource: Resource = .{},
    /// Atomic and volatile accesses are ordered even if their value is unused.
    ordered: bool = false,
    failure_name: ?[]const u8 = null,
};

pub const RequirementKind = enum {
    nonzero,
    quotient_representable,
    in_bounds,
    live,
    terminates,
    execution_context,
    conversion_representable,
    callee_contract,
};

/// A requirement is a premise to prove at the use, never a producer-supplied proof.
pub const Requirement = struct {
    kind: RequirementKind,
    subject: Subject,
    related: ?Subject = null,
};

pub const Ownership = enum { none, owned, borrowed, transferred, unknown };

pub const ResultFact = struct {
    index: usize,
    fresh_identity: bool = false,
    alias: ?Subject = null,
    ownership: Ownership = .unknown,
    lifetime: Scope = .unknown,
};

pub const Execution = enum { immediate, conditional, repeated, latent, unknown };

pub const RegionFact = struct {
    index: usize,
    execution: Execution = .unknown,
    /// Repetition is not a termination proof, even when every child is total.
    may_diverge: bool = true,
    captures: bool = true,
};

pub const Binding = struct {
    region: usize,
    argument: usize,
    source: Subject,
};

/// Order in this sequence is event order within the operation, not set membership.
pub const Fact = union(enum) {
    event: Event,
    requirement: Requirement,
    result: ResultFact,
    region: RegionFact,
    binding: Binding,
    premise: ContextPremise,
};

pub const Facts = struct {
    records: []const Fact = &.{},
    complete: bool = false,
};

/// Contract entries and arity determine storage before enumeration. No growth occurs.
pub const Capacity = struct {
    entries: usize = 0,
    per_operand: usize = 0,
    per_result: usize = 0,
    per_region: usize = 0,

    pub fn count(self: Capacity, operands: usize, results: usize, regions: usize) ?usize {
        var record_count = self.entries;
        const counts = [_]usize{ operands, results, regions };
        const rates = [_]usize{ self.per_operand, self.per_result, self.per_region };
        for (counts, rates) |n, rate| {
            const increment = std.math.mul(usize, n, rate) catch return null;
            record_count = std.math.add(usize, record_count, increment) catch return null;
        }
        return record_count;
    }
};

pub const Collector = struct {
    storage: []Fact,
    used: usize = 0,
    complete: bool = false,
    exhausted: bool = false,
    observer: ?Observer = null,

    const Observer = struct {
        context: *anyopaque,
        limit: usize,
        visit: *const fn (*anyopaque, Fact) void,
    };

    pub fn append(self: *Collector, fact: Fact) void {
        if (self.observer) |observer| {
            if (self.used == observer.limit) {
                self.exhausted = true;
                return;
            }
            observer.visit(observer.context, fact);
            self.used += 1;
            return;
        }
        std.debug.assert(self.used <= self.storage.len);
        if (self.used == self.storage.len) {
            self.exhausted = true;
            return;
        }
        self.storage[self.used] = fact;
        self.used += 1;
        std.debug.assert(self.used <= self.storage.len);
    }

    pub fn view(self: *const Collector) Facts {
        if (self.observer != null) return .{};
        return .{
            .records = self.storage[0..self.used],
            .complete = self.complete and !self.exhausted,
        };
    }

    /// Scalar value results carry no identity or ownership. This does not assert completeness.
    pub fn valueResults(self: *Collector, op: *const ir.Operation) void {
        for (0..op.getNumResults()) |index| {
            self.append(.{ .result = .{ .index = index, .ownership = .none } });
        }
    }
};

pub const Spec = struct {
    facts: []const Fact = &.{},
    complete: bool = false,
    capacity: Capacity = .{},
    enumerate: ?*const fn (*const ir.Operation, *Collector) void = null,
};

pub const EffectOpInterface = struct {
    pub const interface_name = "ir.interface.effects";
    pub const id = interfaces.interfaceId(interface_name);

    pub const VTable = struct {
        capacity: Capacity,
        collect: *const fn (*const anyopaque, *Collector) void,
    };

    pub fn entry(vtable: *const VTable) interfaces.InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn entryFor(comptime spec: Spec) interfaces.InterfaceEntry {
        const Implementation = struct {
            fn collect(raw: *const anyopaque, collector: *Collector) void {
                const op: *const ir.Operation = @ptrCast(@alignCast(raw));
                collector.complete = spec.complete;
                for (spec.facts) |fact| collector.append(fact);
                if (spec.enumerate) |enumerate| enumerate(op, collector);
            }

            const vtable = VTable{
                .capacity = .{
                    .entries = spec.facts.len + spec.capacity.entries,
                    .per_operand = spec.capacity.per_operand,
                    .per_result = spec.capacity.per_result,
                    .per_region = spec.capacity.per_region,
                },
                .collect = collect,
            };
        };
        return entry(&Implementation.vtable);
    }
};

pub const Declaration = struct {
    storage: []Fact = &.{},
    facts: Facts = .{},
    exhausted: bool = false,

    pub fn deinit(self: *Declaration, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = .{};
    }
};

pub fn inspect(allocator: std.mem.Allocator, op: *ir.Operation) !Declaration {
    const vtable = op.getInterface(EffectOpInterface) orelse return .{};
    const count = vtable.capacity.count(
        op.getNumOperands(),
        op.getNumResults(),
        op.getNumRegions(),
    ) orelse return .{ .exhausted = true };
    const storage = try allocator.alloc(Fact, count);
    errdefer allocator.free(storage);
    var collector = Collector{ .storage = storage };
    vtable.collect(op, &collector);
    try validate(op, collector.view());
    return .{ .storage = storage, .facts = collector.view(), .exhausted = collector.exhausted };
}

/// Collect into caller-admitted storage. Recollect after every semantic edit.
pub fn collectInto(op: *ir.Operation, storage: []Fact) !Facts {
    const vtable = op.getInterface(EffectOpInterface) orelse return .{};
    var collector = Collector{ .storage = storage };
    vtable.collect(op, &collector);
    try validate(op, collector.view());
    return collector.view();
}

pub const ShapeError = error{
    InvalidEffectPremise,
    InvalidEffectSubject,
    InvalidEffectFootprint,
    InvalidEffectScope,
    InvalidEffectResult,
    InvalidEffectRegion,
    InvalidEffectBinding,
    DuplicateEffectResult,
    DuplicateEffectRegion,
    DuplicateEffectBinding,
    MissingEffectResult,
    MissingEffectRegion,
    ContradictoryEffectResult,
};

fn validateSubject(op: *const ir.Operation, subject: Subject) ShapeError!void {
    const valid = switch (subject) {
        .operation => true,
        .operand => |index| index < op.getNumOperands(),
        .result => |index| index < op.getNumResults(),
        .global => |name| name.len > 0,
        .region => |index| index < op.getNumRegions(),
    };
    if (!valid) return error.InvalidEffectSubject;
}

fn validateScope(op: *const ir.Operation, scope: Scope) ShapeError!void {
    switch (scope) {
        .unknown, .operation => {},
        .region => |index| if (index >= op.getNumRegions()) return error.InvalidEffectScope,
        .named => |name| if (name.len == 0) return error.InvalidEffectScope,
    }
}

fn validateResource(op: *const ir.Operation, resource: Resource) ShapeError!void {
    try validateSubject(op, resource.subject);
    try validateScope(op, resource.alias_scope);
    try validateScope(op, resource.lifetime);
    try validateScope(op, resource.ordering_scope);
    if (resource.bytes) |bytes| {
        _ = std.math.add(u64, bytes.offset, bytes.length) catch return error.InvalidEffectFootprint;
    }
    if (resource.allocator_domain) |name| {
        if (name.len == 0) return error.InvalidEffectScope;
    }
    if (resource.state_key) |name| {
        if (name.len == 0) return error.InvalidEffectScope;
    }
}

fn validateResult(op: *const ir.Operation, fact: ResultFact) ShapeError!void {
    if (fact.index >= op.getNumResults()) return error.InvalidEffectResult;
    try validateScope(op, fact.lifetime);
    if (fact.alias) |alias| {
        try validateSubject(op, alias);
        if (fact.fresh_identity) return error.ContradictoryEffectResult;
        switch (alias) {
            .result => |index| if (index == fact.index) return error.ContradictoryEffectResult,
            .operand, .global => {},
            .operation, .region => return error.ContradictoryEffectResult,
        }
    }
    if (fact.fresh_identity and fact.ownership == .borrowed) {
        return error.ContradictoryEffectResult;
    }
}

fn validateFact(op: *const ir.Operation, fact: Fact) ShapeError!void {
    switch (fact) {
        .premise => switch (fact.premise) {
            .floating_environment => {
                if (!op.getContext().arithmetic_policy.permitsFloatingValues()) {
                    return error.InvalidEffectPremise;
                }
            },
        },
        .event => |event| try validateResource(op, event.resource),
        .requirement => |requirement| {
            try validateSubject(op, requirement.subject);
            if (requirement.related) |related| try validateSubject(op, related);
        },
        .result => |result| try validateResult(op, result),
        .region => |region| {
            if (region.index >= op.getNumRegions()) return error.InvalidEffectRegion;
        },
        .binding => |binding| {
            if (binding.region >= op.getNumRegions()) return error.InvalidEffectBinding;
            const region = &op.regions.items[binding.region];
            const block = region.blocks.head orelse return error.InvalidEffectBinding;
            if (binding.argument >= block.arguments.items.len) return error.InvalidEffectBinding;
            try validateSubject(op, binding.source);
        },
    }
}

pub fn validate(op: *const ir.Operation, facts: Facts) ShapeError!void {
    for (facts.records, 0..) |fact, index| {
        try validateFact(op, fact);
        for (facts.records[0..index]) |prior| {
            try validatePair(fact, prior);
        }
    }
    if (!facts.complete) return;
    for (0..op.getNumResults()) |index| {
        if (!hasResult(facts, index)) return error.MissingEffectResult;
    }
    for (0..op.getNumRegions()) |index| {
        if (!hasRegion(facts, index)) return error.MissingEffectRegion;
    }
}

fn hasResult(facts: Facts, index: usize) bool {
    for (facts.records) |fact| {
        if (fact == .result and fact.result.index == index) return true;
    }
    return false;
}

fn hasRegion(facts: Facts, index: usize) bool {
    for (facts.records) |fact| {
        if (fact == .region and fact.region.index == index) return true;
    }
    return false;
}

fn validatePair(fact: Fact, prior: Fact) ShapeError!void {
    if (fact == .result and prior == .result and fact.result.index == prior.result.index) {
        return error.DuplicateEffectResult;
    }
    if (fact == .binding and prior == .binding and fact.binding.region == prior.binding.region and
        fact.binding.argument == prior.binding.argument) return error.DuplicateEffectBinding;
    if (fact == .region and prior == .region and fact.region.index == prior.region.index) {
        return error.DuplicateEffectRegion;
    }
}

const Verification = struct {
    op: *ir.Operation,
    vtable: *const EffectOpInterface.VTable,
    limit: usize,
    seen: usize = 0,
    results: usize = 0,
    regions: usize = 0,
    failure: ?ShapeError = null,

    fn visit(raw: *anyopaque, fact: Fact) void {
        const self: *Verification = @ptrCast(@alignCast(raw));
        if (self.failure != null) return;
        self.check(fact) catch |err| {
            self.failure = err;
        };
    }

    fn check(self: *Verification, fact: Fact) ShapeError!void {
        try validateFact(self.op, fact);
        var prior = PriorFacts{ .fact = fact };
        var collector = Collector{
            .storage = &.{},
            .observer = .{ .context = &prior, .limit = self.seen, .visit = PriorFacts.visit },
        };
        self.vtable.collect(self.op, &collector);
        if (prior.failure) |err| return err;
        if (fact == .result) self.results += 1;
        if (fact == .region) self.regions += 1;
        self.seen += 1;
        std.debug.assert(self.seen <= self.limit);
    }
};

const PriorFacts = struct {
    fact: Fact,
    failure: ?ShapeError = null,

    fn visit(raw: *anyopaque, prior: Fact) void {
        const self: *PriorFacts = @ptrCast(@alignCast(raw));
        validatePair(self.fact, prior) catch |err| {
            self.failure = err;
        };
    }
};

/// Shape checking replays bounded, read-only enumeration without allocating.
/// Each record is checked against its preceding records; no shared IR scratch is touched.
pub fn verify(op: *ir.Operation) ShapeError!void {
    const vtable = op.getInterface(EffectOpInterface) orelse return;
    const limit = vtable.capacity.count(
        op.getNumOperands(),
        op.getNumResults(),
        op.getNumRegions(),
    ) orelse return;
    var verification = Verification{ .op = op, .vtable = vtable, .limit = limit };
    var collector = Collector{
        .storage = &.{},
        .observer = .{ .context = &verification, .limit = limit, .visit = Verification.visit },
    };
    vtable.collect(op, &collector);
    if (verification.failure) |err| return err;
    if (!collector.complete or collector.exhausted) return;
    if (verification.results != op.getNumResults()) return error.MissingEffectResult;
    if (verification.regions != op.getNumRegions()) return error.MissingEffectRegion;
}

/// T: complete, total, terminating, with only ordinary memory events.
pub fn total(facts: Facts) bool {
    if (!facts.complete) return false;
    for (facts.records) |fact| switch (fact) {
        .event => |event| {
            if (event.ordered) return false;
            if (event.kind != .read and event.kind != .write) return false;
        },
        .requirement => return false,
        .result => |result| {
            if (result.fresh_identity or result.ownership != .none) return false;
        },
        .region => |region| {
            if (region.execution != .latent) return false;
        },
        .binding, .premise => {},
    };
    return true;
}

/// R: no writes or other observable events. Completeness and totality are separate.
pub fn readOnly(facts: Facts) bool {
    if (!facts.complete) return false;
    for (facts.records) |fact| switch (fact) {
        .event => |event| if (event.kind != .read or event.ordered) return false,
        else => {},
    };
    return true;
}

pub fn memoryFree(facts: Facts) bool {
    if (!facts.complete) return false;
    for (facts.records) |fact| {
        if (fact == .event) return false;
    }
    return true;
}

pub const Stability = struct {
    read_values: bool = false,
    execution_context: bool = false,
};

/// S: memory-free total expressions need no read proof; reads require both premises.
pub fn stable(facts: Facts, proof: Stability) bool {
    if (!total(facts)) return false;
    return memoryFree(facts) or (proof.read_values and proof.execution_context);
}

pub fn discard(facts: Facts) bool {
    return total(facts) and readOnly(facts);
}

pub fn duplicate(facts: Facts, proof: Stability) bool {
    return discard(facts) and stable(facts, proof);
}

pub fn speculate(facts_at_destination: Facts, operands_available: bool) bool {
    return operands_available and discard(facts_at_destination);
}

pub fn repeatableExpression(facts: Facts) bool {
    return discard(facts) and memoryFree(facts);
}

pub const Crossing = struct {
    no_dependencies: bool = false,
    concurrency_exclusive: bool = false,
};

/// Caller proves disjointness. Resource labels and different SSA names prove nothing.
pub fn accessConflict(a: Event, b: Event, proven_disjoint: bool) bool {
    if (a.ordered or b.ordered) return true;
    const a_access = a.kind == .read or a.kind == .write;
    const b_access = b.kind == .read or b.kind == .write;
    if (!a_access or !b_access) return true;
    if (a.kind == .read and b.kind == .read) return false;
    return !proven_disjoint;
}

pub fn reorder(a: Facts, b: Facts, crossing: Crossing) bool {
    if (!crossing.no_dependencies or !total(a) or !total(b)) return false;
    if ((!memoryFree(a) or !memoryFree(b)) and !crossing.concurrency_exclusive) return false;
    for (a.records) |left| {
        if (left != .event) continue;
        for (b.records) |right| {
            if (right != .event) continue;
            if (accessConflict(left.event, right.event, false)) return false;
        }
    }
    return true;
}

fn expectNoPermissions(facts: Facts) !void {
    try std.testing.expect(!discard(facts));
    try std.testing.expect(!duplicate(facts, .{ .read_values = true, .execution_context = true }));
    try std.testing.expect(!speculate(facts, true));
    try std.testing.expect(!repeatableExpression(facts));
    try std.testing.expect(!reorder(facts, .{ .complete = true }, .{
        .no_dependencies = true,
        .concurrency_exclusive = true,
    }));
}

test "EffectOpInterface unknown and unresolved requirements deny every permission" {
    try expectNoPermissions(.{});
    try expectNoPermissions(.{ .records = &.{.{ .event = .{ .kind = .read } }} });
    for (std.enums.values(RequirementKind)) |kind| {
        try expectNoPermissions(.{
            .complete = true,
            .records = &.{.{ .requirement = .{ .kind = kind, .subject = .operation } }},
        });
    }
}

test "EffectOpInterface total expressions and safe reads have distinct permissions" {
    const expression = Facts{ .complete = true };
    try std.testing.expect(discard(expression));
    try std.testing.expect(duplicate(expression, .{}));
    try std.testing.expect(speculate(expression, true));
    try std.testing.expect(!speculate(expression, false));
    try std.testing.expect(repeatableExpression(expression));
    const read = Facts{ .complete = true, .records = &.{.{ .event = .{ .kind = .read } }} };
    try std.testing.expect(discard(read));
    try std.testing.expect(speculate(read, true));
    try std.testing.expect(!duplicate(read, .{}));
    try std.testing.expect(!repeatableExpression(read));
    try std.testing.expect(duplicate(read, .{ .read_values = true, .execution_context = true }));
    try std.testing.expect(!duplicate(read, .{ .read_values = true }));
}

test "EffectOpInterface failure ownership allocation state and ordering remain barriers" {
    for (std.enums.values(EventKind)) |kind| {
        if (kind == .read or kind == .write) continue;
        try expectNoPermissions(.{ .complete = true, .records = &.{.{
            .event = .{ .kind = kind },
        }} });
    }
    const ordered_read = Facts{ .complete = true, .records = &.{.{
        .event = .{ .kind = .read, .ordered = true },
    }} };
    try expectNoPermissions(ordered_read);
    const balanced = Facts{ .complete = true, .records = &.{
        .{ .event = .{ .kind = .retain } },
        .{ .event = .{ .kind = .release } },
    } };
    try expectNoPermissions(balanced);
    try expectNoPermissions(.{ .complete = true, .records = &.{.{
        .result = .{ .index = 0, .ownership = .none, .fresh_identity = true },
    }} });
}

test "EffectOpInterface access conflict is symmetric and ignores resource names" {
    const accesses = [_]Event{
        .{ .kind = .read, .resource = .{ .subject = .{ .operand = 0 } } },
        .{ .kind = .write, .resource = .{ .subject = .{ .operand = 1 } } },
        .{ .kind = .read, .resource = .{ .subject = .{ .global = "different" } } },
    };
    for (accesses) |a| for (accesses) |b| {
        const expected = a.kind == .write or b.kind == .write;
        try std.testing.expectEqual(expected, accessConflict(a, b, false));
        try std.testing.expectEqual(accessConflict(a, b, false), accessConflict(b, a, false));
        try std.testing.expect(!accessConflict(a, b, true));
    };
    try std.testing.expect(accessConflict(.{ .kind = .release }, accesses[0], true));
    const read = Facts{ .complete = true, .records = &.{.{ .event = accesses[0] }} };
    try std.testing.expect(!reorder(read, read, .{ .no_dependencies = true }));
    try std.testing.expect(reorder(read, read, .{
        .no_dependencies = true,
        .concurrency_exclusive = true,
    }));
}

test "EffectOpInterface collector derives capacity and preserves event order on overflow" {
    const capacity = Capacity{ .entries = 2, .per_operand = 2, .per_result = 1, .per_region = 3 };
    try std.testing.expectEqual(@as(?usize, 16), capacity.count(3, 2, 2));
    try std.testing.expectEqual(@as(?usize, null), capacity.count(std.math.maxInt(usize), 0, 0));
    var storage: [2]Fact = undefined;
    var collector = Collector{ .storage = &storage, .complete = true };
    collector.append(.{ .event = .{ .kind = .write } });
    collector.append(.{ .event = .{ .kind = .failure } });
    try std.testing.expect(collector.view().complete);
    try std.testing.expectEqual(EventKind.write, collector.view().records[0].event.kind);
    try std.testing.expectEqual(EventKind.failure, collector.view().records[1].event.kind);
    collector.append(.{ .event = .{ .kind = .read } });
    try std.testing.expect(collector.exhausted);
    try std.testing.expectEqual(@as(usize, 2), collector.view().records.len);
    try expectNoPermissions(collector.view());
    var empty = Collector{ .storage = &.{}, .complete = true };
    empty.append(.{ .event = .{ .kind = .failure } });
    try expectNoPermissions(empty.view());
}

fn testEnumerateValues(op: *const ir.Operation, collector: *Collector) void {
    collector.valueResults(op);
    collector.complete = op.getAttr("incomplete") == null;
}

test "EffectOpInterface registers static and dynamic facts through loadDialectSpec" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try ir.dialects.loadDialectSpec(&ctx, .{
        .name = "effects_fixture",
        .operations = &.{
            .{ .name = "effects_fixture.static", .interfaces = &.{EffectOpInterface.entryFor(.{
                .complete = true,
            })} },
            .{ .name = "effects_fixture.dynamic", .interfaces = &.{EffectOpInterface.entryFor(.{
                .capacity = .{ .per_result = 1 },
                .enumerate = testEnumerateValues,
            })} },
        },
    });
    const static = try ctx.createOperation(ir.Operation.State.init(
        "effects_fixture.static",
        .unknown,
    ));
    const dynamic = try ctx.createOperation(ir.Operation.State.init(
        "effects_fixture.dynamic",
        .unknown,
    ));
    for ([_]*ir.Operation{ static, dynamic }) |op| {
        var declaration = try inspect(std.testing.allocator, op);
        defer declaration.deinit(std.testing.allocator);
        try std.testing.expect(discard(declaration.facts));
        try ir.verifyOperation(op, .{});
    }
    try dynamic.setAttr("incomplete", try ctx.getBoolAttr(true));
    var incomplete = try inspect(std.testing.allocator, dynamic);
    defer incomplete.deinit(std.testing.allocator);
    try expectNoPermissions(incomplete.facts);
    try std.testing.expectEqual(
        interfaces.interfaceId("ir.interface.effects"),
        EffectOpInterface.id,
    );
}

fn testResultOperation(ctx: *ir.Context) !*ir.Operation {
    try ctx.allowUnregistered();
    _ = try ctx.registerOperation("effect_result", .{});
    _ = try ctx.registerType("effect_value");
    const typ = try ctx.getDialectTypeFromName("effect_value");
    var state = ir.Operation.State.init("effect_result", .unknown);
    state.addTypes(&.{typ});
    state.addRegion();
    return ctx.createOperation(state);
}

test "EffectOpInterface validates result and region coverage and contradictions" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    const op = try testResultOperation(&ctx);
    const block = try op.getRegion(0).?.addBlock();
    _ = try block.addArgument(op.getResult(0).?.type, .unknown);
    const binding = Fact{ .binding = .{
        .region = 0,
        .argument = 0,
        .source = .{ .global = "argument" },
    } };
    try std.testing.expectError(
        error.DuplicateEffectBinding,
        validate(op, .{ .records = &.{ binding, binding } }),
    );
    const result = Fact{ .result = .{ .index = 0, .ownership = .none } };
    const region = Fact{ .region = .{ .index = 0, .execution = .latent } };
    try validate(op, .{ .complete = true, .records = &.{ result, region } });
    try std.testing.expectError(error.MissingEffectResult, validate(op, .{ .complete = true }));
    try std.testing.expectError(error.MissingEffectRegion, validate(op, .{
        .complete = true,
        .records = &.{result},
    }));
    try std.testing.expectError(error.DuplicateEffectResult, validate(op, .{
        .records = &.{ result, result },
    }));
    try std.testing.expectError(error.InvalidEffectSubject, validate(op, .{ .records = &.{.{
        .event = .{ .kind = .read, .resource = .{ .subject = .{ .operand = 0 } } },
    }} }));
    try std.testing.expectError(error.ContradictoryEffectResult, validate(op, .{ .records = &.{.{
        .result = .{ .index = 0, .fresh_identity = true, .alias = .{ .global = "escaped" } },
    }} }));
    try expectNoPermissions(.{ .complete = true, .records = &.{
        result, .{ .region = .{ .index = 0, .execution = .repeated } },
    } });
}

test "EffectOpInterface normal verifier reports malformed facts and OOM stays an error" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try ctx.registerOperationInterface("effect_bad", EffectOpInterface.entryFor(.{
        .complete = true,
        .facts = &.{.{ .event = .{
            .kind = .read,
            .resource = .{ .subject = .{ .operand = 4 } },
        } }},
    }));
    const op = try ctx.createOperation(ir.Operation.State.init("effect_bad", .unknown));
    try std.testing.expectError(error.InvalidEffectSubject, ir.verifyOperation(op, .{}));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, inspect(failing.allocator(), op));
}

fn testVerifyWithoutScratch(ctx: *ir.Context) !void {
    try ctx.allowUnregistered();
    _ = try ctx.registerOperation("effects.no_scratch", .{});
    try ctx.registerOperationInterface("effects.no_scratch", EffectOpInterface.entryFor(.{
        .complete = true,
        .facts = &.{.{ .event = .{ .kind = .write } }},
    }));
    const op = try ctx.createOperation(ir.Operation.State.init("effects.no_scratch", .unknown));
    const original = op.allocator;
    defer op.allocator = original;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    op.allocator = failing.allocator();
    try verify(op);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "EffectOpInterface verification uses no shared operation scratch" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try testVerifyWithoutScratch(&ctx);
}
