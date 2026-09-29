const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");
const hashing = @import("root.zig");
const capacity = hashing.capacity;

pub const Event = union(enum) {
    operation: *ir.Operation,
    region: *ir.Region,
    block: *ir.Block,
};

pub const Iterator = struct {
    frames: []capacity.OperationFrame,
    depth: usize,

    pub fn init(frames: []capacity.OperationFrame, root: *ir.Operation) Iterator {
        if (frames.len == 0) @panic("operation traversal has no frame capacity");
        frames[0] = .{ .operation = root };
        return .{ .frames = frames, .depth = 1 };
    }

    pub fn next(self: *Iterator) ?Event {
        while (self.depth > 0) {
            const frame = &self.frames[self.depth - 1];
            switch (frame.state) {
                .operation => {
                    frame.state = .region;
                    return .{ .operation = frame.operation };
                },
                .region => {
                    if (frame.region_index >= frame.operation.regions.items.len) {
                        self.depth -= 1;
                        continue;
                    }
                    const region = &frame.operation.regions.items[frame.region_index];
                    frame.region_index += 1;
                    frame.block = if (region.blocks.head) |block_ptr|
                        @ptrCast(@alignCast(block_ptr))
                    else
                        null;
                    frame.state = .block;
                    return .{ .region = region };
                },
                .block => {
                    const block = frame.block orelse {
                        frame.state = .region;
                        continue;
                    };
                    frame.block = block.next;
                    frame.child = if (block.operations.head) |operation_ptr|
                        @ptrCast(@alignCast(operation_ptr))
                    else
                        null;
                    frame.state = .child;
                    return .{ .block = block };
                },
                .child => {
                    const child = frame.child orelse {
                        frame.state = .block;
                        continue;
                    };
                    frame.child = child.next_op;
                    if (self.depth >= self.frames.len) {
                        @panic("operation traversal exceeded inspected depth");
                    }
                    self.frames[self.depth] = .{ .operation = child };
                    self.depth += 1;
                },
            }
        }
        return null;
    }
};

test "iterator preserves multi-region and multi-block preorder" {
    const allocator = std.testing.allocator;
    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();
    const location = ir.Location.getUnknown();

    var first_region = ir.context.initRegion(&context);
    defer first_region.deinit();
    const first_block = try first_region.addBlock();
    const first = try context.createOperation(ir.Operation.State.init("first", location));
    try first_block.addOperation(first);
    const second_block = try first_region.addBlock();
    const second = try context.createOperation(ir.Operation.State.init("second", location));
    try second_block.addOperation(second);

    var second_region = ir.context.initRegion(&context);
    defer second_region.deinit();
    const third_block = try second_region.addBlock();
    const third = try context.createOperation(ir.Operation.State.init("third", location));
    try third_block.addOperation(third);

    var root_state = ir.Operation.State.init("root", location);
    root_state.addRegionBodies(&.{ &first_region, &second_region });
    const root = try context.createOperation(root_state);
    const limits = try capacity.Limits.inspect(root);
    try std.testing.expectEqual(@as(usize, 2), limits.facts.operation_depth);

    var frames: [2]capacity.OperationFrame = undefined;
    var iterator = Iterator.init(&frames, root);
    try std.testing.expectEqual(Event{ .operation = root }, iterator.next().?);
    try std.testing.expectEqual(Event{ .region = &root.regions.items[0] }, iterator.next().?);
    try std.testing.expectEqual(Event{ .block = first_block }, iterator.next().?);
    try std.testing.expectEqual(Event{ .operation = first }, iterator.next().?);
    try std.testing.expectEqual(Event{ .block = second_block }, iterator.next().?);
    try std.testing.expectEqual(Event{ .operation = second }, iterator.next().?);
    try std.testing.expectEqual(Event{ .region = &root.regions.items[1] }, iterator.next().?);
    try std.testing.expectEqual(Event{ .block = third_block }, iterator.next().?);
    try std.testing.expectEqual(Event{ .operation = third }, iterator.next().?);
    try std.testing.expect(iterator.next() == null);
}

test "iterator consumes the maximum inspected operation depth" {
    const allocator = std.testing.allocator;
    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();
    const location = ir.Location.getUnknown();

    var root_state = ir.Operation.State.init("root", location);
    root_state.addRegion();
    const root = try context.createOperation(root_state);
    var current = root;
    for (1..capacity.maximum_operation_depth) |_| {
        var child_state = ir.Operation.State.init("child", location);
        child_state.addRegion();
        const child = try context.createOperation(child_state);
        const block = try current.getRegion(0).?.addBlock();
        try block.addOperation(child);
        current = child;
    }

    const limits = try capacity.Limits.inspect(root);
    try std.testing.expectEqual(
        capacity.maximum_operation_depth,
        limits.facts.operation_depth,
    );
    var frames: [capacity.maximum_operation_depth]capacity.OperationFrame = undefined;
    var iterator = Iterator.init(&frames, root);
    var operation_count: usize = 0;
    while (iterator.next()) |event| switch (event) {
        .operation => operation_count += 1,
        .region, .block => {},
    };
    try std.testing.expectEqual(capacity.maximum_operation_depth, operation_count);
}
