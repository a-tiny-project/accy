const std = @import("std");
const ir = @import("../core/root.zig");
const dialects = @import("../dialects/root.zig");
const arith_types = @import("../dialects/arith/types.zig");
const pass_mod = @import("pass/root.zig");
const registry_mod = @import("pipeline.zig");
const effects = @import("effects.zig");

const arith = dialects.arith.ArithDialect;
const memref = dialects.memref.MemrefDialect;
const scf = dialects.scf.ScfDialect;
const func_dialect = dialects.func.FuncDialect;

const Pass = pass_mod.Pass;
const PassContext = pass_mod.PassContext;
const PassResult = pass_mod.PassResult;

pub const memory_promotion_pass_name = "choir-mem2reg";
pub const memory_promotion_pass_description =
    "Promote single-cell allocas to SSA values and scf iter args";

const PromotionError = error{
    OutOfMemory,
    InvalidPromotion,
};

/// The operations this pass creates for each operation it is given.
///
/// WHERE AN OPERATION COMES FROM HERE. The pass creates operations in three
/// places and nowhere else. A region a promoted cell is stored inside is
/// rebuilt, because an operation cannot gain a result in place, and a rebuild
/// creates one operation. The rebuilt region's terminators are replaced so
/// they carry the promoted values, which creates one for an `scf.for`, two for
/// an `scf.while`, and one per branch of an `scf.if`. A cell a region carries
/// before anything has stored to it gets a zero constant.
///
/// WHY A CONSTANT AND NOT A COUNT OF CELLS. A region is rebuilt at most once
/// however many cells it carries, so its rebuild and its terminators are
/// charged against the region operation and the terminators the caller handed
/// the pass, and a zero constant is charged against the cell's own
/// `memref.alloca`, which the caller handed it too. No operation of the input
/// is charged by two rebuilds, so three times the operations given holds
/// whatever shape the input has. It is an upper bound and not a measurement:
/// the shapes pinned in this file's tests create fewer.
///
/// WHY A CALLER CARES ABOUT OPERATIONS CREATED AND NOT OPERATIONS KEPT. The
/// segment these operations draw from is a fixed buffer whose free reclaims
/// only the last allocation, so an operation this pass erases holds its bytes
/// for the rest of the compile exactly as a kept one does. A caller sizing
/// that segment multiplies this figure by the operations it will hand over.
pub const operations_created_per_operation: usize = 3;

/// The operations this pass may create given `operations` operations.
///
/// A caller that knows how many operations it will lower calls this instead of
/// reading the constant, so the shape of the bound can change without every
/// caller changing with it.
pub fn operationsCreated(operations: usize) usize {
    return operations_created_per_operation * operations;
}

/// What one run of the pass created, for a caller that wants the figure it
/// paid rather than the bound it was promised.
pub const Created = struct {
    /// Operations the run created, erased ones included.
    operations: usize = 0,
    /// Regions the run rebuilt. Each is rebuilt once however many cells it
    /// carries, so this never passes the regions the caller handed over.
    regions_rebuilt: usize = 0,
};

pub fn createMemoryPromotionPass() Pass {
    return .{
        .name = memory_promotion_pass_name,
        .description = memory_promotion_pass_description,
        .run_fn = runMemoryPromotion,
        .mutation_scope = .whole_module,
    };
}

pub const memory_promotion_pass_registration = registry_mod.PassRegistration{
    .name = memory_promotion_pass_name,
    .description = memory_promotion_pass_description,
    .pass = createMemoryPromotionPass(),
};

/// Promotes every local cell under `op`, and answers whether anything moved.
///
/// The pass above is how a pipeline asks for this. This is how a caller that
/// runs no pipeline asks for the same thing, which is what the x86_64 backend
/// does: it lowers one module and the page and the file are both read from
/// that module, so a transform it runs is seen by both or by neither.
pub fn promote(op: *ir.Operation, allocator: std.mem.Allocator) PromotionError!bool {
    var created = Created{};
    return promoteCounting(op, allocator, &created);
}

/// Promotes as `promote` does and reports what the run created.
///
/// A caller that sizes the context this module is built in reads `created` to
/// see what the run spent, against `operationsCreated` for what it was allowed
/// to spend.
pub fn promoteCounting(
    op: *ir.Operation,
    allocator: std.mem.Allocator,
    created: *Created,
) PromotionError!bool {
    var modified = false;
    try promoteInOp(op, allocator, &modified, created);
    return modified;
}

fn runMemoryPromotion(ctx: *PassContext) PassResult {
    var modified = false;
    var created = Created{};
    promoteInOp(ctx.op, ctx.allocator, &modified, &created) catch return .failure;
    if (modified) {
        ctx.markModified();
    } else {
        ctx.preserveAllAnalyses();
    }
    return .success;
}

fn promoteInOp(
    op: *ir.Operation,
    allocator: std.mem.Allocator,
    modified: *bool,
    created: *Created,
) !void {
    if (std.mem.eql(u8, op.name.name, func_dialect.FuncOp.operation_name)) {
        if (op.getRegion(0)) |region| {
            if (region.getEntryBlock()) |entry| {
                try promoteFunction(entry, allocator, modified, created);
            }
        }
        return;
    }
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                const next = current_op.next_op;
                try promoteInOp(current_op, allocator, modified, created);
                current = next;
            }
        }
    }
}

/// Replaces the accesses of every local cell with the values they carried.
///
/// THE ALLOCATION IS LEFT WHERE IT STANDS. The permission this asks for covers
/// the reads and the writes and nothing else: an allocation can still fail, and
/// a failure is an event no derivation here discharges. Removing the `alloca`
/// would delete that failure along with the bytes, and a program that cannot
/// run out of stack is not the program the footprint charged. A later pass that
/// can state the failure is dead may remove it.
///
/// THE CELLS OF ONE BLOCK TRAVEL TOGETHER. A rewrite is run once per block that
/// declares cells, carrying every cell that block declares, so an `scf` region
/// is rebuilt at most once however many cells it holds. Cells are grouped in
/// the order they were collected, which is outer before inner, and each cell's
/// block is read when its group is reached, because an outer rewrite moves the
/// operations of an inner block into the block it built.
fn promoteFunction(
    entry: *ir.Block,
    allocator: std.mem.Allocator,
    modified: *bool,
    created: *Created,
) !void {
    var allocas = std.ArrayListUnmanaged(*ir.Operation).empty;
    defer allocas.deinit(allocator);
    try collectAllocas(entry, allocator, &allocas);

    var cells = std.ArrayListUnmanaged(Cell).empty;
    defer cells.deinit(allocator);
    for (allocas.items) |alloca| {
        switch (effects.permitsDiscardingLocalAccesses(alloca)) {
            .yes => {},
            .no => continue,
            .unaffordable => return error.OutOfMemory,
        }
        if (!allUsesArePromotable(alloca)) continue;
        const element = elementType(alloca) orelse continue;
        const cell = alloca.getResult(0) orelse continue;
        try cells.append(allocator, .{ .alloca = alloca, .value = cell, .element_type = element });
    }
    if (cells.items.len == 0) return;

    const grouped = try allocator.alloc(bool, cells.items.len);
    defer allocator.free(grouped);
    @memset(grouped, false);

    var group = std.ArrayListUnmanaged(Cell).empty;
    defer group.deinit(allocator);

    for (cells.items, 0..) |first, index| {
        if (grouped[index]) continue;
        const block = first.alloca.getBlock() orelse {
            grouped[index] = true;
            continue;
        };

        group.clearRetainingCapacity();
        var start: ?*ir.Operation = null;
        for (cells.items[index..], index..) |candidate, at| {
            if (grouped[at]) continue;
            if (candidate.alloca.getBlock() != block) continue;
            grouped[at] = true;
            if (!analyzeFrom(candidate.alloca, block, false).ok) continue;
            if (start == null) start = candidate.alloca.next_op;
            try group.append(allocator, candidate);
        }
        if (group.items.len == 0) continue;

        const values = try allocator.alloc(?*ir.Value, group.items.len);
        defer allocator.free(values);
        @memset(values, null);

        var promotion = Promotion{
            .allocator = allocator,
            .ctx = first.alloca.context,
            .cells = group.items,
            .created = created,
        };
        try promotion.rewriteBlock(block, start, values);
        if (promotion.changed) modified.* = true;
    }
}

