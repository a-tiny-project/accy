const std = @import("std");
const alloc_observe = @import("alloc_observe");
const ir = @import("../../core/root.zig");
const passes = @import("../root.zig");
const pass_mod = passes.pass;
const registry_mod = passes.pipeline;
const control_flow = passes.control_flow;
const cse = @import("root.zig");

const Pass = pass_mod.Pass;
const PassContext = pass_mod.PassContext;
const PassResult = pass_mod.PassResult;
const Workspace = cse.Workspace;
const Table = cse.Table;

pub const common_subexpression_elimination_pass_name = "choir-cse";
pub const common_subexpression_elimination_pass_description =
    "Common subexpression elimination for pure operations";

pub fn createCommonSubexpressionEliminationPass() Pass {
    return .{
        .name = common_subexpression_elimination_pass_name,
        .description = common_subexpression_elimination_pass_description,
        .run_fn = run,
        .mutation_scope = .isolated,
        .rerun_policy = .skip_if_unchanged,
    };
}

pub const common_subexpression_elimination_pass_registration = registry_mod.PassRegistration{
    .name = common_subexpression_elimination_pass_name,
    .description = common_subexpression_elimination_pass_description,
    .pass = createCommonSubexpressionEliminationPass(),
};

pub fn run(ctx: *PassContext) PassResult {
    var stack_buffer: [cse.inline_workspace_bytes]u8 = undefined;
    var stack_fallback = alloc_observe.buffer.First.init(&stack_buffer, ctx.allocator);
    const workspace_allocator = stack_fallback.allocator();
    var workspace = Workspace.initForRoot(workspace_allocator, ctx.op) catch
        return .failure;
    defer workspace.deinit(workspace_allocator);
    const dominance: ?*const control_flow.DominanceAnalysis = if (workspace.requiresDominance())
        control_flow.getDominanceAnalysis(ctx, ctx.op) catch return .failure
    else
        null;
    workspace.activate() catch return .failure;

    var modified = false;
    var replacements: u64 = 0;
    cseOnOp(
        ctx.op,
        dominance,
        &workspace,
        &modified,
        &replacements,
    );
    std.debug.assert(workspace.insertion_count == 0);
    std.debug.assert(workspace.active_scope_count == 0);

    if (replacements != 0) {
        ctx.addStatistic("replacements", "redundant operations replaced", replacements);
    }

    if (modified) {
        ctx.preserveAnalysisSet(control_flow.analysis_ids);
        ctx.markModified();
    } else {
        ctx.preserveAllAnalyses();
    }
    return .success;
}

fn cseOnOp(
    op: *ir.Operation,
    dominance: ?*const control_flow.DominanceAnalysis,
    workspace: *Workspace,
    modified: *bool,
    replacements: *u64,
) void {
    for (op.regions.items) |*region| {
        const table = workspace.acquire();
        defer workspace.release(table);

        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                const next = current_op.next_op;

                if (current_op.regions.items.len > 0) {
                    cseOnOp(
                        current_op,
                        dominance,
                        workspace,
                        modified,
                        replacements,
                    );
                }

                cseOperation(
                    current_op,
                    dominance,
                    table,
                    workspace.effect_records,
                    modified,
                    replacements,
                );
                current = next;
            }
        }
    }
}

fn findDominatingCseCandidate(
    table: Table,
    key: u64,
    op: *ir.Operation,
    options: ir.OperationEquivalence.Options,
    dominance: ?*const control_flow.DominanceAnalysis,
) ?*ir.Operation {
    var candidates = table.candidates(key);
    while (candidates.next()) |candidate| {
        if (!cseCandidateDominates(candidate, op, dominance)) continue;
        if (ir.OperationEquivalence.isEquivalentTo(
            candidate,
            op,
            options,
        )) {
            return candidate;
        }
    }
    return null;
}

fn cseOperation(
    current_op: *ir.Operation,
    dominance: ?*const control_flow.DominanceAnalysis,
    table: Table,
    effect_records: []ir.interfaces.effects.Fact,
    modified: *bool,
    replacements: *u64,
) void {
    const traits = current_op.getTraits();
    if (isCseCandidate(current_op, traits, effect_records)) {
        const commutative = isCommutativeForCse(current_op, traits);
        const options = cseEquivalenceOptions(commutative);
        const key = ir.OperationEquivalence.computeHash(current_op, options);
        const existing = findDominatingCseCandidate(
            table,
            key,
            current_op,
            options,
            dominance,
        );
        if (existing) |existing_op| {
            replaceOperation(current_op, existing_op);
            modified.* = true;
            replacements.* +|= 1;
        } else {
            table.add(key, current_op) catch
                @panic("CSE exact candidate capacity exhausted after activation");
        }
    }
}

fn replaceOperation(current_op: *ir.Operation, existing_op: *ir.Operation) void {
    std.debug.assert(current_op.getNumResults() == existing_op.getNumResults());
    for (current_op.results.items, existing_op.results.items) |*current_result, *existing_result| {
        current_result.replaceAllUsesWith(existing_result);
    }
    current_op.erase();
}

fn cseCandidateDominates(
    candidate: *ir.Operation,
    op: *ir.Operation,
    dominance: ?*const control_flow.DominanceAnalysis,
) bool {
    const candidate_block = candidate.parent_block orelse return false;
    const op_block = op.parent_block orelse return false;
    const candidate_region = candidate_block.parent orelse return false;
    if (op_block.parent != candidate_region) return false;
    if (candidate_block == op_block) return candidate.isBeforeInBlock(op);
    const analysis = dominance orelse
        @panic("cross-block CSE candidate admitted without dominance");
    return analysis.dominatesBlock(candidate_block, op_block);
}

fn isCseCandidate(
    op: *ir.Operation,
    traits: ir.OperationTraits,
    storage: []ir.interfaces.effects.Fact,
) bool {
    if (!cse.hasCandidateShape(op)) return false;
    return isCseCandidateWithTraits(op, traits, storage);
}

fn isCseCandidateWithTraits(
    op: *ir.Operation,
    traits: ir.OperationTraits,
    storage: []ir.interfaces.effects.Fact,
) bool {
    if (traits.is_terminator) return false;
    if (op.hasInterface(ir.interfaces.SymbolOpInterface)) return false;
    if (op.hasInterface(ir.interfaces.CallOpInterface)) return false;
    const declaration = ir.interfaces.effects.collectInto(op, storage) catch return false;
    return ir.interfaces.effects.repeatableExpression(declaration);
}

fn isCommutativeForCse(op: *ir.Operation, traits: ir.OperationTraits) bool {
    if (traits.is_commutative) return true;
    if (op.interface(ir.interfaces.CseOpInterface)) |iface| {
        return iface.call(.commuteOperandsInKey, .{});
    }
    return false;
}

fn cseEquivalenceOptions(commutative: bool) ir.OperationEquivalence.Options {
    return .{
        .attribute_filter = includeAttributeInCseKey,
        .commute_operands = commutative,
    };
}

fn includeAttributeInCseKey(_: ?*const anyopaque, op: *ir.Operation, attr: ir.NamedAttribute) bool {
    if (op.interface(ir.interfaces.CseOpInterface)) |iface| {
        return iface.call(.includeAttributeInKey, .{ attr.name, attr.value });
    }
    return true;
}
