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

    /// Records `fact` by copying the record, not the bytes its slices name.
    ///
    /// EVERY SLICE IN A FACT IS BORROWED. A global's name, a state key and a failure name must
    /// stay unchanged and alive for as long as any summary holds the fact, as a string literal
    /// and an interned attribute's payload do. This binds the static facts of a `Spec` too.
    /// A label formatted into a local buffer dangles once the enumerator returns. A label in
    /// scratch the enumerator writes again makes every fact that borrowed it read the last
    /// one written, and a later comparison against a fresh declaration cannot see that, since
    /// both name the same address and length.
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
    pub fn valueResults(self: *Collector, subject: EffectSubject) void {
        for (0..subject.resultCount()) |index| {
            self.append(.{ .result = .{ .index = index, .ownership = .none } });
        }
    }
};

/// The one place a declaration may read an operand's literal from: the named attribute of the
/// operation that defines the operand, when that operation has the named name.
pub const LiteralSource = struct {
    operation: []const u8,
    attribute: []const u8,
    /// The dialect attribute kind `operandLiteralBytes` requires of the attribute.
    payload_kind: ?[]const u8 = null,
};

/// The attribute `source` names for operand `index` of `op`, or null when the operand is not
/// defined by the named operation or that operation lacks the attribute.
///
/// The subject's literal accessors and the revision of a cached summary both resolve through
/// this, so they cannot disagree about which attribute a literal is.
pub fn literalAttribute(
    op: *const ir.Operation,
    index: usize,
    source: LiteralSource,
) ?ir.Attribute {
    if (index >= op.operands.items.len) return null;
    const raw = op.operands.items[index].value.getDefiningOp() orelse return null;
    const definition: *const ir.Operation = @ptrCast(@alignCast(raw));
    if (!std.mem.eql(u8, definition.name.name, source.operation)) return null;
    return definition.getAttr(source.attribute);
}

/// What an enumerator receives in place of its operation: the operation's own declared fields,
/// and the literal its declaration named a source for.
///
/// THE CONTRACT IS PURITY, AND THIS TYPE DOES NOT ENFORCE IT. An enumerator is a pure,
/// deterministic function of the data this subject admits. It looks nothing up outside the
/// subject, does not re-enter the IR, mutates nothing, reads no mutable global or thread-local,
/// and takes no authority through an attribute's or a type's interface. The subject removes the
/// ordinary path from an operation to its parent, its children and its operands' definitions,
/// since no method takes or returns an operation, block, region or value. It does not sandbox
/// the function: `attr`, `attrAs`, `operandType` and `resultType` return handles that reach
/// interface dispatch and the context's registries, and a global reaches anything. A cached
/// summary therefore still replays every declaration before it trusts itself, and a one-shot
/// answer still rests on this contract for the time it takes to build.
pub const EffectSubject = struct {
    handle: *const Handle,
    literal: ?LiteralSource,

    const Handle = opaque {};

    fn of(op: *const ir.Operation, literal: ?LiteralSource) EffectSubject {
        return .{ .handle = @ptrCast(op), .literal = literal };
    }

    fn operation(self: EffectSubject) *const ir.Operation {
        return @ptrCast(@alignCast(self.handle));
    }

    pub fn name(self: EffectSubject) []const u8 {
        return self.operation().name.name;
    }

    pub fn attr(self: EffectSubject, attribute: []const u8) ?ir.Attribute {
        return self.operation().getAttr(attribute);
    }

    pub fn attrAs(self: EffectSubject, comptime T: type, attribute: []const u8) ?*const T {
        return self.operation().getAttrAs(T, attribute);
    }

    pub fn operandCount(self: EffectSubject) usize {
        return self.operation().getNumOperands();
    }

    pub fn resultCount(self: EffectSubject) usize {
        return self.operation().getNumResults();
    }

    pub fn regionCount(self: EffectSubject) usize {
        return self.operation().getNumRegions();
    }

    pub fn operandType(self: EffectSubject, index: usize) ir.Type {
        return self.operation().operands.items[index].value.type;
    }

    pub fn resultType(self: EffectSubject, index: usize) ir.Type {
        return self.operation().results.items[index].type;
    }

    pub fn arithmeticPolicy(self: EffectSubject) ArithmeticPolicy {
        return self.operation().getContext().arithmetic_policy;
    }

    /// The integer the declared literal source gives operand `index`, or null.
    pub fn operandLiteralInt(self: EffectSubject, index: usize) ?i64 {
        const attribute = self.literalOf(index) orelse return null;
        return (attribute.cast(ir.Attribute.IntegerAttr) orelse return null).getValue();
    }

    /// The float the declared literal source gives operand `index`, or null.
    pub fn operandLiteralFloat(self: EffectSubject, index: usize) ?f64 {
        const attribute = self.literalOf(index) orelse return null;
        return (attribute.cast(ir.Attribute.FloatAttr) orelse return null).getValue();
    }

    /// The interned bytes the declared literal source gives operand `index`, or null. The
    /// attribute must have the dialect attribute kind the source names.
    pub fn operandLiteralBytes(self: EffectSubject, index: usize) ?[]const u8 {
        const source = self.literal orelse return null;
        const kind = source.payload_kind orelse return null;
        const attribute = self.literalOf(index) orelse return null;
        if (!std.mem.eql(u8, attribute.abstract.name, kind)) return null;
        return (attribute.cast(ir.Attribute.DialectAttr) orelse return null).payload;
    }

    fn literalOf(self: EffectSubject, index: usize) ?ir.Attribute {
        return literalAttribute(self.operation(), index, self.literal orelse return null);
    }
};