fn collectAllocas(block: *ir.Block, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(*ir.Operation)) !void {
    var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
    while (current) |op| {
        const next = op.next_op;
        if (std.mem.eql(u8, op.name.name, memref.AllocaOp.operation_name)) {
            try out.append(allocator, op);
        }
        for (op.regions.items) |*region| {
            var block_iter = region.getBlocks();
            while (block_iter.next()) |nested| {
                try collectAllocas(nested, allocator, out);
            }
        }
        current = next;
    }
}

fn elementType(alloca: *ir.Operation) ?ir.Type {
    const result = alloca.getResult(0) orelse return null;
    const name = result.type.getDialectTypeName() orelse return null;
    const params = result.type.getDialectParamKey() orelse return null;
    _ = name;
    const parsed = memref.parseMemrefParams(params) orelse return null;
    if (parsed.size) |size| {
        if (size != 1) return null;
    } else {
        return null;
    }
    const ctx = alloca.context;
    return ctx.getDialectTypeFromName(parsed.element_type_name) catch null;
}

/// Whether this pass can MODEL every use, which is a narrower question than
/// whether discarding them is permitted.
///
/// The permission comes from `effects.permitsDiscardingLocalAccesses`, which
/// reads the declarations. What is left here is arithmetic this pass does: one
/// SSA value stands for one cell, so a second cell has nowhere to go, and the
/// value that stands for it is only the right one when every access names the
/// same cell, which a literal index at zero is what this pass knows how to
/// check.
fn allUsesArePromotable(alloca: *ir.Operation) bool {
    const cell = alloca.getResult(0) orelse return false;
    if (elementType(alloca) == null) return false;
    var use = cell.first_use;
    while (use) |operand| {
        const owner: *ir.Operation = @ptrCast(@alignCast(operand.owner));
        if (std.mem.eql(u8, owner.name.name, memref.LoadOp.operation_name)) {
            if (operand.operand_number != 0) return false;
            if (!indexIsZero(owner, 1)) return false;
        } else if (std.mem.eql(u8, owner.name.name, memref.StoreOp.operation_name)) {
            if (operand.operand_number != 1) return false;
            if (!indexIsZero(owner, 2)) return false;
        } else {
            return false;
        }
        use = operand.next_use;
    }
    return true;
}

fn indexIsZero(op: *ir.Operation, operand_index: usize) bool {
    const index_value = op.getOperand(operand_index) orelse return false;
    const defining = index_value.getDefiningOp() orelse return false;
    const defining_op: *ir.Operation = @ptrCast(@alignCast(defining));
    if (!std.mem.eql(u8, defining_op.name.name, arith.ConstantOp.operation_name)) return false;
    const value = (arith.ConstantOp{ .op = defining_op }).getIntValue() orelse return false;
    return value == 0;
}

const Analysis = struct {
    ok: bool,
    defined: bool,
    stores: bool,
};

fn analyzeFrom(alloca: *ir.Operation, block: *ir.Block, defined_at_entry: bool) Analysis {
    return analyzeOps(alloca, if (block == alloca.getBlock()) alloca.next_op else firstOp(block), defined_at_entry);
}

fn firstOp(block: *ir.Block) ?*ir.Operation {
    return @ptrCast(@alignCast(block.operations.head));
}

fn analyzeOps(alloca: *ir.Operation, start: ?*ir.Operation, defined_at_entry: bool) Analysis {
    const cell = alloca.getResult(0) orelse return .{ .ok = false, .defined = false, .stores = false };
    var defined = defined_at_entry;
    var stores = false;
    var current = start;
    while (current) |op| {
        const next = op.next_op;
        if (std.mem.eql(u8, op.name.name, memref.LoadOp.operation_name) and op.getOperand(0) == cell) {
            if (!defined) return .{ .ok = false, .defined = defined, .stores = stores };
        } else if (std.mem.eql(u8, op.name.name, memref.StoreOp.operation_name) and op.getOperand(1) == cell) {
            defined = true;
            stores = true;
        } else if (op.regions.items.len != 0) {
            if (!subtreeUsesCell(op, cell)) {
                current = next;
                continue;
            }
            if (std.mem.eql(u8, op.name.name, scf.ForOp.operation_name)) {
                const body = (scf.ForOp{ .op = op }).getBodyBlock();
                const body_result = analyzeOps(alloca, firstOp(body), defined);
                if (!body_result.ok) return .{ .ok = false, .defined = defined, .stores = stores };
                stores = stores or body_result.stores;
            } else if (std.mem.eql(u8, op.name.name, scf.WhileOp.operation_name)) {
                const loop = analyzeWhile(alloca, op, defined);
                if (!loop.ok) return .{ .ok = false, .defined = defined, .stores = stores };
                defined = loop.defined;
                stores = stores or loop.stores;
            } else if (std.mem.eql(u8, op.name.name, scf.IfOp.operation_name)) {
                const if_op = scf.IfOp{ .op = op };
                const then_result = analyzeOps(alloca, firstOp(if_op.getThenBlock()), defined);
                if (!then_result.ok) return .{ .ok = false, .defined = defined, .stores = stores };
                var else_defined = defined;
                var else_stores = false;
                if (if_op.getElseBlock()) |else_block| {
                    const else_result = analyzeOps(alloca, firstOp(else_block), defined);
                    if (!else_result.ok) return .{ .ok = false, .defined = defined, .stores = stores };
                    else_defined = else_result.defined;
                    else_stores = else_result.stores;
                }
                defined = then_result.defined and else_defined;
                stores = stores or then_result.stores or else_stores;
            } else {
                return .{ .ok = false, .defined = defined, .stores = stores };
            }
        }
        current = next;
    }
    return .{ .ok = true, .defined = defined, .stores = stores };
}

/// A `scf.while` runs its before block at least once and its after block zero
/// or more times, each time after a before block. So the after block starts
/// with whatever the before block defined, and after the loop the cell is
/// defined exactly when the before block defines it.
///
/// A later trip through the before block starts at least as defined as the
/// first, because a trip through the after block only adds definitions, so
/// checking the first trip is enough.
fn analyzeWhile(alloca: *ir.Operation, op: *ir.Operation, defined: bool) Analysis {
    const loop = scf.WhileOp{ .op = op };
    const before = analyzeOps(alloca, firstOp(loop.getBeforeBlock()), defined);
    if (!before.ok) return .{ .ok = false, .defined = defined, .stores = false };
    const after = analyzeOps(alloca, firstOp(loop.getAfterBlock()), before.defined);
    if (!after.ok) return .{ .ok = false, .defined = defined, .stores = false };
    return .{ .ok = true, .defined = before.defined, .stores = before.stores or after.stores };
}

fn subtreeUsesCell(op: *ir.Operation, cell: *ir.Value) bool {
    for (op.operands.items) |operand| {
        if (operand.value == cell) return true;
    }
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |nested| {
                if (subtreeUsesCell(nested, cell)) return true;
                current = nested.next_op;
            }
        }
    }
    return false;
}

/// A local cell the pass promotes, and the type of the value it held.
const Cell = struct {
    alloca: *ir.Operation,
    value: *ir.Value,
    element_type: ir.Type,
};

/// Nested context bytes one region rewrite consumes for its own splice before
/// the cells it carries are counted, not counting the rewrites nested inside
/// it, which reserve for themselves.
///
/// MEASURED AND NOT DERIVED. Over the nested-loop reproducer and two
/// generated nests, one splice took between 992 and 4576 bytes at cell counts
/// of 1, 2, 8 and 12, the widest being a twelve cell block. This pair holds at
/// least 1.5 times the widest measured point at every one of those counts. A
/// rewrite that outgrows the pair exhausts the segment after it has begun
/// mutating, and `refuseOutgrownRewrite` turns that into a refusal at the end
/// of the rewrite rather than leaving a module for a later reader to trip
/// over. A bound derived from the new operations, blocks and carried values
/// would replace this measurement.
pub const rewrite_bytes_base: usize = 1024;

/// Nested context bytes one region rewrite consumes for each cell it carries.
/// Read `rewrite_bytes_base` above for what the pair was measured against.
pub const rewrite_bytes_per_cell: usize = 512;

/// The nested context bytes one region rewrite reserves before it mutates
/// anything, carrying `cells` cells.
///
/// A caller sizing `operation_nested` calls this instead of reading the two
/// constants, so the shape of the bound can change without every caller
/// changing with it.
pub fn rewriteBytes(cells: usize) usize {
    return rewrite_bytes_base + rewrite_bytes_per_cell * cells;
}

