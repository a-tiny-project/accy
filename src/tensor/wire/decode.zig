const std = @import("std");
const accy = @import("../../root.zig");
const tensor = @import("../root.zig");
const format = @import("format.zig");

const program_mod = tensor.program;
const Builder = tensor.trace.Builder;
const ByteReader = accy.artifact.wire.ByteReader;
const Dim = tensor.Dim;
const Id = program_mod.Id;
const Kind = program_mod.Kind;
const Operation = program_mod.Operation;
const Program = program_mod.Program;
const Tag = format.Tag;
const Type = program_mod.Type;
const Value = tensor.trace.Value;

const max_operands = program_mod.max_operation_operands;
const min_dim_bytes = @sizeOf(u32) + @sizeOf(i64);
const derived_result = Type.scalar(.i1);

/// A caller uses this function to rebuild a tensor program from wire bytes, the versioned byte
/// encoding of a tensor program, sent by another process. The function reads version 1 bytes and
/// replays each operation through `Builder.operation` on the program builder, the object that
/// builds a program one checked operation at a time, which works out every result type again and
/// checks it, so the bytes never supply a result type the builder did not derive. Bytes that end
/// early or carry anything after the program return `error.InvalidArtifact`. A wrong magic number
/// returns `error.BadMagic` and another version returns `error.UnsupportedVersion`. The caller owns
/// the returned program and frees it with `Program.deinit`. The builder copies names and payloads
/// into the program's own memory, so the caller may free `bytes` as soon as the call returns.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Program {
    var decoder = Decoder{ .allocator = allocator, .reader = .{ .bytes = bytes } };
    defer decoder.deinit();
    if (try decoder.reader.readU32() != format.magic) return error.BadMagic;
    if (try decoder.reader.readU32() != format.version) return error.UnsupportedVersion;
    const name = try decoder.reader.readLengthPrefixedBytes();
    try decoder.open(name, .{});
    for (0..bytes.len) |_| {
        const frame = &decoder.frames[decoder.count - 1];
        if (frame.remaining != 0) {
            frame.remaining -= 1;
            try decoder.operation(frame);
        } else if (decoder.count == 1) {
            return decoder.finish(frame);
        } else {
            try decoder.close();
        }
    }
    unreachable;
}

const Scan = struct {
    length: i64 = 0,
    inits: [program_mod.max_scan_carries]Id = undefined,
    init_count: usize = 0,
};

const Frame = struct {
    builder: Builder,
    values: std.ArrayListUnmanaged(Value) = .empty,
    remaining: u32,
    scan: Scan,
};

const Span = struct {
    start: usize,
    end: usize,
};

