const std = @import("std");
const abi = @import("gpu_abi");
const choir = @import("../../../root.zig");
const fixture = @import("../fixture/root.zig");
const registration = @import("../registration.zig");
const cpu = @import("root.zig");

const ir = choir.ir;
const testing = std.testing;
const countOperationsNamed = ir.inspection.countOperationsNamed;
const Arith = choir.dialects.ArithDialect;
const Gpu = choir.dialects.gpu.GpuDialect;
const Memref = choir.dialects.MemrefDialect;
const Scf = choir.dialects.ScfDialect;
const execution = choir.backends.execution;

test "cpu declaration coverage" {
    std.testing.refAllDecls(cpu.lowering);
    std.testing.refAllDecls(cpu);
}

/// A parsed kernel module and the host loop lowered from it, both owned by
/// `ctx`.
const Lowered = struct {
    ctx: ir.Context,
    kernel: *ir.Operation,
    host: *ir.Operation,
    text: []u8,

    fn init(
        self: *Lowered,
        source: []const u8,
        options: cpu.LowerOptions,
    ) !void {
        self.ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
        errdefer self.ctx.deinit(testing.allocator);
        try registration.prepareCompilationDialects(&self.ctx);
        self.kernel = try fixture.parse(&self.ctx, source);
        errdefer self.kernel.erase();
        self.host = try cpu.lowerKernelToHostLoop(testing.allocator, self.kernel, options);
        errdefer self.host.erase();
        try ir.verifyOperation(self.host, ir.verify.default_options);
        self.text = try ir.dump.operationAlloc(testing.allocator, self.host);
    }

    fn deinit(self: *Lowered) void {
        testing.allocator.free(self.text);
        self.host.erase();
        self.kernel.erase();
        self.ctx.deinit(testing.allocator);
    }

    fn function(self: *const Lowered) choir.dialects.FuncDialect.FuncOp {
        const body = ir.inspection.moduleBodyBlock(self.host).?;
        var operations = body.getOperations();
        const op = operations.next().?;
        std.debug.assert(ir.inspection.isFunctionDefinition(op));
        return .{ .op = op };
    }

    fn count(self: *const Lowered, comptime Op: type) usize {
        return countOperationsNamed(self.host, Op.operation_name);
    }

    /// Reports whether one printed line holds both `operation` and `type_name`.
    fn hasTypedLine(self: *const Lowered, operation: []const u8, type_name: []const u8) bool {
        var lines = std.mem.splitScalar(u8, self.text, '\n');
        while (lines.next()) |line| {
            const has_operation = std.mem.indexOf(u8, line, operation) != null;
            if (has_operation and std.mem.indexOf(u8, line, type_name) != null) return true;
        }
        return false;
    }
};

test "host loop lowering wraps a parsed global x kernel in an scf loop" {
    var lowered: Lowered = undefined;
    try lowered.init(@embedFile("fixture/copy.txt"), .{ .entry_name = "test_copy" });
    defer lowered.deinit();
    const host = lowered.function();
    try testing.expect(!host.isKernel());
    try testing.expectEqual(@as(usize, 10), host.getNumArguments());
    try testing.expect(lowered.count(Scf.ForOp) > 0);
    try testing.expectEqual(@as(usize, 0), lowered.count(Gpu.GlobalIdxOp));
    try testing.expect(lowered.count(Arith.RemOp) > 0);
    try testing.expect(lowered.count(Memref.LoadOp) > 0);
    try testing.expect(lowered.count(Memref.StoreOp) > 0);
}

test "host loop lowering vectorizes a parsed straight line add" {
    var lowered: Lowered = undefined;
    try lowered.init(@embedFile("fixture/vector.txt"), .{
        .entry_name = "test_vector",
        .vector_width = 4,
    });
    defer lowered.deinit();
    try testing.expectEqual(@as(usize, 0), lowered.count(Gpu.GlobalIdxOp));
    try testing.expect(lowered.hasTypedLine("memref.load(", "!arith.vec4xf32"));
    try testing.expect(lowered.hasTypedLine("arith.add(", "!arith.vec4xf32"));
}

test "host loop lowering splats a parsed scalar argument and keeps a scalar tail" {
    var lowered: Lowered = undefined;
    try lowered.init(@embedFile("fixture/splat.txt"), .{
        .entry_name = "test_splat",
        .vector_width = 4,
    });
    defer lowered.deinit();
    try testing.expectEqual(@as(usize, 2), lowered.count(Scf.ForOp));
    try testing.expect(lowered.hasTypedLine("arith.splat(", "!arith.vec4xf32"));
    try testing.expect(lowered.hasTypedLine("arith.add(", "!arith.vec4xf32"));
}

test "host loop lowering derives parsed global y and z from the flat launch shape" {
    var lowered: Lowered = undefined;
    try lowered.init(@embedFile("fixture/axes.txt"), .{ .entry_name = "test_axes" });
    defer lowered.deinit();
    try testing.expectEqual(@as(usize, 8), lowered.function().getNumArguments());
    try testing.expectEqual(@as(usize, 0), lowered.count(Gpu.GlobalIdxOp));
    try testing.expect(lowered.count(Arith.DivOp) > 0);
    try testing.expect(lowered.count(Arith.RemOp) > 0);
    try testing.expect(lowered.count(Arith.MulOp) > 0);
}

