const std = @import("std");
const library = @import("../../root.zig");
const catalog = descriptor_mod;
const attention = library.attention;
const reduction = library.reduction;
const ReductionOperand = catalog.ReductionOperand;
const descriptor_mod = @import("../root.zig");
const owned = @import("owned.zig");
const static = @import("static/root.zig");
const namespace = @import("root.zig");
const select = namespace.select;

test {
    @import("test_discovery").discover(selection_scalar_tests);
    @import("test_discovery").discover(selection_attention_tests);
    _ = @import("static/test.zig");
    @import("test_discovery").discover(owned);
    @import("test_discovery").discover(static);
}

test "accy kernel library catalog select declaration coverage" {
    std.testing.refAllDecls(owned);
    std.testing.refAllDecls(static);
}

const selection_scalar_tests = struct {
    test "kernel library catalog selects scalar reductions by einsum roles" {
        const input_dims = [_]i64{8};
        const output_dims = [_]i64{};
        const sum_inputs = [_]ReductionOperand{.{ .indices = "i", .dims = &input_dims }};
        const dot_inputs = [_]ReductionOperand{
            .{ .indices = "i", .dims = &input_dims },
            .{ .indices = "i", .dims = &input_dims },
        };

        const sum = select(.{ .reduction = .{
            .dtype = .f32,
            .kind = .sum,
            .inputs = &sum_inputs,
            .output_indices = "",
            .output_dims = &output_dims,
        } }) orelse return error.TestExpectedReductionSelection;
        const dot = select(.{ .reduction = .{
            .dtype = .f32,
            .kind = .dot_product,
            .inputs = &dot_inputs,
            .output_indices = "",
            .output_dims = &output_dims,
        } }) orelse return error.TestExpectedReductionSelection;

        try std.testing.expectEqualStrings(reduction.Sum8F32.target, sum.metadata.target);
        try std.testing.expectEqualStrings(reduction.Dot8F32.target, dot.metadata.target);
    }
};

const selection_attention_tests = struct {
    test "kernel library catalog selects scaled dot product attention by canonical roles" {
        const query_dims = [_]i64{ 2, 2, 2 };
        const key_dims = [_]i64{ 2, 3, 2 };
        const value_dims = [_]i64{ 2, 3, 2 };
        const output_dims = [_]i64{ 2, 2, 2 };
        const selected = select(.{ .attention = .{
            .dtype = .f32,
            .kind = .scaled_dot_product,
            .query_indices = "bqh",
            .key_indices = "bkh",
            .value_indices = "bkv",
            .output_indices = "bqv",
            .query_dims = &query_dims,
            .key_dims = &key_dims,
            .value_dims = &value_dims,
            .output_dims = &output_dims,
        } }) orelse return error.TestExpectedAttentionSelection;

        try std.testing.expectEqualStrings(attention.ScaledDotProductAttention2x2x3x2x2F32.target, selected.metadata.target);
        try std.testing.expectEqualStrings(attention.ScaledDotProductAttention2x2x3x2x2F32.name, selected.name);
    }

    test "kernel library catalog selects scaled dot product attention schedule specialization" {
        const query_dims = [_]i64{ 2, 2, 2 };
        const key_dims = [_]i64{ 2, 3, 2 };
        const value_dims = [_]i64{ 2, 3, 2 };
        const output_dims = [_]i64{ 2, 2, 2 };
        const selected = select(.{ .attention = .{
            .dtype = .f32,
            .kind = .scaled_dot_product,
            .query_indices = "bqh",
            .key_indices = "bkh",
            .value_indices = "bkv",
            .output_indices = "bqv",
            .query_dims = &query_dims,
            .key_dims = &key_dims,
            .value_dims = &value_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 2, .y = 2, .z = 1 } },
        } }) orelse return error.TestExpectedAttentionScheduleSelection;

        try std.testing.expectEqualStrings(attention.ScaledDotProductAttention2x2x3x2x2F32.target, selected.metadata.target);
        try std.testing.expectEqual(@as(u32, 2), selected.metadata.specialization.launch.?.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 2), selected.metadata.specialization.launch.?.threadgroup[1]);
        try std.testing.expectEqual(@as(u32, 1), selected.metadata.specialization.launch.?.threadgroup[2]);
    }
};