/// What a registration declares. `facts` and every slice an enumerator appends are borrowed
/// under the lifetime rule on `Collector.append`.
pub const Spec = struct {
    facts: []const Fact = &.{},
    complete: bool = false,
    capacity: Capacity = .{},
    literal: ?LiteralSource = null,
    enumerate: ?*const fn (EffectSubject, *Collector) void = null,
};

pub const EffectOpInterface = struct {
    pub const interface_name = "ir.interface.effects";
    pub const id = interfaces.interfaceId(interface_name);

    /// A declaration as data. Nothing in it receives an operation: `collect` builds the
    /// subject and hands that to `enumerate`. Its facts are borrowed under the lifetime rule
    /// on `Collector.append`.
    pub const VTable = struct {
        capacity: Capacity,
        facts: []const Fact = &.{},
        complete: bool = false,
        literal: ?LiteralSource = null,
        enumerate: ?*const fn (EffectSubject, *Collector) void = null,

        pub fn collect(self: *const VTable, op: *const ir.Operation, collector: *Collector) void {
            collector.complete = self.complete;
            for (self.facts) |fact| collector.append(fact);
            const enumerate = self.enumerate orelse return;
            enumerate(EffectSubject.of(op, self.literal), collector);
        }
    };

    pub fn entry(vtable: *const VTable) interfaces.InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn entryFor(comptime spec: Spec) interfaces.InterfaceEntry {
        const Implementation = struct {
            const vtable = VTable{
                .capacity = .{
                    .entries = spec.facts.len + spec.capacity.entries,
                    .per_operand = spec.capacity.per_operand,
                    .per_result = spec.capacity.per_result,
                    .per_region = spec.capacity.per_region,
                },
                .facts = spec.facts,
                .complete = spec.complete,
                .literal = spec.literal,
                .enumerate = spec.enumerate,
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

/// A question one operation answers from its own declared facts.
pub const Question = enum { discard, repeatable };

/// Whether `op`'s own declared facts answer `question`, read without storage.
///
/// NO ALLOCATOR REACHES THE ANSWER. `inspect` stores the records, so asking
/// through it can fail for want of bytes, and a caller that folds that failure
/// into "no" builds a different program under a smaller budget and reports
/// nothing. This replays the enumeration through an observer, as `verify`
/// does, and judges each record as it is visited. The answer is a function of
/// the operation alone, with no bound to outgrow.
///
/// THE FOLD IS EXACT. Under `complete`, `discard` and `repeatableExpression`
/// are conjunctions of one condition per record, so judging each record alone
/// and joining the verdicts gives the answer the stored records give. A count
/// that overflows, a shape `verify` refuses, and an enumeration that is
/// incomplete or outruns its capacity answer false, as `inspect` does.
pub fn answers(op: *ir.Operation, comptime question: Question) bool {
    const vtable = op.getInterface(EffectOpInterface) orelse return false;
    const limit = vtable.capacity.count(
        op.getNumOperands(),
        op.getNumResults(),
        op.getNumRegions(),
    ) orelse return false;
    verify(op) catch return false;
    const Judgment = Judge(question);
    var judgment = Judgment{};
    var collector = Collector{
        .storage = &.{},
        .observer = .{ .context = &judgment, .limit = limit, .visit = Judgment.visit },
    };
    vtable.collect(op, &collector);
    return collector.complete and !collector.exhausted and judgment.holds;
}

fn Judge(comptime question: Question) type {
    return struct {
        holds: bool = true,

        fn visit(raw: *anyopaque, fact: Fact) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const records = [_]Fact{fact};
            const one = Facts{ .records = &records, .complete = true };
            const holds = switch (question) {
                .discard => discard(one),
                .repeatable => repeatableExpression(one),
            };
            self.holds = self.holds and holds;
        }
    };
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

fn testEnumerateValues(subject: EffectSubject, collector: *Collector) void {
    collector.valueResults(subject);
    collector.complete = subject.attr("incomplete") == null;
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

/// Whether `T` is `Target` or an optional, pointer, slice or array of it.
fn reaches(comptime T: type, comptime Target: type) bool {
    if (T == Target) return true;
    return switch (@typeInfo(T)) {
        .optional => |optional| reaches(optional.child, Target),
        .pointer => |pointer| reaches(pointer.child, Target),
        .array => |array| reaches(array.child, Target),
        else => false,
    };
}