test "host loop lowering derives parsed thread, block and launch dimensions" {
    var lowered: Lowered = undefined;
    try lowered.init(@embedFile("fixture/dims.txt"), .{ .entry_name = "test_dims" });
    defer lowered.deinit();
    try testing.expectEqual(@as(usize, 8), lowered.function().getNumArguments());
    inline for (.{ Gpu.ThreadIdxOp, Gpu.BlockIdxOp, Gpu.BlockDimOp, Gpu.GridDimOp }) |Op| {
        try testing.expectEqual(@as(usize, 0), lowered.count(Op));
    }
    try testing.expect(lowered.count(Arith.DivOp) > 0);
    try testing.expect(lowered.count(Arith.RemOp) > 0);
}

test "host loop lowering rejects a parsed lane id" {
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try registration.prepareCompilationDialects(&ctx);
    const kernel = try fixture.parse(&ctx, @embedFile("fixture/lane.txt"));
    defer kernel.erase();
    try testing.expectError(
        error.UnsupportedOperation,
        cpu.lowerKernelToHostLoop(testing.allocator, kernel, .{ .entry_name = "test_lane" }),
    );
}

/// One argument of a checked call into compiled code.
const Invoke = execution.Value;

/// A kernel's host loop compiled for this machine and called over ranges of
/// one launch, as a pool worker or a harness thread calls the twin.
const Twin = struct {
    lowered: Lowered,
    runtime: execution.native.Runtime,
    handle: execution.Handle,
    entry_name: []const u8,

    /// The kernel arguments a twin call takes before the launch shape.
    const max_leading = 4;

    fn init(self: *Twin, source: []const u8, options: cpu.LowerOptions) !void {
        try self.lowered.init(source, options);
        errdefer self.lowered.deinit();
        self.runtime = try execution.native.Runtime.init(testing.allocator, .testing);
        errdefer self.runtime.deinit();
        self.handle = try self.runtime.compile(self.lowered.host);
        self.entry_name = options.entry_name;
    }

    fn deinit(self: *Twin) void {
        self.runtime.deinit();
        self.lowered.deinit();
    }

    /// Runs invocations [shape.first, shape.upper) of `shape`'s launch, with
    /// `leading` as the host function's buffers and then its scalars.
    fn run(self: *Twin, leading: []const Invoke, shape: abi.LaunchShape) !void {
        std.debug.assert(leading.len <= max_leading);
        var words: [abi.launch_shape_argument_count]abi.ScalarArgument = undefined;
        try shape.scalarArguments(&words);
        var arguments: [max_leading + abi.launch_shape_argument_count]Invoke = undefined;
        @memcpy(arguments[0..leading.len], leading);
        for (words, arguments[leading.len..][0..words.len]) |word, *argument| {
            argument.* = .{ .index = word.u32 };
        }
        const count = leading.len + words.len;
        try self.runtime.call(self.handle, self.entry_name, arguments[0..count], &.{});
    }

    /// Runs `shape` once into `whole` and as [first, split) then [split,
    /// upper) into `parts`, both filled with one sentinel first, and expects
    /// the same bytes. `leading[output]` is the buffer the kernel writes.
    fn expectSplitAgrees(
        self: *Twin,
        leading: []const Invoke,
        output: usize,
        whole: []u8,
        parts: []u8,
        shape: abi.LaunchShape,
        split: u32,
    ) !void {
        std.debug.assert(whole.len == parts.len);
        var arguments: [max_leading]Invoke = undefined;
        @memcpy(arguments[0..leading.len], leading);
        @memset(whole, sentinel);
        @memset(parts, sentinel);
        arguments[output] = .{ .memref = @intFromPtr(whole.ptr) };
        try self.run(arguments[0..leading.len], shape);
        arguments[output] = .{ .memref = @intFromPtr(parts.ptr) };
        try self.run(arguments[0..leading.len], shape.range(shape.first, split));
        try self.run(arguments[0..leading.len], shape.range(split, shape.upper));
        try testing.expectEqualSlices(u8, whole, parts);
    }
};

/// The byte every output starts as, so a write outside the launch shows.
const sentinel: u8 = 0xa5;

/// T = 37 invocations of a 40-wide row, split at 13: odd, not a multiple of
/// the vector width, and leaving a tail in both halves.
const row_geometry: abi.LaunchGeometry = .{ .grid = .{ 10, 1, 1 }, .threadgroup = .{ 4, 1, 1 } };
const row_total = 37;
const row_split = 13;

/// Rows of 6, 4 rows to a plane and 2 planes: 48 invocations, of which a
/// launch of `row_total` runs 37.
const cube_geometry: abi.LaunchGeometry = .{ .grid = .{ 3, 2, 2 }, .threadgroup = .{ 2, 2, 1 } };

/// Two rows of 16, a multiple of the vector width. A range from 13 starts a
/// vector at x = 13, whose fourth invocation is x = 0 of row 1.
const crossing_geometry: abi.LaunchGeometry = .{ .grid = .{ 4, 2, 1 }, .threadgroup = .{ 4, 1, 1 } };