/// Rewrites one block and everything below it, carrying every cell at once.
///
/// A REGION IS REBUILT AT MOST ONCE. An `scf` region a promoted cell is stored
/// inside gains a carried value, and the operation holding that region cannot
/// gain a result in place, so it is rebuilt. Rebuilding once per cell would
/// create one operation per cell and per region, and the context segment these
/// operations draw from is a bump allocator, so the storage an erased operation
/// held stays spent for the rest of the compile. Carrying every cell of a block
/// through one walk keeps the operations this pass creates proportional to the
/// operations it was given.
const Promotion = struct {
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    cells: []const Cell,
    created: *Created,
    changed: bool = false,

    /// Refuses before the first mutation when `operation_nested` cannot hold
    /// the splice this rewrite is about to perform.
    ///
    /// WHY A RESERVATION AND NOT A ROLLBACK. A rewrite creates the new region,
    /// splices it into the parent, moves the body across, and only then erases
    /// the old one. A shortfall anywhere between those steps leaves a module
    /// Choir's own verifier rejects, and there is no
    /// undo to run. So the one failure point is moved in front of the first
    /// mutation and the steps after it are reached only when the bytes are
    /// already there.
    ///
    /// WHAT IT GUARDS AND WHAT IT DOES NOT. It guards the three region
    /// rewrites, which are the steps that leave a module the verifier rejects
    /// when they stop halfway. It does not guard the walk that reaches them:
    /// `rewriteBlock` replaces a block's own loads and stores with the values
    /// last stored as it goes, so a refusal deeper in the nest leaves those
    /// already replaced. The module is then SMALLER than the one that went in
    /// and it still verifies, because replacing a load with the value last
    /// stored is a complete edit on its own. A pass that refuses leaves a
    /// valid module, not an untouched one.
    ///
    /// IT ASKS THE SEGMENT RATHER THAN READING ITS HEADROOM. A request the
    /// segment cannot serve is how the segment learns which one ran short and
    /// by how much, and that record is what the driver turns into a refusal
    /// naming the capacity and the flag. A reservation that only compared
    /// figures would refuse with nothing to say. The bytes come straight back:
    /// the segment bumps, and this was the last allocation in it.
    fn reserveRewrite(self: *Promotion) PromotionError!void {
        const allocator = ir.context.operationAllocator(self.ctx);
        const held = allocator.alloc(u8, rewriteBytes(self.cells.len)) catch
            return error.OutOfMemory;
        allocator.free(held);
    }

    /// Refuses when the splice outgrew the reservation it was taken under.
    ///
    /// ON THE PATH THAT FINISHED, AND NOT ON THE PATH THAT REFUSED. A rewrite
    /// nested inside this one refuses by asking the segment for its own
    /// reservation and being told no, and that request is recorded on the
    /// context. A refusal leaves through the error and never reaches here, so
    /// an exhaustion recorded at the end of a rewrite that COMPLETED means
    /// this splice outgrew the bytes it reserved and a shortfall inside it was
    /// swallowed, which is the defect this file is fixing.
    ///
    /// WHY A REFUSAL AND NOT AN ASSERTION. An assertion is compiled out of a
    /// release build, so the one shape that outgrew the bound would emit an
    /// object in release and say nothing, which is the class of defect this
    /// pass exists to close. This is one load and one compare per rebuilt
    /// region. The refusal is safe to take because nothing reads the module
    /// after it: `promote` returns the error, the backend maps it to
    /// `BackendError.OutOfMemory`, and the consumer's `measureModule` forgets
    /// every measurement and writes no object.
    fn refuseOutgrownRewrite(self: *Promotion) PromotionError!void {
        if (self.ctx.exhaustion() != null) return error.OutOfMemory;
    }

    /// The value each cell holds at the point the walk has reached. A null
    /// entry is a cell nothing has stored to yet, which a load may not read.
    /// Every `values` slice below holds one entry per cell, in cell order.
    fn rewriteBlock(
        self: *Promotion,
        block: *ir.Block,
        start: ?*ir.Operation,
        values: []?*ir.Value,
    ) PromotionError!void {
        std.debug.assert(values.len == self.cells.len);
        var current = start;
        while (current) |op| {
            const next = op.next_op;
            if (self.loadedCell(op)) |index| {
                const loaded = op.getResult(0) orelse return error.InvalidPromotion;
                const replacement = values[index] orelse return error.InvalidPromotion;
                loaded.replaceAllUsesWith(replacement);
                op.erase();
                self.changed = true;
            } else if (self.storedCell(op)) |index| {
                values[index] = op.getOperand(0) orelse return error.InvalidPromotion;
                op.erase();
                self.changed = true;
            } else if (op.regions.items.len != 0 and self.subtreeUsesAnyCell(op)) {
                if (std.mem.eql(u8, op.name.name, scf.ForOp.operation_name)) {
                    try self.rewriteFor(block, op, values);
                } else if (std.mem.eql(u8, op.name.name, scf.WhileOp.operation_name)) {
                    try self.rewriteWhile(block, op, values);
                } else if (std.mem.eql(u8, op.name.name, scf.IfOp.operation_name)) {
                    try self.rewriteIf(block, op, values);
                } else {
                    return error.InvalidPromotion;
                }
            }
            current = next;
        }
    }

    fn loadedCell(self: *Promotion, op: *ir.Operation) ?usize {
        if (!std.mem.eql(u8, op.name.name, memref.LoadOp.operation_name)) return null;
        return self.cellIndex(op.getOperand(0) orelse return null);
    }

    fn storedCell(self: *Promotion, op: *ir.Operation) ?usize {
        if (!std.mem.eql(u8, op.name.name, memref.StoreOp.operation_name)) return null;
        return self.cellIndex(op.getOperand(1) orelse return null);
    }

    fn cellIndex(self: *Promotion, value: *ir.Value) ?usize {
        for (self.cells, 0..) |cell, index| {
            if (cell.value == value) return index;
        }
        return null;
    }

    fn subtreeUsesAnyCell(self: *Promotion, op: *ir.Operation) bool {
        for (self.cells) |cell| {
            if (subtreeUsesCell(op, cell.value)) return true;
        }
        return false;
    }

    /// The cells a region stores to, and how many of them there are. A cell the
    /// region only reads keeps the value it had outside, so it is not carried.
    const Carried = struct {
        flags: []bool,
        count: usize,
    };

    fn carriedBuffer(self: *Promotion) PromotionError![]bool {
        const flags = self.allocator.alloc(bool, self.cells.len) catch return error.OutOfMemory;
        @memset(flags, false);
        return flags;
    }

    fn valuesBuffer(self: *Promotion, from: []?*ir.Value) PromotionError![]?*ir.Value {
        const copied = self.allocator.alloc(?*ir.Value, self.cells.len) catch return error.OutOfMemory;
        @memcpy(copied, from);
        return copied;
    }

    /// Collects the carried values a rebuilt region receives, in cell order,
    /// and the type of each, so the inits and the results agree on the order.
    fn collectCarried(
        self: *Promotion,
        carried: Carried,
        values: []?*ir.Value,
        parent: *ir.Block,
        before: *ir.Operation,
        loc: ir.Location,
        inits: *std.ArrayListUnmanaged(*ir.Value),
        result_types: *std.ArrayListUnmanaged(ir.Type),
    ) PromotionError!void {
        for (self.cells, 0..) |cell, index| {
            if (!carried.flags[index]) continue;
            const init_value = values[index] orelse try self.zeroValue(cell, parent, before, loc);
            try inits.append(self.allocator, init_value);
            try result_types.append(self.allocator, cell.element_type);
        }
    }

    /// Points `values` at the carried arguments a rebuilt block receives.
    fn bindCarried(
        self: *Promotion,
        carried: Carried,
        block: *ir.Block,
        values: []?*ir.Value,
    ) void {
        const base = block.arguments.items.len - carried.count;
        var rank: usize = 0;
        for (self.cells, 0..) |_, index| {
            if (!carried.flags[index]) continue;
            values[index] = block.arguments.items[base + rank];
            rank += 1;
        }
    }

    fn rewriteFor(
        self: *Promotion,
        parent: *ir.Block,
        old_op: *ir.Operation,
        values: []?*ir.Value,
    ) PromotionError!void {
        try self.reserveRewrite();
        const old_for = scf.ForOp{ .op = old_op };
        const old_body = old_for.getBodyBlock();

        const flags = try self.carriedBuffer();
        defer self.allocator.free(flags);
        var count: usize = 0;
        for (self.cells, 0..) |cell, index| {
            const body = analyzeOps(cell.alloca, firstOp(old_body), values[index] != null);
            flags[index] = body.stores;
            if (body.stores) count += 1;
        }
        const carried = Carried{ .flags = flags, .count = count };

        if (count == 0) {
            try self.rewriteBlock(old_body, firstOp(old_body), values);
            return;
        }

        const loc = old_op.getLoc();

        var inits = std.ArrayListUnmanaged(*ir.Value).empty;
        defer inits.deinit(self.allocator);
        for (old_op.operands.items[3..]) |operand| {
            try inits.append(self.allocator, operand.value);
        }

        var result_types = std.ArrayListUnmanaged(ir.Type).empty;
        defer result_types.deinit(self.allocator);
        for (old_op.results.items) |result| {
            try result_types.append(self.allocator, result.type);
        }

        try self.collectCarried(carried, values, parent, old_op, loc, &inits, &result_types);

        const new_for = scf.ForOp.create(
            self.ctx,
            loc,
            old_for.getLowerBound(),
            old_for.getUpperBound(),
            old_for.getStep(),
            inits.items,
            result_types.items,
        ) catch return error.OutOfMemory;
        parent.addOperation(new_for.op) catch return error.OutOfMemory;
        new_for.op.moveBefore(old_op) catch return error.OutOfMemory;

        const new_body = new_for.getBodyBlock();
        try self.moveBlockBody(old_body, new_body);
        for (old_op.results.items, 0..) |*old_result, index| {
            old_result.replaceAllUsesWith(new_for.op.getResult(index) orelse return error.InvalidPromotion);
        }
        old_op.erase();

        const body_values = try self.valuesBuffer(values);
        defer self.allocator.free(body_values);
        self.bindCarried(carried, new_body, body_values);

        const entering = try self.valuesBuffer(body_values);
        defer self.allocator.free(entering);

        try self.rewriteBlock(new_body, firstOp(new_body), body_values);
        try self.extendYield(new_body, loc, carried, body_values, entering);
        try self.takeResults(carried, new_for.op, values);
        self.created.operations += 1;
        self.created.regions_rebuilt += 1;
        self.changed = true;
        try self.refuseOutgrownRewrite();
    }

    /// Rebuilds a `scf.while` that stores cells with those cells' values as
    /// more carried values. The before block receives them, forwards what it
    /// holds at the condition to both the after block and the loop's results,
    /// and the after block yields them back.
    fn rewriteWhile(
        self: *Promotion,
        parent: *ir.Block,
        old_op: *ir.Operation,
        values: []?*ir.Value,
    ) PromotionError!void {
        try self.reserveRewrite();
        const old_while = scf.WhileOp{ .op = old_op };
        const old_before = old_while.getBeforeBlock();
        const old_after = old_while.getAfterBlock();

        const flags = try self.carriedBuffer();
        defer self.allocator.free(flags);
        var count: usize = 0;
        for (self.cells, 0..) |cell, index| {
            const loop = analyzeWhile(cell.alloca, old_op, values[index] != null);
            std.debug.assert(loop.ok);
            flags[index] = loop.stores;
            if (loop.stores) count += 1;
        }
        const carried = Carried{ .flags = flags, .count = count };

        if (count == 0) {
            const before_values = try self.valuesBuffer(values);
            defer self.allocator.free(before_values);
            try self.rewriteBlock(old_before, firstOp(old_before), before_values);
            const after_values = try self.valuesBuffer(values);
            defer self.allocator.free(after_values);
            try self.rewriteBlock(old_after, firstOp(old_after), after_values);
            return;
        }

        const loc = old_op.getLoc();

        var inits = std.ArrayListUnmanaged(*ir.Value).empty;
        defer inits.deinit(self.allocator);
        for (old_op.operands.items) |operand| {
            try inits.append(self.allocator, operand.value);
        }

        var result_types = std.ArrayListUnmanaged(ir.Type).empty;
        defer result_types.deinit(self.allocator);
        for (old_op.results.items) |result| {
            try result_types.append(self.allocator, result.type);
        }

        try self.collectCarried(carried, values, parent, old_op, loc, &inits, &result_types);

        const new_while = scf.WhileOp.create(self.ctx, loc, inits.items, result_types.items) catch
            return error.OutOfMemory;
        parent.addOperation(new_while.op) catch return error.OutOfMemory;
        new_while.op.moveBefore(old_op) catch return error.OutOfMemory;

        const new_before = new_while.getBeforeBlock();
        const new_after = new_while.getAfterBlock();
        try self.moveBlockBody(old_before, new_before);
        try self.moveBlockBody(old_after, new_after);
        for (old_op.results.items, 0..) |*old_result, index| {
            old_result.replaceAllUsesWith(
                new_while.op.getResult(index) orelse return error.InvalidPromotion,
            );
        }
        old_op.erase();

        const before_values = try self.valuesBuffer(values);
        defer self.allocator.free(before_values);
        self.bindCarried(carried, new_before, before_values);
        const before_entering = try self.valuesBuffer(before_values);
        defer self.allocator.free(before_entering);

        try self.rewriteBlock(new_before, firstOp(new_before), before_values);
        try self.extendCondition(new_before, loc, carried, before_values, before_entering);

        const after_values = try self.valuesBuffer(values);
        defer self.allocator.free(after_values);
        self.bindCarried(carried, new_after, after_values);
        const after_entering = try self.valuesBuffer(after_values);
        defer self.allocator.free(after_entering);

        try self.rewriteBlock(new_after, firstOp(new_after), after_values);
        try self.extendYield(new_after, loc, carried, after_values, after_entering);

        try self.takeResults(carried, new_while.op, values);
        self.created.operations += 1;
        self.created.regions_rebuilt += 1;
        self.changed = true;
        try self.refuseOutgrownRewrite();
    }

    fn rewriteIf(
        self: *Promotion,
        parent: *ir.Block,
        old_op: *ir.Operation,
        values: []?*ir.Value,
    ) PromotionError!void {
        try self.reserveRewrite();
        const old_if = scf.IfOp{ .op = old_op };
        const old_then = old_if.getThenBlock();
        const old_else = old_if.getElseBlock();

        const flags = try self.carriedBuffer();
        defer self.allocator.free(flags);
        var count: usize = 0;
        for (self.cells, 0..) |cell, index| {
            const defined = values[index] != null;
            const then_branch = analyzeOps(cell.alloca, firstOp(old_then), defined);
            const else_stores = if (old_else) |block|
                analyzeOps(cell.alloca, firstOp(block), defined).stores
            else
                false;
            flags[index] = then_branch.stores or else_stores;
            if (flags[index]) count += 1;
        }
        const carried = Carried{ .flags = flags, .count = count };

        if (count == 0) {
            const then_values = try self.valuesBuffer(values);
            defer self.allocator.free(then_values);
            try self.rewriteBlock(old_then, firstOp(old_then), then_values);
            if (old_else) |block| {
                const else_values = try self.valuesBuffer(values);
                defer self.allocator.free(else_values);
                try self.rewriteBlock(block, firstOp(block), else_values);
            }
            return;
        }

        const loc = old_op.getLoc();

        var result_types = std.ArrayListUnmanaged(ir.Type).empty;
        defer result_types.deinit(self.allocator);
        for (old_op.results.items) |result| {
            try result_types.append(self.allocator, result.type);
        }
        for (self.cells, 0..) |cell, index| {
            if (!carried.flags[index]) continue;
            try result_types.append(self.allocator, cell.element_type);
        }

        const new_if = scf.IfOp.create(
            self.ctx,
            loc,
            old_if.getCondition(),
            result_types.items,
        ) catch return error.OutOfMemory;
        parent.addOperation(new_if.op) catch return error.OutOfMemory;
        new_if.op.moveBefore(old_op) catch return error.OutOfMemory;

        const new_then = new_if.getThenBlock();
        const new_else = new_if.getElseBlock() orelse return error.InvalidPromotion;
        try self.moveBranch(old_then, new_then);
        if (old_else) |block| {
            try self.moveBranch(block, new_else);
        }

        for (old_op.results.items, 0..) |*old_result, index| {
            old_result.replaceAllUsesWith(new_if.op.getResult(index) orelse return error.InvalidPromotion);
        }
        old_op.erase();

        const then_values = try self.valuesBuffer(values);
        defer self.allocator.free(then_values);
        try self.rewriteBlock(new_then, firstOp(new_then), then_values);
        try self.extendBranchYield(new_then, loc, carried, then_values, values);

        const else_values = try self.valuesBuffer(values);
        defer self.allocator.free(else_values);
        try self.rewriteBlock(new_else, firstOp(new_else), else_values);
        try self.extendBranchYield(new_else, loc, carried, else_values, values);

        try self.takeResults(carried, new_if.op, values);
        self.created.operations += 1;
        self.created.regions_rebuilt += 1;
        self.changed = true;
        try self.refuseOutgrownRewrite();
    }

    /// Points `values` at the carried results a rebuilt operation returns.
    fn takeResults(
        self: *Promotion,
        carried: Carried,
        op: *ir.Operation,
        values: []?*ir.Value,
    ) PromotionError!void {
        const base = op.results.items.len - carried.count;
        var rank: usize = 0;
        for (self.cells, 0..) |_, index| {
            if (!carried.flags[index]) continue;
            values[index] = op.getResult(base + rank) orelse return error.InvalidPromotion;
            rank += 1;
        }
    }

    /// Moves every operation of `from` into `to` and points uses of `from`'s
    /// arguments at the arguments `to` holds in the same positions. `to` may
    /// hold more arguments than `from`.
    fn moveBlockBody(self: *Promotion, from: *ir.Block, to: *ir.Block) PromotionError!void {
        std.debug.assert(from.arguments.items.len <= to.arguments.items.len);
        try self.moveBranch(from, to);
        for (from.arguments.items, 0..) |old_arg, index| {
            old_arg.replaceAllUsesWith(to.arguments.items[index]);
        }
    }

    fn moveBranch(self: *Promotion, from: *ir.Block, to: *ir.Block) PromotionError!void {
        _ = self;
        var op_iter: ?*ir.Operation = @ptrCast(@alignCast(from.operations.head));
        while (op_iter) |moved| {
            const next = moved.next_op;
            moved.moveToEnd(to) catch return error.OutOfMemory;
            op_iter = next;
        }
    }

    /// The value each carried cell leaves a region with, in cell order. A cell
    /// the walk left holding nothing leaves with what it entered holding.
    fn finalValues(
        self: *Promotion,
        carried: Carried,
        values: []?*ir.Value,
        entering: []const ?*ir.Value,
        out: *std.ArrayListUnmanaged(*ir.Value),
    ) PromotionError!void {
        for (self.cells, 0..) |_, index| {
            if (!carried.flags[index]) continue;
            const final = values[index] orelse entering[index] orelse return error.InvalidPromotion;
            try out.append(self.allocator, final);
        }
    }

    fn extendYield(
        self: *Promotion,
        block: *ir.Block,
        loc: ir.Location,
        carried: Carried,
        values: []?*ir.Value,
        entering: []const ?*ir.Value,
    ) PromotionError!void {
        const yield_op = lastOp(block) orelse return error.InvalidPromotion;
        if (!std.mem.eql(u8, yield_op.name.name, scf.YieldOp.operation_name)) return error.InvalidPromotion;
        var yields = std.ArrayListUnmanaged(*ir.Value).empty;
        defer yields.deinit(self.allocator);
        for (yield_op.operands.items) |operand| {
            try yields.append(self.allocator, operand.value);
        }
        try self.finalValues(carried, values, entering, &yields);
        const new_yield = scf.YieldOp.create(self.ctx, loc, yields.items) catch return error.OutOfMemory;
        block.addOperation(new_yield.op) catch return error.OutOfMemory;
        new_yield.op.moveBefore(yield_op) catch return error.OutOfMemory;
        yield_op.erase();
        self.created.operations += 1;
    }

    /// A branch of an `scf.if` may hold no terminator yet, so this adds one
    /// when the branch has none and extends the one it has otherwise.
    fn extendBranchYield(
        self: *Promotion,
        block: *ir.Block,
        loc: ir.Location,
        carried: Carried,
        values: []?*ir.Value,
        entering: []const ?*ir.Value,
    ) PromotionError!void {
        var yields = std.ArrayListUnmanaged(*ir.Value).empty;
        defer yields.deinit(self.allocator);
        const existing = lastOp(block);
        const extends = existing != null and
            std.mem.eql(u8, existing.?.name.name, scf.YieldOp.operation_name);
        if (extends) {
            for (existing.?.operands.items) |operand| {
                try yields.append(self.allocator, operand.value);
            }
        }
        try self.finalValues(carried, values, entering, &yields);
        const new_yield = scf.YieldOp.create(self.ctx, loc, yields.items) catch return error.OutOfMemory;
        block.addOperation(new_yield.op) catch return error.OutOfMemory;
        if (extends) {
            new_yield.op.moveBefore(existing.?) catch return error.OutOfMemory;
            existing.?.erase();
        }
        self.created.operations += 1;
    }

    fn extendCondition(
        self: *Promotion,
        block: *ir.Block,
        loc: ir.Location,
        carried: Carried,
        values: []?*ir.Value,
        entering: []const ?*ir.Value,
    ) PromotionError!void {
        const condition_op = lastOp(block) orelse return error.InvalidPromotion;
        if (!std.mem.eql(u8, condition_op.name.name, scf.ConditionOp.operation_name)) {
            return error.InvalidPromotion;
        }
        const old_condition = scf.ConditionOp{ .op = condition_op };
        var forwarded = std.ArrayListUnmanaged(*ir.Value).empty;
        defer forwarded.deinit(self.allocator);
        for (condition_op.operands.items[1..]) |operand| {
            try forwarded.append(self.allocator, operand.value);
        }
        try self.finalValues(carried, values, entering, &forwarded);
        const new_condition = scf.ConditionOp.create(
            self.ctx,
            loc,
            old_condition.getCondition(),
            forwarded.items,
        ) catch return error.OutOfMemory;
        block.addOperation(new_condition.op) catch return error.OutOfMemory;
        new_condition.op.moveBefore(condition_op) catch return error.OutOfMemory;
        condition_op.erase();
        self.created.operations += 1;
    }

    fn zeroValue(
        self: *Promotion,
        cell: Cell,
        parent: *ir.Block,
        before: *ir.Operation,
        loc: ir.Location,
    ) PromotionError!*ir.Value {
        const name = cell.element_type.getDialectTypeName() orelse return error.InvalidPromotion;
        const kind = arith_types.scalarKindFromTypeName(name) orelse return error.InvalidPromotion;
        const constant = if (arith_types.scalarDescriptor(kind).class == .float)
            arith.ConstantOp.createFloat(self.ctx, loc, cell.element_type, 0.0) catch return error.OutOfMemory
        else if (kind == .bool)
            arith.ConstantOp.createBool(self.ctx, loc, false) catch return error.OutOfMemory
        else
            arith.ConstantOp.createInt(self.ctx, loc, cell.element_type, 0) catch return error.OutOfMemory;
        parent.addOperation(constant.op) catch return error.OutOfMemory;
        constant.op.moveBefore(before) catch return error.OutOfMemory;
        self.created.operations += 1;
        var mutable = constant;
        return mutable.getResult();
    }
};

