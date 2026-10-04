const std = @import("std");
const interpret = @import("interpret/root.zig");
const program_mod = @import("program.zig");
const trace = @import("trace/root.zig");
const types = @import("type/root.zig");

pub fn apply(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
) !program_mod.Program {
    var builder = try trace.Builder.init(allocator, source.name);
    errdefer builder.deinit();

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const graph = interpret.Graph{ .builder = &builder };
    return try interpret.run(allocator, source, Semantics(@TypeOf(graph)){
        .next = graph,
        .scratch = scratch.allocator(),
    });
}

fn Semantics(comptime Next: type) type {
    return struct {
        next: Next,
        scratch: std.mem.Allocator,
        finals: std.AutoHashMapUnmanaged(u32, []trace.Value) = .empty,

        pub const Value: type = trace.Value;
        pub const Result: type = Next.Result;

        pub fn operation(self: *@This(), step: *interpret.Step(Value)) !Value {
            switch (step.op.kind) {
                .scan => |scan| {
                    var buffer: [program_mod.max_scan_carries]trace.Value = undefined;
                    for (scan.inits, 0..) |init_id, index| buffer[index] = step.read(init_id);
                    const expanded = try self.expandScan(scan, buffer[0..scan.inits.len]);
                    try self.finals.put(self.scratch, step.op.id.index, expanded);
                    return expanded[0];
                },
                .projection => |projection| {
                    return self.finals.get(projection.source.index).?[projection.index];
                },
                else => {
                    var buffer: [program_mod.max_operation_operands]trace.Value = undefined;
                    return self.next.bind(
                        step.op,
                        interpret.arguments(Value, step.op, step.values, &buffer),
                    );
                },
            }
        }

        fn expandScan(
            self: *@This(),
            scan: program_mod.Scan,
            inits: []const trace.Value,
        ) anyerror![]trace.Value {
            const carries = try self.scratch.dupe(trace.Value, inits);
            var iteration: i64 = 0;
            while (iteration < scan.length) : (iteration += 1) {
                try self.expandStep(scan.body, carries);
            }
            return carries;
        }

        fn expandStep(
            self: *@This(),
            body: *const program_mod.Subgraph,
            carries: []trace.Value,
        ) !void {
            const values = try self.scratch.alloc(trace.Value, body.values.len);
            var nested_finals: std.AutoHashMapUnmanaged(u32, []trace.Value) = .empty;
            for (body.operations) |*op| {
                values[op.id.index] = switch (op.kind) {
                    .parameter => |parameter| carries[parameter.index],
                    .scan => |nested| blk: {
                        var buffer: [program_mod.max_scan_carries]trace.Value = undefined;
                        for (nested.inits, 0..) |init_id, index| {
                            buffer[index] = values[init_id.index];
                        }
                        const expanded = try self.expandScan(nested, buffer[0..nested.inits.len]);
                        try nested_finals.put(self.scratch, op.id.index, expanded);
                        break :blk expanded[0];
                    },
                    .projection => |projection| nested_finals.get(
                        projection.source.index,
                    ).?[projection.index],
                    else => blk: {
                        var buffer: [program_mod.max_operation_operands]trace.Value = undefined;
                        const args = interpret.arguments(Value, op, values, &buffer);
                        break :blk try self.next.bind(op, args);
                    },
                };
            }
            var buffer: [program_mod.max_scan_carries]trace.Value = undefined;
            for (body.outputs, 0..) |id, index| buffer[index] = values[id.index];
            @memcpy(carries, buffer[0..body.outputs.len]);
        }

        pub fn finish(self: *@This(), outputs: []const Value) !Result {
            return self.next.finish(outputs);
        }

        pub fn builderHandle(self: *@This()) *trace.Builder {
            return self.next.builderHandle();
        }
    };
}

fn incrementScanStep(scan_builder: *trace.Builder, carry: trace.Value) !trace.Value {
    const bump = try scan_builder.full(.f32, .{ .lane = 2 }, 1.0);
    return carry.add(bump);
}

fn projectionScanStep(_: *trace.Builder, carry: anytype) !@TypeOf(carry) {
    const doubled = try carry.x.add(carry.x);
    return .{
        .x = doubled,
        .acc = try carry.acc.add(doubled),
    };
}
