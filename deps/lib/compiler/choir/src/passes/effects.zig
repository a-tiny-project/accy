const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");

const facts = ir.interfaces.effects;

const Dependency = struct {
    op: *ir.Operation,
    revision: []u8,
    declaration: facts.Declaration,
    executes: bool,
    instantiate_body: bool,
};

/// A graph of ordered local declarations bound to exact IR and callee inputs.
/// Nodes retain their local subjects: operand zero in a callee is not operand
/// zero in its caller. Unproved bindings therefore never authorize an action.
pub const EffectSummary = struct {
    allocator: std.mem.Allocator,
    storage: alloc_arena.Arena,
    context: *ir.Context,
    creation_boundary: u31,
    nodes: []Dependency,
    used: usize = 0,
    complete: bool = true,
    /// Room to rewrite one node's revision for comparison, taken once from
    /// this summary's own arena and as wide as the widest revision it holds.
    /// `isCurrent` borrows it so that asking whether a summary is still
    /// current costs no allocation and cannot fail for want of one.
    scratch: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, op: *ir.Operation) !EffectSummary {
        var storage = alloc_arena.Arena.init(allocator);
        errdefer storage.deinit();
        const scratch = storage.allocator();
        const node_count = if (isLeaf(op)) 1 else op.getContext().operationCount();
        var self = EffectSummary{
            .allocator = scratch,
            .storage = undefined,
            .context = op.getContext(),
            .creation_boundary = op.getContext().operationCreationBoundary(),
            .nodes = try scratch.alloc(Dependency, node_count),
        };
        try self.append(op, true, false);
        var index: usize = 0;
        while (index < self.used) : (index += 1) try self.expand(index);
        std.debug.assert(self.used <= self.nodes.len);
        var widest: usize = 0;
        for (self.nodes[0..self.used]) |node| widest = @max(widest, node.revision.len);
        self.scratch = try scratch.alloc(u8, widest);
        self.allocator = allocator;
        self.storage = storage;
        return self;
    }

    pub fn deinit(self: *EffectSummary) void {
        self.storage.deinit();
        self.* = undefined;
    }

    fn append(self: *EffectSummary, op: *ir.Operation, executes: bool, body: bool) !void {
        for (self.nodes[0..self.used]) |node| {
            if (node.op == op) {
                self.complete = false;
                return;
            }
        }
        if (self.used == self.nodes.len) {
            self.complete = false;
            return;
        }
        var declaration = try facts.inspect(self.allocator, op);
        errdefer declaration.deinit(self.allocator);
        const revision = try revisionAlloc(self.allocator, op);
        self.nodes[self.used] = .{
            .op = op,
            .revision = revision,
            .declaration = declaration,
            .executes = executes,
            .instantiate_body = body,
        };
        self.used += 1;
        if (executes and !declaration.facts.complete) self.complete = false;
    }

    fn expand(self: *EffectSummary, index: usize) !void {
        const node = self.nodes[index];
        for (node.op.regions.items, 0..) |*region, region_index| {
            const mode = regionExecution(node.declaration.facts, region_index);
            if (node.executes and mode == .unknown) self.complete = false;
            const executes = node.executes and (mode != .latent or node.instantiate_body);
            var blocks = region.getBlocks();
            while (blocks.next()) |block| {
                var operations = block.getOperations();
                while (operations.next()) |child| try self.append(child, executes, false);
            }
        }
        if (node.op.hasInterface(ir.interfaces.CallOpInterface)) {
            if (resolveCallee(node.op)) |callee| {
                try self.append(callee, node.executes, true);
            } else if (node.executes) self.complete = false;
        }
    }

    pub fn isCurrent(self: *const EffectSummary) bool {
        for (self.nodes[0..self.used]) |node| {
            if (!self.context.containsOperation(node.op)) return false;
            if (!node.op.createdBefore(self.creation_boundary)) return false;
            if (!revisionMatches(self.scratch, node.op, node.revision)) return false;
        }
        return true;
    }

    pub fn discard(self: *const EffectSummary) bool {
        return self.all(.discard);
    }

    pub fn repeatableExpression(self: *const EffectSummary) bool {
        return self.all(.repeatable);
    }

    pub fn duplicate(self: *const EffectSummary, stability: facts.Stability) bool {
        if (!self.discard()) return false;
        for (self.nodes[0..self.used]) |node| {
            if (node.executes and !facts.duplicate(node.declaration.facts, stability)) return false;
        }
        return true;
    }

    pub fn speculate(self: *const EffectSummary, operands_available: bool) bool {
        if (!self.discard()) return false;
        for (self.nodes[0..self.used]) |node| {
            if (node.executes and !facts.speculate(node.declaration.facts, operands_available)) {
                return false;
            }
        }
        return true;
    }

    pub fn reorder(self: *const EffectSummary, other: *const EffectSummary) bool {
        if (!self.complete or !other.complete) return false;
        if (!self.isCurrent() or !other.isCurrent()) return false;
        for (self.nodes[0..self.used]) |left| {
            if (!left.executes) continue;
            for (other.nodes[0..other.used]) |right| {
                if (!right.executes) continue;
                if (dependsOn(left.op, right.op) or dependsOn(right.op, left.op)) return false;
                if (!facts.reorder(left.declaration.facts, right.declaration.facts, .{
                    .no_dependencies = true,
                })) return false;
            }
        }
        return true;
    }

    pub fn invalidatesStores(self: *const EffectSummary) bool {
        return !self.all(.read_only);
    }

    pub fn observesStores(self: *const EffectSummary) bool {
        return !self.repeatableExpression();
    }

    fn all(
        self: *const EffectSummary,
        comptime action: enum { discard, repeatable, read_only },
    ) bool {
        if (!self.complete or !self.isCurrent()) return false;
        for (self.nodes[0..self.used]) |node| {
            if (!node.executes) continue;
            const allowed = switch (action) {
                .discard, .read_only => facts.discard(node.declaration.facts),
                .repeatable => facts.repeatableExpression(node.declaration.facts),
            };
            if (!allowed) return false;
        }
        return true;
    }
};