fn lastOp(block: *ir.Block) ?*ir.Operation {
    return @ptrCast(@alignCast(block.operations.tail));
}

const testing = std.testing;

fn runPromotion(allocator: std.mem.Allocator, module: *ir.Operation) !bool {
    var manager = pass_mod.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createMemoryPromotionPass());
    try testing.expectEqual(PassResult.success, manager.run(module, module.context));
    return manager.stats.passes_modified > 0;
}

fn countOps(op: *ir.Operation, name: []const u8) usize {
    var count: usize = 0;
    if (std.mem.eql(u8, op.name.name, name)) count += 1;
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |nested| {
                count += countOps(nested, name);
                current = nested.next_op;
            }
        }
    }
    return count;
}

const TestFunction = struct {
    ctx: ir.Context,
    module: dialects.builtin.BuiltinDialect.ModuleOp,
    func: func_dialect.FuncOp,
    alloca: memref.AllocaOp,
    zero: *ir.Value,

    fn init(allocator: std.mem.Allocator) !*TestFunction {
        const self = try allocator.create(TestFunction);
        self.ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        errdefer self.ctx.deinit(allocator);
        try dialects.registerAllDialects(&self.ctx);
        const loc = ir.Location.getUnknown();
        self.module = try dialects.builtin.BuiltinDialect.ModuleOp.create(&self.ctx, loc);
        const i64_type = try arith.getScalarType(&self.ctx, .i64);
        self.func = try func_dialect.FuncOp.create(&self.ctx, loc, "f", &.{i64_type}, &.{i64_type});
        try self.module.getBodyBlock().addOperation(self.func.op);
        const entry = self.func.getEntryBlock();

        const index_type = try arith.getIndexType(&self.ctx);
        var zero = try arith.ConstantOp.createInt(&self.ctx, loc, index_type, 0);
        try entry.addOperation(zero.op);
        self.zero = zero.getResult();

        const cell_type = try memref.getMemrefType1D(&self.ctx, 1, i64_type, .host);
        self.alloca = try memref.AllocaOp.createStatic(&self.ctx, loc, cell_type);
        try entry.addOperation(self.alloca.op);
        return self;
    }

    fn deinit(self: *TestFunction, allocator: std.mem.Allocator) void {
        self.ctx.deinit(allocator);
        allocator.destroy(self);
    }
};