/// Two rows of 6, not a multiple of the vector width. Run whole, a vector at 4
/// covers x = 4, 5, 0, 1, so only the scalar loop writes the right bytes.
/// Row 1 stores to the x that row 0 stores to, so a whole run cannot show
/// what the vector loop wrote. A range over row 0 alone runs a vector over
/// x = 0 to 3 and the scalar tail over x = 4 and 5.
const ragged_geometry: abi.LaunchGeometry = .{ .grid = .{ 3, 2, 1 }, .threadgroup = .{ 2, 1, 1 } };
const ragged_row = 6;

fn memrefOf(bytes: []u8) Invoke {
    return .{ .memref = @intFromPtr(bytes.ptr) };
}

test "a host loop run as two ranges writes the bytes one run writes" {
    if (comptime !execution.native.available) return error.SkipZigTest;
    const shape = try abi.launchShape(row_total, row_geometry);
    var lhs: [40]f32 = undefined;
    var rhs: [40]f32 = undefined;
    for (&lhs, &rhs, 0..) |*left, *right, index| {
        left.* = @as(f32, @floatFromInt(index)) * 0.5 + 1.0;
        right.* = @as(f32, @floatFromInt(index)) * -0.25;
    }
    const lhs_bytes = std.mem.sliceAsBytes(lhs[0..]);
    const rhs_bytes = std.mem.sliceAsBytes(rhs[0..]);
    var whole: [40]f32 = undefined;
    var parts: [40]f32 = undefined;
    const whole_bytes = std.mem.sliceAsBytes(whole[0..]);
    const parts_bytes = std.mem.sliceAsBytes(parts[0..]);

    var copy: Twin = undefined;
    try copy.init(@embedFile("fixture/copy.txt"), .{ .entry_name = "test_copy" });
    defer copy.deinit();
    const copied = [_]Invoke{ memrefOf(lhs_bytes), memrefOf(whole_bytes) };
    try copy.expectSplitAgrees(&copied, 1, whole_bytes, parts_bytes, shape, row_split);
    try testing.expectEqualSlices(f32, lhs[0..row_total], whole[0..row_total]);

    var vector: Twin = undefined;
    try vector.init(@embedFile("fixture/vector.txt"), .{
        .entry_name = "test_vector",
        .vector_width = 4,
    });
    defer vector.deinit();
    const summed = [_]Invoke{ memrefOf(whole_bytes), memrefOf(lhs_bytes), memrefOf(rhs_bytes) };
    try vector.expectSplitAgrees(&summed, 0, whole_bytes, parts_bytes, shape, row_split);
    for (whole[0..row_total], lhs[0..row_total], rhs[0..row_total]) |sum, left, right| {
        try testing.expectEqual(left + right, sum);
    }

    var splat: Twin = undefined;
    try splat.init(@embedFile("fixture/splat.txt"), .{
        .entry_name = "test_splat",
        .vector_width = 4,
    });
    defer splat.deinit();
    const offset: Invoke = .{ .i32 = @bitCast(@as(f32, 2.5)) };
    const splatted = [_]Invoke{ memrefOf(whole_bytes), memrefOf(lhs_bytes), offset };
    try splat.expectSplitAgrees(&splatted, 0, whole_bytes, parts_bytes, shape, row_split);
    for (whole[0..row_total], lhs[0..row_total]) |sum, left| try testing.expectEqual(left + 2.5, sum);
    for (whole_bytes[row_total * 4 ..]) |byte| try testing.expectEqual(sentinel, byte);
}

test "a range that is empty, or whose first is past its upper, runs no invocation" {
    if (comptime !execution.native.available) return error.SkipZigTest;
    const shape = try abi.launchShape(row_total, row_geometry);
    var lhs: [40]f32 = @splat(1.0);
    var rhs: [40]f32 = @splat(2.0);
    var out: [40]f32 = undefined;
    const out_bytes = std.mem.sliceAsBytes(out[0..]);
    @memset(out_bytes, sentinel);
    const leading = [_]Invoke{
        memrefOf(out_bytes),
        memrefOf(std.mem.sliceAsBytes(lhs[0..])),
        memrefOf(std.mem.sliceAsBytes(rhs[0..])),
    };

    var vector: Twin = undefined;
    try vector.init(@embedFile("fixture/vector.txt"), .{
        .entry_name = "test_vector",
        .vector_width = 4,
    });
    defer vector.deinit();
    try vector.run(&leading, shape.range(row_split, row_split));
    var reversed = shape;
    reversed.first = row_split + 7;
    reversed.upper = row_split;
    try vector.run(&leading, reversed);
    for (out_bytes) |byte| try testing.expectEqual(sentinel, byte);

    var copy: Twin = undefined;
    try copy.init(@embedFile("fixture/copy.txt"), .{ .entry_name = "test_copy" });
    defer copy.deinit();
    const copied = [_]Invoke{ leading[1], leading[0] };
    try copy.run(&copied, shape.range(row_split, row_split));
    try copy.run(&copied, reversed);
    for (out_bytes) |byte| try testing.expectEqual(sentinel, byte);
}