fn regionExecution(declaration: facts.Facts, index: usize) facts.Execution {
    for (declaration.records) |record| switch (record) {
        .region => |region| if (region.index == index) return region.execution,
        else => {},
    };
    return .unknown;
}

fn resolveCallee(op: *ir.Operation) ?*ir.Operation {
    const call = op.interface(ir.interfaces.CallOpInterface) orelse return null;
    const name = call.call(.getCalleeSymbol, .{}) orelse return null;
    return ir.SymbolTable.lookupNearestSymbolFrom(op, name);
}

fn dependsOn(user: *ir.Operation, definition: *ir.Operation) bool {
    if (user == definition) return true;
    if (user.isAncestor(definition) or definition.isAncestor(user)) return true;
    for (user.operands.items) |operand| {
        if (operand.value.getDefiningOp() == @as(*anyopaque, @ptrCast(definition))) return true;
    }
    return false;
}

/// Identity-based, exact records use immutable interned attributes and types.
/// The bytes include placement, operand identities, result types, properties,
/// child rosters, block arguments, interface contracts and resolved callees.
/// Whether `op` still spells the revision `expected`, written into `room`
/// rather than into memory this has to ask for.
///
/// WHY THE STORED LENGTH IS THE EXACT BOUND. `room` is as wide as the widest
/// revision the summary holds, so a revision that does not fit in
/// `expected.len` bytes is longer than the one recorded and is therefore a
/// different revision. Overflow and mismatch are the same answer, and both are
/// facts about the operation rather than about the memory left, which is the
/// whole point: a summary that could not be checked used to read as a summary
/// that was stale, and three separate permissions turned on that reading.
fn revisionMatches(room: []u8, op: *ir.Operation, expected: []const u8) bool {
    if (expected.len > room.len) return false;
    var writer = std.Io.Writer.fixed(room[0..expected.len]);
    revisionInto(&writer, op) catch return false;
    return writer.end == expected.len and std.mem.eql(u8, room[0..expected.len], expected);
}

