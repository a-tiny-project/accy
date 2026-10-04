const std = @import("std");
const ir = @import("../../core/root.zig");
const subject = @import("root.zig");

const Pass = subject.Pass;
const PassContext = subject.PassContext;
const PassMutationScope = subject.PassMutationScope;
const PassResult = subject.PassResult;

pub fn OperationPass(
    comptime OpType: type,
    comptime run_on_op: fn (*OpType, *PassContext) PassResult,
) type {
    return struct {
        base: Pass,

        const Self = @This();

        pub fn init(
            name: []const u8,
            description: []const u8,
        ) Self {
            return initWithMutationScope(name, description, .whole_module);
        }

        pub fn initWithMutationScope(
            name: []const u8,
            description: []const u8,
            mutation_scope: PassMutationScope,
        ) Self {
            return .{
                .base = .{
                    .name = name,
                    .description = description,
                    .run_fn = &runImpl,
                    .mutation_scope = mutation_scope,
                },
            };
        }

        fn runImpl(ctx: *PassContext) PassResult {
            return walkAndApply(ctx.op, ctx);
        }

        fn walkAndApply(op: *ir.Operation, ctx: *PassContext) PassResult {
            if (std.mem.eql(u8, op.name.name, OpType.operation_name)) {
                var typed_op = OpType{ .op = op };
                const result = run_on_op(&typed_op, ctx);
                if (result == .failure) {
                    return .failure;
                }
            }

            for (op.regions.items) |*region| {
                var block_iter = region.getBlocks();
                while (block_iter.next()) |block| {
                    var current_op: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
                    while (current_op) |nested_op| {
                        const result = walkAndApply(nested_op, ctx);
                        if (result == .failure) {
                            return .failure;
                        }
                        current_op = nested_op.next_op;
                    }
                }
            }

            return .success;
        }
    };
}