test "a range of a 3-D launch writes the global, thread and block indices one run writes" {
    if (comptime !execution.native.available) return error.SkipZigTest;
    const shape = try abi.launchShape(row_total, cube_geometry);
    var whole: [48]i32 = undefined;
    var parts: [48]i32 = undefined;
    const whole_bytes = std.mem.sliceAsBytes(whole[0..]);
    const parts_bytes = std.mem.sliceAsBytes(parts[0..]);

    var twin: Twin = undefined;
    try twin.init(@embedFile("fixture/range.txt"), .{ .entry_name = "test_range" });
    defer twin.deinit();
    try twin.expectSplitAgrees(&.{memrefOf(whole_bytes)}, 0, whole_bytes, parts_bytes, shape, row_split);
    for (whole[0..row_total], 0..) |value, linear| {
        const x = linear % 6;
        const y = linear / 6 % 4;
        const z = linear / 24;
        const expected = x % 2 + 10 * (x / 2) + 1000 * y + 100000 * z;
        try testing.expectEqual(@as(i32, @intCast(expected)), value);
    }
}

test "a vector never crosses a row of the launch, whatever the range's first" {
    if (comptime !execution.native.available) return error.SkipZigTest;
    var lhs: [32]f32 = undefined;
    var rhs: [32]f32 = undefined;
    for (&lhs, &rhs, 0..) |*left, *right, index| {
        left.* = @floatFromInt(index);
        right.* = 100.0;
    }
    const lhs_bytes = std.mem.sliceAsBytes(lhs[0..]);
    const rhs_bytes = std.mem.sliceAsBytes(rhs[0..]);
    var whole: [32]f32 = undefined;
    var parts: [32]f32 = undefined;
    const whole_bytes = std.mem.sliceAsBytes(whole[0..]);
    const parts_bytes = std.mem.sliceAsBytes(parts[0..]);

    var vector: Twin = undefined;
    try vector.init(@embedFile("fixture/vector.txt"), .{
        .entry_name = "test_vector",
        .vector_width = 4,
    });
    defer vector.deinit();
    const leading = [_]Invoke{ memrefOf(whole_bytes), memrefOf(lhs_bytes), memrefOf(rhs_bytes) };

    const rows = try abi.launchShape(32, crossing_geometry);
    try vector.expectSplitAgrees(&leading, 0, whole_bytes, parts_bytes, rows, row_split);
    for (whole[0..16], lhs[0..16]) |sum, left| try testing.expectEqual(left + 100.0, sum);
    for (whole_bytes[16 * 4 ..]) |byte| try testing.expectEqual(sentinel, byte);

    var scalar: Twin = undefined;
    try scalar.init(@embedFile("fixture/vector.txt"), .{ .entry_name = "test_vector" });
    defer scalar.deinit();
    const short = try abi.launchShape(12, ragged_geometry);
    @memset(whole_bytes, sentinel);
    @memset(parts_bytes, sentinel);
    try vector.run(&leading, short);
    var scalar_leading = leading;
    scalar_leading[0] = memrefOf(parts_bytes);
    try scalar.run(&scalar_leading, short);
    try testing.expectEqualSlices(u8, parts_bytes, whole_bytes);

    const first_row = short.range(0, ragged_row);
    @memset(whole_bytes, sentinel);
    @memset(parts_bytes, sentinel);
    try vector.run(&leading, first_row);
    try scalar.run(&scalar_leading, first_row);
    try testing.expectEqualSlices(u8, parts_bytes, whole_bytes);
    for (whole[0..ragged_row], lhs[0..ragged_row]) |sum, left| try testing.expectEqual(left + 100.0, sum);
    for (whole_bytes[ragged_row * 4 ..]) |byte| try testing.expectEqual(sentinel, byte);
}

/// A stage module and the host functions lowered from it, both owned by `session`.
const LoweredStages = struct {
    session: fixture.stages.Session,
    host: *ir.Operation,

    fn init(self: *LoweredStages, source: []const u8) !void {
        try self.session.init(testing.allocator, .testing, source, false);
        errdefer self.session.deinit(testing.allocator);
        self.host = try cpu.lowerStagesToHost(testing.allocator, self.session.module, null);
    }

    fn deinit(self: *LoweredStages) void {
        self.host.erase();
        self.session.deinit(testing.allocator);
    }
};

test "stage lowering turns each stage into a host function over the stage buffers" {
    var lowered: LoweredStages = undefined;
    try lowered.init(fixture.stages.cases[0].source);
    defer lowered.deinit();
    for ([_][]const u8{ "textured_vertex", "textured_fragment" }) |name| {
        const function = choir.dialects.FuncDialect.FuncOp{ .op = ir.inspection.functionDefinitionByName(lowered.host, name).? };
        try testing.expectEqual(@as(usize, 3), function.getNumArguments());
    }
    try testing.expectEqual(@as(usize, 0), countOperationsNamed(lowered.host, Gpu.StageInputOp.operation_name));
    try testing.expectEqual(@as(usize, 0), countOperationsNamed(lowered.host, Gpu.SampleOp.operation_name));
    try testing.expectEqual(@as(usize, 1), countOperationsNamed(lowered.host, choir.dialects.FuncDialect.CallOp.operation_name));
}

