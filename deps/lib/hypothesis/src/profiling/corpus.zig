const std = @import("std");
const hypothesis = @import("hypothesis");

const ChoiceNode = hypothesis.ChoiceNode;
const Span = hypothesis.Span;
const Status = hypothesis.Status;

pub const delete_choices: usize = 1024;
pub const delete_span_width: usize = 4;
pub const delete_survivors: usize = 128;
pub const lattice_small: usize = 256;
pub const lattice_large: usize = 4096;
pub const lattice_floor: u64 = 1000;
pub const stall_choices: usize = 1024;
pub const stall_span_width: usize = 8;
pub const stall_value: u64 = 7;
pub const draw_choices: usize = 4096;
pub const draw_blocks: usize = 64;
pub const shrink_budget: usize = 5000;
pub const engine_list: usize = 64;
pub const engine_sum_limit: u64 = 30_000;
pub const seed: u64 = 0xdecafbad;

pub const State = struct {
    delete: []const ChoiceNode,
    delete_spans: []const Span,
    lattice256: []const ChoiceNode,
    lattice4096: []const ChoiceNode,
    stall: []const ChoiceNode,
    stall_spans: []const Span,
    replay: []const ChoiceNode,
};

var state: ?State = null;

pub fn get() *const State {
    if (state) |*built| return built;
    @panic("hypothesis profiling corpus not built");
}

pub fn reset() void {
    state = null;
}

pub fn build(arena: std.mem.Allocator) !void {
    state = .{
        .delete = try integerChoices(arena, delete_choices, 5, 0, 10),
        .delete_spans = try flatSpans(arena, delete_choices, delete_span_width),
        .lattice256 = try integerChoices(arena, lattice_small, 1 << 31, 0, 1 << 32),
        .lattice4096 = try integerChoices(arena, lattice_large, 1 << 31, 0, 1 << 32),
        .stall = try integerChoices(arena, stall_choices, stall_value, 0, 100),
        .stall_spans = try flatSpans(arena, stall_choices, stall_span_width),
        .replay = try rampChoices(arena, draw_choices),
    };
}

fn integerChoices(
    arena: std.mem.Allocator,
    count: usize,
    value: u64,
    min: u64,
    max: u64,
) ![]const ChoiceNode {
    const nodes = try arena.alloc(ChoiceNode, count);
    for (nodes) |*node| {
        node.* = .{
            .kind = .integer,
            .value = value,
            .min = min,
            .max = max,
            .shrink_towards = 0,
        };
    }
    return nodes;
}

fn rampChoices(arena: std.mem.Allocator, count: usize) ![]const ChoiceNode {
    const nodes = try arena.alloc(ChoiceNode, count);
    for (nodes, 0..) |*node, index| {
        node.* = .{
            .kind = .integer,
            .value = @intCast(index % 1000),
            .min = 0,
            .max = 1 << 32,
            .shrink_towards = 0,
        };
    }
    return nodes;
}

fn flatSpans(arena: std.mem.Allocator, count: usize, width: usize) ![]const Span {
    const spans = try arena.alloc(Span, count / width);
    for (spans, 0..) |*span, index| {
        span.* = .{
            .label = "blk",
            .start = index * width,
            .end = index * width + width,
            .depth = 0,
        };
    }
    return spans;
}

pub fn survivorsPredicate(
    choices: []const ChoiceNode,
    byte_blocks: ?[]const u8,
    context: *anyopaque,
) Status {
    _ = byte_blocks;
    _ = context;
    return if (choices.len >= delete_survivors) .interesting else .valid;
}

pub fn latticePredicate(
    choices: []const ChoiceNode,
    byte_blocks: ?[]const u8,
    context: *anyopaque,
) Status {
    _ = byte_blocks;
    _ = context;
    for (choices) |node| {
        if (node.value < lattice_floor) return .valid;
    }
    return .interesting;
}

pub fn stallPredicate(
    choices: []const ChoiceNode,
    byte_blocks: ?[]const u8,
    context: *anyopaque,
) Status {
    _ = byte_blocks;
    _ = context;
    if (choices.len != stall_choices) return .valid;
    for (choices) |node| {
        if (node.value != stall_value) return .valid;
    }
    return .interesting;
}

test "corpus builds deterministic shapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try build(arena_state.allocator());
    defer reset();
    const built = get();
    try std.testing.expectEqual(delete_choices, built.delete.len);
    try std.testing.expectEqual(delete_choices / delete_span_width, built.delete_spans.len);
    try std.testing.expectEqual(lattice_large, built.lattice4096.len);
    try std.testing.expectEqual(@as(u64, 999), built.replay[999].value);
}
