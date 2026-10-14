const std = @import("std");
const alloc_observe = @import("alloc_observe");
const alloc_phase = @import("alloc_phase");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");

const Allocator = std.mem.Allocator;
const effects = ir.interfaces.effects;

const maximum_cse_operation_depth: usize = 256;
const cse_table_max_load_percentage: usize = 80;
const cse_storage_alignment: usize = @max(@alignOf(u64), @alignOf(usize), @alignOf(effects.Fact));
pub const inline_workspace_bytes: usize = 8 * 1024;

const CseInspectError = error{
    CapacityOverflow,
    CountOverflow,
    NestingLimitExceeded,
};

const CseFacts = struct {
    operation_depth: usize = 0,
    peak_candidate_count: usize = 0,
    peak_effect_records: usize = 0,
    requires_dominance: bool = false,
};

const CseLimits = struct {
    facts: CseFacts,

    pub fn inspect(root: *ir.Operation) CseInspectError!CseLimits {
        var survey = CseSurvey{};
        survey.facts.peak_candidate_count = try inspectCseOperation(
            root,
            1,
            &survey,
        );
        return .{ .facts = survey.facts };
    }
};

const CseCapacity = struct {
    facts: CseFacts,
    slot_count: usize,
    slot_bytes: usize,
    insertion_offset: usize,
    insertion_bytes: usize,
    effect_offset: usize,
    working_bytes: usize,

    pub fn derive(limits: CseLimits) error{CapacityOverflow}!CseCapacity {
        const slot_count = try cseTableSlotCount(
            limits.facts.peak_candidate_count,
        );
        const slot_bytes = std.math.mul(
            usize,
            slot_count,
            @sizeOf(CseSlot),
        ) catch return error.CapacityOverflow;
        const insertion_bytes = std.math.mul(
            usize,
            limits.facts.peak_candidate_count,
            @sizeOf(usize),
        ) catch return error.CapacityOverflow;
        var cursor: usize = 0;
        _ = try csePlaceBytes(slot_bytes, @alignOf(CseSlot), &cursor);
        const insertion_offset = try csePlaceBytes(
            insertion_bytes,
            @alignOf(usize),
            &cursor,
        );
        const effect_bytes = std.math.mul(
            usize,
            limits.facts.peak_effect_records,
            @sizeOf(effects.Fact),
        ) catch return error.CapacityOverflow;
        const effect_offset = try csePlaceBytes(effect_bytes, @alignOf(effects.Fact), &cursor);
        return .{
            .facts = limits.facts,
            .slot_count = slot_count,
            .slot_bytes = slot_bytes,
            .insertion_offset = insertion_offset,
            .insertion_bytes = insertion_bytes,
            .effect_offset = effect_offset,
            .working_bytes = cursor,
        };
    }
};

