const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");

const facts = ir.interfaces.effects;

const Dependency = struct {
    op: *ir.Operation,
    revision: []usize,
    declaration: facts.Declaration,
    executes: bool,
    instantiate_body: bool,
};

/// A graph of ordered local declarations bound to exact IR and callee inputs.
/// Nodes retain their local subjects: operand zero in a callee is not operand
/// zero in its caller. Unproved bindings therefore never authorize an action.
///
/// AN INCOMPLETE SUMMARY STOPS GROWING. Every answer reads `complete` before
/// any node, and nothing makes a summary complete again, so once one fact
/// makes it incomplete no later node can change an answer. The nodes it holds
/// carry that fact in their own revisions: the incomplete declaration, the
/// unknown region, the unresolved callee, or the parent whose roster reaches a
/// subject twice. The shorter summary therefore goes stale whenever that fact
/// could change. A call declares its callee contract as an unproved
/// requirement, so a call's summary is incomplete at its first node, and
/// walking the callee's reach after it made each query cost the whole reach.
pub const EffectSummary = struct {
    allocator: std.mem.Allocator,
    storage: alloc_arena.Arena,
    context: *ir.Context,
    creation_boundary: u31,
    /// The context's `operationReleaseEpoch` when the summary was built.
    release_epoch: u64,
    nodes: []Dependency,
    used: usize = 0,
    complete: bool = true,
    /// Whether nodes carry revisions. A revised summary may outlive a mutation, so every
    /// answer asks `isCurrent` first. An unrevised one answers from the nodes it holds, and
    /// its caller owes the premise `initUnrevised` states.
    revised: bool = true,

    const Question = enum { discard, repeatable, read_only };

    pub fn init(allocator: std.mem.Allocator, op: *ir.Operation) !EffectSummary {
        return build(allocator, op, true);
    }

    /// A summary that holds no revisions, for a caller that builds it, asks it and drops it
    /// with no IR mutation in between. Its answers skip `isCurrent`, whose three checks hold
    /// by construction for such a caller, as `answerOnce` argues. Recording a revision walks
    /// the operation and resolves a call's callee through the module's symbol table, and
    /// comparing one walks it again, so a query that cannot go stale pays for neither.
    ///
    /// A caller that mutates the IR and then asks gets an answer about the IR it had. Nothing
    /// checks that, so a summary kept across a mutation is built with `init`.
    pub fn initUnrevised(allocator: std.mem.Allocator, op: *ir.Operation) !EffectSummary {
        return build(allocator, op, false);
    }

    fn build(allocator: std.mem.Allocator, op: *ir.Operation, revised: bool) !EffectSummary {
        var storage = alloc_arena.Arena.init(allocator);
        errdefer storage.deinit();
        const scratch = storage.allocator();
        var self = EffectSummary{
            .allocator = scratch,
            .storage = undefined,
            .context = op.getContext(),
            .creation_boundary = op.getContext().operationCreationBoundary(),
            .release_epoch = op.getContext().operationReleaseEpoch(),
            .nodes = try scratch.alloc(Dependency, 1),
            .revised = revised,
        };
        {
            // The index shares the arena lifetime. Interleaving allocations
            // on the backing allocator would strand holes on fixed buffers.
            var visited: std.AutoHashMapUnmanaged(*ir.Operation, void) = .empty;
            defer visited.deinit(scratch);
            try self.append(op, true, false, &visited);
            var index: usize = 0;
            while (self.complete and index < self.used) : (index += 1) {
                try self.expand(index, &visited);
            }
        }
        std.debug.assert(self.used <= self.nodes.len);
        self.allocator = allocator;
        self.storage = storage;
        return self;
    }

    pub fn deinit(self: *EffectSummary) void {
        self.storage.deinit();
        self.* = undefined;
    }

    fn append(
        self: *EffectSummary,
        op: *ir.Operation,
        executes: bool,
        body: bool,
        visited: *std.AutoHashMapUnmanaged(*ir.Operation, void),
    ) !void {
        if (!self.complete) return;
        // An operation the context does not track is outside every currency check, so nothing
        // it declares may grant a permission. The tracker's list is circular, so every tracked
        // operation, the head included, has a previous one: a null link is exact for a live op.
        if (op.tracking_prev == null) {
            self.complete = false;
            return;
        }
        // A summary's graph belongs to one context: the liveness, creation-boundary and
        // arithmetic-policy checks all ask `self.context`. An operation another context
        // tracks, nested here or resolved as a callee, would pass the link above.
        if (op.getContext() != self.context) {
            self.complete = false;
            return;
        }
        // A leaf needs no membership allocation. Once expansion reaches a
        // second subject, index only this summary's subjects, not the context.
        // Repeated subjects still make bindings incomplete, as before.
        if (self.used != 0) {
            if (visited.count() == 0) try visited.put(self.allocator, self.nodes[0].op, {});
            const entry = try visited.getOrPut(self.allocator, op);
            if (entry.found_existing) {
                self.complete = false;
                return;
            }
        }
        if (self.used == self.nodes.len) {
            self.nodes = try self.allocator.realloc(self.nodes, self.nodes.len * 2);
        }
        var declaration = try facts.inspect(self.allocator, op);
        errdefer declaration.deinit(self.allocator);
        const revision: []usize = if (self.revised) try revisionAlloc(self.allocator, op) else &.{};
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

    fn expand(
        self: *EffectSummary,
        index: usize,
        visited: *std.AutoHashMapUnmanaged(*ir.Operation, void),
    ) !void {
        const node = self.nodes[index];
        for (node.op.regions.items, 0..) |*region, region_index| {
            const mode = regionExecution(node.declaration.facts, region_index);
            if (node.executes and mode == .unknown) self.complete = false;
            if (!self.complete) return;
            const executes = node.executes and (mode != .latent or node.instantiate_body);
            var blocks = region.getBlocks();
            while (blocks.next()) |block| {
                var operations = block.getOperations();
                while (operations.next()) |child| {
                    try self.append(child, executes, false, visited);
                    if (!self.complete) return;
                }
            }
        }
        if (node.op.hasInterface(ir.interfaces.CallOpInterface)) {
            if (resolveCallee(node.op)) |callee| {
                try self.append(callee, node.executes, true, visited);
            } else if (node.executes) self.complete = false;
        }
    }

    /// Whether a summary built now would hold the same nodes and declarations.
    ///
    /// WHY EVERY DECLARATION IS REPLAYED AND NOT ONLY SPELLED. A node's revision spells its own
    /// fields and its children's addresses, but an enumerator may read state no revision spells:
    /// arith's and accy's divisions read the constant that defines an operand, and an enumerator
    /// may read a descendant the walk never reached because it stopped first. A change there
    /// leaves every revision equal while it changes a declaration, and through it whether a
    /// region executes, which nodes the walk reaches, and the answer. Replaying each node's
    /// declaration closes that, whatever its enumerator reads: with every revision and every
    /// declaration equal, the walk takes the same steps it took, so a fresh summary is this one.
    /// This assumes an enumerator neither mutates IR nor answers differently on equal IR.
    ///
    /// WHY THE NODES ARE CHECKED IN ORDER. Liveness is read from the operation's own tracking
    /// link, so the check reads the storage a node names. Every node after the first was reached
    /// from an earlier one, through a region roster or a resolved callee, and that node's
    /// revision spells both. Once the earlier node's revision matches, each operation it reaches
    /// is in a live block or behind a live symbol, so its storage is an operation's. Only the
    /// first node is read with no such witness: it is the subject the caller asks about, and
    /// the caller may have erased it. A pool slot stays a header or a free slot once erased, so
    /// the link is read there. Storage outside the pools may be reused under another layout,
    /// so once any has been released since the summary was built, the subject is looked up on
    /// the context's list, which reads nothing at its address.
    ///
    /// The check allocates nothing and formats nothing: each node's words are compared against
    /// the recorded ones as the walk produces them.
    pub fn isCurrent(self: *const EffectSummary) bool {
        std.debug.assert(self.revised);
        if (self.used != 0 and self.context.operationReleaseEpoch() != self.release_epoch) {
            if (!self.context.listsOperation(self.nodes[0].op)) return false;
        }
        for (self.nodes[0..self.used]) |node| {
            if (!self.context.containsOperation(node.op)) return false;
            if (!node.op.createdBefore(self.creation_boundary)) return false;
            if (!revisionMatches(node.op, node.revision)) return false;
        }
        for (self.nodes[0..self.used]) |node| {
            if (!declarationHolds(node)) return false;
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
        if (!self.answersCurrent() or !other.answersCurrent()) return false;
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

    /// Whether no summary can cross this one: `other.reorder(self)` is false for every
    /// `other`. `reorder` refuses an incomplete summary, and refuses any pair in which an
    /// executing node is not total or, without exclusive concurrency, not memory-free,
    /// whatever the other side holds. A caller that walks many candidates past the same
    /// operation asks this once and skips the walk.
    pub fn blocksEveryCrossing(self: *const EffectSummary) bool {
        if (!self.complete or !self.answersCurrent()) return true;
        for (self.nodes[0..self.used]) |node| {
            if (!node.executes) continue;
            if (!facts.total(node.declaration.facts)) return true;
            if (!facts.memoryFree(node.declaration.facts)) return true;
        }
        return false;
    }

    pub fn invalidatesStores(self: *const EffectSummary) bool {
        return !self.all(.read_only);
    }

    pub fn observesStores(self: *const EffectSummary) bool {
        return !self.repeatableExpression();
    }

    fn all(self: *const EffectSummary, comptime action: Question) bool {
        if (!self.complete or !self.answersCurrent()) return false;
        return self.holds(action);
    }

    /// Whether this summary's nodes may be read as the IR's. A revised summary proves it. An
    /// unrevised one holds it as its caller's premise.
    fn answersCurrent(self: *const EffectSummary) bool {
        return !self.revised or self.isCurrent();
    }

    /// Whether every executing node permits `action`, without asking whether
    /// the summary is still current. Only `all` and `answerOnce` call it:
    /// `all` asks currency first, and `answerOnce` answers before anything
    /// can make its summary stale.
    fn holds(self: *const EffectSummary, comptime action: Question) bool {
        std.debug.assert(self.complete);
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

/// Whether `node`'s declaration, collected again without storage, is the one it recorded.
///
/// WHAT EQUAL MEANS HERE. Records compare field by field, and a slice by its address and
/// length, not by its bytes. A recorded fact borrows every string it names, so this is exact
/// only under the premise that those bytes are immutable and outlive the summary, as static
/// strings and interned attribute payloads are. An enumerator that names a string in scratch
/// it later overwrites breaks that premise: the record and the replay then read the same new
/// bytes and compare equal. Under the premise, two different addresses holding equal bytes
/// read as stale, which costs a rebuild and never a wrong answer.
fn declarationHolds(node: Dependency) bool {
    const op = node.op;
    // The interface and the counts that size its capacity are spelled in the revision, so a
    // node without one, or past its capacity, declares what it declared when it was collected.
    const vtable = op.getInterface(facts.EffectOpInterface) orelse return true;
    const limit = vtable.capacity.count(
        op.getNumOperands(),
        op.getNumResults(),
        op.getNumRegions(),
    ) orelse return true;
    const Replay = struct {
        recorded: []const facts.Fact,
        seen: usize = 0,
        same: bool = true,

        fn visit(raw: *anyopaque, fact: facts.Fact) void {
            const replay: *@This() = @ptrCast(@alignCast(raw));
            if (!replay.same) return;
            if (replay.seen == replay.recorded.len or
                !std.meta.eql(replay.recorded[replay.seen], fact))
            {
                replay.same = false;
                return;
            }
            replay.seen += 1;
        }
    };
    const recorded = node.declaration;
    var replay = Replay{ .recorded = recorded.facts.records };
    var collector = facts.Collector{
        .storage = &.{},
        .observer = .{ .context = &replay, .limit = limit, .visit = Replay.visit },
    };
    vtable.collect(op, &collector);
    return replay.same and replay.seen == recorded.facts.records.len and
        collector.exhausted == recorded.exhausted and
        (collector.complete and !collector.exhausted) == recorded.facts.complete;
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

/// One operation's revision: the words `revisionInto` produces for it, either recorded or
/// compared against a recorded revision as they are produced.
///
/// A revision is exact, not a digest. Two revisions are equal only when every fact
/// `revisionInto` reads is equal, so a summary whose IR was changed and then restored is
/// current again, and no two states share a revision by collision. Pointers, counts and flags
/// are one word each. Text is its length and then its bytes, eight to a word.
const Revision = struct {
    /// A recording's room may be shorter than the revision. Words past its end are counted
    /// and dropped, so `used` is the revision's length either way.
    target: union(enum) { record: []usize, compare: []const usize },
    used: usize = 0,
    same: bool = true,

    fn word(self: *Revision, value: usize) void {
        switch (self.target) {
            .record => |room| if (self.used < room.len) {
                room[self.used] = value;
            },
            .compare => |expected| self.same = self.same and
                self.used < expected.len and expected[self.used] == value,
        }
        self.used += 1;
    }

    fn wide(self: *Revision, value: u64) void {
        if (@sizeOf(usize) >= @sizeOf(u64)) {
            self.word(@intCast(value));
        } else {
            self.word(@truncate(value));
            self.word(@intCast(value >> 32));
        }
    }

    fn text(self: *Revision, bytes: []const u8) void {
        const width = @sizeOf(usize);
        self.word(bytes.len);
        var rest = bytes;
        while (rest.len >= width) : (rest = rest[width..]) {
            self.word(std.mem.readInt(usize, rest[0..width], .little));
        }
        if (rest.len == 0) return;
        var tail: [width]u8 = @splat(0);
        @memcpy(tail[0..rest.len], rest);
        self.word(std.mem.readInt(usize, &tail, .little));
    }

    fn typed(self: *Revision, operand: *ir.Value) void {
        self.word(@intFromPtr(operand));
        self.word(@intFromPtr(operand.type.impl));
    }

    /// The fields a location prints, which are the ones a revision has always spelled.
    fn location(self: *Revision, loc: ir.Location) void {
        self.word(@backingInt(std.meta.activeTag(loc)));
        switch (loc) {
            .unknown, .fused, .call_site => {},
            .file => |file| {
                self.text(file.filename);
                self.word(file.line);
                self.word(file.column);
            },
            .file_range => |range| {
                self.text(range.filename);
                for ([_]ir.Location.FilePosition{ range.start, range.end }) |position| {
                    self.wide(position.byte);
                    self.word(position.line);
                    self.word(position.column);
                }
            },
            .name => |name| self.text(name.name),
        }
    }
};

/// Whether `op` still has the revision `expected`. The walk compares each word as it
/// produces it, so the check needs no room of its own and cannot fail for want of memory.
/// A revision that is longer or shorter than `expected` is a different one.
fn revisionMatches(op: *ir.Operation, expected: []const usize) bool {
    var revision = Revision{ .target = .{ .compare = expected } };
    revisionInto(&revision, op) catch return false;
    return revision.same and revision.used == expected.len;
}

/// The words a revised summary compares for `op`, owned by the caller.
pub fn revisionAlloc(allocator: std.mem.Allocator, op: *ir.Operation) ![]usize {
    // A leaf's revision fits here, so it is walked once. A wider one is measured by this
    // walk and recorded by a second.
    var small: [64]usize = undefined;
    var first = Revision{ .target = .{ .record = &small } };
    try revisionInto(&first, op);
    const words = try allocator.alloc(usize, first.used);
    errdefer allocator.free(words);
    if (first.used <= small.len) {
        @memcpy(words, small[0..first.used]);
        return words;
    }
    var second = Revision{ .target = .{ .record = words } };
    try revisionInto(&second, op);
    std.debug.assert(second.used == words.len);
    return words;
}

/// Produces `op`'s revision. One walk serves the summary that records a revision and the
/// check that compares one, so the two cannot drift apart and answer differently about the
/// same operation.
///
/// WHAT A REVISION OBSERVES. These are the facts of `op` a summary depends on, each with the
/// owner that changes it. No owner reports a change and none keeps a counter: each fact is
/// read again here, so a new mutator needs no hook, and a new fact an enumerator reads needs
/// a word here.
/// - Identity and placement: the operation's name and location, set at creation, and its
///   block and neighbours, which `Block` insertion and `Operation.moveBefore`, `moveToEnd`
///   and `removeFromBlock` change.
/// - Contracts: its effect and call interfaces, which the context's operation registry
///   changes when an interface is registered, and the callee its symbol resolves to now,
///   which changes with the symbol attribute of any operation in the enclosing symbol
///   tables and with their rosters.
/// - The context's arithmetic policy, a field of `Context` its owner writes directly.
/// - Its properties, which `setPropertiesFromAttr` and `copyProperties` change, and every
///   attribute, by name and interned value, which `setAttr` and `removeAttr` change.
/// - Each operand's value and type, which `setOperandValue` and `replaceOperands` change,
///   and the literal its declared source resolves to, which changes with the defining
///   operation's attributes.
/// - Each result's value and type, and each successor. A `Value`'s type is a field its
///   holder writes directly, and `setSuccessors` changes the successors.
/// - Each region's blocks, their arguments, and the operations in them, in order, which
///   `Region` and `Block` change.
/// Liveness is not a word: `isCurrent` reads it from the context's tracker, which
/// `createOperation` and `erase` change, and compares creation boundaries.
/// Attributes and types are interned and immutable, so their addresses stand for them.
///
/// THE WORDS PARSE ONE WAY. A count leads every list whose length is known before it is
/// walked. An attribute is led by a one and the attributes end with a zero. A block's
/// operations end with a zero and so do a region's blocks, which no address is. Two different
/// states therefore never produce the same words.
fn revisionInto(revision: *Revision, op: *ir.Operation) !void {
    revision.text(op.name.name);
    revision.word(pointer(op.getBlock()));
    revision.word(pointer(op.prev_op));
    revision.word(pointer(op.next_op));
    revision.word(pointer(op.getInterface(facts.EffectOpInterface)));
    revision.word(pointer(op.getInterface(ir.interfaces.CallOpInterface)));
    revision.word(pointer(resolveCallee(op)));
    revision.location(op.getLoc());
    const arithmetic = op.getContext().arithmetic_policy;
    revision.word(@as(usize, @intFromBool(arithmetic.exceptions_masked)) |
        @as(usize, @intFromBool(arithmetic.default_rounding)) << 1 |
        @as(usize, @intFromBool(arithmetic.environment_observable)) << 2);
    const properties = try op.getPropertiesAsAttr();
    revision.word(if (properties) |attr| @intFromPtr(attr.impl) else 0);
    var attrs = op.getAttrs();
    while (attrs.next()) |attr| {
        revision.word(1);
        revision.word(@intFromPtr(attr.value.impl));
        revision.text(attr.name);
    }
    revision.word(0);
    revision.word(op.operands.items.len);
    for (op.operands.items) |operand| revision.typed(operand.value);
    // An enumerator may read each operand's literal through its declared source, so the
    // revision holds the attribute that source resolves to, through the resolver the subject
    // uses. That is one word per operand, literal or not, and none for a declaration that
    // names no source.
    const literal = if (op.getInterface(facts.EffectOpInterface)) |vtable| vtable.literal else null;
    revision.word(@intFromBool(literal != null));
    if (literal) |source| {
        for (0..op.operands.items.len) |index| {
            const attr = facts.literalAttribute(op, index, source);
            revision.word(if (attr) |found| @intFromPtr(found.impl) else 0);
        }
    }
    revision.word(op.results.items.len);
    for (op.results.items) |*result| revision.typed(result);
    revision.word(op.successors.items.len);
    for (op.successors.items) |successor| revision.word(@intFromPtr(successor));
    revision.word(op.regions.items.len);
    for (op.regions.items) |*region| {
        revision.word(@intFromPtr(region));
        var blocks = region.getBlocks();
        while (blocks.next()) |block| {
            revision.word(@intFromPtr(block));
            revision.word(block.arguments.items.len);
            for (block.arguments.items) |argument| revision.typed(argument);
            var children = block.getOperations();
            while (children.next()) |child| revision.word(@intFromPtr(child));
            revision.word(0);
        }
        revision.word(0);
    }
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
/// still walks a summary drawn from the context, and answers false when that
/// summary cannot be afforded. A caller that can refuse asks `discardPermission`
/// instead, and one that only ever asks leaves asks `leafPermitsDiscard`.
pub fn permitsDiscard(op: *ir.Operation) bool {
    return discardPermission(op) == .yes;
}

/// Whether `op` may be discarded, with a shortfall named as `unaffordable` rather than read as no.
pub fn discardPermission(op: *ir.Operation) Permission {
    if (!op.hasInterface(facts.EffectOpInterface)) return .no;
    if (isLeaf(op)) return if (facts.answers(op, .discard)) .yes else .no;
    return answerOnce(op, .discard);
}

/// `permitsDiscard` for a caller that only ever asks leaves, which no budget can
/// change. Asking it of a region operation or a call is a caller's error, so it
/// cannot become budget-sensitive without failing a test.
pub fn leafPermitsDiscard(op: *ir.Operation) bool {
    std.debug.assert(isLeaf(op));
    return op.hasInterface(facts.EffectOpInterface) and facts.answers(op, .discard);
}

/// The answer a summary of `op` would give to `action`, from a summary built,
/// read and dropped inside this call.
///
/// WHY CURRENCY IS NOT ASKED. `isCurrent` checks that every node is still a
/// live operation of the context, was created before the summary, and still
/// has the revision recorded for it. The third check walks every node again,
/// so asking it once per operation doubled a pass over a module. Here every
/// check holds by construction:
/// - Every node is reachable from `op` through regions or a resolved callee,
///   so it is live, and the walk refuses to complete through a node this
///   context does not track, as `append` says.
/// - The creation boundary is read at construction, after every node exists.
/// - No caller's mutation can come between construction and the answer,
///   because the summary never leaves this function.
/// One premise is not checked: that no effect enumerator mutates IR while
/// the summary is built. An enumerator receives an `EffectSubject`, which
/// offers no path to another operation, and its contract forbids taking one.
/// The contract is not enforced, so an enumerator that breaks it can still
/// change a parent's declaration after it was read, and this answer would
/// then be wrong for the IR it leaves.
/// With currency never asked, no revision is ever read, so none is recorded.
/// A summary that outlives its query, such as a cached one, still records its
/// revisions and asks currency through `all`.
fn answerOnce(op: *ir.Operation, comptime action: EffectSummary.Question) Permission {
    var summary = EffectSummary.initUnrevised(op.allocator, op) catch |err| switch (err) {
        error.OutOfMemory => return .unaffordable,
        // A declaration this operation states wrongly reads the same at every budget.
        else => return .no,
    };
    defer summary.deinit();
    return if (summary.complete and summary.holds(action)) .yes else .no;
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
    return repeatableExpressionPermission(op) == .yes;
}

/// Whether `op` is a repeatable expression, with a shortfall named as `unaffordable`.
pub fn repeatableExpressionPermission(op: *ir.Operation) Permission {
    if (!op.hasInterface(facts.EffectOpInterface)) return .no;
    if (isLeaf(op)) return if (facts.answers(op, .repeatable)) .yes else .no;
    return answerOnce(op, .repeatable);
}

/// `permitsRepeatableExpression` for a caller that only ever asks leaves, as
/// `leafPermitsDiscard` is for discard.
pub fn leafPermitsRepeatableExpression(op: *ir.Operation) bool {
    std.debug.assert(isLeaf(op));
    return op.hasInterface(facts.EffectOpInterface) and facts.answers(op, .repeatable);
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

fn maybeCompleteEffects(subject: facts.EffectSubject, collector: *facts.Collector) void {
    collector.complete = subject.attr("incomplete") == null;
}

/// FORBIDDEN BY THE ENUMERATOR CONTRACT. The three enumerators below reach an operation other
/// than their subject through this pointer, which no subject offers. A test sets it to the
/// operation its enumerator reads or changes. They stand for what the contract excludes and
/// show which guard, if any, still answers for it.
var forbidden_watched: ?*ir.Operation = null;

/// Complete while the watched operation, a child of the subject, lacks `incomplete`.
fn childCompletesEffects(_: facts.EffectSubject, collector: *facts.Collector) void {
    const child = forbidden_watched orelse return;
    collector.complete = child.getAttr("incomplete") == null;
}

fn appendsOneRead(_: facts.EffectSubject, collector: *facts.Collector) void {
    collector.append(.{ .event = .{ .kind = .read } });
}

const nested_latent = facts.Fact{ .region = .{
    .index = 0,
    .execution = .latent,
    .may_diverge = false,
    .captures = false,
} };

/// Declares its region immediate while the watched operation, somewhere below the subject,
/// carries `run`, and latent otherwise, so its declaration reads state no revision spells.
fn readsBelowEffects(_: facts.EffectSubject, collector: *facts.Collector) void {
    collector.complete = true;
    const runs = if (forbidden_watched) |found| found.getAttr("run") != null else false;
    collector.append(.{ .region = .{
        .index = 0,
        .execution = if (runs) .immediate else .latent,
        .may_diverge = false,
        .captures = false,
    } });
}

fn regionOp(ctx: *ir.Context, name: []const u8) !*ir.Operation {
    var state = ir.Operation.State.init(name, .unknown);
    state.addRegion();
    const op = try ctx.createOperation(state);
    _ = try op.regions.items[0].addBlock();
    return op;
}

fn nest(parent: *ir.Operation, child: *ir.Operation) !void {
    try parent.regions.items[0].blocks.front().?.addOperation(child);
}

const missing_call_vtable = callVTable("missing");
const callee_call_vtable = callVTable("callee");

fn callVTable(comptime symbol: []const u8) ir.interfaces.CallOpInterface.VTable {
    return .{
        .getCalleeSymbol = struct {
            fn callee(_: *const anyopaque) ?[]const u8 {
                return symbol;
            }
        }.callee,
        .getCalleeValue = struct {
            fn value(_: *const anyopaque) ?*ir.Value {
                return null;
            }
        }.value,
        .getArgumentValues = struct {
            fn values(_: *const anyopaque) []const *ir.Value {
                return &.{};
            }
        }.values,
        .getArgumentKeywords = struct {
            fn keywords(_: *const anyopaque) []const []const u8 {
                return &.{};
            }
        }.keywords,
    };
}

/// Declares a global write unless its own `pure` attribute is present.
fn writesUnlessPureEffects(subject: facts.EffectSubject, collector: *facts.Collector) void {
    collector.complete = true;
    collector.append(nested_latent);
    if (subject.attr("pure") == null) {
        collector.append(.{ .event = .{
            .kind = .write,
            .resource = .{ .subject = .{ .global = "log" } },
        } });
    }
}

/// Removes the watched operation's `pure` attribute while its own declaration is collected.
fn unmarksWatchedEffects(_: facts.EffectSubject, collector: *facts.Collector) void {
    collector.complete = true;
    const watched = forbidden_watched orelse return;
    _ = watched.removeAttr("pure");
}

const MarkerInterface = struct {
    pub const id = ir.interfaces.interfaceId("test.effects.marker");
    pub const VTable = struct {};
    const vtable = VTable{};
};

/// Declares a failure when its `policy` attribute's kind carries the marker interface.
fn markedPolicyFailsEffects(subject: facts.EffectSubject, collector: *facts.Collector) void {
    collector.complete = true;
    const policy = subject.attr("policy") orelse return;
    if (policy.getInterface(MarkerInterface) != null) {
        collector.append(.{ .event = .{ .kind = .failure } });
    }
}

/// Whether `op`'s revision now differs from `before`, which is replaced by the new one.
fn revisionChanged(op: *ir.Operation, before: *[]usize) !bool {
    const after = try revisionAlloc(std.testing.allocator, op);
    const earlier = before.*;
    defer std.testing.allocator.free(earlier);
    before.* = after;
    return !std.mem.eql(usize, earlier, after);
}

fn declaresFailure(op: *ir.Operation, name: []const u8) !bool {
    var declaration = try facts.inspect(std.testing.allocator, op);
    defer declaration.deinit(std.testing.allocator);
    for (declaration.facts.records) |fact| switch (fact) {
        .event => |event| if (event.failure_name) |declared| {
            if (std.mem.eql(u8, declared, name)) return true;
        },
        else => {},
    };
    return false;
}

/// Fails unless its first operand's literal bytes begin with a nonzero byte.
fn nonzeroBytesEffects(subject: facts.EffectSubject, collector: *facts.Collector) void {
    collector.complete = true;
    const bytes = subject.operandLiteralBytes(0) orelse &[_]u8{0};
    if (bytes.len == 0 or bytes[0] == 0) collector.append(.{ .event = .{ .kind = .failure } });
}

var forbidden_scratch: [1]u8 = undefined;

/// Forbidden: names a string in scratch it writes again on its next call.
fn scratchLabelEffects(subject: facts.EffectSubject, collector: *facts.Collector) void {
    collector.complete = true;
    forbidden_scratch[0] = if (subject.attr("second") == null) 'a' else 'b';
    collector.append(.{ .event = .{
        .kind = .write,
        .resource = .{ .subject = .{ .global = &forbidden_scratch } },
    } });
}
