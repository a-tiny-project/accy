const std = @import("std");
const accy = @import("../../root.zig");
const tensor = @import("../root.zig");
const format = @import("format.zig");

const program_mod = tensor.program;
const ByteWriter = accy.artifact.wire.ByteWriter;
const Dim = tensor.Dim;
const Id = program_mod.Id;
const Kind = program_mod.Kind;
const Operation = program_mod.Operation;
const Program = program_mod.Program;
const Subgraph = program_mod.Subgraph;
const Type = program_mod.Type;

const Frame = struct {
    graph: Subgraph,
    next: usize = 0,
};

/// A caller uses this to send a tensor program to another process, so the function writes `program`
/// as version 1 bytes, which the caller owns. The call returns `error.InvalidProgram` unless the
/// operation ids run densely from zero and the parameter operations appear in parameter order, and
/// every program made by the program builder meets both. The program builder is the tracer that
/// appends one operation at a time and checks each result type as it goes. The call returns
/// `error.ScanTooDeep` when scans nest deeper than eight levels and `error.InvalidArtifact` when a
/// list or string is longer than a 32-bit count can hold.
pub fn encode(allocator: std.mem.Allocator, program: *const Program) ![]u8 {
    var sink = Sink{ .allocator = allocator };
    errdefer sink.writer.deinit(allocator);
    try sink.word(format.magic);
    try sink.word(format.version);
    try sink.bytes(program.name);

    var frames: [format.max_scan_depth + 1]Frame = undefined;
    frames[0] = .{ .graph = .{
        .values = program.values,
        .operations = program.operations,
        .parameters = program.parameters,
        .outputs = program.outputs,
    } };
    var count: usize = 1;
    try sink.graph(frames[0].graph);
    while (count != 0) {
        const frame = &frames[count - 1];
        std.debug.assert(frame.next <= frame.graph.operations.len);
        if (frame.next == frame.graph.operations.len) {
            try sink.idList(frame.graph.outputs);
            count -= 1;
            continue;
        }
        const op = frame.graph.operations[frame.next];
        frame.next += 1;
        try sink.operation(op);
        if (op.kind != .scan) continue;
        if (count > format.max_scan_depth) return error.ScanTooDeep;
        frames[count] = .{ .graph = op.kind.scan.body.* };
        count += 1;
        std.debug.assert(count <= frames.len);
        try sink.graph(op.kind.scan.body.*);
    }
    return sink.writer.toOwnedSlice(allocator);
}