pub const Workspace = struct {
    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "choir.cse_workspace",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "effect_records_bounded_by_declared_contract_capacity",
                        .lifetime = .steady,
                        .detail = "reused fact buffer bounded by arity-derived contract capacity",
                    },
                    .{
                        .id = "scoped_cse_hash_slots_bounded_by_peak_active_candidate_shapes",
                        .lifetime = .steady,
                        .detail = "scoped CSE hash slots bounded by peak active candidate shapes",
                    },
                    .{
                        .id = "lifo_insertion_indices_bounded_by_peak_active_candidate_shapes",
                        .lifetime = .steady,
                        .detail = "LIFO insertion indices bounded by peak active candidate shapes",
                    },
                },
                .excluded = &.{
                    "borrowed IR and dominance analysis",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "facts_operation_depth", "facts.operation_depth"),
                    alloc_phase.capacity.bindInput(Limits, "facts_peak_candidate_count", "facts.peak_candidate_count"),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "facts_peak_effect_records",
                        "facts.peak_effect_records",
                    ),
                },
                .type_selectors = &.{},
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .input = 1 },
                    .{ .add = .{ .left = 0, .right = 1 } },
                    .{ .input = 2 },
                    .{ .add = .{ .left = 2, .right = 3 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .upper_bound,
                    .expression = 4,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "nesting, count arithmetic, capacity arithmetic, or fallback OOM rejects before CSE traversal",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "CSE equivalence, result remapping, duplicate erasure, and scoped table mutation use only admitted storage after activation",
                },
                .foreign = .{
                    .status = .open,
                    .detail = "the workspace has no visible foreign edge, but foreign-edge closure lacks a machine-checked certificate",
                },
            },
            .obligations = &.{
                .{ .key = "cse_inline_boundary", .role = .overload },
                .{ .key = "cse_capacity", .role = .capacity_model },
                .{ .key = "cse_sealed_reuse_overload", .role = .overload },
                .{ .key = "cse_sealed_reuse_foreign_risk", .role = .foreign_risk },
                .{ .key = "cse_oom_retry", .role = .overload },
                .{ .key = "cse_steady_no_alloc", .role = .transitive_risk },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    phase: alloc_phase.capacity.Phase,
    capacity: CseCapacity,
    bytes: []align(cse_storage_alignment) u8,
    slots: []CseSlot,
    insertion_slots: []usize,
    effect_records: []effects.Fact,
    insertion_count: usize,
    active_scope_count: usize,

    pub const Limits = CseLimits;
    pub const Capacity = CseCapacity;

    pub fn initForRoot(allocator: Allocator, root: *ir.Operation) !Workspace {
        return init(allocator, try Limits.inspect(root));
    }

    pub fn init(allocator: Allocator, limits: Limits) !Workspace {
        const capacity = try Capacity.derive(limits);
        const bytes = try allocator.alignedAlloc(
            u8,
            .fromByteUnits(cse_storage_alignment),
            capacity.working_bytes,
        );
        const slots = cseTypedSlice(
            CseSlot,
            bytes,
            0,
            capacity.slot_count,
        );
        @memset(slots, .{});
        return .{
            .phase = .initialization,
            .capacity = capacity,
            .bytes = bytes,
            .slots = slots,
            .insertion_slots = cseTypedSlice(
                usize,
                bytes,
                capacity.insertion_offset,
                capacity.facts.peak_candidate_count,
            ),
            .insertion_count = 0,
            .active_scope_count = 0,
            .effect_records = cseTypedSlice(
                effects.Fact,
                bytes,
                capacity.effect_offset,
                capacity.facts.peak_effect_records,
            ),
        };
    }

    pub fn activate(self: *Workspace) error{AlreadyActive}!void {
        if (self.phase != .initialization) return error.AlreadyActive;
        self.phase = .steady;
    }

    pub fn requiresDominance(self: *const Workspace) bool {
        if (self.phase != .initialization) {
            @panic("CSE dominance admission checked outside initialization");
        }
        return self.capacity.facts.requires_dominance;
    }

    pub fn acquire(self: *Workspace) Table {
        self.requireSteady();
        self.active_scope_count = std.math.add(
            usize,
            self.active_scope_count,
            1,
        ) catch @panic("CSE active scope count overflow after activation");
        return .{
            .slots = self.slots,
            .insertion_slots = self.insertion_slots,
            .insertion_count = &self.insertion_count,
            .log_start = self.insertion_count,
        };
    }

    pub fn release(self: *Workspace, table: Table) void {
        self.requireSteady();
        std.debug.assert(table.slots.ptr == self.slots.ptr);
        std.debug.assert(table.insertion_slots.ptr == self.insertion_slots.ptr);
        std.debug.assert(table.insertion_count == &self.insertion_count);
        var scope = table;
        scope.clear();
        std.debug.assert(self.active_scope_count > 0);
        self.active_scope_count -= 1;
    }

    pub fn deinit(self: *Workspace, allocator: Allocator) void {
        if (self.phase == .teardown) @panic("CSE workspace teardown is terminal");
        std.debug.assert(self.insertion_count == 0);
        std.debug.assert(self.active_scope_count == 0);
        self.phase = .teardown;
        allocator.free(self.bytes);
        self.bytes = undefined;
        self.slots = undefined;
        self.insertion_slots = undefined;
        self.insertion_count = undefined;
        self.active_scope_count = undefined;
    }

    fn requireSteady(self: *const Workspace) void {
        if (self.phase != .steady) {
            @panic("CSE workspace used outside its steady phase");
        }
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(Workspace);
}

const CseSlot = struct {
    key: u64 = 0,
    op: ?*ir.Operation = null,
};

pub const Table = struct {
    slots: []CseSlot,
    insertion_slots: []usize,
    insertion_count: *usize,
    log_start: usize,

    pub fn candidates(self: Table, key: u64) CandidateIterator {
        return CandidateIterator.init(self.slots, key);
    }

    pub fn add(self: Table, key: u64, op: *ir.Operation) error{CapacityExceeded}!void {
        if (self.insertion_count.* >= self.insertion_slots.len) {
            return error.CapacityExceeded;
        }
        if (self.slots.len == 0) return error.CapacityExceeded;
        var index = cseSlotIndex(key, self.slots.len);
        var remaining = self.slots.len;
        while (remaining > 0) : (remaining -= 1) {
            const slot = &self.slots[index];
            if (slot.op == null) {
                slot.* = .{
                    .key = key,
                    .op = op,
                };
                self.insertion_slots[self.insertion_count.*] = index;
                self.insertion_count.* += 1;
                return;
            }
            index = (index + 1) & (self.slots.len - 1);
        }
        return error.CapacityExceeded;
    }

    fn clear(self: *Table) void {
        std.debug.assert(self.insertion_count.* >= self.log_start);
        while (self.insertion_count.* > self.log_start) {
            self.insertion_count.* -= 1;
            const index = self.insertion_slots[self.insertion_count.*];
            std.debug.assert(self.slots[index].op != null);
            self.slots[index] = .{};
        }
    }
};

pub const CandidateIterator = struct {
    slots: []const CseSlot,
    key: u64,
    index: usize,
    remaining: usize,

    fn init(slots: []const CseSlot, key: u64) CandidateIterator {
        return .{
            .slots = slots,
            .key = key,
            .index = if (slots.len == 0) 0 else cseSlotIndex(key, slots.len),
            .remaining = slots.len,
        };
    }

    pub fn next(self: *CandidateIterator) ?*ir.Operation {
        while (self.remaining > 0) {
            const slot = self.slots[self.index];
            self.index = (self.index + 1) & (self.slots.len - 1);
            self.remaining -= 1;
            const op = slot.op orelse {
                self.remaining = 0;
                return null;
            };
            if (slot.key == self.key) return op;
        }
        return null;
    }
};

fn cseSlotIndex(key: u64, slot_count: usize) usize {
    std.debug.assert(std.math.isPowerOfTwo(slot_count));
    return @as(usize, @truncate(key)) & (slot_count - 1);
}

fn cseTableSlotCount(candidate_count: usize) error{CapacityOverflow}!usize {
    if (candidate_count == 0) return 0;
    const scaled = std.math.mul(usize, candidate_count, 100) catch
        return error.CapacityOverflow;
    const minimum = std.math.add(
        usize,
        scaled / cse_table_max_load_percentage,
        1,
    ) catch return error.CapacityOverflow;
    return std.math.ceilPowerOfTwo(usize, minimum) catch error.CapacityOverflow;
}

fn csePlaceBytes(
    byte_count: usize,
    alignment: usize,
    cursor: *usize,
) error{CapacityOverflow}!usize {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    const mask = alignment - 1;
    const padded = std.math.add(usize, cursor.*, mask) catch
        return error.CapacityOverflow;
    const offset = padded & ~mask;
    cursor.* = std.math.add(usize, offset, byte_count) catch
        return error.CapacityOverflow;
    return offset;
}

fn cseTypedSlice(
    comptime T: type,
    bytes: []align(cse_storage_alignment) u8,
    offset: usize,
    count: usize,
) []T {
    if (count == 0) return &.{};
    const byte_count = std.math.mul(usize, count, @sizeOf(T)) catch unreachable;
    const region: []align(@alignOf(T)) u8 = @alignCast(
        bytes[offset..][0..byte_count],
    );
    return std.mem.bytesAsSlice(T, region);
}

const CseSurvey = struct {
    facts: CseFacts = .{},
};

fn inspectCseOperation(
    op: *ir.Operation,
    depth: usize,
    survey: *CseSurvey,
) CseInspectError!usize {
    if (depth > maximum_cse_operation_depth) return error.NestingLimitExceeded;
    survey.facts.operation_depth = @max(survey.facts.operation_depth, depth);

    if (op.regions.items.len == 0) return 0;
    const child_depth = depth + 1;
    var peak_candidate_count: usize = 0;
    for (op.regions.items) |*region| {
        var active_candidate_count: usize = 0;
        var region_peak_candidate_count: usize = 0;
        var candidate_block_count: usize = 0;
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var block_has_candidate = false;
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            if (current != null) {
                if (child_depth > maximum_cse_operation_depth) {
                    return error.NestingLimitExceeded;
                }
                survey.facts.operation_depth = @max(survey.facts.operation_depth, child_depth);
            }
            while (current) |current_op| {
                const nested_peak_candidate_count = if (current_op.regions.items.len == 0)
                    0
                else
                    try inspectCseOperation(current_op, child_depth, survey);
                const nested_active_candidate_count = std.math.add(
                    usize,
                    active_candidate_count,
                    nested_peak_candidate_count,
                ) catch return error.CapacityOverflow;
                region_peak_candidate_count = @max(
                    region_peak_candidate_count,
                    nested_active_candidate_count,
                );
                if (hasCandidateShape(current_op)) {
                    if (current_op.getInterface(effects.EffectOpInterface)) |vtable| {
                        const count = vtable.capacity.count(
                            current_op.getNumOperands(),
                            current_op.getNumResults(),
                            current_op.getNumRegions(),
                        ) orelse return error.CapacityOverflow;
                        survey.facts.peak_effect_records = @max(
                            survey.facts.peak_effect_records,
                            count,
                        );
                    }
                    block_has_candidate = true;
                    active_candidate_count = std.math.add(usize, active_candidate_count, 1) catch
                        return error.CountOverflow;
                    region_peak_candidate_count = @max(
                        region_peak_candidate_count,
                        active_candidate_count,
                    );
                }
                current = current_op.next_op;
            }
            if (block_has_candidate) {
                candidate_block_count = std.math.add(usize, candidate_block_count, 1) catch
                    return error.CountOverflow;
            }
        }
        survey.facts.requires_dominance =
            survey.facts.requires_dominance or candidate_block_count > 1;
        peak_candidate_count = @max(peak_candidate_count, region_peak_candidate_count);
    }
    return peak_candidate_count;
}