test "stage local array survives CPU lowering and runs from host stack" {
    if (comptime !execution.native.available) return error.SkipZigTest;
    var lowered: LoweredStages = undefined;
    try lowered.init(fixture.stages.alloca_case.source);
    defer lowered.deinit();
    try testing.expectEqual(@as(usize, 2), countOperationsNamed(lowered.host, Memref.AllocaOp.operation_name));

    var runtime = try execution.native.Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(lowered.host);
    const Stage = *const fn ([*]const f32, [*]f32, *anyopaque) callconv(.c) void;
    const fragment: Stage = @ptrFromInt(try runtime.functionAddress(handle, "alloca_fragment"));
    var inputs: [abi.stage.io_words]f32 = @splat(0);
    var outputs: [abi.stage.io_words]f32 = @splat(0);
    var context: [abi.stage.context_words]f32 = @splat(0);
    const color = [_]f32{ 0.125, 0.375, 0.625, 0.875 };
    inputs[abi.stage.slot(abi.stage.smooth, 0, 0)..][0..4].* = color;
    fragment(&inputs, &outputs, &context);
    try testing.expectEqualSlices(f32, &color, outputs[abi.stage.slot(abi.stage.smooth, 0, 0)..][0..4]);
}

test "stage calls retain shared and nested helpers in the CPU twin" {
    if (comptime !execution.native.available) return error.SkipZigTest;
    var lowered: LoweredStages = undefined;
    try lowered.init(fixture.stages.calls_case.source);
    defer lowered.deinit();
    try testing.expectEqual(@as(usize, 6), countOperationsNamed(lowered.host, choir.dialects.FuncDialect.FuncOp.operation_name));
    try testing.expectEqual(@as(usize, 6), countOperationsNamed(lowered.host, choir.dialects.FuncDialect.CallOp.operation_name));
    try testing.expectEqual(@as(usize, 3), countOperationsNamed(lowered.host, Memref.AllocaOp.operation_name));

    var runtime = try execution.native.Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(lowered.host);
    const Stage = *const fn ([*]const f32, [*]f32, *anyopaque) callconv(.c) void;
    const fragment: Stage = @ptrFromInt(try runtime.functionAddress(handle, "calls_fragment"));
    var inputs: [abi.stage.io_words]f32 = @splat(0);
    var outputs: [abi.stage.io_words]f32 = @splat(0);
    var context: [abi.stage.context_words]f32 = @splat(0);
    inputs[abi.stage.slot(abi.stage.smooth, 0, 0)..][0..4].* = .{ 0, 1, 0, 1 };
    fragment(&inputs, &outputs, &context);
    try testing.expectEqualSlices(f32, &.{ 0, 1, 0, 1 }, outputs[abi.stage.slot(abi.stage.smooth, 0, 0)..][0..4]);
}

test "stage CPU lowering refuses recursive calls by name" {
    const source = try std.mem.replaceOwned(u8, testing.allocator, fixture.stages.calls_case.source, "%9 = func.call(%8) {callee = @invert}", "%9 = func.call(%8) {callee = @nested_invert}");
    defer testing.allocator.free(source);
    var session: fixture.stages.Session = undefined;
    try session.init(testing.allocator, .testing, source, false);
    defer session.deinit(testing.allocator);
    var refusal: cpu.StageRefusal = .{};
    try testing.expectError(error.UnsupportedOperation, cpu.lowerStagesToHost(testing.allocator, session.module, &refusal));
    try testing.expectEqualStrings(choir.dialects.FuncDialect.CallOp.operation_name, refusal.operation);
}

test "stage CPU lowering refuses dynamic local array by name" {
    const source = try std.mem.replaceOwned(
        u8,
        testing.allocator,
        fixture.stages.alloca_case.source,
        "%16 = memref.alloca() : !memref<4,arith.f32,local>",
        "%16 = memref.alloca(%12) : !memref<?,arith.f32,local>",
    );
    defer testing.allocator.free(source);
    var session: fixture.stages.Session = undefined;
    try session.init(testing.allocator, .testing, source, false);
    defer session.deinit(testing.allocator);
    var refusal: cpu.StageRefusal = .{};
    try testing.expectError(error.UnsupportedStageMemory, cpu.lowerStagesToHost(testing.allocator, session.module, &refusal));
    try testing.expectEqualStrings(Memref.AllocaOp.operation_name, refusal.operation);
}

test "a fragment that takes derivatives lowers to a quad function sharing each partner slice" {
    var lowered: LoweredStages = undefined;
    try lowered.init(fixture.stages.gradient_case.source);
    defer lowered.deinit();
    try testing.expect(ir.inspection.functionDefinitionByName(lowered.host, "gradient_fragment") == null);
    const quad_op = ir.inspection.functionDefinitionByName(lowered.host, "gradient_fragment" ++ abi.stage.quad_suffix).?;
    try testing.expectEqual(@as(usize, 4), (choir.dialects.FuncDialect.FuncOp{ .op = quad_op }).getNumArguments());
    inline for (.{ Gpu.DpdxOp, Gpu.DpdyOp, Gpu.FwidthOp }) |Op| {
        try testing.expectEqual(@as(usize, 0), countOperationsNamed(lowered.host, Op.operation_name));
    }
    try testing.expectEqual(@as(usize, 3 * 5), countOperationsNamed(quad_op, Memref.LoadOp.operation_name));
}