fn revisionAlloc(allocator: std.mem.Allocator, op: *ir.Operation) ![]u8 {
    return revisionBytesAlloc(allocator, op) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

fn revisionBytesAlloc(allocator: std.mem.Allocator, op: *ir.Operation) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try revisionInto(&output.writer, op);
    return output.toOwnedSlice();
}

/// Spells `op`'s revision into `writer`. One spelling serves the summary that
/// records a revision and the check that compares one, so the two cannot drift
/// apart and answer differently about the same operation.
fn revisionInto(writer: *std.Io.Writer, op: *ir.Operation) !void {
    try writer.print("{d}:{s};{x};{x};{x};{x};{x};{x};{f};", .{
        op.name.name.len,
        op.name.name,
        pointer(op.getBlock()),
        pointer(op.prev_op),
        pointer(op.next_op),
        pointer(op.getInterface(facts.EffectOpInterface)),
        pointer(op.getInterface(ir.interfaces.CallOpInterface)),
        pointer(resolveCallee(op)),
        op.getLoc(),
    });
    const arithmetic = op.getContext().arithmetic_policy;
    try writer.print("fp{any}:{any}:{any};", .{
        arithmetic.exceptions_masked,
        arithmetic.default_rounding,
        arithmetic.environment_observable,
    });
    const properties = try op.getPropertiesAsAttr();
    try writer.print("p{x};", .{if (properties) |attr| @intFromPtr(attr.impl) else 0});
    var attrs = op.getAttrs();
    while (attrs.next()) |attr| {
        try writer.print(
            "a{d}:{s}:{x};",
            .{ attr.name.len, attr.name, @intFromPtr(attr.value.impl) },
        );
    }
    for (op.operands.items) |operand| try writeValue(writer, operand.value);
    try writer.writeAll("results;");
    for (op.results.items) |*result| try writeValue(writer, result);
    for (op.successors.items) |successor| try writer.print("s{x};", .{@intFromPtr(successor)});
    for (op.regions.items) |*region| {
        try writer.print("r{x};", .{@intFromPtr(region)});
        var blocks = region.getBlocks();
        while (blocks.next()) |block| {
            try writer.print("b{x};", .{@intFromPtr(block)});
            for (block.arguments.items) |argument| try writeValue(writer, argument);
            var children = block.getOperations();
            while (children.next()) |child| try writer.print("c{x};", .{@intFromPtr(child)});
        }
    }
}

fn writeValue(writer: *std.Io.Writer, value: *ir.Value) !void {
    try writer.print("v{x}:{x};", .{ @intFromPtr(value), @intFromPtr(value.type.impl) });
}

fn pointer(value: anytype) usize {
    return if (value) |ptr| @intFromPtr(ptr) else 0;
}

/// What an effect question answered, for a question whose answer costs
/// memory to find.
///
/// WHY THREE AND NOT TWO. Deciding what an operation permits means reading
/// its declared facts, and reading them allocates from the same context the
/// module lives in. A caller that receives `false` for both "this operation
/// forbids it" and "I could not afford to look" cannot tell a fact about the
/// program from a shortfall in the compiler, and will go on to emit a
/// different program under a smaller budget while reporting nothing. The two
/// are different answers and this names them differently.
pub const Permission = enum {
    /// The operation permits it, read from its complete declared facts.
    yes,
    /// The operation does not permit it. This is a fact about the operation
    /// and holds at every budget.
    no,
    /// The answer was not affordable. This says nothing about the operation.
    /// A caller turns it into a refusal that names the segment and the
    /// figure, never into `no`.
    unaffordable,
};

/// An operation whose summary is its own declaration: no region to walk and no
/// callee to resolve, so the summary holds exactly one node. The x86_64
/// emitter asks only leaves, so it reads this predicate rather than restating it.
pub fn isLeaf(op: *ir.Operation) bool {
    return op.getNumRegions() == 0 and !op.hasInterface(ir.interfaces.CallOpInterface);
}