pub fn hasCandidateShape(op: *ir.Operation) bool {
    return op.regions.items.len == 0 and
        op.successors.items.len == 0 and
        op.result_types.len != 0;
}

const testing = std.testing;
const test_dialect = @import("../../dialects/fixture/root.zig");

fn buildTestContext(allocator: Allocator) !ir.Context {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    errdefer ctx.deinit(allocator);
    try test_dialect.registerTestDialect(&ctx);
    return ctx;
}

const WorkspaceFixture = struct {
    root: *ir.Operation,
    outer_region: *ir.Region,
    nested_region: *ir.Region,
    sibling_region: *ir.Region,
};

fn appendWorkspaceCandidates(
    ctx: *ir.Context,
    block: *ir.Block,
    candidate_type: ir.Type,
    count: usize,
) !void {
    for (0..count) |_| {
        var state = ir.Operation.State.init(
            "test.cse_workspace_candidate",
            ir.Location.getUnknown(),
        );
        state.addTypes(&.{candidate_type});
        try block.addOperation(try ctx.createOperation(state));
    }
}

fn appendWorkspaceContainer(
    ctx: *ir.Context,
    block: *ir.Block,
    name: []const u8,
) !*ir.Operation {
    var state = ir.Operation.State.init(name, ir.Location.getUnknown());
    state.addRegion();
    const op = try ctx.createOperation(state);
    try block.addOperation(op);
    return op;
}