test "F10a promotion discards the accesses of a local cell in straight line code" {
    const allocator = testing.allocator;
    var fixture = try TestFunction.init(allocator);
    defer fixture.deinit(allocator);
    const loc = ir.Location.getUnknown();
    const entry = fixture.func.getEntryBlock();
    const i64_type = try arith.getScalarType(&fixture.ctx, .i64);

    const store = try memref.StoreOp.create(&fixture.ctx, loc, fixture.func.getArgument(0), fixture.alloca.getResult(), fixture.zero);
    try entry.addOperation(store.op);
    var load = try memref.LoadOp.create(&fixture.ctx, loc, fixture.alloca.getResult(), fixture.zero, i64_type);
    try entry.addOperation(load.op);
    const ret = try func_dialect.ReturnOp.create(&fixture.ctx, loc, &.{load.getResult()});
    try entry.addOperation(ret.op);

    try testing.expect(try runPromotion(allocator, fixture.module.op));
    try testing.expectEqual(@as(usize, 1), countOps(fixture.module.op, memref.AllocaOp.operation_name));
    try testing.expectEqual(@as(usize, 0), countOps(fixture.module.op, memref.LoadOp.operation_name));
    try testing.expectEqual(
        @as(usize, 0),
        countOps(fixture.module.op, memref.StoreOp.operation_name),
    );
    try testing.expect(ret.op.getOperand(0).? == fixture.func.getArgument(0));
    try ir.verifyOperation(fixture.module.op, ir.verify.default_options);
}