/// Whether `op` may be discarded.
///
/// A LEAF IS ANSWERED WITHOUT ALLOCATING. Its summary is one node whose answer
/// is its own declaration, and `facts.answers` reads that declaration by
/// replay, so no context segment reaches the answer and a smaller budget never
/// keeps an operation a larger one leaves out. A region operation or a call
/// still walks a summary drawn from the context, and still answers false when
/// that summary cannot be afforded.
pub fn permitsDiscard(op: *ir.Operation) bool {
    if (!op.hasInterface(facts.EffectOpInterface)) return false;
    if (isLeaf(op)) return facts.answers(op, .discard);
    var summary = EffectSummary.init(op.allocator, op) catch return false;
    defer summary.deinit();
    return summary.discard();
}

/// Whether the reads and writes of the storage `op` allocates may be discarded.
///
/// THE PERMISSION IS DERIVED AND NOT DECLARED. Nothing states that a cell is
/// private, because no operation can state it: privacy is a fact about every
/// use of a value, which only the module holds. What the declarations state is
/// enough to derive it.
///
/// The premises, each read from a complete declaration:
/// 1. The allocation hands back a fresh identity. Its result is not an alias
///    of an operand and not a name someone else already holds, so the only way
///    to reach the storage is through that result.
/// 2. The uses of an SSA result are all of them. The use list is the module's
///    own record, so a use nobody can see does not exist.
/// 3. Each use is named by its own operation's facts as the subject of an
///    unordered read or write. An ordered access is observable by another
///    thread of control, and any other event over that subject, a free, a
///    borrow, a move, a release or a foreign call, hands the identity on.
/// 4. No result of a using operation aliases that operand, so the identity
///    does not leave through a result either.
/// 5. The only premise a use still carries over that subject is `live`, and
///    that premise is discharged here: an SSA use is dominated by its
///    definition, the allocation is that definition, and premise 3 leaves no
///    event that could end the storage before the use.
///
/// From 1 through 5 the storage is unreachable outside those reads and writes.
/// A read of a cell nobody else can reach answers the last write to it, and a
/// write nobody else can read changes nothing anyone can observe, so a caller
/// that keeps the values in SSA form may discard both.
///
/// WHAT THIS DOES NOT SAY. It does not permit discarding the ALLOCATION. The
/// allocation can still fail, and a failure is an event this says nothing
/// about, so the allocation stays and its bytes stay charged.
///
/// READING THE DECLARATIONS COSTS MEMORY, so this answers three ways and not
/// two. `unaffordable` is not a smaller `no`: a caller that treats it as one
/// promotes nothing, emits a different program, and reports nothing. The caller
/// refuses with the segment and the figure instead.
/// A shape error from `inspect` stays `no`, because a declaration this
/// operation states wrongly is a property of the operation and reads the same
/// at every budget.
pub fn permitsDiscardingLocalAccesses(op: *ir.Operation) Permission {
    if (!op.hasInterface(facts.EffectOpInterface)) return .no;
    var declaration = facts.inspect(op.allocator, op) catch |err| switch (err) {
        error.OutOfMemory => return .unaffordable,
        else => return .no,
    };
    defer declaration.deinit(op.allocator);
    if (!declaration.facts.complete) return .no;

    const cell = op.getResult(0) orelse return .no;
    var allocates = false;
    for (declaration.facts.records) |record| switch (record) {
        .event => |event| switch (event.kind) {
            .allocate => {
                if (!subjectIsResult(event.resource.subject, 0)) return .no;
                allocates = true;
            },
            .failure => {},
            else => return .no,
        },
        .result => |result| {
            if (result.index != 0) continue;
            if (!result.fresh_identity) return .no;
            if (result.alias != null) return .no;
        },
        .requirement => return .no,
        .region, .binding, .premise => {},
    };
    if (!allocates) return .no;

    var use = cell.first_use;
    while (use) |operand| : (use = operand.next_use) {
        const owner: *ir.Operation = @ptrCast(@alignCast(operand.owner));
        switch (accessesOnly(owner, operand.operand_number)) {
            .yes => {},
            .no => return .no,
            .unaffordable => return .unaffordable,
        }
    }
    return .yes;
}