const Sink = struct {
    allocator: std.mem.Allocator,
    writer: ByteWriter = .{},

    fn word(self: *Sink, value: u32) !void {
        try self.writer.writeU32(self.allocator, value);
    }

    fn integer(self: *Sink, value: i64) !void {
        try self.writer.writeU64(self.allocator, @bitCast(value));
    }

    fn bytes(self: *Sink, value: []const u8) !void {
        try self.writer.writeLengthPrefixedBytes(self.allocator, value);
    }

    fn count(self: *Sink, len: usize) !void {
        try self.word(std.math.cast(u32, len) orelse return error.InvalidArtifact);
    }

    fn id(self: *Sink, value: Id) !void {
        std.debug.assert(value.index != program_mod.synthetic_id.index);
        try self.word(value.index);
    }

    fn ids(self: *Sink, values: []const Id) !void {
        std.debug.assert(values.len <= program_mod.max_operation_operands);
        for (values) |value| try self.id(value);
    }

    fn idList(self: *Sink, values: []const Id) !void {
        try self.count(values.len);
        for (values) |value| try self.id(value);
    }

    fn integers(self: *Sink, values: []const i64) !void {
        try self.count(values.len);
        for (values) |value| try self.integer(value);
    }

    fn dims(self: *Sink, values: []const Dim) !void {
        try self.count(values.len);
        for (values) |dim| {
            try self.bytes(dim.name);
            try self.integer(dim.extent);
        }
    }

    fn typed(self: *Sink, value: Type) !void {
        try self.word(format.dtype_codes.code(value.dtype));
        try self.dims(value.dims);
    }

    fn graph(self: *Sink, value: Subgraph) !void {
        if (value.values.len != value.operations.len) return error.InvalidProgram;
        var parameter_count: usize = 0;
        for (value.operations, 0..) |op, index| {
            if (op.id.index != index) return error.InvalidProgram;
            const parameter = switch (op.kind) {
                .parameter => |payload| payload,
                else => continue,
            };
            if (parameter.index != parameter_count) return error.InvalidProgram;
            if (parameter_count == value.parameters.len) return error.InvalidProgram;
            if (value.parameters[parameter_count].index != index) return error.InvalidProgram;
            parameter_count += 1;
        }
        if (parameter_count != value.parameters.len) return error.InvalidProgram;
        try self.count(value.operations.len);
    }

    fn operation(self: *Sink, op: Operation) !void {
        try self.word(format.kind_codes.code(std.meta.activeTag(op.kind)));
        switch (op.kind) {
            .parameter => try self.typed(op.result),
            .constant => |constant| {
                try self.typed(op.result);
                try self.bytes(constant.payload);
            },
            .iota => |iota| {
                try self.typed(op.result);
                try self.integer(iota.axis);
            },
            .custom_call => |custom| {
                try self.typed(op.result);
                try self.bytes(custom.target);
                try self.word(custom.version);
                try self.idList(custom.operands);
            },
            .broadcast => |broadcast| {
                try self.dims(op.result.dims);
                try self.id(broadcast.input);
            },
            .broadcast_in_dim => |broadcast| {
                try self.dims(op.result.dims);
                try self.id(broadcast.input);
                try self.integers(broadcast.broadcast_dims);
            },
            .reshape => |reshape| {
                try self.dims(op.result.dims);
                try self.id(reshape.input);
            },
            .scan => |scan| {
                std.debug.assert(scan.body.parameters.len == scan.inits.len);
                try self.integer(scan.length);
                try self.idList(scan.inits);
            },
            else => try self.derived(op.kind),
        }
    }

    fn derived(self: *Sink, kind: Kind) !void {
        switch (kind) {
            .unary => |unary| {
                try self.word(format.unary_codes.code(unary.op));
                try self.id(unary.input);
            },
            .binary => |binary| {
                try self.word(format.binary_codes.code(binary.op));
                try self.ids(&.{ binary.lhs, binary.rhs });
            },
            .compare => |compare| {
                try self.word(format.compare_codes.code(compare.direction));
                try self.ids(&.{ compare.lhs, compare.rhs });
            },
            .select => |select| try self.ids(&.{ select.pred, select.on_true, select.on_false }),
            .projection => |projection| {
                try self.id(projection.source);
                try self.count(projection.index);
            },
            .transpose => |transpose| {
                try self.id(transpose.input);
                try self.integers(transpose.permutation);
            },
            .reduce => |reduce| {
                try self.ids(&.{ reduce.input, reduce.init });
                try self.word(format.reducer_codes.code(reduce.reducer));
                try self.integers(reduce.dimensions);
            },
            .gather => |gather| {
                try self.ids(&.{ gather.input, gather.indices });
                try self.integer(gather.axis);
            },
            .scatter_add => |scatter| {
                try self.ids(&.{ scatter.input, scatter.indices, scatter.updates });
                try self.integer(scatter.axis);
            },
            .sparse_cross_entropy => |loss| {
                try self.ids(&.{ loss.logits, loss.targets });
                try self.integer(loss.axis);
            },
            .dot_general => |dot| {
                try self.ids(&.{ dot.lhs, dot.rhs });
                const axes = [_][]const i64{
                    dot.lhs_contract,
                    dot.rhs_contract,
                    dot.lhs_batch,
                    dot.rhs_batch,
                };
                for (axes) |values| try self.integers(values);
            },
            .parameter, .constant, .iota, .custom_call => unreachable,
            .broadcast, .broadcast_in_dim, .reshape, .scan => unreachable,
        }
    }
};