test "F10a promotion carries a local cell through a loop as a value" {
    const allocator = testing.allocator;
    var fixture = try TestFunction.init(allocator);
    defer fixture.deinit(allocator);
    const loc = ir.Location.getUnknown();
    const entry = fixture.func.getEntryBlock();
    const i64_type = try arith.getScalarType(&fixture.ctx, .i64);
    const index_type = try arith.getIndexType(&fixture.ctx);

    var init_value = try arith.ConstantOp.createInt(&fixture.ctx, loc, i64_type, 0);
    try entry.addOperation(init_value.op);
    const init_store = try memref.StoreOp.create(&fixture.ctx, loc, init_value.getResult(), fixture.alloca.getResult(), fixture.zero);
    try entry.addOperation(init_store.op);

    var bound = try arith.ConstantOp.createInt(&fixture.ctx, loc, index_type, 8);
    try entry.addOperation(bound.op);
    var step = try arith.ConstantOp.createInt(&fixture.ctx, loc, index_type, 1);
    try entry.addOperation(step.op);
    var for_op = try scf.ForOp.create(&fixture.ctx, loc, fixture.zero, bound.getResult(), step.getResult(), &.{}, &.{});
    try entry.addOperation(for_op.op);
    const body = for_op.getBodyBlock();
    {
        var body_zero = try arith.ConstantOp.createInt(&fixture.ctx, loc, index_type, 0);
        try body.addOperation(body_zero.op);
        var current = try memref.LoadOp.create(&fixture.ctx, loc, fixture.alloca.getResult(), body_zero.getResult(), i64_type);
        try body.addOperation(current.op);
        var one = try arith.ConstantOp.createInt(&fixture.ctx, loc, i64_type, 1);
        try body.addOperation(one.op);
        var next = try arith.AddOp.create(&fixture.ctx, loc, current.getResult(), one.getResult());
        try body.addOperation(next.op);
        const body_store = try memref.StoreOp.create(&fixture.ctx, loc, next.getResult(), fixture.alloca.getResult(), body_zero.getResult());
        try body.addOperation(body_store.op);
        const yield = try scf.YieldOp.create(&fixture.ctx, loc, &.{});
        try body.addOperation(yield.op);
    }

    var final = try memref.LoadOp.create(&fixture.ctx, loc, fixture.alloca.getResult(), fixture.zero, i64_type);
    try entry.addOperation(final.op);
    const ret = try func_dialect.ReturnOp.create(&fixture.ctx, loc, &.{final.getResult()});
    try entry.addOperation(ret.op);

    try testing.expect(try runPromotion(allocator, fixture.module.op));
    try testing.expectEqual(@as(usize, 1), countOps(fixture.module.op, memref.AllocaOp.operation_name));
    try testing.expectEqual(
        @as(usize, 0),
        countOps(fixture.module.op, memref.LoadOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        countOps(fixture.module.op, memref.StoreOp.operation_name),
    );

    var found_for: ?*ir.Operation = null;
    var current: ?*ir.Operation = @ptrCast(@alignCast(entry.operations.head));
    while (current) |op| {
        if (std.mem.eql(u8, op.name.name, scf.ForOp.operation_name)) found_for = op;
        current = op.next_op;
    }
    const promoted_for = found_for orelse return error.TestFailure;
    try testing.expectEqual(@as(usize, 4), promoted_for.operands.items.len);
    try testing.expectEqual(@as(usize, 1), promoted_for.results.items.len);
    try testing.expect(ret.op.getOperand(0).? == &promoted_for.results.items[0]);
    try ir.verifyOperation(fixture.module.op, ir.verify.default_options);
}

test "leaves read before write and escaping cells alone" {
    const allocator = testing.allocator;
    var fixture = try TestFunction.init(allocator);
    defer fixture.deinit(allocator);
    const loc = ir.Location.getUnknown();
    const entry = fixture.func.getEntryBlock();
    const i64_type = try arith.getScalarType(&fixture.ctx, .i64);

    var early = try memref.LoadOp.create(&fixture.ctx, loc, fixture.alloca.getResult(), fixture.zero, i64_type);
    try entry.addOperation(early.op);
    const ret = try func_dialect.ReturnOp.create(&fixture.ctx, loc, &.{early.getResult()});
    try entry.addOperation(ret.op);

    try testing.expect(!try runPromotion(allocator, fixture.module.op));
    try testing.expectEqual(@as(usize, 1), countOps(fixture.module.op, memref.AllocaOp.operation_name));
    try testing.expectEqual(@as(usize, 1), countOps(fixture.module.op, memref.LoadOp.operation_name));
}

test "F10a promotion retains a cell whose second use is a call" {
    const allocator = testing.allocator;
    var fixture = try TestFunction.init(allocator);
    defer fixture.deinit(allocator);
    const loc = ir.Location.getUnknown();
    const entry = fixture.func.getEntryBlock();
    const i64_type = try arith.getScalarType(&fixture.ctx, .i64);

    const store = try memref.StoreOp.create(
        &fixture.ctx,
        loc,
        fixture.func.getArgument(0),
        fixture.alloca.getResult(),
        fixture.zero,
    );
    try entry.addOperation(store.op);
    const call = try func_dialect.CallOp.create(
        &fixture.ctx,
        loc,
        "observer",
        &.{fixture.alloca.getResult()},
        &.{},
    );
    try entry.addOperation(call.op);
    const load = try memref.LoadOp.create(
        &fixture.ctx,
        loc,
        fixture.alloca.getResult(),
        fixture.zero,
        i64_type,
    );
    try entry.addOperation(load.op);
    const ret = try func_dialect.ReturnOp.create(&fixture.ctx, loc, &.{load.getResult()});
    try entry.addOperation(ret.op);

    try testing.expect(!try runPromotion(allocator, fixture.module.op));
    try testing.expectEqual(
        @as(usize, 1),
        countOps(fixture.module.op, memref.LoadOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 1),
        countOps(fixture.module.op, memref.StoreOp.operation_name),
    );
    try testing.expect(ret.op.getOperand(0).? == load.getResult());
}

test "F10a promotion retains a cell an index the operands do not settle reaches" {
    const allocator = testing.allocator;
    var fixture = try TestFunction.init(allocator);
    defer fixture.deinit(allocator);
    const loc = ir.Location.getUnknown();
    const entry = fixture.func.getEntryBlock();
    const i64_type = try arith.getScalarType(&fixture.ctx, .i64);

    const store = try memref.StoreOp.create(
        &fixture.ctx,
        loc,
        fixture.func.getArgument(0),
        fixture.alloca.getResult(),
        fixture.zero,
    );
    try entry.addOperation(store.op);
    var computed = try arith.AddOp.create(&fixture.ctx, loc, fixture.zero, fixture.zero);
    try entry.addOperation(computed.op);
    const load = try memref.LoadOp.create(
        &fixture.ctx,
        loc,
        fixture.alloca.getResult(),
        computed.getResult(),
        i64_type,
    );
    try entry.addOperation(load.op);
    const ret = try func_dialect.ReturnOp.create(&fixture.ctx, loc, &.{load.getResult()});
    try entry.addOperation(ret.op);

    try testing.expect(!try runPromotion(allocator, fixture.module.op));
    try testing.expectEqual(
        @as(usize, 1),
        countOps(fixture.module.op, memref.LoadOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 1),
        countOps(fixture.module.op, memref.StoreOp.operation_name),
    );
}

test "F10a promotion retains a cell of two elements" {
    const allocator = testing.allocator;
    var fixture = try TestFunction.init(allocator);
    defer fixture.deinit(allocator);
    const loc = ir.Location.getUnknown();
    const entry = fixture.func.getEntryBlock();
    const i64_type = try arith.getScalarType(&fixture.ctx, .i64);

    const pair_type = try memref.getMemrefType1D(&fixture.ctx, 2, i64_type, .host);
    const pair = try memref.AllocaOp.createStatic(&fixture.ctx, loc, pair_type);
    try entry.addOperation(pair.op);
    const store = try memref.StoreOp.create(
        &fixture.ctx,
        loc,
        fixture.func.getArgument(0),
        pair.getResult(),
        fixture.zero,
    );
    try entry.addOperation(store.op);
    const load = try memref.LoadOp.create(
        &fixture.ctx,
        loc,
        pair.getResult(),
        fixture.zero,
        i64_type,
    );
    try entry.addOperation(load.op);
    const ret = try func_dialect.ReturnOp.create(&fixture.ctx, loc, &.{load.getResult()});
    try entry.addOperation(ret.op);

    try testing.expect(!try runPromotion(allocator, fixture.module.op));
    try testing.expectEqual(
        @as(usize, 1),
        countOps(fixture.module.op, memref.LoadOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 1),
        countOps(fixture.module.op, memref.StoreOp.operation_name),
    );
}

test "F10a promotion retains a cell a store hands to another cell" {
    const allocator = testing.allocator;
    var fixture = try TestFunction.init(allocator);
    defer fixture.deinit(allocator);
    const loc = ir.Location.getUnknown();
    const entry = fixture.func.getEntryBlock();
    const i64_type = try arith.getScalarType(&fixture.ctx, .i64);

    const cell_type = try memref.getMemrefType1D(&fixture.ctx, 1, i64_type, .host);
    const holder_type = try memref.getMemrefType1D(&fixture.ctx, 1, cell_type, .host);
    const holder = try memref.AllocaOp.createStatic(&fixture.ctx, loc, holder_type);
    try entry.addOperation(holder.op);
    const keeper = try func_dialect.CallOp.create(
        &fixture.ctx,
        loc,
        "observer",
        &.{holder.getResult()},
        &.{},
    );
    try entry.addOperation(keeper.op);
    const store = try memref.StoreOp.create(
        &fixture.ctx,
        loc,
        fixture.func.getArgument(0),
        fixture.alloca.getResult(),
        fixture.zero,
    );
    try entry.addOperation(store.op);
    const escape = try memref.StoreOp.create(
        &fixture.ctx,
        loc,
        fixture.alloca.getResult(),
        holder.getResult(),
        fixture.zero,
    );
    try entry.addOperation(escape.op);
    const load = try memref.LoadOp.create(
        &fixture.ctx,
        loc,
        fixture.alloca.getResult(),
        fixture.zero,
        i64_type,
    );
    try entry.addOperation(load.op);
    const ret = try func_dialect.ReturnOp.create(&fixture.ctx, loc, &.{load.getResult()});
    try entry.addOperation(ret.op);

    try testing.expect(!try runPromotion(allocator, fixture.module.op));
    try testing.expectEqual(
        @as(usize, 1),
        countOps(fixture.module.op, memref.LoadOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 2),
        countOps(fixture.module.op, memref.StoreOp.operation_name),
    );
    try testing.expect(ret.op.getOperand(0).? == load.getResult());
}

test "F10a promotion carries a local cell through a while as a loop value" {
    const allocator = testing.allocator;
    var fixture = try TestFunction.init(allocator);
    defer fixture.deinit(allocator);
    const loc = ir.Location.getUnknown();
    const entry = fixture.func.getEntryBlock();
    const i64_type = try arith.getScalarType(&fixture.ctx, .i64);

    const init_store = try memref.StoreOp.create(
        &fixture.ctx,
        loc,
        fixture.func.getArgument(0),
        fixture.alloca.getResult(),
        fixture.zero,
    );
    try entry.addOperation(init_store.op);

    var loop = try scf.WhileOp.create(&fixture.ctx, loc, &.{}, &.{});
    try entry.addOperation(loop.op);
    {
        const before = loop.getBeforeBlock();
        var held = try memref.LoadOp.create(
            &fixture.ctx,
            loc,
            fixture.alloca.getResult(),
            fixture.zero,
            i64_type,
        );
        try before.addOperation(held.op);
        var limit = try arith.ConstantOp.createInt(&fixture.ctx, loc, i64_type, 10);
        try before.addOperation(limit.op);
        var below = try arith.CmpOp.create(&fixture.ctx, loc, .lt, held.getResult(), limit.getResult());
        try before.addOperation(below.op);
        const decided = try scf.ConditionOp.create(&fixture.ctx, loc, below.getResult(), &.{});
        try before.addOperation(decided.op);

        const after = loop.getAfterBlock();
        var current = try memref.LoadOp.create(
            &fixture.ctx,
            loc,
            fixture.alloca.getResult(),
            fixture.zero,
            i64_type,
        );
        try after.addOperation(current.op);
        var one = try arith.ConstantOp.createInt(&fixture.ctx, loc, i64_type, 1);
        try after.addOperation(one.op);
        var next = try arith.AddOp.create(&fixture.ctx, loc, current.getResult(), one.getResult());
        try after.addOperation(next.op);
        const body_store = try memref.StoreOp.create(
            &fixture.ctx,
            loc,
            next.getResult(),
            fixture.alloca.getResult(),
            fixture.zero,
        );
        try after.addOperation(body_store.op);
        const yield = try scf.YieldOp.create(&fixture.ctx, loc, &.{});
        try after.addOperation(yield.op);
    }

    var final = try memref.LoadOp.create(
        &fixture.ctx,
        loc,
        fixture.alloca.getResult(),
        fixture.zero,
        i64_type,
    );
    try entry.addOperation(final.op);
    const ret = try func_dialect.ReturnOp.create(&fixture.ctx, loc, &.{final.getResult()});
    try entry.addOperation(ret.op);

    try testing.expect(try runPromotion(allocator, fixture.module.op));
    try testing.expectEqual(
        @as(usize, 0),
        countOps(fixture.module.op, memref.LoadOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        countOps(fixture.module.op, memref.StoreOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 1),
        countOps(fixture.module.op, memref.AllocaOp.operation_name),
    );

    var found: ?*ir.Operation = null;
    var current: ?*ir.Operation = @ptrCast(@alignCast(entry.operations.head));
    while (current) |op| {
        if (std.mem.eql(u8, op.name.name, scf.WhileOp.operation_name)) found = op;
        current = op.next_op;
    }
    const promoted = found orelse return error.TestFailure;
    try testing.expectEqual(@as(usize, 1), promoted.operands.items.len);
    try testing.expectEqual(@as(usize, 1), promoted.results.items.len);
    try testing.expect(ret.op.getOperand(0).? == &promoted.results.items[0]);
    try ir.verifyOperation(fixture.module.op, ir.verify.default_options);
}

fn countAllOps(op: *ir.Operation) usize {
    var count: usize = 1;
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |nested| {
                count += countAllOps(nested);
                current = nested.next_op;
            }
        }
    }
    return count;
}