test "a derivative of a helper's result calls the shared helper again at each partner" {
    var lowered: LoweredStages = undefined;
    try lowered.init(fixture.stages.gradient_case.source);
    defer lowered.deinit();
    const quad_op = ir.inspection.functionDefinitionByName(lowered.host, "gradient_call_fragment" ++ abi.stage.quad_suffix).?;
    try testing.expectEqual(@as(usize, 3 * 2), countOperationsNamed(quad_op, choir.dialects.FuncDialect.CallOp.operation_name));
    for ([_][]const u8{ "gradient_scaled", "gradient_twice" }) |name| {
        try testing.expect(ir.inspection.functionDefinitionByName(lowered.host, name) != null);
    }
    try testing.expectEqual(@as(usize, 5), countOperationsNamed(lowered.host, choir.dialects.FuncDialect.FuncOp.operation_name));
}

test "quad derivatives run through the x86_64 JIT as the odd lane minus the even lane" {
    if (comptime !execution.native.available) return error.SkipZigTest;
    const layout = abi.stage;
    var lowered: LoweredStages = undefined;
    try lowered.init(fixture.stages.gradient_case.source);
    defer lowered.deinit();
    var runtime = try execution.native.Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();
    const handle = try runtime.compile(lowered.host);
    const Quad = *const fn ([*]const f32, usize, [*]f32, *anyopaque) callconv(.c) void;
    const fragment: Quad = @ptrFromInt(try runtime.functionAddress(handle, "gradient_fragment" ++ layout.quad_suffix));
    var context: [layout.context_words]f32 = @splat(0);
    var quad: [layout.quad_lanes][layout.io_words]f32 = @splat(@splat(0));
    var q: [layout.quad_lanes]f32 = undefined;
    const u = [layout.quad_lanes]f32{ 0.25, 1, 0.5, 3 };
    for (&quad, &q, u, 0..) |*block, *product, value, lane| {
        const x: f32 = @floatFromInt(2 + (lane & 1));
        const y: f32 = @floatFromInt(4 + (lane >> 1));
        block[layout.frag_coord..][0..4].* = .{ x + 0.5, y + 0.5, 0, 1 };
        block[layout.slot(layout.smooth, 0, 0)] = value;
        product.* = (x + 0.5) * (y + 0.5) * 0.015625;
    }
    const call: Quad = @ptrFromInt(try runtime.functionAddress(handle, "gradient_call_fragment" ++ layout.quad_suffix));
    var outputs: [layout.io_words]f32 = @splat(0);
    for (0..layout.quad_lanes) |lane| {
        const row = lane & 2;
        const column = lane & 1;
        fragment(@ptrCast(&quad), lane, &outputs, &context);
        const dx = u[row | 1] - u[row];
        const dy = u[2 | column] - u[column];
        const expected = [4]f32{ q[row | 1] - q[row], q[2 | column] - q[column], dx, @abs(dx) + @abs(dy) };
        try testing.expectEqualSlices(f32, &expected, outputs[layout.slot(layout.smooth, 0, 0)..][0..4]);
        call(@ptrCast(&quad), lane, &outputs, &context);
        const twice_dx = (u[row | 1] + u[row | 1]) - (u[row] + u[row]);
        const twice_dy = (u[2 | column] + u[2 | column]) - (u[column] + u[column]);
        const through_helpers = [4]f32{ expected[0], expected[1], twice_dx, @abs(twice_dx) + @abs(twice_dy) };
        try testing.expectEqualSlices(f32, &through_helpers, outputs[layout.slot(layout.smooth, 0, 0)..][0..4]);
    }
    for (&quad) |*block| block[layout.slot(layout.smooth, 0, 0)] = 0.5;
    for (0..layout.quad_lanes) |lane| {
        fragment(@ptrCast(&quad), lane, &outputs, &context);
        try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(outputs[layout.slot(layout.smooth, 0, 2)])));
    }
}