/// Whether `op` names its operand `index` only as the subject of its own
/// unordered reads and writes, with `live` as the one premise left over it.
///
/// AN INCOMPLETE DECLARATION IS `no` AND NOT `unaffordable`. `complete` is
/// cleared when an operation's facts outran the capacity that operation
/// itself declares for them, which is a property of the operation and holds
/// at every budget. Measured over the nested-loop reproducer at limits
/// of 65536, 8192 and 4096, every `memref.load` answered complete with 3
/// records and every `memref.store` complete with 2, the same at all three,
/// and the budget that could not afford the question failed `inspect`
/// outright rather than returning an incomplete answer.
fn accessesOnly(op: *ir.Operation, index: usize) Permission {
    if (!op.hasInterface(facts.EffectOpInterface)) return .no;
    var declaration = facts.inspect(op.allocator, op) catch |err| switch (err) {
        error.OutOfMemory => return .unaffordable,
        else => return .no,
    };
    defer declaration.deinit(op.allocator);
    if (!declaration.facts.complete) return .no;

    var accesses = false;
    for (declaration.facts.records) |record| switch (record) {
        .event => |event| {
            if (!subjectIsOperand(event.resource.subject, index)) continue;
            if (event.ordered) return .no;
            if (event.kind != .read and event.kind != .write) return .no;
            accesses = true;
        },
        .requirement => |requirement| {
            const names = subjectIsOperand(requirement.subject, index) or
                (requirement.related != null and
                    subjectIsOperand(requirement.related.?, index));
            if (!names) continue;
            if (requirement.kind != .live) return .no;
        },
        .result => |result| {
            const alias = result.alias orelse continue;
            if (subjectIsOperand(alias, index)) return .no;
        },
        .region, .binding, .premise => {},
    };
    return if (accesses) .yes else .no;
}

fn subjectIsOperand(subject: facts.Subject, index: usize) bool {
    return subject == .operand and subject.operand == index;
}

fn subjectIsResult(subject: facts.Subject, index: usize) bool {
    return subject == .result and subject.result == index;
}

/// Whether `op` is an expression that may be repeated. A leaf is answered
/// without allocating, as `permitsDiscard` answers it.
pub fn permitsRepeatableExpression(op: *ir.Operation) bool {
    if (!op.hasInterface(facts.EffectOpInterface)) return false;
    if (isLeaf(op)) return facts.answers(op, .repeatable);
    var summary = EffectSummary.init(op.allocator, op) catch return false;
    defer summary.deinit();
    return summary.repeatableExpression();
}

const pass = @import("pass/root.zig");
const CachedSummary = pass.Analysis(
    EffectSummary,
    "choir.effects",
    &.{},
    computeSummary,
    destroySummary,
    null,
);

/// Preserving the cache entry never preserves permission across changed inputs.
pub fn analysis(ctx: *pass.PassContext, op: *ir.Operation) !*EffectSummary {
    const cached = try CachedSummary.get(ctx, op);
    if (!cached.isCurrent()) {
        try ctx.refreshAnalysis(op, &CachedSummary.descriptor, refreshSummary);
    }
    return cached;
}

fn refreshSummary(ctx: *pass.PassContext, op: *ir.Operation, value: *anyopaque) !void {
    const cached: *EffectSummary = @ptrCast(@alignCast(value));
    const replacement = try EffectSummary.init(ctx.allocator, op);
    cached.deinit();
    cached.* = replacement;
}

fn computeSummary(ctx: *pass.PassContext, op: *ir.Operation) !*EffectSummary {
    const result = try ctx.allocator.create(EffectSummary);
    errdefer ctx.allocator.destroy(result);
    result.* = try EffectSummary.init(ctx.allocator, op);
    return result;
}

fn destroySummary(summary: *EffectSummary, allocator: std.mem.Allocator) void {
    summary.deinit();
    allocator.destroy(summary);
}

fn checkSummaryAllocationFailure(allocator: std.mem.Allocator, op: *ir.Operation) !void {
    var summary = try EffectSummary.init(allocator, op);
    defer summary.deinit();
}

fn appendsOneRead(_: *const ir.Operation, collector: *facts.Collector) void {
    collector.append(.{ .event = .{ .kind = .read } });
}