fn buildWorkspaceFixture(ctx: *ir.Context) !WorkspaceFixture {
    const candidate_type = try test_dialect.TestDialect.getI32Type(ctx);
    var root_state = ir.Operation.State.init(
        "test.cse_workspace_root",
        ir.Location.getUnknown(),
    );
    root_state.addRegion();
    const root = try ctx.createOperation(root_state);
    const root_region = root.getRegion(0).?;
    const root_block = try root_region.addBlock();

    const outer = try appendWorkspaceContainer(ctx, root_block, "test.cse_workspace_outer");
    const outer_region = outer.getRegion(0).?;
    const outer_block = try outer_region.addBlock();
    try appendWorkspaceCandidates(ctx, outer_block, candidate_type, 3);

    const nested = try appendWorkspaceContainer(ctx, outer_block, "test.cse_workspace_nested");
    const nested_region = nested.getRegion(0).?;
    const nested_block = try nested_region.addBlock();
    try appendWorkspaceCandidates(ctx, nested_block, candidate_type, 7);

    const sibling = try appendWorkspaceContainer(ctx, root_block, "test.cse_workspace_sibling");
    const sibling_region = sibling.getRegion(0).?;
    const sibling_block = try sibling_region.addBlock();
    try appendWorkspaceCandidates(ctx, sibling_block, candidate_type, 9);

    return .{
        .root = root,
        .outer_region = outer_region,
        .nested_region = nested_region,
        .sibling_region = sibling_region,
    };
}

fn addWorkspaceRegionCandidates(
    table: Table,
    region: *ir.Region,
    first_key: u64,
) !usize {
    var count: usize = 0;
    var block_iter = region.getBlocks();
    while (block_iter.next()) |block| {
        var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
        while (current) |current_op| {
            if (hasCandidateShape(current_op)) {
                try table.add(first_key + count, current_op);
                count += 1;
            }
            current = current_op.next_op;
        }
    }
    return count;
}

fn checkWorkspaceInitFailures(allocator: Allocator, root: *ir.Operation) !void {
    var workspace = try Workspace.initForRoot(allocator, root);
    defer workspace.deinit(allocator);
    try testing.expectEqual(alloc_phase.capacity.Phase.initialization, workspace.phase);
}
