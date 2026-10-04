const catalog = @import("../../../root.zig");
const library = @import("../../../../root.zig");

const entry = library.entry;
const FusedLinalgEpilogue = catalog.FusedLinalgEpilogue;

pub fn fusedLinalgEpilogueMatches(
    specialization: entry.Specialization,
    epilogue_value: FusedLinalgEpilogue,
    bias_extent: u64,
) bool {
    return switch (epilogue_value) {
        .bias_activation => |activation| specialization.epilogueMatches(0, .{
            .operator = .bias_add,
            .input_index = 2,
            .extents = &.{bias_extent},
        }) and specialization.epilogueMatches(1, .{ .operator = .{ .activation = activation } }),
    };
}