const CellLoop = struct {
    ctx: ir.Context,
    module: dialects.builtin.BuiltinDialect.ModuleOp,

    fn init(allocator: std.mem.Allocator, cells: usize, depth: usize, seeded: bool) !*CellLoop {
        return initUnder(allocator, cells, depth, seeded, ir.Context.Limits.testing);
    }

    /// The same program in a context of stated limits, for a test that wants
    /// the nested segment to run short at a chosen point.
    fn initUnder(
        allocator: std.mem.Allocator,
        cells: usize,
        depth: usize,
        seeded: bool,
        limits: ir.Context.Limits,
    ) !*CellLoop {
        std.debug.assert(cells >= 1);
        std.debug.assert(depth >= 1);
        const self = try allocator.create(CellLoop);
        self.ctx = try ir.Context.init(allocator, limits);
        errdefer self.ctx.deinit(allocator);
        try dialects.registerAllDialects(&self.ctx);

        const loc = ir.Location.getUnknown();
        self.module = try dialects.builtin.BuiltinDialect.ModuleOp.create(&self.ctx, loc);
        const i64_type = try arith.getScalarType(&self.ctx, .i64);
        const index_type = try arith.getIndexType(&self.ctx);
        var func = try func_dialect.FuncOp.create(&self.ctx, loc, "f", &.{i64_type}, &.{i64_type});
        try self.module.getBodyBlock().addOperation(func.op);
        const entry = func.getEntryBlock();

        var zero = try arith.ConstantOp.createInt(&self.ctx, loc, index_type, 0);
        try entry.addOperation(zero.op);
        const index_zero = zero.getResult();

        const cell_type = try memref.getMemrefType1D(&self.ctx, 1, i64_type, .host);
        const holders = try allocator.alloc(*ir.Value, cells);
        defer allocator.free(holders);
        for (holders) |*holder| {
            var alloca = try memref.AllocaOp.createStatic(&self.ctx, loc, cell_type);
            try entry.addOperation(alloca.op);
            holder.* = alloca.getResult();
            if (!seeded) continue;
            var seed = try arith.ConstantOp.createInt(&self.ctx, loc, i64_type, 0);
            try entry.addOperation(seed.op);
            const store = try memref.StoreOp.create(&self.ctx, loc, seed.getResult(), holder.*, index_zero);
            try entry.addOperation(store.op);
        }

        var bound = try arith.ConstantOp.createInt(&self.ctx, loc, index_type, 8);
        try entry.addOperation(bound.op);
        var step = try arith.ConstantOp.createInt(&self.ctx, loc, index_type, 1);
        try entry.addOperation(step.op);

        var outer = entry;
        var level: usize = 0;
        while (level < depth) : (level += 1) {
            var loop = try scf.ForOp.create(&self.ctx, loc, index_zero, bound.getResult(), step.getResult(), &.{}, &.{});
            try outer.addOperation(loop.op);
            outer = loop.getBodyBlock();
        }

        var body_zero = try arith.ConstantOp.createInt(&self.ctx, loc, index_type, 0);
        try outer.addOperation(body_zero.op);
        for (holders) |holder| {
            var one = try arith.ConstantOp.createInt(&self.ctx, loc, i64_type, 1);
            try outer.addOperation(one.op);
            if (seeded) {
                var current = try memref.LoadOp.create(&self.ctx, loc, holder, body_zero.getResult(), i64_type);
                try outer.addOperation(current.op);
                var next = try arith.AddOp.create(&self.ctx, loc, current.getResult(), one.getResult());
                try outer.addOperation(next.op);
                const store = try memref.StoreOp.create(&self.ctx, loc, next.getResult(), holder, body_zero.getResult());
                try outer.addOperation(store.op);
                continue;
            }
            const store = try memref.StoreOp.create(&self.ctx, loc, one.getResult(), holder, body_zero.getResult());
            try outer.addOperation(store.op);
        }

        var closing = outer;
        var closed: usize = 0;
        while (closed < depth) : (closed += 1) {
            const yield = try scf.YieldOp.create(&self.ctx, loc, &.{});
            try closing.addOperation(yield.op);
            const holder_op = closing.getParentOperation() orelse break;
            closing = holder_op.getBlock() orelse break;
        }

        var final = try memref.LoadOp.create(&self.ctx, loc, holders[0], index_zero, i64_type);
        try entry.addOperation(final.op);
        const ret = try func_dialect.ReturnOp.create(&self.ctx, loc, &.{final.getResult()});
        try entry.addOperation(ret.op);
        return self;
    }

    fn deinit(self: *CellLoop, allocator: std.mem.Allocator) void {
        self.ctx.deinit(allocator);
        allocator.destroy(self);
    }
};