const Decoder = struct {
    allocator: std.mem.Allocator,
    reader: ByteReader,
    frames: [format.max_scan_depth + 1]Frame = undefined,
    count: usize = 0,
    dims: std.ArrayListUnmanaged(Dim) = .empty,
    integers: std.ArrayListUnmanaged(i64) = .empty,
    operands: [max_operands]Id = undefined,

    fn deinit(self: *Decoder) void {
        std.debug.assert(self.count <= self.frames.len);
        for (self.frames[0..self.count]) |*frame| {
            frame.values.deinit(self.allocator);
            frame.builder.deinit();
        }
        self.integers.deinit(self.allocator);
        self.dims.deinit(self.allocator);
        self.* = undefined;
    }

    fn open(self: *Decoder, name: []const u8, scan: Scan) !void {
        std.debug.assert(self.count < self.frames.len);
        std.debug.assert(scan.init_count <= scan.inits.len);
        const remaining = try self.reader.readU32();
        self.frames[self.count] = .{
            .builder = try Builder.init(self.allocator, name),
            .remaining = remaining,
            .scan = scan,
        };
        self.count += 1;
    }

    fn operation(self: *Decoder, frame: *Frame) !void {
        const tag = try format.kind_codes.decode(try self.reader.readU32());
        const limit = frame.values.items.len;
        if (tag == .scan) {
            if (self.count > format.max_scan_depth) return error.ScanTooDeep;
            var scan = Scan{ .length = try self.reader.readInt(i64) };
            const inits = try self.readIdList(limit, program_mod.max_scan_carries);
            @memcpy(scan.inits[0..inits.len], inits);
            scan.init_count = inits.len;
            return self.open("scan_body", scan);
        }
        self.dims.clearRetainingCapacity();
        self.integers.clearRetainingCapacity();
        const op = try self.readOperation(tag, limit);
        try self.bind(frame, &op);
    }

    fn close(self: *Decoder) !void {
        std.debug.assert(self.count >= 2);
        const body = &self.frames[self.count - 1];
        std.debug.assert(body.remaining == 0);
        const count = try self.readCount(@sizeOf(u32));
        const outputs = try body.builder.arena.allocator().alloc(Id, count);
        for (outputs) |*output| output.* = try self.readId(body.values.items.len);
        const view = program_mod.Subgraph{
            .values = body.builder.values.items,
            .operations = body.builder.operations.items,
            .parameters = body.builder.parameters_list.items,
            .outputs = outputs,
        };
        const op = derivedOperation(.{ .scan = .{
            .length = body.scan.length,
            .inits = body.scan.inits[0..body.scan.init_count],
            .body = &view,
        } });
        try self.bind(&self.frames[self.count - 2], &op);
        self.count -= 1;
        body.values.deinit(self.allocator);
        body.builder.deinit();
    }

    fn finish(self: *Decoder, root: *Frame) !Program {
        std.debug.assert(self.count == 1);
        std.debug.assert(root.remaining == 0);
        const count = try self.readCount(@sizeOf(u32));
        const outputs = try self.allocator.alloc(Value, count);
        defer self.allocator.free(outputs);
        for (outputs) |*output| {
            output.* = root.values.items[(try self.readId(root.values.items.len)).index];
        }
        try self.reader.expectDone();
        return root.builder.finish(outputs);
    }

    fn bind(self: *Decoder, frame: *Frame, op: *const Operation) !void {
        var buffer: [max_operands]Value = undefined;
        const args = tensor.interpret.arguments(Value, op, frame.values.items, &buffer);
        const value = try frame.builder.operation(op, args);
        std.debug.assert(value.id.index == frame.values.items.len);
        std.debug.assert(frame.builder.values.items.len == frame.values.items.len + 1);
        try frame.values.append(self.allocator, value);
    }

    fn readOperation(self: *Decoder, tag: Tag, limit: usize) !Operation {
        switch (tag) {
            .parameter => {
                const result = try self.readType();
                return typedOperation(result, .{ .parameter = .{ .index = 0 } });
            },
            .constant => {
                const result = try self.readType();
                const payload = try self.reader.readLengthPrefixedBytes();
                return typedOperation(result, .{ .constant = .{ .payload = payload } });
            },
            .iota => {
                const result = try self.readType();
                const axis = try self.reader.readInt(i64);
                return typedOperation(result, .{ .iota = .{ .axis = axis } });
            },
            .custom_call => {
                const result = try self.readType();
                const target = try self.reader.readLengthPrefixedBytes();
                const version = try self.reader.readU32();
                const operands = try self.readIdList(limit, program_mod.max_custom_call_operands);
                return typedOperation(result, .{ .custom_call = .{
                    .target = target,
                    .version = version,
                    .operands = operands,
                } });
            },
            .broadcast, .broadcast_in_dim, .reshape => return self.readShaped(tag, limit),
            .unary, .binary, .compare, .select, .projection => {
                return self.readPointwise(tag, limit);
            },
            .transpose, .reduce, .gather, .scatter_add, .sparse_cross_entropy, .dot_general => {
                return self.readAxial(tag, limit);
            },
            .scan => unreachable,
        }
    }

    fn readShaped(self: *Decoder, tag: Tag, limit: usize) !Operation {
        const result = Type{ .dtype = derived_result.dtype, .dims = try self.readDims() };
        const input = try self.readId(limit);
        return typedOperation(result, switch (tag) {
            .broadcast => .{ .broadcast = .{ .input = input, .sizes = &.{} } },
            .broadcast_in_dim => .{ .broadcast_in_dim = .{
                .input = input,
                .broadcast_dims = self.slice(try self.readIntegers()),
            } },
            .reshape => .{ .reshape = .{ .input = input, .new_shape = &.{} } },
            else => unreachable,
        });
    }

    fn readPointwise(self: *Decoder, tag: Tag, limit: usize) !Operation {
        switch (tag) {
            .unary => {
                const op = try format.unary_codes.decode(try self.reader.readU32());
                const input = try self.readId(limit);
                return derivedOperation(.{ .unary = .{ .op = op, .input = input } });
            },
            .binary => {
                const op = try format.binary_codes.decode(try self.reader.readU32());
                const ids = try self.readIds(limit, 2);
                return derivedOperation(.{ .binary = .{ .op = op, .lhs = ids[0], .rhs = ids[1] } });
            },
            .compare => {
                const direction = try format.compare_codes.decode(try self.reader.readU32());
                const ids = try self.readIds(limit, 2);
                return derivedOperation(.{ .compare = .{
                    .lhs = ids[0],
                    .rhs = ids[1],
                    .direction = direction,
                } });
            },
            .select => {
                const ids = try self.readIds(limit, 3);
                return derivedOperation(.{ .select = .{
                    .pred = ids[0],
                    .on_true = ids[1],
                    .on_false = ids[2],
                } });
            },
            .projection => {
                const source = try self.readId(limit);
                const index = try self.reader.readU32();
                return derivedOperation(.{ .projection = .{ .source = source, .index = index } });
            },
            else => unreachable,
        }
    }

    fn readAxial(self: *Decoder, tag: Tag, limit: usize) !Operation {
        switch (tag) {
            .transpose => {
                const input = try self.readId(limit);
                const permutation = self.slice(try self.readIntegers());
                return derivedOperation(.{ .transpose = .{
                    .input = input,
                    .permutation = permutation,
                } });
            },
            .reduce => {
                const ids = try self.readIds(limit, 2);
                const reducer = try format.reducer_codes.decode(try self.reader.readU32());
                const dimensions = self.slice(try self.readIntegers());
                return derivedOperation(.{ .reduce = .{
                    .input = ids[0],
                    .init = ids[1],
                    .reducer = reducer,
                    .dimensions = dimensions,
                } });
            },
            .gather => {
                const ids = try self.readIds(limit, 2);
                const axis = try self.reader.readInt(i64);
                return derivedOperation(.{ .gather = .{
                    .input = ids[0],
                    .indices = ids[1],
                    .axis = axis,
                } });
            },
            .scatter_add => {
                const ids = try self.readIds(limit, 3);
                const axis = try self.reader.readInt(i64);
                return derivedOperation(.{ .scatter_add = .{
                    .input = ids[0],
                    .indices = ids[1],
                    .updates = ids[2],
                    .axis = axis,
                } });
            },
            .sparse_cross_entropy, .dot_general => return self.readContraction(tag, limit),
            else => unreachable,
        }
    }

    fn readContraction(self: *Decoder, tag: Tag, limit: usize) !Operation {
        const ids = try self.readIds(limit, 2);
        if (tag == .sparse_cross_entropy) {
            const axis = try self.reader.readInt(i64);
            return derivedOperation(.{ .sparse_cross_entropy = .{
                .logits = ids[0],
                .targets = ids[1],
                .axis = axis,
            } });
        }
        std.debug.assert(tag == .dot_general);
        var spans: [4]Span = undefined;
        for (&spans) |*span| span.* = try self.readIntegers();
        return derivedOperation(.{ .dot_general = .{
            .lhs = ids[0],
            .rhs = ids[1],
            .lhs_contract = self.slice(spans[0]),
            .rhs_contract = self.slice(spans[1]),
            .lhs_batch = self.slice(spans[2]),
            .rhs_batch = self.slice(spans[3]),
        } });
    }

    fn readCount(self: *Decoder, min_item_bytes: usize) !u32 {
        std.debug.assert(min_item_bytes != 0);
        const count = try self.reader.readU32();
        if (count > self.reader.remaining() / min_item_bytes) return error.InvalidArtifact;
        return count;
    }

    fn readId(self: *Decoder, limit: usize) !Id {
        const index = try self.reader.readU32();
        if (index >= limit) return error.InvalidReference;
        return .{ .index = index };
    }

    fn readIds(self: *Decoder, limit: usize, comptime count: usize) ![count]Id {
        var ids: [count]Id = undefined;
        for (&ids) |*id| id.* = try self.readId(limit);
        return ids;
    }

    fn readIdList(self: *Decoder, limit: usize, max: usize) ![]const Id {
        std.debug.assert(max <= self.operands.len);
        const count = try self.readCount(@sizeOf(u32));
        if (count > max) return error.TooManyOperands;
        for (self.operands[0..count]) |*id| id.* = try self.readId(limit);
        return self.operands[0..count];
    }

    fn readIntegers(self: *Decoder) !Span {
        const count = try self.readCount(@sizeOf(i64));
        const start = self.integers.items.len;
        try self.integers.ensureUnusedCapacity(self.allocator, count);
        for (0..count) |_| self.integers.appendAssumeCapacity(try self.reader.readInt(i64));
        return .{ .start = start, .end = self.integers.items.len };
    }

    fn slice(self: *const Decoder, span: Span) []const i64 {
        std.debug.assert(span.start <= span.end);
        std.debug.assert(span.end <= self.integers.items.len);
        return self.integers.items[span.start..span.end];
    }

    fn readDims(self: *Decoder) ![]const Dim {
        const rank = try self.readCount(min_dim_bytes);
        self.dims.clearRetainingCapacity();
        try self.dims.ensureTotalCapacity(self.allocator, rank);
        for (0..rank) |_| {
            const name = try self.reader.readLengthPrefixedBytes();
            const extent = try self.reader.readInt(i64);
            self.dims.appendAssumeCapacity(.{ .name = name, .extent = extent });
        }
        return self.dims.items;
    }

    fn readType(self: *Decoder) !Type {
        const dtype = try format.dtype_codes.decode(try self.reader.readU32());
        return .{ .dtype = dtype, .dims = try self.readDims() };
    }
};

fn typedOperation(result: Type, kind: Kind) Operation {
    return .{ .id = program_mod.synthetic_id, .result = result, .kind = kind };
}

fn derivedOperation(kind: Kind) Operation {
    return .{ .id = program_mod.synthetic_id, .result = derived_result, .kind = kind };
}