test "quad lowering refuses by name what a partner cannot recompute" {
    const gradient = fixture.stages.gradient_case.source;
    const needle = "        %18 = gpu.dpdx(%8) : !arith.f32\n";
    const Case = struct { replacement: []const u8, refused: []const u8 };
    const cases = [_]Case{
        .{
            .replacement = "        %18 = gpu.dpdx(%16) : !arith.f32\n",
            .refused = Gpu.DpdxOp.operation_name,
        },
        .{
            .replacement =
            \\        %50 = arith.constant() properties(0:i64) : !arith.index
            \\        %51 = memref.alloca() : !memref<1,arith.f32,local>
            \\        memref.store(%8, %51, %50)
            \\        %52 = memref.load(%51, %50) : !arith.f32
            \\        %18 = gpu.dpdx(%52) : !arith.f32
            \\
            ,
            .refused = Memref.AllocaOp.operation_name,
        },
        .{
            .replacement =
            \\        %18 = gpu.dpdx(%8) : !arith.f32
            \\        %50 = gpu.front_facing() : !arith.bool
            \\        scf.if(%50) {
            \\          ^bb0:
            \\            %51 = gpu.dpdy(%8) : !arith.f32
            \\            gpu.stage_output(%51) {location = 1:i64}
            \\            scf.yield()
            \\        } {
            \\          ^bb0:
            \\            scf.yield()
            \\        }
            \\
            ,
            .refused = Gpu.DpdyOp.operation_name,
        },
    };
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, gradient, needle));
    for (cases) |case| {
        const source = try std.mem.replaceOwned(u8, testing.allocator, gradient, needle, case.replacement);
        defer testing.allocator.free(source);
        var session: fixture.stages.Session = undefined;
        try session.init(testing.allocator, .testing, source, false);
        defer session.deinit(testing.allocator);
        var refusal: cpu.StageRefusal = .{};
        try testing.expectError(error.UnsupportedOperation, cpu.lowerStagesToHost(testing.allocator, session.module, &refusal));
        try testing.expectEqualStrings(case.refused, refusal.operation);
    }
}

/// The texel `sampleStub` returns: the coordinates it was given, then the key and the level.
fn sampleStub(context: *anyopaque, key: i32, outputs: [*]f32) callconv(.c) void {
    const calls: *u32 = @ptrCast(@alignCast(context));
    calls.* += 1;
    const layout = abi.stage;
    const u = outputs[layout.sample];
    const v = outputs[layout.sample + 1];
    const lod = outputs[layout.sample + 2];
    outputs[layout.sample..][0..4].* = .{ u, v, @floatFromInt(key), lod };
}

test "lowered textured stages run through the x86_64 JIT" {
    if (comptime !execution.native.available) return error.SkipZigTest;
    const layout = abi.stage;
    var lowered: LoweredStages = undefined;
    try lowered.init(fixture.stages.cases[0].source);
    defer lowered.deinit();
    var runtime = try execution.native.Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol(layout.sample_symbol, @intFromPtr(&sampleStub));
    const handle = try runtime.compile(lowered.host);
    const Stage = *const fn ([*]const f32, [*]f32, *anyopaque) callconv(.c) void;
    const vertex: Stage = @ptrFromInt(try runtime.functionAddress(handle, "textured_vertex"));
    const fragment: Stage = @ptrFromInt(try runtime.functionAddress(handle, "textured_fragment"));

    var calls: u32 = 0;
    var inputs: [layout.io_words]f32 = @splat(0);
    var outputs: [layout.io_words]f32 = @splat(0);
    inputs[layout.slot(layout.smooth, 0, 0)..][0..3].* = .{ 0.25, -0.5, 0.75 };
    inputs[layout.slot(layout.smooth, 1, 0)..][0..2].* = .{ 0.125, 0.875 };
    inputs[layout.slot(layout.smooth, 2, 0)..][0..4].* = .{ 1, 0.5, 0.25, 0.75 };
    vertex(&inputs, &outputs, &calls);
    try testing.expectEqualSlices(f32, &.{ 0.25, -0.5, 0.75, 1 }, outputs[layout.position..][0..4]);
    try testing.expectEqualSlices(f32, &.{ 0.125, 0.875 }, outputs[layout.slot(layout.smooth, 0, 0)..][0..2]);
    try testing.expectEqualSlices(f32, &.{ 1, 0.5, 0.25, 0.75 }, outputs[layout.slot(layout.smooth, 1, 0)..][0..4]);
    try testing.expectEqual(@as(u32, 0xf3), @as(u32, @bitCast(outputs[layout.smooth_mask_low])));
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(outputs[layout.flat_mask_low])));

    var fragment_inputs: [layout.io_words]f32 = @splat(0);
    var fragment_outputs: [layout.io_words]f32 = @splat(0);
    fragment_inputs[layout.slot(layout.smooth, 0, 0)..][0..2].* = .{ 0.5, 0.25 };
    fragment_inputs[layout.slot(layout.smooth, 1, 0)..][0..4].* = .{ 2, 4, 0.5, 1 };
    fragment(&fragment_inputs, &fragment_outputs, &calls);
    try testing.expectEqual(@as(u32, 1), calls);
    try testing.expectEqualSlices(f32, &.{ 1, 1, 0, 0 }, fragment_outputs[layout.slot(layout.smooth, 0, 0)..][0..4]);
}

