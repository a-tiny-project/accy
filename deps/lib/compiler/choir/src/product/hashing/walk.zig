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