test "the operations promotion creates for one loop do not grow with the cells it carries" {
    const allocator = testing.allocator;
    const counts = [_]usize{ 1, 2, 8, 32 };
    var first: ?Created = null;
    for (counts) |cells| {
        var fixture = try CellLoop.init(allocator, cells, 1, true);
        defer fixture.deinit(allocator);
        var created = Created{};
        try testing.expect(try promoteCounting(fixture.module.op, allocator, &created));
        try testing.expectEqual(@as(usize, 1), created.regions_rebuilt);
        if (first) |seen| {
            try testing.expectEqual(seen.operations, created.operations);
        } else {
            first = created;
        }
        try testing.expectEqual(@as(usize, 0), countOps(fixture.module.op, memref.LoadOp.operation_name));
        try testing.expectEqual(@as(usize, 0), countOps(fixture.module.op, memref.StoreOp.operation_name));
        try ir.verifyOperation(fixture.module.op, ir.verify.default_options);
    }
}

test "promotion rebuilds one region per region and stays inside the figure it declares" {
    const allocator = testing.allocator;
    const depths = [_]usize{ 1, 2, 4 };
    for (depths) |depth| {
        var fixture = try CellLoop.init(allocator, 4, depth, true);
        defer fixture.deinit(allocator);
        const given = countAllOps(fixture.module.op);
        var created = Created{};
        try testing.expect(try promoteCounting(fixture.module.op, allocator, &created));
        try testing.expectEqual(depth, created.regions_rebuilt);
        try testing.expect(created.operations <= operationsCreated(given));
        try ir.verifyOperation(fixture.module.op, ir.verify.default_options);
    }
}

test "a loop carrying a cell no store defined creates one zero for it and refuses a later read" {
    const allocator = testing.allocator;
    var fixture = try CellLoop.init(allocator, 4, 1, false);
    defer fixture.deinit(allocator);
    const given = countAllOps(fixture.module.op);
    var created = Created{};
    try testing.expect(try promoteCounting(fixture.module.op, allocator, &created));

    try testing.expectEqual(@as(usize, 1), countOps(fixture.module.op, memref.LoadOp.operation_name));
    try testing.expectEqual(@as(usize, 1), countOps(fixture.module.op, memref.StoreOp.operation_name));

    try testing.expectEqual(@as(usize, 1), created.regions_rebuilt);
    try testing.expectEqual(@as(usize, 5), created.operations);
    try testing.expect(created.operations <= operationsCreated(given));
    try ir.verifyOperation(fixture.module.op, ir.verify.default_options);
}

test "a rewrite that cannot reserve its splice leaves the module verifying" {
    const allocator = testing.allocator;
    const cells: usize = 4;
    const depth: usize = 2;

    var built = try CellLoop.init(allocator, cells, depth, true);
    const construction = built.ctx.capacityUsage().operation_nested.frontier_bytes;
    built.deinit(allocator);

    var limits = ir.Context.Limits.testing;
    limits.operations.nested_bytes = construction + rewriteBytes(cells) - 1;

    var fixture = try CellLoop.initUnder(allocator, cells, depth, true, limits);
    defer fixture.deinit(allocator);

    const ops = countAllOps(fixture.module.op);
    const loads = countOps(fixture.module.op, memref.LoadOp.operation_name);
    const stores = countOps(fixture.module.op, memref.StoreOp.operation_name);
    try testing.expect(loads > 0);
    try testing.expect(stores > 0);

    var created = Created{};
    try testing.expectError(
        error.OutOfMemory,
        promoteCounting(fixture.module.op, allocator, &created),
    );

    try ir.verifyOperation(fixture.module.op, ir.verify.default_options);
    try testing.expectEqual(@as(usize, 0), created.regions_rebuilt);
    try testing.expectEqual(@as(usize, 0), created.operations);
    try testing.expect(countAllOps(fixture.module.op) <= ops);
    try testing.expect(countOps(fixture.module.op, memref.LoadOp.operation_name) <= loads);
    try testing.expect(countOps(fixture.module.op, memref.StoreOp.operation_name) <= stores);
}