test "lowered block reads run through the x86_64 JIT over the context words" {
    if (comptime !execution.native.available) return error.SkipZigTest;
    const layout = abi.stage;
    var lowered: LoweredStages = undefined;
    try lowered.init(fixture.stages.cases[2].source);
    defer lowered.deinit();
    var runtime = try execution.native.Runtime.init(testing.allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol(layout.sample_symbol, @intFromPtr(&sampleStub));
    const handle = try runtime.compile(lowered.host);
    const Stage = *const fn ([*]const f32, [*]f32, *anyopaque) callconv(.c) void;
    const vertex: Stage = @ptrFromInt(try runtime.functionAddress(handle, "pushed_vertex"));
    const fragment: Stage = @ptrFromInt(try runtime.functionAddress(handle, "pushed_fragment"));

    var context: [layout.context_words]f32 = @splat(0);
    context[layout.push..][0..4].* = .{ 0.5, -0.25, 2, 0.5 };
    const uniform = layout.uniformWord(1, 0);
    context[uniform..][0..8].* = .{ 1, 0.5, 0.25, 0.5, 0.5, 1, 2, 1 };
    var inputs: [layout.io_words]f32 = @splat(0);
    var outputs: [layout.io_words]f32 = @splat(0);
    inputs[layout.slot(layout.smooth, 0, 0)..][0..3].* = .{ 0.25, 0.5, 0.75 };
    inputs[layout.slot(layout.smooth, 2, 0)..][0..4].* = .{ 1, 1, 1, 1 };
    vertex(&inputs, &outputs, &context);
    try testing.expectEqualSlices(f32, &.{ 1, 0.75, 0.75, 1 }, outputs[layout.position..][0..4]);

    var fragment_inputs: [layout.io_words]f32 = @splat(0);
    var fragment_outputs: [layout.io_words]f32 = @splat(0);
    fragment_inputs[layout.slot(layout.smooth, 0, 0)..][0..4].* = .{ 1, 0.5, 1, 0.5 };
    fragment(&fragment_inputs, &fragment_outputs, &context);
    const color = fragment_outputs[layout.slot(layout.smooth, 0, 0)..][0..4];
    try testing.expectEqualSlices(f32, &.{ 0.25, 0.125, 0.25, 0.25 }, color);
}

test "stage lowering refuses block reads its context cannot place" {
    const pushed = fixture.stages.cases[2];
    const needle = "{binding = 1:i64, group = 0:i64, offset = 12:i64}";
    const refusals = [_][]const u8{
        "{binding = 1:i64, group = 1:i64, offset = 12:i64}",
        "{binding = 8:i64, group = 0:i64, offset = 12:i64}",
        "{binding = 1:i64, group = 0:i64, offset = 1024:i64}",
        "{binding = 1:i64, group = 0:i64, offset = 10:i64}",
    };
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, pushed.source, needle));
    for (refusals) |replacement| {
        const source = try std.mem.replaceOwned(u8, testing.allocator, pushed.source, needle, replacement);
        defer testing.allocator.free(source);
        var session: fixture.stages.Session = undefined;
        try session.init(testing.allocator, .testing, source, false);
        defer session.deinit(testing.allocator);
        var refusal: cpu.StageRefusal = .{};
        const lowered = cpu.lowerStagesToHost(testing.allocator, session.module, &refusal);
        try testing.expectError(error.UnsupportedOperation, lowered);
        try testing.expectEqualStrings(Gpu.UniformOp.operation_name, refusal.operation);
    }
}

/// Fill's grid, 32 by 16 workgroups of 64 invocations, in one row: 32,768
/// invocations, each holding 8 KiB of private memory. A host loop that grew
/// the stack by an alloca per invocation would need 256 MiB of it.
const local_geometry: abi.LaunchGeometry = .{ .grid = .{ 512, 1, 1 }, .threadgroup = .{ 64, 1, 1 } };
const local_total = 32 * 16 * 64;

test "a kernel's private array runs from one host slot across fill's whole grid" {
    if (comptime !execution.native.available) return error.SkipZigTest;
    var twin: Twin = undefined;
    try twin.init(@embedFile("fixture/local.txt"), .{ .entry_name = "test_local" });
    defer twin.deinit();
    try testing.expect(twin.lowered.hasTypedLine("memref.alloca", "!memref<1024,arith.index,host>"));
    const body = twin.lowered.function().getEntryBlock();
    try testing.expectEqual(@as(usize, 1), countOperationsNamed(twin.lowered.host, Memref.AllocaOp.operation_name));
    var allocas = body.getOperations();
    var hoisted = false;
    while (allocas.next()) |op| hoisted = hoisted or std.mem.eql(u8, op.name.name, Memref.AllocaOp.operation_name);
    try testing.expect(hoisted);

    const out = try testing.allocator.alloc(usize, local_total + 1);
    defer testing.allocator.free(out);
    const bytes = std.mem.sliceAsBytes(out);
    @memset(bytes, sentinel);
    try twin.run(&.{memrefOf(bytes)}, try abi.launchShape(local_total, local_geometry));
    for (out[0..local_total], 0..) |word, index| try testing.expectEqual(index + 7, word);
    for (bytes[local_total * @sizeOf(usize) ..]) |byte| try testing.expectEqual(sentinel, byte);
}

test "a kernel's private array of dynamic size refuses" {
    const source = try std.mem.replaceOwned(
        u8,
        testing.allocator,
        @embedFile("fixture/local.txt"),
        "%5 = memref.alloca() : !memref<1024,arith.index,local>",
        "%5 = memref.alloca(%3) : !memref<?,arith.index,local>",
    );
    defer testing.allocator.free(source);
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try registration.prepareCompilationDialects(&ctx);
    const kernel = try fixture.parse(&ctx, source);
    defer kernel.erase();
    try testing.expectError(
        error.UnsupportedOperation,
        cpu.lowerKernelToHostLoop(testing.allocator, kernel, .{ .entry_name = "test_local" }),
    );
}
